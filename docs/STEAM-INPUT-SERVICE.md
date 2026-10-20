# Steam shared input service v1

`LiveLuaLoader.input_service` and `CowboyBingusModLoader.input_service` reference the same object. It is published before mod enable/after-startup callbacks. Availability is declared by `loader.capabilities.shared_input`; check the service itself before use. It reuses LLL's one authenticated helper connection. A mod must not create a competing pipe client.

`service.capabilities` is read-only: `menu`, `camera`, `relative_mouse`, and `coordinates='client-top-left'`. Camera capability requires the versioned extended helper operation. Older backends may provide only menu mode or no service.

## Lease operations

* `token, reason, cleanup_token = service.acquire(owner, mode, frontend)` accepts a printable owner name (1-128 bytes), and `mode='menu'` or `'camera'`. Normal consumers omit `frontend`. It refuses while manager, MCM, another lease or pending restoration owns input. It never implicitly closes another UI. The game must be foreground. Failed activation normally rolls back immediately; if rollback fails, retain the third return value and retry `release(cleanup_token)` explicitly.
* `sample, reason = service.snapshot(token)` requires the active token and foreground ownership. It performs at most one helper exchange per game frame. The sample table is reused: read it immediately; do not retain or mutate it. Repeated calls in a frame return zero wheel/dx/dy so deltas are delivered once.
* `service.owns(token)` indicates active read authority. It becomes false immediately on revocation or failed release, even when cleanup remains pending.
* `ok, reason = service.release(token)` stops the owned reader and restores only the cursor flags changed by that lease. Wrong/stale tokens cannot release another owner. A failed release retains the token for explicit retry. No automatic retry loop runs while restoration is pending.
* `service.status()` returns `owner`, `mode`, `active`, `pending_restore`, and `reason`, plus `frontend='mcm'` for a lease using the registration below. Loader `input_status()` also exposes the shared cursor owner so MCM can refuse conflicting capture.

Acquire only when opening the consuming UI/camera, sample only while it is active, and release on hide/disable/reload. Switching menu/camera mode requires release and reacquisition. Foreground loss or an MCM ownership conflict revokes the lease before mod update callbacks or sample delivery. The service does no helper sampling without an active consumer request.

## MCM frontend registration

The current source adds an optional registration extension to v1. Check for
`service.register_frontend` before enabling the Steam MCM frontend; older builds
may predate it. This extension is included in the installed review candidate.

MCM must publish its actual API table as `_G.DBFMCM`, with callable `is_open()`
and `input_status()` and a direct `shared_input_service` field referencing this
exact service object. It then calls:

```lua
api.shared_input_service = service
-- Publish DBFMCM through the loader's owned-global lifecycle first.
local registration, reason = service.register_frontend('mcm', api)
assert(registration, reason)
-- Only while opening the menu, after the manager releases its input:
local token, why, cleanup = service.acquire('DBF MCM', 'menu', registration)
```

Registration does not acquire cursor ownership or start a reader. Its opaque
token is accepted only for owner `DBF MCM` in `menu` mode. The ordinary input
token remains the authority for `snapshot`, `owns` and `release`; registration
never substitutes for that token. Keep both tokens private to MCM's adapter.

For this registered consumer, MCM may truthfully report `is_open() == true` and
its own `{owner='DBF MCM', active=true}` input status. Other consumers still
refuse while MCM is open. Legacy MCM, foreign owners, pending restoration,
unknown active owners and failing/malformed status remain excluded. A caller
using only the same owner string receives no exemption.
Registered status requires boolean `active` and `pending_restore` fields;
`owner` is nil while released and `DBF MCM` while MCM owns its input.

Changing the published provider or its service reference revokes a bound lease
before further sample delivery. Duplicate registration does not reveal or
replace an existing token. A new provider may register after the previous bound
input lease has fully released; old registration tokens then become stale.

On disable/reload, release the input token (or failed-activation cleanup token)
completely, then call `service.unregister_frontend(registration)` before clearing
the owned global. Unregister rejects wrong/stale tokens and refuses while its
input is active or restoration is pending. Retry failed release explicitly at a
bounded recovery point; the service adds no idle retry loop. Neither registration
nor unchanged active snapshots reapplies cursor flags.

## Shortcut ownership

When the loader and MCM share a shortcut, the Steam frontend defers that whole
key press to MCM. It queries the current published
`DBFMCM.menu_binding_status().global_key` through a protected call on the press
edge only. Closing MCM and releasing its lease earlier in that frame therefore
cannot open the loader on the same key press. Held keys add no binding queries.
Saved shortcuts remain unchanged; `loader.open_manager()` still explicitly opens
the loader after the other frontend releases its input.

## Sample schema

`valid`, `x`, `y`, `width`, `height`, `buttons`, `wheel`, `dx`, `dy`.

Coordinates are client pixels, origin at top left. Convert to GUI units using the sample's client size and the current GUI resolution. Buttons are a bit mask: 1 left, 2 right, 4 middle, 8 extra1, 16 extra2. Wheel uses signed Windows units (normally 120 per detent).

Camera `dx/dy` are signed raw relative counts, positive right/down. They are accumulated independently of cursor clipping/acceleration and drained atomically with wheel. Absolute-device motion packets contribute no relative movement. Menu samples provide zero dx/dy. Do not derive camera motion from absolute cursor positions.

Menu mode uses `mouse_focus=false`, visible cursor and clipping. Camera mode uses `mouse_focus=false`, hidden cursor and clipping. The previous flags are recorded once and restored on release. Native input filtering and cursor state do not identify which camera drives rendering; camera/render ownership remains the consumer's responsibility.

This lease currently suppresses gameplay mouse look, not gameplay keyboard actions. The deployed consumer's menu/camera transitions and release are user-confirmed, but W/A/S/D still move the native player during freecam and with MCM open. Keyboard/action isolation is under investigation; do not infer it from `capabilities.camera` or `relative_mouse`. No focus takeover, player-pose locking or disabled camera movement is used as a substitute.

## Keyboard action isolation investigation

Current retained Lua inventories expose controller reads, thresholds and dead
zones, without a verified gameplay enable/block API. The presence of
`Keyboard.set_down_threshold` does not establish that it suppresses native action
values. A bounded live MCM trial on build 25988413 held the native threshold at
1.0 over 516 successful snapshots while unchanged native button readers recorded
W/A/S/D activity. The user still observed native player movement. MCM release
restored the exact original 0.5 threshold, the observer removed its wrappers,
and its temporary project was removed. This tested threshold route does not
provide gameplay suppression and is not included in the release. Replacing Lua
readers would affect Lua consumers without proving that native gameplay stops
receiving keys.

The published Autodesk native [InputCApi](https://help.autodesk.com/cloudhelp/ENU/Stingray-SDK-Help/engine_c/c__api__input_8h.html)
does declare `void (*flush_controllers_state)()`. The engine supplies this
interface through [ScriptApi.Input](https://help.autodesk.com/cloudhelp/ENU/Stingray-SDK-Help/engine_c/plugin__c__api_8h.html)
using the [plugin API](https://help.autodesk.com/cloudhelp/ENU/Stingray-SDK-Help/engine_c/plugin__api_8h.html).
This is a native investigation candidate, not an implemented suppression route:
the current game's interface layout, reset semantics and callback ordering still
need verification. A reset is not evidence of a persistent input lease.

Offline searches in the current executable and game DLL did not establish a
callable action gate. Known live Lua method names are also absent from those
string inventories, so a negative string search does not prove API absence.
No threshold/reset experiment is enabled in this candidate.

The helper preserves legacy operation10's 36-byte response; operation12 returns 44 bytes with dx/dy appended. Lua clients should use this service instead of those internal wire operations.
