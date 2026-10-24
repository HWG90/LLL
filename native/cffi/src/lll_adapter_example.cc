// Integration example, not a patch against an identified LLL revision.
// Call only from LLL's owning Lua thread, after its host API is validated.
#include "host_api.hh"
#include <windows.h>
bool lll_install_cffi(lua_State *L, const Hd2LuaApi &host,
                      const wchar_t *absolute_dll_path, const char **error) {
    if (error) *error = nullptr;
    if (!L || !absolute_dll_path) {
        if (error) *error = "missing Lua state or module path";
        return false;
    }
    HMODULE module = LoadLibraryW(absolute_dll_path);
    if (!module) {
        if (error) *error = "LoadLibraryW failed; record GetLastError in LLL";
        return false;
    }
    auto bind = reinterpret_cast<int (*)(const Hd2LuaApi *)>(GetProcAddress(module, "hd2_cffi_bind"));
    auto install = reinterpret_cast<int (*)(lua_State *)>(GetProcAddress(module, "hd2_cffi_install"));
    if (!bind || !install || !bind(&host)) {
        if (error) *error = "module exports or complete host Lua API binding unavailable";
        FreeLibrary(module);
        return false;
    }
    if (install(L) != 1) {
        if (error) *error = "registration rejected; inspect package.loaded/preload and Lua state readiness";
        FreeLibrary(module);
        return false;
    }
    // Retain this module reference until process exit. Existing Lua objects and
    // callbacks can reference module code even after a mod is disabled.
    return true;
}
