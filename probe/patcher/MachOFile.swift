// SPDX-License-Identifier: MIT
//
// The ARM64 slice of a Mach-O file: a port of tools/macho.py that runs on the
// device (and on Linux, for CI). Foundation only. Each function keeps the
// Python's behaviour exactly, so that the patched game is byte for byte what
// the Mac build makes (tests/test_swift_patcher.py checks this).

import Foundation

struct MachOError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Little-endian access

extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 {
        UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
    func be32(_ at: Int) -> UInt32 {
        UInt32(self[at]) << 24 | UInt32(self[at + 1]) << 16 | UInt32(self[at + 2]) << 8 | UInt32(self[at + 3])
    }
    /// As Int, for offset arithmetic.
    func int32(_ at: Int) -> Int { Int(u32(at)) }
    func int64(_ at: Int) -> Int { Int(truncatingIfNeeded: u64(at)) }

    mutating func put32(_ value: UInt32, at: Int) {
        for i in 0..<4 { self[at + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i))) }
    }
    mutating func put64(_ value: UInt64, at: Int) {
        for i in 0..<8 { self[at + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    }
    mutating func put32(int value: Int, at: Int) { put32(UInt32(truncatingIfNeeded: value), at: at) }
    mutating func put64(int value: Int, at: Int) { put64(UInt64(truncatingIfNeeded: value), at: at) }

    func isZero(_ at: Int, _ count: Int) -> Bool {
        guard at >= 0, count >= 0, at + count <= self.count else { return false }
        for i in at..<(at + count) where self[i] != 0 { return false }
        return true
    }

    func matches(_ bytes: [UInt8], at: Int) -> Bool {
        guard at >= 0, at + bytes.count <= count else { return false }
        for i in 0..<bytes.count where self[at + i] != bytes[i] { return false }
        return true
    }

    /// The NUL-terminated string at `at`.
    func cstring(_ at: Int, limit: Int? = nil) throws -> String {
        let end = Swift.min(limit ?? count, count)
        guard at >= 0, at < end else { throw MachOError("Mach-O string out of range") }
        var i = at
        while i < end && self[i] != 0 { i += 1 }
        guard i < end else { throw MachOError("Unterminated Mach-O string") }
        return String(decoding: self[at..<i], as: UTF8.self)
    }

    /// A fixed-size name field (segment or section name).
    func fixedString(_ at: Int, _ length: Int) -> String {
        var end = at
        while end < at + length && self[end] != 0 { end += 1 }
        return String(decoding: self[at..<end], as: UTF8.self)
    }
}

/// Python's floor division, for the few places it can see a negative value.
func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

// MARK: - Mach-O

struct MachOFile {
    static let dylibCommands: Set<UInt32> = [0xc, 0x8000_0018, 0x8000_001f, 0x8000_0023]
    static let arm64: UInt32 = 0x0100_000c

    struct Command { let cmd: UInt32; let offset: Int; let size: Int }
    struct Section { let name: String; let segment: String; let address: Int; let size: Int; let offset: Int }
    struct Symbol {
        let name: String
        let type: UInt8
        let section: Int
        let desc: UInt16
        let address: Int
        /// The library an undefined symbol comes from; nil for a defined one.
        let library: String?
        var isImport: Bool { library != nil }
    }

    var data: [UInt8]
    private(set) var commands: [Command] = []
    private(set) var libraries: [String] = []
    private(set) var sections: [Section] = []

    /// A thin or universal file; only its ARM64 slice is kept.
    init(file data: Data) throws {
        if data.count >= 8, data.prefix(4).elementsEqual([0xca, 0xfe, 0xba, 0xbe]) {
            let header = [UInt8](data.prefix(8 + 20 * 64))
            let count = Int(header.be32(4))
            var slice: [UInt8]?
            for i in 0..<count where 8 + 20 * i + 20 <= header.count {
                let at = 8 + 20 * i
                if header.be32(at) == Self.arm64 {
                    let offset = Int(header.be32(at + 8)), size = Int(header.be32(at + 12))
                    guard offset + size <= data.count else { throw MachOError("Truncated universal file") }
                    slice = [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + size])
                    break
                }
            }
            guard let slice else { throw MachOError("No ARM64 slice") }
            try self.init(bytes: slice)
        } else {
            try self.init(bytes: [UInt8](data))
        }
    }

    init(bytes: [UInt8]) throws {
        data = bytes
        guard data.count >= 32, data.matches([0xcf, 0xfa, 0xed, 0xfe], at: 0) else {
            throw MachOError("Expected little-endian 64-bit Mach-O")
        }
        guard data.u32(4) == Self.arm64 else { throw MachOError("Expected ARM64") }
        let count = data.int32(16), size = data.int32(20)
        guard 32 + size <= data.count else { throw MachOError("Malformed load command") }
        var pos = 32
        for _ in 0..<count {
            guard pos + 8 <= 32 + size else { throw MachOError("Malformed load command") }
            let cmd = data.u32(pos), length = data.int32(pos + 4)
            if length < 8 || pos + length > 32 + size { throw MachOError("Malformed load command") }
            commands.append(Command(cmd: cmd, offset: pos, size: length))
            if Self.dylibCommands.contains(cmd) {
                libraries.append(try data.cstring(pos + data.int32(pos + 8), limit: pos + length))
            }
            if cmd == 0x19 {
                let nsects = data.int32(pos + 64)
                for j in 0..<nsects {
                    let sp = pos + 72 + 80 * j
                    sections.append(Section(name: data.fixedString(sp, 16), segment: data.fixedString(sp + 16, 16),
                                            address: data.int64(sp + 32), size: data.int64(sp + 40),
                                            offset: data.int32(sp + 48)))
                }
            }
            pos += length
        }
        guard pos == 32 + size else { throw MachOError("Load commands don't fill sizeofcmds") }
    }

    func command(_ cmd: UInt32) -> Command? { commands.first { $0.cmd == cmd } }

    /// Every non-debugging symbol, in symbol table order, as macho.py's symbols().
    func symbols() throws -> [Symbol] {
        guard let symtab = command(0x2) else { throw MachOError("No symbol table") }
        let symoff = data.int32(symtab.offset + 8), count = data.int32(symtab.offset + 12)
        let stroff = data.int32(symtab.offset + 16), strsize = data.int32(symtab.offset + 20)
        guard symoff + 16 * count <= data.count, stroff + strsize <= data.count else {
            throw MachOError("Symbol table out of range")
        }
        var result: [Symbol] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let at = symoff + 16 * i
            let name = data.int32(at), type = data[at + 4], section = Int(data[at + 5])
            let desc = data.u16(at + 6), value = data.int64(at + 8)
            if name == 0 || type & 0xe0 != 0 { continue }
            var library: String?
            if type & 0x0e == 0 && type & 1 != 0 {
                let ordinal = Int(desc >> 8)
                library = (ordinal > 0 && ordinal <= libraries.count) ? libraries[ordinal - 1] : "ordinal:\(ordinal)"
            }
            result.append(Symbol(name: try data.cstring(stroff + name, limit: stroff + strsize), type: type,
                                 section: section, desc: desc, address: value, library: library))
        }
        return result
    }

    /// macho.py's packed_version: "26.2" -> 0x001a0200.
    static func packedVersion(_ version: String) throws -> UInt32 {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { throw MachOError("Invalid SDK version: \(version)") }
        let p = parts.map { $0! }
        guard (0...65535).contains(p[0]), p.dropFirst().allSatisfy({ (0...255).contains($0) }) else {
            throw MachOError("Invalid SDK version: \(version)")
        }
        return UInt32(p[0] << 16 | (p.count > 1 ? p[1] : 0) << 8 | (p.count > 2 ? p[2] : 0))
    }

    /// macho.py's retarget: a copy with another platform and install names, and no
    /// code signature. Instructions are untouched.
    func retarget(platform: UInt32, replacements: [String: String], sdk: UInt32) throws -> [UInt8] {
        var result = data
        var payload: [UInt8] = []
        var kept = 0
        for command in commands {
            var chunk = Array(result[command.offset ..< command.offset + command.size])
            if Self.dylibCommands.contains(command.cmd) {
                let old = try chunk.cstring(chunk.int32(8))
                let name = Array((replacements[old] ?? old).utf8) + [0]
                let newSize = (24 + name.count + 7) & ~7
                chunk = [UInt8](repeating: 0, count: 24)
                for (i, value) in [command.cmd, UInt32(newSize), 24, 0, 0x10000, 0x10000].enumerated() { chunk.put32(value, at: 4 * i) }
                chunk += name
                chunk += [UInt8](repeating: 0, count: newSize - chunk.count)
            } else if command.cmd == 0x32 {
                chunk.put32(platform, at: 8); chunk.put32(26 << 16, at: 12); chunk.put32(sdk, at: 16)
            } else if command.cmd == 0x24 {
                chunk = [UInt8](repeating: 0, count: 24)
                for (i, value) in [UInt32(0x32), 24, platform, 26 << 16, sdk, 0].enumerated() { chunk.put32(value, at: 4 * i) }
            } else if command.cmd == 0x1d {
                continue   // codesign makes a new signature
            }
            payload += chunk
            kept += 1
        }
        guard let firstSection = sections.filter({ $0.offset > 0 }).map(\.offset).min() else {
            throw MachOError("No sections")
        }
        if 32 + payload.count > firstSection { throw MachOError("Not enough load-command space") }
        let oldSize = result.int32(20)
        let span = Swift.max(oldSize, payload.count)
        result.replaceSubrange(32 ..< 32 + span, with: payload + [UInt8](repeating: 0, count: span - payload.count))
        result.put32(int: kept, at: 16)
        result.put32(int: payload.count, at: 20)
        return result
    }
}
