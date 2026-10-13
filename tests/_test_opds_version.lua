package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local path = os.tmpname()
local function write(body)
    local f = assert(io.open(path, "wb")); f:write(body); f:close()
end
local stat = { mode = "file", size = 4, modification = 10, change = 10 }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return stat end }
package.loaded.socketutil = { set_timeout = function() end, reset_timeout = function() end }
local body, code, headers, requests, broken
local function reset()
    write("book")
    body, code, headers, requests, broken = "book", 200,
        { etag = '"one"', ["content-length"] = "4", ["content-type"] = "application/pdf" }, {}, false
end
package.loaded["socket.http"] = { request = function(req)
    requests[#requests + 1] = req
    assert(req.redirect == false)
    if broken then error("offline") end
    if req.method == "GET" then
        req.sink(body:sub(1, 2)); req.sink(body:sub(3)); req.sink(nil)
    end
    return 1, code, headers
end }
local V = require("lib/bookshelf_opds_version")
t.test("existing matching copy is verified byte for byte", function()
    reset(); local state, cache = V.check("http://host/book", path)
    eq(state, "same"); eq(cache.etag, '"one"'); eq(#requests, 2)
    eq(V.check("http://host/book", path, nil, nil, cache), "same")
    eq(#requests, 3) -- subsequent open uses only HEAD
end)
t.test("same-size updated server book differs", function()
    reset(); body = "next"; eq(V.check("http://host/book", path), "different")
end)
t.test("metadata-only ETag change does not prompt", function()
    reset(); local _, cache = V.check("http://host/book", path)
    headers.etag = '"two"'; eq(V.check("http://host/book", path, nil, nil, cache), "same")
    eq(#requests, 4)
end)
t.test("local file modification invalidates saved proof", function()
    reset(); local _, cache = V.check("http://host/book", path)
    stat.modification = 11; write("edit")
    eq(V.check("http://host/book", path, nil, nil, cache), "different")
end)
t.test("weak or absent validators require content comparison", function()
    for _, tag in ipairs({ 'W/"one"', false }) do
        reset(); headers.etag = tag or nil
        local _, cache = V.check("http://host/book", path)
        eq(V.check("http://host/book", path, nil, nil, cache), "same"); eq(#requests, 4)
    end
end)
t.test("network, auth, redirect and truncated responses are unknown", function()
    for _, status in ipairs({ 401, 403, 302, 404, 500 }) do
        reset(); code = status; eq(V.check("http://host/book", path), "unknown")
    end
    reset(); broken = true; eq(V.check("http://host/book", path), "unknown")
    reset(); body = "bo"; eq(V.check("http://host/book", path), "unknown")
    reset(); headers["content-type"] = "text/html"; eq(V.check("http://host/book", path), "unknown")
end)
t.test("cache belongs to exact acquisition URL", function()
    reset(); local _, cache = V.check("http://host/book", path)
    body = "next"
    eq(V.check("http://other/book", path, nil, nil, cache), "different")
end)
t.test("format choice never guesses between two editions", function()
    local pdf = {type="application/pdf",href="http://host/a"}
    local epub = {type="application/epub+zip",href="http://host/b"}
    eq(V.acquisition({opds={acquisitions={pdf,epub}}},"book.pdf"), pdf)
    eq(V.acquisition({opds={acquisitions={pdf,pdf}}},"book.pdf"), nil)
end)
t.test("PDF export dates are ignored across network chunk boundaries", function()
    local pdf = path .. ".pdf"
    local function bytes(date, content)
        return string.rep("a", 2040) .. "<xmp:MetadataDate>" .. date .. "</xmp:MetadataDate>" .. content .. string.rep("b", 2048)
    end
    local f = assert(io.open(pdf,"wb")); f:write(bytes("2026-10-12T10:20:30.123456", "page one")); f:close()
    local remote = bytes("2026-10-13T10:20:30.654321", "page one")
    local sink, finish = V.comparator(pdf)
    for i=1,#remote,2048 do sink(remote:sub(i,i+2047)) end
    eq(finish(), true)
    sink, finish = V.comparator(pdf)
    remote = bytes("2026-10-13T10:20:30.654321", "page two")
    for i=1,#remote,2048 do sink(remote:sub(i,i+2047)) end
    eq(finish(), false)
    os.remove(pdf)
end)
t.test("Calibre revision avoids repeated regenerated acquisitions", function()
    reset()
    local http = package.loaded["socket.http"]
    local real, gets = http.request, 0
    local uuid = "12345678-1234-1234-1234-123456789abc"
    local stamp = "2026-10-12 12:34:56"
    package.loaded.rapidjson = { decode = function()
        return { uuid=uuid, application_id=12, format_metadata={PDF={mtime=stamp,size=4}} }
    end }
    http.request = function(req)
        if req.url:find("/ajax/book/",1,true) then req.sink("metadata"); return 1,200,{} end
        if req.method == "GET" then gets = gets + 1 end
        return real(req)
    end
    local url, id = "http://host/opds/download/12/pdf/", "OPDS://key/urn:uuid:" .. uuid
    local state, cache = V.check(url,path,nil,nil,nil,id)
    eq(state,"same"); eq(gets,1)
    eq(V.check(url,path,nil,nil,cache,id),"same"); eq(gets,1)
    stamp = "2026-10-13 12:34:56"; body = "next"; headers.etag = '"next"'
    eq(V.check(url,path,nil,nil,cache,id),"different"); eq(gets,2)
    http.request = real
end)
os.remove(path)
t.done()
