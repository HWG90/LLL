#include "host_api.hh"
Hd2LuaApi hd2_api = {};
static bool bound = false;
void ffi_module_open(lua_State *L);
HD2_EXPORT int hd2_cffi_is_bound(void) { return bound ? 1 : 0; }
HD2_EXPORT int hd2_cffi_bind(const Hd2LuaApi *api) {
    if (!api || api->abi_version != 1 || api->struct_size != sizeof(Hd2LuaApi)) return 0;
    if (!api->luaL_argerror) return 0;
    if (!api->luaL_checkany) return 0;
    if (!api->luaL_checkinteger) return 0;
    if (!api->luaL_checklstring) return 0;
    if (!api->luaL_checknumber) return 0;
    if (!api->luaL_checktype) return 0;
    if (!api->luaL_checkudata) return 0;
    if (!api->luaL_error) return 0;
    if (!api->luaL_newmetatable) return 0;
    if (!api->luaL_optinteger) return 0;
    if (!api->luaL_ref) return 0;
    if (!api->luaL_register) return 0;
    if (!api->luaL_unref) return 0;
    if (!api->luaL_where) return 0;
    if (!api->lua_call) return 0;
    if (!api->lua_concat) return 0;
    if (!api->lua_createtable) return 0;
    if (!api->lua_error) return 0;
    if (!api->lua_getfield) return 0;
    if (!api->lua_getmetatable) return 0;
    if (!api->lua_gettable) return 0;
    if (!api->lua_gettop) return 0;
    if (!api->lua_insert) return 0;
    if (!api->lua_isnumber) return 0;
    if (!api->lua_isstring) return 0;
    if (!api->lua_isuserdata) return 0;
    if (!api->lua_newuserdata) return 0;
    if (!api->lua_objlen) return 0;
    if (!api->lua_pcall) return 0;
    if (!api->lua_pushboolean) return 0;
    if (!api->lua_pushcclosure) return 0;
    if (!api->lua_pushfstring) return 0;
    if (!api->lua_pushinteger) return 0;
    if (!api->lua_pushlightuserdata) return 0;
    if (!api->lua_pushlstring) return 0;
    if (!api->lua_pushnil) return 0;
    if (!api->lua_pushnumber) return 0;
    if (!api->lua_pushstring) return 0;
    if (!api->lua_pushvalue) return 0;
    if (!api->lua_rawequal) return 0;
    if (!api->lua_rawget) return 0;
    if (!api->lua_rawgeti) return 0;
    if (!api->lua_replace) return 0;
    if (!api->lua_setfield) return 0;
    if (!api->lua_setmetatable) return 0;
    if (!api->lua_settop) return 0;
    if (!api->lua_toboolean) return 0;
    if (!api->lua_tointeger) return 0;
    if (!api->lua_tolstring) return 0;
    if (!api->lua_tonumber) return 0;
    if (!api->lua_touserdata) return 0;
    if (!api->lua_type) return 0;
    if (!api->lua_typename) return 0;
    if (bound) {
        if (hd2_api.luaL_argerror != api->luaL_argerror) return 0;
        if (hd2_api.luaL_checkany != api->luaL_checkany) return 0;
        if (hd2_api.luaL_checkinteger != api->luaL_checkinteger) return 0;
        if (hd2_api.luaL_checklstring != api->luaL_checklstring) return 0;
        if (hd2_api.luaL_checknumber != api->luaL_checknumber) return 0;
        if (hd2_api.luaL_checktype != api->luaL_checktype) return 0;
        if (hd2_api.luaL_checkudata != api->luaL_checkudata) return 0;
        if (hd2_api.luaL_error != api->luaL_error) return 0;
        if (hd2_api.luaL_newmetatable != api->luaL_newmetatable) return 0;
        if (hd2_api.luaL_optinteger != api->luaL_optinteger) return 0;
        if (hd2_api.luaL_ref != api->luaL_ref) return 0;
        if (hd2_api.luaL_register != api->luaL_register) return 0;
        if (hd2_api.luaL_unref != api->luaL_unref) return 0;
        if (hd2_api.luaL_where != api->luaL_where) return 0;
        if (hd2_api.lua_call != api->lua_call) return 0;
        if (hd2_api.lua_concat != api->lua_concat) return 0;
        if (hd2_api.lua_createtable != api->lua_createtable) return 0;
        if (hd2_api.lua_error != api->lua_error) return 0;
        if (hd2_api.lua_getfield != api->lua_getfield) return 0;
        if (hd2_api.lua_getmetatable != api->lua_getmetatable) return 0;
        if (hd2_api.lua_gettable != api->lua_gettable) return 0;
        if (hd2_api.lua_gettop != api->lua_gettop) return 0;
        if (hd2_api.lua_insert != api->lua_insert) return 0;
        if (hd2_api.lua_isnumber != api->lua_isnumber) return 0;
        if (hd2_api.lua_isstring != api->lua_isstring) return 0;
        if (hd2_api.lua_isuserdata != api->lua_isuserdata) return 0;
        if (hd2_api.lua_newuserdata != api->lua_newuserdata) return 0;
        if (hd2_api.lua_objlen != api->lua_objlen) return 0;
        if (hd2_api.lua_pcall != api->lua_pcall) return 0;
        if (hd2_api.lua_pushboolean != api->lua_pushboolean) return 0;
        if (hd2_api.lua_pushcclosure != api->lua_pushcclosure) return 0;
        if (hd2_api.lua_pushfstring != api->lua_pushfstring) return 0;
        if (hd2_api.lua_pushinteger != api->lua_pushinteger) return 0;
        if (hd2_api.lua_pushlightuserdata != api->lua_pushlightuserdata) return 0;
        if (hd2_api.lua_pushlstring != api->lua_pushlstring) return 0;
        if (hd2_api.lua_pushnil != api->lua_pushnil) return 0;
        if (hd2_api.lua_pushnumber != api->lua_pushnumber) return 0;
        if (hd2_api.lua_pushstring != api->lua_pushstring) return 0;
        if (hd2_api.lua_pushvalue != api->lua_pushvalue) return 0;
        if (hd2_api.lua_rawequal != api->lua_rawequal) return 0;
        if (hd2_api.lua_rawget != api->lua_rawget) return 0;
        if (hd2_api.lua_rawgeti != api->lua_rawgeti) return 0;
        if (hd2_api.lua_replace != api->lua_replace) return 0;
        if (hd2_api.lua_setfield != api->lua_setfield) return 0;
        if (hd2_api.lua_setmetatable != api->lua_setmetatable) return 0;
        if (hd2_api.lua_settop != api->lua_settop) return 0;
        if (hd2_api.lua_toboolean != api->lua_toboolean) return 0;
        if (hd2_api.lua_tointeger != api->lua_tointeger) return 0;
        if (hd2_api.lua_tolstring != api->lua_tolstring) return 0;
        if (hd2_api.lua_tonumber != api->lua_tonumber) return 0;
        if (hd2_api.lua_touserdata != api->lua_touserdata) return 0;
        if (hd2_api.lua_type != api->lua_type) return 0;
        if (hd2_api.lua_typename != api->lua_typename) return 0;
        return 1;
    }
    hd2_api = *api;
    bound = true;
    return 1;
}
HD2_EXPORT int luaopen_cffi(lua_State *L) {
    if (!bound || !L) return 0;
    ffi_module_open(L);
    return 1;
}
HD2_EXPORT int hd2_cffi_install(lua_State *L) {
    if (!bound || !L) return -1;
    const int top = hd2_api.lua_gettop(L);
    hd2_api.lua_getfield(L, LUA_GLOBALSINDEX, "package");
    if (hd2_api.lua_type(L, -1) != LUA_TTABLE) {
        hd2_api.lua_settop(L, top); return -2;
    }
    hd2_api.lua_getfield(L, -1, "loaded");
    if (hd2_api.lua_type(L, -1) != LUA_TTABLE) {
        hd2_api.lua_settop(L, top); return -2;
    }
    hd2_api.lua_getfield(L, -1, "cffi");
    if (hd2_api.lua_type(L, -1) != LUA_TNIL) {
        hd2_api.lua_settop(L, top); return -3;
    }
    hd2_api.lua_settop(L, top + 1);
    hd2_api.lua_getfield(L, -1, "preload");
    if (hd2_api.lua_type(L, -1) != LUA_TTABLE) {
        hd2_api.lua_settop(L, top); return -2;
    }
    hd2_api.lua_getfield(L, -1, "cffi");
    if (hd2_api.lua_type(L, -1) != LUA_TNIL) {
        hd2_api.lua_settop(L, top); return -3;
    }
    hd2_api.lua_settop(L, top + 2);
    hd2_api.lua_pushcclosure(L, luaopen_cffi, 0);
    hd2_api.lua_setfield(L, -2, "cffi");
    hd2_api.lua_settop(L, top);
    return 1;
}
