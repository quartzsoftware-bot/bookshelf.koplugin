-- Cache-only readiness gate. Never publish unresolved folder tiles that might
-- become books; the widget resolves these feeds before releasing the page.
local M = {}
local attempted = {}
local function key(server, url) return server .. "\n" .. url end

function M.reset()
    attempted = {}
end

function M.settle(items)
    for _, item in ipairs(items) do
        attempted[key(item.server_key, item.feed_url)] = true
    end
end

function M.pending(server, records, windowOf)
    local Window = require("lib/bookshelf_opds_window")
    local pending, seen = {}, {}
    for _, rec in ipairs(records) do
        local url = rec.is_opds_nav and rec.opds and rec.opds.feed_url
        local count = tonumber(rec.nav_item_count)
        if url and (not count or count <= 1) and not seen[url]
                and not attempted[key(server, url)] then
            seen[url] = true
            local win = windowOf and windowOf(url) or Window.load(server, url)
            if not win or ((win.fetched_at or 0) <= 0 and (win.count or 0) == 0
                    and not (win.entries and #win.entries > 0)) then
                pending[#pending + 1] = {server_key=server, feed_url=url}
            end
        end
    end
    return pending
end

return M
