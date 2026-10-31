#!/usr/bin/env python3
"""Describe a Factorio macOS executable for porting, without changing it.

Run on your Mac against a version the build does not accept yet, and share the
output: it holds hashes, counts and yes/no checks only, no game code or data.

    python3 tools/inspect_executable.py --app /path/to/factorio.app
"""
import argparse
import hashlib
import plistlib
import struct
import sys
from pathlib import Path

from config import SUPPORTED_SOURCES, validate_patch_layout
from macho import MachO
from entrypoint import curl_default_ca_sites, shipped_ca_site

# What the 2.1.23 port was audited with (docs/DEVELOPMENT.md).
REFERENCE = {'sdl': '3.4.14'}


def movz_movk_value(data, offset):
    """The 32-bit constant a `movz w0, #lo` / `movk w0, #hi, lsl 16` pair loads, or None."""
    lo, hi = struct.unpack_from('<II', data, offset)
    if lo & 0xff800000 != 0x52800000 or hi & 0xffe00000 != 0x72a00000:
        return None
    return ((hi >> 5) & 0xffff) << 16 | ((lo >> 5) & 0xffff)


def sdl_version_from_int(value):
    """SDL 3 packs its version as major*1000000 + minor*1000 + micro."""
    return f'{value // 1000000}.{value // 1000 % 1000}.{value % 1000}'


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--app', type=Path, required=True, help='The factorio.app to describe')
    args = parser.parse_args()
    app = args.app.expanduser().resolve()
    binary = app / 'Contents/MacOS/factorio'
    if not binary.is_file():
        sys.exit(f'No Factorio executable at {binary}')
    raw = binary.read_bytes()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    print('version:', info.get('CFBundleShortVersionString'), 'build:', info.get('CFBundleVersion'))
    print('sha256:', hashlib.sha256(raw).hexdigest())
    print('already supported:', SUPPORTED_SOURCES.get(hashlib.sha256(raw).hexdigest(), 'no'))

    macho = MachO(binary)   # takes the arm64 slice of a universal file
    data = macho.data
    symbols = {s['name']: s for s in macho.symbols() if 'library' not in s}
    base = 0x100000000

    names = ('_main', '_SDL_Init', '_SDL_GetVersion_REAL', '_SDL_GetDisplays', '_SDL_GetDisplay',
             '__ZN9SDLWindow11logDisplaysEv', '__ZN9SDLWindow18logDisplayAdaptersEv')
    for name in names:
        print(f'symbol {name}:', 'yes' if name in symbols else 'no')
    sdl_major = 3 if '_SDL_GetDisplays' in symbols else 2
    print('SDL major:', sdl_major)
    if '_SDL_GetVersion_REAL' in symbols:
        value = movz_movk_value(data, symbols['_SDL_GetVersion_REAL']['address'] - base)
        print('SDL version:', sdl_version_from_int(value) if value else 'unrecognised instructions',
              f'(the port pins {REFERENCE["sdl"]})')
    text_sdl = [s for s in symbols.values() if s['name'].startswith('_SDL_')
                and 0 < s['section'] <= len(macho.sections) and macho.sections[s['section'] - 1]['name'] == '__text']
    print('SDL functions in __text:', len(text_sdl))

    steam = ('__ZNK21SteamContextInterface21getCloudFileTimestamp', '__ZNK21SteamContextInterface15cloudFileExists',
             '__ZNK21SteamContextInterface13readCloudFile')
    for prefix in steam:
        print(f'Steam Cloud stand-in target {prefix[25:]}:', 'yes' if any(n.startswith(prefix) for n in symbols) else 'no')
    print('MainLoop::run (Steam notice patch):', 'yes' if any(n.startswith('__ZN8MainLoop3runE') for n in symbols) else 'no')
    print('Steam notice text:', 'yes' if b'gui-update.could-not-init-steam\0' in data else 'no')
    print('curl default-CA sites (login fix needs 2):', len(curl_default_ca_sites(macho, data, base)))
    print('shipped CA fallback site (login fix):', 'yes' if shipped_ca_site(macho, data, base) is not None else 'no')
    for backend in (b'SecureTransport', b'OpenSSL', b'BoringSSL', b'mbedTLS'):
        print(f'TLS backend text {backend.decode()}:', 'yes' if backend in data else 'no')
    print('libsteam_api linked:', 'yes' if any('libsteam_api' in lib for lib in macho.libraries) else 'no')

    # Where the build puts its redirect pointers and stubs (config.validate_patch_layout).
    segments = {bytes(data[p + 8:p + 24]).rstrip(b'\0').decode(): p for c, p, n in macho.commands if c == 0x19}
    for name, p in segments.items():
        vm, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, p + 24)
        print(f'segment {name}: vmsize {vmsize:#x} filesize {filesize:#x}')
    if '__DATA_CONST' in segments and '__DATA' in segments:
        vm, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, segments['__DATA_CONST'] + 24)
        last = max(x['offset'] + x['size'] for x in macho.sections if x['segment'] == '__DATA_CONST')
        slot = (last + 7) & ~7
        const_free = (fileoff + filesize - slot) // 8
        const_zero = data[slot:fileoff + filesize] == bytes(fileoff + filesize - slot)
        data_vm, data_vmsize, _, data_size = struct.unpack_from('<QQQQ', data, segments['__DATA'] + 24)
        bss_end = max(x['address'] + x['size'] for x in macho.sections if x['segment'] == '__DATA')
        bss_slot = (bss_end + 7) & ~7
        data_free = (data_vm + data_vmsize - bss_slot) // 8
        print(f'pointer slots: __DATA_CONST tail {const_free} (zero: {const_zero}), __DATA zero-fill tail {data_free}, '
              f'total {const_free + data_free}; 2.1.x needs 1270, plus 3 for the Steam Cloud stand-in')
        for x in macho.sections:
            if x['segment'] in ('__DATA_CONST', '__DATA'):
                print(f"  section {x['segment']},{x['name']}: size {x['size']:#x}")
    first = min(x['offset'] for x in macho.sections if x['offset'] > 0)
    header_end = 32 + struct.unpack_from('<I', data, 20)[0]
    zeros = 0
    while first - zeros - 1 >= header_end and data[first - zeros - 1] == 0:
        zeros += 1
    print(f'stub space before code: {zeros // 16} stubs of 16 bytes (needs 1273)')

    try:
        validate_patch_layout(macho, sdl_major)
        print('patch layout: OK')
    except ValueError as error:
        print('patch layout:', error)


if __name__ == '__main__':
    main()
