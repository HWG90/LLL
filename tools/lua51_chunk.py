"""Validate and convert Lua 5.1 chunk string-length width, without executing it.

Steam's stock Lua 5.1 chunks use four-byte size_t, including on Windows x64.
The local test compiler uses eight-byte size_t. Instruction/int/number ABIs must
otherwise match; this is not a LuaJIT bytecode converter.
"""
import struct


def convert(data, size_t):
    if len(data) < 12 or data[:8] != b'\x1bLua\x51\x00\x01\x04':
        raise ValueError('Expected little-endian Lua 5.1 chunk with four-byte int')
    source_width = data[8]
    if source_width not in (4, 8) or size_t not in (4, 8) or data[9:12] != b'\x04\x08\x00':
        raise ValueError('Unsupported Lua 5.1 ABI')
    output = bytearray(data[:8] + bytes([size_t]) + data[9:12])
    position = 12

    def take(length):
        nonlocal position
        if length < 0 or position + length > len(data):
            raise ValueError('Truncated Lua chunk')
        value = data[position:position + length]
        position += length
        return value

    def count():
        value = take(4)
        result = struct.unpack('<I', value)[0]
        if result > len(data):
            raise ValueError('Invalid Lua chunk count')
        output.extend(value)
        return result

    def string():
        length = int.from_bytes(take(source_width), 'little')
        if length >= 1 << (size_t * 8):
            raise ValueError('String length exceeds target ABI')
        value = take(length)
        if length and value[-1] != 0:
            raise ValueError('Unterminated Lua chunk string')
        output.extend(length.to_bytes(size_t, 'little'))
        output.extend(value)

    def function(depth):
        if depth > 100:
            raise ValueError('Lua chunk nesting exceeds limit')
        string()
        output.extend(take(12))  # line bounds and four one-byte function fields
        output.extend(take(count() * 4))
        for _ in range(count()):
            tag = take(1)
            output.extend(tag)
            if tag == b'\x01':
                output.extend(take(1))
            elif tag == b'\x03':
                output.extend(take(8))
            elif tag == b'\x04':
                string()
            elif tag != b'\x00':
                raise ValueError('Invalid Lua chunk constant')
        for _ in range(count()):
            function(depth + 1)
        output.extend(take(count() * 4))
        for _ in range(count()):
            string()
            output.extend(take(8))
        for _ in range(count()):
            string()

    function(0)
    if position != len(data):
        raise ValueError('Trailing Lua chunk data')
    return bytes(output)
