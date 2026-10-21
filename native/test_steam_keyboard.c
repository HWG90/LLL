/* Default: offline control-flow fixtures, with every keyboard/authentication/
 * foreground seam fake. Only our own window, worker, self handle and events
 * are real. Explicit --real-register mode separately measures real, briefly
 * owned registrations and cleanup; it creates no worker or input observation.
 * Neither mode establishes physical keyboard or gameplay behavior.
 * Standalone x64 console TU: /std:c11 /O2 /GS /W4 /WX /MT, user32.lib. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static unsigned int checks;
#define CHECK(value) do { ++checks; if (!(value)) { \
    fprintf(stderr,"FAIL line %d: %s (winerror %lu)\n",__LINE__,#value,(unsigned long)GetLastError()); \
    ExitProcess(1); } } while (0)

typedef struct TestTuple { int id; UINT modifiers,key; } TestTuple;
static TestTuple test_tuples[2048];
static int test_removed[2048];
static volatile LONG test_live[2049],test_keys[256];
static volatile LONG test_registers,test_unregisters,test_reads,test_focus_reads,test_identifies;
static volatile LONG test_hooks,test_unhooks,test_failure_at,test_fake_errors,test_block_unregister,test_block_hook,test_press_after;
static volatile LONG test_register_thread;
static volatile LONG test_visible=1;
static volatile LONG64 test_clock=10000;
static PVOID volatile test_foreground_window;
static DWORD test_pid,test_creation_low=0x12345678u;
static HANDLE test_hook_seen,test_hook_gate,test_async_seen,test_unregister_seen,test_unregister_gate;
static const wchar_t test_expected[]=L"offline-keyboard-fixture.exe";
#define TEST_TARGET ((HWND)(ULONG_PTR)0x1111u)
#define TEST_FOREIGN ((HWND)(ULONG_PTR)0x2222u)

static BOOL WINAPI test_register(HWND window,int id,UINT modifiers,UINT key) {
    LONG call=InterlockedIncrement(&test_registers);
    DWORD thread=GetCurrentThreadId();
    DWORD owner=(DWORD)InterlockedCompareExchange(&test_register_thread,(LONG)thread,0);
    (void)window;
    if (owner&&owner!=thread) InterlockedIncrement(&test_fake_errors);
    if (call==InterlockedCompareExchange(&test_failure_at,0,0)) {
        SetLastError(ERROR_HOTKEY_ALREADY_REGISTERED);return FALSE;
    }
    if (call<1||call>2048||id<1||id>2048) { InterlockedIncrement(&test_fake_errors);return FALSE; }
    test_tuples[call-1].id=id;test_tuples[call-1].modifiers=modifiers;test_tuples[call-1].key=key;
    if (InterlockedExchange(&test_live[id],1)) InterlockedIncrement(&test_fake_errors);
    if (call==InterlockedCompareExchange(&test_press_after,0,0)) InterlockedExchange(&test_keys['W'],0x8000);
    return TRUE;
}
static BOOL WINAPI test_unregister(HWND window,int id) {
    LONG call;
    (void)window;
    if ((DWORD)InterlockedCompareExchange(&test_register_thread,0,0)!=GetCurrentThreadId())
        InterlockedIncrement(&test_fake_errors);
    SetEvent(test_unregister_seen);
    if (InterlockedCompareExchange(&test_block_unregister,0,0)&&
        WaitForSingleObject(test_unregister_gate,10000)!=WAIT_OBJECT_0) {
        InterlockedIncrement(&test_fake_errors);return FALSE;
    }
    call=InterlockedIncrement(&test_unregisters);
    if (call<1||call>2048||id<1||id>2048) { InterlockedIncrement(&test_fake_errors);return FALSE; }
    test_removed[call-1]=id;
    if (InterlockedExchange(&test_live[id],0)!=1) InterlockedIncrement(&test_fake_errors);
    return TRUE;
}
static SHORT WINAPI test_async(int key) {
    SHORT state;
    InterlockedIncrement(&test_reads);
    if (key<0||key>255) { InterlockedIncrement(&test_fake_errors);return 0; }
    state=(SHORT)InterlockedCompareExchange(&test_keys[key],0,0);
    SetEvent(test_async_seen);return state;
}
static HWND WINAPI test_foreground(void) {
    InterlockedIncrement(&test_focus_reads);
    return (HWND)InterlockedCompareExchangePointer(&test_foreground_window,NULL,NULL);
}
static DWORD WINAPI test_window_pid(HWND window,LPDWORD pid) {
    if (pid) *pid=window==TEST_TARGET?test_pid:test_pid+1;
    return 1;
}
static BOOL WINAPI test_is_visible(HWND window) {
    return window==TEST_TARGET&&InterlockedCompareExchange(&test_visible,0,0)!=0;
}
static ULONGLONG WINAPI test_now(void) {
    return (ULONGLONG)InterlockedCompareExchange64(&test_clock,0,0);
}
static HWINEVENTHOOK WINAPI test_hook(DWORD minimum,DWORD maximum,HMODULE module,
                                     WINEVENTPROC callback,DWORD pid,DWORD thread,DWORD flags) {
    if (minimum!=EVENT_SYSTEM_FOREGROUND||maximum!=EVENT_SYSTEM_FOREGROUND||module||!callback||pid||thread||
        flags!=WINEVENT_OUTOFCONTEXT) InterlockedIncrement(&test_fake_errors);
    InterlockedIncrement(&test_hooks);SetEvent(test_hook_seen);
    if (InterlockedCompareExchange(&test_block_hook,0,0)&&
        WaitForSingleObject(test_hook_gate,10000)!=WAIT_OBJECT_0) {
        InterlockedIncrement(&test_fake_errors);return NULL;
    }
    return (HWINEVENTHOOK)(ULONG_PTR)1u;
}
static BOOL WINAPI test_unhook(HWINEVENTHOOK hook) {
    if (hook!=(HWINEVENTHOOK)(ULONG_PTR)1u) InterlockedIncrement(&test_fake_errors);
    InterlockedIncrement(&test_unhooks);return TRUE;
}
static DWORD test_identify(DWORD pid,const wchar_t *expected,HANDLE *process,FILETIME *creation) {
    InterlockedIncrement(&test_identifies);*process=NULL;
    if (pid!=test_pid||!expected||wcscmp(expected,test_expected)) return ERROR_ACCESS_DENIED;
    if (!DuplicateHandle(GetCurrentProcess(),GetCurrentProcess(),GetCurrentProcess(),process,
                         SYNCHRONIZE,FALSE,0)) return GetLastError();
    creation->dwHighDateTime=0x01234567u;creation->dwLowDateTime=test_creation_low;
    return 0;
}
#define LLL_KB_REGISTER test_register
#define LLL_KB_UNREGISTER test_unregister
#define LLL_KB_ASYNC test_async
#define LLL_KB_FOREGROUND test_foreground
#define LLL_KB_WINDOW_PID test_window_pid
#define LLL_KB_VISIBLE test_is_visible
#define LLL_KB_NOW test_now
#define LLL_KB_HOOK test_hook
#define LLL_KB_UNHOOK test_unhook
#define LLL_KB_IDENTIFY test_identify
#include "steam_keyboard.c"

_Static_assert(sizeof(LLLSteamKeyboardReply)==48,"keyboard reply ABI");
_Static_assert(sizeof(LLLSteamKeyboardSample)==44,"keyboard sample ABI");

static void wait_event(HANDLE event) { CHECK(WaitForSingleObject(event,5000)==WAIT_OBJECT_0); }
static void key_bit(uint32_t mask[8],unsigned int key) { mask[key>>5]|=1u<<(key&31); }
static int zero_keys(const uint32_t keys[8]) {
    uint32_t any=0;for (unsigned int i=0;i<8;++i) any|=keys[i];return any==0;
}
static uint32_t current_state(void) {
    uint32_t state;AcquireSRWLockShared(&lll_keyboard_data);state=lll_keyboard_lease.state;
    ReleaseSRWLockShared(&lll_keyboard_data);return state;
}
static void reset_fixture(void) {
    CHECK(lll_keyboard_shutdown());
    CHECK(!lll_keyboard_lease.thread&&!lll_keyboard_lease.ready&&!lll_keyboard_lease.stop&&!lll_keyboard_lease.process);
    CHECK(!InterlockedCompareExchange(&test_fake_errors,0,0));
    for (unsigned int i=0;i<2049;++i) CHECK(!test_live[i]);
    ZeroMemory(&lll_keyboard_retired,sizeof(lll_keyboard_retired));
    lll_keyboard_highest_client=lll_keyboard_last_generation=0;lll_keyboard_session_pid=0;
    ZeroMemory(&lll_keyboard_session_creation,sizeof(lll_keyboard_session_creation));
    ZeroMemory(test_tuples,sizeof(test_tuples));ZeroMemory(test_removed,sizeof(test_removed));
    ZeroMemory((void *)test_keys,sizeof(test_keys));
    test_registers=test_unregisters=test_reads=test_focus_reads=test_identifies=0;
    test_hooks=test_unhooks=test_failure_at=test_block_unregister=test_block_hook=test_press_after=test_register_thread=0;
    test_visible=1;test_creation_low=0x12345678u;
    InterlockedExchange64(&test_clock,10000);
    InterlockedExchangePointer(&test_foreground_window,TEST_TARGET);
    ResetEvent(test_hook_seen);ResetEvent(test_hook_gate);ResetEvent(test_async_seen);
    ResetEvent(test_unregister_seen);ResetEvent(test_unregister_gate);
}
static void direct_begin(const uint32_t mask[8]) {
    reset_fixture();
    lll_keyboard_lease.target=TEST_TARGET;lll_keyboard_lease.window=TEST_TARGET;lll_keyboard_lease.pid=test_pid;
    lll_keyboard_lease.state=LLL_KEYBOARD_ARMING;lll_keyboard_lease.terminal=LLL_KEYBOARD_REVOKED;
    lll_keyboard_lease.stop=CreateEventW(NULL,TRUE,FALSE,NULL);CHECK(lll_keyboard_lease.stop!=NULL);
    CHECK(DuplicateHandle(GetCurrentProcess(),GetCurrentProcess(),GetCurrentProcess(),
                          &lll_keyboard_lease.process,SYNCHRONIZE,FALSE,0));
    memcpy(lll_keyboard_lease.mask,mask,sizeof(lll_keyboard_lease.mask));
}
static void direct_end(unsigned int successful) {
    CHECK(lll_keyboard_unregister_worker(&lll_keyboard_lease));
    CHECK(lll_keyboard_lease.registration_count==0);
    CHECK((unsigned int)test_unregisters==successful);
    for (unsigned int i=0;i<successful;++i) CHECK(test_removed[i]==test_tuples[successful-1-i].id);
    for (unsigned int i=0;i<2049;++i) CHECK(!test_live[i]);
    CHECK(CloseHandle(lll_keyboard_lease.stop));CHECK(CloseHandle(lll_keyboard_lease.process));
    ZeroMemory(&lll_keyboard_lease,sizeof(lll_keyboard_lease));
    CHECK(!test_fake_errors);
}
static LLLSteamKeyboardReply start_worker(uint32_t client,const uint32_t mask[8],int held) {
    LLLSteamKeyboardReply reply;
    /* A new owned worker may have a new ID; each lease's unregisters must
     * still run on the exact thread that made that lease's first register. */
    InterlockedExchange(&test_register_thread,0);
    if (held) InterlockedExchange(&test_keys['W'],0x8000);
    CHECK(lll_keyboard_acquire(test_pid,test_expected,client,mask,&reply)==0);
    CHECK(reply.version==1&&reply.client==client&&reply.generation!=0);
    wait_event(test_hook_seen);
    if (held) { wait_event(test_async_seen);CHECK(current_state()==LLL_KEYBOARD_ARMING);CHECK(test_registers==0); }
    else { wait_event(lll_keyboard_lease.ready);CHECK(current_state()==LLL_KEYBOARD_ACTIVE); }
    return reply;
}
static void finish_worker(const LLLSteamKeyboardReply *reply) {
    uint32_t released=0;
    CHECK(lll_keyboard_release(test_pid,test_expected,reply->client,reply->generation,&released)==0);
    CHECK(released==reply->generation);
    CHECK(!lll_keyboard_lease.thread&&!lll_keyboard_lease.ready&&!lll_keyboard_lease.stop&&!lll_keyboard_lease.process);
    CHECK(test_hooks==test_unhooks&&test_registers==test_unregisters);
    CHECK(!test_fake_errors);
}

static void test_masks_and_tuples(void) {
    uint32_t mask[8]={0};unsigned int allowed=0;
    const unsigned int excluded[]={VK_LBUTTON,VK_RBUTTON,VK_MBUTTON,VK_XBUTTON1,VK_XBUTTON2,
                                   VK_LWIN,VK_RWIN,VK_F12,VK_SNAPSHOT,0,7,0x0a,0x0b,0xff,
                                   0x3a,0x3b,0x3c,0x3d,0x3e,0x3f,0x40};
    const uint32_t expected_allowed[8]={0x081f3300u,0x03ffe1ffu,0x27fffffeu,0xf7ffffffu,
                                       0x000300ffu,0xfc00003fu,0xf8000001u,0x00000004u};
    const unsigned int groups[3][3]={{VK_SHIFT,VK_LSHIFT,VK_RSHIFT},{VK_CONTROL,VK_LCONTROL,VK_RCONTROL},
                                   {VK_MENU,VK_LMENU,VK_RMENU}};
    CHECK(!lll_keyboard_mask_valid(NULL));CHECK(!lll_keyboard_mask_valid(mask));
    for (unsigned int key=0;key<256;++key) {
        if (lll_keyboard_bit(lll_keyboard_allowed,key)) {
            ++allowed;
            if (!((key>=16&&key<=18)||(key>=160&&key<=165))) {
                key_bit(mask,key);CHECK(lll_keyboard_mask_valid(mask));ZeroMemory(mask,sizeof(mask));
            }
        }
        else { key_bit(mask,key);CHECK(!lll_keyboard_mask_valid(mask));ZeroMemory(mask,sizeof(mask)); }
    }
    for (unsigned int i=0;i<sizeof(excluded)/sizeof(excluded[0]);++i)
        CHECK(!lll_keyboard_bit(lll_keyboard_allowed,excluded[i]));
    CHECK(allowed==119);CHECK(!memcmp(lll_keyboard_allowed,expected_allowed,sizeof(expected_allowed)));
    CHECK(lll_keyboard_mask_valid(lll_keyboard_allowed));
    for (unsigned int group=0;group<3;++group) for (unsigned int combination=1;combination<8;++combination) {
        ZeroMemory(mask,sizeof(mask));key_bit(mask,'W');
        for (unsigned int bit=0;bit<3;++bit) if (combination&(1u<<bit)) key_bit(mask,groups[group][bit]);
        CHECK(lll_keyboard_mask_valid(mask)==(combination==7));
    }
    CHECK(!lll_keyboard_tuple(VK_TAB,MOD_ALT));CHECK(!lll_keyboard_tuple(VK_ESCAPE,MOD_CONTROL));
    CHECK(!lll_keyboard_tuple(VK_F4,MOD_ALT));CHECK(!lll_keyboard_tuple(VK_RETURN,MOD_ALT));
    CHECK(!lll_keyboard_tuple(VK_SPACE,MOD_ALT));CHECK(!lll_keyboard_tuple(VK_DELETE,MOD_ALT|MOD_CONTROL));
    for (unsigned int key=VK_LSHIFT;key<=VK_RMENU;++key) CHECK(!lll_keyboard_tuple(key,0));
    for (unsigned int variant=0;variant<8;++variant) CHECK(lll_keyboard_tuple('W',lll_keyboard_modifiers(variant)));
}
static void test_registration_rollback(void) {
    uint32_t mask[8]={0};unsigned int full_count;
    key_bit(mask,'W');
    /* Exhaust every possible Nth failure for this key's eight modifier tuples. */
    for (LONG nth=1;nth<=8;++nth) {
        direct_begin(mask);test_failure_at=nth;
        CHECK(!lll_keyboard_register_worker(&lll_keyboard_lease));
        CHECK(test_registers==nth&&lll_keyboard_lease.registration_count==(unsigned int)(nth-1));
        CHECK(current_state()==LLL_KEYBOARD_CLOSING&&lll_keyboard_lease.terminal==LLL_KEYBOARD_FAILED);
        direct_end((unsigned int)(nth-1));
    }
    direct_begin(lll_keyboard_allowed);CHECK(lll_keyboard_register_worker(&lll_keyboard_lease));
    full_count=lll_keyboard_lease.registration_count;CHECK(full_count==880);
    for (unsigned int i=0;i<full_count;++i) {
        const TestTuple *tuple=&test_tuples[i];UINT modifiers=tuple->modifiers&~MOD_NOREPEAT;
        CHECK(tuple->modifiers&MOD_NOREPEAT);CHECK(!(tuple->modifiers&~(MOD_SHIFT|MOD_CONTROL|MOD_ALT|MOD_NOREPEAT)));
        CHECK(lll_keyboard_bit(lll_keyboard_allowed,tuple->key));CHECK(!(tuple->key>=160&&tuple->key<=165));
        CHECK(lll_keyboard_tuple(tuple->key,modifiers));
    }
    direct_end(full_count);
    /* Roll back a long prefix, including its final successful tuple. */
    direct_begin(lll_keyboard_allowed);test_failure_at=(LONG)full_count;
    CHECK(!lll_keyboard_register_worker(&lll_keyboard_lease));direct_end(full_count-1);
    /* Also exercise the actual worker's failure cleanup, not just the core. */
    reset_fixture();test_failure_at=4;
    { LLLSteamKeyboardReply reply;uint32_t released;
      CHECK(lll_keyboard_acquire(test_pid,test_expected,1,mask,&reply)==0);
      wait_event(lll_keyboard_lease.thread);CHECK(current_state()==LLL_KEYBOARD_FAILED);
      CHECK(test_registers==4&&test_unregisters==3&&test_hooks==1&&test_unhooks==1);
      CHECK(lll_keyboard_release(test_pid,test_expected,1,reply.generation,&released)==0);
      CHECK(released==reply.generation&&!lll_keyboard_lease.thread); }
}
static void test_identity_and_ownership(void) {
    uint32_t mask[8]={0},other[8]={0},released;LLLSteamKeyboardReply reply,next,repeat;
    LLLSteamKeyboardSample sample;LONG registrations,reads,identifies;HANDLE owned_thread;
    key_bit(mask,'W');key_bit(other,'A');reset_fixture();
    CHECK(lll_keyboard_acquire(test_pid,L"wrong.exe",1,mask,&reply)==ERROR_ACCESS_DENIED);
    CHECK(!lll_keyboard_lease.thread&&test_registers==0);
    reply=start_worker(10,mask,0);owned_thread=lll_keyboard_lease.thread;
    registrations=test_registers;identifies=test_identifies;
    CHECK(lll_keyboard_acquire(test_pid,test_expected,10,mask,&repeat)==0);
    CHECK(repeat.generation==reply.generation&&test_identifies==identifies&&test_registers==registrations);
    CHECK(lll_keyboard_acquire(test_pid,test_expected,11,mask,&repeat)==ERROR_BUSY);
    CHECK(lll_keyboard_acquire(test_pid,test_expected,10,other,&repeat)==ERROR_BUSY);
    CHECK(lll_keyboard_acquire(test_pid+1,test_expected,10,mask,&repeat)==ERROR_BUSY);
    reads=test_reads;
    CHECK(lll_keyboard_snapshot(test_pid,11,reply.generation,&sample)==ERROR_NOT_FOUND);
    CHECK(lll_keyboard_snapshot(test_pid+1,10,reply.generation,&sample)==ERROR_NOT_FOUND);
    CHECK(lll_keyboard_snapshot(test_pid,10,reply.generation+1,&sample)==ERROR_NOT_FOUND);
    CHECK(lll_keyboard_snapshot(test_pid,10,0,&sample)==ERROR_INVALID_PARAMETER);
    CHECK(lll_keyboard_release(test_pid,test_expected,10,reply.generation+1,&released)==ERROR_NOT_FOUND);
    CHECK(released==0&&test_reads==reads);
    CHECK(lll_keyboard_release(test_pid,test_expected,11,0,&released)==0&&released==0);
    CHECK(lll_keyboard_highest_client==10&&lll_keyboard_lease.thread==owned_thread&&current_state()==LLL_KEYBOARD_ACTIVE);
    CHECK(lll_keyboard_release(test_pid,L"wrong.exe",12,0,&released)==ERROR_ACCESS_DENIED);
    /* gen0 is rollback of this exact accepted client, never an arbitrary lease. */
    CHECK(lll_keyboard_release(test_pid,test_expected,10,0,&released)==0&&released==reply.generation);
    CHECK(!lll_keyboard_lease.thread&&test_registers==test_unregisters);
    CHECK(lll_keyboard_release(test_pid,test_expected,10,reply.generation,&released)==0&&released==reply.generation);
    ++test_creation_low;
    CHECK(lll_keyboard_acquire(test_pid,test_expected,11,mask,&repeat)==ERROR_ACCESS_DENIED);
    --test_creation_low;
    ResetEvent(test_hook_seen);next=start_worker(11,mask,0);owned_thread=lll_keyboard_lease.thread;
    CHECK(next.generation==reply.generation+1);
    CHECK(lll_keyboard_release(test_pid,test_expected,10,reply.generation,&released)==0);
    CHECK(lll_keyboard_lease.thread==owned_thread&&current_state()==LLL_KEYBOARD_ACTIVE);
    finish_worker(&next);
    CHECK(lll_keyboard_release(test_pid,test_expected,10,reply.generation,&released)==ERROR_NOT_FOUND);
    CHECK(lll_keyboard_release(test_pid,test_expected,10,0,&released)==ERROR_NOT_FOUND);
    CHECK(lll_keyboard_acquire(test_pid,test_expected,10,mask,&repeat)==ERROR_INVALID_PARAMETER);
}
static void test_counter_limits(void) {
    uint32_t mask[8]={0},released=0;LLLSteamKeyboardReply reply,refused;LONG identifies;
    key_bit(mask,'W');reset_fixture();lll_keyboard_last_generation=UINT32_MAX-1;
    reply=start_worker(1,mask,0);CHECK(reply.generation==UINT32_MAX);finish_worker(&reply);
    identifies=test_identifies;
    CHECK(lll_keyboard_acquire(test_pid,test_expected,2,mask,&refused)==ERROR_INVALID_PARAMETER);
    CHECK(lll_keyboard_last_generation==UINT32_MAX&&!lll_keyboard_lease.thread&&test_identifies==identifies);
    reset_fixture();reply=start_worker(UINT32_MAX,mask,0);CHECK(reply.client==UINT32_MAX);finish_worker(&reply);
    identifies=test_identifies;
    CHECK(lll_keyboard_acquire(test_pid,test_expected,1,mask,&refused)==ERROR_INVALID_PARAMETER);
    CHECK(lll_keyboard_acquire(test_pid,test_expected,UINT32_MAX,mask,&refused)==ERROR_INVALID_PARAMETER);
    CHECK(lll_keyboard_release(test_pid,test_expected,1,0,&released)==ERROR_NOT_FOUND&&released==0);
    CHECK(lll_keyboard_highest_client==UINT32_MAX&&!lll_keyboard_lease.thread&&test_identifies==identifies);
}
static void test_press_during_registration(void) {
    uint32_t mask[8]={0};const LONG points[]={1,8};
    key_bit(mask,'W');
    for (unsigned int i=0;i<sizeof(points)/sizeof(points[0]);++i) {
        LLLSteamKeyboardReply reply;uint32_t released=0;
        reset_fixture();test_press_after=points[i];
        CHECK(lll_keyboard_acquire(test_pid,test_expected,1,mask,&reply)==0);
        CHECK(reply.state!=LLL_KEYBOARD_ACTIVE);
        wait_event(lll_keyboard_lease.ready);CHECK(current_state()==LLL_KEYBOARD_FAILED);
        wait_event(lll_keyboard_lease.thread);
        CHECK(lll_keyboard_lease.error==ERROR_BUSY&&lll_keyboard_lease.registration_count==0);
        CHECK(test_registers==8&&test_unregisters==8&&test_hooks==1&&test_unhooks==1);
        CHECK(lll_keyboard_confirm(test_pid,1,reply.generation)==LLL_KEYBOARD_FAILED);
        for (unsigned int id=0;id<2049;++id) CHECK(!test_live[id]);
        InterlockedExchange(&test_keys['W'],0);
        CHECK(lll_keyboard_release(test_pid,test_expected,1,reply.generation,&released)==0&&released==reply.generation);
        CHECK(!lll_keyboard_lease.thread&&!test_fake_errors);
    }
}
static void test_held_and_expiry(void) {
    uint32_t mask[8]={0};LLLSteamKeyboardReply reply;LLLSteamKeyboardSample sample;
    LONG registrations,reads;ULONGLONG heartbeat;
    key_bit(mask,'W');reset_fixture();reply=start_worker(1,mask,1);
    InterlockedExchange64(&test_clock,10100);InterlockedExchange(&test_keys['W'],0);
    CHECK(PostMessageW(lll_keyboard_lease.window,WM_NULL,0,0));wait_event(lll_keyboard_lease.ready);
    CHECK(current_state()==LLL_KEYBOARD_ACTIVE&&test_registers==8);registrations=test_registers;
    InterlockedExchange(&test_keys['W'],0x8001);InterlockedExchange(&test_keys['A'],1);
    reads=test_reads;
    for (unsigned int i=0;i<8;++i) {
        CHECK(lll_keyboard_snapshot(test_pid,1,reply.generation,&sample)==0&&sample.state==LLL_KEYBOARD_ACTIVE);
        CHECK(lll_keyboard_bit(sample.keys,'W')&&!lll_keyboard_bit(sample.keys,'A'));
    }
    CHECK(test_reads-reads==8&&test_registers==registrations&&test_unregisters==0);
    InterlockedExchange(&test_keys['W'],1);reads=test_reads;
    CHECK(lll_keyboard_snapshot(test_pid,1,reply.generation,&sample)==0&&sample.state==LLL_KEYBOARD_ACTIVE);
    CHECK(zero_keys(sample.keys)&&test_reads-reads==1);
    heartbeat=lll_keyboard_lease.heartbeat;reads=test_reads;
    InterlockedExchange64(&test_clock,(LONG64)(heartbeat+100));
    CHECK(lll_keyboard_confirm(test_pid,1,reply.generation)==LLL_KEYBOARD_ACTIVE);
    CHECK(test_reads==reads&&lll_keyboard_lease.heartbeat==heartbeat);
    InterlockedExchange64(&test_clock,(LONG64)(heartbeat+LLL_KEYBOARD_TTL_MS));
    CHECK(lll_keyboard_snapshot(test_pid,1,reply.generation,&sample)==0);
    CHECK(sample.state!=LLL_KEYBOARD_ACTIVE&&zero_keys(sample.keys)&&test_reads==reads);
    CHECK(lll_keyboard_lease.heartbeat==heartbeat);
    wait_event(lll_keyboard_lease.thread);
    CHECK(current_state()==LLL_KEYBOARD_REVOKED&&lll_keyboard_lease.error==ERROR_TIMEOUT);
    InterlockedExchange64(&test_clock,(LONG64)(heartbeat+LLL_KEYBOARD_TTL_MS+100));
    CHECK(lll_keyboard_snapshot(test_pid,1,reply.generation,&sample)==0&&sample.state==LLL_KEYBOARD_REVOKED);
    CHECK(zero_keys(sample.keys)&&test_reads==reads&&test_registers==registrations);
    finish_worker(&reply);
    /* An initially held key becoming released exactly at the deadline cannot arm. */
    reset_fixture();InterlockedExchange(&test_block_hook,1);InterlockedExchange(&test_keys['W'],0x8000);
    CHECK(lll_keyboard_acquire(test_pid,test_expected,1,mask,&reply)==0);wait_event(test_hook_seen);
    CHECK(current_state()==LLL_KEYBOARD_ARMING&&test_registers==0);
    InterlockedExchange64(&test_clock,10000+LLL_KEYBOARD_ARM_MS);InterlockedExchange(&test_keys['W'],0);
    CHECK(SetEvent(test_hook_gate));wait_event(lll_keyboard_lease.thread);
    CHECK(current_state()==LLL_KEYBOARD_FAILED&&lll_keyboard_lease.error==ERROR_TIMEOUT&&test_registers==0);
    finish_worker(&reply);
    /* The final pointer fence independently revokes at the same exact TTL. */
    reset_fixture();reply=start_worker(1,mask,0);reads=test_reads;heartbeat=lll_keyboard_lease.heartbeat;
    InterlockedExchange64(&test_clock,(LONG64)(heartbeat+LLL_KEYBOARD_TTL_MS));
    CHECK(lll_keyboard_confirm(test_pid,1,reply.generation)!=LLL_KEYBOARD_ACTIVE);
    CHECK(test_reads==reads&&lll_keyboard_lease.heartbeat==heartbeat);finish_worker(&reply);
}
static void test_full_preset_sample(void) {
    LLLSteamKeyboardReply reply;LLLSteamKeyboardSample sample;LONG reads,registrations;
    reset_fixture();reply=start_worker(1,lll_keyboard_allowed,0);reads=test_reads;registrations=test_registers;
    InterlockedExchange(&test_keys['W'],0x8001);InterlockedExchange(&test_keys['A'],1);
    CHECK(lll_keyboard_snapshot(test_pid,1,reply.generation,&sample)==0&&sample.state==LLL_KEYBOARD_ACTIVE);
    CHECK(test_reads-reads==119&&test_registers==registrations);
    CHECK(lll_keyboard_bit(sample.keys,'W')&&!lll_keyboard_bit(sample.keys,'A'));finish_worker(&reply);
}
static void test_obsolete_deadline(void) {
    uint32_t mask[8]={0};LONG reads;
    key_bit(mask,'W');direct_begin(mask);CHECK(lll_keyboard_register_worker(&lll_keyboard_lease));reads=test_reads;
    /* A snapshot renews just before the worker's previously computed deadline.
     * At that old deadline the same locked helper must preserve the fresh lease. */
    InterlockedExchange64(&test_clock,11999);CHECK(lll_keyboard_deadline(1)==LLL_KEYBOARD_ACTIVE);
    CHECK(lll_keyboard_lease.heartbeat==11999);
    InterlockedExchange64(&test_clock,12000);CHECK(lll_keyboard_deadline(0)==LLL_KEYBOARD_ACTIVE);
    CHECK(WaitForSingleObject(lll_keyboard_lease.stop,0)==WAIT_TIMEOUT&&test_reads==reads);
    InterlockedExchange64(&test_clock,13999);CHECK(lll_keyboard_deadline(1)==LLL_KEYBOARD_CLOSING);
    CHECK(lll_keyboard_lease.heartbeat==11999&&WaitForSingleObject(lll_keyboard_lease.stop,0)==WAIT_OBJECT_0);
    InterlockedExchange64(&test_clock,14000);CHECK(lll_keyboard_deadline(1)==LLL_KEYBOARD_CLOSING);
    CHECK(lll_keyboard_lease.heartbeat==11999&&test_reads==reads);direct_end(8);
}
static void test_focus_revocation(void) {
    uint32_t mask[8]={0};LLLSteamKeyboardReply reply;LLLSteamKeyboardSample sample;LONG reads;
    key_bit(mask,'W');reset_fixture();reply=start_worker(1,mask,0);reads=test_reads;
    InterlockedExchangePointer(&test_foreground_window,TEST_FOREIGN);
    CHECK(lll_keyboard_snapshot(test_pid,1,reply.generation,&sample)==0);
    CHECK(sample.state!=LLL_KEYBOARD_ACTIVE&&zero_keys(sample.keys)&&test_reads==reads);
    wait_event(lll_keyboard_lease.thread);InterlockedExchangePointer(&test_foreground_window,TEST_TARGET);
    CHECK(lll_keyboard_confirm(test_pid,1,reply.generation)==LLL_KEYBOARD_REVOKED);
    CHECK(test_registers==8&&test_unregisters==8);finish_worker(&reply);
    /* Direct worker-core callback test: unregister immediately and only once. */
    direct_begin(mask);CHECK(lll_keyboard_register_worker(&lll_keyboard_lease));
    lll_keyboard_foreground_event(NULL,EVENT_SYSTEM_FOREGROUND,TEST_TARGET,0,0,0,0);
    CHECK(test_unregisters==0&&current_state()==LLL_KEYBOARD_ACTIVE);
    lll_keyboard_foreground_event(NULL,EVENT_SYSTEM_FOREGROUND,TEST_FOREIGN,0,0,0,0);
    CHECK(test_unregisters==8&&lll_keyboard_lease.registration_count==0&&current_state()==LLL_KEYBOARD_CLOSING);
    CHECK(WaitForSingleObject(lll_keyboard_lease.stop,0)==WAIT_OBJECT_0);
    lll_keyboard_foreground_event(NULL,EVENT_SYSTEM_FOREGROUND,TEST_FOREIGN,0,0,0,0);
    CHECK(test_unregisters==8);direct_end(8);
}
static DWORD WINAPI test_shutdown_thread(void *result) {
    *(int *)result=lll_keyboard_shutdown();return 0;
}
static void test_retirement_and_handles(void) {
    uint32_t mask[8]={0};LLLSteamKeyboardReply reply,other;HANDLE worker,ready,stop,process,shutdown_thread;
    DWORD baseline=0,after=0;int shutdown_result=0;uint32_t released=UINT32_MAX;ULONGLONG begun,elapsed;
    key_bit(mask,'W');reset_fixture();reply=start_worker(1,mask,0);
    worker=lll_keyboard_lease.thread;ready=lll_keyboard_lease.ready;stop=lll_keyboard_lease.stop;process=lll_keyboard_lease.process;
    InterlockedExchange(&test_block_unregister,1);lll_keyboard_cancel_all();wait_event(test_unregister_seen);
    CHECK(WaitForSingleObject(worker,0)==WAIT_TIMEOUT);
    AcquireSRWLockExclusive(&lll_keyboard_lifecycle);CHECK(!lll_keyboard_reap_locked(0));
    ReleaseSRWLockExclusive(&lll_keyboard_lifecycle);
    CHECK(lll_keyboard_lease.thread==worker&&lll_keyboard_lease.ready==ready&&lll_keyboard_lease.stop==stop&&lll_keyboard_lease.process==process);
    begun=GetTickCount64();
    CHECK(lll_keyboard_release(test_pid,test_expected,reply.client,reply.generation,&released)==ERROR_TIMEOUT);
    elapsed=GetTickCount64()-begun;CHECK(elapsed>=900&&elapsed<5000&&released==0);
    CHECK(lll_keyboard_lease.thread==worker&&lll_keyboard_lease.ready==ready&&lll_keyboard_lease.stop==stop&&lll_keyboard_lease.process==process);
    CHECK(lll_keyboard_lease.client==reply.client&&lll_keyboard_lease.generation==reply.generation);
    CHECK(WaitForSingleObject(worker,0)==WAIT_TIMEOUT);
    CHECK(lll_keyboard_acquire(test_pid,test_expected,2,mask,&other)==ERROR_BUSY);
    CHECK(SetEvent(test_unregister_gate));wait_event(worker);finish_worker(&reply);
    reset_fixture();reply=start_worker(1,mask,0);InterlockedExchange(&test_block_unregister,1);
    shutdown_thread=CreateThread(NULL,0,test_shutdown_thread,&shutdown_result,0,NULL);CHECK(shutdown_thread!=NULL);
    wait_event(test_unregister_seen);CHECK(WaitForSingleObject(shutdown_thread,0)==WAIT_TIMEOUT);
    CHECK(lll_keyboard_lease.thread&&lll_keyboard_lease.ready&&lll_keyboard_lease.stop&&lll_keyboard_lease.process);
    CHECK(SetEvent(test_unregister_gate));wait_event(shutdown_thread);CHECK(CloseHandle(shutdown_thread));
    CHECK(shutdown_result==1&&!lll_keyboard_lease.thread&&!lll_keyboard_lease.ready&&!lll_keyboard_lease.stop&&!lll_keyboard_lease.process);
    /* Warm window/message initialization before comparing per-job handle use. */
    reset_fixture();reply=start_worker(1,mask,0);finish_worker(&reply);
    CHECK(GetProcessHandleCount(GetCurrentProcess(),&baseline));
    for (uint32_t client=2;client<18;++client) {
        LLLSteamKeyboardSample sample;LONG registrations;
        ResetEvent(test_hook_seen);reply=start_worker(client,mask,0);registrations=test_registers;
        CHECK(lll_keyboard_snapshot(test_pid,client,reply.generation,&sample)==0&&sample.state==LLL_KEYBOARD_ACTIVE);
        CHECK(test_registers==registrations);finish_worker(&reply);
    }
    CHECK(GetProcessHandleCount(GetCurrentProcess(),&after));CHECK(after==baseline);
}

/* Explicit own-window registration-capacity measurement. Never called by the
 * default fixture path. The reservation deadline is checked before each API
 * call; an individual Windows call cannot be preempted by this fixture. */
static int test_real_registration(void) {
    const wchar_t name[]=L"LLLSteamKeyboardReservationFixture";
    HINSTANCE instance=GetModuleHandleW(NULL);WNDCLASSW type={0};HWND window=NULL;
    int ids[LLL_KEYBOARD_MAX_TUPLES];unsigned int successful=0,attempts=0,unregister_calls=0,unregister_failures=0;
    unsigned int failure_key=0,failure_modifiers=0;int failure_id=0;
    DWORD setup_error=0,registration_error=0,cleanup_error=0;
    ULONGLONG opened=GetTickCount64(),begun=0,reservation_ms=0,cleanup_begun,cleanup_ms,total_ms;
    BOOL owns_class=FALSE,registration_failed=FALSE,budget_exhausted=FALSE,cleanup_ok=TRUE,complete;
    type.hInstance=instance;type.lpfnWndProc=DefWindowProcW;type.lpszClassName=name;
    if (!RegisterClassW(&type)) { setup_error=GetLastError();goto cleanup; }
    owns_class=TRUE;
    window=CreateWindowExW(0,name,L"",0,0,0,0,0,HWND_MESSAGE,NULL,instance,NULL);
    if (!window) { setup_error=GetLastError();goto cleanup; }
    begun=GetTickCount64();
    for (unsigned int key=0;key<256&&!registration_failed&&!budget_exhausted;++key) {
        if (!lll_keyboard_bit(lll_keyboard_allowed,key)||(key>=160&&key<=165)) continue;
        for (unsigned int variant=0;variant<8;++variant) {
            unsigned int modifiers=lll_keyboard_modifiers(variant);int id=1+(int)(key*8+variant);
            if (!lll_keyboard_tuple(key,modifiers)) continue;
            if (GetTickCount64()-begun>=120) { budget_exhausted=TRUE;break; }
            ++attempts;
            if (!RegisterHotKey(window,id,modifiers|MOD_NOREPEAT,key)) {
                registration_error=GetLastError();registration_failed=TRUE;
                failure_key=key;failure_modifiers=modifiers|MOD_NOREPEAT;failure_id=id;break;
            }
            ids[successful++]=id;
        }
    }
    reservation_ms=GetTickCount64()-begun;
    if (reservation_ms>=120) budget_exhausted=TRUE;
cleanup:
    cleanup_begun=GetTickCount64();
    for (unsigned int remaining=successful;remaining>0;--remaining) {
        ++unregister_calls;
        if (!UnregisterHotKey(window,ids[remaining-1])) {
            DWORD error=GetLastError();++unregister_failures;cleanup_ok=FALSE;
            if (!cleanup_error) cleanup_error=error;
        }
    }
    if (window&&!DestroyWindow(window)) {
        DWORD error=GetLastError();cleanup_ok=FALSE;if (!cleanup_error) cleanup_error=error;
    }
    if (owns_class&&!UnregisterClassW(name,instance)) {
        DWORD error=GetLastError();cleanup_ok=FALSE;if (!cleanup_error) cleanup_error=error;
    }
    cleanup_ms=GetTickCount64()-cleanup_begun;total_ms=GetTickCount64()-opened;
    complete=owns_class&&window&&!setup_error&&!registration_failed&&!budget_exhausted&&successful==880&&cleanup_ok;
    printf("{\"mode\":\"real-register\",\"complete\":%s,\"allowed_keys\":119,\"expected_tuples\":880,"
           "\"attempts\":%u,\"registered\":%u,\"registration_failed\":%s,\"setup_error\":%lu,"
           "\"failure_vk\":%u,\"failure_modifiers\":%u,\"failure_id\":%d,\"registration_error\":%lu,"
           "\"reservation_budget_ms\":120,\"budget_exhausted\":%s,\"reservation_ms\":%llu,"
           "\"unregister_calls\":%u,\"unregister_failures\":%u,\"cleanup_ok\":%s,\"cleanup_error\":%lu,"
           "\"cleanup_ms\":%llu,\"total_ms\":%llu}\n",
           complete?"true":"false",attempts,successful,registration_failed?"true":"false",(unsigned long)setup_error,
           failure_key,failure_modifiers,failure_id,(unsigned long)registration_error,budget_exhausted?"true":"false",
           reservation_ms,unregister_calls,unregister_failures,cleanup_ok?"true":"false",(unsigned long)cleanup_error,cleanup_ms,total_ms);
    return complete?0:1;
}

int main(int argc,char **argv) {
    if (argc==2&&!strcmp(argv[1],"--real-register")) return test_real_registration();
    if (argc!=1) { fputs("usage: test_steam_keyboard.exe [--real-register]\n",stderr);return 2; }
    test_pid=GetCurrentProcessId();
    test_hook_seen=CreateEventW(NULL,TRUE,FALSE,NULL);test_hook_gate=CreateEventW(NULL,TRUE,FALSE,NULL);
    test_async_seen=CreateEventW(NULL,TRUE,FALSE,NULL);
    test_unregister_seen=CreateEventW(NULL,TRUE,FALSE,NULL);test_unregister_gate=CreateEventW(NULL,TRUE,FALSE,NULL);
    CHECK(test_hook_seen&&test_hook_gate&&test_async_seen&&test_unregister_seen&&test_unregister_gate);
    reset_fixture();test_masks_and_tuples();test_registration_rollback();test_identity_and_ownership();test_counter_limits();
    test_press_during_registration();test_held_and_expiry();test_full_preset_sample();
    test_obsolete_deadline();test_focus_revocation();test_retirement_and_handles();CHECK(lll_keyboard_shutdown());
    CHECK(!test_fake_errors);CHECK(CloseHandle(test_hook_seen));CHECK(CloseHandle(test_hook_gate));CHECK(CloseHandle(test_async_seen));
    CHECK(CloseHandle(test_unregister_seen));CHECK(CloseHandle(test_unregister_gate));
    printf("PASS %u offline keyboard checks; no real hotkey/WinEvent registration or input\n",checks);
    return 0;
}
