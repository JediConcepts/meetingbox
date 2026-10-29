# Stage 2: the meetingbox app. Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn meetingbox into a Mac app in `~/Applications` with a menu bar item, a floating button and a window holding the meeting library and minutes, while the `meetingbox` command and the Shortcuts hotkey keep working and always agree with the app.

**Architecture:** One executable inside `meetingbox.app` has two modes. Launched with `--record` it is the stage 1 recorder, unchanged in behaviour. Launched normally it is the app, which owns recording (it starts the recorder as a child process of itself, so macOS attributes Screen Recording and the Microphone to meetingbox) and a one-at-a-time processing queue that runs the existing `meetingbox process` pipeline. The command becomes a thin client: it sends `meetingbox://` URLs to the app and reads the same state files the app writes, so the two cannot disagree. Logic lives in Foundation-only Swift files that the native test harness compiles; the AppKit and SwiftUI files are thin.

**Tech Stack:** bash 3.2, Swift 6.4 via `swiftc` only (no SwiftPM, no Xcode, no XCTest), AppKit (`NSStatusItem`, `NSPanel`, `NSWindow`), SwiftUI without macros, ScreenCaptureKit and AVFoundation (recorder), `iconutil` and `sips` for the icon.

**Spec:** `docs/superpowers/specs/2026-10-28-meetingbox-app-and-speakers-design.md`, stage 2 of "Delivery order". Stage 1 shipped as v1.3.0 and v1.3.1.

## Global Constraints

- British English in all user-facing text, comments and docs. No em or en dashes in prose.
- Commit messages carry no `Co-Authored-By: Claude`, `Claude-Session:` or "Generated with" lines.
- One bundle, `meetingbox.app`, bundle ID `com.jediconcepts.meetingbox`, installed at `$HOME/Applications/meetingbox.app`, signed with the stage 1 certificate (`sign_app`). It replaces `$SRC_DIR/meetingbox.app`.
- Every file, folder or keychain item setup creates is recorded in `~/.meetingbox/installed` when created and removed only through the guarded helpers. Never `rm -rf` a path built from config. **Meeting folders are never deleted by meetingbox.** Renames are atomic and refuse to overwrite.
- Build with `swiftc` only. SwiftUI macros do not load with these Command Line Tools: **no `@State`, `@StateObject`, `@Observable`, `@Entry`, `#Preview`**. State lives in `final class ... : ObservableObject` with `@Published`, passed to views as `@ObservedObject`. Entry point is `@main enum Main` compiled with `-parse-as-library`.
- Info.plist keeps `LSUIElement` true; the app makes itself a regular Dock app at run time (`NSApp.setActivationPolicy(.regular)`), so recorder-mode launches never show a Dock icon.
- The bash pipeline (`transcribe`, `mb-transcript`, the `fm` fold) stays the engine. The app runs it; it does not reimplement it.
- The script keeps running under `set -euo pipefail` on bash 3.2.
- Defaults: menu bar item on; floating button "while recording"; Dock icon on; window opens from the Dock icon.
- The timer and `meeting.json` `seconds` count recorded time only (pauses excluded).
- Version becomes `2.0.0`.
- Out of scope here (later stages): participants, calendar fill-in, minutes rebuild on edit, diarisation (stages 3 and 4, per the spec), and the "Me" name setting, which only matters once names replace labels (moved to stage 4).

## Review Focus

1. **The app quits or crashes while recording.** The recorder child keeps running. Expected: on the next launch the app finds it (state files plus the recorder's process) and shows the recording with the right timer; Stop works. Test in Task 3.
2. **Command and app at the same time.** `meetingbox start` while the app is recording, or `meetingbox status` while the app is paused. Expected: "already recording" with the same folder; status says paused. Test in Task 5.
3. **Rename edge cases.** A title with `/` or `:`, an empty title, a name that already exists, a meeting that is recording or processing. Expected: unsafe characters replaced, empty refused, existing refused, busy refused; the folder is untouched on any refusal. Test in Task 2.
4. **Old and odd folders in `~/Meetings`.** `2026-10-27_1430` with no `meeting.json`, a v1.2 `*_meeting.m4a`, an unprocessed recording, and a folder that is not a meeting at all. Expected: the first three listed (titled by date, unprocessed shown as such), the last ignored, nothing crashes. Test in Task 2.
5. **Processing fails part way.** `fm` missing, or the transcriber fails. Expected: that meeting is marked failed with the script's last error line, the files stay, and the next meeting in the queue still runs. Test in Task 4.

---

## File structure

| Path | Responsibility |
|---|---|
| `native/recorder/Recorder.swift` | Was `main.swift`: the recorder as `func runRecorder(_ arguments: [String]) async -> Never` |
| `native/recorder/{AudioMixer,MicRecorder,RecordingOutput,SystemAudioRecorder}.swift` | Unchanged |
| `native/app/Main.swift` | `@main enum Main`: `--record` goes to `runRecorder`, otherwise the app |
| `native/app/MeetingFolder.swift` | Folder names: parse, title by date, new names, safe titles, atomic rename (Foundation only) |
| `native/app/MeetingStore.swift` | Scan the meetings folder, `meeting.json` read and write, state inference (Foundation only) |
| `native/app/Session.swift` | Recording state: state files, recorder child, pause, adopt, recorded-time clock (Foundation only) |
| `native/app/ProcessingQueue.swift` | One-at-a-time runner of `meetingbox process`, progress, failure (Foundation only) |
| `native/app/CommandURL.swift` | `meetingbox://` parsing (Foundation only) |
| `native/app/Preferences.swift` | Settings with defaults over `UserDefaults` (Foundation only) |
| `native/app/AppDelegate.swift` | Wires the above to the UI, URL handling, quit guard, Dock policy |
| `native/app/StatusItem.swift` | Menu bar item and its menu |
| `native/app/FloatingPanel.swift` | The floating button |
| `native/app/LibraryWindow.swift` | Library list, search, detail (minutes, transcript), rename, progress |
| `native/app/PreferencesWindow.swift` | Preferences |
| `native/app/icon.png` | 1024 x 1024 source for the `.icns` |
| `native/tests/app/main.swift` | Tests for the Foundation-only app files |
| `meetingbox` | Build into `~/Applications`, thin client commands, progress file, migration, uninstall |
| `tests/test_app_build.sh`, `tests/test_client.sh` | Bash tests for the build and the thin client |
| `README.md` | The app, its controls and what changed |

## Shared contracts

These names and formats are used across tasks. They are fixed here so each task can rely on them.

- **State files** (unchanged from stage 1, now written by the app): `~/.meetingbox/recording.dir` holds the session folder path; `~/.meetingbox/paused` exists while paused. `MB_STATE_DIR` overrides `~/.meetingbox` for both script and app.
- **Recorder command line:** `<APP_BIN> --record -o <dir> -n meeting [-d <mic>]`. `APP_BIN` is `$HOME/Applications/meetingbox.app/Contents/MacOS/meetingbox`. The script finds recorders by the prefix `<APP_BIN> --record -o <dir> -n`.
- **`meeting.json`** in each meeting folder, written only by the app:
  `{"title": String?, "started": ISO 8601 String, "seconds": Int, "state": "recording"|"processing"|"done"|"failed", "stage": String?, "error": String?, "pausedAt": ISO 8601 String?, "pausedSeconds": Int?}`. Unknown keys are kept on rewrite, so stage 4 can add participants.
- **Progress file:** when `MB_PROGRESS_FILE` is set, `meetingbox process` appends one line per stage: `transcribing`, `speakers`, `minutes`, then `done`. The app shows them as "Transcribing", "Finding speakers", "Writing minutes".
- **URLs:** `meetingbox://start`, `stop`, `pause`, `resume`, `toggle`, `show`; `start` and `toggle` accept `?mic=<substring>&dir=<path>` (URL-encoded) from the command's `--mic` and `--dir`.
- **Info.plist additions:** `CFBundleExecutable` `meetingbox`, `CFBundleIconFile` `meetingbox`, `CFBundleURLTypes` with scheme `meetingbox`, `NSHighResolutionCapable` true, `MBScriptPath` set to `$BIN_DIR/meetingbox` at build time.

---

### Task 1: One executable, two modes, built into ~/Applications

**Files:**
- Rename: `native/recorder/main.swift` to `native/recorder/Recorder.swift`
- Create: `native/app/Main.swift`, `native/app/AppDelegate.swift` (stub: a status item titled "meetingbox" and nothing else), `native/app/icon.png`
- Modify: `meetingbox` (`APP_DIR`, `APP_BIN`, `build_app`, `install_recorder`, `recorder_pids`, `launch_recorder`, `test_recording`, `doctor`, `mics`)
- Test: `tests/test_app_build.sh`, existing bash tests updated for the new paths

**Interfaces:**
- Produces: `func runRecorder(_ arguments: [String]) async -> Never` (arguments exclude `--record`); `APP_DIR="$HOME/Applications/meetingbox.app"`, `APP_BIN="$APP_DIR/Contents/MacOS/meetingbox"`; the recorder command line and Info.plist keys from Shared contracts.

- [ ] **Step 1: Write the failing bash tests** in `tests/test_app_build.sh` (stub `swiftc` to record its arguments and create its `-o` file, stub `codesign`, `iconutil`, `sips`):
  - `build_app` compiles `native/recorder/*.swift` and `native/app/*.swift` in one `swiftc` call with `-parse-as-library` and `-framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework AppKit -framework SwiftUI`, output `$APP_BIN`.
  - The Info.plist has `CFBundleExecutable` = `meetingbox`, `LSUIElement` = true, URL scheme `meetingbox`, `MBScriptPath` = `$BIN_DIR/meetingbox`, `CFBundleIconFile` = `meetingbox`, and `Contents/Resources/meetingbox.icns` exists.
  - `recorder_pids DIR` matches a process line `"$APP_BIN --record -o DIR -n meeting"` and does not match `"$APP_BIN -o DIR -n meeting"`.
  - Migration: with `$SRC_DIR/meetingbox.app` on the install record, `install_recorder` removes it through `remove_installed`; when it is not on the record it is left alone with a warning.
  - `test_recording` launches `open -n -g ... "$APP_DIR" --args --record -o "$PERM_DIR" -n permcheck`.
- [ ] **Step 2: Run `bash tests/run.sh`.** Expected: the new checks FAIL.
- [ ] **Step 3: Convert the recorder.** Move the top-level code of `main.swift` into `runRecorder` in `Recorder.swift`, keeping the order: ignore SIGINT, SIGTERM, SIGPIPE, SIGUSR1, SIGUSR2 first. `Main.main()` (synchronous) checks `CommandLine.arguments[1] == "--record"` before anything else; if so it starts `Task { await runRecorder(Array(CommandLine.arguments.dropFirst(2))) }` and calls `dispatchMain()`. Otherwise it runs `NSApplication.shared` with `AppDelegate`.
- [ ] **Step 4: Make the icon.** `icon.png`: a 1024 px rounded square, dark charcoal, with a red recording dot over a white three-bar waveform. `build_app` makes `meetingbox.iconset` with `sips -z` at 16, 32, 128, 256, 512 (and @2x) and runs `iconutil -c icns`.
- [ ] **Step 5: Update the script** to the new paths and command line from Shared contracts. `install_recorder` migrates the old app as tested. `mics` and `doctor` call `"$APP_BIN" --record -l`.
- [ ] **Step 6: Run `bash tests/run.sh`.** Expected: all PASS. Then build for real into a scratch folder (`APP_DIR=$(mktemp -d)/meetingbox.app`, functions sourced, no `setup`) and run `"$APP_BIN" --record -l`. Expected: the microphone list.
- [ ] **Step 7: Commit** `One executable for the app and the recorder, built into ~/Applications`.

### Task 2: Meeting folders and the store

**Files:**
- Create: `native/app/MeetingFolder.swift`, `native/app/MeetingStore.swift`, `native/tests/app/main.swift` (first line `// sources: ../../app/MeetingFolder.swift ../../app/MeetingStore.swift`)

**Interfaces:**
- Produces:
  - `struct MeetingFolder { let url: URL; let date: Date; let title: String? }` with `static func parse(_ url: URL) -> MeetingFolder?` accepting `YYYY-MM-DD_HHMM`, `YYYY-MM-DD_HHMMSS` and `YYYY-MM-DD HHMM Title`, and `var displayTitle: String` (the title, or the date as "28 October 2026, 15:08").
  - `static func newName(for date: Date) -> String` gives `YYYY-MM-DD_HHMM`.
  - `static func safeTitle(_ raw: String) -> String?` trims, replaces `/` and `:` with `-`, drops leading dots, collapses spaces, cuts to 80 characters, and returns nil when nothing is left.
  - `func renamed(to title: String, busy: Bool) throws -> MeetingFolder` renames to `YYYY-MM-DD HHMM <safe title>` with `renamex_np(..., RENAME_EXCL)`; it throws `RenameError.busy`, `.emptyTitle` or `.exists`.
  - `struct MeetingRecord: Codable` matching the `meeting.json` contract; `enum MeetingState: String, Codable { case recording, processing, done, failed, unprocessed }` (`unprocessed` is inferred, never written).
  - `final class MeetingStore { init(root: URL); func scan() -> [Meeting]; func write(_ record: MeetingRecord, to folder: URL) throws }`, where `struct Meeting { let folder: MeetingFolder; let record: MeetingRecord?; let state: MeetingState }`, sorted newest first.

- [ ] **Step 1: Write the failing tests** in `native/tests/app/main.swift`, in temporary folders:
  - `parse` accepts the three name forms, rejects `notes`, `2026-13-40_9999` and `.DS_Store`.
  - `displayTitle` for `2026-10-28_1508` is `28 October 2026, 15:08` (with `Locale(identifier: "en_GB")`).
  - `safeTitle("  Budget/review: Q3  ")` is `Budget-review- Q3`; `safeTitle("   ")` and `safeTitle("...")` are nil; an 81 character title is cut to 80.
  - Renaming `2026-10-28_1508` to "Budget review" gives `2026-10-28 1508 Budget review` with its files inside; renaming again over an existing folder throws `.exists` and both folders are unchanged; `busy: true` throws `.busy` and the folder is unchanged.
  - `scan` of a root holding `2026-10-27_1430` (`transcript.txt`, `notes.md`, no `meeting.json`), `2026-10-27_1500` (only `2026-10-27_1500_meeting.m4a`), `2026-10-28 0900 Standup` (`meeting.json` state `processing`) and a folder `misc`: three meetings, newest first, states `processing`, `unprocessed`, `done`, `misc` absent.
  - `write` then `scan` round-trips a `MeetingRecord`.
- [ ] **Step 2: Run `bash native/tests/run.sh`.** Expected: FAIL (does not compile).
- [ ] **Step 3: Implement** `MeetingFolder.swift` and `MeetingStore.swift`. Infer state with no `meeting.json`: `notes.md` present means `done`, otherwise `unprocessed`. A `meeting.json` that will not decode counts as absent.
- [ ] **Step 4: Run `bash native/tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `Meeting folders: titles, safe atomic renames, and the library scan`.

### Task 3: The recording session

**Files:**
- Create: `native/app/Session.swift`
- Modify: `native/tests/app/main.swift` (add `../../app/Session.swift` to sources)

**Interfaces:**
- Consumes: `MeetingFolder.newName`, `MeetingStore.write`, `MeetingRecord`.
- Produces:
  - `protocol RecorderLauncher { func launch(dir: URL, mic: String?) throws -> Int32; func signal(_ pid: Int32, _ sig: Int32); func isRunning(_ pid: Int32) -> Bool; func findRecorder(dir: URL) -> Int32? }`, with `ChildRecorderLauncher` (real: `Process` running `Bundle.main.executableURL` with the Shared contracts command line, stderr to `<dir>/capture.log`; `findRecorder` reads `ps -axo pid=,command=` for the prefix).
  - `final class Session: ObservableObject` with `@Published private(set) var phase: Phase` (`enum Phase: Equatable { case idle, recording(dir: URL), paused(dir: URL) }`), `func start(root: URL, mic: String?) throws -> URL`, `pause()`, `resume()`, `func stop() -> URL?` (sends SIGINT, waits up to 15 s for exit, clears the state files, returns the folder), `func adopt()`, `func recordedSeconds(at now: Date) -> Int`, and `init(stateDir: URL, launcher: RecorderLauncher, store: MeetingStore, now: @escaping () -> Date)`.

- [ ] **Step 1: Write the failing tests** with a fake launcher (records calls, keeps a set of live PIDs) and an injected clock:
  - `start` creates `root/YYYY-MM-DD_HHMM`, writes `recording.dir` with its path, writes `meeting.json` state `recording`, and `phase` is `.recording`. A second `start` while recording throws and launches nothing.
  - `pause` sends SIGUSR1 and creates `paused`; `resume` sends SIGUSR2 and removes it; a second `pause` sends nothing.
  - Clock: start at t=0, pause at 60, resume at 90, read at 120. `recordedSeconds` is 90.
  - `stop` sends SIGINT, removes `recording.dir` and `paused`, writes `meeting.json` with `seconds` and state `processing`, and returns the folder.
  - **Adopt (Review Focus 1):** with `recording.dir` naming a folder whose recorder the fake reports alive, a new `Session` calls `adopt()` and `phase` is `.recording(dir)` (`.paused` when `paused` exists); with the recorder dead, `adopt()` clears the state files and marks the folder `processing` so it is queued.
  - The recorder dying on its own (fake marks the PID dead) is noticed by a 1 s check and handled as a stop.
- [ ] **Step 2: Run `bash native/tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement `Session.swift`.** Pause time is tracked in memory and in `meeting.json` (`pausedAt`, `pausedSeconds`), so an adopted session keeps its timer.
- [ ] **Step 4: Run `bash native/tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `The app owns the recording session, and adopts one it finds running`.

### Task 4: The processing queue and progress

**Files:**
- Create: `native/app/ProcessingQueue.swift`
- Modify: `meetingbox` (`process`, `transcribe_channels`, `summarise`: write the progress file), `native/tests/app/main.swift`
- Test: `tests/test_pipeline.sh`

**Interfaces:**
- Consumes: `MeetingStore`, `MeetingRecord`, the progress file contract.
- Produces: `protocol PipelineRunner { func run(audio: URL, progress: URL, done: @escaping (Int32, String) -> Void) }` (exit status, last stderr line), the real `ScriptRunner` (runs `MBScriptPath process <audio>` with `MB_PROGRESS_FILE`, `MB_SOUNDS=0` and `PATH` prefixed by `~/.local/bin:/opt/homebrew/bin:/usr/local/bin`), and `final class ProcessingQueue: ObservableObject { @Published private(set) var current: URL?; @Published private(set) var stage: String?; func enqueue(_ folder: URL); var onFinished: ((URL, Bool) -> Void)? }`.

- [ ] **Step 1: Write the failing tests.**
  - Bash: with `MB_PROGRESS_FILE` set, the first `process` run in `test_pipeline.sh` leaves exactly `transcribing`, `speakers`, `minutes`, `done` in that order; without it no file is written.
  - Swift, with a fake runner: at start-up, `ProcessingQueue.resume(store:)` enqueues every meeting whose `meeting.json` says `processing` (left by a crash or quit), oldest first; two folders enqueued run one after the other, never together; `stage` follows the progress file's last line, shown as "Transcribing", "Finding speakers", "Writing minutes"; success writes state `done`; **a failure (Review Focus 5)** writes state `failed` with `error` set to the last stderr line, and the second folder still runs; enqueueing a folder already queued does nothing.
- [ ] **Step 2: Run both suites.** Expected: FAIL.
- [ ] **Step 3: Implement** the progress lines in the script (one helper, `progress <stage>`, a no-op without `MB_PROGRESS_FILE`) and `ProcessingQueue.swift`.
- [ ] **Step 4: Run `bash tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `A processing queue in the app, fed by progress from the pipeline`.

### Task 5: URL commands and the command as a thin client

**Files:**
- Create: `native/app/CommandURL.swift`
- Modify: `native/app/AppDelegate.swift` (handle URLs), `meetingbox` (`start_recording`, `stop_recording`, `pause_recording`, `resume_recording`, toggle in `main`), `native/tests/app/main.swift`
- Test: `tests/test_client.sh`; existing tests of the old start and stop paths are rewritten to the new behaviour, not deleted

**Interfaces:**
- Consumes: `Session`, `ProcessingQueue`, the URL contract.
- Produces: `enum AppCommand: Equatable { case start(mic: String?, dir: String?), stop, pause, resume, toggle(mic: String?, dir: String?), show }` with `static func parse(_ url: URL) -> AppCommand?`; script function `app_send <command> [query]` that runs `open -g "meetingbox://<command><query>"` and then waits up to 20 s for the state files to show the result.

- [ ] **Step 1: Write the failing tests.**
  - Swift: `parse` maps each URL in the contract, decodes `mic` and `dir`, and returns nil for `meetingbox://format-disk` and for other schemes.
  - Bash (stub `open` to write the state files the way the app would, or to do nothing for the timeout case):
    - `meetingbox start` sends `meetingbox://start`, waits for `recording.dir`, and prints the folder; with `--mic "USB"` the URL carries `?mic=USB`.
    - `meetingbox stop` sends `stop`, waits for `recording.dir` to go, and says the minutes will open in the meetingbox window.
    - `pause` and `resume` send their URLs; the "older meetingbox" guard from 1.3.0 still refuses first.
    - **Review Focus 2:** with the state files saying recording, `meetingbox start` prints "already recording in <dir>" and sends nothing; `meetingbox status` while `paused` exists prints "paused -> <dir>".
    - The app never answers: after 20 s the command fails with "meetingbox did not respond. Is it installed? Run: meetingbox setup".
    - `meetingbox process <file>` still runs the pipeline in the terminal, unchanged.
- [ ] **Step 2: Run both suites.** Expected: FAIL.
- [ ] **Step 3: Implement.** The app handles `application(_:open:)`. `stop` enqueues the stopped folder and plays the stop sound; `start` plays the start sound. Sounds move from the script to the app (`NSSound(named: "Tink"/"Pop"/"Glass")`, off when `Preferences.sounds` is false); the script's `chime` stays only for `process` run in a terminal.
- [ ] **Step 4: Run `bash tests/run.sh`.** Expected: PASS.
- [ ] **Step 5: Commit** `The command hands recording to the app over meetingbox:// URLs`.

### Task 6: Preferences, the menu bar item and the floating button

**Files:**
- Create: `native/app/Preferences.swift`, `native/app/StatusItem.swift`, `native/app/FloatingPanel.swift`
- Modify: `native/app/AppDelegate.swift`, `native/tests/app/main.swift`

**Interfaces:**
- Consumes: `Session` (`phase`, `recordedSeconds`), `ProcessingQueue` (`current`, `stage`).
- Produces: `final class Preferences: ObservableObject` over a given `UserDefaults`, with `@Published var showMenuBar: Bool` (default true), `floating: FloatingMode` (`enum FloatingMode: String { case always, whileRecording, never }`, default `.whileRecording`), `showInDock: Bool` (default true), `sounds: Bool` (default true), `meetingsFolder: String` (default `~/Meetings`, overridden by `MB_DIR` when set), `microphone: String?` (default nil, the system default); `func formatTimer(_ seconds: Int) -> String` (`mm:ss` under an hour, `h:mm:ss` from an hour).

- [ ] **Step 1: Write the failing tests** for `Preferences` (defaults on an empty `UserDefaults(suiteName:)`; values persist across instances; `MB_DIR` wins over the stored folder) and `formatTimer` (0 is `00:00`, 59 is `00:59`, 3599 is `59:59`, 3600 is `1:00:00`).
- [ ] **Step 2: Run `bash native/tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Menu bar: idle shows the SF Symbol `record.circle`; recording shows a red dot and the timer; paused shows `pause.circle` and the frozen timer; processing adds a small spinner title "Writing minutes". The menu has Start recording / Pause / Resume / Stop (only the ones that apply), Show recording folder, Open meetingbox, Preferences..., Quit meetingbox.
  - Floating button: a borderless `NSPanel` (`.nonactivatingPanel`, level `.floating`, `canJoinAllSpaces`, movable by background) about 220 x 44 with a red dot, timer, Pause/Resume, Stop and a folder button. Its position is saved. Shown per `floating`.
  - Both refresh once a second from `Session` and `ProcessingQueue`.
- [ ] **Step 4: Run `bash native/tests/run.sh`, then build the app** into a scratch folder with `build_app` and open it. Expected: the menu bar item appears; Start from the menu shows the floating button and the timer counting.
- [ ] **Step 5: Commit** `Menu bar item and floating button, with preferences`.

### Task 7: The window: library, minutes, transcript, rename

**Files:**
- Create: `native/app/LibraryWindow.swift`
- Modify: `native/app/AppDelegate.swift`, `native/app/MeetingStore.swift` (search), `native/tests/app/main.swift`

**Interfaces:**
- Consumes: `MeetingStore.scan`, `MeetingFolder.renamed`, `ProcessingQueue`, `Session.phase`.
- Produces: `func matches(_ meeting: Meeting, query: String) -> Bool` in `MeetingStore.swift` (case and diacritic insensitive over the title and `transcript.txt`); `LibraryModel: ObservableObject` driving the window; `AppDelegate.showMeeting(_ folder: URL)`.

- [ ] **Step 1: Write the failing tests** for `matches`: a title match, a transcript match, no match, and a meeting with no transcript matched by title only; "cafe" matches "Café".
- [ ] **Step 2: Run `bash native/tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement the window** (a `NavigationSplitView` in an `NSWindow`):
  - Sidebar: search field, then meetings newest first, each with date, length (from `meeting.json` `seconds`, or blank) and title, plus a state badge for recording, processing (with the stage), failed and unprocessed.
  - Detail: title with a Rename button (a sheet with a text field; errors from `renamed` shown in words: "That meeting is busy", "A meeting with that name already exists", "Type a title"); a Minutes / Transcript switch showing `notes.md` (rendered with `AttributedString(markdown:)`) or `transcript.txt`, read only; buttons Show in Finder, Play audio (opens `audio.m4a` with the default app), and Process for unprocessed or failed meetings (enqueues it).
  - The meeting being recorded shows the timer with Pause/Resume, Stop and Show in Finder, so every surface has the same controls.
  - Processing meetings show the stage instead of the minutes. When the queue finishes a meeting, the app plays the done sound, brings the window forward and selects that meeting with its minutes showing.
  - The list rescans when the queue finishes, after a rename, and when the window becomes key.
  - The Dock icon (`applicationShouldHandleReopen`) and Open meetingbox open this window.
- [ ] **Step 4: Run `bash native/tests/run.sh`, build, and check by hand** with a scratch meetings folder copied from fixtures: the list shows titles by date, search narrows it, rename changes the folder name on disk, Minutes and Transcript switch.
- [ ] **Step 5: Commit** `The meetingbox window: library, minutes, transcript and rename`.

### Task 8: Preferences window, Dock, quitting safely

**Files:**
- Create: `native/app/PreferencesWindow.swift`
- Modify: `native/app/AppDelegate.swift`

**Interfaces:**
- Consumes: `Preferences`, `Session`, the microphone list from running `Bundle.main.executableURL` with `--record -l`.

- [ ] **Step 1: Implement the Preferences window**: menu bar item on or off; floating button Always / While recording / Never; show in Dock; sounds; microphone (System default plus the listed devices); meetings folder (shown, with a Choose... button using `NSOpenPanel`). Changes apply at once.
- [ ] **Step 2: Dock policy.** `.regular` when `showInDock`, `.accessory` otherwise. With both the Dock icon and the menu bar item off, the menu bar item is forced back on, so the app is never unreachable.
- [ ] **Step 3: Quit guard.** `applicationShouldTerminate` while recording asks "A recording is running. Stop it and keep it, or keep recording in the background?" with Stop and quit / Keep recording and quit / Cancel. Keep recording leaves the recorder running for the next launch to adopt (Task 3).
- [ ] **Step 4: Build and check by hand**: each preference changes the app at once; quitting while recording shows the question; Keep recording, then relaunching, shows the recording with its timer.
- [ ] **Step 5: Commit** `Preferences, Dock icon and a safe quit`.

### Task 9: Setup, uninstall, docs, version

**Files:**
- Modify: `meetingbox` (`setup` survey wording, `uninstall_cmd`, `reset_cmd`, `VERSION`), `README.md`
- Test: `tests/test_app_build.sh`, `tests/test_install_record.sh`

- [ ] **Step 1: Write the failing tests:** `uninstall` asks the app to quit (`osascript -e 'quit app id "com.jediconcepts.meetingbox"'`) and stops any recorder before removing the recorded app; `reset` (state level) leaves `~/Applications/meetingbox.app` in place; `VERSION` is `2.0.0`.
- [ ] **Step 2: Run `bash tests/run.sh`.** Expected: FAIL.
- [ ] **Step 3: Implement**, and at the end of `setup` open the app (`open -g "$APP_DIR"`) so the menu bar item appears.
- [ ] **Step 4: Update `README.md`:** the app, the three controls and their defaults, Preferences, the library and rename, that `stop` now returns at once and the minutes open in the window, the hotkey unchanged, and the move to `~/Applications` (permissions carry over because the signature is the same).
- [ ] **Step 5: Run `bash tests/run.sh`.** Expected: PASS. **Commit** `v2.0.0: the meetingbox app`.
- [ ] **Step 6: End to end with the user** on this Mac (upgrade from 1.3.1): `./install.sh`; no permission prompts expected (same signature, new path, which is the thing to watch); the menu bar item appears; record a short Meet or YouTube test from the hotkey with a pause; the floating button and timer behave; Stop; the window shows progress then the minutes; rename the meeting; check old meetings appear titled by date. Then tag `v2.0.0` and ask before pushing.
