--[[
Shelf Sync for KOReader.

Mirrors one Grimmory shelf into a folder on the device:
  * new books on the shelf are downloaded
  * books taken off the shelf (or deleted from the library) are removed,
    but only files this plugin downloaded, and never the book that is open
Runs automatically when the device wakes or Wi-Fi connects, and on demand.

Network work happens in a forked subprocess (shelfsync/job.lua) so the reader
never freezes; the main process applies deletions and updates the manifest.
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
local POLL_SECONDS = 1
local JOB_TIMEOUT_SECONDS = 30 * 60
local WAKE_RETRY_SECONDS = 5
local WAKE_RETRY_LIMIT = 12 -- ~60s of waiting for Wi-Fi after wake

-- Shared across plugin instances (the file manager and the reader each create
-- one); the module file is loaded once, so this table is a singleton.
local state = {
    running = false,
    settings = nil,
    manifest = nil,
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

local ShelfSync = WidgetContainer:extend{
    name = "shelfsync",
    is_doc_only = false,
}

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
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

function ShelfSync:syncNow(interactive)
    if state.running then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Shelf Sync is already running."), timeout = 2 })
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
    }
    local snapshot = manifestBooks()

    if interactive then
        Notification:notify(_("Shelf Sync: syncing…"), Notification.SOURCE_ALWAYS_SHOW)
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
        s:saveSetting("last_result", summary .. " — " .. os.date("%Y-%m-%d %H:%M") .. " via " .. tostring(res.server))
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
        local shelves, err = Job.listShelves(self:getUrls(), s:readSetting("username"), s:readSetting("password"))
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
                    return settings():readSetting("last_result") or _("Last sync: never")
                end,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = settings():readSetting("last_result") or _("No sync has run yet."),
                    })
                end,
            },
        },
    }
end

return ShelfSync
