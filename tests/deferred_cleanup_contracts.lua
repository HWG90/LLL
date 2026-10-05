local factory = dofile("src/manager.lua")
local function reset()
    LiveLuaLoader = nil
    CowboyBingusModLoader = nil
    HD2ModLoader = nil
end
local function host_for(record)
    local h = {
        loads = 0,
        saves = 0,
        available = function()
            return true
        end,
        report = function() end,
        can_retry = function()
            return true
        end,
        preflight = function() end,
        evict = function() end,
    }
    h.require = function()
        h.loads = h.loads + 1
        return record
    end
    h.save_enabled = function()
        h.saves = h.saves + 1
        return true
    end
    return h
end
reset()
local disables, polls, updates = 0, 0, 0
local record = {
    live_lua_api = 1,
    on_update = function()
        updates = updates + 1
    end,
    on_disable = function()
        disables = disables + 1
        return false, "pending"
    end,
    on_cleanup_poll = function(dt)
        assert(dt == 0.1)
        polls = polls + 1
        if polls == 1 then
            error("Transient cleanup failure")
        end
        return polls >= 3, "pending"
    end,
}
local h = host_for(record)
local m = factory(h, { "camera" })
local ok, why = m.set_enabled("camera", false)
assert(
    not ok
        and why == "pending"
        and m.records.camera == record
        and m.modules.camera == "cleanup pending"
        and h.saves == 0
)
assert(not m.reload("camera") and not m.retry("camera") and not m.set_enabled("camera", true))
assert(h.loads == 1 and disables == 1)
m.frame(0.1)
assert(
    m.modules.camera:find("cleanup failed", 1, true)
        and m.records.camera == record
        and m.pending_cleanup.camera
)
m.frame(0.1)
assert(m.records.camera == record and polls == 2 and updates == 0)
m.frame(0.1)
assert(
    not m.records.camera
        and not m.pending_cleanup.camera
        and m.modules.camera == "disabled"
        and h.saves == 1
)
m.frame(0.1)
assert(polls == 3 and disables == 1 and h.loads == 1, "No replacement or double cleanup")
reset()
local count = 0
record = {
    live_lua_api = 1,
    on_disable = function()
        return false, "pending"
    end,
    on_cleanup_poll = function()
        count = count + 1
        return count == 2
    end,
}
h = host_for(record)
m = factory(h, { "camera" })
assert(not m.reload("camera"))
m.frame(0.1)
assert(m.records.camera == record)
m.frame(0.1)
assert(not m.records.camera and h.loads == 1)
assert(m.retry("camera") and h.loads == 2, "Replacement permitted after completed retirement")
reset()
record = {
    live_lua_api = 1,
    on_disable = function()
        return false, "pending"
    end,
}
h = host_for(record)
m = factory(h, { "camera" })
assert(not m.reload("camera"))
m.frame(0.1)
assert(
    m.records.camera == record and m.modules.camera:find("cleanup failed", 1, true),
    "Missing poll must not release ownership"
)
reset()
record = {
    live_lua_api = 1,
    on_enable = function()
        error("Enable failed")
    end,
    on_disable = function()
        return false, "pending"
    end,
    on_cleanup_poll = function()
        return true
    end,
}
h = host_for(record)
m = factory(h, { "camera" })
assert(m.pending_cleanup.camera)
m.frame(0.1)
assert(not m.records.camera and m.modules.camera:find("enable failed", 1, true))
reset()
record = {
    live_lua_api = 1,
    on_update = function()
        error("Frame failed")
    end,
    on_disable = function()
        return false, "pending"
    end,
    on_cleanup_poll = function()
        return true
    end,
}
h = host_for(record)
m = factory(h, { "camera" })
m.frame(0.1)
assert(m.records.camera and m.pending_cleanup.camera)
m.frame(0.1)
assert(not m.records.camera and m.modules.camera:find("update failed", 1, true))
reset()
record = {
    live_lua_api = 1,
    on_disable = function()
        return false, "pending"
    end,
    on_cleanup_poll = function()
        return true
    end,
}
h = host_for(record)
m = factory(h, { "camera" })
m.shutdown()
assert(m.records.camera)
m.shutdown()
m.frame(0.1)
assert(not m.records.camera and m.modules.camera == "disabled")
reset()
record = {
    live_lua_api = 1,
    on_disable = function()
        return false, "pending"
    end,
    on_cleanup_poll = function()
        return true
    end,
}
h = host_for(record)
m = factory(h, { "camera" })
m.reload("camera")
local replacement = {}
m.records.camera = replacement
m.modules.camera = "loaded"
m.frame(0.1)
assert(
    m.records.camera == replacement and m.modules.camera == "loaded",
    "Retired queue must not clear replacement"
)
reset()
local source = [[
return {on_enable=function(ctx)ctx.global('DEFERRED_TEST_GLOBAL','owned');ctx.on_cleanup(function()_G.deferred_releases=(_G.deferred_releases or 0)+1;if _G.deferred_releases==1 then error('Cleanup release failure')end end)end,
on_disable=function()return false,'pending'end,
on_cleanup_poll=function(ctx,dt)_G.deferred_polls=(_G.deferred_polls or 0)+1;return _G.deferred_polls>=2 end}
]]
local p = {
    roots = { { kind = "lll", path = "root" } },
    read = function(path)
        if path == "root/camera.lua" then
            return source
        end
    end,
    files = function()
        return { "camera.lua" }
    end,
    write = function()
        return true
    end,
}
local live = dofile("src/live.lua")(p, function() end)
live.scan()
DEFERRED_TEST_GLOBAL = "prior"
local r = live.load("live/camera")
r.on_enable()
assert(r.on_disable() == false and DEFERRED_TEST_GLOBAL == "owned")
assert(r.on_cleanup_poll(0.1) == false and DEFERRED_TEST_GLOBAL == "owned")
assert(not pcall(r.on_cleanup_poll, 0.1) and DEFERRED_TEST_GLOBAL == "owned")
assert(r.on_cleanup_poll(0.1) == true and DEFERRED_TEST_GLOBAL == "prior")
DEFERRED_TEST_GLOBAL = nil
deferred_releases = nil
deferred_polls = nil
reset()
print(
    "PASS deferred cleanup: pending/failure ownership, retries, explicit acknowledgement, blocked reload/enable, delayed persistence, shutdown, stale records and MDL globals"
)

reset()
mock_config = nil
new_live_source = nil
local old_require = require
local old_update = update
local old_shutdown = shutdown
local old_sr = stingray
stingray = { Application = {
    can_get = function()
        return false
    end,
} }
shutdown = function()
    return "bye"
end
local prior = function()
    return "prior", nil, 7, nil
end
update = prior
live_source = [[
return {live_lua_api=1,on_enable=function()_G.deferred_owned=true end,on_disable=function()return false,'pending'end,
on_cleanup_poll=function(dt)_G.deferred_count=(_G.deferred_count or 0)+1;if _G.deferred_count>=2 then _G.deferred_owned=nil;return true end;return false,'pending'end}
]]
assert(loadfile("tests/tmp/bootstrap.lua"))(17, nil, 29)
local retiring = LiveLuaLoader
assert(retiring.records["live/demo"] and deferred_owned)
local detached, why = retiring.detach()
assert(not detached and why == "pending" and update ~= prior)
local values = { update(0.1) }
assert(values[1] == "prior" and values[3] == 7 and deferred_owned and update ~= prior)
update(0.1)
assert(
    not deferred_owned and not retiring.records["live/demo"] and update == prior,
    "Detach must keep polling then restore only its owned frame callback"
)
require = old_require
update = old_update
shutdown = old_shutdown
stingray = old_sr
deferred_count = nil
live_source = nil
reset()
print(
    "PASS compiled bootstrap detach keeps cleanup pump alive and restores owned hook only after acknowledgement"
)

reset()
do
 local h=host_for({live_lua_api=1,on_disable=function()return true end})
 local loader=factory(h,{})
 loader.live_catalog={['live/available']={}}
 for _,name in ipairs({'live/gone','live/pending','live/active','live/available'}) do
  loader.order[#loader.order+1]=name;loader.modules[name]='enable failed'
 end
 loader.pending_cleanup['live/pending']={}
 loader.modules['live/active']='loaded'
 local names,retained=loader.forget_removed()
 assert(#names==1 and names[1]=='live/gone' and retained==2)
 assert(loader.modules['live/gone']==nil and loader.modules['live/available'])
 assert(loader.pending_cleanup['live/pending'] and loader.modules['live/active']=='loaded')
end
reset()
print('PASS missing failed rows retire; available, active and pending ownership remain')

do
 local present=true
 local live=dofile('src/live.lua')({live='mock',read=function()return nil end,files=function()return present and {'gone.lua'} or {},nil,{} end},function()end)
 live.scan(true);assert(live.catalog['live/gone'])
 present=false;live.scan(true);assert(not live.catalog['live/gone'])
 live.forget_removed('live/gone');assert(not live.entries['live/gone'])
end
print('PASS forced discovery removes vanished catalog rows before safe retirement')
