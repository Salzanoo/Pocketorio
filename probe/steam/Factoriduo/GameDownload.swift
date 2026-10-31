// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see ../Madeira/LICENSES/LICENSE-EXCEPTION.md
//
// The downloader's stages 1 and 2 (docs/ON_DEVICE.md): download
// the supported Factorio version the player picks, from its Steam branch, with
// the app's own Steam sign-in through Madeira's depot downloader, and check the
// executable against the audited builds. The downloaded game isn't run yet.

import CryptoKit
import SwiftUI
import UIKit

// MARK: - The audited builds

/// The Factorio executables the port accepts, as in tools/config.py. Factorio's
/// Steam app has a branch per version, named after it ("2.1.24"), so a version
/// is downloaded from its own branch whatever Steam's default is.
enum FactorioBuilds {
    struct Build: Equatable, Sendable {
        let version: String
        let sha256: String
        let status: String
        /// Not an audited build, but an update in the series the app was built for.
        var untested = false
    }

    static let supported: [Build] = [
        Build(version: "2.1.24", sha256: "991c1182742f60cde97be2a412106670f73ba483fd1715a95e687b73c8b5250d",
              status: "Factorio 2.1.24 Steam; ported from the 2.1.23 audit, device testing required"),
        Build(version: "2.1.23", sha256: "42218e9676f36687282800e5b6336b049c0f0e45f0f71eb20f90c49ccdec4359",
              status: "Factorio 2.1.23 Steam; experimental iPhone port"),
        Build(version: "2.0.77", sha256: "90e2ebfdb5fd8b3966915f704a0ae99177c2af64ed9267c634ced42bff36d820",
              status: "experimental; device testing required"),
        Build(version: "2.0.77", sha256: "00b014d78df07e05ab1cee853904c8f7b3814ca652c043461a9d49fbad46cdf6",
              status: "upstream-tested"),
    ]

    static func build(sha256: String) -> Build? { supported.first { $0.sha256 == sha256 } }

    /// Steam's default branch: whatever Factorio is newest there.
    static let newest = "public"

    /// "2.1" of "2.1.24".
    static func series(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// The Factorio the app was built for (tools/build_probe.py, from its profile).
    static var builtFor: String {
        Bundle.main.object(forInfoDictionaryKey: "FactoriduoGameVersion") as? String ?? supported[0].version
    }

    /// An unaudited build of the same series as the app's (2.1.25 for a 2.1.24
    /// app): minor updates usually keep the layout the patcher needs, and the
    /// patcher refuses one that doesn't. A new macOS symbol shows when it loads.
    static func untested(version: String?, sha256: String) -> Build? {
        guard let version, series(version) == series(builtFor) else { return nil }
        return Build(version: version, sha256: sha256,
                     status: "untested update of Factorio \(builtFor)", untested: true)
    }

    /// The versions to offer, newest first, then Steam's newest.
    static var versions: [String] {
        var seen = Set<String>()
        return supported.map(\.version).filter { seen.insert($0).inserted } + [newest]
    }

    static func label(_ version: String) -> String {
        version == newest ? "Newest on Steam" : version
    }

    /// The version the player picked in Settings; the newest by default.
    static var chosen: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "factoriduo.game.version")
            return saved.flatMap { versions.contains($0) ? $0 : nil } ?? versions[0]
        }
        set { UserDefaults.standard.set(newValue, forKey: "factoriduo.game.version") }
    }
}

// MARK: - Download

@MainActor
final class GameDownload: ObservableObject {
    static let shared = GameDownload()

    enum State: Equatable {
        case none
        case downloading(SteamDownloadProgress)
        case verifying
        /// An audited build is on the device.
        case ready(FactorioBuilds.Build)
        /// Downloaded, but not an audited executable.
        case unsupported(version: String?, sha256: String)
        case failed(String)
    }

    @Published private(set) var state: State = .none
    /// The downloaded factorio executable, once checked.
    @Published private(set) var executable: URL?
    private var task: Task<Void, Never>?

    static let appID: UInt32 = 427520

    /// Library/Application Support/Factoriduo/game: kept out of the Files app and backups.
    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Factoriduo/game", isDirectory: true)
    }
    nonisolated static var installFolder: URL { folder.appendingPathComponent("Factorio", isDirectory: true) }

    init() { refresh() }

    var busy: Bool {
        switch state {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    /// Looks at what is already downloaded.
    func refresh() {
        guard !busy else { return }
        guard Self.findApp(in: Self.installFolder) != nil else { state = .none; return }
        verify()
    }

    func download() {
        guard !busy, SteamSignIn.isSignedIn else { return }
        state = .downloading(SteamDownloadProgress())
        FactoriduoSteam.downloading = true
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer {
                FactoriduoSteam.downloading = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                try await run()
                verify()
            } catch is CancellationError {
                state = Self.findApp(in: Self.installFolder) == nil ? .none : .failed("Download stopped. It resumes where it left off.")
            } catch {
                SteamLog.event("[game-download] failed reason=\(String(describing: type(of: error)))")
                state = .failed(SteamSignIn.message(error))
            }
        }
    }

    func cancel() { task?.cancel() }

    func delete() {
        guard !busy else { return }
        try? FileManager.default.removeItem(at: Self.folder)
        state = .none
    }

    private func run() async throws {
        let session = FactoriduoSteam.session, fetcher = FactoriduoSteam.fetcher
        let version = FactorioBuilds.chosen
        try await session.ensureConnected()
        guard let app = try await fetcher.fetchAppInfo(appID: Self.appID) else {
            throw SteamFileError.invalid("Steam sent no product info for Factorio.")
        }
        let owned = try? await fetcher.ownedDepotIDs()
        guard let depot = Self.gameDepot(app, branch: version, owned: owned) else {
            throw SteamFileError.invalid("Steam has no macOS Factorio \(version) for this account.")
        }
        SteamLog.event("[game-download] version=\(version) depot=\(depot.depotID) manifest=\(depot.manifests[version] ?? 0) build=\(app.buildID)")
        UserDefaults.standard.removeObject(forKey: Self.manifestsKey)
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = Self.folder
        try? folder.setResourceValues(values)

        let downloader = DepotDownloader(session: session)
        _ = try await downloader.install(
            app, steamApps: Self.folder, depots: [depot], branch: version,
            installFolder: Self.installFolder, writeRecord: false, removeOtherFiles: true,
            ownedDepots: { try? await fetcher.ownedDepotIDs() },
            progress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress)
                }
            })
        UserDefaults.standard.set(downloader.lastManifests.map { "\($0.depot):\($0.manifest)" }.joined(separator: " "),
                                  forKey: Self.manifestsKey)
    }

    /// "depot:manifest ..." of the last finished download, for the report.
    static let manifestsKey = "factoriduo.game.manifests"
    static var manifests: String? { UserDefaults.standard.string(forKey: manifestsKey) }

    /// The one depot to download: each of Factorio's macOS depots holds the
    /// whole game (427525 the base game, 645392 the game with Space Age), so
    /// the Space Age one when the account owns it, otherwise the base game.
    /// Only depots with a manifest on the version's branch count.
    static func gameDepot(_ app: SteamAppInfo, branch: String, owned: Set<UInt32>?) -> SteamAppInfo.DepotInfo? {
        let mac = app.depots.filter { depot in
            depot.oslist.lowercased().contains("macos") &&
            !depot.isSharedInstall && !depot.lowViolence && depot.manifests[branch] != nil &&
            (depot.language.isEmpty || depot.language.caseInsensitiveCompare("english") == .orderedSame)
        }.sorted { $0.depotID < $1.depotID }
        if let owned, let dlc = mac.last(where: { $0.dlcAppID != nil && owned.contains($0.depotID) }) { return dlc }
        return mac.first { $0.dlcAppID == nil }
    }

    // MARK: Verify

    private func verify() {
        guard let app = Self.findApp(in: Self.installFolder) else { state = .failed("The download has no factorio.app."); return }
        state = .verifying
        executable = app.appendingPathComponent("Contents/MacOS/factorio")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (String?, String?) in
                (Self.sha256(of: app.appendingPathComponent("Contents/MacOS/factorio")), Self.version(of: app))
            }.value
            guard let digest = result.0 else { state = .failed("The game's executable can't be read."); return }
            if let build = FactorioBuilds.build(sha256: digest) {
                state = .ready(build)
                SteamLog.event("[game-download] verified version=\(build.version)")
            } else if let build = FactorioBuilds.untested(version: result.1, sha256: digest) {
                state = .ready(build)
                SteamLog.event("[game-download] untested version=\(build.version) sha256=\(digest)")
            } else {
                state = .unsupported(version: result.1, sha256: digest)
                SteamLog.event("[game-download] unsupported version=\(result.1 ?? "?") sha256=\(digest)")
            }
        }
    }

    /// The factorio.app a depot download contains, at most three folders down.
    nonisolated static func findApp(in folder: URL) -> URL? {
        let fm = FileManager.default
        var level = [folder]
        for _ in 0..<4 {
            var next: [URL] = []
            for directory in level {
                let candidate = directory.appendingPathComponent("factorio.app", isDirectory: true)
                if fm.fileExists(atPath: candidate.appendingPathComponent("Contents/MacOS/factorio").path) { return candidate }
                let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                next += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            level = next
        }
        return nil
    }

    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func version(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}

// MARK: - Settings section

struct GameDownloadSection: View {
    let title: String

    init(title: String = "Factorio") { self.title = title }
    @ObservedObject private var download = GameDownload.shared
    @ObservedObject private var steam = SteamSignInModel.shared

    @State private var version = FactorioBuilds.chosen

    var body: some View {
        Section {
            Picker("Version", selection: $version) {
                ForEach(FactorioBuilds.versions, id: \.self) { Text(FactorioBuilds.label($0)).tag($0) }
            }
            .disabled(download.busy)
            .onChange(of: version) { _, new in FactorioBuilds.chosen = new }
            switch download.state {
            case .none:
                Text("No game files downloaded.")
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                    Text(describe(progress)).font(.footnote).foregroundStyle(.secondary)
                }
            case .verifying:
                HStack(spacing: 12) { ProgressView(); Text("Checking the game files…") }
            case .ready(let build) where build.untested:
                Label("Factorio \(build.version), an untested update of \(FactorioBuilds.builtFor). It usually works; if it doesn't, pick \(FactorioBuilds.builtFor).",
                      systemImage: "questionmark.diamond.fill").foregroundStyle(.orange)
                if let executable = download.executable {
                    GamePrepareRows(build: build, executable: executable)
                }
            case .ready(let build):
                Label("Factorio \(build.version), a supported build", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let executable = download.executable {
                    GamePrepareRows(build: build, executable: executable)
                }
            case .unsupported(let version, let sha256):
                Label("Steam sent Factorio \(version ?? "of an unknown version"), which this app can't run: it was built for \(FactorioBuilds.series(FactorioBuilds.builtFor)).x.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                // Enough to tell a new build from a broken download.
                Text("SHA-256 \(sha256)" + (GameDownload.manifests.map { "\nDepots \($0)" } ?? ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if download.busy {
                if case .downloading = download.state { Button("Stop", role: .cancel) { download.cancel() } }
            } else if steam.accountName == nil {
                Text("Sign in to Steam above to download.").foregroundStyle(.secondary)
            } else {
                Button(downloadTitle) { download.download() }
                if download.state != .none { Button("Delete game files", role: .destructive) { download.delete() } }
            }
        } header: {
            Text(title)
        } footer: {
            Text("Downloads the chosen version of Factorio for macOS from Steam with your account, with Space Age if you own it, and checks it is a supported build. A few GB; keep the app open on Wi-Fi. Changing version downloads only what differs.")
        }
    }

    private var downloadTitle: String {
        switch download.state {
        case .ready(let build) where build.version == version: return "Check the game files"
        case .failed: return "Resume download"
        default: return version == FactorioBuilds.newest ? "Download the newest Factorio" : "Download Factorio \(version)"
        }
    }

    private func describe(_ progress: SteamDownloadProgress) -> String {
        let format = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        switch progress.phase {
        case .preparing: return "Preparing…"
        case .checking: return "Checking files already here: \(format(progress.checkDone)) of \(format(progress.checkTotal))"
        case .finishing: return "Finishing…"
        case .downloading:
            let speed = progress.bytesPerSecond > 0 ? " · \(format(UInt64(progress.bytesPerSecond)))/s" : ""
            return "\(format(progress.doneBytes)) of \(format(progress.totalBytes))\(speed)"
        }
    }
}
