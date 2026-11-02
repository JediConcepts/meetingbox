import Foundation
import AVFoundation

// The recorder and recovery modes of the meetingbox executable. Main.swift
// chooses between them and the app by the first argument:
//   meetingbox --record [options]   record, see the help below
//   meetingbox --recover <dir>      finish an interrupted recording

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

/// The end of the recording blocks its thread while AVFoundation reads durations (see
/// Finaliser.duration(of:), which waits on a semaphore for a detached task). So
/// it runs on a dispatch thread of its own, never on the Swift concurrency pool
/// that the task it waits for needs.
private func endOffThePool(_ output: RecordingOutput, _ stop: StopRequest, _ directory: URL) async -> Ending {
    await withCheckedContinuation { (done: CheckedContinuation<Ending, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            done.resume(returning: endRecording(output: output, stop: stop, directory: directory))
        }
    }
}

// MARK: - Recovery

/// `meetingbox --recover <dir>`: finishes a recording whose recorder was killed
/// or crashed, from its working files. Exit 0 when the folder ends complete, 75
/// (EX_TEMPFAIL) when another process still holds the folder's lock, 1 with
/// everything left in place when it cannot. Main calls it on the main
/// thread, never on the concurrency pool, so finalising may block there.
func runRecover(_ arguments: [String]) -> Never {
    // As before the recorder became one mode of the app: a stop signal must not
    // cut recovery short, and the files it writes are private.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    signal(SIGUSR1, SIG_IGN)
    signal(SIGUSR2, SIG_IGN)
    umask(0o077)

    guard let path = arguments.first else {
        eprint("Error: --recover requires a folder")
        exit(1)
    }
    let dir = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    let result = recoverStatus(directory: dir)
    eprint(result.message)
    exit(result.status)
}

// MARK: - Recording

/// `meetingbox --record [options]`, given the arguments after `--record`.
func runRecorder(_ arguments: [String]) async -> Never {
    // Ignore these before anything else, so a pause or stop that arrives while
    // the devices are still being set up cannot kill the recorder with its files
    // half made. Dispatch sources further down take them over.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    signal(SIGUSR1, SIG_IGN)
    signal(SIGUSR2, SIG_IGN)

    // Recordings are private: every file the recorder writes is 0600.
    umask(0o077)

    // MARK: Parse arguments

    var outputDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings")
    var deviceQuery: String? = nil

    var args = arguments.makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--output", "-o":
            guard let path = args.next() else {
                eprint("Error: --output requires a path")
                exit(1)
            }
            outputDir = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        case "--name", "-n":
            // Still accepted: meetingbox finds its recorders by "--record -o DIR -n NAME".
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
            meetingbox --record: record system audio and microphone

            Usage: meetingbox --record [options]
                   meetingbox --recover <dir>

            Options:
              -n, --name <label>    Label for the recording (accepted, not used in file names)
              -d, --device <name>   Microphone to use (substring match, see --list-devices)
              -l, --list-devices    List available microphones
              -o, --output <dir>    Output directory (default: ~/Recordings)
              -h, --help            Show this help

            --recover <dir> finishes a recording that was interrupted, from its working files.

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

    // MARK: Resolve mic device

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

    // MARK: Setup

    let output: RecordingOutput
    do {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
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

    // MARK: Signal handling (Ctrl+C / kill)
    // The signals are ignored at the very top of this function; the sources below handle them.

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

    // A stop is one request, whether it came from a signal or from the disk floor below.
    let stop = StopRequest()
    let stopSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { stop.request(.signal) }
        source.resume()
        return source
    }
    stop.onStop { stopSources.forEach { $0.cancel() } }

    // MARK: Start capture

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

    // MARK: Recording

    let startTime = Date()
    eprint("Recording started at \(DateFormatter.localizedString(from: startTime, dateStyle: .none, timeStyle: .short))")
    eprint("  Microphone: \(micDevice.localizedName)")
    eprint("  Folder:     \(outputDir.path)")
    eprint("Press Ctrl+C to stop.")

    let healthTimer = DispatchSource.makeTimerSource(queue: .global())
    healthTimer.schedule(deadline: .now() + 2, repeating: 2)
    healthTimer.setEventHandler { eprint(health.line()) }
    healthTimer.resume()

    // The backstop for a recorder whose app has gone: below 100 MB free, plus what finalising the
    // audio written so far needs, it stops itself as on SIGINT (finalise, verify, marker), after
    // writing "stopped: the disk is nearly full". The app's own floor is 200 MB plus the same need,
    // so with the app running the app stops it first.
    let diskFloor = DiskFloor.watching(outputDir, secondsWritten: { output.secondsWritten }, stop: stop)

    // Nothing uses the pause sources again, and a local may be released after
    // its last use, so keep them alive for the whole recording explicitly.
    await stop.wait()
    withExtendedLifetime(pauseSources) {}

    // MARK: Stop

    eprint("\nStopping...")
    diskFloor.cancel()
    healthTimer.cancel()
    micRecorder.stop()
    try? await systemRecorder.stop()
    mixer.finish()
    switch await endOffThePool(output, stop, outputDir) {
    case .saved:
        break
    case .refused(let line):
        // The disk is too full to encode: nothing was written, and the working files are kept.
        eprint(line)
        exit(1)
    case .failed(let message):
        eprint("Could not finish the recording: \(message)")
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
    exit(0)
}
