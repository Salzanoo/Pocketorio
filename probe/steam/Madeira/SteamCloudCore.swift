// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// Modified for Factoriduo (2026-10-30): the Steam Cloud protocol parts of
// Madeira's SteamCloud.swift (app/Madeira/SteamCloud.swift at c2c1b03), without
// the Wine-prefix path mapping, profile merge and remotecache.vdf code, which
// Factoriduo replaces with probe/steam/Factoriduo/FactorioCloud.swift. The
// parts below are unchanged, except that SteamCloudAudit loses run() and
// findElsewhere(), which read the Wine prefix (FactorioCloud.swift builds audits).
//
// Written from Steam's published service messages (Cloud.GetAppFileChangelist,
// Cloud.ClientFileDownload, Cloud.BeginAppUploadBatch, ...); the same model as
// other open-source Steam clients use.

import Compression
import CryptoKit
import Foundation

// MARK: - The cloud's file list

/// One file of an app's Steam Cloud, as Cloud.GetAppFileChangelist lists it.
struct SteamCloudFile: Equatable, Sendable {
    /// Folder part, usually starting with a `%Root%` placeholder; may be empty.
    var prefix: String
    var name: String
    var sha: Data
    /// Unix seconds.
    var timestamp: UInt64
    var size: UInt64
    /// persist_state: 0 = present; anything else is a forgotten or deleted file.
    var persistState: UInt32

    var path: String { prefix + name }
}

struct SteamCloudListing: Equatable, Sendable {
    var changeNumber: UInt64 = 0
    var files: [SteamCloudFile] = []

    /// CCloud_GetAppFileChangelist_Response: current_change_number = 1,
    /// files = 2 { file_name = 1, sha_file = 2, time_stamp = 3, raw_file_size = 4,
    /// persist_state = 5, path_prefix_index = 7 }, path_prefixes = 4.
    static func parse(_ data: Data) throws -> SteamCloudListing {
        var decoder = ProtobufDecoder(data)
        var listing = SteamCloudListing()
        var prefixes: [String] = []
        var raw: [(file: SteamCloudFile, prefixIndex: Int?)] = []
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): listing.changeNumber = try decoder.readVarint()
            case (4, .lengthDelimited): prefixes.append(try decoder.readString())
            case (2, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var file = SteamCloudFile(prefix: "", name: "", sha: Data(), timestamp: 0, size: 0, persistState: 0)
                var prefixIndex: Int?
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): file.name = try sub.readString()
                    case (2, .lengthDelimited): file.sha = try sub.readBytes()
                    case (3, .varint): file.timestamp = try sub.readVarint()
                    case (4, .varint): file.size = try sub.readVarint()
                    case (5, .varint): file.persistState = UInt32(truncatingIfNeeded: try sub.readVarint())
                    case (7, .varint): prefixIndex = Int(truncatingIfNeeded: try sub.readVarint())
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                raw.append((file, prefixIndex))
                if raw.count > 20_000 { throw SteamFileError.invalid("Too many Steam Cloud files.") }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        listing.files = raw.map { entry in
            var file = entry.file
            if let index = entry.prefixIndex, prefixes.indices.contains(index) { file.prefix = prefixes[index] }
            return file
        }
        return listing
    }
}

// MARK: - Comparison

/// One save file, on either side or both.
struct SteamCloudEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case same, differ, cloudOnly, localOnly }
    /// The cloud path with its %Root% placeholder (for a local-only file, the
    /// path it would have).
    var path: String
    var kind: Kind
    var cloudSize: UInt64 = 0
    var cloudTime: UInt64 = 0
    var localSize: UInt64 = 0
    var localTime: UInt64 = 0
    var cloudSHA = Data()
    var localSHA = Data()

    var id: String { path }
    /// Baseline key: one spelling per file.
    var key: String { path.lowercased() }
    /// The file name without its folders, for display.
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// How one app's cloud and local save files compare.
struct SteamCloudAudit: Equatable, Sendable {
    var changeNumber: UInt64 = 0
    var cloudFiles = 0
    var entries: [SteamCloudEntry] = []
    /// Cloud paths under a root this prefix has no folder for.
    var unmapped: [String] = []

    func count(_ kind: SteamCloudEntry.Kind) -> Int { entries.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }
    func paths(_ kind: SteamCloudEntry.Kind) -> [String] { entries.filter { $0.kind == kind }.map(\.path) }

    static func sha1(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil  // A partial digest is not a checksum of this save.
        }
        return Data(hasher.finalize())
    }

    private static func attributes(_ url: URL) -> (size: UInt64, time: UInt64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return (UInt64(max(0, values.fileSize ?? 0)), UInt64(max(0, values.contentModificationDate?.timeIntervalSince1970 ?? 0)))
    }

    /// One spelling per file, whatever route led to it and whatever its case.
    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path.lowercased() }

    var summary: String {
        "cloud-change=\(changeNumber) cloud-files=\(cloudFiles) same=\(count(.same)) differ=\(count(.differ)) " +
        "missing-local=\(count(.cloudOnly)) local-only=\(count(.localOnly)) unmapped=\(unmapped.count)"
    }
}

// MARK: - Download

/// Where Steam says a cloud file can be fetched (Cloud.ClientFileDownload).
struct SteamCloudDownloadInfo: Sendable {
    var fileSize: UInt64 = 0      // bytes on the wire
    var rawSize: UInt64 = 0       // bytes of the file itself
    var host = ""
    var path = ""
    var https = true
    var headers: [(name: String, value: String)] = []
    var encrypted = false

    /// CCloud_ClientFileDownload_Response: file_size = 2, raw_file_size = 3,
    /// url_host = 7, url_path = 8, use_https = 9, request_headers = 10
    /// { name = 1, value = 2 }, encrypted = 11.
    static func parse(_ data: Data) throws -> SteamCloudDownloadInfo {
        var decoder = ProtobufDecoder(data)
        var info = SteamCloudDownloadInfo()
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (2, .varint): info.fileSize = try decoder.readVarint()
            case (3, .varint): info.rawSize = try decoder.readVarint()
            case (7, .lengthDelimited): info.host = try decoder.readString()
            case (8, .lengthDelimited): info.path = try decoder.readString()
            case (9, .varint): info.https = try decoder.readVarint() != 0
            case (11, .varint): info.encrypted = try decoder.readVarint() != 0
            case (10, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var name = "", value = ""
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): name = try sub.readString()
                    case (2, .lengthDelimited): value = try sub.readString()
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                if !name.isEmpty, info.headers.count < 32 { info.headers.append((name, value)) }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return info
    }

    var url: URL? {
        guard !host.isEmpty, !host.contains("/"), !host.contains("@") else { return nil }
        // Saves and request headers always go over TLS, whatever use_https says.
        return URL(string: "https://" + host + (path.hasPrefix("/") ? path : "/" + path))
    }
}

enum SteamCloudTransfer {
    /// Saves are small; anything larger than this is refused.
    static let maxFileBytes = 256 << 20

    private static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// The first entry of a ZIP archive (Steam sends a compressed cloud file
    /// as a one-entry archive): stored or deflated. Sizes come from the
    /// central directory, which is always filled in.
    static func unzipFirstEntry(_ data: Data, rawSize: Int) -> Data? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 30, u32(0) == 0x04034b50, rawSize >= 0, rawSize <= maxFileBytes else { return nil }
        let method = u16(8)
        let start = 30 + u16(26) + u16(28)
        var packed = u32(18)
        if packed == 0 {   // sizes deferred to the central directory
            var at = bytes.count - 46
            var found = false
            while at >= start {
                if u32(at) == 0x02014b50 { packed = u32(at + 20); found = true; break }
                at -= 1
            }
            guard found else { return nil }
        }
        guard start <= bytes.count, packed >= 0, start + packed <= bytes.count else { return nil }
        let payload = Array(bytes[start..<(start + packed)])
        if method == 0 { return payload.count == rawSize ? Data(payload) : nil }
        guard method == 8, rawSize > 0 else { return rawSize == 0 && method == 8 ? Data() : nil }
        let capacity = rawSize + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compression_decode_buffer(&output, capacity, payload, payload.count, nil, COMPRESSION_ZLIB)
        return written == rawSize ? Data(output[0..<rawSize]) : nil
    }

    /// Fetches one cloud file's bytes and checks them against the SHA-1 the
    /// cloud's own list gives. Throws rather than return anything unverified.
    static func fetch(_ info: SteamCloudDownloadInfo, expectedSHA: Data) async throws -> Data {
        guard !info.encrypted else { throw SteamFileError.invalid("This Steam Cloud file is encrypted, which is not supported.") }
        guard let url = info.url, info.fileSize <= UInt64(maxFileBytes), info.rawSize <= UInt64(maxFileBytes) else {
            throw SteamFileError.invalid("Steam gave no usable address for this Steam Cloud file.")
        }
        var request = URLRequest(url: url)
        for header in info.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        let (body, response) = try await http.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamFileError.invalid("Steam Cloud download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        var file = body
        if info.fileSize != info.rawSize || (body.count != Int(info.rawSize) && body.starts(with: [0x50, 0x4b, 0x03, 0x04])) {
            guard let unpacked = unzipFirstEntry(body, rawSize: Int(info.rawSize)) else {
                throw SteamFileError.invalid("A Steam Cloud file could not be unpacked.")
            }
            file = unpacked
        }
        guard Data(Insecure.SHA1.hash(data: file)) == expectedSHA else {
            throw SteamFileError.invalid("A Steam Cloud file did not match its checksum.")
        }
        return file
    }

    /// Puts downloaded bytes in place. An existing file is first copied under
    /// `backup` (same relative path); the new file replaces it atomically and
    /// takes the cloud's modification time.
    static func place(_ file: Data, at url: URL, backupTo backup: URL, relative: [String], time: UInt64) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            var target = backup
            for part in relative { target.appendPathComponent(part) }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: url, to: target)
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url, options: .atomic)
        if time > 0 {
            try? manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(time))], ofItemAtPath: url.path)
        }
    }
}

// MARK: - What to do with a comparison

/// Decides, from a comparison and the record of what was last in sync, which
/// files changed on one side only (and can be copied without asking) and
/// which need the user's choice. Foundation only.
struct SteamCloudPlan: Equatable, Sendable {
    var download: [SteamCloudEntry] = []
    var upload: [SteamCloudEntry] = []
    /// Differ, and either both sides changed since the last sync or there is
    /// no record of one.
    var conflicts: [SteamCloudEntry] = []
    /// New record entries: SHA-1 of the files identical on both sides now, and
    /// the marks below.
    var settled: [String: String] = [:]

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Record marks besides a SHA-1. `missing:<sha>`: a save synced here at
    /// <sha> is gone from this device while the cloud still has it, and no
    /// choice was made yet. `deleted:<sha>`: the user chose to leave it gone
    /// while the cloud held <sha>.
    static let missingMark = "missing:", deletedMark = "deleted:"

    /// `baseline`: SHA-1 (hex) of each file when it was last the same on both
    /// sides, or a mark, by `SteamCloudEntry.key`.
    static func make(audit: SteamCloudAudit, baseline: [String: String]) -> SteamCloudPlan {
        var plan = SteamCloudPlan()
        for entry in audit.entries {
            let known = baseline[entry.key]
            let marked = known.map { $0.hasPrefix(missingMark) || $0.hasPrefix(deletedMark) } ?? false
            switch entry.kind {
            case .same:
                plan.settled[entry.key] = hex(entry.cloudSHA)
            case .differ:
                // Without a complete local checksum neither side can be chosen automatically.
                guard !entry.localSHA.isEmpty else { plan.conflicts.append(entry); continue }
                // A save that was missing here and is back is a new file, not a
                // change of the synced one: never copied over the cloud's unasked.
                let cloud = hex(entry.cloudSHA), local = hex(entry.localSHA)
                if let known, !marked, known == cloud, known != local { plan.upload.append(entry) }
                else if let known, !marked, known == local, known != cloud { plan.download.append(entry) }
                else { plan.conflicts.append(entry) }
            case .cloudOnly:
                let cloud = hex(entry.cloudSHA)
                if known == nil {
                    plan.download.append(entry)          // new in the cloud
                } else if known == deletedMark + cloud {
                    break                                // left gone, by the user's choice
                } else if known?.hasPrefix(deletedMark) == true {
                    plan.download.append(entry)          // changed in the cloud since: nothing here to lose
                } else {
                    // Synced here once and gone now: lost with the prefix or deleted
                    // by the game. The user chooses; until then the mark keeps a new
                    // save of that name from going up over the cloud's copy.
                    plan.conflicts.append(entry)
                    if !marked { plan.settled[entry.key] = missingMark + (known ?? "") }
                }
            case .localOnly:
                // New on this device. A file the cloud once had and no longer has was
                // deleted elsewhere: it is not sent back.
                if known == nil, !entry.localSHA.isEmpty { plan.upload.append(entry) }
            }
        }
        return plan
    }
}

// MARK: - Upload

/// One HTTP request of a file upload (ClientCloudFileUploadBlockDetails).
struct SteamCloudUploadBlock: Sendable {
    var host = ""
    var path = ""
    var https = true
    var method: Int32 = 0
    var headers: [(name: String, value: String)] = []
    var offset: UInt64 = 0
    var length: UInt64 = 0
    var explicitBody = Data()

    /// CCloud_ClientBeginFileUpload_Response: encrypt_file = 1, block_requests = 2
    /// { url_host = 1, url_path = 2, use_https = 3, http_method = 4,
    /// request_headers = 5 { name = 1, value = 2 }, block_offset = 6,
    /// block_length = 7, explicit_body_data = 8 }.
    static func parse(_ data: Data) throws -> (encrypt: Bool, blocks: [SteamCloudUploadBlock]) {
        var decoder = ProtobufDecoder(data)
        var encrypt = false
        var blocks: [SteamCloudUploadBlock] = []
        while let tag = try decoder.readTag() {
            switch (tag.fieldNumber, tag.wireType) {
            case (1, .varint): encrypt = try decoder.readVarint() != 0
            case (2, .lengthDelimited):
                var sub = ProtobufDecoder(try decoder.readBytes())
                var block = SteamCloudUploadBlock()
                while let field = try sub.readTag() {
                    switch (field.fieldNumber, field.wireType) {
                    case (1, .lengthDelimited): block.host = try sub.readString()
                    case (2, .lengthDelimited): block.path = try sub.readString()
                    case (3, .varint): block.https = try sub.readVarint() != 0
                    case (4, .varint): block.method = Int32(truncatingIfNeeded: try sub.readVarint())
                    case (6, .varint): block.offset = try sub.readVarint()
                    case (7, .varint): block.length = try sub.readVarint()
                    case (8, .lengthDelimited): block.explicitBody = try sub.readBytes()
                    case (5, .lengthDelimited):
                        var header = ProtobufDecoder(try sub.readBytes())
                        var name = "", value = ""
                        while let part = try header.readTag() {
                            switch (part.fieldNumber, part.wireType) {
                            case (1, .lengthDelimited): name = try header.readString()
                            case (2, .lengthDelimited): value = try header.readString()
                            default: try header.skip(wireType: part.wireType)
                            }
                        }
                        if !name.isEmpty, block.headers.count < 32 { block.headers.append((name, value)) }
                    default: try sub.skip(wireType: field.wireType)
                    }
                }
                blocks.append(block)
                if blocks.count > 4096 { throw SteamFileError.invalid("Steam asked for too many upload parts.") }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return (encrypt, blocks)
    }

    var url: URL? {
        guard !host.isEmpty, !host.contains("/"), !host.contains("@") else { return nil }
        // Saves and request headers always go over TLS, whatever use_https says.
        return URL(string: "https://" + host + (path.hasPrefix("/") ? path : "/" + path))
    }
}

extension SteamCloudTransfer {
    /// Sends the parts of one file where Steam asked for them. k_EHTTPMethodPOST
    /// is 3; Steam's storage otherwise takes PUT. Returns each part's HTTP status.
    @discardableResult
    static func send(_ file: Data, blocks: [SteamCloudUploadBlock]) async throws -> [Int] {
        var statuses: [Int] = []
        for block in blocks {
            guard let url = block.url else { throw SteamFileError.invalid("Steam gave no usable address for an upload.") }
            var body = block.explicitBody
            if body.isEmpty {
                let start = Int(min(block.offset, UInt64(file.count)))
                let end = Int(min(block.offset + block.length, UInt64(file.count)))
                guard end - start == Int(block.length) else { throw SteamFileError.invalid("Steam asked for a part outside the file.") }
                body = file.subdata(in: start..<end)
            }
            var request = URLRequest(url: url)
            request.httpMethod = block.method == 3 ? "POST" : "PUT"
            for header in block.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
            let (_, response) = try await uploadSession.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            statuses.append(status)
            guard (200..<300).contains(status) else { throw SteamFileError.invalid("Steam Cloud upload failed (HTTP \(status)).") }
        }
        return statuses
    }

    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}
