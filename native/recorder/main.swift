import Foundation
import AVFoundation

// Ignore these before anything else, so a pause or stop that arrives while the
// devices are still being set up cannot kill the recorder with its files half
// made. Dispatch sources further down take them over.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)

// Recordings are private: every file the recorder or recovery writes is 0600.
umask(0o077)

// MARK: - Helpers

func discoverInputDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    ).devices
}

func findDevice(matching name: String) -> AVCaptureDevice? {
    discoverInputDevices().first { $0.localizedName.localizedCaseInsensitiveContains(name) }
}

// MARK: - Parse arguments

var outputDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Recordings")
var deviceQuery: String? = nil

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--output", "-o":
        guard let path = args.next() else {
            eprint("Error: --output requires a path")
            exit(1)
        }
        outputDir = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    case "--name", "-n":
        // Still accepted: meetingbox finds its recorders by "-o DIR -n NAME".
        // The files are always audio.m4a, mic.m4a and call.m4a.
        guard args.next() != nil else {
            eprint("Error: --name requires a label")
            exit(1)
        }
    case "--device", "-d":
        guard let name = args.next() else {
            eprint("Error: --device requires a device name")
            exit(1)
        }
        deviceQuery = name
    case "--recover":
        // Finishes a recording whose recorder was killed or crashed, from its working files.
        guard let path = args.next() else {
            eprint("Error: --recover requires a folder")
            exit(1)
        }
        let dir = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        do {
            try recover(directory: dir)
            eprint("Recovered \(dir.path)")
            exit(0)
        } catch {
            eprint("Could not recover \(dir.path): \(error.localizedDescription)")
            exit(1)
        }
    case "--list-devices", "-l":
        let devices = discoverInputDevices()
        let defaultDevice = AVCaptureDevice.default(for: .audio)
        if devices.isEmpty {
            print("No audio input devices found.")
        } else {
            for device in devices {
                let marker = device.uniqueID == defaultDevice?.uniqueID ? " (default)" : ""
                print("  \(device.localizedName)\(marker)")
            }
        }
        exit(0)
    case "--help", "-h":
        print("""
        audio-capture: record system audio and microphone

        Usage: audio-capture [options]

        Options:
          -n, --name <label>    Label for the recording (accepted, not used in file names)
          -d, --device <name>   Microphone to use (substring match, see --list-devices)
          -l, --list-devices    List available microphones
          -o, --output <dir>    Output directory (default: ~/Recordings)
              --recover <dir>   Finish a recording that was interrupted, from its working files
          -h, --help            Show this help

        While recording, writes mic.caf and call.caf (16-bit PCM, about 0.7 GB
        an hour together), which survive the recorder being killed. On stop they
        become three aligned files, and are removed once those are verified:
          audio.m4a   the mix of both
          mic.m4a     your microphone only
          call.m4a    system audio only
        Refuses to start if any of them is already in the output directory.

        Status goes to stderr, with a health line every 2 s:
          health mic=<ok|stalled|error> system=<ok|stalled|error>
        Press Ctrl+C to stop recording.
        First run will prompt for Screen Recording and Microphone permissions.
        """)
        exit(0)
    default:
        eprint("Unknown option: \(arg). Use --help for usage.")
        exit(1)
    }
}

// MARK: - Resolve mic device

let micDevice: AVCaptureDevice
if let query = deviceQuery {
    guard let device = findDevice(matching: query) else {
        eprint("No input device matching \"\(query)\".")
        eprint("Available devices:")
        for device in discoverInputDevices() {
            eprint("  \(device.localizedName)")
        }
        exit(1)
    }
    micDevice = device
} else {
    guard let device = AVCaptureDevice.default(for: .audio) else {
        eprint("No audio input device found.")
        exit(1)
    }
    micDevice = device
}

// MARK: - Setup

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let output: RecordingOutput
do {
    output = try RecordingOutput(directory: outputDir)
} catch {
    eprint("Failed to create output files: \(error.localizedDescription)")
    exit(1)
}

let mixer = AudioMixer { mic, system in output.write(mic: mic, system: system) }
let health = HealthMonitor()
let systemExtractor = SampleExtractor()
let micExtractor = SampleExtractor()

func abort(_ message: String) -> Never {
    eprint(message)
    output.close()
    // Capture never started, so there is no recording to keep. Only what this
    // run created: never a file that was there before.
    output.created.forEach { try? FileManager.default.removeItem(at: $0) }
    exit(1)
}

// MARK: - Signal handling (Ctrl+C / kill)
// The signals are ignored at the very top of this file; the sources below handle them.

// SIGUSR1 pauses, SIGUSR2 resumes. The files keep recording; the mixer drops the paused stretch.
let pauseSources = [(SIGUSR1, "Paused"), (SIGUSR2, "Resumed")].map { sig, message -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        if sig == SIGUSR1 { mixer.pause() } else { mixer.resume() }
        eprint(message)
    }
    source.resume()
    return source
}

let stopSignal = AsyncStream<Void> { continuation in
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            continuation.yield()
            continuation.finish()
        }
        source.resume()
        return source
    }
    continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
}

// MARK: - Start capture

eprint("Starting recording...")

let systemRecorder = SystemAudioRecorder(onError: { health.error(from: .system) }) { buffer, hostTime in
    health.buffer(from: .system)
    if let samples = systemExtractor.samples(from: buffer) {
        mixer.append(samples, from: .system, at: hostTime)
    }
}
do {
    try await systemRecorder.start()
} catch {
    abort("""
    Failed to start system audio: \(error.localizedDescription)
    Grant Screen Recording permission in System Settings → Privacy & Security.
    """)
}

let micRecorder = MicRecorder(onError: { health.error(from: .mic) }) { buffer, hostTime in
    health.buffer(from: .mic)
    if let samples = micExtractor.samples(from: buffer) {
        mixer.append(samples, from: .mic, at: hostTime)
    }
}
do {
    try micRecorder.start(device: micDevice)
} catch {
    try? await systemRecorder.stop()
    abort("""
    Failed to start microphone: \(error.localizedDescription)
    Grant Microphone permission in System Settings → Privacy & Security.
    """)
}

// MARK: - Recording

let startTime = Date()
eprint("Recording started at \(DateFormatter.localizedString(from: startTime, dateStyle: .none, timeStyle: .short))")
eprint("  Microphone: \(micDevice.localizedName)")
eprint("  Folder:     \(outputDir.path)")
eprint("Press Ctrl+C to stop.")

let healthTimer = DispatchSource.makeTimerSource(queue: .global())
healthTimer.schedule(deadline: .now() + 2, repeating: 2)
healthTimer.setEventHandler { eprint(health.line()) }
healthTimer.resume()

for await _ in stopSignal { break }

// MARK: - Stop

eprint("\nStopping...")
healthTimer.cancel()
micRecorder.stop()
try? await systemRecorder.stop()
mixer.finish()
do {
    try output.finish()
} catch {
    eprint("Could not finish the recording: \(error.localizedDescription)")
    eprint("Its working files are kept. Run: meetingbox recover \(outputDir.path)")
    exit(1)
}

// What was actually written, not wall-clock time, so a stalled source shows.
let elapsed = Int(output.secondsWritten)
let h = elapsed / 3600
let m = (elapsed % 3600) / 60
let s = elapsed % 60
let duration = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)

eprint("Saved (\(duration))")
for name in RecordingOutput.names {
    eprint("  \(outputDir.appendingPathComponent(name).path)")
}
