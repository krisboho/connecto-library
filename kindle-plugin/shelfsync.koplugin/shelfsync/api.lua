--[[
Shelf Sync: minimal Grimmory REST client.

Endpoints used (all present in Grimmory v3.5.0):
  GET  /api/v1/healthcheck             no auth, reachability probe
  POST /api/v1/auth/login              { username, password } -> { accessToken }
  GET  /api/v1/shelves                 the caller's shelves
  GET  /api/v1/shelves/{id}/books      books on one shelf (with primaryFile)
  GET  /api/v1/books/{id}/download     original file bytes (needs download permission)

Plain HTTP is expected (LAN or a Tailscale 100.x address). KOReader's global
HTTP proxy setting (used by Tailscale userspace mode) applies automatically.
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local socketutil = require("socketutil")

local Api = {}
Api.__index = Api

local function decode(text)
    if type(text) ~= "string" or text == "" then return nil end
    local ok, value = pcall(json.decode, text, json.decode.simple)
    if ok then return value end
    return nil
end

function Api.new(base_url)
    local base = tostring(base_url or ""):gsub("%s+", ""):gsub("/+$", "")
    return setmetatable({ base = base, token = nil }, Api)
end

-- Returns code (number or nil), body text, error string.
function Api:_request(method, path, body, sink)
    local headers = {
        ["Accept-Encoding"] = "identity",
        ["Accept"] = "application/json",
        ["User-Agent"] = "shelfsync.koplugin (" .. socketutil.USER_AGENT .. ")",
    }
    if self.token then
        headers["Authorization"] = "Bearer " .. self.token
    end
    local source
    if body ~= nil then
        local encoded = json.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#encoded)
        source = ltn12.source.string(encoded)
    end
    local chunks = {}
    local ok, code = pcall(function()
        local r, c = http.request {
            url = self.base .. path,
            method = method,
            headers = headers,
            source = source,
            sink = sink or ltn12.sink.table(chunks),
        }
        if not r then return c end -- c is an error string here
        return c
    end)
    if not ok then
        return nil, nil, tostring(code)
    end
    if type(code) ~= "number" then
        return nil, nil, tostring(code)
    end
    return code, table.concat(chunks), nil
end

function Api:ping()
    socketutil:set_timeout(5, 10)
    local code, _, err = self:_request("GET", "/api/v1/healthcheck")
    socketutil:reset_timeout()
    return code == 200, err or (code and ("HTTP " .. code))
end

function Api:login(username, password)
    socketutil:set_timeout(10, 30)
    local code, text, err = self:_request("POST", "/api/v1/auth/login",
        { username = username, password = password })
    socketutil:reset_timeout()
    if code ~= 200 then
        local body = decode(text)
        local msg = type(body) == "table" and (body.message or body.error)
        return false, msg or err or ("login failed (HTTP " .. tostring(code) .. ")")
    end
    local body = decode(text)
    local token = type(body) == "table" and body.accessToken
    if type(token) ~= "string" or token == "" then
        return false, "login response had no token"
    end
    self.token = token
    return true
end

function Api:_getJson(path)
    socketutil:set_timeout(15, 60)
    local code, text, err = self:_request("GET", path)
    socketutil:reset_timeout()
    if code ~= 200 then
        return nil, err or ("HTTP " .. tostring(code) .. " for " .. path)
    end
    local body = decode(text)
    if body == nil then
        return nil, "could not parse response for " .. path
    end
    return body
end

function Api:shelves()
    local body, err = self:_getJson("/api/v1/shelves")
    if not body then return nil, err end
    local list = {}
    for _, s in ipairs(body) do
        if type(s) == "table" and s.id then
            list[#list + 1] = { id = s.id, name = s.name or ("Shelf " .. tostring(s.id)) }
        end
    end
    return list
end

function Api:shelfBooks(shelf_id)
    local body, err = self:_getJson("/api/v1/shelves/" .. tostring(tonumber(shelf_id)) .. "/books")
    if not body then return nil, err end
    if type(body) ~= "table" then return nil, "unexpected shelf response" end
    return body
end

-- Streams a book to dest_path. Returns ok, err, bytes_written.
function Api:download(book_id, dest_path)
    local fh, open_err = io.open(dest_path, "wb")
    if not fh then return false, "cannot write " .. dest_path .. ": " .. tostring(open_err) end
    -- Long block timeout for slow links (Tailscale relays); no total cap.
    socketutil:set_timeout(30, -1)
    local code, _, err = self:_request("GET",
        "/api/v1/books/" .. tostring(tonumber(book_id)) .. "/download", nil, ltn12.sink.file(fh))
    socketutil:reset_timeout()
    -- ltn12.sink.file closes the handle at end of stream.
    if code ~= 200 then
        pcall(fh.close, fh) -- may already be closed by the sink
        os.remove(dest_path)
        return false, err or ("HTTP " .. tostring(code))
    end
    local check = io.open(dest_path, "rb")
    local size = 0
    if check then
        size = check:seek("end") or 0
        check:close()
    end
    return true, nil, size
end

return Api
