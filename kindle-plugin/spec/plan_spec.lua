-- Run from kindle-plugin/:  luajit spec/plan_spec.lua
package.path = "shelfsync.koplugin/?.lua;" .. package.path
local Plan = require("shelfsync/plan")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function book(id, name, file_id, kb, extra)
    local pf = { id = file_id or id * 10, fileName = name, fileSizeKb = kb or 100 }
    for k, v in pairs(extra or {}) do pf[k] = v end
    return { id = id, primaryFile = pf }
end

local function existsIn(set)
    return function(p) return set[p] == true end
end

test("safeName strips path and reserved characters", function()
    eq(Plan.safeName('a/b:c*?"<>|.EPUB', 1), "a_b_c______.epub")
    eq(Plan.safeName("  .hidden.epub", 1), "hidden.epub")
    eq(Plan.safeName(".epub", 7), "book-7.epub")
    eq(Plan.safeName(nil, 9), "book-9")
end)

test("utf8Truncate never splits a multibyte character", function()
    local s = string.rep("é", 100) -- 200 bytes
    local t = Plan.utf8Truncate(s, 181)
    eq(#t, 180)
    eq(t:sub(-2), "é")
end)

test("desired filters formats and folder-based books", function()
    local d = Plan.desired({
        book(1, "A.epub"), book(2, "B.m4b"), book(3, "C.pdf"),
        book(4, "D.epub", nil, nil, { folderBased = true }),
        { id = 5 }, -- no primary file
    })
    eq(d["1"].name, "A.epub"); eq(d["2"], nil); eq(d["3"].name, "C.pdf"); eq(d["4"], nil); eq(d["5"], nil)
end)

test("desired disambiguates colliding names case-insensitively", function()
    local d = Plan.desired({ book(1, "Same.epub"), book(2, "same.EPUB") })
    eq(d["1"].name, "Same.epub")
    eq(d["2"].name, "same [2].epub")
end)

test("compute: new books download, removed books delete", function()
    local desired = Plan.desired({ book(1, "A.epub"), book(2, "B.epub") })
    local manifest = { ["2"] = { path = "/d/B.epub", file_id = 20 }, ["3"] = { path = "/d/C.epub", file_id = 30 } }
    local r = Plan.compute(desired, manifest, "/d", existsIn({ ["/d/B.epub"] = true, ["/d/C.epub"] = true }))
    eq(#r.download, 1); eq(r.download[1].id, "1"); eq(r.download[1].path, "/d/A.epub")
    eq(#r.delete, 1); eq(r.delete[1].id, "3")
end)

test("compute: missing local file is re-fetched to the same path", function()
    local desired = Plan.desired({ book(2, "B.epub") })
    local manifest = { ["2"] = { path = "/d/Old name.epub", file_id = 20 } }
    local r = Plan.compute(desired, manifest, "/d", existsIn({}))
    eq(#r.download, 1); eq(r.download[1].path, "/d/Old name.epub"); eq(r.download[1].replaces, nil)
end)

test("compute: replaced server file downloads and marks old path", function()
    local desired = Plan.desired({ book(2, "B v2.epub", 99) })
    local manifest = { ["2"] = { path = "/d/B.epub", file_id = 20 } }
    local r = Plan.compute(desired, manifest, "/d", existsIn({ ["/d/B.epub"] = true }))
    eq(#r.download, 1); eq(r.download[1].path, "/d/B v2.epub"); eq(r.download[1].replaces, "/d/B.epub")
end)

test("compute: never overwrites a user's own file with the same name", function()
    local desired = Plan.desired({ book(1, "A.epub") })
    local r = Plan.compute(desired, {}, "/d", existsIn({ ["/d/A.epub"] = true }))
    eq(r.download[1].path, "/d/A [1].epub")
end)

test("compute: the open book is never deleted or replaced", function()
    local desired = Plan.desired({ book(2, "B v2.epub", 99) })
    local manifest = {
        ["2"] = { path = "/d/B.epub", file_id = 20 },
        ["3"] = { path = "/d/C.epub", file_id = 30 },
    }
    local ex = existsIn({ ["/d/B.epub"] = true, ["/d/C.epub"] = true })
    local r = Plan.compute(desired, manifest, "/d", ex, "/d/B.epub")
    eq(#r.download, 0, "replacement of open book deferred")
    local r2 = Plan.compute(desired, manifest, "/d", ex, "/d/C.epub")
    eq(#r2.delete, 0, "open book not deleted"); eq(#r2.deferred, 1)
end)

test("compute: up-to-date books are left alone", function()
    local desired = Plan.desired({ book(1, "A.epub") })
    local manifest = { ["1"] = { path = "/d/A.epub", file_id = 10 } }
    local r = Plan.compute(desired, manifest, "/d", existsIn({ ["/d/A.epub"] = true }))
    eq(#r.download, 0); eq(#r.delete, 0)
end)

test("sizeOk tolerates KiB rounding but rejects truncation", function()
    eq(Plan.sizeOk(102400, 100), true)
    eq(Plan.sizeOk(102400 + 1023, 100), true)
    eq(Plan.sizeOk(50000, 100), false)
    eq(Plan.sizeOk(0, 100), false)
    eq(Plan.sizeOk(1234, nil), true)
end)

test("isMassDelete only trips on big, majority removals", function()
    eq(Plan.isMassDelete(5, 6), false)
    eq(Plan.isMassDelete(11, 20), true)
    eq(Plan.isMassDelete(11, 100), false)
end)

test("isPrivateHost: LAN yes, Tailscale and public no", function()
    eq(Plan.isPrivateHost("http://192.168.0.9:6060"), true)
    eq(Plan.isPrivateHost("http://10.1.2.3"), true)
    eq(Plan.isPrivateHost("http://172.20.0.5:6060"), true)
    eq(Plan.isPrivateHost("http://grimmory:6060"), true)
    eq(Plan.isPrivateHost("http://nas.local:6060"), true)
    eq(Plan.isPrivateHost("http://100.95.26.46:6060"), false)
    eq(Plan.isPrivateHost("https://grimmory.example.com"), false)
    eq(Plan.isPrivateHost("http://172.32.0.1"), false)
    eq(Plan.isPrivateHost(nil), false)
end)

test("routes: LAN direct first, Tailscale via proxy first, no proxy means direct only", function()
    local r = Plan.routes({ "http://192.168.0.9:6060", "http://100.95.26.46:6060" }, "http://127.0.0.1:1056")
    eq(#r, 4)
    eq(r[1].url, "http://192.168.0.9:6060"); eq(r[1].proxy, nil)
    eq(r[2].url, "http://192.168.0.9:6060"); eq(r[2].proxy, "http://127.0.0.1:1056")
    eq(r[3].url, "http://100.95.26.46:6060"); eq(r[3].proxy, "http://127.0.0.1:1056")
    eq(r[4].url, "http://100.95.26.46:6060"); eq(r[4].proxy, nil)
    local d = Plan.routes({ "http://192.168.0.9:6060", "", "http://100.95.26.46:6060" }, nil)
    eq(#d, 2); eq(d[1].proxy, nil); eq(d[2].proxy, nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
