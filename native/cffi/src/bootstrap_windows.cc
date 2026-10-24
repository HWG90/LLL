// Build-specific normal Lua module bootstrap. No hooks or target code writes.
#include "host_api.hh"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <cstring>
#include <cstdint>
static const char *boot_status = "not attempted";
static bool fail(const char *why) { boot_status=why; OutputDebugStringA(why); return false; }
HD2_EXPORT const char *hd2_cffi_bootstrap_status() { return boot_status; }
static bool readable(const void *ptr, size_t count, bool code=false) {
    MEMORY_BASIC_INFORMATION m = {};
    if (!ptr || !count || !VirtualQuery(ptr,&m,sizeof(m))) return false;
    uintptr_t low=reinterpret_cast<uintptr_t>(ptr),end=low+count;
    if (end<low || end>reinterpret_cast<uintptr_t>(m.BaseAddress)+m.RegionSize) return false;
    if (m.State!=MEM_COMMIT || (m.Protect&(PAGE_NOACCESS|PAGE_GUARD))) return false;
    DWORD p=m.Protect&0xff;
    if (code) return p==PAGE_EXECUTE_READ || p==PAGE_EXECUTE_READWRITE || p==PAGE_EXECUTE_WRITECOPY;
    return p==PAGE_READONLY || p==PAGE_READWRITE || p==PAGE_WRITECOPY || p==PAGE_EXECUTE_READ || p==PAGE_EXECUTE_READWRITE || p==PAGE_EXECUTE_WRITECOPY;
}
static bool expected_file() {
    wchar_t path[32768];
    DWORD length=GetModuleFileNameW(nullptr,path,32768);
    if (!length || length>=32768) return fail("Cannot resolve host executable path");
    HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,0,nullptr);
    if (file==INVALID_HANDLE_VALUE) return fail("Cannot read host executable");
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;
    unsigned char buffer[65536],digest[32];DWORD count;bool ok=false;
    if (BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0 && BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)>=0) {
        ok=true;
        for (;;) {
            if (!ReadFile(file,buffer,sizeof(buffer),&count,nullptr)) {ok=false;break;}
            if (!count) break;
            if (BCryptHashData(hash,buffer,count,0)<0) {ok=false;break;}
        }
        if (ok) ok=BCryptFinishHash(hash,digest,32,0)>=0;
    }
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm,0);
    CloseHandle(file);
    const unsigned char expected[32]={0x0a,0xcc,0x07,0xde,0xbe,0x04,0x71,0x4a,0xe0,0x42,0x81,0xe1,0xa6,0x6b,0xd2,0xeb,0x9d,0x3d,0x85,0x23,0x29,0x53,0xe3,0x2a,0x93,0xc8,0xa3,0xdd,0x08,0x74,0xea,0xbe};
    return (ok && !std::memcmp(digest,expected,32)) || fail("Unsupported host executable; expected Helldivers 2 build 26088801");
}
static bool bind_current_host() {
    if (!expected_file()) return false;
    auto base=reinterpret_cast<unsigned char *>(GetModuleHandleW(nullptr));
    if (!readable(base,sizeof(IMAGE_DOS_HEADER))) return fail("Unreadable host header");
    auto dos=reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
    if (dos->e_magic!=IMAGE_DOS_SIGNATURE || dos->e_lfanew<0 || dos->e_lfanew>0x100000) return fail("Invalid host DOS header");
    auto nt=reinterpret_cast<const IMAGE_NT_HEADERS64 *>(base+dos->e_lfanew);
    if (!readable(nt,sizeof(*nt)) || nt->Signature!=IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC) return fail("Invalid host PE header");
    constexpr uintptr_t table_rva=0x286f710;
    if (nt->OptionalHeader.SizeOfImage<table_rva+115*sizeof(void *)) return fail("Host image too small for LuaApi");
    auto table=reinterpret_cast<void *const *>(base+table_rva);
    if (!readable(table,115*sizeof(void *))) return fail("Unreadable host LuaApi table");
    Hd2LuaApi api={};api.abi_version=1;api.struct_size=sizeof(api);
    { // luaL_argerror, SDK member lib_argerror
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x81,0xec,0xf0,0x00};
        auto expected=base+0x792af0;
        if (table[91]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_argerror");
        api.luaL_argerror=reinterpret_cast<decltype(api.luaL_argerror)>(table[91]);
    }
    { // luaL_checkany, SDK member lib_checkany
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0x44,0x8b,0xd2,0x4c,0x8b,0xd9,0xe8,0x21,0x34,0x00,0x00,0x48};
        auto expected=base+0x7931b0;
        if (table[100]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_checkany");
        api.luaL_checkany=reinterpret_cast<decltype(api.luaL_checkany)>(table[100]);
    }
    { // luaL_checkinteger, SDK member lib_checkinteger
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x30,0x8b};
        auto expected=base+0x7934c0;
        if (table[96]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_checkinteger");
        api.luaL_checkinteger=reinterpret_cast<decltype(api.luaL_checkinteger)>(table[96]);
    }
    { // luaL_checklstring, SDK member lib_checklstring
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57};
        auto expected=base+0x7931f0;
        if (table[92]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_checklstring");
        api.luaL_checklstring=reinterpret_cast<decltype(api.luaL_checklstring)>(table[92]);
    }
    { // luaL_checknumber, SDK member lib_checknumber
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x40,0x0f,0x29,0x74,0x24,0x30,0x8b};
        auto expected=base+0x793370;
        if (table[94]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_checknumber");
        api.luaL_checknumber=reinterpret_cast<decltype(api.luaL_checknumber)>(table[94]);
    }
    { // luaL_checktype, SDK member lib_checktype
        const unsigned char prefix[16]={0x40,0x53,0x48,0x83,0xec,0x20,0x45,0x8b,0xd0,0x44,0x8b,0xda,0x48,0x8b,0xd9,0xe8};
        auto expected=base+0x793160;
        if (table[99]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_checktype");
        api.luaL_checktype=reinterpret_cast<decltype(api.luaL_checktype)>(table[99]);
    }
    { // luaL_checkudata, SDK member lib_checkudata
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57};
        auto expected=base+0x793060;
        if (table[102]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_checkudata");
        api.luaL_checkudata=reinterpret_cast<decltype(api.luaL_checkudata)>(table[102]);
    }
    { // luaL_error, SDK member lib_error
        const unsigned char prefix[16]={0x48,0x89,0x54,0x24,0x10,0x4c,0x89,0x44,0x24,0x18,0x4c,0x89,0x4c,0x24,0x20,0x53};
        auto expected=base+0x792e10;
        if (table[104]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_error");
        api.luaL_error=reinterpret_cast<decltype(api.luaL_error)>(table[104]);
    }
    { // luaL_newmetatable, SDK member lib_newmetatable
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x20,0x48};
        auto expected=base+0x792f90;
        if (table[101]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_newmetatable");
        api.luaL_newmetatable=reinterpret_cast<decltype(api.luaL_newmetatable)>(table[101]);
    }
    { // luaL_optinteger, SDK member lib_optinteger
        const unsigned char prefix[16]={0x40,0x53,0x48,0x83,0xec,0x20,0x4d,0x8b,0xd0,0x44,0x8b,0xda,0x48,0x8b,0xd9,0xe8};
        auto expected=base+0x7935c0;
        if (table[97]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_optinteger");
        api.luaL_optinteger=reinterpret_cast<decltype(api.luaL_optinteger)>(table[97]);
    }
    { // luaL_ref, SDK member lib_ref
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x10,0x56,0x48,0x83,0xec,0x30,0x8d,0x82,0x0f,0x27,0x00,0x00};
        auto expected=base+0x7942d0;
        if (table[106]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_ref");
        api.luaL_ref=reinterpret_cast<decltype(api.luaL_ref)>(table[106]);
    }
    { // luaL_register, SDK member lib_register
        const unsigned char prefix[16]={0x45,0x33,0xc9,0xe9,0x28,0x00,0x00,0x00,0x41,0x54,0x48,0x83,0xec,0x60,0x33,0xd0};
        auto expected=base+0x7937a0;
        if (table[87]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_register");
        api.luaL_register=reinterpret_cast<decltype(api.luaL_register)>(table[87]);
    }
    { // luaL_unref, SDK member lib_unref
        const unsigned char prefix[16]={0x45,0x85,0xc0,0x0f,0x88,0x9f,0x00,0x00,0x00,0x48,0x89,0x5c,0x24,0x08,0x48,0x89};
        auto expected=base+0x794410;
        if (table[107]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_unref");
        api.luaL_unref=reinterpret_cast<decltype(api.luaL_unref)>(table[107]);
    }
    { // luaL_where, SDK member lib_where
        const unsigned char prefix[16]={0x40,0x57,0x48,0x81,0xec,0xe0,0x00,0x00,0x00,0x4c,0x8b,0x41,0x28,0x48,0x8b,0xf9};
        auto expected=base+0x792cf0;
        if (table[103]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: luaL_where");
        api.luaL_where=reinterpret_cast<decltype(api.luaL_where)>(table[103]);
    }
    { // lua_call, SDK member call
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x20,0x8d,0x42,0x01,0x41,0x8b,0xd8};
        auto expected=base+0x797a30;
        if (table[64]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_call");
        api.lua_call=reinterpret_cast<decltype(api.lua_call)>(table[64]);
    }
    { // lua_concat, SDK member concat
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x20,0x48,0x63,0xda,0x48,0x8b,0xf9};
        auto expected=base+0x797fd0;
        if (table[75]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_concat");
        api.lua_concat=reinterpret_cast<decltype(api.lua_concat)>(table[75]);
    }
    { // lua_createtable, SDK member createtable
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57};
        auto expected=base+0x797510;
        if (table[54]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_createtable");
        api.lua_createtable=reinterpret_cast<decltype(api.lua_createtable)>(table[54]);
    }
    { // lua_error, SDK member error
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0xe8,0xe7,0xe4,0xff,0xff,0x33,0xc0,0x48,0x83,0xc4,0x28,0xc3};
        auto expected=base+0x797f80;
        if (table[73]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_error");
        api.lua_error=reinterpret_cast<decltype(api.lua_error)>(table[73]);
    }
    { // lua_getfield, SDK member getfield
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x30,0x4d,0x8b,0xd0,0x48,0x8b,0xd9};
        auto expected=base+0x797420;
        if (table[51]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_getfield");
        api.lua_getfield=reinterpret_cast<decltype(api.lua_getfield)>(table[51]);
    }
    { // lua_getmetatable, SDK member getmetatable
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0x4c,0x8b,0xd1,0xe8,0x54,0xf0,0xff,0xff,0x48,0x63,0x48,0x08};
        auto expected=base+0x797580;
        if (table[56]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_getmetatable");
        api.lua_getmetatable=reinterpret_cast<decltype(api.lua_getmetatable)>(table[56]);
    }
    { // lua_gettable, SDK member gettable
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0x4c,0x8b,0xd1,0xe8,0xe4,0xf1,0xff,0xff,0x4d,0x8b,0x42,0x10};
        auto expected=base+0x7973f0;
        if (table[50]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_gettable");
        api.lua_gettable=reinterpret_cast<decltype(api.lua_gettable)>(table[50]);
    }
    { // lua_gettop, SDK member gettop
        const unsigned char prefix[16]={0x48,0x8b,0x41,0x10,0x48,0x2b,0x41,0x18,0x48,0xc1,0xf8,0x04,0xc3,0x41,0x56,0x57};
        auto expected=base+0x796950;
        if (table[13]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_gettop");
        api.lua_gettop=reinterpret_cast<decltype(api.lua_gettop)>(table[13]);
    }
    { // lua_insert, SDK member insert
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0x4c,0x8b,0xd9,0xe8,0xc4,0xfb,0xff,0xff,0x49,0x8b,0x53,0x10};
        auto expected=base+0x796a10;
        if (table[17]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_insert");
        api.lua_insert=reinterpret_cast<decltype(api.lua_insert)>(table[17]);
    }
    { // lua_isnumber, SDK member isnumber
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0xe8,0x87,0xf9,0xff,0xff,0x8b,0x48,0x08,0x83,0xf9,0x03,0x74};
        auto expected=base+0x796c50;
        if (table[21]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_isnumber");
        api.lua_isnumber=reinterpret_cast<decltype(api.lua_isnumber)>(table[21]);
    }
    { // lua_isstring, SDK member isstring
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0xe8,0x47,0xf9,0xff,0xff,0x48,0x8d,0x0d,0x40,0x2b,0xf6,0x00};
        auto expected=base+0x796c90;
        if (table[22]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_isstring");
        api.lua_isstring=reinterpret_cast<decltype(api.lua_isstring)>(table[22]);
    }
    { // lua_isuserdata, SDK member isuserdata
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0xe8,0x07,0xf9,0xff,0xff,0x8b,0x48,0x08,0x83,0xf9,0x07,0x74};
        auto expected=base+0x796cd0;
        if (table[24]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_isuserdata");
        api.lua_isuserdata=reinterpret_cast<decltype(api.lua_isuserdata)>(table[24]);
    }
    { // lua_newuserdata, SDK member newuserdata
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x10,0x48,0x89,0x6c,0x24,0x18,0x48,0x89,0x74,0x24,0x20,0x57};
        auto expected=base+0x7980a0;
        if (table[55]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_newuserdata");
        api.lua_newuserdata=reinterpret_cast<decltype(api.lua_newuserdata)>(table[55]);
    }
    { // lua_objlen, SDK member objlen
        const unsigned char prefix[16]={0x40,0x53,0x48,0x83,0xec,0x20,0x4c,0x8b,0xd1,0xe8,0x42,0xf6,0xff,0xff,0x48,0x8b};
        auto expected=base+0x796f90;
        if (table[34]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_objlen");
        api.lua_objlen=reinterpret_cast<decltype(api.lua_objlen)>(table[34]);
    }
    { // lua_pcall, SDK member pcall
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x40,0x41,0x8b,0xf8,0x44,0x8b,0xda};
        auto expected=base+0x797a90;
        if (table[65]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pcall");
        api.lua_pcall=reinterpret_cast<decltype(api.lua_pcall)>(table[65]);
    }
    { // lua_pushboolean, SDK member pushboolean
        const unsigned char prefix[16]={0x4c,0x8b,0x41,0x10,0x33,0xc0,0x85,0xd2,0x0f,0x95,0xc0,0x41,0x89,0x00,0x41,0xc7};
        auto expected=base+0x797380;
        if (table[47]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushboolean");
        api.lua_pushboolean=reinterpret_cast<decltype(api.lua_pushboolean)>(table[47]);
    }
    { // lua_pushcclosure, SDK member pushcclosure
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x20,0x4c};
        auto expected=base+0x7972b0;
        if (table[46]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushcclosure");
        api.lua_pushcclosure=reinterpret_cast<decltype(api.lua_pushcclosure)>(table[46]);
    }
    { // lua_pushfstring, SDK member pushfstring
        const unsigned char prefix[16]={0x48,0x89,0x54,0x24,0x10,0x4c,0x89,0x44,0x24,0x18,0x4c,0x89,0x4c,0x24,0x20,0x53};
        auto expected=base+0x797260;
        if (table[45]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushfstring");
        api.lua_pushfstring=reinterpret_cast<decltype(api.lua_pushfstring)>(table[45]);
    }
    { // lua_pushinteger, SDK member pushinteger
        const unsigned char prefix[16]={0x48,0x8b,0x41,0x10,0x0f,0x57,0xc0,0xf2,0x48,0x0f,0x2a,0xc2,0xc7,0x40,0x08,0x03};
        auto expected=base+0x797150;
        if (table[41]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushinteger");
        api.lua_pushinteger=reinterpret_cast<decltype(api.lua_pushinteger)>(table[41]);
    }
    { // lua_pushlightuserdata, SDK member pushlightuserdata
        const unsigned char prefix[16]={0x48,0x8b,0x41,0x10,0x48,0x89,0x10,0xc7,0x40,0x08,0x02,0x00,0x00,0x00,0x48,0x83};
        auto expected=base+0x7973a0;
        if (table[48]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushlightuserdata");
        api.lua_pushlightuserdata=reinterpret_cast<decltype(api.lua_pushlightuserdata)>(table[48]);
    }
    { // lua_pushlstring, SDK member pushlstring
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57};
        auto expected=base+0x797170;
        if (table[42]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushlstring");
        api.lua_pushlstring=reinterpret_cast<decltype(api.lua_pushlstring)>(table[42]);
    }
    { // lua_pushnil, SDK member pushnil
        const unsigned char prefix[16]={0x48,0x8b,0x41,0x10,0xc7,0x40,0x08,0x00,0x00,0x00,0x00,0x48,0x83,0x41,0x10,0x10};
        auto expected=base+0x797110;
        if (table[39]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushnil");
        api.lua_pushnil=reinterpret_cast<decltype(api.lua_pushnil)>(table[39]);
    }
    { // lua_pushnumber, SDK member pushnumber
        const unsigned char prefix[16]={0x48,0x8b,0x41,0x10,0xf2,0x0f,0x11,0x08,0xc7,0x40,0x08,0x03,0x00,0x00,0x00,0x48};
        auto expected=base+0x797130;
        if (table[40]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushnumber");
        api.lua_pushnumber=reinterpret_cast<decltype(api.lua_pushnumber)>(table[40]);
    }
    { // lua_pushstring, SDK member pushstring
        const unsigned char prefix[16]={0x48,0x85,0xd2,0x75,0x0d,0x48,0x8b,0x41,0x10,0x89,0x50,0x08,0x48,0x83,0x41,0x10};
        auto expected=base+0x7971e0;
        if (table[43]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushstring");
        api.lua_pushstring=reinterpret_cast<decltype(api.lua_pushstring)>(table[43]);
    }
    { // lua_pushvalue, SDK member pushvalue
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0x4c,0x8b,0xd1,0xe8,0x34,0xfa,0xff,0xff,0x4d,0x8b,0x42,0x10};
        auto expected=base+0x796ba0;
        if (table[15]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_pushvalue");
        api.lua_pushvalue=reinterpret_cast<decltype(api.lua_pushvalue)>(table[15]);
    }
    { // lua_rawequal, SDK member rawequal
        const unsigned char prefix[16]={0x40,0x53,0x48,0x83,0xec,0x20,0x45,0x8b,0xd8,0x4c,0x8b,0xd1,0xe8,0xcf,0xf8,0xff};
        auto expected=base+0x796d00;
        if (table[28]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_rawequal");
        api.lua_rawequal=reinterpret_cast<decltype(api.lua_rawequal)>(table[28]);
    }
    { // lua_rawget, SDK member rawget
        const unsigned char prefix[16]={0x40,0x53,0x48,0x83,0xec,0x20,0x4c,0x8b,0xd1,0xe8,0x42,0xf1,0xff,0xff,0x49,0x8b};
        auto expected=base+0x797490;
        if (table[52]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_rawget");
        api.lua_rawget=reinterpret_cast<decltype(api.lua_rawget)>(table[52]);
    }
    { // lua_rawgeti, SDK member rawgeti
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0x45,0x8b,0xd0,0x4c,0x8b,0xd9,0xe8,0x01,0xf1,0xff,0xff,0x41};
        auto expected=base+0x7974d0;
        if (table[53]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_rawgeti");
        api.lua_rawgeti=reinterpret_cast<decltype(api.lua_rawgeti)>(table[53]);
    }
    { // lua_replace, SDK member replace
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x20,0x8b,0xfa,0x48,0x8b,0xd9,0x81};
        auto expected=base+0x796a60;
        if (table[18]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_replace");
        api.lua_replace=reinterpret_cast<decltype(api.lua_replace)>(table[18]);
    }
    { // lua_setfield, SDK member setfield
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x30,0x4d,0x8b,0xd0,0x48,0x8b,0xd9};
        auto expected=base+0x797690;
        if (table[59]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_setfield");
        api.lua_setfield=reinterpret_cast<decltype(api.lua_setfield)>(table[59]);
    }
    { // lua_setmetatable, SDK member setmetatable
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0x4c,0x8b,0xd1,0xe8,0x64,0xed,0xff,0xff,0x49,0x8b,0x52,0x10};
        auto expected=base+0x797870;
        if (table[62]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_setmetatable");
        api.lua_setmetatable=reinterpret_cast<decltype(api.lua_setmetatable)>(table[62]);
    }
    { // lua_settop, SDK member settop
        const unsigned char prefix[16]={0x85,0xd2,0x78,0x40,0x4c,0x63,0xc2,0x48,0x8b,0x51,0x18,0x4d,0x03,0xc0,0x4a,0x8d};
        auto expected=base+0x796960;
        if (table[14]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_settop");
        api.lua_settop=reinterpret_cast<decltype(api.lua_settop)>(table[14]);
    }
    { // lua_toboolean, SDK member toboolean
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0xe8,0x17,0xf7,0xff,0xff,0x8b,0x48,0x08,0x85,0xc9,0x74,0x14};
        auto expected=base+0x796ec0;
        if (table[32]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_toboolean");
        api.lua_toboolean=reinterpret_cast<decltype(api.lua_toboolean)>(table[32]);
    }
    { // lua_tointeger, SDK member tointeger
        const unsigned char prefix[16]={0x48,0x83,0xec,0x38,0xe8,0x77,0xf7,0xff,0xff,0x8b,0x48,0x08,0x83,0xf9,0x03,0x74};
        auto expected=base+0x796e60;
        if (table[31]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_tointeger");
        api.lua_tointeger=reinterpret_cast<decltype(api.lua_tointeger)>(table[31]);
    }
    { // lua_tolstring, SDK member tolstring
        const unsigned char prefix[16]={0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x20,0x49};
        auto expected=base+0x796ef0;
        if (table[33]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_tolstring");
        api.lua_tolstring=reinterpret_cast<decltype(api.lua_tolstring)>(table[33]);
    }
    { // lua_tonumber, SDK member tonumber
        const unsigned char prefix[16]={0x48,0x83,0xec,0x38,0xe8,0xd7,0xf7,0xff,0xff,0x8b,0x48,0x08,0x83,0xf9,0x03,0x74};
        auto expected=base+0x796e00;
        if (table[30]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_tonumber");
        api.lua_tonumber=reinterpret_cast<decltype(api.lua_tonumber)>(table[30]);
    }
    { // lua_touserdata, SDK member touserdata
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0xe8,0x97,0xf5,0xff,0xff,0x8b,0x48,0x08,0x83,0xf9,0x02,0x74};
        auto expected=base+0x797040;
        if (table[36]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_touserdata");
        api.lua_touserdata=reinterpret_cast<decltype(api.lua_touserdata)>(table[36]);
    }
    { // lua_type, SDK member type
        const unsigned char prefix[16]={0x48,0x83,0xec,0x28,0xe8,0x07,0xfa,0xff,0xff,0x48,0x8d,0x0d,0x00,0x2c,0xf6,0x00};
        auto expected=base+0x796bd0;
        if (table[25]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_type");
        api.lua_type=reinterpret_cast<decltype(api.lua_type)>(table[25]);
    }
    { // lua_typename, SDK member lua_typename
        const unsigned char prefix[16]={0x83,0xfa,0xff,0x75,0x08,0x48,0x8d,0x05,0x74,0x0d,0xfa,0x00,0xc3,0x48,0x63,0xc2};
        auto expected=base+0x796c00;
        if (table[26]!=expected || !readable(expected,16,true) || std::memcmp(expected,prefix,16))
            return fail("LuaApi validation failed: lua_typename");
        api.lua_typename=reinterpret_cast<decltype(api.lua_typename)>(table[26]);
    }
    if (!hd2_cffi_bind(&api)) return fail("Host API binding rejected");
    boot_status="validated build 26088801 and all 53 LuaApi slots";
    return true;
}
HD2_EXPORT int luaopen_hd2_cffi(lua_State *L) {
    if (!L) {fail("Null Lua state");return 0;}
    if (!bind_current_host()) return 0;
    return luaopen_cffi(L);
}
