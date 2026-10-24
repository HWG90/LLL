#pragma once
#include <stdint.h>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}
// Must be called by LLL on the owning Lua thread before luaopen_cffi.
// Every pointer must belong to this state's host VM, not another Lua DLL.
struct Hd2LuaApi {
    uint32_t abi_version;
    uint32_t struct_size;
    decltype(&::luaL_argerror) luaL_argerror;
    decltype(&::luaL_checkany) luaL_checkany;
    decltype(&::luaL_checkinteger) luaL_checkinteger;
    decltype(&::luaL_checklstring) luaL_checklstring;
    decltype(&::luaL_checknumber) luaL_checknumber;
    decltype(&::luaL_checktype) luaL_checktype;
    decltype(&::luaL_checkudata) luaL_checkudata;
    decltype(&::luaL_error) luaL_error;
    decltype(&::luaL_newmetatable) luaL_newmetatable;
    decltype(&::luaL_optinteger) luaL_optinteger;
    decltype(&::luaL_ref) luaL_ref;
    decltype(&::luaL_register) luaL_register;
    decltype(&::luaL_unref) luaL_unref;
    decltype(&::luaL_where) luaL_where;
    decltype(&::lua_call) lua_call;
    decltype(&::lua_concat) lua_concat;
    decltype(&::lua_createtable) lua_createtable;
    decltype(&::lua_error) lua_error;
    decltype(&::lua_getfield) lua_getfield;
    decltype(&::lua_getmetatable) lua_getmetatable;
    decltype(&::lua_gettable) lua_gettable;
    decltype(&::lua_gettop) lua_gettop;
    decltype(&::lua_insert) lua_insert;
    decltype(&::lua_isnumber) lua_isnumber;
    decltype(&::lua_isstring) lua_isstring;
    decltype(&::lua_isuserdata) lua_isuserdata;
    decltype(&::lua_newuserdata) lua_newuserdata;
    decltype(&::lua_objlen) lua_objlen;
    decltype(&::lua_pcall) lua_pcall;
    decltype(&::lua_pushboolean) lua_pushboolean;
    decltype(&::lua_pushcclosure) lua_pushcclosure;
    decltype(&::lua_pushfstring) lua_pushfstring;
    decltype(&::lua_pushinteger) lua_pushinteger;
    decltype(&::lua_pushlightuserdata) lua_pushlightuserdata;
    decltype(&::lua_pushlstring) lua_pushlstring;
    decltype(&::lua_pushnil) lua_pushnil;
    decltype(&::lua_pushnumber) lua_pushnumber;
    decltype(&::lua_pushstring) lua_pushstring;
    decltype(&::lua_pushvalue) lua_pushvalue;
    decltype(&::lua_rawequal) lua_rawequal;
    decltype(&::lua_rawget) lua_rawget;
    decltype(&::lua_rawgeti) lua_rawgeti;
    decltype(&::lua_replace) lua_replace;
    decltype(&::lua_setfield) lua_setfield;
    decltype(&::lua_setmetatable) lua_setmetatable;
    decltype(&::lua_settop) lua_settop;
    decltype(&::lua_toboolean) lua_toboolean;
    decltype(&::lua_tointeger) lua_tointeger;
    decltype(&::lua_tolstring) lua_tolstring;
    decltype(&::lua_tonumber) lua_tonumber;
    decltype(&::lua_touserdata) lua_touserdata;
    decltype(&::lua_type) lua_type;
    decltype(&::lua_typename) lua_typename;
};
extern Hd2LuaApi hd2_api;
#if defined(_WIN32)
#define HD2_EXPORT extern "C" __declspec(dllexport)
#else
#define HD2_EXPORT extern "C" __attribute__((visibility("default")))
#endif
HD2_EXPORT int hd2_cffi_bind(const Hd2LuaApi *api);
HD2_EXPORT int hd2_cffi_is_bound(void);
HD2_EXPORT int luaopen_cffi(lua_State *L);
// Register package.preload.cffi on this state's owning thread.
// 1: installed; -1: unbound/null state; -2: missing package tables;
// -3: cffi is already loaded or preloaded. Preserves the stack on normal return.
HD2_EXPORT int hd2_cffi_install(lua_State *L);
