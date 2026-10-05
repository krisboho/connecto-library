--[[
Shelf Sync for KOReader.

Mirrors one Grimmory shelf into a folder on the device:
  * new books on the shelf are downloaded
  * books taken off the shelf (or deleted from the library) are removed,
    but only files this plugin downloaded, and never the book that is open
Runs automatically when the device wakes or Wi-Fi connects, and on demand.

Network work happens in a forked subprocess (shelfsync/job.lua) so the reader
never freezes; the main process applies deletions and updates the manifest.
The subprocess reports progress through a small JSON file; the main process
reads it once a second and shows a live box ("Sync now") or short toasts
(automatic syncs), and the menu shows "Syncing now: …" while it runs.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = ffiutil.template

local Plan = require("shelfsync/plan")

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/shelfsync.lua"
local MANIFEST_FILE = DataStorage:getSettingsDir() .. "/shelfsync_manifest.lua"
local PROGRESS_FILE = DataStorage:getSettingsDir() .. "/shelfsync_progress.json"
local POLL_SECONDS = 1
local JOB_TIMEOUT_SECONDS = 30 * 60
local WAKE_RETRY_SECONDS = 5
local WAKE_RETRY_LIMIT = 12 -- ~60s of waiting for Wi-Fi after wake
local BOX_REFRESH_SECONDS = 2 -- live box repaint rate (e-ink friendly)
local BIG_FILE_KB = 20 * 1024 -- files this size get percent toasts in automatic syncs

-- Shared across plugin instances (the file manager and the reader each create
-- one); the module file is loaded once, so this table is a singleton.
local state = {
    running = false,
    settings = nil,
    manifest = nil,
    progress = nil,      -- last progress table read from the subprocess
    box = nil,           -- live InfoMessage while a manual sync runs
    box_wanted = false,  -- false once the user taps the box away
    box_text = nil,
    box_at = 0,
    box_closing = false, -- our own close in progress: not a user dismissal
    last_toast_key = nil,
}

local function settings()
    if not state.settings then
        state.settings = LuaSettings:open(SETTINGS_FILE)
    end
    return state.settings
end

local function manifest()
    if not state.manifest then
        state.manifest = LuaSettings:open(MANIFEST_FILE)
    end
    return state.manifest
end

local function manifestBooks()
    return manifest():readSetting("books") or {}
end

local function fileExists(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

local function openDocumentPath()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
        return ReaderUI.instance.document.file
    end
    return nil
end

local function refreshFileBrowser()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager and FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

---------------------------------------------------------------------------
-- Progress: read what the subprocess reports and turn it into words
---------------------------------------------------------------------------

local function readProgress()
    local fh = io.open(PROGRESS_FILE, "rb")
    if not fh then return nil end
    local raw = fh:read("*a")
    fh:close()
    local ok, p = pcall(json.decode, raw, json.decode.simple)
    if ok and type(p) == "table" then return p end
    return nil
end

local function fmtSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 100 * 1048576 then return string.format("%d MB", bytes / 1048576) end
    if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
    return string.format("%d KB", bytes / 1024)
end

local function fmtSpeed(bytes_per_s)
    if not bytes_per_s or bytes_per_s <= 0 then return nil end
    if bytes_per_s >= 1048576 then return string.format("%.1f MB/s", bytes_per_s / 1048576) end
    return string.format("%d KB/s", bytes_per_s / 1024)
end

local function fmtDuration(seconds)
    if seconds < 60 then return T(_("%1 s"), math.floor(seconds)) end
    return T(_("%1 min"), math.floor(seconds / 60 + 0.5))
end

local function routeLabel(route)
    if route == "proxy" then return _("via Tailscale") end
    return _("direct")
end

-- Numbers behind a download stage: percent, speed, time left.
local function downloadStats(p)
    local bytes = tonumber(p.bytes) or 0
    local size = (tonumber(p.size_kb) or 0) * 1024
    local elapsed = math.max(1, os.time() - (tonumber(p.file_started) or os.time()))
    local speed = bytes > 0 and bytes / elapsed or nil
    local pct = size > 0 and math.min(100, math.floor(bytes * 100 / size)) or nil
    local left = (speed and size > bytes) and (size - bytes) / speed or nil
    return bytes, size, pct, speed, left
end

-- compact=true gives a one-line toast; otherwise a multi-line box text.
local function progressText(p, compact)
    local sep = compact and " · " or "\n"
    local head = compact and "Shelf Sync: " or _("Shelf Sync") .. "\n"
    if not p or not p.stage then
        return head .. _("starting…")
    end
    if p.stage == "connect" then
        return head .. T(_("connecting to %1 (%2)…"), tostring(p.server or ""), routeLabel(p.route))
    elseif p.stage == "login" then
        return head .. _("signing in…")
    elseif p.stage == "shelf" then
        return head .. _("reading the shelf…")
    elseif p.stage == "plan" then
        local n = tonumber(p.total) or 0
        if n == 0 then return head .. _("nothing new to download") end
        return head .. T(_("%1 to download (%2)"),
            n == 1 and _("1 book") or T(_("%1 books"), n), fmtSize((tonumber(p.total_kb) or 0) * 1024))
    elseif p.stage == "download" then
        local bytes, size, pct, speed, left = downloadStats(p)
        local name = tostring(p.name or ""):gsub("%.[^.]+$", "")
        local parts = {}
        if compact then
            parts[1] = T(_("%1 of %2"), p.step or 1, p.total or 1)
            parts[2] = name
            if pct then parts[#parts + 1] = pct .. "%" end
            if speed then parts[#parts + 1] = fmtSpeed(speed) end
            if tonumber(p.attempt) and p.attempt > 1 then parts[#parts + 1] = _("retrying") end
            return head .. table.concat(parts, sep)
        end
        parts[1] = T(_("downloading %1 of %2"), p.step or 1, p.total or 1)
        parts[2] = name
        local line = pct and T(_("%1% of %2"), pct, fmtSize(size)) or fmtSize(bytes)
        if speed then line = line .. " · " .. fmtSpeed(speed) end
        if left then line = line .. " · " .. T(_("about %1 left"), fmtDuration(left)) end
        parts[3] = line
        if tonumber(p.attempt) and p.attempt > 1 then parts[4] = _("second try after an interrupted download") end
        parts[#parts + 1] = _("(tap to hide; it keeps syncing)")
        return head .. table.concat(parts, sep)
    elseif p.stage == "done" then
        return head .. _("finishing…")
    end
    return head .. tostring(p.stage)
end

-- Something worth a toast during an automatic sync? Returns a key that
-- changes only at milestones: the plan, each new file, and 25% steps of big files.
local function toastKey(p)
    if not p or not p.stage then return nil end
    if p.stage == "plan" then
        return (tonumber(p.total) or 0) > 0 and "plan" or nil
    elseif p.stage == "download" then
        local key = "file" .. tostring(p.step)
        if (tonumber(p.size_kb) or 0) >= BIG_FILE_KB then
            local _, _, pct = downloadStats(p)
            key = key .. ":" .. tostring(math.floor((pct or 0) / 25))
        end
        return key
    end
    return nil
end

local ShelfSync = WidgetContainer:extend{
    name = "shelfsync",
    is_doc_only = false,
}

---------------------------------------------------------------------------
-- Live progress box (manual sync) and toasts (automatic sync)
---------------------------------------------------------------------------

local function closeBox()
    if state.box then
        state.box_closing = true
        UIManager:close(state.box)
        state.box_closing = false
        state.box = nil
    end
end

local function showBox(text)
    closeBox()
    state.box = InfoMessage:new{
        text = text,
        dismiss_callback = function()
            -- InfoMessage calls this on every close, ours included.
            if not state.box_closing then
                state.box_wanted = false -- user tapped it away: toasts from here on
                state.box = nil
            end
        end,
    }
    state.box_text = text
    state.box_at = os.time()
    UIManager:show(state.box)
end

local function onProgress(p)
    state.progress = p
    local now = os.time()
    if state.box_wanted then
        local text = progressText(p, false)
        local stage_change = p and p.stage ~= "download"
        if text ~= state.box_text and (stage_change or now - state.box_at >= BOX_REFRESH_SECONDS) then
            showBox(text)
        end
        return
    end
    local key = toastKey(p)
    if key and key ~= state.last_toast_key then
        state.last_toast_key = key
        Notification:notify(progressText(p, true), Notification.SOURCE_ALWAYS_SHOW)
    end
end

---------------------------------------------------------------------------
-- Settings helpers
---------------------------------------------------------------------------

function ShelfSync:getUrls()
    local s = settings()
    local urls = {}
    for _, key in ipairs({ "home_url", "away_url" }) do
        local v = s:readSetting(key)
        if type(v) == "string" and v:match("%S") then
            urls[#urls + 1] = v
        end
    end
    return urls
end

function ShelfSync:getFolder()
    return settings():readSetting("folder")
        or (filemanagerutil.getHomeFolder() .. "/Grimmory")
end

function ShelfSync:isConfigured()
    local s = settings()
    return #self:getUrls() > 0
        and s:readSetting("username") and s:readSetting("password")
        and s:readSetting("shelf_id") ~= nil
end

function ShelfSync:autoEnabled()
    return settings():nilOrTrue("auto_sync")
end

function ShelfSync:removeEnabled()
    return settings():nilOrTrue("remove_deleted")
end

---------------------------------------------------------------------------
-- Lifecycle and events
---------------------------------------------------------------------------

function ShelfSync:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function ShelfSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("shelfsync_sync", {
        category = "none", event = "ShelfSyncNow",
        title = _("Shelf Sync: sync now"), general = true,
    })
end

function ShelfSync:onShelfSyncNow()
    self:syncNow(true)
    return true
end

function ShelfSync:onResume()
    if not self:autoEnabled() or not self:isConfigured() then return end
    -- Wi-Fi usually takes a few seconds to come back after wake. Poll briefly;
    -- a NetworkConnected event (if it fires) will also trigger a sync.
    self._wake_tries = 0
    UIManager:unschedule(self._wakeCheck)
    self._wakeCheck = function()
        self._wake_tries = (self._wake_tries or 0) + 1
        if NetworkMgr:isConnected() then
            self:syncNow(false)
        elseif self._wake_tries < WAKE_RETRY_LIMIT then
            UIManager:scheduleIn(WAKE_RETRY_SECONDS, self._wakeCheck)
        end
    end
    UIManager:scheduleIn(3, self._wakeCheck)
end

function ShelfSync:onNetworkConnected()
    if not self:autoEnabled() or not self:isConfigured() then return end
    UIManager:unschedule(self._netSync)
    self._netSync = function() self:syncNow(false) end
    UIManager:scheduleIn(2, self._netSync)
end

function ShelfSync:onSuspend()
    if self._wakeCheck then UIManager:unschedule(self._wakeCheck) end
    if self._netSync then UIManager:unschedule(self._netSync) end
end

function ShelfSync:onCloseWidget()
    self:onSuspend()
    -- The file manager or reader that owns this instance is closing (for
    -- example a book is being opened); a modal box must not outlive it.
    if state.box then
        state.box_wanted = false
        closeBox()
    end
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

function ShelfSync:syncNow(interactive)
    if state.running then
        if interactive then
            state.box_wanted = true
            showBox(progressText(state.progress, false))
        end
        return
    end
    if not self:isConfigured() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Shelf Sync is not set up yet.\n\nSet the server, account and shelf first."),
            })
        end
        return
    end

    if interactive then
        NetworkMgr:runWhenConnected(function() self:_start(true) end)
    else
        -- Automatic: never prompt, never turn Wi-Fi on by ourselves.
        if not NetworkMgr:isConnected() then return end
        local s = settings()
        local min_gap = (s:readSetting("min_interval_minutes") or 5) * 60
        local last = s:readSetting("last_attempt") or 0
        if os.time() - last < min_gap then
            logger.dbg("ShelfSync: skipping, last attempt", os.time() - last, "s ago")
            return
        end
        self:_start(false)
    end
end

function ShelfSync:_start(interactive)
    if state.running then return end
    state.running = true
    local s = settings()
    s:saveSetting("last_attempt", os.time())
    s:flush()

    local cfg = {
        urls = self:getUrls(),
        username = s:readSetting("username"),
        password = s:readSetting("password"),
        shelf_id = s:readSetting("shelf_id"),
        folder = self:getFolder(),
        open_path = openDocumentPath(),
        proxy = require("socket.http").PROXY, -- KOReader's HTTP proxy (Tailscale userspace mode)
        progress_file = PROGRESS_FILE,
    }
    local snapshot = manifestBooks()

    os.remove(PROGRESS_FILE)
    state.progress = nil
    state.last_toast_key = nil
    state.box_wanted = interactive and true or false
    if interactive then
        showBox(progressText(nil, false))
    end
    UIManager:preventStandby()

    local pid, fd = ffiutil.runInSubProcess(function(_pid, child_fd)
        local Job = require("shelfsync/job")
        local ok, res = pcall(Job.run, cfg, snapshot)
        if not ok then
            res = { ok = false, error = "sync crashed: " .. tostring(res) }
        end
        ffiutil.writeToFD(child_fd, json.encode(res), true)
    end, true)

    if not pid then
        self:_finish(interactive, { ok = false, error = "could not start sync process: " .. tostring(fd) })
        return
    end

    local started = os.time()
    local poll
    poll = function()
        local has_output = ffiutil.getNonBlockingReadSize(fd) ~= 0
        local done = ffiutil.isSubProcessDone(pid)
        if has_output then
            local raw = ffiutil.readAllFromFD(fd)
            local ok, res = pcall(json.decode, raw, json.decode.simple)
            if not ok or type(res) ~= "table" then
                res = { ok = false, error = "unreadable result from sync process" }
            end
            if not done then self:_reap(pid) end
            self:_finish(interactive, res)
        elseif done then
            ffiutil.readAllFromFD(fd)
            self:_finish(interactive, { ok = false, error = "sync process exited without a result" })
        elseif os.time() - started > JOB_TIMEOUT_SECONDS then
            ffiutil.terminateSubProcess(pid)
            ffiutil.readAllFromFD(fd)
            self:_reap(pid)
            self:_finish(interactive, { ok = false, error = "sync timed out" })
        else
            local p = readProgress()
            if p then onProgress(p) end
            UIManager:scheduleIn(POLL_SECONDS, poll)
        end
    end
    UIManager:scheduleIn(POLL_SECONDS, poll)
end

function ShelfSync:_reap(pid)
    local reap
    reap = function()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(2, reap)
        end
    end
    UIManager:scheduleIn(2, reap)
end

-- Delete one plugin-managed file the KOReader way (sidecar, history, collections).
local function deleteBookFile(path)
    if not fileExists(path) then return true end
    local FileManager = require("apps/filemanager/filemanager")
    return FileManager:deleteFile(path, true) == true
end

function ShelfSync:_applyDeletes(items)
    local books = manifestBooks()
    local open_path = openDocumentPath()
    local removed, kept = 0, 0
    for _, item in ipairs(items) do
        local entry = books[item.id]
        -- Re-check against the live manifest and the currently open book.
        if entry and entry.path == item.path then
            if open_path and item.path == open_path then
                kept = kept + 1
            elseif deleteBookFile(item.path) then
                books[item.id] = nil
                removed = removed + 1
                logger.info("ShelfSync: removed", item.path)
            else
                kept = kept + 1
            end
        end
    end
    manifest():saveSetting("books", books)
    manifest():flush()
    return removed, kept
end

function ShelfSync:_finish(interactive, res)
    state.running = false
    UIManager:allowStandby()
    closeBox()
    state.box_wanted = false
    state.progress = nil
    os.remove(PROGRESS_FILE)
    local s = settings()
    s:saveSetting("last_finished", os.time())

    if not res.ok then
        local msg = T(_("Shelf Sync failed: %1"), tostring(res.error))
        logger.warn("ShelfSync:", msg)
        s:saveSetting("last_result", msg)
        s:flush()
        if interactive then
            UIManager:show(InfoMessage:new{ text = msg, icon = "notice-warning" })
        end
        return
    end

    -- Record downloads first so they are never orphaned.
    local books = manifestBooks()
    local added = 0
    local open_path = openDocumentPath()
    for _, dl in ipairs(res.downloaded or {}) do
        books[tostring(dl.id)] = { path = dl.path, file_id = dl.file_id }
        added = added + 1
        local secs = math.max(1, tonumber(dl.seconds) or 1)
        logger.info("ShelfSync: downloaded", dl.path, fmtSize(dl.bytes), "in", secs .. "s",
            fmtSpeed((tonumber(dl.bytes) or 0) / secs) or "")
        if dl.replaces and dl.replaces ~= dl.path and dl.replaces ~= open_path then
            deleteBookFile(dl.replaces)
        end
    end
    manifest():saveSetting("books", books)
    manifest():flush()

    local deletes = self:removeEnabled() and (res.delete or {}) or {}
    local failed = #(res.failed or {})
    local deferred = #(res.deferred or {})

    local function report(removed, kept_extra)
        refreshFileBrowser()
        local summary = T(_("Shelf Sync: %1 added, %2 removed"), added, removed)
        if failed > 0 then summary = summary .. T(_(", %1 failed"), failed) end
        local waiting = deferred + (kept_extra or 0)
        if waiting > 0 then summary = summary .. T(_(", %1 waiting"), waiting) end
        s:saveSetting("last_result", summary .. " — " .. os.date("%Y-%m-%d %H:%M") .. " via " .. tostring(res.server)
            .. " (" .. routeLabel(res.route) .. ")")
        s:saveSetting("last_success", os.time())
        s:flush()
        if interactive or added > 0 or removed > 0 or failed > 0 then
            Notification:notify(summary, Notification.SOURCE_ALWAYS_SHOW)
        end
        for _, f in ipairs(res.failed or {}) do
            logger.warn("ShelfSync: failed", f.id, f.name, f.error)
        end
    end

    local total = 0
    for _ in pairs(books) do total = total + 1 end
    if #deletes > 0 and Plan.isMassDelete(#deletes, total) then
        if interactive then
            UIManager:show(ConfirmBox:new{
                text = T(_("The shelf no longer lists %1 of the %2 books synced to this device.\n\nRemove them from this device?"), #deletes, total),
                ok_text = _("Remove"),
                ok_callback = function()
                    report(self:_applyDeletes(deletes))
                end,
                cancel_callback = function() report(0, #deletes) end,
            })
        else
            logger.warn("ShelfSync: refusing automatic mass delete of", #deletes, "books")
            report(0, #deletes)
        end
        return
    end

    local removed, kept = self:_applyDeletes(deletes)
    report(removed, kept)
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

function ShelfSync:showAccountDialog(touchmenu_instance)
    local s = settings()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Grimmory server and account"),
        fields = {
            { description = _("Home address"), text = s:readSetting("home_url") or "", hint = "http://192.168.0.9:6060" },
            { description = _("Away address (Tailscale)"), text = s:readSetting("away_url") or "", hint = "http://100.x.y.z:6060" },
            { description = _("Username"), text = s:readSetting("username") or "", hint = _("Grimmory username") },
            { description = _("Password"), text = s:readSetting("password") or "", text_type = "password", hint = _("Grimmory password") },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local f = dialog:getFields()
                s:saveSetting("home_url", f[1])
                s:saveSetting("away_url", f[2])
                s:saveSetting("username", f[3])
                s:saveSetting("password", f[4])
                s:flush()
                UIManager:close(dialog)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ShelfSync:chooseShelf(touchmenu_instance)
    local s = settings()
    if #self:getUrls() == 0 or not s:readSetting("username") then
        UIManager:show(InfoMessage:new{ text = _("Set the server and account first.") })
        return
    end
    NetworkMgr:runWhenConnected(function()
        local wait = InfoMessage:new{ text = _("Loading shelves…") }
        UIManager:show(wait)
        UIManager:forceRePaint()
        local Job = require("shelfsync/job")
        local shelves, err = Job.listShelves(self:getUrls(), s:readSetting("username"), s:readSetting("password"),
            require("socket.http").PROXY)
        UIManager:close(wait)
        if not shelves then
            UIManager:show(InfoMessage:new{ text = T(_("Could not load shelves: %1"), tostring(err)), icon = "notice-warning" })
            return
        end
        if #shelves == 0 then
            UIManager:show(InfoMessage:new{ text = _("This account has no shelves. Create one in Grimmory (for example \"Kindle\") and add books to it.") })
            return
        end
        local ButtonDialog = require("ui/widget/buttondialog")
        local picker
        local buttons = {}
        for _, shelf in ipairs(shelves) do
            table.insert(buttons, {{
                text = shelf.name,
                callback = function()
                    UIManager:close(picker)
                    if s:readSetting("shelf_id") ~= shelf.id then
                        s:saveSetting("shelf_id", shelf.id)
                        s:saveSetting("shelf_name", shelf.name)
                        s:flush()
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            }})
        end
        table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(picker) end }})
        picker = ButtonDialog:new{ title = _("Which shelf should this device mirror?"), buttons = buttons }
        UIManager:show(picker)
    end)
end

function ShelfSync:addToMainMenu(menu_items)
    menu_items.shelfsync = {
        text = _("Shelf Sync (Grimmory)"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                keep_menu_open = true,
                callback = function() self:syncNow(true) end,
            },
            {
                text_func = function()
                    local s = settings()
                    local user = s:readSetting("username")
                    return user and T(_("Server and account: %1"), user) or _("Server and account…")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:showAccountDialog(touchmenu_instance) end,
            },
            {
                text_func = function()
                    local name = settings():readSetting("shelf_name")
                    return name and T(_("Shelf: %1"), name) or _("Choose shelf…")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:chooseShelf(touchmenu_instance) end,
            },
            {
                text_func = function()
                    return T(_("Folder: %1"), filemanagerutil.abbreviate(self:getFolder()))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    filemanagerutil.showChooseDialog(_("Shelf Sync folder:"), function(path)
                        settings():saveSetting("folder", path)
                        settings():flush()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end, self:getFolder(), filemanagerutil.getHomeFolder() .. "/Grimmory")
                end,
                separator = true,
            },
            {
                text = _("Sync automatically on wake and Wi-Fi connect"),
                checked_func = function() return self:autoEnabled() end,
                callback = function()
                    settings():saveSetting("auto_sync", not self:autoEnabled())
                    settings():flush()
                end,
            },
            {
                text = _("Remove books taken off the shelf"),
                checked_func = function() return self:removeEnabled() end,
                callback = function()
                    settings():saveSetting("remove_deleted", not self:removeEnabled())
                    settings():flush()
                end,
                separator = true,
            },
            {
                text_func = function()
                    if state.running then
                        local short = progressText(state.progress, true):gsub("^Shelf Sync: ", "")
                        return T(_("Syncing now: %1"), short)
                    end
                    return settings():readSetting("last_result") or _("Last sync: never")
                end,
                keep_menu_open = true,
                callback = function()
                    if state.running then
                        state.box_wanted = true
                        showBox(progressText(state.progress, false))
                        return
                    end
                    UIManager:show(InfoMessage:new{
                        text = settings():readSetting("last_result") or _("No sync has run yet."),
                    })
                end,
            },
        },
    }
end

return ShelfSync
