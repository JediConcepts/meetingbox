# Stage 2: the meetingbox app. Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn meetingbox into a Mac app in `~/Applications` with a menu bar item, a floating button and a window holding the meeting library and minutes, while the `meetingbox` command and the Shortcuts hotkey keep working, always agree with the app, and no recording can be silently lost.

**Architecture:** One executable inside `meetingbox.app` has three modes: `--record` (the stage 1 recorder, now writing crash-safe working files), `--recover DIR` (rebuilds the `.m4a` files from those working files) and the app. The app owns recording (the recorder is its child process) and a durable one-at-a-time processing queue that runs the existing `meetingbox process` pipeline. The command is a client of the app over a private Unix socket and gets a real answer for every request. Recording and processing logic live in Foundation-only Swift files that the native test harness compiles; an `@MainActor` `AppModel` exposes them to thin AppKit and SwiftUI views.

**Tech Stack:** bash 3.2, `/usr/bin/nc -U`, Swift 6.4 via `swiftc` only (no SwiftPM, no Xcode, no XCTest), AppKit, SwiftUI without macros, AVFoundation and ScreenCaptureKit, `afinfo`, `iconutil`, `sips`.

**Spec:** `docs/superpowers/specs/2026-10-28-meetingbox-app-and-speakers-design.md`, stage 2 of "Delivery order". Stage 1 shipped as v1.3.0 and v1.3.1. This revision takes in an architecture review (control protocol, recorder lifecycle, durable recovery).

## Global Constraints

- British English in all user-facing text, comments and docs. No em or en dashes in prose.
- Commit messages carry no `Co-Authored-By: Claude`, `Claude-Session:` or "Generated with" lines.
- One bundle, `meetingbox.app`, bundle ID `com.jediconcepts.meetingbox`, at `$HOME/Applications/meetingbox.app`, signed with the stage 1 certificate (`sign_app`). It replaces `$SRC_DIR/meetingbox.app`.
- Every file, folder or keychain item setup creates is recorded in `~/.meetingbox/installed` when created and removed only through the guarded helpers. Never `rm -rf` a path built from config. **Meeting folders and their audio are never deleted by meetingbox**; the recorder removes only the working files it created itself, and only after the `.m4a` files are verified. Renames are atomic and refuse to overwrite.
- **A recording counts as finished only when its `.m4a` files are verified readable.** Nothing is queued for processing before that.
- Build with `swiftc` only. SwiftUI macros do not load with these Command Line Tools: no `@State`, `@StateObject`, `@Observable`, `@Entry`, `#Preview`. UI state lives in `@MainActor final class ... : ObservableObject` with `@Published`, passed as `@ObservedObject`. Entry point `@main enum Main`, compiled with `-parse-as-library`.
- Files under "Core" in the file table import Foundation (and AVFoundation where stated) only: no Combine, AppKit or SwiftUI. They report changes through closures; callbacks reach UI state only via `AppModel` on the main actor.
- Info.plist keeps `LSUIElement` true; the app makes itself a Dock app at run time, so recorder and recovery launches never show a Dock icon.
- Settings belong to the app (`UserDefaults` suite `com.jediconcepts.meetingbox`). The app never reads `MB_*` variables, because an app opened by macOS does not inherit a Terminal's environment. The command's `--dir` and `--mic` (and `MB_DIR`, `MB_MIC`) travel inside each request. `MB_STATE_DIR` exists for tests only.
- The bash pipeline stays the engine. The script keeps running under `set -euo pipefail` on bash 3.2.
- Defaults: menu bar item on; floating button "while recording"; Dock icon on; open the minutes when ready on (never while a recording is running); sounds on.
- The timer and `seconds` count recorded time only.
- Version becomes `2.0.0`.
- Out of scope (later stages): participants, calendar, minutes rebuild on edit, diarisation, and the "Me" name setting (moved to stage 4, where names replace labels).

## Review Focus

1. **The app is force quit or crashes while recording.** The recorder child keeps running. Expected: the next launch adopts it with the right timer and Stop works. If the recorder died too, the next launch rebuilds the `.m4a` files from the working files and the meeting is queued; if nothing can be rebuilt, the meeting is marked failed and every file is kept. Tests in Tasks 1 and 4; proven on the real Mac at the gate after Task 6.
2. **Stop while the recorder is slow to finish.** Expected: state "finalising" until the recorder exits and the files verify; no processing before that; a recorder that has to be killed is recovered from its working files, not processed half written. Test in Task 4.
3. **The command and the app at once, or the app not running.** Expected: one answer from one owner: "already recording in <dir>", status "paused", a start that fails says why (for example the permission message), and a command that finds no app starts it and retries. Test in Task 6.
4. **Processing interrupted or duplicated.** The app crashes with five meetings queued, or `meetingbox process` is run on a meeting the app is processing. Expected: all five are still queued after relaunch; the second process refuses with "already being processed"; an interrupted job is retried at most three times, then failed. Tests in Task 5.
5. **Old, odd and colliding folders.** `2026-10-27_1430` with no `meeting.json`, a v1.2 `*_meeting.m4a`, a non-meeting folder, two recordings in the same minute, unsafe or duplicate titles. Expected: listed, titled by date, audio playable, non-meetings ignored, new folders never collide, renames refused cleanly. Test in Task 3.

---

## File structure

| Path | Layer | Responsibility |
|---|---|---|
| `native/recorder/Recorder.swift` | Core (AVFoundation) | Was `main.swift`: `runRecorder`, `runRecover` |
| `native/recorder/RecordingOutput.swift` | Core (AVFoundation) | Writes `mic.caf` and `call.caf` while recording; at stop encodes and verifies the three `.m4a`, then removes the `.caf` it created |
| `native/recorder/{AudioMixer,MicRecorder,SystemAudioRecorder}.swift` | Core | Unchanged |
| `native/app/Main.swift` | Entry | `--record`, `--recover`, or the app |
| `native/app/MeetingFolder.swift` | Core | Folder names, titles, unique new names, atomic rename, audio file resolver |
| `native/app/MeetingStore.swift` | Core | Scan, `meeting.json` atomic read-merge-write keeping unknown keys, search index |
| `native/app/Session.swift` | Core | Recording lifecycle: idle, recording, paused, finalising; state files; adopt; health; clock |
| `native/app/ProcessingQueue.swift` | Core | Durable queue over `meeting.json`, one job at a time, retries |
| `native/app/ControlServer.swift` | Core | The socket: line protocol in, one line out |
| `native/app/Preferences.swift` | Core | Settings with defaults over a given `UserDefaults` |
| `native/app/AppModel.swift` | UI | `@MainActor ObservableObject` over the core; the only place UI state changes |
| `native/app/AppDelegate.swift`, `StatusItem.swift`, `FloatingPanel.swift`, `LibraryWindow.swift`, `PreferencesWindow.swift` | UI | Thin views over `AppModel` |
| `native/app/icon.png` | | 1024 px source for the `.icns` |
| `native/tests/app/main.swift`, `native/tests/recorder/main.swift` | Tests | Core tests |
| `meetingbox` | | Build, client commands, processing lock, progress file, recovery, setup guard, uninstall |
| `tests/test_app_build.sh`, `tests/test_client.sh` | Tests | Bash tests |

## Shared contracts

- **Recorder:** `<APP_BIN> --record -o <dir> -n meeting [-d <mic>]`, found by the prefix `<APP_BIN> --record -o <dir> -n`. `APP_BIN` is `$HOME/Applications/meetingbox.app/Contents/MacOS/meetingbox`. While recording it writes `mic.caf` and `call.caf` (16-bit PCM, 48 kHz, mono). On a clean stop it writes `audio.m4a`, `mic.m4a`, `call.m4a`, verifies each opens with a duration within one second of the others, then deletes the two `.caf`. Exit 0 only when that all succeeded.
- **Recovery:** `<APP_BIN> --recover <dir>` builds the three `.m4a` from `mic.caf` and `call.caf` (mixing them as the mixer does), verifies them, removes the `.caf`, exit 0; leaves everything and exits 1 when it cannot.
- **State files** in `~/.meetingbox` (unchanged names): `recording.dir`, `paused`. Written only by the app; read by the command when the app is not running.
- **Socket:** `~/.meetingbox/control.sock`, mode 0600, folder mode 0700. One request line, one reply line, then close.
  - Requests: `status`, `start [mic=<pct-encoded>] [dir=<pct-encoded>]`, `pause`, `resume`, `stop`, `toggle [mic=...] [dir=...]`, `show`.
  - Replies: `ok <state> <folder or ->` where state is `idle`, `recording`, `paused` or `finalising`; or `error <message>`. `stop` replies once the session is `finalising`; the folder is in the reply.
- **`meeting.json`**, written only by the app, atomically (`Data.write(options: .atomic)`), merging into the existing JSON object so unknown keys survive:
  `{"id": UUID String, "title": String?, "started": ISO 8601, "seconds": Int, "pausedAt": ISO 8601?, "pausedSeconds": Int?, "state": "recording"|"finalising"|"queued"|"processing"|"done"|"failed", "stage": String?, "error": String?, "attempts": Int?}`. A folder with no `meeting.json` is given one, with a fresh `id`, the first time the app writes anything for it.
- **Processing lock:** `meetingbox process` creates `<dir>/.processing` with `mkdir` (atomic) holding a `pid` file, removes it on exit (trap), and refuses with "already being processed" when it exists and the PID is alive. A lock whose PID is dead is stale and is replaced.
- **Progress file:** with `MB_PROGRESS_FILE` set, `meetingbox process` appends `transcribing`, `speakers`, `minutes`, `done`. Shown as "Transcribing", "Finding speakers", "Writing minutes".
- **Info.plist:** `CFBundleExecutable` `meetingbox`, `CFBundleIconFile` `meetingbox`, `LSUIElement` true, `NSHighResolutionCapable` true, `MBScriptPath` = `$BIN_DIR/meetingbox`. No URL scheme.

---

### Task 1: A recorder that survives being killed

**Files:**
- Modify: `native/recorder/RecordingOutput.swift`, `native/recorder/main.swift` (stop path)
- Create: `native/tests/recorder/main.swift` (sources: `../../recorder/RecordingOutput.swift ../../recorder/AudioMixer.swift` plus a small recovery file if split out)
- Modify: `meetingbox` (`stop_recording` runs recovery when the recorder had to be killed; `process` refuses a folder that still has `.caf` files and no verified `.m4a`)
- Test: `tests/test_recording_files.sh`

**Interfaces:**
- Produces: `RecordingOutput` writing `.caf` working files and `func finish() throws` (encode, verify, remove working files); `func recover(directory: URL) throws` used by `--recover` in Task 2 (until Task 2, exposed as `audio-capture --recover DIR`).

Why: a spike on this Mac showed an AAC `.m4a` killed mid-write is unreadable, while a 16-bit PCM `.caf` killed the same way keeps every sample written and converts cleanly.

- [ ] **Step 1: Write the failing tests** (synthetic sine audio, no devices, no permissions):
  - Writing 3 s through `RecordingOutput` then `finish()` leaves `audio.m4a`, `mic.m4a`, `call.m4a` (each about 3 s by `AVURLAsset` duration) and no `.caf`.
  - A child test program that writes then is `kill -9`ed leaves `mic.caf` and `call.caf`; `recover` on that folder produces the three `.m4a`, all the same length within one second, and removes the `.caf`.
  - `recover` on a folder with no `.caf` throws and changes nothing; with `.m4a` already present it throws rather than overwrite.
  - Bash: `stop_recording` whose recorder needed `kill -9` (stubbed) runs `--recover` and reports "recovered"; `process` on a folder holding only `.caf` says "this recording was not finished. Run: meetingbox recover <dir>" (a new `recover` command calling the same mode).
- [ ] **Step 2: Run `bash tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement.** Encoding at stop reads the `.caf` files back (the mix through the existing `AudioMixer` mixing rule) and writes the `.m4a` with the stage 1 settings. Disk use while recording is about 0.7 GB an hour; say so in the README.
- [ ] **Step 4: Run `bash tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `Record to crash-safe working files, and recover from them`.

### Task 2: One executable, three modes, built into ~/Applications

**Files:**
- Rename: `native/recorder/main.swift` to `native/recorder/Recorder.swift`
- Create: `native/app/Main.swift`, `native/app/AppDelegate.swift` (stub: a status item titled "meetingbox"), `native/app/icon.png`
- Modify: `meetingbox` (`APP_DIR`, `APP_BIN`, `build_app`, `install_recorder`, `recorder_pids`, `launch_recorder`, `test_recording`, `doctor`, `mics`, `setup`)
- Test: `tests/test_app_build.sh`; existing bash tests updated to the new paths

**Interfaces:**
- Produces: `func runRecorder(_ arguments: [String]) async -> Never`, `func runRecover(_ arguments: [String]) -> Never`; the paths and Info.plist keys from Shared contracts.

- [ ] **Step 1: Write the failing bash tests** (stub `swiftc`, `codesign`, `iconutil`, `sips`):
  - `build_app` compiles `native/recorder/*.swift` and `native/app/*.swift` in one `swiftc` call with `-parse-as-library -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework AppKit -framework SwiftUI`, output `$APP_BIN`; the Info.plist has the Shared contracts keys and no `CFBundleURLTypes`; `Contents/Resources/meetingbox.icns` exists.
  - `recorder_pids DIR` matches `"$APP_BIN --record -o DIR -n meeting"` and not `"$APP_BIN -o DIR -n meeting"`.
  - Migration: an old `$SRC_DIR/meetingbox.app` on the install record is removed through `remove_installed`; one not on the record is left with a warning.
  - **Setup refuses to rebuild while recording** (`is_recording` true): it says "a recording is running. Stop it first: meetingbox stop" and builds nothing.
  - `test_recording` launches `open -n -g ... "$APP_DIR" --args --record -o "$PERM_DIR" -n permcheck`.
- [ ] **Step 2: Run `bash tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement.** `Main.main()` (synchronous) checks the first argument before anything else: `--record` starts `Task { await runRecorder(...) }` then `dispatchMain()`; `--recover` calls `runRecover`; otherwise `NSApplication.shared` with `AppDelegate`. `runRecorder` keeps ignoring SIGINT, SIGTERM, SIGPIPE, SIGUSR1 and SIGUSR2 as its first statements. Icon: a dark charcoal rounded square with a red dot over a white three-bar waveform, turned into `.icns` with `sips -z` (16 to 512, with @2x) and `iconutil -c icns`.
- [ ] **Step 4: Run `bash tests/run.sh`.** Expected: PASS. Then build for real into a scratch `APP_DIR` (functions sourced, no `setup`) and run `"$APP_BIN" --record -l`. Expected: the microphone list.
- [ ] **Step 5: Commit** `One executable for the app, the recorder and recovery, in ~/Applications`.
- [ ] **Step 6: Gate with the user: permissions at the new location.** The user runs `./install.sh`. Expected: no new Screen Recording or Microphone prompt (same signature, new path); `meetingbox start` then `stop` from Terminal works (the command still drives the recorder directly at this point). If macOS asks again, record that in the README's upgrade note and the setup walkthrough handles it; continue only when recording works from `~/Applications`.

### Task 3: Meeting folders and the store

**Files:**
- Create: `native/app/MeetingFolder.swift`, `native/app/MeetingStore.swift`, `native/tests/app/main.swift`

**Interfaces:**
- Produces:
  - `struct MeetingFolder { let url: URL; let date: Date; let title: String? }`: `static func parse(_ url: URL) -> MeetingFolder?` (accepts `YYYY-MM-DD_HHMM`, `YYYY-MM-DD_HHMMSS`, `YYYY-MM-DD HHMM Title`), `var displayTitle: String`, `static func create(in root: URL, at date: Date) throws -> URL` (makes `YYYY-MM-DD_HHMM`, else `_HHMMSS`, else `_HHMMSS-2`, `-3` and so on, created with `mkdir` so two callers can never share one), `static func safeTitle(_ raw: String) -> String?`, `func renamed(to title: String, busy: Bool) throws -> MeetingFolder` (`renamex_np` with `RENAME_EXCL`; throws `RenameError.busy`, `.emptyTitle`, `.exists`), `var audioFile: URL?` (`audio.m4a`, else the newest `*_meeting.m4a`, else nil).
  - `struct MeetingRecord` with the Shared contracts fields, `enum MeetingState: String { case recording, finalising, queued, processing, done, failed, unprocessed }` (`unprocessed` inferred only).
  - `final class MeetingStore { init(root: URL); func scan() -> [Meeting]; func update(_ folder: URL, _ change: (inout MeetingRecord) -> Void) throws; func matches(_ meeting: Meeting, query: String) -> Bool; func indexTranscripts(_ done: @escaping () -> Void) }`, where `struct Meeting { let folder: MeetingFolder; let record: MeetingRecord?; let state: MeetingState }`, newest first. `indexTranscripts` reads every `transcript.txt` once on a background queue into a folded lowercase cache; `matches` reads only that cache.

- [ ] **Step 1: Write the failing tests:**
  - `parse` accepts the three forms and rejects `notes`, `2026-13-40_9999`, `.DS_Store`; `displayTitle` of `2026-10-28_1508` is `28 October 2026, 15:08` (`en_GB`).
  - `create` twice in the same minute gives two different folders; a third gives a third.
  - `safeTitle("  Budget/review: Q3  ")` is `Budget-review- Q3`; blank and `...` are nil; 81 characters cut to 80.
  - Rename to "Budget review" gives `2026-10-28 1508 Budget review` with its files; over an existing name throws `.exists`, `busy: true` throws `.busy`, and both leave every folder as it was.
  - `audioFile` finds `audio.m4a`, falls back to `2026-10-27_1500_meeting.m4a`, and is nil for a folder with neither.
  - `scan` of `2026-10-27_1430` (`notes.md`, no `meeting.json`), `2026-10-27_1500` (only a `*_meeting.m4a`), `2026-10-28 0900 Standup` (`meeting.json` state `queued`), and `misc`: three meetings, newest first, states `queued`, `unprocessed`, `done`; `misc` absent.
  - `update` on a `meeting.json` holding `"participants": ["Priya"]` changes `title` and keeps `participants`; it gives a folder without `meeting.json` an `id`; a `meeting.json` that will not decode is replaced only by `update`, never by `scan`.
  - `matches` after `indexTranscripts`: title match, transcript match, no match, and "cafe" matches "Café".
- [ ] **Step 2: Run `bash native/tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement** both files, Foundation only.
- [ ] **Step 4: Run `bash native/tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `Meeting folders and the library store`.

### Task 4: The recording session

**Files:**
- Create: `native/app/Session.swift`; tests in `native/tests/app/main.swift`

**Interfaces:**
- Consumes: `MeetingFolder.create`, `MeetingStore.update`.
- Produces:
  - `protocol RecorderControl { func launch(dir: URL, mic: String?) throws -> Int32; func signal(_ pid: Int32, _ sig: Int32); func isRunning(_ pid: Int32) -> Bool; func find(dir: URL) -> Int32?; func exitStatus(_ pid: Int32) -> Int32?; func recover(dir: URL) -> Bool; func verify(dir: URL) -> Bool }` and the real `ChildRecorder` (a `Process` of `Bundle.main.executableURL` with the Shared contracts line, stderr to `<dir>/capture.log`; `recover` runs `--recover`; `verify` checks the three `.m4a` open with matching durations).
  - `final class Session` (no Combine): `enum Phase: Equatable { case idle, recording(URL), paused(URL), finalising(URL) }`, `private(set) var phase: Phase`, `var onChange: ((Phase) -> Void)?`, `var onFinished: ((URL, Bool) -> Void)?` (folder, verified), `func start(root: URL, mic: String?) throws -> URL`, `pause()`, `resume()`, `func stop() -> URL?`, `func adopt()`, `func recordedSeconds(at: Date) -> Int`, `var healthy: Bool`, `init(stateDir: URL, recorder: RecorderControl, store: MeetingStore, now: @escaping () -> Date)`.

- [ ] **Step 1: Write the failing tests** with a fake `RecorderControl` and clock:
  - `start` creates the folder, writes `recording.dir`, sets `meeting.json` `recording` with a new `id`; a second `start` throws "already recording" and launches nothing; a launch that throws leaves `idle`, removes `recording.dir`, and the error text reaches the caller.
  - `pause` sends SIGUSR1 and creates `paused`; `resume` sends SIGUSR2 and removes it; repeats are no-ops. Clock: start 0, pause 60, resume 90, read 120 gives 90.
  - **Finalising (Review Focus 2):** `stop` sends SIGINT and moves to `finalising` at once. While the fake recorder is still alive nothing is queued. When it exits 0 and `verify` passes: state files cleared, `meeting.json` `queued` with `seconds`, `onFinished(dir, true)`. If it has not exited after 60 s it gets SIGTERM, then after 10 s SIGKILL, then `recover`; recovered means queued, not recovered means `failed` with "the recording was interrupted; its files are kept" and `onFinished(dir, false)`.
  - **Adopt (Review Focus 1):** with `recording.dir` set and the recorder alive, `adopt` gives `.recording` (or `.paused` with `paused`) and the timer continues from `meeting.json`; with the recorder dead, `adopt` runs `recover` then queues, or marks failed, as above, and never queues unverified audio.
  - `healthy` is false when the fake reports `mic.caf` has not grown for 10 s while recording, true otherwise.
- [ ] **Step 2: Run `bash native/tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement**, Foundation only; a 1 s timer drives the finalising wait, health and a recorder that died on its own (handled as a stop).
- [ ] **Step 4: Run `bash native/tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `The recording session: finalising before processing, and adopting after a crash`.

### Task 5: A durable processing queue

**Files:**
- Create: `native/app/ProcessingQueue.swift`; tests in `native/tests/app/main.swift`
- Modify: `meetingbox` (`process`: lock, progress file), `tests/test_pipeline.sh`

**Interfaces:**
- Consumes: `MeetingStore.update`, `MeetingStore.scan`.
- Produces: `protocol PipelineRunner { func run(audio: URL, progress: URL, done: @escaping (Int32, String) -> Void) -> Int32 }` (returns the worker PID; the closure gets exit status and last stderr line), the real `ScriptRunner` (runs `MBScriptPath process <audio>` with `MB_PROGRESS_FILE`, `MB_SOUNDS=0`, `PATH` prefixed by `~/.local/bin:/opt/homebrew/bin:/usr/local/bin`), and `final class ProcessingQueue` (no Combine): `func enqueue(_ folder: URL)`, `func resume()`, `var current: URL?`, `var stage: String?`, `var onChange: (() -> Void)?`, `var onFinished: ((URL, Bool) -> Void)?`.

- [ ] **Step 1: Write the failing tests.**
  - Bash: `process` takes `<dir>/.processing`; a second `process` on the same folder while the first holder's PID is alive exits non-zero with "already being processed" and runs nothing; a lock with a dead PID is replaced; the lock is gone after success and after failure. With `MB_PROGRESS_FILE`, the stages are written in order; without it, no file.
  - Swift, fake runner:
    - `enqueue` writes `queued` before anything runs; jobs run one at a time, oldest first; a folder already queued or processing is not added twice.
    - **Review Focus 4:** five folders marked `queued` and one `processing` on disk; a new queue's `resume()` runs all six. For the `processing` one: if its `.processing` lock PID is alive, the queue waits for it to go and then reads the result; if dead, it is retried with `attempts` + 1; at `attempts` 3 it becomes `failed` with "processing kept stopping part way".
    - A failure writes `failed` with the last stderr line and the next job still runs; success writes `done`; `stage` follows the progress file.
- [ ] **Step 2: Run both suites.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `bash tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `A processing queue that survives crashes and never doubles up`.

### Task 6: The control socket and the command as its client

**Files:**
- Create: `native/app/ControlServer.swift`, `native/app/Preferences.swift`, `native/app/AppModel.swift`; tests in `native/tests/app/main.swift`
- Modify: `native/app/AppDelegate.swift`, `meetingbox` (`start_recording`, `stop_recording`, `pause_recording`, `resume_recording`, `status_cmd`, toggle)
- Test: `tests/test_client.sh`; existing tests of the old start and stop are rewritten to the new behaviour

**Interfaces:**
- Consumes: `Session`, `ProcessingQueue`, the socket contract.
- Produces:
  - `enum ControlRequest: Equatable { case status, start(mic: String?, dir: String?), pause, resume, stop, toggle(mic: String?, dir: String?), show }` with `static func parse(_ line: String) -> ControlRequest?`; `func reply(for: ControlRequest) -> String` on a `ControlHandler` that wraps `Session`; `ControlServer(socket: URL, handler:)` (creates the folder 0700 and the socket 0600, removes a stale socket file it can bind over, serves one line per connection).
  - `final class Preferences` (Foundation only) over a given `UserDefaults`: `showMenuBar` (true), `floating: FloatingMode` (`always`, `whileRecording`, `never`; default `whileRecording`), `showInDock` (true), `openMinutes` (true), `sounds` (true), `meetingsFolder` (`~/Meetings`), `microphone: String?` (nil); `func formatTimer(_ seconds: Int) -> String`.
  - `@MainActor final class AppModel: ObservableObject`, the one place UI state changes; core callbacks hop to it with `Task { @MainActor in ... }`.
  - Script: `app_request <line>` connects with `nc -U -w 30`; when it cannot connect it runs `open -g "$APP_DIR"` and retries for up to 10 s; prints the reply's message or dies with an `error` reply's text.

- [ ] **Step 1: Write the failing tests.**
  - Swift: `parse` handles every request, decodes `mic` and `dir`, and returns nil for anything else (`rm -rf /`, empty, two lines). `reply` gives `ok recording <dir>` after a start, `error already recording in <dir>` on a second start, `ok finalising <dir>` from stop, and `error <launch message>` when the fake recorder's launch throws. A request's `dir` beats `Preferences.meetingsFolder`. `Preferences` defaults on an empty suite and persists; `formatTimer` 0 is `00:00`, 59 `00:59`, 3599 `59:59`, 3600 `1:00:00`. The server, bound in a temp folder, answers `status` from a real `nc -U` and the socket file is mode 0600.
  - Bash, with `nc` stubbed to answer from a script:
    - `meetingbox start --mic "USB"` sends `start mic=USB` and prints the folder; an `error` reply exits non-zero with its text.
    - `meetingbox stop` sends `stop` and says the minutes will open in the meetingbox window when ready.
    - **Review Focus 3:** with no app answering, the command opens `$APP_DIR`, retries, and after 10 s says "meetingbox did not start. Run: meetingbox setup". `status` with no app running falls back to the state files and the recorder's process, so it still tells the truth after a crash.
    - The 1.3.0 "older meetingbox" pause guard still refuses first; `meetingbox process <file>` runs in the terminal as before.
- [ ] **Step 2: Run both suites.** Expected: FAIL.
- [ ] **Step 3: Implement.** On launch the app adopts (Task 4), resumes the queue (Task 5), then opens the socket. The app plays the start and stop sounds (`NSSound` "Tink", "Pop", "Glass" when done; none when `sounds` is off); the script's `chime` stays only for `process` in a terminal.
- [ ] **Step 4: Run `bash tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `The command talks to the app over a private socket`.
- [ ] **Step 6: Gate with the user: the lifecycle on the real Mac**, before any interface work. Install, then from Terminal: start a recording; force quit meetingbox from Activity Monitor; `meetingbox status` still says recording; reopen meetingbox; `meetingbox stop`; the meeting processes and its audio plays. Then start again, `kill -9` the recorder process itself; reopen; the meeting is recovered and processed. Both must pass before Task 7.

### Task 7: Menu bar item and floating button

**Files:**
- Create: `native/app/StatusItem.swift`, `native/app/FloatingPanel.swift`
- Modify: `native/app/AppModel.swift`, `native/app/AppDelegate.swift`

**Interfaces:**
- Consumes: `AppModel` (phase, recorded seconds, healthy, queue stage), `Preferences`.

- [ ] **Step 1: Implement the menu bar item:** idle `record.circle`; recording a red dot and the timer; paused `pause.circle` and the frozen timer; an amber dot instead of red when `healthy` is false; "Writing minutes" while processing; "Minutes ready" with a link to the meeting when a job finishes. Menu: Start recording, Pause, Resume, Stop (only those that apply), Show recording folder, Open meetingbox, Preferences..., Quit meetingbox. Every action goes through the same `ControlHandler` the socket uses.
- [ ] **Step 2: Implement the floating button:** borderless `NSPanel` (`.nonactivatingPanel`, level `.floating`, all Spaces, movable by background), about 220 x 44: dot, timer, Pause/Resume, Stop, folder. Position saved. Shown per `floating`.
- [ ] **Step 3: Build and check by hand:** Start from the menu shows the button and the timer; Pause freezes it; `meetingbox status` in Terminal agrees at each step; Stop shows "Writing minutes" in the menu bar.
- [ ] **Step 4: Commit** `Menu bar item and floating button`.

### Task 8: The window: library, minutes, transcript, rename

**Files:**
- Create: `native/app/LibraryWindow.swift`
- Modify: `native/app/AppModel.swift`, `native/app/AppDelegate.swift`

**Interfaces:**
- Consumes: `MeetingStore` (`scan`, `matches`, `indexTranscripts`, `update`), `MeetingFolder.renamed`, `audioFile`, `ProcessingQueue`, `Session`.

- [ ] **Step 1: Implement** a `NavigationSplitView` in an `NSWindow`:
  - Sidebar: search field (filtering through `matches`, after `indexTranscripts`), then meetings newest first with date, length and title, and a badge for recording, finalising, queued, processing (with stage), failed and unprocessed.
  - Detail: title with Rename (sheet; errors in words: "That meeting is busy", "A meeting with that name already exists", "Type a title"), writing `title` through `update` as well as renaming the folder; Minutes / Transcript switch (`notes.md` via `AttributedString(markdown:)`, `transcript.txt`), read only; Show in Finder; Play audio (opens `audioFile`); Process for unprocessed or failed meetings.
  - The meeting being recorded shows the timer, Pause/Resume, Stop and Show in Finder.
  - When a job finishes: the done sound, the menu bar "Minutes ready", and, if `openMinutes` is on and nothing is recording, the window comes forward on that meeting's minutes.
  - Rescan after a job, a rename, and when the window becomes key. The Dock icon and Open meetingbox open the window.
- [ ] **Step 2: Build and check by hand** with a copy of real meeting folders in a scratch meetings folder (set in Preferences): titles by date, search narrows, rename changes the folder on disk, Play works for a v1.2 `*_meeting.m4a` folder.
- [ ] **Step 3: Commit** `The meetingbox window: library, minutes, transcript and rename`.

### Task 9: Preferences window, Dock, quitting safely

**Files:**
- Create: `native/app/PreferencesWindow.swift`
- Modify: `native/app/AppModel.swift`, `native/app/AppDelegate.swift`

- [ ] **Step 1: Preferences window:** menu bar item; floating button Always / While recording / Never; show in Dock; open minutes when ready; sounds; microphone (System default plus `--record -l`); meetings folder with Choose... (`NSOpenPanel`). Changes apply at once.
- [ ] **Step 2: Dock policy:** `.regular` when `showInDock`, else `.accessory`; with the Dock icon and the menu bar item both off, the menu bar item is forced back on.
- [ ] **Step 3: Quit guard:** quitting while recording asks "A recording is running." with Stop and quit (waits for finalising), Keep recording and quit (the next launch adopts it), and Cancel.
- [ ] **Step 4: Build and check by hand** each preference and the three quit choices.
- [ ] **Step 5: Commit** `Preferences, Dock icon and a safe quit`.

### Task 10: Setup, uninstall, docs, version, end to end

**Files:**
- Modify: `meetingbox` (`uninstall_cmd`, `reset_cmd`, `setup`, `VERSION`), `README.md`
- Test: `tests/test_app_build.sh`, `tests/test_install_record.sh`

- [ ] **Step 1: Write the failing tests:** `uninstall` refuses while recording, asks the app to quit (`osascript -e 'quit app id "com.jediconcepts.meetingbox"'`), then removes the recorded app and `control.sock`; `reset` at state level leaves the app installed; `VERSION` is `2.0.0`; `setup` ends by opening the app.
- [ ] **Step 2: Run `bash tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement, and update `README.md`:** the app and its three controls with defaults, Preferences, the library and rename, `stop` returning at once, the hotkey unchanged, the move to `~/Applications`, crash safety and the 0.7 GB an hour working files, and `meetingbox recover`.
- [ ] **Step 4: Run `bash tests/run.sh`.** Expected: PASS. **Commit** `v2.0.0: the meetingbox app`.
- [ ] **Step 5: End to end with the user** (upgrade from 1.3.1): a Meet test from the hotkey with a pause; the menu bar and floating button agree with `meetingbox status`; Stop; progress then minutes; rename; old meetings listed and playable; quit while recording with Keep recording, relaunch, stop. Then tag `v2.0.0` and ask before pushing.
