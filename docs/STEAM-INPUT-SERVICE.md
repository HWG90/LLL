# Steam shared input service v1

`LiveLuaLoader.input_service` and `CowboyBingusModLoader.input_service` reference the same object. It is published before mod enable/after-startup callbacks. Availability is declared by `loader.capabilities.shared_input`; check the service itself before use. It reuses LLL's one authenticated helper connection. A mod must not create a competing pipe client.

`service.capabilities` is read-only: `menu`, `camera`, `relative_mouse`, and `coordinates='client-top-left'`. Camera capability requires the versioned extended helper operation. Older backends may provide only menu mode or no service.

## Lease operations

* `token, reason, cleanup_token = service.acquire(owner, mode)` accepts a printable owner name (1-128 bytes), and `mode='menu'` or `'camera'`. It refuses while manager, MCM, another lease or pending restoration owns input. It never implicitly closes another UI. The game must be foreground. Failed activation normally rolls back immediately; if rollback fails, retain the third return value and retry `release(cleanup_token)` explicitly.
* `sample, reason = service.snapshot(token)` requires the active token and foreground ownership. It performs at most one helper exchange per game frame. The sample table is reused: read it immediately; do not retain or mutate it. Repeated calls in a frame return zero wheel/dx/dy so deltas are delivered once.
* `service.owns(token)` indicates active read authority. It becomes false immediately on revocation or failed release, even when cleanup remains pending.
* `ok, reason = service.release(token)` stops the owned reader and restores only the cursor flags changed by that lease. Wrong/stale tokens cannot release another owner. A failed release retains the token for explicit retry. No automatic retry loop runs while restoration is pending.
* `service.status()` returns `owner`, `mode`, `active`, `pending_restore`, and `reason`. Loader `input_status()` also exposes the shared cursor owner so MCM can refuse conflicting capture.

Acquire only when opening the consuming UI/camera, sample only while it is active, and release on hide/disable/reload. Switching menu/camera mode requires release and reacquisition. Foreground loss or an MCM ownership conflict revokes the lease before mod update callbacks or sample delivery. The service does no helper sampling without an active consumer request.

## Sample schema

`valid`, `x`, `y`, `width`, `height`, `buttons`, `wheel`, `dx`, `dy`.

Coordinates are client pixels, origin at top left. Convert to GUI units using the sample's client size and the current GUI resolution. Buttons are a bit mask: 1 left, 2 right, 4 middle, 8 extra1, 16 extra2. Wheel uses signed Windows units (normally 120 per detent).

Camera `dx/dy` are signed raw relative counts, positive right/down. They are accumulated independently of cursor clipping/acceleration and drained atomically with wheel. Absolute-device motion packets contribute no relative movement. Menu samples provide zero dx/dy. Do not derive camera motion from absolute cursor positions.

Menu mode uses `mouse_focus=false`, visible cursor and clipping. Camera mode uses `mouse_focus=false`, hidden cursor and clipping. The previous flags are recorded once and restored on release. Native input filtering and cursor state do not identify which camera drives rendering; camera/render ownership remains the consumer's responsibility.

This lease currently suppresses gameplay mouse look, not gameplay keyboard actions. The deployed consumer's menu/camera transitions and release are user-confirmed, but W/A/S/D still move the native player during freecam. Keyboard/action isolation is under investigation; do not infer it from `capabilities.camera` or `relative_mouse`. No focus takeover, player-pose locking or disabled camera movement is used as a substitute.

The helper preserves legacy operation10's 36-byte response; operation12 returns 44 bytes with dx/dy appended. Lua clients should use this service instead of those internal wire operations.
