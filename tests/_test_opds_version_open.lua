-- tests/_test_opds_download_refresh.lua
-- The shelf refresh that follows a completed OPDS download.
--
-- Regression guard for the missing downloaded tick (device report, PW5): the
-- refresh used to hang off the "Read it now?" box's cancel_callback, so the
-- "Read" answer parked a shelf whose page records predated the download. The
-- way back from the reader is main.lua's _raiseInPlace, which reorders the
-- window stack and repaints -- it never re-fetches -- so the cell the user had
-- just downloaded showed no tick for the rest of the visit.
--
-- What is asserted: _opdsRunDownload rebuilds the shelf ONCE, BEFORE the prompt
-- is shown, and neither answer to the prompt adds or removes a rebuild.
--
-- Usage (from plugin root): lua tests/_test_opds_download_refresh.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ── Minimal class system ───────────────────────────────────────────────────
local function make_widget_class()
    local cls = {}
    cls.__index = cls
    function cls:extend(props)
        local sub = props or {}
        sub.__index = sub
        setmetatable(sub, { __index = cls })
        return sub
    end
    return cls
end

-- ── Recorders the stubs write into ─────────────────────────────────────────
local log = {}
local function note(what) log[#log + 1] = what end
local shown = {}   -- every widget handed to UIManager:show

-- ── KOReader stubs ─────────────────────────────────────────────────────────
local widget_cls = make_widget_class()
package.loaded["ui/widget/container/inputcontainer"]  = widget_cls
package.loaded["ui/widget/container/framecontainer"]  = make_widget_class()
package.loaded["ui/widget/container/centercontainer"] = make_widget_class()
package.loaded["ui/widget/verticalgroup"]             = make_widget_class()
package.loaded["ui/widget/horizontalgroup"]           = make_widget_class()
package.loaded["ui/widget/textwidget"]                = make_widget_class()
package.loaded["ui/widget/textboxwidget"]             = make_widget_class()
package.loaded["ui/widget/verticalspan"]              = make_widget_class()
package.loaded["ui/geometry"]     = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
package.loaded["ui/size"] = {
    padding = { default = 4, large = 8, fullscreen = 16 },
    item    = { height_default = 30 },
    border  = { thin = 1 },
    line    = { medium = 1 },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/uimanager"] = {
    setDirty       = function() note("setDirty") end,
    close          = function() note("close") end,
    show           = function(_, w) note("show"); shown[#shown + 1] = w end,
    nextTick       = function(_, fn) if fn then fn() end end,
    scheduleIn     = function() end,
    unschedule     = function() end,
    isWidgetShown  = function() return false end,
}
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 0xFF,
                                     gray = function(v) return v end }
package.loaded["device"] = {
    screen = {
        getWidth    = function() return 1236 end,
        getHeight   = function() return 1648 end,
        scaleBySize = function(_, n) return n end,
    },
    isKindle = function() return false end,
}
package.loaded["logger"] = { dbg = function() end, warn = function() end,
                             err = function() end, info = function() end }
package.loaded["lib/bookshelf_settings_store"] = {
    read      = function(_, default) return default end,
    save      = function() note("settings_save") end,
    delete    = function() end,
    flush     = function() end,
    isTrue    = function() return false end,
    nilOrTrue = function() return true end,
}
package.loaded["lib/bookshelf_i18n"] = {
    gettext  = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["lib/bookshelf_book_repository"] = {
    invalidateWalkCache = function() note("invalidateWalkCache") end,
}
package.loaded["lib/bookshelf_hero_card"] = {
    new = function() return {} end,
    buildStatusRow = function() return nil end,
}
package.loaded["lib/bookshelf_chip_bar"]  = { new = function() return {} end }
package.loaded["lib/bookshelf_shelf_row"] = {}
-- Stubbed rather than loaded: bookshelf_cover_progress opens the real
-- ffi.typeof("ColorRGB32") at load, which only resolves inside KOReader (the
-- cdef lives in its blitbuffer). Loading it here would make this suite a
-- luajit-only failure, which is exactly the shape _test_collection_sort.lua
-- already has. Nothing on the download tail reads from it.
package.loaded["lib/bookshelf_cover_progress"] = {
    decide          = function() return { bar = false, bar_pct = 0, glyph = nil } end,
    resolvedColors  = function() return {} end,
    badgeSize       = function(n) return n end,
    glyphRenderedH  = function() return 0 end,
}
-- Same reason (it opens the ffi type too, at lib/bookshelf_spine_widget.lua's
-- top). The download tail never builds a cover.
package.loaded["lib/bookshelf_spine_widget"] = {
    new                 = function() return {} end,
    setDraftMode        = function() end,
    trueAspectBoxHeight = function(_w, _b, max_h) return max_h end,
    downloadedTickOffset = function() return 0, 0 end,
}

-- Modules _opdsRunDownload requires at CALL time. Each is the smallest thing
-- that lets the success path run to the prompt.
package.loaded["lib/bookshelf_opds_download"] = {
    STORE_KEY = "opds_downloads",
    download  = function(_url, dest) note("download"); return dest end,
    pruneMap  = function(map) return map, 0 end,
}
package.loaded["lib/bookshelf_opds_source"] = {
    getServer = function() return { url = "http://host/", title = "T" } end,
    serverKey = function() return "deadbeef" end,
}
package.loaded["lib/bookshelf_opds_feed"] = {
    sameOrigin = function() return true end,
}
package.loaded["lib/bookshelf_cover_fetch"] = {
    runWhenOnline = function(fn) fn() end,
}
package.loaded["ui/trapper"] = {
    wrap  = function(_, fn) fn() end,
    info  = function() return true end,
    clear = function() end,
    -- The transfer runs in a dismissable subprocess since issue #377;
    -- under stubs it just runs inline and reports completion.
    dismissableRunInSubprocess = function(_, task, _widget)
        return true, task()
    end,
}
package.loaded["ui/widget/confirmbox"] = {
    new = function(_, spec) spec.is_confirmbox = true; return spec end,
}
package.loaded["ui/widget/notification"] = { new = function(_, s) return s end }
package.loaded["ui/widget/infomessage"]  = { new = function(_, s) return s end }

_G.G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() end,
    isTrue      = function() return false end,
    flush       = function() end,
}

-- Benign mock for every KOReader core dep the widget pulls in at load time but
-- this path never reads a real value from (same fallback the tall-screen
-- suite installs, and for the same reason).
local function mock()
    local m = {}
    return setmetatable(m, {
        __index = function() return function() return mock() end end,
        __call  = function() return mock() end,
    })
end
table.insert(package.searchers or package.loaders, function(_name)
    return function() return mock() end
end)

local BW = dofile("lib/bookshelf_widget.lua")

local t = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local state, online, opened, updated, checked, selected
local acq = { href = "http://host/book", type = "application/pdf" }
package.loaded["lib/bookshelf_opds_version"] = {
    STORE_KEY = "opds_verified_versions",
    acquisition = function() return selected end,
    check = function() checked = checked + 1; return state end,
}
package.loaded["ui/network/manager"] = { isConnected = function() return online end }
local function run(value, connected)
    state, online, opened, updated, checked, selected = value, connected, 0, 0, 0, acq
    shown = {}
    local s = setmetatable({}, {__index = BW})
    s._opdsDownloadedPath = function() return "/books/test.pdf" end
    s._launchReader = function() opened = opened + 1 end
    s._opdsRunDownload = function(_, _, a, dest)
        eq(a, acq); eq(dest, "/books/test.pdf"); updated = updated + 1
    end
    s._opdsFetchBusy = function() return false end
    BW.live = s
    s:_opdsOpenBook({filepath="OPDS://deadbeef/book"})
    return s
end
t.test("matching copy opens directly with no download prompt", function()
    run("same", true); eq(opened, 1); eq(#shown, 0); eq(checked, 1)
end)
t.test("changed copy offers update or local reading", function()
    run("different", true); eq(opened, 0); eq(#shown, 1)
    shown[1].cancel_callback(); eq(opened, 1); eq(updated, 0)
    run("different", true); shown[1].ok_callback(); eq(updated, 1); eq(opened, 0)
end)
t.test("offline and failed checks open local without a prompt", function()
    run("different", false); eq(opened, 1); eq(#shown, 0); eq(checked, 0)
    run("unknown", true); eq(opened, 1); eq(#shown, 0)
end)
t.test("cancelled check opens local copy", function()
    local trap = package.loaded["ui/trapper"]
    local real = trap.dismissableRunInSubprocess
    trap.dismissableRunInSubprocess = function() return false end
    run("different", true); eq(opened, 1); eq(#shown, 0)
    trap.dismissableRunInSubprocess = real
end)
t.done()
