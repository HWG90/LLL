/* These tests run solely in their own process. They never change foreground
 * focus, synthesize input, open the game process, or alter game registration. */
#include "steam_pointer.c"
#include <assert.h>
#include <stdio.h>

static void decoder_contracts(void) {
    RAWINPUT input;
    LLLSteamPointerMotion motion, taken;
    ZeroMemory(&input, sizeof(input));
    input.header.dwType = RIM_TYPEMOUSE;
    input.header.dwSize = sizeof(input);
    input.data.mouse.usButtonFlags = RI_MOUSE_WHEEL;
    input.data.mouse.usButtonData = WHEEL_DELTA;
    input.data.mouse.lLastX = -8;
    input.data.mouse.lLastY = 14;
    assert(lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion));
    assert(motion.wheel == WHEEL_DELTA && motion.dx == -8 && motion.dy == 14);
    lll_pointer_add_motion(&motion);
    input.data.mouse.usButtonData = (USHORT)(SHORT)-WHEEL_DELTA;
    input.data.mouse.lLastX = 3;
    input.data.mouse.lLastY = -2;
    assert(lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion));
    assert(motion.wheel == -WHEEL_DELTA && motion.dx == 3 && motion.dy == -2);
    lll_pointer_add_motion(&motion);
    taken = lll_pointer_take_motion();
    assert(!taken.wheel && taken.dx == -5 && taken.dy == 12);
    taken = lll_pointer_take_motion();
    assert(!taken.wheel && !taken.dx && !taken.dy);
    assert(!lll_pointer_decode_motion(&input, sizeof(input), 42, 43, &motion));
    assert(!motion.wheel && !motion.dx && !motion.dy);
    assert(!lll_pointer_decode_motion(&input, sizeof(input), 0, 0, &motion));
    assert(!lll_pointer_decode_motion(&input, sizeof(RAWINPUTHEADER), 42, 42, &motion));
    input.header.dwSize = sizeof(RAWINPUTHEADER);
    assert(!lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion));
    input.header.dwSize = sizeof(input) + 1;
    assert(!lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion));
    input.header.dwSize = sizeof(input);
    input.header.dwType = RIM_TYPEKEYBOARD;
    assert(!lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion));
    input.header.dwType = RIM_TYPEMOUSE;
    input.data.mouse.usButtonFlags = RI_MOUSE_LEFT_BUTTON_DOWN;
    assert(lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion) && !motion.wheel);
    input.data.mouse.usButtonFlags = RI_MOUSE_HWHEEL;
    assert(lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion) && !motion.wheel);
    input.data.mouse.usButtonFlags = RI_MOUSE_WHEEL;
    input.data.mouse.usFlags = MOUSE_MOVE_ABSOLUTE | MOUSE_VIRTUAL_DESKTOP;
    assert(lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion));
    assert(motion.wheel == -WHEEL_DELTA && !motion.dx && !motion.dy);
    input.data.mouse.usFlags = MOUSE_ATTRIBUTES_CHANGED;
    assert(lll_pointer_decode_motion(&input, sizeof(input), 42, 42, &motion));
    assert(motion.dx == 3 && motion.dy == -2);
    motion.wheel = INT32_MAX; motion.dx = INT32_MIN; motion.dy = INT32_MAX;
    lll_pointer_add_motion(&motion);
    motion.wheel = 1; motion.dx = -1; motion.dy = 1;
    lll_pointer_add_motion(&motion);
    taken = lll_pointer_take_motion();
    assert(taken.wheel == INT32_MAX && taken.dx == INT32_MIN && taken.dy == INT32_MAX);
    motion.wheel = INT32_MIN; motion.dx = INT32_MAX; motion.dy = INT32_MIN;
    lll_pointer_add_motion(&motion);
    motion.wheel = -1; motion.dx = 1; motion.dy = -1;
    lll_pointer_add_motion(&motion);
    taken = lll_pointer_take_motion();
    assert(taken.wheel == INT32_MIN && taken.dx == INT32_MAX && taken.dy == INT32_MIN);
}

static void registration_ownership_contract(void) {
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW type;
    HWND window;
    RAWINPUTDEVICE device, found;
    ZeroMemory(&type, sizeof(type));
    type.lpfnWndProc = DefWindowProcW;
    type.hInstance = instance;
    type.lpszClassName = L"LLLPointerRegistrationFixture";
    assert(RegisterClassW(&type));
    window = CreateWindowExW(0, type.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, instance, NULL);
    assert(window);
    device.usUsagePage = 1;
    device.usUsage = 2;
    device.dwFlags = RIDEV_INPUTSINK;
    device.hwndTarget = window;
    assert(RegisterRawInputDevices(&device, 1, sizeof(device)));
    assert(!lll_pointer_start(GetCurrentProcessId()));
    assert(lll_pointer_release());
    assert(lll_pointer_registration(&found) == 1 && found.hwndTarget == window && found.dwFlags == device.dwFlags);
    device.dwFlags = RIDEV_REMOVE;
    device.hwndTarget = NULL;
    assert(RegisterRawInputDevices(&device, 1, sizeof(device)));
    /* A newer registration replacing our target remains the new owner's. */
    assert(lll_pointer_start(GetCurrentProcessId()));
    device.dwFlags = RIDEV_INPUTSINK;
    device.hwndTarget = window;
    assert(RegisterRawInputDevices(&device, 1, sizeof(device)));
    assert(lll_pointer_release());
    assert(lll_pointer_registration(&found) == 1 && found.hwndTarget == window);
    device.dwFlags = RIDEV_REMOVE;
    device.hwndTarget = NULL;
    assert(RegisterRawInputDevices(&device, 1, sizeof(device)));
    assert(DestroyWindow(window));
    assert(UnregisterClassW(type.lpszClassName, instance));
}

int main(void) {
    LLLSteamPointerSnapshot snapshot;
    LLLSteamPointerSample sample;
    LLLSteamPointerMotion motion = {WHEEL_DELTA, -17, 31}, taken;
    RAWINPUTDEVICE device;
    DWORD before = 0, after = 0;
    ULONGLONG maximum = 0;
    decoder_contracts();
    assert(sizeof(snapshot) == 28 && sizeof(sample) == 36);
    assert(!lll_pointer_start(0));
    assert(!lll_pointer_snapshot(NULL));
    assert(!lll_pointer_snapshot_extended(NULL));
    assert(!lll_pointer_snapshot(&snapshot) && !snapshot.valid);
    assert(lll_pointer_release());
    assert(lll_pointer_registration(&device) == 0);
    registration_ownership_contract();
    assert(GetProcessHandleCount(GetCurrentProcess(), &before));
    for (int index = 0; index < 100; ++index) {
        ULONGLONG start = GetTickCount64();
        /* An impossible foreground owner proves no pointer or buttons leak. */
        assert(lll_pointer_start(MAXDWORD));
        if (GetTickCount64() - start > maximum) maximum = GetTickCount64() - start;
        assert(lll_pointer_start(MAXDWORD));
        assert(lll_pointer_registration(&device) == 1 && device.hwndTarget == lll_pointer_state.window);
        lll_pointer_add_motion(&motion);
        assert(lll_pointer_snapshot(&snapshot));
        assert(!snapshot.valid && !snapshot.x && !snapshot.y && !snapshot.width && !snapshot.height && !snapshot.buttons && !snapshot.wheel);
        taken = lll_pointer_take_motion();
        assert(!taken.wheel && !taken.dx && !taken.dy);
        lll_pointer_add_motion(&motion);
        assert(lll_pointer_snapshot_extended(&sample));
        assert(!sample.valid && !sample.x && !sample.y && !sample.width && !sample.height && !sample.buttons && !sample.wheel && !sample.dx && !sample.dy);
        taken = lll_pointer_take_motion();
        assert(!taken.wheel && !taken.dx && !taken.dy);
        /* After a focus-invalid drain, only newly received deltas survive. */
        lll_pointer_add_motion(&motion);
        taken = lll_pointer_take_motion();
        assert(taken.wheel == WHEEL_DELTA && taken.dx == -17 && taken.dy == 31);
        lll_pointer_add_motion(&motion);
        assert(lll_pointer_release());
        assert(!lll_pointer_state.thread && !lll_pointer_state.window && !lll_pointer_state.ready && !lll_pointer_state.stop);
        taken = lll_pointer_take_motion();
        assert(!taken.wheel && !taken.dx && !taken.dy);
        assert(!lll_pointer_snapshot(&snapshot) && !snapshot.valid);
        assert(!lll_pointer_snapshot_extended(&sample) && !sample.valid && !sample.dx && !sample.dy);
        assert(lll_pointer_registration(&device) == 0);
    }
    assert(GetProcessHandleCount(GetCurrentProcess(), &after));
    assert(before == after);
    assert(maximum <= 1000);
    printf("PASS pointer ownership, raw relative/wheel decoder, atomic exactly-once drain, saturation, focus clearing, registration preservation, 100 start/releases; max setup %llu ms; handles %lu -> %lu\n",
           (unsigned long long)maximum, (unsigned long)before, (unsigned long)after);
    return 0;
}
