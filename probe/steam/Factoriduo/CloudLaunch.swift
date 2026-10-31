// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see ../Madeira/LICENSES/LICENSE-EXCEPTION.md
//
// The app's home screen, before Factorio starts: the game's state, Steam Cloud
// sync, and Play; a setup checklist while there is no game yet; a review of saves
// that changed on both sides; Settings in a sheet. After the game, a closing
// screen that syncs. And an upload when the app leaves the screen. Called from
// probe/UIKitEntry.m through the C functions at the end of this file.

import SwiftUI
import UIKit

@MainActor
final class CloudLaunch: ObservableObject {
    enum Stage: Equatable { case home, review, closed }

    @Published var stage: Stage
    @Published var signingIn = false
    @Published var showingSettings: Bool
    /// The Steam Cloud offer was put aside for this launch.
    @Published var offerDismissed = false
    @Published private(set) var syncing = false
    /// The single app has no game to start yet: the screen stays until one is ready.
    let needsGame: Bool
    /// After the game: the closing sync has finished (or there was none).
    @Published var closingDone = false
    private(set) var finished = false
    let sync = FactorioCloudSync.shared
    private var signInObserver: NSObjectProtocol?

    init(settings: Bool, closed: Bool = false, needsGame: Bool = false) {
        self.needsGame = needsGame
        stage = closed ? .closed : .home
        showingSettings = settings && !closed
        signInObserver = NotificationCenter.default.addObserver(forName: SteamSignIn.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signInChanged() }
        }
    }

    deinit { if let signInObserver { NotificationCenter.default.removeObserver(signInObserver) } }

    var cloudOn: Bool { FactorioCloudSettings.enabled && SteamSignIn.isSignedIn }

    /// Whether to offer Steam Cloud on the home screen.
    var offeringCloud: Bool {
        FactorioCloudSettings.enabled && !SteamSignIn.isSignedIn && !FactorioCloudSettings.declined && !offerDismissed
    }

    func start() {
        if stage == .home, cloudOn { runSync() }
        if stage == .closed { runClosingSync() }
    }

    /// After the game: everything may sync now, downloads included.
    func runClosingSync() {
        sync.gameRunning = false
        guard FactorioCloudSettings.enabled, SteamSignIn.isSignedIn else { closingDone = true; return }
        Task {
            await sync.sync()
            await sync.close()
            closingDone = true
        }
    }

    func runSync() {
        guard !syncing else { return }
        syncing = true
        Task {
            await sync.sync()
            syncing = false
        }
    }

    func choose(_ entries: [SteamCloudEntry], keep side: FactorioCloudSync.Side) {
        Task {
            await sync.resolve(entries, keep: side)
            if sync.conflicts.isEmpty { stage = .home }
        }
    }

    func signIn() { signingIn = true }

    private func signInChanged() {
        SteamSignInModel.shared.refresh()
        sync.reloadRecord()
        if SteamSignIn.isSignedIn {
            FactorioCloudSettings.declined = false
            signingIn = false
            if stage == .home, cloudOn { runSync() }
        }
    }

    func notNow() { offerDismissed = true }

    func neverAsk() {
        FactorioCloudSettings.declined = true
        offerDismissed = true
    }

    /// Closes the app, after showing the home screen: iOS can't restart Factorio
    /// inside the same process (it can't unload a library with Objective-C in it,
    /// and an app can't relaunch itself), so the next tap on the icon starts fresh.
    func closeApp() {
        UIApplication.shared.perform(Selector(("suspend")))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
    }

    func play() {
        finished = true
        Task { await sync.close() }
    }

    // MARK: Running before the game

    private static var window: UIWindow?

    /// Shows the screen over the launch screen and returns once the player can
    /// play. Runs the main run loop meanwhile: the game has not started, and
    /// SDL calls this from a run-loop timer, not from a main-queue block.
    static func runBeforeGame(settings: Bool, needsGame: Bool = false) {
        // A game signed with an earlier certificate is signed again first.
        GamePrepare.resignIfNeeded(gameExecutable: GameDownload.shared.executable)
        show(CloudLaunch(settings: settings, needsGame: needsGame))
    }

    /// After Factorio's main returned: sync, then wait for Close (which exits).
    static func runAfterGame() {
        show(CloudLaunch(settings: false, closed: true))
    }

    private static func show(_ launch: CloudLaunch) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            SteamLog.event("[steam-cloud] no window scene; starting without the Steam Cloud screen")
            return
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: CloudLaunchView(launch: launch))
        window.makeKeyAndVisible()
        Self.window = window
        launch.start()
        while !launch.finished {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        window.isHidden = true
        window.rootViewController = nil
        Self.window = nil
    }
}

// MARK: - The screen

struct CloudLaunchView: View {
    @ObservedObject var launch: CloudLaunch
    @ObservedObject private var sync = FactorioCloudSync.shared
    @ObservedObject private var steam = SteamSignInModel.shared
    @ObservedObject private var prepare = GamePrepare.shared
    /// Read by FPIFullScreen in probe/SDLInputBridge.c when SDL sizes the game view.
    static let fullScreenKey = "factoriduo.display.fullScreen"

    /// A signed game is in place for the launcher (probe/UIKitEntry.m) to load.
    private var gameReady: Bool {
        if case .prepared(let summary) = prepare.state { return summary.installed }
        return GamePrepare.isInstalled
    }

    /// The single app with no game yet: the setup checklist instead of the status.
    private var settingUp: Bool { launch.needsGame && !gameReady }

    var body: some View {
        NavigationStack {
            Form {
                switch launch.stage {
                case .home: settingUp ? AnyView(setup) : AnyView(home)
                case .review: AnyView(review)
                case .closed: AnyView(closed)
                }
            }
            .navigationTitle(launch.stage == .review ? "Saves" : "Factorio")
            .toolbar {
                if launch.stage != .closed {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { launch.showingSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
            }
        }
        .sheet(isPresented: $launch.signingIn) { SteamSignInView() }
        .sheet(isPresented: $launch.showingSettings) {
            SettingsView(launch: launch)
        }
    }

    // MARK: Home

    @ViewBuilder private var home: some View {
        Section {
            LabeledContent {
                Text(launch.needsGame ? "Ready" : "Built in").foregroundStyle(.green)
            } label: {
                Label(gameTitle, systemImage: "gearshape.2.fill")
            }
            LabeledContent {
                Text(cloudStatus).foregroundStyle(cloudColor).multilineTextAlignment(.trailing)
            } label: {
                Label("Steam Cloud", systemImage: "icloud")
            }
        }
        if launch.offeringCloud {
            Section {
                Text("Keep your saves in step with your PC: sign in to Steam, and saves sync before you play and when you leave the app.")
                Button("Sign in to Steam") { launch.signIn() }.fontWeight(.semibold)
                Button("Not now") { launch.notNow() }
                Button("Don't ask again", role: .destructive) { launch.neverAsk() }
            } header: {
                Text("Steam Cloud saves")
            }
        }
        if !sync.conflicts.isEmpty {
            Section {
                Button {
                    launch.stage = .review
                } label: {
                    Label("\(sync.conflicts.count) save\(sync.conflicts.count == 1 ? "" : "s") changed on both your PC and this phone",
                          systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("Choose which copy to keep, or play and decide later.")
            }
        }
        if let error = GamePrepare.loadError {
            Section {
                Label("Factorio \(GamePrepare.installedVersion ?? "") didn't load. Pick another version under Settings > Game files.",
                      systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(error).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        Section {
            playButton
        } footer: {
            if launch.syncing {
                Button("Play without waiting for Steam Cloud") { launch.play() }.font(.footnote)
            }
        }
    }

    private var gameTitle: String {
        if launch.needsGame, let version = GamePrepare.installedVersion { return "Factorio \(version)" }
        return "Factorio"
    }

    private var playButton: some View {
        Button { launch.play() } label: {
            HStack {
                Spacer()
                if launch.syncing { ProgressView().padding(.trailing, 6) }
                Text(launch.syncing ? "Syncing…" : "Play").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(launch.syncing)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var cloudStatus: String {
        guard FactorioCloudSettings.enabled else { return "Off" }
        guard steam.accountName != nil else { return "Not signed in" }
        switch sync.phase {
        case .idle: return launch.syncing ? "Checking…" : "On"
        case .checking: return "Checking…"
        case .downloading(let done, let of): return "Downloading \(done) of \(of)…"
        case .uploading(let done, let of): return "Uploading \(done) of \(of)…"
        case .ready: return sync.problem ?? sync.summary ?? "In sync"
        case .failed(let message): return message
        }
    }

    private var cloudColor: Color {
        if case .failed = sync.phase { return .orange }
        if sync.problem != nil { return .orange }
        if case .ready = sync.phase { return .green }
        return .secondary
    }

    // MARK: Setup

    @ViewBuilder private var setup: some View {
        Section {
            Text("Factorio isn't on this phone yet. Three steps get it here from your Steam account; after that, it's just Play.")
        }
        Section {
            if let name = steam.accountName {
                Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Sign in to Steam") { launch.signIn() }.fontWeight(.semibold)
            }
        } header: {
            Text("1 · Steam account")
        } footer: {
            if steam.accountName == nil { Text("The account that owns Factorio. It also syncs your saves with Steam Cloud.") }
        }
        GameCertificateSection(title: "2 · Signing certificate")
        if steam.accountName != nil {
            GameDownloadSection(title: "3 · Download and prepare Factorio")
        } else {
            Section { Text("Sign in to Steam first.").foregroundStyle(.secondary) } header: { Text("3 · Download and prepare Factorio") }
        }
    }

    // MARK: Closed

    @ViewBuilder private var closed: some View {
        Section {
            if !launch.closingDone {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Syncing saves with Steam Cloud…")
                }
            } else if !FactorioCloudSettings.enabled || !SteamSignIn.isSignedIn {
                Label("Factorio has closed.", systemImage: "checkmark.circle")
            } else if case .failed(let message) = sync.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label(sync.problem ?? sync.summary ?? "Saves are in sync.", systemImage: "checkmark.icloud")
            }
        } footer: {
            if launch.closingDone, !sync.conflicts.isEmpty {
                Text("Saves that changed on both sides are listed next time you open the app.")
            }
        }
        Section {
            Button { launch.closeApp() } label: {
                HStack { Spacer(); Text("Close").font(.title3.weight(.semibold)); Spacer() }.padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!launch.closingDone)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } footer: {
            Text("Factorio can't start again inside the app. Close it, then tap the Factorio icon to play again.")
        }
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        if case .failed(let message) = sync.phase {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Try again") { launch.runSync() }
            }
        }
        if let problem = sync.problem {
            Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
        if let summary = sync.summary, sync.problem == nil {
            Section { Text(summary) }
        }
        if !sync.conflicts.isEmpty {
            Section {
                ForEach(sync.conflicts) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.name).font(.headline)
                        Text(side("Steam Cloud", time: entry.cloudTime, size: entry.cloudSize, present: !entry.cloudSHA.isEmpty))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(side("This phone", time: entry.localTime, size: entry.localSize, present: entry.kind != .cloudOnly))
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("Keep Steam's") { launch.choose([entry], keep: .cloud) }
                            Spacer()
                            Button(entry.kind == .cloudOnly ? "Leave it off this phone" : "Keep this phone's") {
                                launch.choose([entry], keep: .device)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Changed on both sides")
            } footer: {
                Text("Whichever copy you don't keep is saved in Documents › Factorio › steam-cloud-backups.")
            }
        }
        Section {
            Button("Decide later") { launch.stage = .home }
                .disabled(isBusy)
        }
    }

    private var isBusy: Bool {
        switch sync.phase {
        case .checking, .downloading, .uploading: return true
        default: return false
        }
    }

    private func side(_ label: String, time: UInt64, size: UInt64, present: Bool) -> String {
        guard present else { return "\(label): not there" }
        let date = Date(timeIntervalSince1970: TimeInterval(time)).formatted(date: .abbreviated, time: .shortened)
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(label): \(date), \(bytes)"
    }

}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var launch: CloudLaunch
    @ObservedObject private var steam = SteamSignInModel.shared
    @State private var signingIn = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let name = steam.accountName {
                        LabeledContent("Account", value: name)
                        Button("Sign out", role: .destructive) { steam.signOut() }
                    } else {
                        Button("Sign in to Steam") { signingIn = true }
                    }
                    NavigationLink("Steam Cloud saves") { CloudSettingsPage() }
                } header: {
                    Text("Steam")
                }
                if launch.needsGame || GamePrepare.isInstalled {
                    Section {
                        NavigationLink("Game files") { Form { GameDownloadSection() }.navigationTitle("Game files") }
                        NavigationLink("Signing certificate") { Form { GameCertificateSection() }.navigationTitle("Signing") }
                    } header: {
                        Text("Factorio")
                    }
                }
                Section {
                    NavigationLink("Display") { DisplaySettingsPage() }
                    NavigationLink("Diagnostics") { Form { DiagnosticsSection() }.navigationTitle("Diagnostics") }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(isPresented: $signingIn) { SteamSignInView() }
        .onReceive(NotificationCenter.default.publisher(for: SteamSignIn.didChange)) { _ in
            steam.refresh()
            if steam.signedIn { signingIn = false }
        }
    }
}

struct CloudSettingsPage: View {
    @State private var syncOn = FactorioCloudSettings.enabled
    @State private var autosaves = FactorioCloudSettings.includeAutosaves

    var body: some View {
        Form {
            Section {
                Toggle("Sync saves with Steam Cloud", isOn: $syncOn)
                    .onChange(of: syncOn) { _, value in FactorioCloudSettings.enabled = value }
                Toggle("Include autosaves", isOn: $autosaves)
                    .onChange(of: autosaves) { _, value in FactorioCloudSettings.includeAutosaves = value }
            } footer: {
                Text("Saves sync before you play and upload when you leave the app. Autosaves are left out by default: the PC and the phone both write them, so they would need a choice after every session. Factorio must be the same version on both, or a save from the newer one won't load.")
            }
        }
        .navigationTitle("Steam Cloud saves")
    }
}

struct DisplaySettingsPage: View {
    @State private var fullScreen = UserDefaults.standard.bool(forKey: CloudLaunchView.fullScreenKey)

    var body: some View {
        Form {
            Section {
                Toggle("Use the whole screen", isOn: $fullScreen)
                    .onChange(of: fullScreen) { _, value in UserDefaults.standard.set(value, forKey: CloudLaunchView.fullScreenKey) }
            } footer: {
                Text("Drops the border around the game. The screen's rounded corners may then cover the edges of Factorio's panels, such as the minimap and the quickbar.")
            }
        }
        .navigationTitle("Display")
    }
}

// MARK: - Upload when the app leaves the screen

@MainActor
enum CloudBackground {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { upload() }
        }
    }

    /// The background-task identifier, ended once by whichever finishes first:
    /// the upload or iOS's time limit.
    private final class Grant: @unchecked Sendable {
        var id = UIBackgroundTaskIdentifier.invalid
        var work: Task<Void, Never>?
        @MainActor func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    private static func upload() {
        guard FactorioCloudSettings.enabled, SteamSignIn.isSignedIn else { return }
        let grant = Grant()
        grant.id = UIApplication.shared.beginBackgroundTask(withName: "Steam Cloud upload") {
            // Out of time: whatever is left uploads at the next start.
            MainActor.assumeIsolated {
                grant.work?.cancel()
                grant.end()
            }
        }
        grant.work = Task { @MainActor in
            await FactorioCloudSync.shared.uploadChanges()
            await FactorioCloudSync.shared.close()
            grant.end()
        }
    }
}

// MARK: - Called from probe/UIKitEntry.m

/// After Factorio's main returned, on the main thread. Syncs and shows the result
/// until the player closes the app; UIKitEntry.m exits if this ever returns.
@_cdecl("FDSteamCloudAfterGame")
public func FDSteamCloudAfterGame(_ status: Int32) {
    MainActor.assumeIsolated {
        CloudLaunch.runAfterGame()
    }
}

/// Before Factorio starts, on the main thread. `settings`: the player chose the
/// Steam Cloud quick action. Returns when the game may start.
@_cdecl("FDSteamCloudBeforeGame")
public func FDSteamCloudBeforeGame(_ flags: Int32) {
    MainActor.assumeIsolated {
        // Bit 0: opened from the Settings shortcut. Bit 1: the single app has no game yet.
        CloudLaunch.runBeforeGame(settings: flags & 1 != 0, needsGame: flags & 2 != 0)
        FactorioCloudSync.shared.gameRunning = true
        CloudBackground.install()
    }
}

// MARK: - Diagnostics

/// The log probe/UIKitEntry.m keeps of each run (stderr), to share after a crash.
struct DiagnosticsSection: View {
    private static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
    private let previous = caches.appendingPathComponent("factoriduo-previous.log")
    private let current = caches.appendingPathComponent("factoriduo.log")

    var body: some View {
        Section {
            if FileManager.default.fileExists(atPath: previous.path) {
                ShareLink(item: previous) { Label("Share the log of the last run", systemImage: "doc.text") }
            }
            if FileManager.default.fileExists(atPath: current.path) {
                ShareLink(item: current) { Label("Share this run's log", systemImage: "doc.text") }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("After a crash, open the app again and share the log of the last run. Crash reports are in Settings > Privacy & Security > Analytics & Improvements > Analytics Data.")
        }
    }
}
