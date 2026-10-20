/*
 * HD2SE experimental native plugin ABI, draft 0.1.
 *
 * CONTRACT ONLY: no native host, exported entrypoint loader, engine bridge,
 * or Lua binding installation is implemented by this header or LLL runtime.
 * Windows x64, C99/C++; native plugins execute as trusted process code.
 * Independently authored; no SKSE/F4SE implementation is included.
 */
#ifndef HD2SE_PLUGIN_H_INCLUDED
#define HD2SE_PLUGIN_H_INCLUDED

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define HD2SE_CALL __cdecl
#if defined(HD2SE_BUILD_PLUGIN)
#define HD2SE_PLUGIN_EXPORT __declspec(dllexport)
#else
#define HD2SE_PLUGIN_EXPORT
#endif
#else
/* Non-Windows builds can check declarations; no non-Windows host is promised. */
#define HD2SE_CALL
#define HD2SE_PLUGIN_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* No packed structs. Windows x64's native alignment and 64-bit pointers apply.
 * Do not pass bool, size_t, C++ classes, exceptions, STL, or ownership of an
 * allocation across this ABI. Interface tables and descriptors use this prefix.
 * Callers initialize struct_size to their allocation size and abi_version to
 * the interface's negotiated version. Callees read/write only the understood
 * prefix, reject undersized mandatory prefixes, and never increase struct_size.
 * Reserved fields must be zero. Unknown enum/flag values must be rejected.
 * Unless explicitly marked worker-safe, host/interface calls require the Lua
 * thread. Returned views and query/load/unload context pointers are borrowed;
 * retain copied values, not context pointers. Draft changes may break
 * compatibility until the ABI is declared stable.
 */
#define HD2SE_ABI_MAJOR UINT32_C(1)
#define HD2SE_ABI_MINOR UINT32_C(0)
#define HD2SE_MAKE_VERSION(major, minor) \
    ((((uint32_t)(major)) << 16) | (((uint32_t)(minor)) & UINT32_C(0xffff)))
#define HD2SE_ABI_VERSION HD2SE_MAKE_VERSION(HD2SE_ABI_MAJOR, HD2SE_ABI_MINOR)
#define HD2SE_VERSION_MAJOR(version) (((uint32_t)(version)) >> 16)
#define HD2SE_VERSION_MINOR(version) (((uint32_t)(version)) & UINT32_C(0xffff))
#define HD2SE_STRUCT_INIT(type) { (uint32_t)sizeof(type), HD2SE_ABI_VERSION }

typedef int32_t hd2se_result;
#define HD2SE_OK                 ((hd2se_result)0)
#define HD2SE_PENDING            ((hd2se_result)1)
#define HD2SE_E_ARGUMENT         ((hd2se_result)-1)
#define HD2SE_E_ABI              ((hd2se_result)-2)
#define HD2SE_E_UNAVAILABLE      ((hd2se_result)-3)
#define HD2SE_E_UNSUPPORTED_GAME ((hd2se_result)-4)
#define HD2SE_E_THREAD           ((hd2se_result)-5)
#define HD2SE_E_OWNER            ((hd2se_result)-6)
#define HD2SE_E_STALE            ((hd2se_result)-7)
#define HD2SE_E_LIMIT            ((hd2se_result)-8)
#define HD2SE_E_BUSY             ((hd2se_result)-9)
#define HD2SE_E_CANCELLED        ((hd2se_result)-10)
#define HD2SE_E_PLUGIN           ((hd2se_result)-11)

/* Zero is invalid. Tokens are opaque, session-local and never persistable.
 * The host maps them to owner/session/world/generation records, not pointers.
 * No public token is reused within a host session. A new session, world unload,
 * object destruction/replacement, or provider revocation can make it stale.
 */
typedef uint64_t hd2se_plugin_handle;
typedef uint64_t hd2se_world_handle;
typedef uint64_t hd2se_object_handle;
typedef uint64_t hd2se_snapshot_handle;
typedef uint64_t hd2se_registration_handle;
#define HD2SE_INVALID_HANDLE UINT64_C(0)

typedef struct hd2se_header {
    uint32_t struct_size;
    uint32_t abi_version;
} hd2se_header;

/* UTF-8, no embedded NUL, length excludes any terminator. Borrowed for the call
 * unless stated otherwise; hosts copy strings retained beyond that call.
 */
typedef struct hd2se_string_view {
    const char *data;
    uint32_t length;
    uint32_t reserved;
} hd2se_string_view;

typedef struct hd2se_game_identity {
    hd2se_header header;
    uint64_t session_id;
    uint64_t steam_build_id;
    uint32_t exe_pe_timestamp;
    uint32_t game_pe_timestamp;
    uint8_t exe_sha256[32];
    uint8_t game_sha256[32];
    uint8_t lua_sha256[32];
    uint32_t pointer_bits;
    uint32_t reserved;
} hd2se_game_identity;

/* Required export HD2SE_Query runs before load. It must only examine immutable
 * metadata, negotiate compatibility, and fill its caller-owned output. No
 * engine access, task/event/binding registration, global writes or allocation
 * retained for gameplay is allowed here. It must also work on an unsupported
 * build and return HD2SE_E_UNSUPPORTED_GAME instead of touching engine state.
 */
typedef struct hd2se_query_context {
    hd2se_header header;
    hd2se_game_identity game;
    uint32_t host_api_major;
    uint32_t host_api_minor;
    uint32_t flags;
    uint32_t reserved;
} hd2se_query_context;

#define HD2SE_PLUGIN_ID_CAPACITY UINT32_C(64)
#define HD2SE_PLUGIN_NAME_CAPACITY UINT32_C(128)
#define HD2SE_PLUGIN_AUTHOR_CAPACITY UINT32_C(128)
typedef struct hd2se_plugin_info {
    hd2se_header header;
    /* Stable ASCII id [a-z0-9_.-], and NUL-terminated UTF-8 display strings. */
    char id[64];
    char name[128];
    char author[128];
    uint32_t version_major;
    uint32_t version_minor;
    uint32_t version_patch;
    uint32_t required_host_major;
    uint32_t minimum_host_minor;
    uint32_t flags;
    uint32_t reserved[2];
} hd2se_plugin_info;

typedef struct hd2se_interface_view {
    hd2se_header header;
    const void *table;
    uint32_t table_size;
    uint32_t major;
    uint32_t minor;
    uint32_t reserved;
} hd2se_interface_view;

/* Exact name, exact major, at least minimum_minor. Success requires a non-NULL
 * table and a sufficient table_size for fields the plugin uses. Table storage
 * stays valid until that plugin's completed unload. Revoked providers leave
 * valid host trampolines that return HD2SE_E_UNAVAILABLE; never dangling code.
 */
typedef hd2se_result (HD2SE_CALL *hd2se_query_interface_fn)(
    hd2se_plugin_handle owner, hd2se_string_view name,
    uint32_t major, uint32_t minimum_minor, hd2se_interface_view *out_interface);

typedef struct hd2se_host_api {
    hd2se_header header;
    hd2se_query_interface_fn query_interface;
    /* Worker-safe; copies message before returning. */
    hd2se_result (HD2SE_CALL *log)(hd2se_plugin_handle owner,
        uint32_t severity, hd2se_string_view message);
    /* Worker-safe; exactly 0 or 1. */
    uint32_t (HD2SE_CALL *is_lua_thread)(void);
    /* Idempotent for an already released token owned by this plugin. PENDING
     * means callbacks/dispatch still reference it: retain all backing memory.
     */
    hd2se_result (HD2SE_CALL *release_registration)(
        hd2se_plugin_handle owner, hd2se_registration_handle registration);
    hd2se_result (HD2SE_CALL *outstanding_work)(
        hd2se_plugin_handle owner, uint32_t *out_callbacks,
        uint32_t *out_registrations, uint32_t *out_resources);
} hd2se_host_api;

#define HD2SE_LOG_DEBUG UINT32_C(0)
#define HD2SE_LOG_INFO UINT32_C(1)
#define HD2SE_LOG_WARNING UINT32_C(2)
#define HD2SE_LOG_ERROR UINT32_C(3)

typedef struct hd2se_load_context {
    hd2se_header header;
    hd2se_plugin_handle owner;
    const hd2se_host_api *host;
    const hd2se_game_identity *game;
    uint32_t flags;
    uint32_t reserved;
} hd2se_load_context;

typedef struct hd2se_unload_context {
    hd2se_header header;
    hd2se_plugin_handle owner;
    uint32_t reason;
    uint32_t reserved;
} hd2se_unload_context;
#define HD2SE_UNLOAD_REQUESTED UINT32_C(1)
#define HD2SE_UNLOAD_RELOAD UINT32_C(2)
#define HD2SE_UNLOAD_LOAD_FAILED UINT32_C(3)
#define HD2SE_UNLOAD_SESSION_END UINT32_C(4)

/* All four exports are required by this draft. Load/BeginUnload/PollUnload run
 * on the host-owned Lua thread. BeginUnload is called once; PollUnload is called
 * after PENDING. Only OK acknowledges plugin cleanup, and the host additionally
 * requires all work/resources to drain before unloading native machine code.
 * Any error retains the DLL/resources and reports an unload failure.
 * Failed partial Load still enters cleanup. Plugin-created threads must stop
 * and join before acknowledgement. DllMain must not enter Lua or the host.
 */
HD2SE_PLUGIN_EXPORT hd2se_result HD2SE_CALL HD2SE_Query(
    const hd2se_query_context *context, hd2se_plugin_info *out_info);
HD2SE_PLUGIN_EXPORT hd2se_result HD2SE_CALL HD2SE_Load(
    const hd2se_load_context *context);
HD2SE_PLUGIN_EXPORT hd2se_result HD2SE_CALL HD2SE_BeginUnload(
    const hd2se_unload_context *context);
HD2SE_PLUGIN_EXPORT hd2se_result HD2SE_CALL HD2SE_PollUnload(
    const hd2se_unload_context *context);

/* All callbacks must return normally; no C++ exception or Lua longjmp may cross
 * the ABI. User data stays plugin-owned until on_release acknowledges the host
 * no longer references it. on_release runs once on the Lua thread and must not
 * register new work. A host cannot recover arbitrary access violations.
 */
typedef void (HD2SE_CALL *hd2se_release_callback)(
    hd2se_plugin_handle owner, void *user_data);

/* Single-shot, bounded, FIFO tasks are the sole worker-to-Lua dispatch route.
 * Submit/cancel can be called from workers. Execution is deferred to a later
 * host pump, never inline or recursively during dispatch. Lua state is borrowed
 * only during a task callback, and must not be retained or used by workers.
 */
struct lua_State;
typedef struct hd2se_task_context {
    hd2se_header header;
    uint64_t frame_id;
    uint64_t monotonic_ns;
    struct lua_State *lua;
    uint32_t flags;
    uint32_t reserved;
} hd2se_task_context;
typedef void (HD2SE_CALL *hd2se_task_callback)(
    hd2se_plugin_handle owner, const hd2se_task_context *context, void *user_data);
typedef struct hd2se_task_desc {
    hd2se_header header;
    hd2se_task_callback callback;
    hd2se_release_callback on_release;
    void *user_data;
    uint64_t not_before_monotonic_ns; /* 0 means next eligible host pump. */
    uint32_t flags;
    uint32_t reserved;
} hd2se_task_desc;
typedef struct hd2se_tasks_v1 {
    hd2se_header header;
    hd2se_result (HD2SE_CALL *submit)(hd2se_plugin_handle owner,
        const hd2se_task_desc *task, hd2se_registration_handle *out_task);
    hd2se_result (HD2SE_CALL *cancel)(hd2se_plugin_handle owner,
        hd2se_registration_handle task);
} hd2se_tasks_v1;
#define HD2SE_INTERFACE_TASKS "hd2se.tasks"

/* Event payloads are copied data with a named, versioned schema: no borrowed
 * engine pointers. Views/data are valid only for this callback. Delivery occurs
 * on the Lua thread, FIFO within a source, with bounded queues. Unsubscribe
 * prevents future delivery and drains active callbacks before on_release.
 * Payload schemas contain no pointers; retained data is a byte copy, not a
 * recursive object copy. Engine names use hd2se.*; plugins may emit only
 * plugin.<their-id>.*. Subscribe/emit require the Lua thread.
 */
typedef struct hd2se_event {
    hd2se_header header;
    hd2se_string_view name;
    hd2se_string_view payload_schema;
    const void *payload;
    uint32_t payload_size;
    uint32_t payload_major;
    uint32_t payload_minor;
    uint32_t flags;
    uint64_t sequence;
    uint64_t frame_id;
    uint64_t monotonic_ns;
} hd2se_event;
typedef void (HD2SE_CALL *hd2se_event_callback)(
    hd2se_plugin_handle owner, const hd2se_event *event, void *user_data);
typedef struct hd2se_event_subscription {
    hd2se_header header;
    hd2se_string_view event_name;
    hd2se_event_callback callback;
    hd2se_release_callback on_release;
    void *user_data;
    uint32_t flags;
    uint32_t reserved;
} hd2se_event_subscription;
typedef struct hd2se_events_v1 {
    hd2se_header header;
    hd2se_result (HD2SE_CALL *subscribe)(hd2se_plugin_handle owner,
        const hd2se_event_subscription *subscription,
        hd2se_registration_handle *out_subscription);
    hd2se_result (HD2SE_CALL *emit)(hd2se_plugin_handle owner,
        const hd2se_event *event);
} hd2se_events_v1;
#define HD2SE_INTERFACE_EVENTS "hd2se.events"

/* Lua functions are installed only through host-owned revocable trampolines.
 * The host copies names/descriptors and calls functions only on its Lua thread.
 * Cached Lua closures survive revocation but return "provider unavailable".
 * Never install a direct plugin-code closure, expose a native function address,
 * retain lua_State, change VM/JIT global state, or unload a referenced DLL.
 * Callback reads arguments and pushes results, fills result_count/error, then
 * returns normally. Host validates stack balance and raises any Lua error after
 * callback return. Error storage must survive the host's subsequent copy; do
 * not reference callback-local stack storage. Calling lua_error/luaL_error
 * from a callback is prohibited.
 */
typedef struct hd2se_lua_call {
    hd2se_header header;
    struct lua_State *lua;
    uint32_t argument_count;
    uint32_t result_count;
    hd2se_string_view error;
    uint64_t call_id;
} hd2se_lua_call;
typedef hd2se_result (HD2SE_CALL *hd2se_lua_callback)(
    hd2se_plugin_handle owner, hd2se_lua_call *call, void *user_data);
typedef struct hd2se_lua_function_desc {
    hd2se_header header;
    hd2se_string_view module_name;
    hd2se_string_view function_name;
    hd2se_lua_callback callback;
    hd2se_release_callback on_release;
    void *user_data;
    uint32_t flags;
    uint32_t reserved;
} hd2se_lua_function_desc;
typedef struct hd2se_lua_v1 {
    hd2se_header header;
    /* Atomic batch: success owns every descriptor; failure owns none. Calls to
     * register_functions must be on the Lua thread; submit a task otherwise.
     */
    hd2se_result (HD2SE_CALL *register_functions)(hd2se_plugin_handle owner,
        const hd2se_lua_function_desc *functions, uint32_t count,
        hd2se_registration_handle *out_registration);
} hd2se_lua_v1;
#define HD2SE_INTERFACE_LUA "hd2se.lua"

/* First engine vertical slice: read-only world/entity views. Every call must
 * run on the Lua thread and revalidate current session/world/generation.
 * A snapshot is an immutable inventory of candidate tokens at a past instant;
 * it does not pin game objects or prove they remain alive when read later.
 * get_info/validate re-check the live backing object at each call, and return
 * STALE/UNAVAILABLE instead of dereferencing an unverified address. Validation
 * and native reads require one verified engine lifetime/synchronization guard
 * covering the entire call; a separate earlier validity check is insufficient.
 */
typedef struct hd2se_world_info {
    hd2se_header header;
    hd2se_world_handle handle;
    uint64_t session_id;
    uint64_t generation;
    uint64_t observed_frame_id;
    uint32_t flags;
    uint32_t reserved;
} hd2se_world_info;
typedef struct hd2se_entity_info {
    hd2se_header header;
    hd2se_object_handle handle;
    hd2se_world_handle world;
    uint64_t session_id;
    uint64_t world_generation;
    uint64_t object_generation;
    uint64_t observed_frame_id;
    uint32_t kind; /* Defined only by a negotiated engine binding profile. */
    uint32_t flags;
} hd2se_entity_info;
typedef struct hd2se_snapshot_request {
    hd2se_header header;
    hd2se_world_handle world;
    uint32_t maximum_entities; /* Bounded request; host may impose a lower limit. */
    uint32_t flags;
} hd2se_snapshot_request;
typedef struct hd2se_snapshot_info {
    hd2se_header header;
    hd2se_snapshot_handle handle;
    hd2se_world_handle world;
    uint64_t observed_frame_id;
    uint32_t entity_count;
    uint32_t reserved;
} hd2se_snapshot_info;
typedef struct hd2se_snapshot_page {
    hd2se_header header;
    uint64_t next_cursor; /* 0 on completion; opaque cursor, initial cursor is 0. */
    uint32_t written;
    uint32_t has_more; /* Exactly 0 or 1. */
} hd2se_snapshot_page;
typedef struct hd2se_world_v1 {
    hd2se_header header;
    hd2se_result (HD2SE_CALL *current)(hd2se_plugin_handle owner,
        hd2se_world_info *out_world);
    hd2se_result (HD2SE_CALL *get_info)(hd2se_plugin_handle owner,
        hd2se_world_handle world, hd2se_world_info *out_world);
    /* Complete snapshot or failure; no silently truncated entity inventory. */
    hd2se_result (HD2SE_CALL *open_snapshot)(hd2se_plugin_handle owner,
        const hd2se_snapshot_request *request, hd2se_snapshot_info *out_snapshot);
    hd2se_result (HD2SE_CALL *read_snapshot)(hd2se_plugin_handle owner,
        hd2se_snapshot_handle snapshot, uint64_t cursor,
        hd2se_object_handle *items, uint32_t capacity, hd2se_snapshot_page *out_page);
    hd2se_result (HD2SE_CALL *close_snapshot)(hd2se_plugin_handle owner,
        hd2se_snapshot_handle snapshot);
} hd2se_world_v1;
typedef struct hd2se_entity_v1 {
    hd2se_header header;
    hd2se_result (HD2SE_CALL *validate)(hd2se_plugin_handle owner,
        hd2se_object_handle object);
    hd2se_result (HD2SE_CALL *get_info)(hd2se_plugin_handle owner,
        hd2se_object_handle object, hd2se_entity_info *out_entity);
} hd2se_entity_v1;
#define HD2SE_INTERFACE_WORLD "hd2se.world"
#define HD2SE_INTERFACE_ENTITY "hd2se.entity"

/* Interfaces above are drafts, not claims of current engine availability.
 * No entity mutation/spawning, network authority, serialization, raw memory,
 * or hook installation API is defined here.
 */

#ifdef __cplusplus
} /* extern "C" */
#endif
#endif /* HD2SE_PLUGIN_H_INCLUDED */
