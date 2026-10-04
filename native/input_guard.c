/* Per-window input capture. No Lua callbacks from the window thread.
 * Does not hook another process or suppress OS shortcuts globally.
 */
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>

static HWND owner;
static WNDPROC previous;
static volatile LONG captured;
static volatile LONG wheel;
static volatile LONG keys[256];
static volatile LONG buttons[5];
static volatile LONG previous_raw[256];
static volatile LONG previous_legacy[256];

__declspec(dllexport) int mcm_policy(UINT message, UINT raw_type, int capture) {
    if (!capture) return 0;
    if (message == WM_INPUT) return raw_type == RIM_TYPEKEYBOARD || raw_type == RIM_TYPEMOUSE;
    if (message >= WM_KEYFIRST && message <= WM_KEYLAST) return 1;
    if (message >= WM_MOUSEFIRST && message <= WM_MOUSELAST) return 1;
    return 0;
}

static int keyboard_gate(UINT key, int up, int capture) {
    if (key >= 256) return capture;
    if (capture) { InterlockedExchange(&keys[key], up ? 0 : 1); return 1; }
    if (InterlockedCompareExchange(&keys[key], 0, 0)) {
        if (up) InterlockedExchange(&keys[key], 0);
        return 1;
    }
    return 0;
}

static int mouse_gate(USHORT flags, int capture) {
    int gate = capture;
    const USHORT down[5] = {RI_MOUSE_LEFT_BUTTON_DOWN,RI_MOUSE_RIGHT_BUTTON_DOWN,
        RI_MOUSE_MIDDLE_BUTTON_DOWN,RI_MOUSE_BUTTON_4_DOWN,RI_MOUSE_BUTTON_5_DOWN};
    const USHORT up[5] = {RI_MOUSE_LEFT_BUTTON_UP,RI_MOUSE_RIGHT_BUTTON_UP,
        RI_MOUSE_MIDDLE_BUTTON_UP,RI_MOUSE_BUTTON_4_UP,RI_MOUSE_BUTTON_5_UP};
    for (int i=0; i<5; ++i) {
        if (InterlockedCompareExchange(&buttons[i],0,0)) gate=1;
        if (capture && (flags & down[i])) InterlockedExchange(&buttons[i],1);
        if (flags & up[i]) InterlockedExchange(&buttons[i],0);
    }
    return gate;
}

static USHORT mouse_flags(UINT msg, WPARAM wp) {
    switch (msg) {
    case WM_LBUTTONDOWN:case WM_LBUTTONDBLCLK:return RI_MOUSE_LEFT_BUTTON_DOWN;
    case WM_LBUTTONUP:return RI_MOUSE_LEFT_BUTTON_UP;
    case WM_RBUTTONDOWN:case WM_RBUTTONDBLCLK:return RI_MOUSE_RIGHT_BUTTON_DOWN;
    case WM_RBUTTONUP:return RI_MOUSE_RIGHT_BUTTON_UP;
    case WM_MBUTTONDOWN:case WM_MBUTTONDBLCLK:return RI_MOUSE_MIDDLE_BUTTON_DOWN;
    case WM_MBUTTONUP:return RI_MOUSE_MIDDLE_BUTTON_UP;
    case WM_XBUTTONDOWN:case WM_XBUTTONDBLCLK:return HIWORD(wp)==XBUTTON1?RI_MOUSE_BUTTON_4_DOWN:RI_MOUSE_BUTTON_5_DOWN;
    case WM_XBUTTONUP:return HIWORD(wp)==XBUTTON1?RI_MOUSE_BUTTON_4_UP:RI_MOUSE_BUTTON_5_UP;
    default:return 0;
    }
}

static LRESULT CALLBACK guarded_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    int capture = hwnd==owner && InterlockedCompareExchange(&captured,0,0) && GetForegroundWindow()==owner;
    if (msg==WM_KILLFOCUS || (msg==WM_ACTIVATEAPP && !wp)) {
        InterlockedExchange(&captured,0);
        for (int i=0;i<256;++i) { InterlockedExchange(&keys[i],0); InterlockedExchange(&previous_raw[i],0); InterlockedExchange(&previous_legacy[i],0); }
        for (int i=0;i<5;++i) InterlockedExchange(&buttons[i],0);
        capture=0;
    }
    if (msg==WM_INPUT) {
        RAWINPUT raw;UINT size=sizeof raw;
        UINT read=GetRawInputData((HRAWINPUT)lp,RID_INPUT,&raw,&size,sizeof(RAWINPUTHEADER));
        if (read!=(UINT)-1 && read>=sizeof(RAWINPUTHEADER)) {
            int block=0;
            if (raw.header.dwType==RIM_TYPEKEYBOARD) {
                UINT key=raw.data.keyboard.VKey;int up=(raw.data.keyboard.Flags&RI_KEY_BREAK)!=0;
                /* Release keys that the game already saw before capture. */
                if (key<256 && up && InterlockedExchange(&previous_raw[key],0))block=0;
                else block=keyboard_gate(key,up,capture);
            }
            else if (raw.header.dwType==RIM_TYPEMOUSE) {
                if (capture && (raw.data.mouse.usButtonFlags & RI_MOUSE_WHEEL))
                    InterlockedExchangeAdd(&wheel,(SHORT)raw.data.mouse.usButtonData);
                block=mouse_gate(raw.data.mouse.usButtonFlags,capture);
            }
            if (block) {
                /* WM_INPUT foreground packets require DefWindowProc cleanup. */
                return DefWindowProcW(hwnd,msg,wp,lp);
            }
        } else if (capture) return DefWindowProcW(hwnd,msg,wp,lp);
    } else if (msg==WM_KEYDOWN || msg==WM_SYSKEYDOWN || msg==WM_KEYUP || msg==WM_SYSKEYUP) {
        UINT key=(UINT)wp;int up=msg==WM_KEYUP || msg==WM_SYSKEYUP;
        if (!(key<256 && up && InterlockedExchange(&previous_legacy[key],0)) && keyboard_gate(key,up,capture))return 0;
    } else if (msg>=WM_MOUSEFIRST && msg<=WM_MOUSELAST) {
        if (mouse_gate(mouse_flags(msg,wp),capture))return 0;
    } else if (mcm_policy(msg,99,capture))return 0;
    if (capture && msg==WM_SETCURSOR) { SetCursor(LoadCursorW(NULL,IDC_ARROW));return TRUE; }
    return CallWindowProcW(previous,hwnd,msg,wp,lp);
}

__declspec(dllexport) int mcm_install(HWND hwnd) {
    DWORD pid=0;GetWindowThreadProcessId(hwnd,&pid);
    if (!IsWindow(hwnd) || pid!=GetCurrentProcessId())return 0;
    if (owner) return owner==hwnd;
    previous=(WNDPROC)GetWindowLongPtrW(hwnd,GWLP_WNDPROC);
    if (!previous)return 0;
    /* Pin before installing a callback that other subclasses may retain. */
    HMODULE module;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        (LPCWSTR)guarded_proc,&module))return 0;
    owner=hwnd;SetLastError(0);
    LONG_PTR old=SetWindowLongPtrW(hwnd,GWLP_WNDPROC,(LONG_PTR)guarded_proc);
    if (!old && GetLastError()) {owner=NULL;previous=NULL;return 0;}
    previous=(WNDPROC)old;
    return 1;
}

__declspec(dllexport) int mcm_capture(int active) {
    if (!owner || !IsWindow(owner))return 0;
    if (active && GetForegroundWindow()!=owner)return 0;
    if (active && !InterlockedCompareExchange(&captured,0,0)) {
        /* A held gameplay mouse button cannot be released through a raw packet
         * without also forwarding its movement. Refuse acquisition until up.
         */
        const int mouse_keys[5]={VK_LBUTTON,VK_RBUTTON,VK_MBUTTON,VK_XBUTTON1,VK_XBUTTON2};
        for (int i=0;i<5;++i)if (GetAsyncKeyState(mouse_keys[i])&0x8000)return 0;
        for (int i=0;i<256;++i) {
            LONG down=(GetAsyncKeyState(i)&0x8000)?1:0;
            InterlockedExchange(&previous_raw[i],down);InterlockedExchange(&previous_legacy[i],down);
        }
    }
    if (!active || !InterlockedCompareExchange(&captured,0,0))InterlockedExchange(&wheel,0);
    InterlockedExchange(&captured,active?1:0);return 1;
}
__declspec(dllexport) int mcm_captured(void) {
    return owner && GetForegroundWindow()==owner && InterlockedCompareExchange(&captured,0,0);
}
__declspec(dllexport) void mcm_release(void) {
    InterlockedExchange(&captured,0);InterlockedExchange(&wheel,0);
    /* Keep an inert callback until held menu keys/buttons have released.
     * Its DLL is pinned; all ordinary traffic continues through previous.
     */
}

__declspec(dllexport) int mcm_wheel(void) { return (int)InterlockedExchange(&wheel,0); }
