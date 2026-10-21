/* Opt-in external keyboard lease. RegisterHotKey runs only in this service's
 * own message thread. No target hooks, injected input, focus changes, process
 * memory access, or idle keyboard thread. This candidate's modifier behavior
 * requires physical qualification before the capability may be advertised.
 * Include in steam_service.c; standalone fixtures replace only Win32 seams. */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

#define LLL_KEYBOARD_VERSION 1u
#define LLL_KEYBOARD_ARMING 1u
#define LLL_KEYBOARD_ACTIVE 2u
#define LLL_KEYBOARD_REVOKED 3u
#define LLL_KEYBOARD_CLOSING 4u
#define LLL_KEYBOARD_FAILED 5u
#define LLL_KEYBOARD_TTL_MS 2000u
#define LLL_KEYBOARD_ARM_MS 2000u
#define LLL_KEYBOARD_COMMAND_MS 1000u
#define LLL_KEYBOARD_MAX_TUPLES 2048u

typedef struct LLLSteamKeyboardReply {
    uint32_t version, client, generation, state, mask[8];
} LLLSteamKeyboardReply;
typedef struct LLLSteamKeyboardSample {
    uint32_t version, generation, state, keys[8];
} LLLSteamKeyboardSample;
typedef struct LLLSteamKeyboardLease {
    HANDLE thread, ready, stop, process;
    HWND target, window;
    HWINEVENTHOOK foreground_hook;
    FILETIME creation;
    DWORD pid;
    uint32_t client, generation, state, error, terminal, mask[8];
    ULONGLONG started, heartbeat, register_ms;
    int registrations[LLL_KEYBOARD_MAX_TUPLES];
    unsigned int registration_count;
    int revoking;
} LLLSteamKeyboardLease;
typedef struct LLLSteamKeyboardRetired {
    DWORD pid;
    uint32_t client, generation;
} LLLSteamKeyboardRetired;

/* This exact whitelist is shared with Lua. Side modifier bits are aliases:
 * requesting any member requires generic + left + right; only generic VKs
 * are registered. Windows/F12/PrintScreen/mouse/unassigned VKs are excluded.
 * Alt+Tab/Esc/F4/Enter/Space, Ctrl+Esc and Ctrl+Alt+Delete tuples are deliberately
 * omitted. The owned-window 39-tuple W/Space/generic-modifier proof passed;
 * the complete matrix and integrated gameplay behavior remain unqualified.
 * A successful registration alone does not establish suppression. */
static const uint32_t lll_keyboard_allowed[8] = {
    0x081f3300u, 0x03ffe1ffu, 0x27fffffeu, 0xf7ffffffu,
    0x000300ffu, 0xfc00003fu, 0xf8000001u, 0x00000004u
};
static SRWLOCK lll_keyboard_lifecycle = SRWLOCK_INIT;
static SRWLOCK lll_keyboard_data = SRWLOCK_INIT;
static LLLSteamKeyboardLease lll_keyboard_lease;
static LLLSteamKeyboardRetired lll_keyboard_retired;
static uint32_t lll_keyboard_highest_client, lll_keyboard_last_generation;
static DWORD lll_keyboard_session_pid;
static FILETIME lll_keyboard_session_creation;
static const wchar_t lll_keyboard_class[] = L"LLLSteamExternalKeyboard";

/* Production uses direct Win32 calls. Tests substitute deterministic fakes
 * at compilation; no mutable function table is exposed by the service. */
#ifndef LLL_KB_REGISTER
#define LLL_KB_REGISTER RegisterHotKey
#endif
#ifndef LLL_KB_UNREGISTER
#define LLL_KB_UNREGISTER UnregisterHotKey
#endif
#ifndef LLL_KB_ASYNC
#define LLL_KB_ASYNC GetAsyncKeyState
#endif
#ifndef LLL_KB_FOREGROUND
#define LLL_KB_FOREGROUND GetForegroundWindow
#endif
#ifndef LLL_KB_WINDOW_PID
#define LLL_KB_WINDOW_PID GetWindowThreadProcessId
#endif
#ifndef LLL_KB_VISIBLE
#define LLL_KB_VISIBLE IsWindowVisible
#endif
#ifndef LLL_KB_NOW
#define LLL_KB_NOW GetTickCount64
#endif
#ifndef LLL_KB_HOOK
#define LLL_KB_HOOK SetWinEventHook
#endif
#ifndef LLL_KB_UNHOOK
#define LLL_KB_UNHOOK UnhookWinEvent
#endif

static int lll_keyboard_bit(const uint32_t mask[8], unsigned int key) {
    return (mask[key >> 5] & (1u << (key & 31))) != 0;
}
static int lll_keyboard_mask_valid(const uint32_t mask[8]) {
    uint32_t any = 0;
    static const unsigned int groups[3][3] = {{16,160,161},{17,162,163},{18,164,165}};
    if (!mask) return 0;
    for (unsigned int i = 0; i < 8; ++i) {
        if (mask[i] & ~lll_keyboard_allowed[i]) return 0;
        any |= mask[i];
    }
    if (!any) return 0;
    for (unsigned int i = 0; i < 3; ++i) {
        int bits = lll_keyboard_bit(mask, groups[i][0]) + lll_keyboard_bit(mask, groups[i][1]) +
                   lll_keyboard_bit(mask, groups[i][2]);
        if (bits && bits != 3) return 0;
    }
    return 1;
}
static int lll_keyboard_tuple(unsigned int key, unsigned int modifiers) {
    if (key >= 160 && key <= 165) return 0;
    if ((modifiers & MOD_ALT) && (key == VK_TAB || key == VK_ESCAPE || key == VK_F4 ||
        key == VK_RETURN || key == VK_SPACE)) return 0;
    if ((modifiers & MOD_CONTROL) && key == VK_ESCAPE) return 0;
    if ((modifiers & (MOD_CONTROL | MOD_ALT)) == (MOD_CONTROL | MOD_ALT) && key == VK_DELETE) return 0;
    return 1;
}
static unsigned int lll_keyboard_modifiers(unsigned int index) {
    return ((index & 1) ? MOD_SHIFT : 0u) | ((index & 2) ? MOD_CONTROL : 0u) |
           ((index & 4) ? MOD_ALT : 0u);
}
static int lll_keyboard_foreground(const LLLSteamKeyboardLease *lease) {
    DWORD pid = 0;
    HWND window = LLL_KB_FOREGROUND();
    if (!window || window != lease->target || !LLL_KB_VISIBLE(window)) return 0;
    LLL_KB_WINDOW_PID(window, &pid);
    return pid == lease->pid;
}
static int lll_keyboard_held(const uint32_t mask[8]) {
    for (unsigned int key = 0; key < 256; ++key)
        if (lll_keyboard_bit(mask, key) && (LLL_KB_ASYNC((int)key) & 0x8000)) return 1;
    return 0;
}

/* Read-only identity proof: an ordinary query handle, exact canonical stock
 * executable path, and process creation time. No target VM permissions. */
#ifndef LLL_KB_IDENTIFY
static int lll_keyboard_canonical(const wchar_t *path, wchar_t result[32768]) {
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    DWORD count;
    if (file == INVALID_HANDLE_VALUE) return 0;
    count = GetFinalPathNameByHandleW(file, result, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(file);
    return count > 0 && count < 32768;
}
static DWORD lll_keyboard_identify(DWORD pid, const wchar_t *expected, HANDLE *process, FILETIME *creation) {
    wchar_t actual[32768], canonical_actual[32768], canonical_expected[32768];
    DWORD count = 32768, error = ERROR_ACCESS_DENIED;
    FILETIME exited, kernel, user;
    HANDLE handle;
    *process = NULL;
    if (!pid || !expected || !expected[0]) return ERROR_INVALID_PARAMETER;
    handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
    if (!handle) return GetLastError();
    if (GetProcessTimes(handle, creation, &exited, &kernel, &user) &&
        QueryFullProcessImageNameW(handle, 0, actual, &count) &&
        lll_keyboard_canonical(actual, canonical_actual) && lll_keyboard_canonical(expected, canonical_expected) &&
        CompareStringOrdinal(canonical_actual, -1, canonical_expected, -1, TRUE) == CSTR_EQUAL &&
        WaitForSingleObject(handle, 0) == WAIT_TIMEOUT) {
        *process = handle;
        return 0;
    }
    CloseHandle(handle);
    return error;
}
#define LLL_KB_IDENTIFY lll_keyboard_identify
#endif

static void lll_keyboard_reply_locked(LLLSteamKeyboardReply *out) {
    out->version = LLL_KEYBOARD_VERSION;
    out->client = lll_keyboard_lease.client;
    out->generation = lll_keyboard_lease.generation;
    AcquireSRWLockShared(&lll_keyboard_data);
    out->state = lll_keyboard_lease.state;
    memcpy(out->mask, lll_keyboard_lease.mask, sizeof(out->mask));
    ReleaseSRWLockShared(&lll_keyboard_data);
}
/* Only the message thread calls this function. Failed removal is retained as
 * FAILED until the actual thread has retired (thread exit frees its hotkeys). */
static int lll_keyboard_unregister_worker(LLLSteamKeyboardLease *lease) {
    int clean = 1;
    while (lease->registration_count) {
        int id = lease->registrations[--lease->registration_count];
        if (!LLL_KB_UNREGISTER(lease->window, id)) clean = 0;
    }
    if (!clean) {
        AcquireSRWLockExclusive(&lll_keyboard_data);
        lease->error = ERROR_BUSY;
        lease->terminal = LLL_KEYBOARD_FAILED;
        ReleaseSRWLockExclusive(&lll_keyboard_data);
    }
    return clean;
}
static void lll_keyboard_stop_request(uint32_t terminal, DWORD error) {
    AcquireSRWLockExclusive(&lll_keyboard_data);
    if (lll_keyboard_lease.state == LLL_KEYBOARD_ARMING || lll_keyboard_lease.state == LLL_KEYBOARD_ACTIVE) {
        lll_keyboard_lease.state = LLL_KEYBOARD_CLOSING;
        lll_keyboard_lease.terminal = terminal;
        lll_keyboard_lease.error = error;
    }
    ReleaseSRWLockExclusive(&lll_keyboard_data);
    if (lll_keyboard_lease.stop) SetEvent(lll_keyboard_lease.stop);
}
/* Checking/renewing the deadline and changing its state use the same lock.
 * A snapshot cannot revive an expired lease, and a worker using an earlier
 * deadline cannot revoke a heartbeat that has just renewed it. */
static uint32_t lll_keyboard_deadline(int renew) {
    LLLSteamKeyboardLease *lease = &lll_keyboard_lease;
    uint32_t state;
    int expired = 0;
    AcquireSRWLockExclusive(&lll_keyboard_data);
    if (lease->state == LLL_KEYBOARD_ACTIVE) {
        ULONGLONG now = LLL_KB_NOW();
        if (now - lease->heartbeat >= LLL_KEYBOARD_TTL_MS) {
            lease->state = LLL_KEYBOARD_CLOSING;
            lease->terminal = LLL_KEYBOARD_REVOKED;
            lease->error = ERROR_TIMEOUT;
            expired = 1;
        } else if (renew) lease->heartbeat = now;
    }
    state = lease->state;
    ReleaseSRWLockExclusive(&lll_keyboard_data);
    if (expired) SetEvent(lease->stop);
    return state;
}
static void CALLBACK lll_keyboard_foreground_event(HWINEVENTHOOK hook, DWORD event, HWND window,
                                                  LONG object, LONG child, DWORD thread, DWORD time) {
    LLLSteamKeyboardLease *lease = &lll_keyboard_lease;
    (void)hook; (void)object; (void)child; (void)thread; (void)time;
    if (event != EVENT_SYSTEM_FOREGROUND || window == lease->target || lease->revoking) return;
    lease->revoking = 1;
    lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
    lll_keyboard_unregister_worker(lease);
}
static LRESULT CALLBACK lll_keyboard_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_HOTKEY) return 0;
    return DefWindowProcW(window, message, wp, lp);
}
static int lll_keyboard_messages(void) {
    MSG message;
    for (unsigned int count = 0; count < 64 && PeekMessageW(&message, NULL, 0, 0, PM_REMOVE); ++count) {
        if (message.message == WM_QUIT) return 0;
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return 1;
}
static int lll_keyboard_register_worker(LLLSteamKeyboardLease *lease) {
    ULONGLONG started = LLL_KB_NOW();
    for (unsigned int key = 0; key < 256; ++key) {
        if (!lll_keyboard_bit(lease->mask, key) || (key >= 160 && key <= 165)) continue;
        for (unsigned int variant = 0; variant < 8; ++variant) {
            unsigned int modifiers = lll_keyboard_modifiers(variant);
            int id = 1 + (int)(key * 8 + variant);
            if (!lll_keyboard_tuple(key, modifiers)) continue;
            /* Registration is a bounded transition; foreground notifications
             * are dispatched between tuples rather than queued until the end. */
            if (!lll_keyboard_messages() || WaitForSingleObject(lease->stop, 0) != WAIT_TIMEOUT ||
                !lll_keyboard_foreground(lease) || WaitForSingleObject(lease->process, 0) != WAIT_TIMEOUT) {
                lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
                return 0;
            }
            if (LLL_KB_NOW() - started >= LLL_KEYBOARD_COMMAND_MS) {
                lll_keyboard_stop_request(LLL_KEYBOARD_FAILED, ERROR_TIMEOUT);
                return 0;
            }
            if (!LLL_KB_REGISTER(lease->window, id, modifiers | MOD_NOREPEAT, key)) {
                DWORD error = GetLastError();
                lll_keyboard_stop_request(LLL_KEYBOARD_FAILED, error ? error : ERROR_HOTKEY_ALREADY_REGISTERED);
                return 0;
            }
            lease->registrations[lease->registration_count++] = id;
        }
    }
    /* The bulk reservation is not atomic. A key pressed before its tuple was
     * reserved may already be held by the game. Never claim ACTIVE in that
     * state, and never return to ARMING with existing IDs registered. */
    if (lll_keyboard_held(lease->mask)) {
        lll_keyboard_stop_request(LLL_KEYBOARD_FAILED, ERROR_BUSY);
        return 0;
    }
    if (LLL_KB_NOW() - started >= LLL_KEYBOARD_COMMAND_MS) {
        lll_keyboard_stop_request(LLL_KEYBOARD_FAILED, ERROR_TIMEOUT);
        return 0;
    }
    if (WaitForSingleObject(lease->stop, 0) != WAIT_TIMEOUT || !lll_keyboard_foreground(lease) ||
        WaitForSingleObject(lease->process, 0) != WAIT_TIMEOUT) {
        lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
        return 0;
    }
    AcquireSRWLockExclusive(&lll_keyboard_data);
    lease->register_ms = LLL_KB_NOW() - started;
    if (lease->state == LLL_KEYBOARD_ARMING) {
        lease->heartbeat = LLL_KB_NOW();
        lease->state = LLL_KEYBOARD_ACTIVE;
    }
    ReleaseSRWLockExclusive(&lll_keyboard_data);
    return 1;
}
static DWORD WINAPI lll_keyboard_thread(void *unused) {
    LLLSteamKeyboardLease *lease = &lll_keyboard_lease;
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW type;
    HANDLE waits[2];
    int owns_class = 0;
    (void)unused;
    ZeroMemory(&type, sizeof(type));
    type.lpfnWndProc = lll_keyboard_proc;
    type.hInstance = instance;
    type.lpszClassName = lll_keyboard_class;
    if (!RegisterClassW(&type)) goto setup_failed;
    owns_class = 1;
    lease->window = CreateWindowExW(0, lll_keyboard_class, L"", 0, 0, 0, 0, 0,
                                   HWND_MESSAGE, NULL, instance, NULL);
    if (!lease->window) goto setup_failed;
    lease->foreground_hook = LLL_KB_HOOK(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, NULL,
        lll_keyboard_foreground_event, 0, 0, WINEVENT_OUTOFCONTEXT);
    if (!lease->foreground_hook) goto setup_failed;
    waits[0] = lease->stop;
    waits[1] = lease->process;
    for (;;) {
        uint32_t state;
        ULONGLONG now, heartbeat;
        DWORD timeout, result;
        AcquireSRWLockShared(&lll_keyboard_data);
        state = lease->state;
        heartbeat = lease->heartbeat;
        ReleaseSRWLockShared(&lll_keyboard_data);
        now = LLL_KB_NOW();
        if (state != LLL_KEYBOARD_ARMING && state != LLL_KEYBOARD_ACTIVE) break;
        if (state == LLL_KEYBOARD_ARMING) {
            if (!lll_keyboard_foreground(lease)) {
                lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED); break;
            }
            if (now - lease->started >= LLL_KEYBOARD_ARM_MS) {
                lll_keyboard_stop_request(LLL_KEYBOARD_FAILED, ERROR_TIMEOUT); break;
            }
            /* No raw sink is registered. This finite qualification is the only
             * timed key sampling: at most 2 seconds, then no idle retry/rearm. */
            if (!lll_keyboard_held(lease->mask)) {
                if (!lll_keyboard_register_worker(lease)) break;
                SetEvent(lease->ready);
                continue;
            }
            now = LLL_KB_NOW();
            if (now - lease->started >= LLL_KEYBOARD_ARM_MS) {
                lll_keyboard_stop_request(LLL_KEYBOARD_FAILED, ERROR_TIMEOUT); break;
            }
            timeout = LLL_KEYBOARD_ARM_MS - (DWORD)(now - lease->started);
            if (timeout > 16) timeout = 16;
        } else {
            ULONGLONG elapsed = now - heartbeat;
            if (elapsed >= LLL_KEYBOARD_TTL_MS) {
                if (lll_keyboard_deadline(0) != LLL_KEYBOARD_ACTIVE) break;
                continue;
            }
            timeout = LLL_KEYBOARD_TTL_MS - (DWORD)elapsed;
        }
        result = MsgWaitForMultipleObjectsEx(2, waits, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (result == WAIT_OBJECT_0) break;
        if (result == WAIT_OBJECT_0 + 1) {
            lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_PROCESS_ABORTED); break;
        }
        if (result == WAIT_OBJECT_0 + 2) {
            if (!lll_keyboard_messages()) { lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED); break; }
        } else if (result != WAIT_TIMEOUT) {
            lll_keyboard_stop_request(LLL_KEYBOARD_FAILED, GetLastError()); break;
        }
        /* A heartbeat does not wake this thread. At the previous deadline the
         * next loop recomputes the remaining TTL without key/foreground reads. */
    }
    goto done;
setup_failed:
    { DWORD error = GetLastError(); lll_keyboard_stop_request(LLL_KEYBOARD_FAILED, error ? error : ERROR_NOT_READY); }
done:
    lll_keyboard_unregister_worker(lease);
    if (lease->foreground_hook && !LLL_KB_UNHOOK(lease->foreground_hook)) {
        AcquireSRWLockExclusive(&lll_keyboard_data);
        lease->terminal = LLL_KEYBOARD_FAILED;
        lease->error = ERROR_BUSY;
        ReleaseSRWLockExclusive(&lll_keyboard_data);
    }
    lease->foreground_hook = NULL;
    if (lease->window) DestroyWindow(lease->window);
    lease->window = NULL;
    if (owns_class) UnregisterClassW(lll_keyboard_class, instance);
    AcquireSRWLockExclusive(&lll_keyboard_data);
    lease->state = lease->terminal ? lease->terminal : LLL_KEYBOARD_REVOKED;
    ReleaseSRWLockExclusive(&lll_keyboard_data);
    SetEvent(lease->ready);
    return 0;
}

/* Lifecycle lock held. Never close a handle or reset storage under a live
 * worker. Keeping one retired pair makes explicit release idempotent without
 * a token history; a stale pair can never close a new lease. */
static int lll_keyboard_reap_locked(DWORD timeout) {
    LLLSteamKeyboardLease *lease = &lll_keyboard_lease;
    if (!lease->thread) return 1;
    if (WaitForSingleObject(lease->thread, timeout) != WAIT_OBJECT_0) return 0;
    lll_keyboard_retired.pid = lease->pid;
    lll_keyboard_retired.client = lease->client;
    lll_keyboard_retired.generation = lease->generation;
    CloseHandle(lease->thread);
    CloseHandle(lease->ready);
    CloseHandle(lease->stop);
    CloseHandle(lease->process);
    ZeroMemory(lease, sizeof(*lease));
    return 1;
}
static int lll_keyboard_same_session(DWORD pid, const FILETIME *creation) {
    return !lll_keyboard_session_pid || (pid == lll_keyboard_session_pid &&
        CompareFileTime(creation, &lll_keyboard_session_creation) == 0);
}

DWORD lll_keyboard_acquire(DWORD pid, const wchar_t *expected, uint32_t client,
                           const uint32_t mask[8], LLLSteamKeyboardReply *out) {
    LLLSteamKeyboardLease *lease = &lll_keyboard_lease;
    HANDLE process = NULL;
    FILETIME creation;
    DWORD error = ERROR_INVALID_PARAMETER, foreground_pid = 0;
    HWND foreground;
    if (!out || !client || !lll_keyboard_mask_valid(mask)) return ERROR_INVALID_PARAMETER;
    ZeroMemory(out, sizeof(*out));
    AcquireSRWLockExclusive(&lll_keyboard_lifecycle);
    lll_keyboard_reap_locked(0);
    if (lease->thread) {
        if (pid == lease->pid && client == lease->client && !memcmp(mask, lease->mask, sizeof(lease->mask))) {
            lll_keyboard_reply_locked(out); error = 0;
        } else error = ERROR_BUSY;
        goto done;
    }
    if (client <= lll_keyboard_highest_client || lll_keyboard_last_generation == UINT32_MAX) goto done;
    error = LLL_KB_IDENTIFY(pid, expected, &process, &creation);
    if (error) goto done;
    if (!lll_keyboard_same_session(pid, &creation)) { error = ERROR_ACCESS_DENIED; goto done; }
    foreground = LLL_KB_FOREGROUND();
    if (foreground) LLL_KB_WINDOW_PID(foreground, &foreground_pid);
    if (!foreground || foreground_pid != pid || !LLL_KB_VISIBLE(foreground)) { error = ERROR_NOT_READY; goto done; }
    lease->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!lease->ready) { error = GetLastError(); goto failed_setup; }
    lease->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!lease->stop) { error = GetLastError(); goto failed_setup; }
    lease->pid = pid; lease->target = foreground; lease->process = process; process = NULL;
    lease->creation = creation; lease->client = client;
    lease->generation = ++lll_keyboard_last_generation;
    lease->state = LLL_KEYBOARD_ARMING;
    lease->terminal = LLL_KEYBOARD_REVOKED;
    memcpy(lease->mask, mask, sizeof(lease->mask));
    lease->started = lease->heartbeat = LLL_KB_NOW();
    /* Accepted ownership is recorded BEFORE a worker can register anything.
     * A lost reply can therefore always be rolled back by exact client/gen0. */
    lll_keyboard_highest_client = client;
    lll_keyboard_session_pid = pid;
    lll_keyboard_session_creation = creation;
    lease->thread = CreateThread(NULL, 0, lll_keyboard_thread, NULL, 0, NULL);
    if (!lease->thread) {
        error = GetLastError();
        lll_keyboard_retired.pid = pid; lll_keyboard_retired.client = client;
        lll_keyboard_retired.generation = lease->generation;
        goto failed_setup;
    }
    /* Do not wait on UI activation. ARMING is an accepted lease, never a
     * promise that keys are suppressed; a later explicit sample sees ACTIVE. */
    lll_keyboard_reply_locked(out);
    error = 0;
    goto done;
failed_setup:
    if (lease->process) CloseHandle(lease->process);
    if (lease->ready) CloseHandle(lease->ready);
    if (lease->stop) CloseHandle(lease->stop);
    ZeroMemory(lease, sizeof(*lease));
done:
    if (process) CloseHandle(process);
    ReleaseSRWLockExclusive(&lll_keyboard_lifecycle);
    return error;
}

DWORD lll_keyboard_snapshot(DWORD pid, uint32_t client, uint32_t generation, LLLSteamKeyboardSample *out) {
    LLLSteamKeyboardLease *lease = &lll_keyboard_lease;
    DWORD error = ERROR_NOT_FOUND;
    uint32_t state;
    if (!out || !client || !generation) return ERROR_INVALID_PARAMETER;
    ZeroMemory(out, sizeof(*out));
    AcquireSRWLockShared(&lll_keyboard_lifecycle);
    if (!lease->thread || pid != lease->pid || client != lease->client || generation != lease->generation) goto done;
    out->version = LLL_KEYBOARD_VERSION; out->generation = generation;
    state = lll_keyboard_deadline(0);
    if (state == LLL_KEYBOARD_ACTIVE) {
        if (!lll_keyboard_foreground(lease) || WaitForSingleObject(lease->process, 0) != WAIT_TIMEOUT) {
            lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
        } else {
            /* One physical read per captured key, only on an explicit active
             * sample. The high bit is current state; the low bit is ignored.
             * No engine keyboard reader is replaced or modified. */
            for (unsigned int key = 0; key < 256; ++key)
                if (lll_keyboard_bit(lease->mask, key) && (LLL_KB_ASYNC((int)key) & 0x8000))
                    out->keys[key >> 5] |= 1u << (key & 31);
            if (!lll_keyboard_foreground(lease)) {
                ZeroMemory(out->keys, sizeof(out->keys));
                lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
            } else {
                lll_keyboard_deadline(1);
            }
        }
    }
    AcquireSRWLockShared(&lll_keyboard_data);
    out->state = lease->state;
    ReleaseSRWLockShared(&lll_keyboard_data);
    if (out->state != LLL_KEYBOARD_ACTIVE) ZeroMemory(out->keys, sizeof(out->keys));
    error = 0;
done:
    ReleaseSRWLockShared(&lll_keyboard_lifecycle);
    return error;
}

/* Final fence after the service takes its single pointer sample. This does
 * not read keys or renew the heartbeat, and cannot revive an expired lease. */
uint32_t lll_keyboard_confirm(DWORD pid, uint32_t client, uint32_t generation) {
    LLLSteamKeyboardLease *lease = &lll_keyboard_lease;
    uint32_t state = LLL_KEYBOARD_FAILED;
    AcquireSRWLockShared(&lll_keyboard_lifecycle);
    if (!lease->thread || pid != lease->pid || client != lease->client || generation != lease->generation) goto done;
    state = lll_keyboard_deadline(0);
    if (state == LLL_KEYBOARD_ACTIVE && (!lll_keyboard_foreground(lease) ||
        WaitForSingleObject(lease->process, 0) != WAIT_TIMEOUT)) {
        lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
        AcquireSRWLockShared(&lll_keyboard_data);
        state = lease->state;
        ReleaseSRWLockShared(&lll_keyboard_data);
    }
done:
    ReleaseSRWLockShared(&lll_keyboard_lifecycle);
    return state;
}

DWORD lll_keyboard_release(DWORD pid, const wchar_t *expected, uint32_t client, uint32_t generation,
                           uint32_t *released_generation) {
    LLLSteamKeyboardLease *lease = &lll_keyboard_lease;
    DWORD error = ERROR_NOT_FOUND;
    HANDLE process = NULL;
    FILETIME creation;
    if (!client || !released_generation) return ERROR_INVALID_PARAMETER;
    *released_generation = 0;
    AcquireSRWLockExclusive(&lll_keyboard_lifecycle);
    /* A matching current pair is preferred over any retired acknowledgement. */
    if (lease->thread && pid == lease->pid && client == lease->client &&
        (!generation || generation == lease->generation)) {
        uint32_t owned_generation = lease->generation;
        lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
        if (!lll_keyboard_reap_locked(LLL_KEYBOARD_COMMAND_MS)) { error = ERROR_TIMEOUT; goto done; }
        *released_generation = owned_generation; error = 0; goto done;
    }
    if (pid == lll_keyboard_retired.pid && client == lll_keyboard_retired.client &&
        (!generation || generation == lll_keyboard_retired.generation)) {
        *released_generation = lll_keyboard_retired.generation; error = 0; goto done;
    }
    /* Never-owned rollback after an explicit refusal/lost request. Serialized
     * authenticated pipe requests cannot later accept this old request. This
     * acknowledgement changes neither a current lease nor the retired pair. */
    if (!generation && client > lll_keyboard_highest_client) {
        error = LLL_KB_IDENTIFY(pid, expected, &process, &creation);
        if (!error && !lll_keyboard_same_session(pid, &creation)) error = ERROR_ACCESS_DENIED;
    }
done:
    if (process) CloseHandle(process);
    ReleaseSRWLockExclusive(&lll_keyboard_lifecycle);
    return error;
}

void lll_keyboard_cancel_all(void) {
    AcquireSRWLockShared(&lll_keyboard_lifecycle);
    if (lll_keyboard_lease.thread) lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
    ReleaseSRWLockShared(&lll_keyboard_lifecycle);
}
int lll_keyboard_shutdown(void) {
    int clean;
    AcquireSRWLockExclusive(&lll_keyboard_lifecycle);
    if (lll_keyboard_lease.thread) lll_keyboard_stop_request(LLL_KEYBOARD_REVOKED, ERROR_CANCELLED);
    clean = lll_keyboard_reap_locked(LLL_KEYBOARD_COMMAND_MS);
    ReleaseSRWLockExclusive(&lll_keyboard_lifecycle);
    return clean;
}
