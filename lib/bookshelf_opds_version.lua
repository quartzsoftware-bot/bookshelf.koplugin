-- Verify the acquisition itself, not an OPDS entry's metadata timestamp.
-- A first comparison streams bytes without replacing or buffering the book.
local M = { STORE_KEY = "opds_verified_versions" }

function M.acquisition(book, path)
    local ext = path:match("%.([^.]+)$")
    local types = require("lib/bookshelf_opds_feed").TYPE_EXT
    local selected
    for _, acq in ipairs(book.opds and book.opds.acquisitions or {}) do
        if ext and types[acq.type] == ext:lower() then
            if selected then return nil end -- ambiguous editions: do not guess
            selected = acq
        end
    end
    return selected
end

local function strongETag(headers)
    local tag = headers and headers.etag
    if type(tag) == "string" and tag:match('^".*"$') then return tag end
end

-- Calibre regenerates this XMP export timestamp on every PDF acquisition.
-- Ignore only that timestamp; all book content and other metadata still compare.
local function normalizePDF(bytes)
    return (bytes:gsub("(<xmp:MetadataDate>)[^<]*(</xmp:MetadataDate>)", function(a, b)
        return a .. b
    end))
end

function M.comparator(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local pdf = path:lower():match("%.pdf$")
    local left, right, equal = "", "", true
    return function(chunk)
        if chunk then
            if not equal then return 1 end
            local data = file:read(#chunk) or ""
            if #data ~= #chunk then equal = false; return 1 end
            left, right = left .. data, right .. chunk
            -- Keep a complete tag if it straddles the comparison boundary.
            local cut = math.max(0, math.min(#left, #right) - 256)
            if pdf then
                for _, value in ipairs({left, right}) do
                    local start = value:find("<xmp:MetadataDate>", 1, true)
                    if start and start <= cut then
                        local stop = value:find("</xmp:MetadataDate>", start, true)
                        if not stop or stop + 18 > cut then cut = start - 1 end
                    end
                end
            end
            local a, b = left:sub(1,cut), right:sub(1,cut)
            if pdf then a, b = normalizePDF(a), normalizePDF(b) end
            if a ~= b then equal = false end
            left, right = left:sub(cut+1), right:sub(cut+1)
            if not equal then left, right = "", "" end
        end
        return 1
    end, function()
        local tail = file:read(1)
        file:close()
        if pdf then left, right = normalizePDF(left), normalizePDF(right) end
        return equal and left == right and not tail
    end
end

-- ZIP container timestamps/compression are not ebook content. Compare EPUB
-- members by name and decompressed bytes; bound memory on constrained readers.
function M.sameEPUB(left, right)
    local ok, result = pcall(function()
        local Reader = require("ffi/archiver").Reader
        local a, b = Reader:new(), Reader:new()
        local success, equal = pcall(function()
            if not a:open(left) or not b:open(right) then return nil end
            local names, count = {}, 0
            for entry in a:iterate() do
                if entry.mode == "file" then
                    if names[entry.path] or entry.size > 32 * 1024 * 1024 then return nil end
                    names[entry.path] = entry.size
                    count = count + 1
                end
            end
            if a.err then return nil end
            for entry in b:iterate() do
                if entry.mode == "file" then
                    if names[entry.path] ~= entry.size then return false end
                    local x, y = a:extractToMemory(entry.path), b:extractToMemory(entry.path)
                    if not x or not y then return nil end
                    if x ~= y then return false end
                    names[entry.path] = nil
                    count = count - 1
                end
            end
            if b.err then return nil end
            return count == 0
        end)
        a:close(); b:close()
        if success then return equal end
    end)
    if ok then return result end
end

function M.check(url, path, user, password, cached, identity)
    local http = require("socket.http")
    local socketutil = require("socketutil")
    local lfs = require("libs/libkoreader-lfs")
    local before = lfs.attributes(path)
    if not before or before.mode ~= "file" then return "unknown" end
    local function request(method, sink, target)
        local started = os.time()
        local guarded = function(chunk, err)
            if os.time() - started > 60 then return nil, "timeout" end
            return sink(chunk, err)
        end
        local ok, received, code, headers = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            return http.request{
                url = target or url, method = method, sink = guarded,
                headers = { ["Accept-Encoding"] = "identity", ["Cache-Control"] = "no-cache" },
                -- Fail closed on redirects; never forward catalog credentials.
                redirect = false, user = user, password = password,
            }
        end)
        pcall(function() socketutil:reset_timeout() end)
        if ok and received and tonumber(code) == 200 then return headers or {} end
    end
    -- Calibre-Web's authenticated metadata endpoint gives a stable revision even
    -- when its metadata embedder regenerates the file and HTTP ETag per request.
    local root, book_id, format = url:match("^(https?://.-)/opds/download/(%d+)/([%w]+)/?$")
    local uuid = type(identity) == "string" and identity:match("/urn:uuid:([%x%-]+)$")
    local function revision()
        if not root or not uuid or #uuid ~= 36 then return nil end
        local parts, size = {}, 0
        local h = request("GET", function(chunk)
            if chunk then
                size = size + #chunk
                if size > 262144 then return nil, "metadata too large" end
                parts[#parts+1] = chunk
            end
            return 1
        end, root .. "/ajax/book/" .. uuid)
        if not h then return nil end
        local ok, data = pcall(function() return require("rapidjson").decode(table.concat(parts)) end)
        if not ok or type(data) ~= "table" or data.uuid ~= uuid
            or tonumber(data.application_id) ~= tonumber(book_id) then return nil end
        local f = data.format_metadata and data.format_metadata[format:upper()]
        if type(f) ~= "table" or type(f.mtime) ~= "string" or type(f.size) ~= "number" then return nil end
        return f.mtime .. ":" .. tostring(f.size)
    end
    local rev = revision()
    if rev and cached and cached.url == url and cached.revision == rev
        and cached.size == before.size and cached.modification == before.modification
        and cached.change == before.change then return "same", cached end
    local head = request("HEAD", function() return 1 end)
    local etag = strongETag(head)
    if etag and cached and cached.url == url and cached.etag == etag
        and cached.size == before.size and cached.modification == before.modification
        and cached.change == before.change
        and (not head["content-length"] or tonumber(head["content-length"]) == before.size) then
        return "same", cached
    end
    local compare, finish = M.comparator(path)
    if not compare then return "unknown" end
    local count = 0
    local tmp = path .. ".bookshelf-check.tmp"
    local zipfile = path:lower():match("%.epub$") and io.open(tmp, "wb") or nil
    local headers = request("GET", function(chunk, err)
        if err then return nil, err end
        if chunk then
            count = count + #chunk
            if zipfile and not zipfile:write(chunk) then return nil, "write failed" end
            compare(chunk)
        end
        return 1
    end)
    if zipfile then zipfile:close() end
    local equal = finish()
    if zipfile then
        if headers and not equal then equal = M.sameEPUB(path, tmp) end
        os.remove(tmp)
    end
    local after = lfs.attributes(path)
    if not headers or not after or before.size ~= after.size
        or before.modification ~= after.modification or before.change ~= after.change
        or (headers["content-length"] and tonumber(headers["content-length"]) ~= count)
        or (headers["content-encoding"] and headers["content-encoding"] ~= "identity") then
        return "unknown"
    end
    -- Authentication portals and server errors sometimes answer HTTP 200.
    local content_type = (headers["content-type"] or ""):lower()
    if content_type:find("text/html", 1, true) and not path:lower():match("%.html?$") then
        return "unknown"
    end
    if equal == nil then return "unknown" end
    if not equal then return "different" end
    if rev and revision() ~= rev then return "unknown" end
    return "same", { url = url, etag = strongETag(headers), revision = rev, size = after.size,
        modification = after.modification, change = after.change }
end

return M
