import AVFAudio
import CryptoKit
import Foundation

@main
private enum EverydayServicesCheck {
    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4, arguments[0] == "--resources", arguments[2] == "--output" else {
            FileHandle.standardError.write(Data("Usage: EverydayServicesCheck --resources PetSounds --output report.json\n".utf8))
            exit(2)
        }
        let resources = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[3])
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool) {
            checks.append(Check(name: name, passed: passed))
        }

        let login = FakeLoginAdapter()
        let service = LoginItemService(adapter: login, allowsChanges: true)
        check("login init only reads state", service.status == .notRegistered && login.registerCalls == 0 && login.unregisterCalls == 0)
        check("explicit login opt-in reads enabled state", service.setEnabled(true) && service.status == .enabled && login.registerCalls == 1)
        check("enabled registration is idempotent", service.setEnabled(true) && login.registerCalls == 1)
        check("explicit opt-out unregisters and reads back", service.setEnabled(false) && service.status == .notRegistered && login.unregisterCalls == 1)
        login.registerResult = .requiresApproval
        check("approval remains distinct from eligible enabled state", service.setEnabled(true) && service.status == .requiresApproval && service.status.isRegistered)
        let beforeApprovalRegister = login.registerCalls
        _ = service.setEnabled(true)
        check("pending approval never reregisters", login.registerCalls == beforeApprovalRegister)
        service.openSettings()
        check("login settings opens only on explicit action", login.openCalls == 1)
        login.status = .enabled
        service.refresh()
        check("external approval is reflected by refresh", service.status == .enabled)
        login.unregisterError = TestFailure.refused
        check("unregister failure retains authoritative state and error", !service.setEnabled(false) && service.status == .enabled && service.lastError != nil)
        login.unregisterError = nil
        _ = service.setEnabled(false)
        login.registerError = TestFailure.refused
        check("register failure retains disabled readback and error", !service.setEnabled(true) && service.status == .notRegistered && service.lastError != nil)
        login.registerError = nil
        login.registerResult = .notFound
        check("unexpected OS readback is not reported as enabled", !service.setEnabled(true) && service.status == .notFound && service.lastError != nil)
        let blockedAdapter = FakeLoginAdapter()
        let blocked = LoginItemService(adapter: blockedAdapter, allowsChanges: false)
        _ = blocked.setEnabled(true); _ = blocked.setEnabled(false); blocked.openSettings()
        check("review service cannot register unregister or open settings", blockedAdapter.registerCalls == 0 && blockedAdapter.unregisterCalls == 0 && blockedAdapter.openCalls == 0)
        let diagnosticFlags = ["--probe", "--soak", "--sample-review", "--welcome-review", "--desktop-acceptance", "--everyday-services-validation", "--everyday-review", "--settings-review", "--diagnostics"]
        check("all diagnostic modes reject login mutations", diagnosticFlags.allSatisfy { !LoginItemService.permitsChanges(arguments: ["Spriglet", $0], bundleIdentifier: "dev.spriglet.app") })
        check("normal source build is permitted without a location rule", LoginItemService.permitsChanges(arguments: ["/work/.build/Spriglet.app/Contents/MacOS/Spriglet", "--controls"], bundleIdentifier: "dev.spriglet.app"))
        check("nonapplication validation executables cannot register by default", !LoginItemService.permitsChanges(arguments: ["fixture"], bundleIdentifier: nil))

        let clock = FakeClock()
        var players: [FakeSoundPlayer] = []
        var loadedNames: [String] = []
        let sound = PetSoundService(resourceDirectory: resources, playerFactory: { url in
            let player = FakeSoundPlayer()
            players.append(player); loadedNames.append(url.lastPathComponent)
            return player
        }, elapsed: { clock.value })
        check("sound is disabled and creates no player by default", !sound.isEnabled && !sound.play(.greeting) && players.isEmpty)
        sound.setEnabled(true)
        check("enabling sound never starts playback", players.isEmpty && !sound.isPlaying)
        check("explicit cue selects the finite greeting asset", sound.play(.greeting) && sound.isPlaying && loadedNames == ["greeting.wav"])
        clock.value = 101
        check("rapid repeated cues do not overlap or restart", !sound.play(.play) && players.count == 1 && players[0].stopCalls == 0)
        sound.setEnabled(false)
        check("disabling cancels and releases playback", !sound.isPlaying && players[0].stopCalls == 1)
        sound.setEnabled(true)
        check("reenabling does not resume cancelled audio", !sound.isPlaying && players.count == 1)
        clock.value = 103
        _ = sound.play(.play)
        sound.setSuspended(true)
        check("suspension cancels audio and blocks new cues", !sound.isPlaying && !sound.play(.greeting) && players.count == 2 && players[1].stopCalls == 1)
        sound.setSuspended(false)
        check("clearing suspension remains silent", !sound.isPlaying && players.count == 2)
        clock.value = 106
        _ = sound.play(.greeting)
        players[2].finish()
        check("finite completion releases the current player", !sound.isPlaying && players[2].stopCalls == 1)
        clock.value = 109
        _ = sound.play(.greeting)
        let staleCompletion = players[3].onFinished
        sound.stop()
        clock.value = 112
        _ = sound.play(.play)
        staleCompletion?()
        check("stale completion cannot cancel a newer cue", sound.isPlaying && players[4].stopCalls == 0)
        sound.stop()

        let loadFailure = PetSoundService(resourceDirectory: resources, playerFactory: { _ in throw TestFailure.refused })
        loadFailure.setEnabled(true)
        check("asset decode failure is contained", !loadFailure.play(.greeting) && !loadFailure.isPlaying && loadFailure.lastError != nil)
        let refusesPlayback = FakeSoundPlayer(); refusesPlayback.playResult = false
        let playFailure = PetSoundService(resourceDirectory: resources, playerFactory: { _ in refusesPlayback })
        playFailure.setEnabled(true)
        check("playback refusal releases the player and reports an error", !playFailure.play(.greeting) && !playFailure.isPlaying && refusesPlayback.stopCalls == 1 && playFailure.lastError != nil)
        let missing = PetSoundService(resourceDirectory: nil, playerFactory: { _ in fatalError("Missing resources must not create a player") })
        missing.setEnabled(true)
        check("missing bundle resources do not start audio", !missing.play(.greeting) && missing.lastError != nil)
        clock.value = .nan
        check("invalid elapsed time cannot start another cue", !sound.play(.greeting) && players.count == 5)

        var assets: [Asset] = []
        for cue in PetSoundCue.allCases {
            let url = resources.appendingPathComponent(cue.rawValue).appendingPathExtension("wav")
            // Decoding a file is silent: neither prepareToPlay() nor play() is called.
            let decoded = try AVAudioPlayer(contentsOf: url)
            let data = try Data(contentsOf: url)
            let expectedDuration = cue == .greeting ? 0.44 : 0.62
            check("\(cue.rawValue) WAV silently decodes as finite mono audio", !decoded.isPlaying && decoded.numberOfChannels == 1 && abs(decoded.duration - expectedDuration) < 1.0 / 48_000)
            assets.append(Asset(file: url.lastPathComponent, bytes: data.count, duration: decoded.duration,
                                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        let report = Report(recordedAt: .now, checks: checks, assets: assets)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: .atomic)
        let failed = checks.filter { !$0.passed }
        print("\(checks.count - failed.count)/\(checks.count) service checks passed; no OS registration or audio output performed.")
        for check in failed { print("FAILED: \(check.name)") }
        if !failed.isEmpty { exit(1) }
    }
}

private struct Check: Encodable { let name: String; let passed: Bool }
private struct Asset: Encodable { let file: String; let bytes: Int; let duration: Double; let sha256: String }
private struct Report: Encodable {
    let kind = "spriglet-everyday-services-validation"
    let scope = "Service logic uses fake login and playback adapters. WAVs are decoded without prepareToPlay or play. No ServiceManagement registration/unregistration, system settings opening, or audio output is performed. OS acceptance of actual login registration and perceived audio loudness remain separate checks."
    let recordedAt: Date
    let checks: [Check]
    let assets: [Asset]
}
private enum TestFailure: Error { case refused }

@MainActor
private final class FakeLoginAdapter: LoginItemAdapter {
    var status: LoginItemStatus = .notRegistered
    var registerResult: LoginItemStatus = .enabled
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    var registerCalls = 0
    var unregisterCalls = 0
    var openCalls = 0
    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = registerResult
    }
    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
    func openSettings() { openCalls += 1 }
}

@MainActor
private final class FakeSoundPlayer: PetSoundPlaying {
    var isPlaying = false
    var onFinished: (@MainActor () -> Void)?
    var playResult = true
    var stopCalls = 0
    func play() -> Bool { isPlaying = playResult; return playResult }
    func stop() { stopCalls += 1; isPlaying = false }
    func finish() { isPlaying = false; onFinished?() }
}

@MainActor
private final class FakeClock { var value: TimeInterval = 100 }
