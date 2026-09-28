--[[
Shelf Sync: pure planning logic.

This module has NO KOReader dependencies so it can be unit-tested with plain
LuaJIT on a desktop (see kindle-plugin/spec/plan_spec.lua).

Vocabulary
  book      One entry from Grimmory's GET /api/v1/shelves/{id}/books.
  desired   What should be on the device: id -> { name, file_id, size_kb }.
  manifest  What this plugin has put on the device: id -> { path, file_id }.
            Only files listed in the manifest are ever deleted.
]]

local Plan = {}

-- Formats KOReader reads well. Audiobooks / folder-based books are skipped.
Plan.ALLOWED_EXT = {
    epub = true, kepub = true, pdf = true, mobi = true, azw3 = true, azw = true,
    fb2 = true, cbz = true, cbr = true, djvu = true, txt = true, rtf = true,
}

-- Above this many removals in one pass (and more than half the manifest),
-- automatic syncs refuse to delete and ask for a manual sync instead.
Plan.MASS_DELETE_MIN = 10

local MAX_BASE_BYTES = 180

function Plan.extension(filename)
    if type(filename) ~= "string" then return nil end
    local ext = filename:match("%.([^./]+)$")
    return ext and ext:lower() or nil
end

-- Cut a UTF-8 string to at most max_bytes without splitting a character.
function Plan.utf8Truncate(s, max_bytes)
    if #s <= max_bytes then return s end
    local cut = max_bytes
    -- Walk back over continuation bytes (10xxxxxx) to a character boundary.
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- A filename that is safe on the Kindle's FAT/ext filesystem.
function Plan.safeName(filename, book_id)
    filename = type(filename) == "string" and filename or ""
    local base, ext = filename:match("^(.*)%.([^./]+)$")
    if not base then base, ext = filename, nil end
    base = base:gsub("[%c/\\:%*%?\"<>|]", "_")
    base = base:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
    if base == "" then base = "book-" .. tostring(book_id) end
    base = Plan.utf8Truncate(base, MAX_BASE_BYTES):gsub("[%s%.]+$", "")
    if ext then
        return base .. "." .. ext:lower()
    end
    return base
end

-- "Name.epub" -> "Name [42].epub"
function Plan.withId(name, book_id)
    local base, ext = name:match("^(.*)(%.[^./]+)$")
    if not base then base, ext = name, "" end
    return string.format("%s [%s]%s", base, tostring(book_id), ext)
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
    end)
    return keys
end
Plan.sortedKeys = sortedKeys

--[[
Turn the server's shelf listing into the desired set.
Keys are strings (LuaSettings/JSON friendly).
Books whose file names collide get " [id]" appended so both survive.
]]
function Plan.desired(books)
    local desired, by_name = {}, {}
    for _, book in ipairs(books or {}) do
        local pf = type(book) == "table" and book.primaryFile
        local id = type(book) == "table" and book.id
        if id and type(pf) == "table" and not pf.folderBased and pf.fileName then
            local ext = Plan.extension(pf.fileName)
            if ext and Plan.ALLOWED_EXT[ext] then
                local key = tostring(id)
                local name = Plan.safeName(pf.fileName, id)
                local lower = name:lower()
                if by_name[lower] then
                    name = Plan.withId(name, id)
                    lower = name:lower()
                end
                by_name[lower] = key
                desired[key] = {
                    name = name,
                    file_id = pf.id,
                    size_kb = tonumber(pf.fileSizeKb),
                }
            end
        end
    end
    return desired
end

--[[
Compare desired vs manifest.
  exists(path) -> bool       does a file exist on the device
  folder                     target directory (no trailing slash)
  open_path                  file currently open in the reader (never touched)
Returns { download = {...}, delete = {...}, deferred = {...} }
  download item: { id, name, path, file_id, size_kb, replaces }
  delete item:   { id, path }
]]
function Plan.compute(desired, manifest, folder, exists, open_path)
    local result = { download = {}, delete = {}, deferred = {} }
    manifest = manifest or {}

    -- Paths the plugin owns, so name collisions with user files can be detected.
    local owned = {}
    for _, entry in pairs(manifest) do
        if entry.path then owned[entry.path] = true end
    end

    for _, id in ipairs(sortedKeys(desired)) do
        local want = desired[id]
        local have = manifest[id]
        local need, replaces = false, nil
        if not have then
            need = true
        elseif have.file_id ~= want.file_id then
            need, replaces = true, have.path
        elseif not exists(have.path) then
            need = true
        end
        if need then
            local path
            if have and have.file_id == want.file_id and have.path then
                path = have.path -- re-fetch to the same place
            else
                path = folder .. "/" .. want.name
                if exists(path) and not owned[path] then
                    path = folder .. "/" .. Plan.withId(want.name, id)
                end
            end
            if open_path and (path == open_path or replaces == open_path) then
                table.insert(result.deferred, { id = id, path = path, reason = "open" })
            else
                table.insert(result.download, {
                    id = id, name = want.name, path = path,
                    file_id = want.file_id, size_kb = want.size_kb,
                    replaces = (replaces ~= path) and replaces or nil,
                })
            end
        end
    end

    for _, id in ipairs(sortedKeys(manifest)) do
        if not desired[id] then
            local path = manifest[id].path
            if open_path and path == open_path then
                table.insert(result.deferred, { id = id, path = path, reason = "open" })
            else
                table.insert(result.delete, { id = id, path = path })
            end
        end
    end

    return result
end

-- Grimmory reports whole KiB; allow a little slack either way.
function Plan.sizeOk(actual_bytes, size_kb)
    if type(actual_bytes) ~= "number" or actual_bytes <= 0 then return false end
    if type(size_kb) ~= "number" or size_kb <= 0 then return true end
    return math.abs(actual_bytes - size_kb * 1024) <= 2048
end

function Plan.isMassDelete(n_delete, n_manifest)
    return n_delete > Plan.MASS_DELETE_MIN and n_delete > (n_manifest / 2)
end

return Plan
