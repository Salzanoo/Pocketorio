// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see ../Madeira/LICENSES/LICENSE-EXCEPTION.md
//
// Stages 3 and 4 of the single app (docs/ON_DEVICE.md): after the download,
//   - patch the game (probe/patcher), against this app's own SDL, ProbeShim and
//     SDK;
//   - turn it into a library and sign it with the imported certificate
//     (GameCertificate.swift), into game/Current with a link to its data and
//     launch.plist, which probe/UIKitEntry.m loads before calling its main.

import Foundation
import SwiftUI

@MainActor
final class GamePrepare: ObservableObject {
    static let shared = GamePrepare()

    struct Summary: Codable, Equatable {
        /// The downloaded executable it was made from.
        let sourceSHA256: String
        let version: String
        let sdlRedirects: Int
        let platformPatches: Int
        let notes: [String]
        let mainOffset: Int
        /// Installed for playing (signed), or why not.
        var installed: Bool
        var installProblem: String?
    }

    enum State: Equatable {
        case none
        case preparing(String)
        case prepared(Summary)
        case failed(String)
    }

    @Published private(set) var state: State = .none

    nonisolated static var folder: URL { GameDownload.folder.appendingPathComponent("Prepared", isDirectory: true) }
    nonisolated static var executable: URL { folder.appendingPathComponent("FactorioProbe") }
    nonisolated private static var summaryURL: URL { folder.appendingPathComponent("prepare.json") }
    /// What probe/UIKitEntry.m loads.
    nonisolated static var current: URL { GameDownload.folder.appendingPathComponent("Current", isDirectory: true) }
    nonisolated static var library: URL { current.appendingPathComponent("Factorio.dylib") }
    nonisolated static var launchURL: URL { current.appendingPathComponent("launch.plist") }

    /// The version in game/Current, if any.
    nonisolated static var installedVersion: String? {
        (NSDictionary(contentsOf: launchURL) as? [String: Any])?["Version"] as? String
    }

    /// Why the game library didn't load at the last Play (probe/UIKitEntry.m), until it is prepared again.
    nonisolated static var loadError: String? {
        (try? String(contentsOf: current.appendingPathComponent("load-error.txt"), encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: library.path) && FileManager.default.fileExists(atPath: launchURL.path)
    }

    var busy: Bool { if case .preparing = state { return true }; return false }

    /// What was prepared before, if it was made from `sha256`.
    func refresh(for sha256: String?) {
        guard !busy else { return }
        guard let sha256, let summary = Self.savedSummary(), summary.sourceSHA256 == sha256,
              FileManager.default.fileExists(atPath: Self.executable.path) else { state = .none; return }
        var shown = summary
        shown.installed = Self.isInstalled && Self.signedBy == GameCertificate.info?.fingerprint
        state = .prepared(shown)
    }

    nonisolated private static func savedSummary() -> Summary? {
        (try? Data(contentsOf: summaryURL)).flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
    }

    nonisolated private static var signedBy: String? {
        (NSDictionary(contentsOf: launchURL) as? [String: Any])?["SignedBy"] as? String
    }

    func prepare(_ build: FactorioBuilds.Build, executable: URL) {
        guard !busy else { return }
        state = .preparing("Patching the game…")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Summary, Error> in
                Result {
                    var summary = try Self.patch(build, executable: executable)
                    Task { @MainActor in GamePrepare.shared.state = .preparing("Signing the game…") }
                    do {
                        try Self.install(summary, gameExecutable: executable)
                        summary.installed = true
                    } catch {
                        summary.installProblem = "\(error)"
                    }
                    try JSONEncoder().encode(summary).write(to: Self.summaryURL)
                    return summary
                }
            }.value
            switch result {
            case .success(let summary):
                state = .prepared(summary)
                SteamLog.event("[game-prepare] version=\(summary.version) redirects=\(summary.sdlRedirects) installed=\(summary.installed)")
            case .failure(let error):
                state = .failed("Couldn't prepare the game: \(error)")
                SteamLog.event("[game-prepare] failed \(error)")
            }
        }
    }

    // MARK: Patch

    nonisolated private static func patch(_ build: FactorioBuilds.Build, executable: URL) throws -> Summary {
        guard let frameworks = Bundle.main.privateFrameworksURL, let app = Bundle.main.executableURL else {
            throw MachOError("The app has no Frameworks folder")
        }
        let sdl3 = frameworks.appendingPathComponent("libSDL3.dylib")
        let sdlMajor = FileManager.default.fileExists(atPath: sdl3.path) ? 3 : 2
        let sdl = sdlMajor == 3 ? sdl3 : frameworks.appendingPathComponent("libSDL2.dylib")
        // The SDK this app was built with, from its own LC_BUILD_VERSION.
        let header = try FileHandle(forReadingFrom: app)
        let headBytes = try header.read(upToCount: 1 << 20) ?? Data()
        try? header.close()
        let own = try MachOFile(bytes: [UInt8](headBytes))
        guard let version = own.command(0x32) else { throw MachOError("The app has no LC_BUILD_VERSION") }
        #if targetEnvironment(simulator)
        let platform: UInt32 = 7
        #else
        let platform: UInt32 = 2
        #endif
        let host = GamePatcher.Host(
            sdlExports: try GamePatcher.exports(MachOFile(file: Data(contentsOf: sdl))),
            shimSymbols: try GamePatcher.defined(MachOFile(file: Data(contentsOf: frameworks.appendingPathComponent("ProbeShim.dylib")))),
            sdlMajor: sdlMajor, sdk: own.data.u32(version.offset + 16), platform: platform)

        let (bytes, report) = try autoreleasepool {
            try GamePatcher.patch(MachOFile(file: Data(contentsOf: executable, options: .alwaysMapped)), host: host)
        }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(bytes).write(to: Self.executable)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: folder.appendingPathComponent("patch-report.json"))

        return Summary(sourceSHA256: build.sha256, version: build.version, sdlRedirects: report.sdlRedirects,
                       platformPatches: report.platformPatches.count, notes: report.notes,
                       mainOffset: report.originalEntryOffset, installed: false, installProblem: nil)
    }

    // MARK: Install

    /// The patched game as a signed library in game/Current, with its data and launch.plist.
    nonisolated static func install(_ summary: Summary, gameExecutable: URL) throws {
        let fm = FileManager.default
        // This app's own bundle ID: amfid matches TEAMID.<identifier> against the
        // app's provisioning profile, as for the code LiveContainer signs.
        let signer = try GameCertificate.signer(identifier: Bundle.main.bundleIdentifier ?? "com.factoriduo.factorio")
        guard let fingerprint = GameCertificate.info?.fingerprint else { throw MachOError("No certificate") }
        let signed = try autoreleasepool { () -> [UInt8] in
            let library = try GameLibrary.make([UInt8](try Data(contentsOf: executable)), installName: "Factorio.dylib")
            return try signer.sign(library)
        }
        let staging = GameDownload.folder.appendingPathComponent("Current.new", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(signed).write(to: staging.appendingPathComponent("Factorio.dylib"))
        // factorio.app/Contents/MacOS/factorio -> factorio.app/Contents/data
        let data = gameExecutable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data", isDirectory: true)
        try fm.createSymbolicLink(at: staging.appendingPathComponent("data"), withDestinationURL: data)
        let launch: [String: Any] = ["MainOffset": summary.mainOffset, "Version": summary.version,
                                     "SourceSHA256": summary.sourceSHA256, "SignedBy": fingerprint]
        try PropertyListSerialization.data(fromPropertyList: launch, format: .xml, options: 0)
            .write(to: staging.appendingPathComponent("launch.plist"))
        try? fm.removeItem(at: current)
        try fm.moveItem(at: staging, to: current)
    }

    /// Before the game starts: sign the game again if the certificate changed
    /// since (a new one from SideStore, say). Quick: the patch is kept.
    nonisolated static func resignIfNeeded(gameExecutable: URL?) {
        guard isInstalled, let info = GameCertificate.info, signedBy != info.fingerprint,
              let summary = savedSummary(), let gameExecutable,
              FileManager.default.fileExists(atPath: executable.path) else { return }
        do {
            try install(summary, gameExecutable: gameExecutable)
            SteamLog.event("[game-prepare] signed again with the current certificate")
        } catch {
            SteamLog.event("[game-prepare] signing again failed \(error)")
        }
    }
}

// MARK: - Rows

struct GamePrepareRows: View {
    let build: FactorioBuilds.Build
    let executable: URL
    @ObservedObject private var prepare = GamePrepare.shared

    var body: some View {
        Group {
            switch prepare.state {
            case .none:
                EmptyView()
            case .preparing(let step):
                HStack(spacing: 12) { ProgressView(); Text(step) }
            case .prepared(let summary):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Patched: \(summary.sdlRedirects) SDL redirects, \(summary.platformPatches) iOS fixes", systemImage: "hammer.fill")
                    if !summary.notes.isEmpty {
                        Text(summary.notes.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                    }
                    if summary.installed, let error = GamePrepare.loadError {
                        Label("The game didn't load. A new build of the app is needed for this version, or pick another one.",
                              systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        Text(error).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if summary.installed {
                        Label("Signed and ready to play", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label(summary.installProblem ?? "Import your signing certificate below, then prepare again.",
                              systemImage: "signature").foregroundStyle(.orange)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if !prepare.busy {
                Button(isPrepared ? "Prepare again" : "Prepare the game") { prepare.prepare(build, executable: executable) }
            }
        }
        .onAppear { prepare.refresh(for: build.sha256) }
    }

    private var isPrepared: Bool { if case .prepared = prepare.state { return true }; return false }

}
