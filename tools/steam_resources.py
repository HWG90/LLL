"""Bounded, read-only access to Steam DSAA/DSAR stock resources.

Reads only blocks intersecting a requested range; never unpacks the game tree.
DSAR version 0x10003 uses independent LZ4 blocks. Requires Python lz4.
"""
from bisect import bisect_right
from pathlib import Path
import argparse
import struct

import lz4.block


class DSAR:
    def __init__(self, path):
        self.path = Path(path)
        length = self.path.stat().st_size
        with self.path.open('rb') as stream:
            header = stream.read(32)
            if len(header) != 32:
                raise ValueError('Truncated DSAR header')
            magic, version, count, end, self.size, _ = struct.unpack('<4I2Q', header)
            if magic != 0x52415344 or version != 0x10003:
                raise ValueError('Unsupported DSAR format')
            if count > 1000000 or end < 32 + count * 32 or end > length:
                raise ValueError('Invalid DSAR block table')
            table = stream.read(count * 32)
        self.blocks = []
        expected = 0
        for index in range(count):
            logical, physical, raw, packed, codec = struct.unpack_from('<QQIIB', table, index * 32)
            if logical != expected or raw <= 0 or (codec == 3 and raw > 16 * 1024 * 1024):
                raise ValueError('Invalid DSAR logical block')
            if codec not in (0, 3) or physical < end or physical + packed > length or not packed or (codec == 0 and raw != packed):
                raise ValueError('Invalid DSAR compressed block')
            self.blocks.append((logical, physical, raw, packed, codec))
            expected += raw
        if expected != self.size:
            raise ValueError('DSAR size mismatch')
        self.starts = [block[0] for block in self.blocks]

    def read(self, offset, size):
        if offset < 0 or size < 0 or offset + size > self.size:
            raise ValueError('DSAR read outside logical file')
        if not size:
            return b''
        result = bytearray()
        index = bisect_right(self.starts, offset) - 1
        with self.path.open('rb') as stream:
            while index < len(self.blocks):
                logical, physical, raw, packed, codec = self.blocks[index]
                if logical >= offset + size:
                    break
                low, high = max(0, offset - logical), min(raw, offset + size - logical)
                stream.seek(physical + (low if codec == 0 else 0))
                chunk = stream.read(high - low if codec == 0 else packed)
                if codec == 3:
                    chunk = lz4.block.decompress(chunk, uncompressed_size=raw)[low:high]
                if len(chunk) != high - low:
                    raise ValueError('DSAR decompressed size mismatch')
                result.extend(chunk)
                index += 1
        if len(result) != size:
            raise ValueError('Incomplete DSAR range')
        return bytes(result)


class SteamResources:
    def __init__(self, data):
        self.root = Path(data)
        index = DSAR(self.root / 'bundles.nxa')
        if index.size > 128 * 1024 * 1024:
            raise ValueError('Oversized DSAA index')
        self.index = index.read(0, index.size)
        if len(self.index) < 24:
            raise ValueError('Truncated DSAA header')
        magic, version, size, self.bundle_count, count, _ = struct.unpack_from('<6I', self.index)
        if magic != 0x41415344 or version != 0x10001 or size != len(self.index):
            raise ValueError('Unsupported DSAA index')
        if self.bundle_count > 256 or count > 1000000 or 24 + count * 24 > size:
            raise ValueError('Invalid DSAA file table')
        self.files = {}
        for position in range(count):
            length, name_at, chunks, chunk_at = struct.unpack_from('<QIIQ', self.index, 24 + position * 24)
            name_end = self.index.find(b'\0', name_at, min(size, name_at + 1024))
            if name_at < 24 + count * 24 or name_end < 0 or chunks > 1000000 or chunk_at + chunks * 16 > size:
                raise ValueError('Invalid DSAA file record')
            name = self.index[name_at:name_end].decode('ascii')
            if '/' in name or '\\' in name or name in self.files:
                raise ValueError('Unsafe or duplicate DSAA filename')
            self.files[name] = (length, chunks, chunk_at)
        self.bundles = {}

    def read(self, name, offset, size):
        length, count, table = self.files[name]
        if offset < 0 or size < 0 or offset + size > length:
            raise ValueError('Stock archive read outside logical file')
        result = bytearray()
        previous = -1
        for index in range(count):
            start, packed = struct.unpack_from('<QQ', self.index, table + index * 16)
            end = struct.unpack_from('<Q', self.index, table + (index + 1) * 16)[0] if index + 1 < count else length
            if start <= previous or end <= start or end > length:
                raise ValueError('Invalid DSAA chunk ordering')
            previous = start
            if end <= offset or start >= offset + size:
                continue
            bundle, physical = packed >> 56, packed & 0x00ffffffffffffff
            if bundle >= self.bundle_count:
                raise ValueError('Invalid DSAA bundle number')
            if bundle not in self.bundles:
                self.bundles[bundle] = DSAR(self.root / f'bundles.{bundle:02}.nxa')
            low, high = max(start, offset), min(end, offset + size)
            result.extend(self.bundles[bundle].read(physical + low - start, high - low))
        if len(result) != size:
            raise ValueError('Incomplete stock archive range')
        return bytes(result)

    def resources(self, name):
        header = self.read(name, 0, 72)
        magic, types, count = struct.unpack_from('<III', header)
        if magic != 0xf0000011 or types > 100000 or count > 100000:
            raise ValueError('Unsupported stock archive')
        start = 72 + types * 32
        table = self.read(name, start, count * 80)
        length = self.files[name][0]
        for index in range(count):
            at = index * 80
            identity, kind, offset = struct.unpack_from('<QQQ', table, at)
            size = struct.unpack_from('<I', table, at + 56)[0]
            if offset < start + len(table) or offset + size > length:
                raise ValueError('Invalid stock resource range')
            yield identity, kind, offset, size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('data', type=Path)
    parser.add_argument('archive')
    parser.add_argument('--resource', help='Resource name hash in hexadecimal')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    stock = SteamResources(args.data)
    for identity, kind, offset, size in stock.resources(args.archive):
        if args.resource is None:
            print(f'{identity:016x} {kind:016x} {offset:x} {size}')
        elif identity == int(args.resource, 16):
            if args.output is None:
                parser.error('--resource requires --output')
            with args.output.open('xb') as stream:
                stream.write(stock.read(args.archive, offset, size))
            return
    if args.resource is not None:
        raise SystemExit('Resource not found')


if __name__ == '__main__':
    main()
