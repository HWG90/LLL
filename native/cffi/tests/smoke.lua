local ffi = require('cffi')
ffi.cdef [[
int ffi_test_add(int a, int b);
int ffi_test_callback(int (*callback)(int), int value);
]]
local lib = ffi.load(assert(FFI_TEST_LIBRARY))
assert(ffi.tonumber(lib.ffi_test_add(19, 23)) == 42)
local array = ffi.new('int[3]', {4, 5, 6})
assert(ffi.tonumber(array[1]) == 5)
local callback = ffi.cast('int (*)(int)', function(n) return ffi.tonumber(n)*2 end)
assert(ffi.tonumber(lib.ffi_test_callback(callback, 20)) == 41)
callback:free()
local ok = pcall(ffi.cdef, 'this is not a C declaration;')
assert(not ok, 'parser errors must remain contained in Lua pcall')
local ok2 = pcall(ffi.load, 'nonexistent_ffi_test_library_979013')
assert(not ok2, 'missing library must raise a Lua error')
print('PASS: ffi.load, cdef, call, array, callback, parser error, missing library')

-- Regression: CFFI pointer subtraction across element sizes and signs.
local ptrffi=require('cffi')
local function address(p)return ptrffi.tonumber(ptrffi.cast('uintptr_t',p))end
for _,ctype in ipairs({'uint8_t *','uint32_t *','uint64_t *'})do
 local p=ptrffi.cast(ctype,0x100000)
 local size=ptrffi.sizeof(ctype:gsub(' %*',''))
 for _,n in ipairs({-31,-1,0,1,24,31})do
  assert(address(p-n)==0x100000-n*size,'Pointer subtraction direction/stride')
  assert((p+n)-p==n,'Positive pointer difference')
  assert(p-(p+n)==-n,'Negative pointer difference')
 end
end
local a=ptrffi.new('uint32_t[8]')
assert(address(a-1)==address(a)-4,'Array subtraction must yield pointer')
print('PASS pointer subtraction: signed offsets, strides1/4/8, positive/negative differences, arrays')
