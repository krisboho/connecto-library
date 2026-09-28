--[[
Test driver for Shelf Sync (harness only, never installed on a device).

Env:
  SHELFSYNC_TEST_EVENT  "Resume" (default) or "NetworkConnected"
  SHELFSYNC_TEST_OPEN   optional path of a book to open in the reader first
Prints "SHELFSYNC_TEST_RESULT: <last_result>" then quits KOReader.
]]
local DataStorage = require("datastorage")
local Event = require("ui/event")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local fired = false

local Test = WidgetContainer:extend{ name = "shelfsynctest", is_doc_only = false }

local function out(line)
    io.stdout:write(line .. "\n")
    io.stdout:flush()
end

local function readSettings()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/shelfsync.lua")
end

local function fire()
    local event = os.getenv("SHELFSYNC_TEST_EVENT") or "Resume"
    local t0 = os.time()
    out("SHELFSYNC_TEST_FIRE: " .. event)
    UIManager:broadcastEvent(Event:new(event))
    local deadline = t0 + 120
    local poll
    poll = function()
        local s = readSettings()
        local finished = s:readSetting("last_finished") or 0
        if finished >= t0 then
            out("SHELFSYNC_TEST_RESULT: " .. tostring(s:readSetting("last_result")))
            -- Close an open book the normal way so KOReader writes its .sdr sidecar.
            local ReaderUI = require("apps/reader/readerui")
            if ReaderUI.instance then ReaderUI.instance:onClose() end
            UIManager:scheduleIn(2, function() UIManager:quit() end)
        elseif os.time() > deadline then
            out("SHELFSYNC_TEST_RESULT: TIMEOUT")
            UIManager:quit()
        else
            UIManager:scheduleIn(1, poll)
        end
    end
    UIManager:scheduleIn(1, poll)
end

function Test:init()
    if fired then return end
    fired = true
    UIManager:scheduleIn(2, function()
        local open = os.getenv("SHELFSYNC_TEST_OPEN")
        if open and open ~= "" then
            out("SHELFSYNC_TEST_OPEN: " .. open)
            require("apps/reader/readerui"):showReader(open)
            UIManager:scheduleIn(6, fire)
        else
            fire()
        end
    end)
end

return Test
