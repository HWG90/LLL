# Porting a mod to Live Lua Loader

This guide targets published **LLL 0.1.0 / R18**. Live loading applies to Lua code with reversible ownership; it does not automatically reload game archive assets or make arbitrary native patches reversible.

## Choose the migration path

**Existing Bingus addon:** keep the archived version available for existing users, but port its initialization, update and cleanup into a returned live lifecycle table. LLL already starts compatible archived addons; that alone does not make them reloadable. Remove the archived installation of this particular mod while testing its loose replacement. Use one shared startup loader, with winning mod-manager priority.

**Ordinary archived Lua script:** move work currently performed during resource `require`, boot/startup execution or a global update wrapper into `on_enable` and `on_update`. Move restoration and shutdown work into `on_disable`. An archive marker, an old global initialization guard or `return true` is insufficient: managed loose scripts must return a lifecycle table.

Port only code you own or have permission to modify and redistribute. This example contains no third-party implementation.

## Folder and metadata

```text
%LOCALAPPDATA%/LLL/Helldivers2/
  Mods/
    example_live/
      mod.lua
      manifest.json
  Settings/
    mdl_example_live.lua
  Logs/
  LLL.cfg
```

Folder IDs use letters, digits, underscores or hyphens. A root-level `example_live.lua` also works, but a folder gives companions a clear home. LLL identifies this module as `live/example_live`. Avoid the same ID in multiple scanned roots: the LLL root has priority over migrated copies. Existing MDL/Bingus locations are also scanned; copying a mod does not remove its previous startup path.

Optional `manifest.json`, `mod.json` or `metadata.json` supplies display metadata. For example:

```json
{
  "name": "Example live mod",
  "author": "Example author"
}
```

The loader reads `name`/`Name` and `author`/`Author`. It does not interpret arbitrary dependency or asset declarations as installation instructions.

## Lifecycle: recommended context adapter

R18 supports an MDL-style lifecycle subset without requiring MDL. A table with `on_enable(context)` and no `live_lua_api` marker uses this adapter. The context provides `api = 2`, `id`, `dir`, `settings`, `loader`, `log`, `on_cleanup`, `global` and `set`.

This complete `mod.lua` example modifies only its own demonstration global:

```lua
local state

return {
    name = "Example live mod",
    author = "Example author",

    on_enable = function(ctx)
        state = { ticks = ctx.settings.ticks or 0 }
        ctx.global("ExampleLiveState", state)
        ctx.on_cleanup(function()
            state = nil
            return true
        end)
        ctx.log("enabled")
    end,

    on_update = function(ctx, dt)
        state.ticks = state.ticks + 1
    end,

    on_disable = function(ctx)
        ctx.set("ticks", state.ticks)
        return true
    end,
}
```

`ctx.set(key, value)` saves that mod's settings to `Settings/mdl_<id>.lua`; a failed write restores the previous value and raises an error. `ctx.settings` is loaded from that file, with migration fallback to the matching settings entry in loader config. Do not rewrite another mod's files or store transient native pointers. Loading and saving preserve values; settings are Lua tables, not JSON. R18 saves them with readable indentation.

`ctx.global(key, value)` tracks the previous global and the exact installed value. It restores the previous value only if the global is still owned by this instance. Cleanup callbacks run in reverse registration order, after the mod's `on_disable`. Globals are restored after cleanup completes. Names must be unique to the mod.

## Direct LLL lifecycle

For a mod that already manages ownership and persistence itself:

```lua
local ticks = 0
return {
    live_lua_api = 1,
    name = "Direct lifecycle example",
    on_enable = function() ticks = 0 end,
    on_update = function(dt) ticks = ticks + 1 end,
    on_disable = function() ticks = 0; return true end,
}
```

Direct `live_lua_api = 1` callbacks receive **no context**; `on_update` receives `dt`. `on_disable` is required. Do not accidentally add the marker to context-based callbacks. Initialization failure should raise an error; `on_enable` returning `false` is not an initialization-failure contract in R18. The loader invokes cleanup after an initialization exception, so partial initialization must also be reversible.

There is no author-facing `start()`/`shutdown()` lifecycle in these tables: map old startup work to `on_enable`, per-frame work to `on_update`, and shutdown work to `on_disable`.

## Convert the archived initialization

Typical archived shape:

```lua
-- Illustrative old structure
-- if an already-initialized global exists, return end
-- install hooks/resources immediately
-- replace the game's update function
-- return true
```

The port should instead have a side-effect-free module body that constructs the returned table. Acquire hooks/resources in `on_enable`; update through `on_update` where possible. Remove initialization guards that permanently block a second instance after reload. Keep duplicate protection appropriate to the resources you actually own.

Do not make a live wrapper that merely `require`s the existing archived module: `package.loaded` can preserve its old instance, and its original side effects may have no cleanup. Companion modules are not automatically reloaded with `mod.lua`. Explicitly manage their cache/ownership or keep reloadable behavior in the main lifecycle until companions have a tested reload contract.

## Cleanup and asynchronous release

For ordinary cleanup, return `true` once all owned effects are restored. Returning `false, reason` from `on_disable` declares cleanup pending. Supply `on_cleanup_poll` and return **exactly `true`** only after release is complete. Direct callbacks use `on_cleanup_poll(dt)`; context-adapter callbacks use `on_cleanup_poll(ctx, dt)`. Replacement remains blocked while the old record owns cleanup. An exception or missing acknowledgment must not be hidden as success.

Base-mod asynchronous cleanup is polled before adapter cleanup callbacks and owned globals are restored. A registered `ctx.on_cleanup` callback that returns `false` is retried until it completes. Design each cleanup step to tolerate repeated calls and partially completed work.

For hooks, capture the prior function, forward arguments and all return values, and restore it only if the current hook is still yours. Do not overwrite a newer owner's hook. Prefer `on_update` to wrapping global `update` yourself.

For native resources, release callbacks, windows, allocated memory and handles through the API that created them. Retain referenced Lua/native objects until asynchronous release acknowledges completion. Do not unload a DLL while a callback can still enter it. Native game writes need their own identity/range/ownership validation and reversal; LLL does not supply that guarantee.

For input capture, release cursor/key/button ownership and wait for held-input restoration before acknowledging cleanup. Escape, disable, focus loss and reload must leave player controls recoverable. A boolean saying capture is off is insufficient evidence that all handlers and held states were restored.

## Assets and dependencies

`ctx.dir` is the absolute mod directory. Use it to locate owned companion files; LLL does not automatically change `package.path`, install dependencies or add arbitrary asset paths to the game resource system. A native library may be loaded by its full path, but Lua reload does not automatically unload/reload its machine code. If safely replacing it is unsupported, require a new game session.

Textures, shaders, meshes, fonts and other archive-only resources remain separately deployed assets. Keep required resource archives installed while removing only the old duplicate Lua entry. If a package cannot separate its Lua startup from its assets, produce a dedicated asset package before offering a loose port. Do not remove stock or shared resources to solve a duplicate entry.

## Verify the port

1. Disable the old archived Lua startup and any second loose copy. Deploy the required asset/dependency packages with only one shared startup loader.
2. Copy the new folder to LLL Mods. In the F9 manager, Refresh and confirm its unique entry and loaded/error state.
3. Verify startup and an update callback. Change a harmless value, finish saving the edit, and verify cleanup followed by one new initialization. Do not assume file discovery proves gameplay behavior.
4. Introduce a syntax error: the existing instance should remain active and the error should be visible. Repair it and verify recovery.
5. Disable and re-enable. Confirm globals/hooks/resources are restored and no duplicate callbacks remain. Check that a deliberately pending cleanup blocks replacement until acknowledgment.
6. Verify saved settings survive reload, and that malformed/read-only settings fail visibly without silently resetting user values.
7. For input/UI/native mods, also test held inputs, focus loss and restoration in game. Check frame cost while idle and after repeated reloads.

Troubleshooting: a missing entry can mean an invalid ID or missing `mod.lua`; unsupported lifecycle means the returned table does not match either contract. A mod can be discovered yet disabled by its saved selection. `cleanup pending` means the old owner has not acknowledged release; investigate its cleanup rather than forcing another instance. Archive-only mods require a new session unless their author has added a supported live lifecycle. R18's game build/callback constraints still apply.

## R18 bundled smoke-test correction

The optional heartbeat.lua shipped in the R18 ZIP returns an unsupported table. Replace that optional test script with the direct lifecycle example above: it supplies `live_lua_api = 1` and the required `on_disable`. This documentation correction does not change the R18 download or require another loader version. The context example above is also verified against the published R18 adapter.
