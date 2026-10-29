# Stage 1: own recorder, stable signing, Me/Them transcripts. Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record the microphone and the call audio as separate channels (with pause), sign the app with a stable local certificate so permissions survive rebuilds, and turn the two channels into a transcript labelled "Me" and "Them" that the minutes use. Command line only.

**Architecture:** The audio-capture recorder (danySam, MIT) is vendored into `native/recorder/` and changed to keep two timelines and write `audio.m4a` (mix), `mic.m4a` and `call.m4a`. A new Swift helper, `mb-transcript`, reads each channel's word-timed transcriber JSON, removes echo, and merges the words into labelled turns. The bash script stays the pipeline: it builds both Swift programs in setup, transcribes each channel, calls the helper, and feeds the labelled transcript to the existing `fm` fold.

**Tech Stack:** bash 3.2 (stock macOS), Swift 6.4 via `swiftc` (no SwiftPM, no Xcode, no XCTest), ScreenCaptureKit, AVFoundation, LibreSSL 3.3.6 `/usr/bin/openssl`, `security`, `codesign`, speech-analyzer (`-f json`), whisper-cli (`-oj`).

**Spec:** `docs/superpowers/specs/2026-10-28-meetingbox-app-and-speakers-design.md` (stage 1 of "Delivery order").

## Global Constraints

- British English in all user-facing text, comments and docs. No em or en dashes in prose.
- Commit messages carry no `Co-Authored-By: Claude`, `Claude-Session:` or "Generated with" lines (enforced by a global commit-msg hook).
- Bundle ID stays `com.jediconcepts.meetingbox`; `APP_DIR` stays `$SRC_DIR/meetingbox.app` in this stage (moving to `~/Applications` is stage 2).
- Every file, folder or keychain item setup creates is recorded in `~/.meetingbox/installed` at the moment of creation and removed only through the guarded helpers. Never `rm -rf` a path built from config. Meeting folders are never deleted by meetingbox.
- Recording and transcription work on macOS 14 and up; minutes need macOS 27 (`fm`).
- Build with `swiftc` only. Compile flags for the recorder: `-O -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia`.
- The script must keep running under `set -euo pipefail` on bash 3.2: no `mapfile`, no associative arrays, no empty-array expansion.
- Speaker labels in this stage are exactly `Me` and `Them`. Transcript line format is exactly `[HH:MM:SS] Label: text`.
- Credit and keep danySam's MIT licence with the vendored recorder.
- Version becomes `1.3.0`.

## Review Focus

1. **Speakerphone call (call channel silent).** `call.m4a` holds silence, so its transcript is empty or the transcriber errors. Expected: the meeting still gets a transcript, all "Me", and minutes. Only both channels empty is an error. Test in Task 7.
2. **Video call on laptop speakers (echo).** The far side is picked up by the mic. Expected: those words appear once, as "Them". Test in Task 6.
3. **Old meetings and plain files.** `meetingbox process old/audio.m4a` with no `mic.m4a`/`call.m4a` beside it, or a `.txt`. Expected: the v1.2 single-transcript path, unlabelled. Test in Task 7.
4. **Stop while paused, or pause twice.** Expected: stop finalises all three files with only the recorded time; a second pause is a no-op with a message. Test in Task 5.
5. **Keychain entries in the install record.** `keychain:meetingbox local signing` sits in the same list as paths. Expected: never passed to `rm -rf`; removed only by `security`. Test in Task 1 and Task 3.

---

## File structure

| Path | Responsibility |
|---|---|
| `tests/lib.sh` | Loads the script's functions without running `main`, with a scratch `HOME` and stubs |
| `tests/run.sh` | Sets `MB_TEST_BIN=$(mktemp -d)`, runs `native/tests/run.sh` if it exists, then every `tests/test_*.sh`; exit code is the verdict |
| `tests/test_install_record.sh`, `test_signing.sh`, `test_pause.sh`, `test_pipeline.sh` | Bash tests, one file per task area |
| `tests/fixtures/` | Transcriber JSON samples (speech-analyzer and whisper shapes) |
| `native/recorder/*.swift` | Vendored, modified recorder (`main.swift`, `AudioMixer.swift`, `MicRecorder.swift`, `SystemAudioRecorder.swift`, `RecordingOutput.swift`) |
| `native/recorder/LICENSE` | danySam's MIT licence, unchanged |
| `native/transcript/Transcript.swift` | Word loading, echo removal, merging, rendering (pure logic) |
| `native/transcript/main.swift` | `mb-transcript` command line |
| `native/tests/run.sh` | Compiles and runs the Swift test programs |
| `native/tests/mixer/main.swift` | Mixer tests |
| `native/tests/transcript/main.swift` | Transcript tests |
| `meetingbox` | Pipeline changes (setup, signing, pause, per-channel transcription, minutes) |
| `install.sh` | Passes the local checkout to setup |
| `README.md` | Docs for the new files, commands and signing |

---

### Task 1: Test harness in the repo, and keychain-safe install record

**Files:**
- Create: `tests/lib.sh`, `tests/run.sh`, `tests/test_install_record.sh`
- Modify: `meetingbox:145-152` (`remove_installed`)

**Interfaces:**
- Produces: `tests/lib.sh` sets `HOME` to `$(mktemp -d)`, sources the script with everything from the line `# ---...--- main` onwards removed (`sed '/^# -* main$/,$d'`), sets `LSREGISTER=/usr/bin/true`, and defines stubs `tccutil`, `confirm` (always yes), `codesign`, `security`, `openssl` (each appends its arguments to `$HOME/calls.log` and returns 0), plus `pass NAME` / `fail NAME` that print and count, and `finish` that exits non-zero if any failed. A test file is `#!/bin/bash`, `. "$(dirname "$0")/lib.sh"`, then plain checks, then `finish`.
- Produces: `remove_installed PATH` returns 1 with a warning for any entry not starting with `/`.

- [ ] **Step 1: Write the failing test** in `tests/test_install_record.sh`:
  - `record_install "keychain:meetingbox local signing"; mkdir "$HOME/keychain:meetingbox local signing"`, run from `cd "$HOME"`: `remove_installed "keychain:meetingbox local signing"` returns non-zero and the folder still exists.
  - The v1.2.1 guarantees still hold: a recorded `$HOME/a` is removed and dropped from the record; an unrecorded `$HOME/b` is not removed; `""`, `/` and `$HOME` are refused.
- [ ] **Step 2: Run** `bash tests/run.sh`. Expected: the keychain case FAILS (today the relative entry is deleted in the working directory).
- [ ] **Step 3: Implement.** In `remove_installed`, extend the refusal `case` so anything not matching `/*` is refused.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.
- [ ] **Step 5: Commit** `git add tests meetingbox && git commit -m "Tests in the repo, and remove_installed refuses anything that is not a path"`

### Task 2: Vendor the recorder and build it from the meetingbox source

**Files:**
- Create: `native/recorder/` (copy of `~/.local/share/meetingbox/audio-capture/Sources/*.swift` and `LICENSE` at upstream commit `3ea627f7d8210a393eb57e490c04848a52278ba5`, unmodified in this task)
- Modify: `meetingbox` config block, `install_audio_capture` (rename to `install_recorder`, update callers in `setup`/`need_audio_capture`), `old_recorder`, the "leave alone" list in `reset_cmd`
- Modify: `install.sh`
- Test: `tests/test_install_record.sh`

**Interfaces:**
- Produces: config `SOURCE_DIR="${MB_SOURCE_DIR:-$SRC_DIR/meetingbox}"` and `MEETINGBOX_REPO="https://github.com/JediConcepts/meetingbox"`.
- Produces: `fetch_source` ensures `$SOURCE_DIR/native/recorder/main.swift` exists. If `MB_SOURCE_DIR` is set, it is used as is and never recorded or deleted. Otherwise `$SOURCE_DIR` is a clone of tag `v$VERSION`: cloned with `claim_path` + `git clone -q --depth 1 --branch "v$VERSION"`, or, if already a recorded clone, `git -C … fetch --depth 1 origin tag "v$VERSION"` then `checkout -q "v$VERSION"`.
- Produces: `install_recorder` = `fetch_source`, then `swiftc` into a `mktemp -d` folder, then `build_app <binary>` (unchanged signature).
- Produces: `recorder_ready` is true only when `$APP_BIN` is executable and the app's `CFBundleShortVersionString` (read with PlistBuddy) equals `$VERSION`, so updating meetingbox makes setup rebuild the recorder. Today an update never rebuilds it.
- `install.sh`: when it uses the local copy and `$here/native/recorder` exists, it runs setup with `MB_SOURCE_DIR="$here"` in the environment.

- [ ] **Step 1: Write the failing tests:** with `MB_SOURCE_DIR` pointing at a fake tree containing `native/recorder/main.swift`, `fetch_source` succeeds, makes no clone, and `installed_by_us "$MB_SOURCE_DIR"` is false. Without it and with a stub `git` that creates the folder, `$SRC_DIR/meetingbox` is recorded and `git` was called with `--branch v$VERSION`.
- [ ] **Step 2: Run** `bash tests/run.sh`. Expected: FAIL, `fetch_source` not defined.
- [ ] **Step 3: Copy the sources and implement** `fetch_source`, `install_recorder`, and the `install.sh` change. Add `native/recorder/README.md` (two lines: where it came from, the commit, MIT).
- [ ] **Step 4: Run** `bash tests/run.sh` (PASS), then a real build: `swiftc -O -o "$(mktemp -d)/rec" native/recorder/*.swift -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia` and run the result with `-h`. Expected: compiles, help text prints.
- [ ] **Step 5: Commit** `git commit -m "Vendor the recorder and build it from meetingbox's own source"`

### Task 3: A stable local signing certificate

**Files:**
- Modify: `meetingbox` (`build_app`, `reset_cmd`, `doctor`, new functions after `register_app`)
- Test: `tests/test_signing.sh`

**Interfaces:**
- Produces: `SIGN_NAME="meetingbox local signing"`, `SIGN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"`.
- Produces: `ensure_signing_identity` returns 0 when an identity named `$SIGN_NAME` exists (`security find-certificate -c "$SIGN_NAME" "$SIGN_KEYCHAIN"`). If one exists that setup did not create, it is used and not recorded. Otherwise it creates one and records `keychain:$SIGN_NAME`.
- Produces: `remove_signing_identity` acts only if `installed_by_us "keychain:$SIGN_NAME"`: `security delete-identity -c "$SIGN_NAME" "$SIGN_KEYCHAIN"`, then removes that line from the record (factor the record-rewrite lines out of `remove_installed` into `forget_install ENTRY` and use it in both).
- `build_app` signs with `codesign --force --sign "$SIGN_NAME" --identifier "$APP_ID"`; if `ensure_signing_identity` or that fails, it warns ("could not use the meetingbox signing certificate, so macOS will ask for permissions again after each update") and signs ad hoc as today.
- `reset_cmd tools|all` lists `keychain:$SIGN_NAME` as "the meetingbox signing certificate in your login keychain" and calls `remove_signing_identity`; its existing remove loop skips entries not starting with `/`.

Creation recipe (the part the signature does not determine):

```bash
tmp="$(mktemp -d)"; pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
cat > "$tmp/cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$SIGN_NAME" -passout "pass:$pw" -out "$tmp/id.p12"
security import "$tmp/id.p12" -k "$SIGN_KEYCHAIN" -P "$pw" -T /usr/bin/codesign
rm -rf "$tmp"
```

- [ ] **Step 1: Spike on this Mac (manual, before the tests).** Run the recipe by hand into the login keychain, then `codesign --force --sign "meetingbox local signing" --identifier com.jediconcepts.meetingbox` on a copy of the current app. If codesign refuses the certificate as untrusted, add `security add-trusted-cert -r trustRoot -p codeSign -k "$SIGN_KEYCHAIN" "$tmp/cert.pem"` to the recipe (this is the one password prompt the spec warns of) and note it in the README. Then sign a second build and compare `codesign -d -r- APP 2>&1 | grep designated` across both. Expected: identical designated requirements containing `certificate leaf = H"…"`. Delete the spike identity with `security delete-identity -c "meetingbox local signing"`.
- [ ] **Step 2: Write the failing tests** in `tests/test_signing.sh` (stubs from lib.sh; make the `security find-certificate` stub fail until `security import` has been called):
  - (Task 2 test) `recorder_ready` is false for an app whose Info.plist says `1.2.2`.
  - fresh: `ensure_signing_identity` calls `openssl` and `security import`, records `keychain:meetingbox local signing`, and leaves no temporary folder behind in `$TMPDIR` named by it;
  - existing but not ours: no `import`, nothing recorded;
  - `reset_cmd tools` with it recorded: calls `security delete-identity -c meetingbox local signing`, record line gone, and nothing named `keychain:*` was passed to `rm`;
  - `build_app` with a failing `codesign --sign "$SIGN_NAME"` stub falls back to `--sign -` and warns.
- [ ] **Step 3: Run** `bash tests/run.sh`. Expected: FAIL.
- [ ] **Step 4: Implement**, and add a `doctor` line: `+ signing certificate` or `- signing certificate (permissions will be asked again after updates)`.
- [ ] **Step 5: Run** `bash tests/run.sh`. Expected: PASS.
- [ ] **Step 6: Commit** `git commit -m "Sign the app with a local certificate so permissions survive rebuilds"`

### Task 4: Recorder writes separate channels

**Files:**
- Modify: `native/recorder/AudioMixer.swift`, `native/recorder/RecordingOutput.swift`, `native/recorder/main.swift`
- Create: `native/tests/run.sh`, `native/tests/mixer/main.swift`
- Modify: `tests/run.sh` (call `native/tests/run.sh`)
- Modify: `meetingbox` (`stop_recording`, `test_recording`, `clear_permcheck`, `newest_m4a` no longer used by stop)

**Interfaces:**
- Produces: `AudioMixer(now: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }, emit: @escaping (_ mic: [Float], _ system: [Float]) -> Void)`. Two timelines, one per `AudioSource`; `drain` emits equal-length slices of both. Behaviour per source (resync, lag, clock fallback) is unchanged. `now` replaces every direct host clock read, including `startTime`.
- Produces: `RecordingOutput(directory: URL) throws` creating `audio.m4a`, `mic.m4a`, `call.m4a` (AAC, 48 kHz, mono, 96 kbit/s each). Throws if any of the three exists. `write(mic: [Float], system: [Float])` writes mic, system, and `min(max(mic+system, -1), 1)` to the mix. `close()`. `var secondsWritten: Double { get }` (thread-safe).
- `PipeWriter`, `--pipe-rate` and stdout streaming are deleted (meetingbox sends stdout to `/dev/null`).
- `main.swift`: `-n` is still accepted (meetingbox finds recorders by `-o DIR -n`) but no longer names files; `abort` removes only files this run created; "Saved" prints `secondsWritten` formatted as `m:ss` or `h:mm:ss`.
- Script: `stop_recording` takes `$dir/audio.m4a`; the "no recording was written" check uses it. `test_recording` passes if `$PERM_DIR/audio.m4a` is non-empty. `clear_permcheck` removes exactly `audio.m4a mic.m4a call.m4a log` in `$PERM_DIR`, then `rmdir`.
- `native/tests/run.sh`: for each `native/tests/*/main.swift`, compile it together with the sources it names in a first-line comment `// sources: ../../recorder/AudioMixer.swift` (paths relative to the test file), into a `mktemp -d` binary, run it, fail on non-zero exit.

- [ ] **Step 1: Write the failing tests** in `native/tests/mixer/main.swift`, using a fake clock (`var t = 0.0; now: { CMTime(seconds: t, preferredTimescale: 48000) }`) and a tiny `check(_ cond: Bool, _ name: String)` that sets the exit code:
  - mic 0.1 and system 0.2 for one second each at the same host time: total emitted mic frames == system frames == 48000 after `finish()`; every mic sample is 0.1 and every system sample 0.2;
  - system silent (never appended), mic 1 s: after `finish()` 48000 frames, system all 0;
  - mic arrives 0.25 s after system (same timestamps): output still aligned (sample index of the first non-zero mic frame equals that of system).
- [ ] **Step 2: Run** `bash native/tests/run.sh`. Expected: compile FAIL (old `emit` signature).
- [ ] **Step 3: Implement** mixer, output and `main.swift` changes; then the script changes.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all PASS.
- [ ] **Step 5: Manual check on this Mac.** `MB_SOURCE_DIR="$PWD" meetingbox setup` (builds and signs), play a YouTube clip and talk over it for 20 seconds with `meetingbox start` / `meetingbox stop`. Expected: the folder has `audio.m4a`, `mic.m4a`, `call.m4a`; `afinfo` shows equal durations; `call.m4a` has the clip but not your voice, `mic.m4a` your voice. (Stop runs the old pipeline on `audio.m4a`; that is fine until Task 7.)
- [ ] **Step 6: Commit** `git commit -m "Recorder keeps the mic and the call as separate files beside the mix"`

### Task 5: Pause and resume

**Files:**
- Modify: `native/recorder/AudioMixer.swift`, `native/recorder/main.swift`, `native/tests/mixer/main.swift`
- Modify: `meetingbox` (new `pause_recording`, `resume_recording`; dispatch; `status`; `usage`; state cleanup in `start_recording`, `stop_recording`, `reset_cmd`)
- Test: `tests/test_pause.sh`

**Interfaces:**
- Produces: `AudioMixer.pause()` drains everything buffered (as `finish` does) and then drops appended samples. `AudioMixer.resume()` makes the next samples from each source land straight after the last emitted frame: keep an accumulated `shift` (frames) subtracted in `frame(at:)`, set on resume to `frame(now) - (baseFrame + timeline length)`, and reset both cursors to `nil`. Both are idempotent.
- Recorder: `SIGUSR1` pauses, `SIGUSR2` resumes (ignore with `signal(…, SIG_IGN)` then a `DispatchSource`, as for SIGINT). Logs `Paused` / `Resumed` to stderr.
- Script: `PAUSE_FILE="$STATE_DIR/paused"`. `meetingbox pause` takes the lock, requires `is_recording`, sends `kill -USR1` to `recorder_pids "$dir"`, creates `PAUSE_FILE`, says "paused". Already paused: info "already paused", exit 0. `meetingbox resume` mirrors it with `USR2`. `status` prints `paused -> DIR` when `PAUSE_FILE` exists. `start_recording`, `stop_recording` and `reset_cmd` remove `PAUSE_FILE`. Stopping while paused needs no special case: SIGINT finishes as normal.
- `usage` gains `meetingbox pause | resume`.

- [ ] **Step 1: Write the failing tests.** Mixer: 1 s of audio at t 0 to 1, `pause()` at t=1, append at t=1.5 (dropped), `resume()` at t=3, 1 s at t 3 to 4, `finish()`: exactly 96000 frames per channel, no zero gap at the join (frame 48000 is non-zero). Pause twice and resume twice gives the same result. Bash (`tests/test_pause.sh`, recorder faked by overriding `recorder_pids` to echo a sleeping process's PID and `is_recording` to return 0): `pause` creates the marker and a second `pause` says "already paused"; `status` says paused; `resume` removes it; `start_recording`'s and `stop_recording`'s cleanup removes it.
- [ ] **Step 2: Run** `bash tests/run.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: PASS.
- [ ] **Step 5: Manual check.** Start, talk 10 s, `meetingbox pause`, wait 10 s, `meetingbox resume`, talk 10 s, stop. Expected: all three files about 20 s, and "Saved (0:20)" or close in `capture.log`.
- [ ] **Step 6: Commit** `git commit -m "Pause and resume a recording"`

### Task 6: `mb-transcript`, the Me/Them merge

**Files:**
- Create: `native/transcript/Transcript.swift`, `native/transcript/main.swift`, `native/tests/transcript/main.swift`, `tests/fixtures/sa-mic.json`, `tests/fixtures/sa-call.json`, `tests/fixtures/whisper.json`

**Interfaces:**
- Produces (in `Transcript.swift`):
  - `struct Word: Equatable { let start: Double; let end: Double; let text: String }`
  - `struct Turn: Equatable { let label: String; let start: Double; let text: String }`
  - `func loadWords(_ data: Data) throws -> [Word]`: accepts speech-analyzer JSON (`{"words":[{"start","end","text",…}]}`) and whisper-cli `-oj` JSON (`{"transcription":[{"offsets":{"from","to"}, "text"}]}`, offsets in milliseconds). Empty data, or `{}`, gives `[]`.
  - `func normalised(_ s: String) -> String`: lowercased, letters and digits only.
  - `func removeEcho(mic: [Word], call: [Word], window: Double = 0.6) -> [Word]`: drops a mic word when a call word with the same non-empty `normalised` text starts within `window` seconds of it. Each call word can cancel at most one mic word.
  - `func mergeTurns(_ streams: [(label: String, words: [Word])], gap: Double = 1.5) -> [Turn]`: all words sorted by `start` (stable), grouped into turns; a new turn starts when the label changes or when `start - previous.end > gap`. Text joined with the speech-analyzer rule: no space before `, . ! ? ; : % ) ] }` and closing quotes, none after `( [` and opening quotes.
  - `func render(_ turns: [Turn]) -> String`: one line per turn, `[HH:MM:SS] Label: text\n`, time from `start` rounded down.
- Produces: `native/tests/run.sh` also compiles `native/transcript/*.swift` to `$MB_TEST_BIN/mb-transcript` for the bash tests.
- Produces (CLI): `mb-transcript --mic FILE --call FILE`, printing the rendered transcript to stdout. A missing or empty file counts as no words. Exit 1 with "no speech found on either channel" if both are empty. Labels `Me` for mic, `Them` for call.

- [ ] **Step 1: Write the fixtures** (short, hand-written, five to ten words each; `sa-mic.json` includes two echoed words matching `sa-call.json` within 0.2 s) and the failing tests in `native/tests/transcript/main.swift`:
  - `loadWords` on each fixture gives the expected count and the whisper offsets come out in seconds;
  - `removeEcho` drops exactly the two echoed words, keeps a mic "yes" that is 2 s away from a call "yes", and one call "ok" cancels only one of two mic "ok"s;
  - `mergeTurns` alternates correctly, splits a single speaker's run at a 2 s gap, and joins "Hello" "," "world" as `Hello, world`;
  - `render` of a turn at 3725.9 s gives `[01:02:05] Them: …`;
  - mic words only (empty call): every turn is `Me`.
- [ ] **Step 2: Run** `bash native/tests/run.sh`. Expected: FAIL to compile.
- [ ] **Step 3: Implement** `Transcript.swift` and `main.swift`.
- [ ] **Step 4: Run** `bash native/tests/run.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "mb-transcript: merge the two channels into Me and Them turns"`

### Task 7: The pipeline uses both channels

**Files:**
- Modify: `meetingbox` (`install_recorder` also builds `mb-transcript`; `need_audio_capture`/`recorder_ready`; `transcribe`; `process`; `split_chunks`; `summarise`; the instruction strings; `doctor`; `usage`; the "Output lands in" text)
- Test: `tests/test_pipeline.sh`

**Interfaces:**
- Consumes: `mb-transcript --mic --call` (Task 6), `audio.m4a`/`mic.m4a`/`call.m4a` (Task 4).
- Produces: `TRANSCRIPT_BIN="$SRC_DIR/mb-transcript"`, built by `install_recorder` with `swiftc -O native/transcript/*.swift`, placed with `claim_path`. `recorder_ready` also requires it to be executable.
- Produces: `transcribe_words AUDIO OUT_JSON` writes word-timed JSON: native `speech-analyzer --locale "$LOCALE" -f json "$AUDIO" > OUT_JSON`; whisper as today plus `-oj -ml 1 -sow` writing `OUT_JSON`. A transcriber failure on a channel warns and leaves an empty `OUT_JSON` instead of dying.
- Produces: `process INPUT`. If INPUT is an audio file and `mic.m4a` and `call.m4a` sit beside it: `transcribe_words` each into `mic.words.json` / `call.words.json` in the meeting folder, then `"$TRANSCRIPT_BIN" --mic … --call … > transcript.txt` (die with the helper's message on failure). Otherwise the v1.2 `transcribe` path, unchanged. `.txt/.md/.vtt/.srt` unchanged. `--no-keep-audio` removes `mic.m4a` and `call.m4a` too.
- Produces: `summarise` feeds `fm` a copy without the leading `[HH:MM:SS] ` (`sed -E 's/^\[[0-9:]+\] //'`), made in `$work`.
- `split_chunks` keeps line breaks: write `\n` at the end of each input line instead of joining lines; a chunk ends at the first line end once `w >= n`, or anywhere once `w >= n * 1.5`.
- Instruction text: append to `MAP_INSTRUCTIONS` and `REDUCE_INSTRUCTIONS`: ` Lines may start with the speaker: "Me" is the person who recorded the meeting, "Them" is everyone on the other end of the call. Keep those labels when naming who said or owns something.` Change `FINAL_INSTRUCTIONS` "(one line each, owner first)" to "(one line each, owner first, using Me or Them where no name was said)".

- [ ] **Step 1: Write the failing tests** in `tests/test_pipeline.sh`. Stubs: `speech-analyzer` copies `tests/fixtures/sa-mic.json` or `sa-call.json` depending on whether its audio argument ends in `mic.m4a`; `fm` echoes a fixed answer and `count-tokens` returns 100; `TRANSCRIPT_BIN` is the real helper built by `native/tests/run.sh` into a known path (`$MB_TEST_BIN/mb-transcript`):
  - folder with three m4a files: `transcript.txt` has lines matching `^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] (Me|Them): `, and the echoed words appear once;
  - `speech-analyzer` failing for `call.m4a` only: transcript produced, all `Me`, a warning printed;
  - both failing: dies with "no speech found on either channel";
  - folder with only `audio.m4a`: the old `transcribe` path ran (speech-analyzer called once, without `-f json`);
  - the text `fm` received has no `[00:` timestamps;
  - `split_chunks` on a 3-line file of 10 words per line with n=12 produces chunks that each end at a line end.
- [ ] **Step 2: Run** `bash tests/run.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: PASS.
- [ ] **Step 5: Manual check** with the Task 4 recording folder: `meetingbox process ~/Meetings/<that folder>/audio.m4a`. Expected: labelled `transcript.txt`, minutes that say who said what.
- [ ] **Step 6: Commit** `git commit -m "Transcribe each channel and label the transcript Me and Them"`

### Task 8: Docs, version, release

**Files:**
- Modify: `meetingbox` (`VERSION="1.3.0"`), `README.md`

**Interfaces:** none new.

- [ ] **Step 1: Update README:**
  - "What you get": add `mic.m4a`, `call.m4a`, `mic.words.json`, `call.words.json`, and show a two-line labelled transcript example.
  - Commands: add `meetingbox pause | resume`.
  - Setup table: replace the audio-capture row with "the recorder, built from meetingbox's own source", and add the signing certificate row (what it is, that it lives in the login keychain, that uninstall removes it, and the password prompt if Task 3 Step 1 found trust necessary).
  - Troubleshooting: "Asked for permission again after an update" now reads as a one-off for the move to the certificate.
  - Credits: audio-capture is now vendored in `native/recorder`, licence kept.
- [ ] **Step 2: Run** `bash tests/run.sh` and `grep -nP '[\x{2013}\x{2014}]' README.md meetingbox` (no output expected).
- [ ] **Step 3: End-to-end on this Mac** (with Jamie): `./install.sh` from the checkout. Expect one last round of Screen Recording and Microphone prompts. Then record a 2 minute Meet or Zoom call, pause in the middle, stop, read the minutes. Then force a rebuild without `reset` (set `CFBundleShortVersionString` to `0` in the built app's Info.plist with PlistBuddy, run `meetingbox setup`, which now rebuilds and re-signs it) and confirm a new recording starts with no permission prompt. This is the check that the certificate did its job.
- [ ] **Step 4: Commit and tag** `git commit -m "v1.3.0: separate channels, pause, Me and Them transcripts, stable signing"` then `git tag v1.3.0`. Pushing (`git push && git push --tags`) only when Jamie says so, since a curl install of 1.3.0 fetches the recorder source from that tag.
