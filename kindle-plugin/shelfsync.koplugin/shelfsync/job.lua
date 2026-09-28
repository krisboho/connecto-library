--[[
Shelf Sync: the network half of a sync, run inside a forked subprocess so the
e-reader UI never freezes. It only ADDS files (download to .part, verify size,
rename). Deletions are decided here but applied by the main process, which can
safely update KOReader's history, collections and sidecar folders.

Input  cfg = { urls = {...}, username, password, shelf_id, folder, open_path }
       manifest = id -> { path, file_id }
Output a plain table (JSON-encoded by the caller).
]]

local Api = require("shelfsync/api")
local Plan = require("shelfsync/plan")
local lfs = require("libs/libkoreader-lfs")

local Job = {}

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

function Job.run(cfg, manifest)
    local result = { ok = false, downloaded = {}, failed = {}, delete = {}, deferred = {} }

    -- 1. Find a reachable server (home LAN first, then Tailscale, etc).
    local api
    local last_err
    for _, url in ipairs(cfg.urls or {}) do
        if url and url ~= "" then
            local candidate = Api.new(url)
            local ok, err = candidate:ping()
            if ok then
                api = candidate
                result.server = url
                break
            end
            last_err = url .. ": " .. tostring(err)
        end
    end
    if not api then
        result.error = "server unreachable" .. (last_err and (" (" .. last_err .. ")") or "")
        return result
    end

    -- 2. Log in and read the shelf.
    local ok, err = api:login(cfg.username, cfg.password)
    if not ok then
        result.error = err
        return result
    end
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

    -- 4. Download.
    for _, item in ipairs(plan.download) do
        local tmp = item.path .. ".part"
        local dl_ok, dl_err, bytes = api:download(item.id, tmp)
        if dl_ok and Plan.sizeOk(bytes, item.size_kb) then
            local renamed, rename_err = os.rename(tmp, item.path)
            if renamed then
                table.insert(result.downloaded, {
                    id = item.id, path = item.path, file_id = item.file_id,
                    replaces = item.replaces, bytes = bytes,
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

    result.ok = true
    return result
end

-- Used by the settings menu (runs in the main process, blocking, short timeouts).
function Job.listShelves(urls, username, password)
    local api, last_err
    for _, url in ipairs(urls or {}) do
        if url and url ~= "" then
            local candidate = Api.new(url)
            local ok, err = candidate:ping()
            if ok then api = candidate break end
            last_err = url .. ": " .. tostring(err)
        end
    end
    if not api then return nil, "server unreachable" .. (last_err and (" (" .. last_err .. ")") or "") end
    local ok, err = api:login(username, password)
    if not ok then return nil, err end
    return api:shelves()
end

return Job
