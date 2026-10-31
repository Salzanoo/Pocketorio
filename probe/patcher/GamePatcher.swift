// SPDX-License-Identifier: MIT
//
// Stage 3 of getting the game on the device (docs/ON_DEVICE.md): the patch
// tools/build_probe.py applies on the Mac, on the device. A port of
// macho.retarget and tools/entrypoint.py's inject_entry, kept step for step
// with the Python so both make the same bytes: tests/test_swift_patcher.py runs
// both on a synthetic game, and the app checks its output against its own
// executable when it was built from the same Factorio.

import Foundation

struct GamePatchReport: Codable, Equatable {
    struct Patch: Codable, Equatable { let name: String; let offset: Int; let originalBytes: String }
    var originalEntryOffset = 0
    var entryStubOffset = 0
    var pointerSlotOffset = 0
    var bindStreamOffset = 0
    var dataZeroFillGrowth = 0
    var sdlRedirects = 0
    var platformPatches: [Patch] = []
    /// Patches that didn't apply because the code wasn't recognised, as the Python prints.
    var notes: [String] = []
    /// The reexporting facades (P<index>.dylib) the patched game loads.
    var facades: [String] = []
}

enum GamePatcher {
    /// What the patch needs from the app the game will run in.
    struct Host {
        /// Exported symbols of the app's libSDL2/3.dylib.
        let sdlExports: Set<String>
        /// Defined symbols of the app's ProbeShim.dylib.
        let shimSymbols: Set<String>
        let sdlMajor: Int
        /// LC_BUILD_VERSION's packed SDK version.
        let sdk: UInt32
        /// 2 for iOS, 7 for the simulator.
        var platform: UInt32 = 2
        /// SDL functions the game must define, as entrypoint.py checks.
        var expectedRedirects: Int? = nil
    }

    // MARK: Library names (macho.py library_replacements)

    static func mobilePath(_ path: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "/Versions/[^/]+/") else { return path }
        return regex.stringByReplacingMatches(in: path, range: NSRange(path.startIndex..., in: path), withTemplate: "/")
    }

    static func needsFacade(_ path: String) -> Bool { path.contains(".framework/") || path.contains("libsteam_api") }

    static func facadeName(_ index: Int) -> String { (index < 10 ? "P0" : "P") + "\(index).dylib" }

    static func libraryReplacements(_ libraries: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for library in libraries { result[library] = mobilePath(library) }
        for (index, library) in libraries.enumerated() where needsFacade(library) {
            result[library] = "@executable_path/Frameworks/" + facadeName(index)
        }
        return result
    }

    /// Exported symbols of a library (entrypoint.py's SDL export set).
    static func exports(_ library: MachOFile) throws -> Set<String> {
        Set(try library.symbols().filter { $0.type & 1 != 0 && !$0.isImport }.map(\.name))
    }

    /// Defined symbols of a library (entrypoint.py's shim set).
    static func defined(_ library: MachOFile) throws -> Set<String> {
        Set(try library.symbols().filter { !$0.isImport }.map(\.name))
    }

    // MARK: Patch

    /// The game's executable as build_probe.py leaves it before codesign:
    /// retargeted to iOS, then the entry point and redirects installed.
    static func patch(_ game: MachOFile, host: Host) throws -> (bytes: [UInt8], report: GamePatchReport) {
        let retargeted = try game.retarget(platform: host.platform,
                                           replacements: libraryReplacements(game.libraries), sdk: host.sdk)
        var image = try MachOFile(bytes: retargeted)
        var report = try injectEntry(&image, host: host)
        report.facades = game.libraries.enumerated().filter { needsFacade($0.element) }.map { facadeName($0.offset) }
        return (image.data, report)
    }

    static let caFile = Array("/etc/ssl/cert.pem".utf8) + [0]
    static let shippedCAMessage = Array("Failed to find the system certificate authority file, using shipped file".utf8) + [0]
    static let steamNoticeKey = Array("gui-update.could-not-init-steam".utf8) + [0]

    static func uleb(_ value: Int) -> [UInt8] {
        var value = UInt64(value), out: [UInt8] = []
        while value >= 128 { out.append(UInt8(value & 127) | 128); value >>= 7 }
        out.append(UInt8(value))
        return out
    }

    /// Where the bind stream's BIND_OPCODE_DONE is.
    static func bindEnd(_ stream: [UInt8]) throws -> Int {
        var p = 0
        while p < stream.count {
            let at = p, op = stream[p] & 0xf0
            p += 1
            if op == 0 { return at }
            if op == 0x40 {
                guard let zero = stream[p...].firstIndex(of: 0) else { throw MachOError("Unterminated bind symbol") }
                p = zero + 1
            } else if [0x20, 0x60, 0x70, 0x80, 0xa0, 0xc0].contains(op) {
                for _ in 0..<(op == 0xc0 ? 2 : 1) {
                    while p < stream.count && stream[p] & 128 != 0 { p += 1 }
                    p += 1
                }
            } else if ![0x10, 0x30, 0x50, 0x90, 0xb0].contains(op) {
                throw MachOError("Unsupported bind opcode \(String(op, radix: 16))")
            }
        }
        throw MachOError("No BIND_DONE")
    }

    /// The file offset an adrp/add pair at `at` points to.
    static func stringAt(_ data: [UInt8], _ base: Int, _ at: Int) -> Int {
        let adrp = Int(data.u32(at)), add = Int(data.u32(at + 4))
        let page = ((base + at) & ~0xfff) + ((((adrp >> 5) & 0x7ffff) << 2 | (adrp >> 29) & 3) << 12)
        return page + ((add >> 10) & 0xfff) - base
    }

    /// The target address of the bl/b at `at`.
    static func callTarget(_ data: [UInt8], _ base: Int, _ at: Int) -> Int {
        let offset = Int(data.u32(at)) & 0x3ffffff
        return base + at + 4 * (offset & (1 << 25) != 0 ? offset - (1 << 26) : offset)
    }

    static func branch(from at: Int, to target: Int) -> UInt32 {
        0x1400_0000 | UInt32(truncatingIfNeeded: ((target - at) >> 2) & 0x3ffffff)
    }

    static func hex(_ data: [UInt8], _ at: Int, _ count: Int = 4) -> String {
        data[at ..< at + count].map { String(format: "%02x", $0) }.joined()
    }

    /// entrypoint.py's curl_default_ca_sites.
    static func curlDefaultCASites(_ data: [UInt8], _ base: Int, _ defined: [String: MachOFile.Symbol]) -> [Int] {
        guard let initialize = defined["_Curl_init_userdefined"], let setstropt = defined["_Curl_setstropt"] else { return [] }
        let start = initialize.address - base
        return stride(from: start, to: start + 0x400, by: 4).compactMap { at in
            guard at + 12 <= data.count, data.u32(at) & 0x9f00_001f == 0x9000_0001,
                  data.u32(at + 4) & 0xffc0_03ff == 0x9100_0021,
                  data.matches(caFile, at: stringAt(data, base, at)),
                  callTarget(data, base, at + 8) == setstropt.address else { return nil }
            return at + 4
        }
    }

    /// entrypoint.py's shipped_ca_site.
    static func shippedCASite(_ data: [UInt8], _ base: Int, _ symbols: [MachOFile.Symbol]) -> Int? {
        guard let pick = symbols.first(where: { $0.name == "__ZN10CurlHandle20pickCertFileLocationEv" }) else { return nil }
        let at = pick.address - base + 0x30
        guard at + 0x14c <= data.count else { return nil }
        if data.u32(at) == 0x1400_0006 && data.matches(shippedCAMessage, at: stringAt(data, base, at + 0x144)) { return at }
        return nil
    }

    /// entrypoint.py's stub_address: the __stubs entry for an import.
    static func stubAddress(_ m: MachOFile, _ name: String) throws -> Int? {
        let data = m.data
        guard let symtab = m.command(0x2), let dysymtab = m.command(0xb) else { return nil }
        let symoff = data.int32(symtab.offset + 8), stroff = data.int32(symtab.offset + 16)
        let indirect = data.int32(dysymtab.offset + 56)
        for command in m.commands where command.cmd == 0x19 {
            for j in 0..<data.int32(command.offset + 64) {
                let sp = command.offset + 72 + 80 * j
                guard data.fixedString(sp, 16) == "__stubs" else { continue }
                let address = data.int64(sp + 32), size = data.int64(sp + 40)
                let first = data.int32(sp + 68), stride = data.int32(sp + 72)
                guard stride > 0 else { continue }
                for i in 0..<(size / stride) {
                    let index = data.int32(indirect + 4 * (first + i))
                    if index < 0x4000_0000, try data.cstring(stroff + data.int32(symoff + 16 * index)) == name {
                        return address + i * stride
                    }
                }
            }
        }
        return nil
    }

    /// entrypoint.py's grow_zero_fill: raises __DATA's vmsize, moving __LINKEDIT up if needed.
    static func growZeroFill(_ data: inout [UInt8], _ segments: [(offset: Int, name: String)],
                             _ dataSegment: Int, _ missingSlots: Int) throws -> Int {
        let page = 0x4000
        let growth = (missingSlots * 8 + page - 1) & ~(page - 1)
        guard let position = segments.firstIndex(where: { $0.offset == dataSegment }),
              segments[(position + 1)...].map(\.name) == ["__LINKEDIT"] else {
            throw MachOError("Not enough pointer space, and __DATA is not followed only by __LINKEDIT")
        }
        let linkedit = segments[position + 1].offset
        let dataVM = data.int64(dataSegment + 24), dataVMSize = data.int64(dataSegment + 32)
        let linkeditVM = data.int64(linkedit + 24)
        data.put64(int: dataVMSize + growth, at: dataSegment + 32)
        let overlap = dataVM + dataVMSize + growth - linkeditVM
        if overlap > 0 { data.put64(int: linkeditVM + ((overlap + page - 1) & ~(page - 1)), at: linkedit + 24) }
        return growth
    }

    /// entrypoint.py's inject_entry (device builds: no simulator Metal probe).
    static func injectEntry(_ m: inout MachOFile, host: Host) throws -> GamePatchReport {
        var data = m.data
        let fail = { (message: String) in MachOError(message) }
        guard m.command(0x1d) == nil else { throw fail("Inject before codesign") }
        let segments = m.commands.filter { $0.cmd == 0x19 }.map { (offset: $0.offset, name: data.fixedString($0.offset + 8, 16)) }
        guard let segIndex = segments.firstIndex(where: { $0.name == "__DATA_CONST" }) else { throw fail("No __DATA_CONST") }
        let segment = segments[segIndex].offset
        let vm = data.int64(segment + 24), fileoff = data.int64(segment + 40), filesize = data.int64(segment + 48)
        guard let last = m.sections.filter({ $0.segment == "__DATA_CONST" }).map({ $0.offset + $0.size }).max() else {
            throw fail("No __DATA_CONST sections")
        }
        let slot = (last + 7) & ~7
        guard slot + 8 <= fileoff + filesize, data.isZero(slot, 8) else { throw fail("No free entry pointer slot") }
        guard let first = m.sections.filter({ $0.offset > 0 }).map(\.offset).min() else { throw fail("No sections") }

        let symbols = try m.symbols()
        var defined: [String: MachOFile.Symbol] = [:]
        for symbol in symbols where !symbol.isImport { defined[symbol.name] = symbol }

        var redirects: [MachOFile.Symbol] = []
        for symbol in symbols where symbol.name.hasPrefix("_SDL_") && host.sdlExports.contains(symbol.name) && !symbol.isImport {
            // Python indexes sections[s['section']-1]; section 0 wraps to the last.
            let index = symbol.section == 0 ? m.sections.count - 1 : symbol.section - 1
            if index >= 0, index < m.sections.count, m.sections[index].name == "__text" { redirects.append(symbol) }
        }
        let expected = host.expectedRedirects ?? (host.sdlMajor == 2 ? 817 : 1269)
        guard redirects.count == expected else {
            throw fail("SDL\(host.sdlMajor) redirect set changed: expected \(expected), got \(redirects.count)")
        }

        // Steam Cloud stand-in (probe/SteamCloud.mm).
        var cloud: [(symbol: MachOFile.Symbol, target: String, label: String)] = []
        let string = "ERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEE"
        // Each method with the rest of its mangled name: the write takes the name and
        // the contents as strings, then a bool.
        for (method, rest, replacement) in [("21getCloudFileTimestamp", string, "_FPICloudFileTimestamp"),
                                            ("15cloudFileExists", string, "_FPICloudFileExists"),
                                            ("13readCloudFile", string, "_FPIReadCloudFile"),
                                            ("14writeCloudFile", string + "S8_b", "_FPIWriteCloudFile"),
                                            ("15deleteCloudFile", string, "_FPIDeleteCloudFile"),
                                            ("14isCloudEnabled", "Ev", "_FPICloudEnabled")] {
            if let symbol = defined["__ZNK21SteamContextInterface" + method + rest], host.shimSymbols.contains(replacement) {
                cloud.append((symbol: symbol, target: replacement, label: "Steam Cloud stand-in: " + String(method.dropFirst(2))))
            }
        }

        let count = 1 + redirects.count + cloud.count
        let stub = (first - 16 * count) & ~15
        guard stub >= 32 + data.int32(20) else { throw fail("Entry stubs overlap the load commands") }
        guard data.isZero(stub, 16 * count) else { throw fail("Entry stub padding is not empty") }
        guard let text = segments.first(where: { $0.name == "__TEXT" }) else { throw fail("No __TEXT") }
        let base = data.int64(text.offset + 24)

        func trampoline(_ at: Int, _ pointerVM: Int) throws {
            let pc = base + at
            let pages = ((pointerVM & ~4095) - (pc & ~4095)) >> 12
            guard -(1 << 20) <= pages && pages < (1 << 20) else { throw fail("Trampoline out of adrp range") }
            let adrp = 0x9000_0010 | ((pages & 3) << 29) | (((pages >> 2) & 0x7ffff) << 5)
            let ldr = 0xf940_0210 | (((pointerVM & 4095) / 8) << 10)
            data.put32(int: adrp, at: at); data.put32(int: ldr, at: at + 4)
            data.put32(0xd61f_0200, at: at + 8); data.put32(0xd503_201f, at: at + 12)
        }
        try trampoline(stub, vm + slot - fileoff)

        guard let dyld = m.command(0x8000_0022)?.offset else { throw fail("No LC_DYLD_INFO_ONLY") }
        let bindoff = data.int32(dyld + 16), bindsize = data.int32(dyld + 20)
        let oldbind = Array(data[bindoff ..< bindoff + bindsize])
        // Ordinal 1 is P00.dylib, which reexports ProbeShim. Reset bind state explicitly.
        func binding(_ symbol: String, _ index: Int, _ offset: Int) -> [UInt8] {
            var out: [UInt8] = [0x11, 0x40]
            out += Array(symbol.utf8)
            out += [0, 0x51, 0x60, 0, UInt8(0x70 | index)]
            out += uleb(offset)
            out.append(0x90)
            return out
        }
        var extra = binding("_ProbeMain", segIndex, slot - fileoff)
        guard let dataIndex = segments.firstIndex(where: { $0.name == "__DATA" }) else { throw fail("No __DATA") }
        let dataSegment = segments[dataIndex].offset
        let dataVM = data.int64(dataSegment + 24), dataSize = data.int64(dataSegment + 48)
        var dataVMSize = data.int64(dataSegment + 32)
        guard let bssEnd = m.sections.filter({ $0.segment == "__DATA" }).map({ $0.address + $0.size }).max() else {
            throw fail("No __DATA sections")
        }
        var bssSlot = (bssEnd + 7) & ~7
        var constSlot = slot + 8
        let room = floorDiv(fileoff + filesize - constSlot, 8) + floorDiv(dataVM + dataVMSize - bssSlot, 8)
        var report = GamePatchReport()
        if room < count - 1 {
            report.dataZeroFillGrowth = try growZeroFill(&data, segments, dataSegment, count - 1 - room)
            dataVMSize += report.dataZeroFillGrowth
        }
        typealias Item = (symbol: MachOFile.Symbol, target: String, label: String?)
        var items: [Item] = redirects.map { Item(symbol: $0, target: $0.name, label: nil) }
        for entry in cloud { items.append(Item(symbol: entry.symbol, target: entry.target, label: entry.label)) }
        for (i, item) in items.enumerated() {
            let at = stub + 16 * (i + 1)
            let pointerVM: Int
            if constSlot + 8 <= fileoff + filesize {
                guard data.isZero(constSlot, 8) else { throw fail("Pointer slot is not empty") }
                pointerVM = vm + constSlot - fileoff
                extra += binding(item.target, segIndex, constSlot - fileoff)
                constSlot += 8
            } else {
                guard bssSlot >= dataVM + dataSize, bssSlot + 8 <= dataVM + dataVMSize else { throw fail("Insufficient zero-fill padding") }
                pointerVM = bssSlot
                extra += binding(item.target, dataIndex, bssSlot - dataVM)
                bssSlot += 8
            }
            try trampoline(at, pointerVM)
            let offset = item.symbol.address - base
            let displacement = base + at - item.symbol.address
            guard displacement % 4 == 0, -(1 << 27) <= displacement, displacement < (1 << 27) else { throw fail("Redirect out of branch range") }
            let before = hex(data, offset)
            data.put32(int: 0x1400_0000 | ((displacement >> 2) & 0x3ffffff), at: offset)
            if let label = item.label {
                report.platformPatches.append(.init(name: label, offset: offset, originalBytes: before))
            } else {
                report.sdlRedirects += 1
            }
        }

        if host.sdlMajor == 2 {
            // Factorio restarts itself with execv; iOS can't exec. Quit instead.
            let restartName = "__ZN10AppManager10restartAppEbNSt3__16vectorINS0_12basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEENS5_IS7_EEEEb"
            guard let restart = symbols.first(where: { $0.name == restartName }) else { throw fail("No AppManager::restartApp") }
            let execv = try stubAddress(m, "_execv"), exitStub = try stubAddress(m, "__exit")
            let start = restart.address - base
            let calls = stride(from: start, to: start + 0x400, by: 4).filter {
                data.u32($0) >> 26 == 0b100101 && callTarget(data, base, $0) == execv
            }
            if calls.count == 1, let exitStub {
                let at = calls[0]
                for offset in [at - 4, at] {
                    report.platformPatches.append(.init(name: "quit instead of restarting, which iOS cannot do",
                                                        offset: offset, originalBytes: hex(data, offset)))
                }
                data.put32(0x5280_0000, at: at - 4)   // mov w0, #0
                data.put32(0x9400_0000 | UInt32(truncatingIfNeeded: ((exitStub - base - at) >> 2) & 0x3ffffff), at: at)   // bl _exit
            } else {
                report.notes.append("Note: unrecognised AppManager::restartApp; restarting will abort on iOS")
            }
            // Skip the macOS display-ID suffix of the display log.
            guard let log = symbols.first(where: { $0.name == "__ZN9SDLWindow18logDisplayAdaptersEv" }) else {
                throw fail("No SDLWindow::logDisplayAdapters")
            }
            let at = log.address - base + 424
            guard data.u32(at) == 0xaa14_03e0 else { throw fail("Unrecognised SDLWindow::logDisplayAdapters") }
            data.put32(0x1400_0000 | UInt32(truncatingIfNeeded: ((-152) >> 2) & 0x3ffffff), at: at)
            report.platformPatches.append(.init(name: "skip macOS display-ID log suffix", offset: at, originalBytes: "e00314aa"))
        }

        // factorio.com logins: no default CA file for curl.
        let sites = curlDefaultCASites(data, base, defined)
        if sites.count == 2 {
            for at in sites {
                report.platformPatches.append(.init(name: "no default CA file for curl", offset: at, originalBytes: hex(data, at)))
                data.put32(0xd280_0001, at: at)   // mov x1, #0
            }
        } else {
            report.notes.append("Note: unrecognised Curl_init_userdefined (\(sites.count) sites); factorio.com login may fail on iOS")
        }
        if let at = shippedCASite(data, base, symbols) {
            data.put32(0x1400_0000 | (0x13c >> 2), at: at)
            report.platformPatches.append(.init(name: "use the shipped CA certificate file", offset: at, originalBytes: "06000014"))
        } else {
            report.notes.append("Note: unrecognised CurlHandle::pickCertFileLocation; factorio.com login may fail on iOS")
        }

        // No "Steam error" notice at startup.
        func loadsKey(_ start: Int, _ end: Int) -> Bool {
            stride(from: start, to: end, by: 4).contains { at in
                at + 8 <= data.count && data.u32(at) & 0x9f00_0000 == 0x9000_0000 && data.u32(at + 4) & 0xffc0_0000 == 0x9100_0000 &&
                    data.matches(steamNoticeKey, at: stringAt(data, base, at))
            }
        }
        var noticeSites: [(Int, Int)] = []
        if let run = symbols.first(where: { $0.name.hasPrefix("__ZN8MainLoop3runE") }) {
            let start = run.address - base
            for at in stride(from: start, to: Swift.min(start + 0x4000, data.count - 3), by: 4) {
                let word = data.u32(at)
                if word & 0xfff8_001f == 0x3700_0000 {   // tbnz w0, #0
                    let skip = at + 4 * ((Int((word >> 5) & 0x3fff) ^ 0x2000) - 0x2000)
                    if at < skip && skip < at + 0x400 && loadsKey(at + 4, skip) { noticeSites.append((at, skip)) }
                }
            }
        }
        if noticeSites.count == 1 {
            let (at, skip) = noticeSites[0]
            report.platformPatches.append(.init(name: "no Steam error notice at startup", offset: at, originalBytes: hex(data, at)))
            data.put32(int: 0x1400_0000 | ((skip - at) >> 2), at: at)
        } else {
            report.notes.append("Note: unrecognised MainLoop::run; the Steam error notice will still show")
        }

        extra.append(0)
        let bindingStream = Array(oldbind[..<(try bindEnd(oldbind))]) + extra
        let newoff = (data.count + 7) & ~7
        data += [UInt8](repeating: 0, count: newoff - data.count) + bindingStream
        data.put32(int: newoff, at: dyld + 16)
        data.put32(int: bindingStream.count, at: dyld + 20)
        guard let linkedit = segments.first(where: { $0.name == "__LINKEDIT" })?.offset else { throw fail("No __LINKEDIT") }
        let leoff = data.int64(linkedit + 40)
        data.put64(int: data.count - leoff, at: linkedit + 48)
        data.put64(int: (data.count - leoff + 16383) & ~16383, at: linkedit + 32)
        guard let main = m.command(0x8000_0028)?.offset else { throw fail("No LC_MAIN") }
        report.originalEntryOffset = data.int64(main + 8)
        data.put64(int: stub, at: main + 8)
        report.entryStubOffset = stub
        report.pointerSlotOffset = slot
        report.bindStreamOffset = newoff
        m.data = data
        return report
    }

    // MARK: Check against a signed build

    /// Compares a patch with an executable codesign signed afterwards (the
    /// app's own, when built from the same Factorio): undoes what codesign adds
    /// (LC_CODE_SIGNATURE, the signature, __LINKEDIT's sizes), then compares.
    /// nil when they match, otherwise where they first differ.
    static func difference(_ patched: [UInt8], signed: [UInt8]) throws -> String? {
        let image = try MachOFile(bytes: signed)
        var copy = signed
        if let signature = image.command(0x1d) {
            guard signature.offset + signature.size == 32 + copy.int32(20) else { return "the signature isn't the last load command" }
            let dataoff = copy.int32(signature.offset + 8)
            guard dataoff >= patched.count, copy.isZero(patched.count, dataoff - patched.count) else {
                return "the signature starts at \(dataoff), before the end of the patch (\(patched.count))"
            }
            for i in 0..<signature.size { copy[signature.offset + i] = 0 }
            copy.put32(int: copy.int32(16) - 1, at: 16)
            copy.put32(int: copy.int32(20) - signature.size, at: 20)
            copy.removeSubrange(patched.count...)
            if let linkedit = image.commands.first(where: { $0.cmd == 0x19 && copy.fixedString($0.offset + 8, 16) == "__LINKEDIT" }) {
                let leoff = copy.int64(linkedit.offset + 40)
                copy.put64(int: patched.count - leoff, at: linkedit.offset + 48)
                copy.put64(int: (patched.count - leoff + 16383) & ~16383, at: linkedit.offset + 32)
            }
        }
        guard copy.count == patched.count else { return "sizes differ: \(patched.count) and \(copy.count) bytes" }
        if let at = (0..<copy.count).first(where: { copy[$0] != patched[$0] }) { return "first difference at offset \(at)" }
        return nil
    }
}
