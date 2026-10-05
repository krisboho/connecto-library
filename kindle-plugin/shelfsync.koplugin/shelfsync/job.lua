--[[
Shelf Sync: the network half of a sync, run inside a forked subprocess so the
e-reader UI never freezes. It only ADDS files (download to .part, verify size,
rename). Deletions are decided here but applied by the main process, which can
safely update KOReader's history, collections and sidecar folders.

Input  cfg = { urls = {...}, username, password, shelf_id, folder, open_path,
               proxy, progress_file }
       manifest = id -> { path, file_id }
Output a plain table (JSON-encoded by the caller).

While it runs it rewrites cfg.progress_file (small JSON, at most once a
second) so the main process can show what is happening.
]]

local Api = require("shelfsync/api")
local Plan = require("shelfsync/plan")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")

local Job = {}

local DOWNLOAD_ATTEMPTS = 2
local RETRY_PAUSE_SECONDS = 3

local function exists(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

local function makeDir(path)
    local acc = ""
    for part in path:gmatch("[^/]+") do
        acc = acc .. "/" .. part
        if lfs.attributes(acc, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(acc)
            if not ok and lfs.attributes(acc, "mode") ~= "directory" then
                return false, err
            end
        end
    end
    return true
end

local function cleanPartials(folder)
    if lfs.attributes(folder, "mode") ~= "directory" then return end
    for name in lfs.dir(folder) do
        if name:match("%.part$") then
            os.remove(folder .. "/" .. name)
        end
    end
end

local function pause(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then socket.sleep(seconds) end
end

-- Progress file: written whole, then renamed, so the reader never sees a torn file.
local function progressWriter(path)
    local prog = { started = os.time() }
    if not path then
        return function(stage, fields) end, prog
    end
    local function write(stage, fields)
        if stage then prog.stage = stage end
        for k, v in pairs(fields or {}) do prog[k] = v end
        prog.updated = os.time()
        local tmp = path .. ".tmp"
        local fh = io.open(tmp, "wb")
        if not fh then return end
        fh:write(json.encode(prog))
        fh:close()
        os.rename(tmp, path)
    end
    return write, prog
end

function Job.run(cfg, manifest)
    local result = { ok = false, downloaded = {}, failed = {}, delete = {}, deferred = {} }
    local report = progressWriter(cfg.progress_file)

    -- 1. Find a reachable route: home LAN direct, then via the proxy, then the
    --    Tailscale address via the proxy, then direct as a last resort.
    local api
    local last_err
    for _, route in ipairs(Plan.routes(cfg.urls, cfg.proxy)) do
        local candidate = Api.new(route.url, route.proxy)
        report("connect", { server = route.url, route = candidate:routeName() })
        local ok, err = candidate:ping()
        if ok then
            api = candidate
            result.server = route.url
            result.route = candidate:routeName()
            break
        end
        last_err = route.url .. " (" .. candidate:routeName() .. "): " .. tostring(err)
    end
    if not api then
        result.error = "server unreachable" .. (last_err and (" (" .. last_err .. ")") or "")
        return result
    end

    -- 2. Log in and read the shelf.
    report("login")
    local ok, err = api:login(cfg.username, cfg.password)
    if not ok then
        result.error = err
        return result
    end
    report("shelf")
    local books
    books, err = api:shelfBooks(cfg.shelf_id)
    if not books then
        result.error = err
        return result
    end

    -- 3. Plan.
    local folder = (cfg.folder or ""):gsub("/+$", "")
    if folder == "" then
        result.error = "no sync folder set"
        return result
    end
    local dir_ok, dir_err = makeDir(folder)
    if not dir_ok then
        result.error = "cannot create " .. folder .. ": " .. tostring(dir_err)
        return result
    end
    cleanPartials(folder)

    local desired = Plan.desired(books)
    local plan = Plan.compute(desired, manifest, folder, exists, cfg.open_path)
    result.delete = plan.delete
    result.deferred = plan.deferred
    result.shelf_count = #Plan.sortedKeys(desired)

    local total_kb = 0
    for _, item in ipairs(plan.download) do total_kb = total_kb + (item.size_kb or 0) end
    report("plan", { total = #plan.download, total_kb = total_kb, removals = #plan.delete })

    -- 4. Download, one attempt plus one retry each (covers a proxy or Wi-Fi blip).
    for i, item in ipairs(plan.download) do
        local tmp = item.path .. ".part"
        local dl_ok, dl_err, bytes, started
        for attempt = 1, DOWNLOAD_ATTEMPTS do
            started = os.time()
            local last_tick = started
            report("download", {
                step = i, total = #plan.download, name = item.name, size_kb = item.size_kb,
                bytes = 0, file_started = started, attempt = attempt,
            })
            dl_ok, dl_err, bytes = api:download(item.id, tmp, function(n)
                local now = os.time()
                if now ~= last_tick then
                    last_tick = now
                    report("download", { bytes = n })
                end
            end)
            if dl_ok and Plan.sizeOk(bytes, item.size_kb) then break end
            os.remove(tmp)
            if attempt < DOWNLOAD_ATTEMPTS then pause(RETRY_PAUSE_SECONDS) end
        end
        if dl_ok and Plan.sizeOk(bytes, item.size_kb) then
            local renamed, rename_err = os.rename(tmp, item.path)
            if renamed then
                table.insert(result.downloaded, {
                    id = item.id, path = item.path, file_id = item.file_id,
                    replaces = item.replaces, bytes = bytes,
                    seconds = os.time() - started,
                })
            else
                os.remove(tmp)
                table.insert(result.failed, { id = item.id, name = item.name, error = tostring(rename_err) })
            end
        else
            os.remove(tmp)
            table.insert(result.failed, {
                id = item.id, name = item.name,
                error = dl_err or ("size mismatch: got " .. tostring(bytes) .. " bytes, expected ~" .. tostring(item.size_kb) .. " KiB"),
            })
        end
    end

    report("done")
    result.ok = true
    return result
end

-- Used by the settings menu (runs in the main process, blocking, short timeouts).
function Job.listShelves(urls, username, password, proxy)
    local api, last_err
    for _, route in ipairs(Plan.routes(urls, proxy)) do
        local candidate = Api.new(route.url, route.proxy)
        local ok, err = candidate:ping()
        if ok then api = candidate break end
        last_err = route.url .. " (" .. candidate:routeName() .. "): " .. tostring(err)
    end
    if not api then return nil, "server unreachable" .. (last_err and (" (" .. last_err .. ")") or "") end
    local ok, err = api:login(username, password)
    if not ok then return nil, err end
    return api:shelves()
end

return Job
