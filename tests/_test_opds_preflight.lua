package.path = "./?.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq
local cached = {}
package.loaded["lib/bookshelf_opds_window"] = {load=function(_,url) return cached[url] or {fetched_at=0,count=0} end}
local P = require("lib/bookshelf_opds_preflight")
local nav = {is_opds_nav=true,opds={feed_url="http://host/news"}}
local src = assert(io.open("lib/bookshelf_widget.lua")):read("*a")
local body = assert(src:match("\nfunction BookshelfWidget:_opdsResolveBeforePaint%(items%)\n(.-)\nend\n"))
local function rig(opts)
    opts = opts or {}
    P.reset(); cached = {}
    local log = {fetches=0, paints={}, stored=0, requests={}, ticks={}}
    local bw = { _page_items={opds_preflight=P.pending("srv",{nav})} }
    local class = {live=bw}
    local UI = {
        nextTick=function(_,fn) log.ticks[#log.ticks+1]=fn end,
        scheduleIn=function(_,_,fn) log.ticks[#log.ticks+1]=fn end,
        setDirty=function() end,
    }
    function bw:_opdsFetchBusy() return opts.busy end
    function bw:_rebuild()
        local pending = P.pending("srv",{nav})
        if #pending > 0 then self._page_items={opds_preflight=pending}
        else
            self._page_items={}
            log.paints[#log.paints+1]=cached[nav.opds.feed_url] and "article" or "folder"
        end
    end
    function bw:_opdsEnsureCovers() log.covers=true end
    local modules = {
        ["lib/bookshelf_opds_preflight"] = P,
        ["ui/network/manager"] = {isConnected=function() return not opts.offline end},
        ["lib/bookshelf_opds_source"] = {getServer=function() return {url="http://host/",username="u",password="p"} end},
        ["lib/bookshelf_opds_feed"] = {
            sameOrigin=function(_,url) return url:find("http://host/",1,true)==1 end,
            fetch=function(url,user,password)
                log.fetches=log.fetches+1
                log.requests[#log.requests+1]={user=user,password=password}
                eq(#log.paints,0,"no folder or partial page may paint during resolution")
                if opts.failed then return nil end
                return "feed"
            end,
        },
        ["ui/trapper"] = {
            wrap=function(_,fn) fn() end,
            clear=function() end,
            dismissableRunInSubprocess=function(_,fn)
                if opts.cancelled then return false end
                return true,fn()
            end,
        },
    }
    local env = setmetatable({
        BookshelfWidget=class, UIManager=UI, _=function(s) return s end,
        require=function(name) return assert(modules[name],name) end,
        _storeChildFeed=function(_,url,content)
            assert(content=="feed")
            cached[url]={fetched_at=1,count=1}
            log.stored=log.stored+1
        end,
    },{__index=_G})
    local chunk = assert(loadstring("return function(self,items)\n"..body.."\nend"))
    setfenv(chunk,env)
    bw._opdsResolveBeforePaint=chunk()
    function log.tick()
        local fn=table.remove(log.ticks,1); assert(fn,"no scheduled callback");fn()
    end
    bw:_opdsResolveBeforePaint(bw._page_items.opds_preflight)
    return bw,log,class
end

t.test("first non-loading paint is the article",function()
    local bw,log=rig()
    eq(#log.paints,0)
    log.tick()
    eq(log.paints,{"article"});eq(log.fetches,1);eq(log.stored,1)
    eq(bw._opds_download_started_at,nil)
end)
t.test("offline, failed, or cancelled resolution releases a stable fallback",function()
    for _,opts in ipairs({{offline=true},{failed=true},{cancelled=true}}) do
        local bw,log=rig(opts);log.tick()
        eq(log.paints,{"folder"});eq(log.stored,0)
        eq(#P.pending("srv",{nav}),0,"passive repaint must not retry")
        P.reset();eq(#P.pending("srv",{nav}),1,"next navigation can retry")
    end
end)
t.test("an intermediate loading rebuild does not strand the job",function()
    local bw,log=rig()
    bw._page_items={opds_preflight=P.pending("srv",{nav})}
    log.tick();eq(log.paints,{"article"})
end)
t.test("navigation away discards a queued resolution",function()
    local bw,log=rig();bw._page_items={}
    log.tick();eq(log.fetches,0);eq(#log.paints,0)
    local _,nextlog,class=rig();class.live=nil
    nextlog.tick();eq(nextlog.fetches,0)
end)
t.test("another active transfer queues without racing Trapper",function()
    local opts={busy=true}
    local bw,log=rig(opts)
    log.tick();eq(log.fetches,0)
    opts.busy=false;log.tick();log.tick()
    eq(log.paints,{"article"})
end)
t.test("off-origin child does not receive catalog credentials",function()
    local bw,log=rig()
    bw._page_items.opds_preflight[1].feed_url="http://other/news"
    log.tick();eq(log.requests[1].user,nil);eq(log.requests[1].password,nil)
end)
t.test("known multi-item folders, cached children, and duplicate links need no extra requests",function()
    P.reset();cached={}
    eq(#P.pending("srv",{nav,nav}),1)
    local many={is_opds_nav=true,nav_item_count=2,opds=nav.opds}
    eq(#P.pending("srv",{many}),0)
    cached[nav.opds.feed_url]={fetched_at=1,count=1}
    eq(#P.pending("srv",{nav}),0)
end)
t.done()
