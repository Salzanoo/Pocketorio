// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see ../Madeira/LICENSES/LICENSE-EXCEPTION.md
//
// Steam Cloud sync for Factorio's saves. The comparison, the record of the last
// sync, and the download and upload steps are adapted from Madeira's
// SteamOwnedLibrary.swift and SteamCloud.swift (github.com/willfaust/Madeira at
// c2c1b03, GPL-3.0-or-later); the path mapping is Factoriduo's own.
//
// Factorio's saves reach Steam Cloud through Steam Auto-Cloud: Steam's own log
// names the rule root="WinAppDataRoaming" path="Factorio/saves/" pattern="*.zip"
// (recursive). So a Windows PC's saves are listed as
// "%WinAppDataRoaming%Factorio/saves/<name>.zip", and on this device they live
// in Documents/Factorio/user/saves/<name>.zip, the game's write-data folder.
//
// Rules, as in Madeira (docs/STEAM_CLOUD.md there):
// - a save changed or new on one side only is copied to the other;
// - a save changed on both sides, or different with no record of a sync, is
//   left alone until the player chooses a side;
// - a download is checked against Steam's SHA-1 before anything is written;
// - a device file a download replaces, and a cloud file an upload replaces,
//   are backed up first (Documents/Factorio/steam-cloud-backups);
// - nothing is ever deleted in the cloud.
// Autosaves (_autosave*.zip) are left out unless the player turns them on:
// the PC and the phone both write them all the time, so they would be a
// choice after every session.

import CryptoKit
import Foundation

// MARK: - Where Factorio's cloud saves live on this device

struct FactorioCloudPaths: Sendable {
    static let appID: UInt32 = 427520
    static let defaultRoot = "WinAppDataRoaming"
    static let defaultFolder = "Factorio/saves"

    /// Documents/Factorio/user/saves
    var savesFolder: URL
    /// Steam's root and folder for the saves, from the app's `ufs` when it has a
    /// matching rule, else the defaults above.
    var root = FactorioCloudPaths.defaultRoot
    var folder = FactorioCloudPaths.defaultFolder
    var includeAutosaves = false

    static var device: FactorioCloudPaths {
        let documents = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
        return FactorioCloudPaths(savesFolder: documents.appendingPathComponent("Factorio/user/saves", isDirectory: true))
    }

    /// Takes the save rule from the app's product info, when it has one for
    /// Windows that names a saves folder of zip files.
    mutating func adopt(_ saveFiles: [SteamAppInfo.SaveFile]) {
        guard let rule = saveFiles.first(where: { rule in
            (rule.platforms.isEmpty || rule.platforms.contains("windows"))
                && rule.root.lowercased().hasPrefix("win")
                && rule.path.lowercased().replacingOccurrences(of: "\\", with: "/").contains("saves")
                && (rule.pattern.isEmpty || rule.pattern.lowercased().hasSuffix(".zip") || rule.pattern == "*")
        }) else { return }
        root = rule.root
        folder = rule.path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Splits "%Root%rest" into its root name and the rest.
    static func split(_ path: String) -> (root: String?, rest: String) {
        guard path.hasPrefix("%"), let end = path.dropFirst().firstIndex(of: "%") else { return (nil, path) }
        let root = String(path[path.index(after: path.startIndex)..<end])
        return (root, String(path[path.index(after: end)...]))
    }

    /// Whether a file name is a save this syncs.
    func syncs(name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".zip"), lower.count > 4, !lower.hasPrefix(".") else { return false }
        return includeAutosaves || !lower.hasPrefix("_autosave")
    }

    /// Plain relative components, or nil for an empty, absolute or escaping path.
    static func components(_ relative: String) -> [String]? {
        let parts = relative.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 16,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") || $0.utf8.count > 255 }) else { return nil }
        return parts
    }

    /// The path under the saves folder a cloud path stands for, or nil when it
    /// is not a Factorio save this syncs (another root or folder, an autosave
    /// while those are off, or an unsafe path).
    func relative(cloudPath: String) -> [String]? {
        let (cloudRoot, rest) = Self.split(cloudPath)
        guard let cloudRoot, cloudRoot.caseInsensitiveCompare(root) == .orderedSame,
              let parts = Self.components(rest), let folderParts = Self.components(folder),
              parts.count > folderParts.count else { return nil }
        for (index, part) in folderParts.enumerated() where parts[index].caseInsensitiveCompare(part) != .orderedSame { return nil }
        let inside = Array(parts[folderParts.count...])
        guard let name = inside.last, syncs(name: name) else { return nil }
        return inside
    }

    /// The cloud path for a save under the saves folder. `like` is a cloud path
    /// already in the list, whose spelling of root and folder is kept.
    func cloudPath(relative: [String], like: String? = nil) -> String {
        var prefix = "%\(root)%\(folder)/"
        if let like, self.relative(cloudPath: like) != nil, let parts = Self.components(Self.split(like).rest),
           let count = Self.components(folder)?.count, parts.count > count {
            prefix = "%\(Self.split(like).root ?? root)%" + parts[..<count].joined(separator: "/") + "/"
        }
        return prefix + relative.joined(separator: "/")
    }

    /// The device file for a relative path. The device's file system tells case
    /// apart and Windows does not: follow existing names without regard to case.
    func url(for relative: [String]) -> URL {
        var url = savesFolder
        for (index, part) in relative.enumerated() {
            let isFolder = index < relative.count - 1
            let exact = url.appendingPathComponent(part, isDirectory: isFolder)
            if FileManager.default.fileExists(atPath: exact.path) { url = exact; continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if let match = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                url = url.appendingPathComponent(match, isDirectory: isFolder)
            } else {
                url = exact
            }
        }
        return url
    }

    /// One key per save, whatever the spelling: its relative path, lower-cased.
    static func key(_ relative: [String]) -> String { relative.joined(separator: "/").lowercased() }
}

// MARK: - Comparison

enum FactorioCloudAudit {
    static func attributes(_ url: URL) -> (size: UInt64, time: UInt64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return (UInt64(max(0, values.fileSize ?? 0)), UInt64(max(0, values.contentModificationDate?.timeIntervalSince1970 ?? 0)))
    }

    /// Compares the cloud's list with the saves folder. Reads files; changes nothing.
    static func run(listing: SteamCloudListing, paths: FactorioCloudPaths) -> SteamCloudAudit {
        var audit = SteamCloudAudit()
        audit.changeNumber = listing.changeNumber
        var known = Set<String>()
        var spelling: String?
        for file in listing.files where file.persistState == 0 {
            audit.cloudFiles += 1
            guard let relative = paths.relative(cloudPath: file.path) else { audit.unmapped.append(file.path); continue }
            guard known.insert(FactorioCloudPaths.key(relative)).inserted else { continue }
            spelling = spelling ?? file.path
            let url = paths.url(for: relative)
            var entry = SteamCloudEntry(path: file.path, kind: .cloudOnly, cloudSize: file.size, cloudTime: file.timestamp, cloudSHA: file.sha)
            if let local = attributes(url) {
                entry.localSize = local.size; entry.localTime = local.time
                entry.localSHA = SteamCloudAudit.sha1(of: url) ?? Data()
                entry.kind = (local.size == file.size && entry.localSHA == file.sha) ? .same : .differ
            }
            audit.entries.append(entry)
        }
        // Saves on this device the cloud does not list.
        let base = paths.savesFolder.resolvingSymlinksInPath().path
        guard let walk = FileManager.default.enumerator(at: paths.savesFolder, includingPropertiesForKeys: [.isRegularFileKey]) else { return audit }
        var visited = 0
        for case let url as URL in walk {
            visited += 1
            if visited > 5_000 { break }
            guard paths.syncs(name: url.lastPathComponent), let local = attributes(url) else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/"), let relative = FactorioCloudPaths.components(String(path.dropFirst(base.count + 1))),
                  known.insert(FactorioCloudPaths.key(relative)).inserted else { continue }
            audit.entries.append(SteamCloudEntry(path: paths.cloudPath(relative: relative, like: spelling), kind: .localOnly,
                                                 localSize: local.size, localTime: local.time,
                                                 localSHA: SteamCloudAudit.sha1(of: url) ?? Data()))
        }
        return audit
    }
}

// MARK: - Settings

/// The player's Steam Cloud settings, in UserDefaults.
enum FactorioCloudSettings {
    /// Off: nothing is checked, downloaded or uploaded.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "factoriduo.steamCloud.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "factoriduo.steamCloud.enabled") }
    }
    static var includeAutosaves: Bool {
        get { UserDefaults.standard.bool(forKey: "factoriduo.steamCloud.autosaves") }
        set { UserDefaults.standard.set(newValue, forKey: "factoriduo.steamCloud.autosaves") }
    }
    /// The player said not to offer sign-in at launch again.
    static var declined: Bool {
        get { UserDefaults.standard.bool(forKey: "factoriduo.steamCloud.declined") }
        set { UserDefaults.standard.set(newValue, forKey: "factoriduo.steamCloud.declined") }
    }
}

// MARK: - Sync

/// Factorio's Steam Cloud saves for the signed-in account: compares, copies what
/// changed on one side only, and holds the rest for the player's choice.
@MainActor
final class FactorioCloudSync: ObservableObject {
    static let shared = FactorioCloudSync()

    enum Phase: Equatable {
        case idle, checking, ready, failed(String)
        case downloading(done: Int, of: Int), uploading(done: Int, of: Int)
    }

    @Published private(set) var phase: Phase = .idle
    /// Saves that need the player's choice.
    @Published private(set) var conflicts: [SteamCloudEntry] = []
    /// What the last sync did, for the screen.
    @Published private(set) var summary: String?
    /// Why the last download or upload stopped.
    @Published private(set) var problem: String?

    // MARK: Steam

    // One Steam logon for the whole app (a second one could log the first off).
    private var session: SteamSession { FactoriduoSteam.session }
    private var fetcher: SteamLibraryFetcher { FactoriduoSteam.fetcher }
    private var appInfo: SteamAppInfo?
    private var busy = false
    /// While the game runs nothing is downloaded: it may have the saves open.
    var gameRunning = false

    private static let supportFolder: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Factoriduo", isDirectory: true)
    }()
    private static var backupsFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents/Factorio/steam-cloud-backups", isDirectory: true)
    }

    private func currentPaths() -> FactorioCloudPaths {
        var paths = FactorioCloudPaths.device
        paths.includeAutosaves = FactorioCloudSettings.includeAutosaves
        if let info = appInfo { paths.adopt(info.saveFiles) }
        return paths
    }

    private static func reason(_ error: Error) -> String {
        if let steam = error as? SteamError { return SteamSignIn.reason(steam) }
        if let url = error as? URLError { return "url-\(url.code.rawValue)" }
        return String(describing: type(of: error))
    }

    /// Logs off and closes the connection, so this device holds no Steam logon
    /// while it is not syncing. Awaited, so a later sync starts on a clean
    /// connection. (Steam's idle timer would also log off after a minute.)
    func close() async {
        // A game download (GameDownload.swift) uses the same logon; leave it open.
        guard !FactoriduoSteam.downloading else { return }
        await session.suspend()
        session.resume()
    }

    // MARK: Record of the last sync

    // SHA-1 (hex) of each save when it was last the same on both sides, or a
    // mark (SteamCloudPlan.missingMark / deletedMark). Without it a difference
    // cannot be told from a change, so a save with no record is never copied
    // over the other side unasked.
    private struct Baseline: Codable { var account: String; var files: [String: String] }
    private var baselineFiles: [String: String]?

    private static func accountKey() -> String? { SteamSignIn.accountName?.lowercased() }
    private static var baselineURL: URL { supportFolder.appendingPathComponent("steam-cloud-sync.json") }

    private func baseline() -> [String: String] {
        if baselineFiles == nil {
            if let data = try? Data(contentsOf: Self.baselineURL), data.count <= 16 << 20,
               let stored = try? JSONDecoder().decode(Baseline.self, from: data), stored.account == Self.accountKey() {
                baselineFiles = stored.files
            } else {
                baselineFiles = [:]
            }
        }
        return baselineFiles ?? [:]
    }

    private func recordBaseline(_ settled: [String: String]) {
        guard !settled.isEmpty, let account = Self.accountKey() else { return }
        var files = baseline()
        var changed = false
        for (key, sha) in settled where files[key] != sha { files[key] = sha; changed = true }
        guard changed else { return }
        baselineFiles = files
        try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Baseline(account: account, files: files)).write(to: Self.baselineURL, options: .atomic)
    }

    /// The sign-in changed: read the record again. It belongs to one account,
    /// so another account starts with none.
    func reloadRecord() { baselineFiles = nil }

    // MARK: Check

    /// Compares the cloud with this device and returns what to do, or nil when
    /// it could not (phase says why).
    @discardableResult
    func check() async -> SteamCloudPlan? {
        guard FactorioCloudSettings.enabled, SteamSignIn.isSignedIn else { phase = .idle; return nil }
        phase = .checking
        do {
            try await session.ensureConnected()
            if appInfo == nil { appInfo = try? await fetcher.fetchAppInfo(appID: FactorioCloudPaths.appID) }
            var request = ProtobufEncoder()
            request.writeUInt32(fieldNumber: 1, value: FactorioCloudPaths.appID)   // appid
            request.writeUInt64(fieldNumber: 2, value: 0)                          // synced_change_number: the whole list
            let listing = try SteamCloudListing.parse(
                try await session.callServiceMethod(method: .cloudGetAppFileChangelist, body: request.data, timeout: 20))
            let paths = currentPaths()
            let audit = await Task.detached(priority: .utility) { FactorioCloudAudit.run(listing: listing, paths: paths) }.value
            let plan = SteamCloudPlan.make(audit: audit, baseline: baseline())
            recordBaseline(plan.settled)
            conflicts = plan.conflicts
            phase = .ready
            SteamLog.event("[steam-cloud] app=\(FactorioCloudPaths.appID) \(audit.summary) root=\(paths.root) folder-depth=\(paths.folder.split(separator: "/").count) autosaves=\(paths.includeAutosaves ? 1 : 0) | plan download=\(plan.download.count) upload=\(plan.upload.count) ask=\(plan.conflicts.count)")
            return plan
        } catch {
            phase = .failed(SteamSignIn.message(error))
            SteamLog.event("[steam-cloud] check failed reason=\(Self.reason(error))")
            return nil
        }
    }

    /// Compares, then copies what changed on one side only. Downloads only while
    /// the game is not running. Saves that need a choice stay in `conflicts`.
    func sync() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        problem = nil; summary = nil
        guard let plan = await check() else { return }
        var down = 0, up = 0
        if !plan.download.isEmpty, !gameRunning { down = await download(plan.download) }
        if !plan.upload.isEmpty { up = await upload(plan.upload) }
        if down + up > 0 { await check() }
        summary = Self.describe(down: down, up: up, ask: conflicts.count)
    }

    /// Uploads saves that changed on this device only. For when the app leaves
    /// the screen: nothing comes down while the game runs.
    func uploadChanges() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let plan = await check(), !plan.upload.isEmpty else { return }
        // The game may still be writing a save: wait until two looks 2 s apart agree.
        let paths = currentPaths()
        func snapshot() -> [String: (UInt64, UInt64)] {
            var result: [String: (UInt64, UInt64)] = [:]
            for entry in plan.upload {
                guard let relative = paths.relative(cloudPath: entry.path),
                      let local = FactorioCloudAudit.attributes(paths.url(for: relative)) else { continue }
                result[entry.key] = (local.size, local.time)
            }
            return result
        }
        let first = snapshot()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let second = snapshot()
        let steady = plan.upload.filter { entry in
            guard let a = first[entry.key], let b = second[entry.key] else { return false }
            return a == b && a.0 == entry.localSize
        }
        if !steady.isEmpty { _ = await upload(steady) }
    }

    enum Side { case device, cloud }

    /// The player's choice for the saves that need one: the cloud's copies
    /// replace this device's (backed up first), or this device's replace the
    /// cloud's (the cloud's backed up first).
    func resolve(_ entries: [SteamCloudEntry], keep side: Side) async {
        guard !busy, !entries.isEmpty else { return }
        busy = true
        defer { busy = false }
        SteamLog.event("[steam-cloud] choice=\(side == .cloud ? "cloud" : "device") files=\(entries.count)")
        var down = 0, up = 0
        if side == .cloud {
            down = await download(entries)
        } else {
            // A save missing on this device stays missing; the cloud keeps its copy.
            let gone = entries.filter { $0.kind == .cloudOnly }
            recordBaseline(Dictionary(gone.map { ($0.key, SteamCloudPlan.deletedMark + SteamCloudPlan.hex($0.cloudSHA)) },
                                      uniquingKeysWith: { a, _ in a }))
            let present = entries.filter { $0.kind != .cloudOnly }
            if !present.isEmpty { up = await upload(present) }
        }
        await check()
        summary = Self.describe(down: down, up: up, ask: conflicts.count)
    }

    static func describe(down: Int, up: Int, ask: Int) -> String {
        var parts: [String] = []
        if down > 0 { parts.append("\(down) save\(down == 1 ? "" : "s") downloaded") }
        if up > 0 { parts.append("\(up) uploaded") }
        if ask > 0 { parts.append("\(ask) need\(ask == 1 ? "s" : "") a choice") }
        return parts.isEmpty ? "Saves are in sync." : parts.joined(separator: ", ") + "."
    }

    // MARK: Download

    private static func backup(_ kind: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return backupsFolder.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
    }

    /// One cloud file's bytes, checked against the SHA-1 of the comparison: a
    /// file that changed in the cloud since then throws.
    private func cloudFile(_ entry: SteamCloudEntry) async throws -> Data {
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: FactorioCloudPaths.appID)   // appid
        request.writeString(fieldNumber: 2, value: entry.path)                 // filename
        let info = try SteamCloudDownloadInfo.parse(
            try await session.callServiceMethod(method: .cloudClientFileDownload, body: request.data, timeout: 20))
        return try await SteamCloudTransfer.fetch(info, expectedSHA: entry.cloudSHA)
    }

    /// Downloads the given cloud saves. Each is checked against Steam's checksum
    /// before anything is written, and a save it replaces is backed up first.
    /// Returns how many arrived.
    private func download(_ wanted: [SteamCloudEntry]) async -> Int {
        guard !gameRunning, !wanted.isEmpty else { return 0 }
        phase = .downloading(done: 0, of: wanted.count); problem = nil
        let paths = currentPaths()
        let backup = Self.backup("device")
        var done = 0, backedUp = 0
        var settled: [String: String] = [:]
        do {
            for entry in wanted {
                guard let relative = paths.relative(cloudPath: entry.path) else { continue }
                let file = try await cloudFile(entry)
                // The player may have started the game while this file came down.
                guard !gameRunning else { throw CancellationError() }
                let url = paths.url(for: relative)
                let existed = FileManager.default.fileExists(atPath: url.path)
                try SteamCloudTransfer.place(file, at: url, backupTo: backup, relative: relative, time: entry.cloudTime)
                done += 1; if existed { backedUp += 1 }
                settled[entry.key] = SteamCloudPlan.hex(entry.cloudSHA)
                phase = .downloading(done: done, of: wanted.count)
            }
            SteamLog.event("[steam-cloud] downloaded files=\(done) backed-up=\(backedUp)")
        } catch {
            SteamLog.event("[steam-cloud] download failed after=\(done) reason=\(Self.reason(error))")
            problem = "Steam Cloud download stopped: \(SteamSignIn.message(error)) Saves already downloaded are in place; nothing else was changed."
        }
        recordBaseline(settled)
        phase = .ready
        return done
    }

    // MARK: Upload

    /// A number Steam uses to tell this device's uploads from other machines'.
    private static var clientID: UInt64 {
        let url = supportFolder.appendingPathComponent("steam-cloud-client-id")
        if let text = try? String(contentsOf: url, encoding: .utf8), let stored = UInt64(text), stored != 0 { return stored }
        let fresh = UInt64.random(in: 1...UInt64(Int64.max))
        try? FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        try? String(fresh).write(to: url, atomically: true, encoding: .utf8)
        return fresh
    }

    /// Uploads the given device saves to Steam Cloud as one batch. Returns how
    /// many Steam accepted; the comparison that follows confirms the cloud holds them.
    private func upload(_ wanted: [SteamCloudEntry]) async -> Int {
        guard !wanted.isEmpty else { return 0 }
        phase = .uploading(done: 0, of: wanted.count); problem = nil
        let appID = FactorioCloudPaths.appID
        let paths = currentPaths()
        var done = 0
        var batchID: UInt64 = 0
        var settled: [String: String] = [:]
        func complete(_ ok: Bool) async {
            guard batchID != 0 else { return }
            var request = ProtobufEncoder()
            request.writeUInt32(fieldNumber: 1, value: appID)                // appid
            request.writeUInt64(fieldNumber: 2, value: batchID)              // batch_id
            request.writeUInt32(fieldNumber: 3, value: ok ? 1 : 2)           // batch_eresult: OK / Fail
            _ = try? await session.callServiceMethod(method: .cloudCompleteAppUploadBatch, body: request.data, timeout: 30)
        }
        do {
            // Steam keeps no copy of a cloud file an upload replaces: keep one here
            // first. If one cannot be fetched (or the cloud changed since the
            // check), nothing is uploaded.
            let replaced = wanted.filter { !$0.cloudSHA.isEmpty }
            if !replaced.isEmpty {
                let backup = Self.backup("cloud")
                for entry in replaced {
                    guard let relative = paths.relative(cloudPath: entry.path) else { continue }
                    let file = try await cloudFile(entry)
                    var target = backup
                    for part in relative { target.appendPathComponent(part) }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.write(to: target, options: .atomic)
                }
                SteamLog.event("[steam-cloud] cloud copies backed up before upload files=\(replaced.count)")
            }
            var begin = ProtobufEncoder()
            begin.writeUInt32(fieldNumber: 1, value: appID)                  // appid
            begin.writeString(fieldNumber: 2, value: "Factoriduo")           // machine_name
            for entry in wanted { begin.writeString(fieldNumber: 3, value: entry.path) }   // files_to_upload
            begin.writeUInt64(fieldNumber: 5, value: Self.clientID)          // client_id
            begin.writeUInt64(fieldNumber: 6, value: UInt64(appInfo?.buildID ?? 0))   // app_build_id
            var batch = ProtobufDecoder(try await session.callServiceMethod(method: .cloudBeginAppUploadBatch, body: begin.data, timeout: 30))
            while let tag = try batch.readTag() {
                if tag.fieldNumber == 1, tag.wireType == .varint { batchID = try batch.readVarint() } else { try batch.skip(wireType: tag.wireType) }
            }
            guard batchID != 0 else { throw SteamFileError.invalid("Steam did not open an upload for Factorio.") }
            for entry in wanted {
                guard let relative = paths.relative(cloudPath: entry.path) else { continue }
                let url = paths.url(for: relative)
                let file = try Data(contentsOf: url)
                guard file.count <= SteamCloudTransfer.maxFileBytes else { throw SteamFileError.invalid("A save is too large to upload.") }
                let sha = Data(Insecure.SHA1.hash(data: file))
                let time = UInt64(max(0, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970))
                var request = ProtobufEncoder()
                request.writeUInt32(fieldNumber: 1, value: appID)                    // appid
                request.writeUInt32(fieldNumber: 2, value: UInt32(file.count))       // file_size
                request.writeUInt32(fieldNumber: 3, value: UInt32(file.count))       // raw_file_size
                request.writeBytes(fieldNumber: 4, value: sha)                       // file_sha
                request.writeUInt64(fieldNumber: 5, value: time)                     // time_stamp
                request.writeString(fieldNumber: 6, value: entry.path)               // filename
                request.writeUInt32(fieldNumber: 7, value: 0xFFFF_FFFF)              // platforms_to_sync: all
                request.writeUInt32(fieldNumber: 9, value: session.cellID)           // cell_id
                request.writeUInt64(fieldNumber: 13, value: batchID)                 // upload_batch_id
                let answer = try SteamCloudUploadBlock.parse(
                    try await session.callServiceMethod(method: .cloudClientBeginFileUpload, body: request.data, timeout: 30))
                guard !answer.encrypt else { throw SteamFileError.invalid("Steam asked for an encrypted upload, which is not supported.") }
                var sent = true
                var statuses: [Int] = []
                do { statuses = try await SteamCloudTransfer.send(file, blocks: answer.blocks) } catch {
                    sent = false
                    SteamLog.event("[steam-cloud] upload part failed reason=\(Self.reason(error))")
                }
                var commit = ProtobufEncoder()
                commit.writeBool(fieldNumber: 1, value: sent)                        // transfer_succeeded
                commit.writeUInt32(fieldNumber: 2, value: appID)                     // appid
                commit.writeBytes(fieldNumber: 3, value: sha)                        // file_sha
                commit.writeString(fieldNumber: 4, value: entry.path)                // filename
                var committed = false
                var reply = ProtobufDecoder(try await session.callServiceMethod(method: .cloudClientCommitFileUpload, body: commit.data, timeout: 30))
                while let tag = try reply.readTag() {
                    if tag.fieldNumber == 1, tag.wireType == .varint { committed = try reply.readVarint() != 0 } else { try reply.skip(wireType: tag.wireType) }
                }
                SteamLog.event("[steam-cloud] upload file=\(done + 1)/\(wanted.count) bytes=\(file.count) parts=\(answer.blocks.count) http=\(statuses.map(String.init).joined(separator: ",")) committed=\(committed ? 1 : 0)")
                guard sent, committed else { throw SteamFileError.invalid("Steam did not accept a save file.") }
                settled[entry.key] = SteamCloudPlan.hex(sha)
                done += 1
                phase = .uploading(done: done, of: wanted.count)
            }
            await complete(true)
            SteamLog.event("[steam-cloud] uploaded files=\(done)")
        } catch {
            await complete(false)
            SteamLog.event("[steam-cloud] upload failed after=\(done) reason=\(Self.reason(error))")
            problem = "Steam Cloud upload stopped: \(SteamSignIn.message(error)) This device's saves were not changed."
        }
        recordBaseline(settled)
        phase = .ready
        return done
    }
}
