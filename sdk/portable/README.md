# Portable data SDK v1

`lll_portable.lua` is a standalone Lua 5.1 module. It implements real 32-bit bit
operations and fixed-width integer byte codecs. It does not install `ffi`,
`bit`, `package.loaded` aliases or any globals. It makes no native calls, reads
no process memory and starts no callbacks, tasks, timers, watchers or IPC.
The working LLL runtime does not need changing to use this source module.

Copy the file into your modular project's declared sources, for example
`vendor/lll_portable.lua`, then load it explicitly:

```lua
local data = mod.require('vendor.lll_portable')
assert(data.version == 1 and data.capabilities.integer_codecs)
local flags = data.bit.bor(0x100, 0x20)
local encoded = data.bytes.write_u32(flags) -- little endian by default
local value, next_offset = data.bytes.read_u32(encoded)
```

A standalone host can use `dofile` instead. This is a source SDK, not an
automatic port of a mod that imports LuaJIT libraries. Existing LLL preflight
still refuses declared `ffi`, `bit` and `jit` imports on the Steam Lua 5.1 VM.

## Bit operations

`data.bit` supplies `tobit`, `band`, `bor`, `bxor`, `bnot`, `lshift`, `rshift`, `arshift`,
`rol`, `ror`, `bswap` and `tohex`. Numeric results are signed 32-bit values,
matching LuaJIT bit results for accepted inputs. `band`/`bor`/`bxor` accept one
or more operands; they require at least one. Shifts and rotations use the low
five bits of the count, including negative counts.

Every word and shift count must be a finite integer in
`[-2147483648, 4294967295]`. Numeric strings, fractions and wider values are
rejected rather than silently rounded or coerced. This input contract is
narrower than LuaJIT's general numeric conversion rules. `tohex(value, digits)`
defaults to eight lowercase digits; `digits` must be an integer from -8 to 8.
Negative counts select uppercase; zero returns an empty string. Hex conversion
keeps the requested least-significant digits.

Binary operations use eight nibble lookups per additional operand, without
allocating an intermediate table. Lookup tables are built once when the module
loads. Shifts reduce before multiplication to keep intermediate values exact.
The module performs work only when loaded or called; it has no idle cost from
callbacks or helper requests.

## Integer byte codecs

| Read | Return values | Write |
| --- | --- | --- |
| `bytes.read_u16(source, offset, order)` | unsigned value, next offset | `bytes.write_u16(value, order)` |
| `bytes.read_i16(source, offset, order)` | signed value, next offset | `bytes.write_i16(value, order)` |
| `bytes.read_u32(source, offset, order)` | unsigned value, next offset | `bytes.write_u32(value, order)` |
| `bytes.read_i32(source, offset, order)` | signed value, next offset | `bytes.write_i32(value, order)` |
| `bytes.read_u64(source, offset, order)` | unsigned low word, unsigned high word, next offset | `bytes.write_u64(low, high, order)` |

`bytes` above means `data.bytes`. Source data is an ordinary binary Lua string,
including embedded zeros. Offsets are one-based integers, default to 1, and must
leave the entire value within the string. `order` is `'le'` (the default) or
`'be'`. Writes return one new value-sized string of 2, 4 or 8 bytes; they do not
mutate an array or memory address. Inputs outside the named signed/unsigned
range are errors. Both u64 words are unsigned integers from 0 to 4294967295.

Keep 64-bit integers as two words. Combining them into a Lua number can lose
precision above 2^53. A data-only union previously used for byte conversion can
be replaced explicitly:

```lua
-- Before, on little-endian LuaJIT:
-- local u = ffi.new('union { uint64_t value; uint32_t word[2]; }[1]')
-- u[0].word[0], u[0].word[1] = 0x89abcdef, 0x01234567
-- local encoded = ffi.string(u, 8)

local encoded = data.bytes.write_u64(0x89abcdef, 0x01234567, 'le')
local low, high, next_offset = data.bytes.read_u64(encoded, 1, 'le')
assert(low == 0x89abcdef and high == 0x01234567 and next_offset == 9)
```

This replaces the union's byte representation, not a native pointer or native
integer object. An old `ffi.C`/DLL call still needs a real supported backend;
this module does not implement it. Existing LLL input and screenshot services
remain separate APIs with their own capabilities and ownership contracts.

The integer module's `float32`, `native_memory`, `native_calls`,
`mutable_buffers` and `ffi` capabilities remain false. Float codecs and mutable
Lua-owned float arrays are supplied separately by `lll_float32.lua`, below.
C declarations/layouts, arbitrary native calls and raw pointers still require
other providers.

## Float32 codecs and mutable arrays

Vendor `lll_float32.lua` alongside the integer module and import it explicitly:

```lua
local f32 = mod.require('vendor.lll_float32')
local values = f32.array(4)
values:set(0, 0.1)                  -- rounds once to IEEE754 binary32
values:fill(1.0, 1, 3)
local tail = values:view(1, 3)      -- checked, zero-based shared view
local encoded = values:export(0, 4, 'le')
values:release()                   -- invalidates tail and all nested views
assert(not tail:alive())
```

The scalar API is `to_bits(number)`, `from_bits(u32)`, `round(number)`,
`write(number, order)` and `read(bytes, offset, order)`. Byte order defaults to
`'le'`; offsets are one-based. Reads return the number and next offset.
Conversions use round-to-nearest, ties-to-even, including subnormals, the
normal/subnormal boundary and overflow. Signed zero and infinities round trip.
NaN writes/imports canonicalize to positive quiet NaN `0x7fc00000`; NaN payload
bits are not preserved.

`array(count, initial)` defaults to zero and permits 0 through 262144 elements
(at most 1 MiB encoded; Lua table storage is larger). Methods use zero-based
element indices: `get`, `set`, `fill(value, start, count)`,
`copy(source, source_start, destination_start, count)`, `view(start, count)`,
`export(start, count, order)`, `import(bytes, offset, start, count, order)`,
`length`, `alive`, and owner-only `release`. Omitted ranges extend to the end;
the copy count defaults to the source's remaining range. Import returns its
next byte offset; other mutators return true. Copy handles overlapping views
like `memmove`. Release is idempotent and invalidates every view.

Storage keeps private 32-bit words. `get`/`set` are constant time; `fill`
rounds the fill value once and `copy` copies words. Scalar edits do not
re-encode the whole array. Export joins chunks of 256 words, rather than
repeatedly appending to one growing string. There are no frame callbacks,
watchers, helper requests or idle tasks. These are checked Lua data views;
they do not contain C addresses and cannot be passed to an engine C function.

The float module advertises `float32`, `round_to_nearest_even`,
`mutable_arrays` and `views`. Its native-memory, native-pointer, native-call
and FFI capabilities are false. Six focused tests compare Python `struct`
and actual LuaJIT FFI conversions, test rounding midpoints and special values,
exercise ownership/bounds/overlap, and verify that scalar edits do not encode
the full array. Run them with:

```powershell
py -3.14 -m unittest discover -s tests -p test_steam_float32.py -v
```

The focused Python suite uses actual Lua 5.1, LuaJIT's bit library as the bit
oracle, Python `struct` as the integer-codec oracle, seeded random cases and
malformed/bounds checks. Run it separately; the SDK has no test-time native
backend or game access requirement:

```powershell
py -3.14 -m unittest discover -s tests -p test_steam_portable.py -v
```

## Qualification on the current Steam runtime

The six focused tests passed, along with four native-import preflight checks.
A temporary, hash-verified mod then ran 128 independent golden cases in the
current game's Lua 5.1 VM: 64 bit-operation cases and 64 integer/byte cases.
All passed across eight updates of 16 cases. SDK initialization and those small
compute batches were below the available `os.clock` resolution; the reported
zero deltas are not evidence of zero execution time. The loader's broader
source-loading health measurement was 5 ms and includes more than SDK compute.

An offline batch of 10,000 XOR calls in Lua 5.1 measured approximately 10 ms,
with no measured temporary allocation while GC was stopped. This is one local
sample, not a throughput guarantee for a full LUT or another mod. Large data
consumers still need representative end-to-end measurements.

The temporary proof source was removed. Installed startup/helper bytes and user
settings stayed hash-identical; R34's production runtime was not replaced.
