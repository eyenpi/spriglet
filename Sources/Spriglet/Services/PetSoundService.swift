import AVFAudio
import Foundation

enum PetSoundCue: String, CaseIterable, Sendable { case greeting, play }

@MainActor
protocol PetSoundPlaying: AnyObject {
    var isPlaying: Bool { get }
    var onFinished: (@MainActor () -> Void)? { get set }
    func play() -> Bool
    func stop()
}

/// Optional finite cues. Disabled by default, with no engine, timer, or input monitor.
@MainActor
final class PetSoundService {
    typealias PlayerFactory = @MainActor (URL) throws -> any PetSoundPlaying
    private let resourceDirectory: URL?
    private let playerFactory: PlayerFactory
    private let elapsed: @MainActor () -> TimeInterval
    private var player: (any PetSoundPlaying)?
    private var generation: UInt64 = 0
    private var lastStartedAt: TimeInterval?
    private(set) var isEnabled = false
    private(set) var isSuspended = false
    private(set) var lastError: String?
    var isPlaying: Bool { player?.isPlaying == true }

    init(
        resourceDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("PetSounds", isDirectory: true),
        playerFactory: @escaping PlayerFactory = { try FiniteAudioPlayer(url: $0) },
        elapsed: (@MainActor () -> TimeInterval)? = nil
    ) {
        self.resourceDirectory = resourceDirectory
        self.playerFactory = playerFactory
        let clock = ContinuousClock()
        let origin = clock.now
        self.elapsed = elapsed ?? {
            let duration = origin.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { stop() }
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended { stop() }
    }

    @discardableResult
    func play(_ cue: PetSoundCue) -> Bool {
        guard isEnabled, !isSuspended else { return false }
        let now = elapsed()
        guard now.isFinite else { return false }
        if let lastStartedAt {
            guard now >= lastStartedAt else { self.lastStartedAt = now; return false }
            guard now - lastStartedAt >= 2 else { return false }
        }
        stop()
        lastError = nil
        guard let resourceDirectory else {
            lastError = "The optional sound files are unavailable."
            return false
        }
        do {
            let player = try playerFactory(resourceDirectory.appendingPathComponent(cue.rawValue).appendingPathExtension("wav"))
            let expectedGeneration = generation
            player.onFinished = { [weak self] in
                guard let self, generation == expectedGeneration else { return }
                stop()
            }
            self.player = player
            guard player.play() else {
                stop()
                lastError = "The optional sound couldn’t play."
                return false
            }
            lastStartedAt = now
            return true
        } catch {
            stop()
            lastError = "The optional sound couldn’t be loaded."
            return false
        }
    }

    func stop() {
        generation &+= 1
        player?.onFinished = nil
        player?.stop()
        player = nil
    }
}

/// AVAudioPlayer handles the finite file's device work and completion callback.
@MainActor
private final class FiniteAudioPlayer: NSObject, PetSoundPlaying, AVAudioPlayerDelegate {
    private let audio: AVAudioPlayer
    var onFinished: (@MainActor () -> Void)?
    var isPlaying: Bool { audio.isPlaying }

    init(url: URL) throws {
        audio = try AVAudioPlayer(contentsOf: url)
        super.init()
        audio.numberOfLoops = 0
        audio.volume = 0.20
        audio.isMeteringEnabled = false
        audio.delegate = self
    }

    func play() -> Bool { audio.play() }
    func stop() { audio.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinished?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.onFinished?() }
    }
}
