import AVFoundation

// The top bar's player (spec 6.6): plays the selected meeting's audio inside the app. `Player` is the
// model the bar's player view observes; `AudioPlaying` is what makes the sound, `AVAudioPlayer` in the app
// (`SystemAudio`) and a fake in the tests, so no test ever plays anything.

/// What plays one file. `load` throws when the file cannot be played (missing, unreadable, not audio);
/// `position` is in seconds from the start, and `duration` is 0 with nothing loaded. Used on one queue,
/// the player's.
protocol AudioPlaying: AnyObject {
    func load(_ url: URL) throws
    func play()
    func pause()
    func stop()
    var position: Double { get set }
    var duration: Double { get }
}

/// Where the player stands, as the bar shows it.
enum PlayerState: Equatable {
    case idle
    case playing(URL)
    case paused(URL)
    /// Why the last file asked for cannot be played, in the bar's words.
    case failed(String)
}

/// Play, Pause, Stop (back to the start) and the slider, over an `AudioPlaying`. Call it on its tick
/// queue (the main queue in the app). With a tick queue, playing runs one repeating 1 s timer that calls
/// `tick`, and pause, stop, a failure and the end of the file cancel it; with none (the tests) there is no
/// timer and `tick` is called directly. Only a change is published, and only the top bar's player view
/// observes this, so nothing else in the window is redrawn while a meeting plays.
final class Player: ObservableObject {
    @Published private(set) var state: PlayerState = .idle
    /// Seconds from the start, as the last tick, seek or pause found it.
    @Published private(set) var position: Double = 0
    /// The length of the file the player holds, 0 when it holds none.
    private(set) var duration: Double = 0

    /// What makes the sound (read only here, so a test can see an app model built without one plays nothing).
    let audio: AudioPlaying
    private let tickQueue: DispatchQueue?
    private var timer: DispatchSourceTimer?

    init(audio: AudioPlaying, tickQueue: DispatchQueue?) {
        self.audio = audio
        self.tickQueue = tickQueue
    }

    deinit { timer?.cancel() }

    /// The 1 s timer is running.
    var ticking: Bool { timer != nil }

    /// Play or Pause: the file the player holds pauses or carries on; any other file is loaded and
    /// played from the start, or fails, saying so.
    func toggle(_ url: URL) {
        switch state {
        case .playing(let held) where held == url:
            stopTimer()
            audio.pause()
            set(position: within(audio.position))
            set(state: .paused(url))
        case .paused(let held) where held == url:
            audio.play()
            set(state: .playing(url))
            startTimer()
        default:
            begin(url)
        }
    }

    /// Stop: back to the start, holding nothing. Also what a recording, a voice sample and another
    /// meeting being chosen do first.
    func stop() {
        stopTimer()
        audio.stop()
        audio.position = 0
        duration = 0
        set(position: 0)
        set(state: .idle)
    }

    /// The slider: only while the player holds a file, and only within it.
    func seek(to seconds: Double) {
        switch state {
        case .playing, .paused: break
        case .idle, .failed: return
        }
        let to = within(seconds)
        audio.position = to
        set(position: to)
    }

    /// Once a second while playing: the position, or at the end of the file, Stop.
    func tick() {
        guard case .playing = state else { return }
        let now = audio.position
        if duration > 0, now >= duration {
            stop()
            return
        }
        set(position: within(now))
    }

    private func begin(_ url: URL) {
        stopTimer()
        audio.stop()
        do {
            try audio.load(url)
        } catch {
            duration = 0
            set(position: 0)
            set(state: .failed(TopBarPresentation.cannotPlay))
            return
        }
        duration = audio.duration
        audio.position = 0
        set(position: 0)
        audio.play()
        set(state: .playing(url))
        startTimer()
    }

    private func within(_ seconds: Double) -> Double {
        min(max(seconds.isFinite ? seconds : 0, 0), duration)
    }

    private func set(state next: PlayerState) {
        if state != next { state = next }
    }

    private func set(position next: Double) {
        if position != next { position = next }
    }

    private func startTimer() {
        guard let queue = tickQueue, timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// `AudioPlaying` over `AVAudioPlayer`, on the main queue: the app's only player of a meeting's
/// recording. Passed only by AppDelegate, never by a test.
final class SystemAudio: AudioPlaying {
    private var player: AVAudioPlayer?
    /// Asked to play and not paused or stopped since. `AVAudioPlayer` stops by itself at the end of the
    /// file, and then the position is the end, so the player sees the file has finished.
    private var wanted = false

    /// Throws for a file that is missing, unreadable or not audio, or that cannot be readied to play.
    func load(_ url: URL) throws {
        stop()
        let loaded = try AVAudioPlayer(contentsOf: url)
        guard loaded.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
        player = loaded
    }

    func play() {
        wanted = true
        player?.play()
    }

    func pause() {
        wanted = false
        player?.pause()
    }

    /// Stopped, it holds nothing, so the meeting's file is not kept open.
    func stop() {
        wanted = false
        player?.stop()
        player = nil
    }

    var position: Double {
        get {
            guard let player = player else { return 0 }
            return wanted && !player.isPlaying ? player.duration : player.currentTime
        }
        set { player?.currentTime = newValue }
    }

    var duration: Double { player?.duration ?? 0 }
}

/// No player: every file is refused, so it "cannot be played". `AppModel`'s default, so an app model a
/// test builds without a player can never make a sound.
final class NoAudio: AudioPlaying {
    func load(_ url: URL) throws { throw CocoaError(.featureUnsupported) }
    func play() {}
    func pause() {}
    func stop() {}
    var position: Double {
        get { 0 }
        set {}
    }
    var duration: Double { 0 }
}
