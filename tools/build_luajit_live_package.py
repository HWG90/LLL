"""Build the LuaJIT Live drop-in package for HD2 Arsenal (Steam build 26088801): patches only.

Options of the one Arsenal mod:
  LuaJIT VM + Live Lua Loader  LLL R35's boot patch with src/luajit_live/prologue_dropin.lua in
                               front. The runtime travels inside the boot chunk; at boot it is
                               written to data/hd2_luajit_runtime_<hash>.dll, checked byte for byte
                               and loaded. The outcome goes to %LOCALAPPDATA%/HD2-LuaJIT-boot-result.txt.
                               If the load is refused, R35 boots in Lua 5.1 exactly as its own patch.
  Mod Options Menu 1.2.1       optional (--mom): CowboyBingus's mod with its build data remapped to 26088801,
  Match Your Colors 1.5        optional (--myc): the same. Both are LuaJIT VM test mods kept outside this
                               repository (the Linux HD2 workspace's bingus-ports/, built by its
                               native-work/mom-port and native-work/myc-port); --licenses names the folder
                               holding ModOptionsMenu/LICENSE and MatchYourColors/LICENSE. Without the three
                               options the package carries the LuaJIT VM and LLL alone.

The R35 boot source must compile (32-bit stock Lua 5.1.4, chunk '@native-font-repair') to the
R35 boot archive's chunk byte for byte; the prologue is then compiled in front of it.

usage: build_luajit_live_package.py --lll-archive <R35 9ba626afa44a3aa3.patch_0> --lll-source <R35 boot source.lua>
         --lua51-32 <lua 5.1.4 32-bit> --runtime <hd2 LuaJIT runtime DLL> --output <zip>
         [--mom <archive> --myc <archive> --licenses <folder with ModOptionsMenu/LICENSE, MatchYourColors/LICENSE>]
"""
from pathlib import Path
import argparse, hashlib, json, struct, subprocess, tempfile, zipfile, zlib

ROOT = Path(__file__).resolve().parents[1]
BOOT, LUA = 0xf476df93691895fa, 0xa14e8dfa2cd117e2
ARCHIVE = '9ba626afa44a3aa3.patch_0'
GUID = '5b0f3c2e-8d1a-4e62-9f47-2a6c1d8e7b30'
README = """HD2 LuaJIT VM - LuaJIT Live (Steam build 26088801)

WHAT THIS IS
The game's Lua VM replaced by LuaJIT 2.1 at boot (JIT, ffi and bit), with Live Lua Loader running
its own LuaJIT build (no external helper, no cffi DLL). Proven on Linux/Proton. On native Windows
the game has refused other custom DLLs with system error 577 (ERROR_INVALID_IMAGE_HASH); this
package reports what happens there and does not try to get around it.

INSTALL (HD2 Arsenal)
1. Close Helldivers 2. In Arsenal disable any other Live Lua Loader, and the Megapack's
   Mod Options Menu and Match Your Colors options if you have them.
2. Import this ZIP, enable the options you want ("LuaJIT VM + Live Lua Loader" is required),
   then Purge / Deploy and start the game.

RESULT
%LOCALAPPDATA%\\HD2-LuaJIT-boot-result.txt has one line per start:
  "LuaJIT boot taken (...)"            the runtime loaded; see LLL\\Helldivers2\\Logs\\LuaJITBoot.log
                                       and LiveLuaLoader.log ("R31-bsl-v20", "JIT on")
  "boot handoff not taken ...: <why>"  the runtime was refused; <why> is the exact loader error
If it is refused, the game boots with LLL R35 in its normal Lua 5.1 mode. That mode needs LLL's
external helper (installed by LLL's own Install.ps1); without it LLL reports that its filesystem
service is unavailable and the game runs unmodded.

KNOWN LIMITS
LLL's LuaJIT build has no shared input service (the Steam helper provides it), so mods that need
it (for example DBF-MCM, DBF freecam) do not enable. Mods ported to the Lua 5.1 VM that
require('cffi') get the runtime's alias over LuaJIT's ffi.

FILES
The runtime is written once to the game's data folder as hd2_luajit_runtime_<hash>.dll (checked
byte for byte before every load). Arsenal's purge removes the patches; delete that DLL by hand to
remove everything. Nothing else is written except the result file and LLL's own logs/settings.
LICENSES/ holds the notices for LuaJIT, the two CowboyBingus mods and this package's contents.
"""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def dump(lua32, source, name, work):
    script = work / 'dump.lua'
    script.write_text("local src,name,out=...\nlocal f=assert(io.open(src,'rb'));local s=f:read('*a');f:close()\n"
                      "local fn=assert(loadstring(s,name))\nlocal o=assert(io.open(out,'wb'));o:write(string.dump(fn));o:close()\n")
    out = work / 'chunk.luac'
    subprocess.run([str(lua32), str(script), str(source), name, str(out)], check=True)
    return out.read_bytes()


def boot_archive(original, chunk):
    """LLL's single-resource boot archive with only the resource body, size fields and padding changed."""
    magic, types, count = struct.unpack_from('<III', original)
    if not (magic == 0xf0000011 and types == 1 and count == 1):
        raise ValueError('Not a single-resource boot archive')
    e = list(struct.unpack_from('<7Q6I', original, 104))
    if not (e[0] == BOOT and e[1] == LUA and e[2] == 0xc0):
        raise ValueError('Not the LLL boot resource')
    length, kind = struct.unpack_from('<II', original, e[2])
    if kind != 1 or length != e[7] - 8 or struct.unpack_from('<I', original, 32)[0] != len(original):
        raise ValueError('Unexpected boot archive layout')
    body = struct.pack('<II', len(chunk), kind) + chunk
    total = e[2] + len(body)
    total += (-total) % 16
    out = bytearray(original[:e[2]])
    struct.pack_into('<I', out, 32, total)
    e[7] = len(body)
    struct.pack_into('<7Q6I', out, 104, *e)
    out += body
    out += b'\0' * (total - len(out))
    return bytes(out), original[e[2] + 8:e[2] + 8 + length]


def png(size=64):
    """A plain icon: orange square with a dark border (no image library)."""
    rows = b''.join(b'\0' + b''.join(bytes((30, 30, 30)) if min(x, y, size - 1 - x, size - 1 - y) < 4 else bytes((242, 140, 40))
                                     for x in range(size)) for y in range(size))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    for name in ('lll-archive', 'lll-source', 'lua51-32', 'runtime', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    # The CowboyBingus test mods, kept outside this repository: both archives and the folder with their LICENSE
    # files, or none of the three.
    for name in ('mom', 'myc', 'licenses'):
        parser.add_argument('--' + name, type=Path)
    args = parser.parse_args()
    bundled = [n for n in ('mom', 'myc', 'licenses') if getattr(args, n)]
    if bundled and len(bundled) != 3:
        parser.error('--mom, --myc and --licenses go together')
    original, lll, dll = args.lll_archive.read_bytes(), args.lll_source.read_bytes(), args.runtime.read_bytes()
    if dll[:2] != b'MZ':
        raise ValueError('The runtime must be a Windows DLL')
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        _, installed = boot_archive(original, b'')
        (work / 'lll.lua').write_bytes(lll)
        if dump(args.lua51_32, work / 'lll.lua', '@native-font-repair', work) != installed:
            raise ValueError('The LLL source does not reproduce the boot archive chunk')
        name = 'hd2_luajit_runtime_%s.dll' % sha(dll)[:16]
        prologue = (ROOT / 'src/luajit_live/prologue_dropin.lua').read_text()
        if prologue.count('@RUNTIME_NAME@') != 1 or prologue.count('@RUNTIME_BYTES@') != 1:
            raise ValueError('Prologue placeholders missing')
        prologue = prologue.replace('@RUNTIME_NAME@', name).replace(
            '@RUNTIME_BYTES@', '"' + ''.join('\\%03d' % b for b in dll) + '"')
        (work / 'boot.lua').write_bytes(prologue.encode() + lll)
        chunk = dump(args.lua51_32, work / 'boot.lua', '@native-font-repair', work)
    if chunk[:12] != installed[:12] or dll not in chunk:
        raise ValueError('Boot chunk header or embedded runtime unexpected')
    patch, _ = boot_archive(original, chunk)
    files, folders = {'LuaJIT-LLL/' + ARCHIVE: patch}, ['LuaJIT-LLL']
    options = [{'Name': 'LuaJIT VM + Live Lua Loader', 'Include': ['LuaJIT-LLL'],
                'Description': 'Required. LLL R35 boot patch carrying the LuaJIT runtime; falls back to LLL in Lua 5.1 if the runtime is refused.'}]
    licenses = [('LuaJIT-COPYRIGHT.txt', ROOT / 'docs/LUAJIT-COPYRIGHT.txt'), ('LUAJIT-LIVE-NOTICES.txt', ROOT / 'docs/LUAJIT-LIVE-NOTICES.txt'),
                ('LLL-CONTENTS-NOTICES.txt', ROOT / 'docs/CONTENTS-NOTICES.txt')]
    readme = README
    if bundled:
        files['ModOptionsMenu/' + ARCHIVE] = args.mom.read_bytes()
        files['MatchYourColors/' + ARCHIVE] = args.myc.read_bytes()
        folders += ['ModOptionsMenu', 'MatchYourColors']
        options += [{'Name': 'Mod Options Menu 1.2.1 (LuaJIT)', 'Include': ['ModOptionsMenu'],
                     'Description': 'Native MODS tab on the Options screen. Needs the LuaJIT VM.'},
                    {'Name': 'Match Your Colors 1.5 (LuaJIT)', 'Include': ['MatchYourColors'],
                     'Description': 'Helmet, armor, cape and weapon recoloring. Needs the LuaJIT VM.'}]
        licenses += [('ModOptionsMenu-0BSD.txt', args.licenses / 'ModOptionsMenu/LICENSE'),
                     ('MatchYourColors-0BSD.txt', args.licenses / 'MatchYourColors/LICENSE')]
    else:
        for old, new in (("In Arsenal disable any other Live Lua Loader, and the Megapack's\n"
                          "   Mod Options Menu and Match Your Colors options if you have them.",
                          'In Arsenal disable any other Live Lua Loader.'),
                         ('LICENSES/ holds the notices for LuaJIT, the two CowboyBingus mods and this package\'s contents.',
                          'LICENSES/ holds the notices for LuaJIT and this package\'s contents.')):
            if readme.count(old) != 1:
                raise ValueError('README text to adapt not found: ' + old[:40])
            readme = readme.replace(old, new)
    for folder in folders:
        for suffix in ('.stream', '.gpu_resources'):
            files[folder + '/' + ARCHIVE + suffix] = b''
    manifest = {'Version': 1, 'Guid': GUID, 'Name': 'HD2 LuaJIT VM - LuaJIT Live (26088801)',
                'Description': 'The game Lua VM as LuaJIT, with Live Lua Loader in LuaJIT. Writes the boot result to '
                               '%LOCALAPPDATA%\\HD2-LuaJIT-boot-result.txt. See README.txt.',
                'IconPath': 'icon.png', 'Options': options}
    files['manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    files['icon.png'] = png()
    files['README.txt'] = readme.replace('\n', '\r\n').encode()
    for target, source in licenses:
        files['LICENSES/' + target] = source.read_bytes()
    files['SHA256SUMS.txt'] = ''.join('%s  %s\n' % (sha(data), n) for n, data in sorted(files.items())).encode()
    with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as z:
        for n, data in sorted(files.items()):
            info = zipfile.ZipInfo(n, (2026, 10, 24, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)
    print(json.dumps({'zip': str(args.output), 'zip_sha256': sha(args.output.read_bytes()), 'runtime': name,
                      'boot_archive_sha256': sha(patch)}, indent=1))


if __name__ == '__main__':
    main()
