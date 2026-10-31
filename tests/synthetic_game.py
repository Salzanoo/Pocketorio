"""A synthetic stand-in for Factorio's macOS executable, and the app's libSDL3 and
ProbeShim, laid out like the real files where the patch looks (no game files).

The game is a universal file whose ARM64 slice has __PAGEZERO, __TEXT (with 1,269
SDL functions and the six Steam Cloud methods), __DATA_CONST, __DATA with
zero-fill, __LINKEDIT with a classic bind stream, three libraries, LC_MAIN, a
macOS LC_BUILD_VERSION and a code signature command. `tight=True` leaves too few
pointer slots, as in Factorio 2.1.24, so __DATA's zero-fill has to grow."""
import struct

SDL_FUNCTIONS = 1269
STRING = 'ERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEE'
CLOUD_METHODS = ['__ZNK21SteamContextInterface' + m + rest
                 for m, rest in (('21getCloudFileTimestamp', STRING), ('15cloudFileExists', STRING),
                                 ('13readCloudFile', STRING), ('14writeCloudFile', STRING + 'S8_b'),
                                 ('15deleteCloudFile', STRING), ('14isCloudEnabled', 'Ev'))]
LIBRARIES = ['/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa',
             '/usr/lib/libc++.1.dylib',
             '@loader_path/libsteam_api.dylib']
BASE = 0x100000000


def sdl_name(i):
    return f'_SDL_Function{i:04}'


def pad(data, alignment):
    data += bytes(-len(data) % alignment)


def segment(name, vmaddr, vmsize, fileoff, filesize, sections=(), prot=3):
    command = struct.pack('<II16sQQQQIIII', 0x19, 72 + 80 * len(sections), name.encode(), vmaddr, vmsize,
                          fileoff, filesize, prot, prot, len(sections), 0)
    for sect, seg, addr, size, offset, flags in sections:
        command += struct.pack('<16s16sQQIIIIIIII', sect.encode(), seg.encode(), addr, size, offset,
                               2 if seg == '__TEXT' else 3, 0, 0, flags, 0, 0, 0)
    return command


def dylib_command(name):
    raw = name.encode() + b'\0'
    size = (24 + len(raw) + 7) & ~7
    return struct.pack('<IIIIII', 0xc, size, 24, 2, 0x10000, 0x10000) + raw + bytes(size - 24 - len(raw))


def symbol_table(symbols):
    """(nlist bytes, string table) for (name, type, sect, desc, value) entries."""
    strings = bytearray(b' \0')
    table = bytearray()
    for name, type_, sect, desc, value in symbols:
        table += struct.pack('<IBBHQ', len(strings), type_, sect, desc, value)
        strings += name.encode() + b'\0'
    pad(strings, 8)
    return table, strings


def game_slice(tight=False):
    text_off, const_off, data_off, linkedit_off = 0x8000, 0x10000, 0x14000, 0x18000
    const_size = 0x3f00 if tight else 0x100
    bss_size = 0x3f00 if tight else 0x100
    # __text: _main, then the SDL functions, a private SDL function and the cloud methods, each `ret`.
    names = ['_main'] + [sdl_name(i) for i in range(SDL_FUNCTIONS)] + ['_SDL_PrivateHelper'] + CLOUD_METHODS
    symbols = [(n, 0x0f, 1, 0, BASE + text_off + 4 * i) for i, n in enumerate(names)]
    symbols.append(('_objc_msgSend', 0x01, 0, 2 << 8, 0))
    # An existing bind of _objc_msgSend to the first __DATA_CONST pointer, then padding.
    bind = bytearray(b'\x12\x40_objc_msgSend\0\x51\x72\x00\x90\x00')
    pad(bind, 8)
    nlist, strings = symbol_table(symbols)
    linkedit = bytearray(bind)
    symoff = linkedit_off + len(linkedit)
    linkedit += nlist
    stroff = linkedit_off + len(linkedit)
    linkedit += strings
    end = linkedit_off + len(linkedit)

    commands = [
        segment('__PAGEZERO', 0, BASE, 0, 0, prot=0),
        segment('__TEXT', BASE, 0x10000, 0, 0x10000,
                [('__text', '__TEXT', BASE + text_off, 0x8000, text_off, 0x80000400)], prot=5),
        segment('__DATA_CONST', BASE + const_off, 0x4000, const_off, 0x4000,
                [('__const', '__DATA_CONST', BASE + const_off, const_size, const_off, 0)]),
        segment('__DATA', BASE + data_off, 0x8000, data_off, 0x4000,
                [('__data', '__DATA', BASE + data_off, 0x100, data_off, 0),
                 ('__bss', '__DATA', BASE + 0x18000, bss_size, 0, 1)]),
        segment('__LINKEDIT', BASE + 0x1c000, (len(linkedit) + 0x3fff) & ~0x3fff, linkedit_off, len(linkedit), prot=1),
        struct.pack('<12I', 0x80000022, 48, 0, 0, linkedit_off, len(bind), 0, 0, 0, 0, 0, 0),
        struct.pack('<6I', 0x2, 24, symoff, len(symbols), stroff, len(strings)),
        *[dylib_command(name) for name in LIBRARIES],
        struct.pack('<IIQQ', 0x80000028, 24, text_off, 0),
        struct.pack('<6I', 0x32, 24, 1, 11 << 16, 15 << 16, 0),
        struct.pack('<4I', 0x1d, 16, end, 0),
    ]
    payload = b''.join(commands)
    data = bytearray(struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, len(commands), len(payload), 0x200085, 0))
    data += payload
    data += bytes(text_off - len(data))
    for _ in names:
        data += struct.pack('<I', 0xd65f03c0)   # ret
    data += bytes(const_off - len(data))
    data += bytes(data_off - const_off) + bytes(linkedit_off - data_off)
    data += linkedit
    return bytes(data)


def universal(arm64):
    """A fat file with a placeholder x86_64 slice before the ARM64 one."""
    x86_off, arm_off = 0x4000, 0x8000
    header = struct.pack('>II', 0xcafebabe, 2)
    header += struct.pack('>5I', 0x1000007, 3, x86_off, 0x100, 14)
    header += struct.pack('>5I', 0x100000c, 0, arm_off, len(arm64), 14)
    return header + bytes(x86_off - len(header)) + b'\xcf\xfa\xed\xfe' + bytes(0xfc) + \
        bytes(arm_off - x86_off - 0x100) + arm64


def library(symbols, imports=()):
    """A thin ARM64 dylib holding only a symbol table: exports, and imports from one library."""
    entries = [(n, 0x0f, 1, 0, 0x4000 + 4 * i) for i, n in enumerate(symbols)]
    entries += [(n, 0x01, 0, 1 << 8, 0) for n in imports]
    nlist, strings = symbol_table(entries)
    commands = [dylib_command('/usr/lib/libSystem.B.dylib'), struct.pack('<6I', 0x2, 24, 0, 0, 0, 0)]
    payload = b''.join(commands)
    data = bytearray(struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 6, len(commands), len(payload), 0, 0))
    data += payload
    pad(data, 8)
    symoff = len(data)
    data += nlist
    stroff = len(data)
    data += strings
    symtab = 32 + len(commands[0])
    struct.pack_into('<4I', data, symtab + 8, symoff, len(entries), stroff, len(strings))
    return bytes(data)


def sdl_library():
    return library([sdl_name(i) for i in range(SDL_FUNCTIONS)] + ['_SDL_NotInTheGame'], imports=['_malloc'])


def shim_library():
    return library(['_ProbeMain', '_FPICloudFileTimestamp', '_FPICloudFileExists', '_FPIReadCloudFile',
                    '_FPIWriteCloudFile', '_FPIDeleteCloudFile', '_FPICloudEnabled'])


def fake_sign(data):
    """What codesign does to the layout: LC_CODE_SIGNATURE after the load commands,
    a signature at a 16-byte aligned offset, and __LINKEDIT grown to cover it."""
    data = bytearray(data)
    count, size = struct.unpack_from('<II', data, 16)
    dataoff = (len(data) + 15) & ~15
    signature = b'\xfa\xde\x0c\xc0' + bytes(0x200)
    struct.pack_into('<4I', data, 32 + size, 0x1d, 16, dataoff, len(signature))
    struct.pack_into('<II', data, 16, count + 1, size + 16)
    pos = 32
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, pos)
        if cmd == 0x19 and data[pos + 8:pos + 24].rstrip(b'\0') == b'__LINKEDIT':
            fileoff = struct.unpack_from('<Q', data, pos + 40)[0]
            total = dataoff + len(signature) - fileoff
            struct.pack_into('<QQ', data, pos + 32, (total + 0x3fff) & ~0x3fff, fileoff)
            struct.pack_into('<Q', data, pos + 48, total)
        pos += length
    data += bytes(dataoff - len(data)) + signature
    return bytes(data)
