#include "host_api.hh"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while(0)
int main(int argc, char **argv) {
    CHECK(argc == 3);
#if defined(_WIN32)
    auto handle = LoadLibraryA(argv[1]);
    CHECK(handle);
    auto symbol = [handle](const char *name) { return reinterpret_cast<void *>(GetProcAddress(handle, name)); };
#else
    auto handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) std::fprintf(stderr, "%s\n", dlerror());
    CHECK(handle);
    auto symbol = [handle](const char *name) { return dlsym(handle, name); };
#endif
    auto bind = reinterpret_cast<int (*)(const Hd2LuaApi *)>(symbol("hd2_cffi_bind"));
    auto is_bound = reinterpret_cast<int (*)()>(symbol("hd2_cffi_is_bound"));
    auto open = reinterpret_cast<lua_CFunction>(symbol("luaopen_cffi"));
    auto install = reinterpret_cast<int (*)(lua_State *)>(symbol("hd2_cffi_install"));
    CHECK(bind && is_bound && open && install);
    CHECK(install(nullptr) == -1);
    CHECK(!is_bound());
    CHECK(!bind(nullptr));
    CHECK(open(nullptr) == 0);
#if defined(_WIN32)
    auto bootstrap=reinterpret_cast<lua_CFunction>(symbol("luaopen_hd2_cffi"));
    auto boot_status=reinterpret_cast<const char *(*)()>(symbol("hd2_cffi_bootstrap_status"));
    CHECK(bootstrap && boot_status);
    lua_State *foreign=luaL_newstate();
    CHECK(foreign);
    CHECK(bootstrap(foreign)==0);
    CHECK(!is_bound());
    CHECK(std::strstr(boot_status(), "Unsupported host executable"));
    lua_close(foreign);
#endif
    Hd2LuaApi api = {};
    api.abi_version = 1;
    api.struct_size = sizeof(api);
    CHECK(!bind(&api));
    api.luaL_argerror = &::luaL_argerror;
    api.luaL_checkany = &::luaL_checkany;
    api.luaL_checkinteger = &::luaL_checkinteger;
    api.luaL_checklstring = &::luaL_checklstring;
    api.luaL_checknumber = &::luaL_checknumber;
    api.luaL_checktype = &::luaL_checktype;
    api.luaL_checkudata = &::luaL_checkudata;
    api.luaL_error = &::luaL_error;
    api.luaL_newmetatable = &::luaL_newmetatable;
    api.luaL_optinteger = &::luaL_optinteger;
    api.luaL_ref = &::luaL_ref;
    api.luaL_register = &::luaL_register;
    api.luaL_unref = &::luaL_unref;
    api.luaL_where = &::luaL_where;
    api.lua_call = &::lua_call;
    api.lua_concat = &::lua_concat;
    api.lua_createtable = &::lua_createtable;
    api.lua_error = &::lua_error;
    api.lua_getfield = &::lua_getfield;
    api.lua_getmetatable = &::lua_getmetatable;
    api.lua_gettable = &::lua_gettable;
    api.lua_gettop = &::lua_gettop;
    api.lua_insert = &::lua_insert;
    api.lua_isnumber = &::lua_isnumber;
    api.lua_isstring = &::lua_isstring;
    api.lua_isuserdata = &::lua_isuserdata;
    api.lua_newuserdata = &::lua_newuserdata;
    api.lua_objlen = &::lua_objlen;
    api.lua_pcall = &::lua_pcall;
    api.lua_pushboolean = &::lua_pushboolean;
    api.lua_pushcclosure = &::lua_pushcclosure;
    api.lua_pushfstring = &::lua_pushfstring;
    api.lua_pushinteger = &::lua_pushinteger;
    api.lua_pushlightuserdata = &::lua_pushlightuserdata;
    api.lua_pushlstring = &::lua_pushlstring;
    api.lua_pushnil = &::lua_pushnil;
    api.lua_pushnumber = &::lua_pushnumber;
    api.lua_pushstring = &::lua_pushstring;
    api.lua_pushvalue = &::lua_pushvalue;
    api.lua_rawequal = &::lua_rawequal;
    api.lua_rawget = &::lua_rawget;
    api.lua_rawgeti = &::lua_rawgeti;
    api.lua_replace = &::lua_replace;
    api.lua_setfield = &::lua_setfield;
    api.lua_setmetatable = &::lua_setmetatable;
    api.lua_settop = &::lua_settop;
    api.lua_toboolean = &::lua_toboolean;
    api.lua_tointeger = &::lua_tointeger;
    api.lua_tolstring = &::lua_tolstring;
    api.lua_tonumber = &::lua_tonumber;
    api.lua_touserdata = &::lua_touserdata;
    api.lua_type = &::lua_type;
    api.lua_typename = &::lua_typename;
    api.abi_version = 0;
    CHECK(!bind(&api));
    api.abi_version = 1;
    CHECK(bind(&api));
    CHECK(bind(&api));
    CHECK(is_bound());
    Hd2LuaApi incompatible = api;
    incompatible.lua_isstring = api.lua_isuserdata;
    CHECK(!bind(&incompatible));
    lua_State *L = luaL_newstate();
    CHECK(L);
    luaL_openlibs(L);
    lua_pushinteger(L, 123);
    int top = lua_gettop(L);
    CHECK(install(L) == 1);
    CHECK(lua_gettop(L) == top);
    CHECK(lua_tointeger(L, -1) == 123);
    CHECK(install(L) == -3);
    CHECK(lua_gettop(L) == top);
    lua_settop(L, 0);
    lua_State *bare = luaL_newstate();
    CHECK(bare);
    CHECK(install(bare) == -2);
    CHECK(lua_gettop(bare) == 0);
    lua_close(bare);
    lua_pushstring(L, argv[2]);
    lua_setglobal(L, "FFI_TEST_LIBRARY");
    int status = luaL_dofile(L, "smoke.lua");
    if (status) std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L);
    CHECK(status == 0);
    std::puts("PASS: bound API, opened module, FFI smoke tests, closed state");
    // Keep module resident until process exit: callbacks and C data may reference it.
    return 0;
}
