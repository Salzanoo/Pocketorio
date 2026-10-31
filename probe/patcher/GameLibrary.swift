// SPDX-License-Identifier: MIT
//
// Turns the patched Factorio executable into a library the app can load with
// dlopen and then start, the way LiveContainer runs apps it hasn't installed:
//   - the file type becomes MH_DYLIB, with MH_NO_REEXPORTED_DYLIBS set and
//     MH_PIE cleared;
//   - __PAGEZERO, which reserves the executable's first 4 GB, shrinks to one
//     16 KB page just below the image, or dyld runs out of address space;
//   - an LC_ID_DYLIB naming the library becomes the first load command.
// The game's own main is where GamePatcher found it (originalEntryOffset in
// its report): LC_MAIN now points at the trampoline to ProbeMain, which a
// library's loader never runs.

import Foundation

enum GameLibrary {
    /// Free bytes after the load commands, up to the first byte in use (the
    /// entry trampolines GamePatcher put there, or the first section).
    static func freeAfterLoadCommands(_ data: [UInt8], sections: [MachOFile.Section]) -> Int {
        let start = 32 + data.int32(20)
        let limit = sections.filter { $0.offset > 0 }.map(\.offset).min() ?? data.count
        var at = start
        while at < limit && data[at] == 0 { at += 1 }
        return at - start
    }

    static func dylibCommand(_ cmd: UInt32, name: String) -> [UInt8] {
        let raw = Array(name.utf8) + [0]
        let size = (24 + raw.count + 7) & ~7
        var command = [UInt8](repeating: 0, count: 24)
        for (i, value) in [cmd, UInt32(size), 24, 2, 0x10000, 0x10000].enumerated() { command.put32(value, at: 4 * i) }
        return command + raw + [UInt8](repeating: 0, count: size - 24 - raw.count)
    }

    /// `reserve`: load command bytes to leave free afterwards (the code signature's).
    static func make(_ input: [UInt8], installName: String, reserve: Int = 16) throws -> [UInt8] {
        var data = input
        let image = try MachOFile(bytes: data)
        guard image.command(0x1d) == nil else { throw MachOError("Make the library before signing it") }
        guard data.u32(12) == 2 else { throw MachOError("Not an executable") }
        data.put32(6, at: 12)                                           // MH_DYLIB
        data.put32((data.u32(24) | 0x0010_0000) & ~0x0020_0000, at: 24)   // +NO_REEXPORTED_DYLIBS, -PIE

        if let first = image.commands.first, first.cmd == 0x19, data.fixedString(first.offset + 8, 16) == "__PAGEZERO",
           data.u64(first.offset + 24) == 0 {
            data.put64(0x1_0000_0000 - 0x4000, at: first.offset + 24)
            data.put64(0x4000, at: first.offset + 32)
        }

        if image.command(0xd) == nil {
            let id = dylibCommand(0xd, name: installName)
            let free = freeAfterLoadCommands(data, sections: image.sections)
            guard free >= id.count + reserve else {
                throw MachOError("No room for LC_ID_DYLIB: \(free) free bytes after the load commands, \(id.count + reserve) needed")
            }
            let size = data.int32(20)
            let commands = Array(data[32 ..< 32 + size])
            data.replaceSubrange(32 ..< 32 + size + id.count, with: id + commands)
            data.put32(int: data.int32(16) + 1, at: 16)
            data.put32(int: size + id.count, at: 20)
        }
        _ = try MachOFile(bytes: data)   // still well formed
        return data
    }
}
