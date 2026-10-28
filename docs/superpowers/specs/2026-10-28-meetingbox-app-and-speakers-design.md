# meetingbox 2.0: a Mac app, speakers and a meeting library

Status: awaiting Jamie's approval. Marked **(my call)** where the decision was made by
Claude rather than Jamie; everything else was asked for directly.

## Intent

meetingbox today is a terminal command: press a hotkey, have the meeting, press it
again, get audio, a transcript and minutes, all on the Mac. Two things are
missing for everyday use:

1. **Who said what.** The transcript is one block of text. Jamie records video
   calls (Meet, Zoom, Teams) and, often, phone calls put on speakerphone next to
   the Mac. The minutes need to say who said and owns what.
2. **Something to see and press.** Start, pause and stop buttons, a running timer,
   where the files are going, the minutes on screen when they are done, and a list
   of past meetings that can be renamed and tagged with who was there.

Everything stays on the Mac. That is the product.

## Goals

### The app

- meetingbox becomes a proper Mac app with a Dock icon and a desktop/Applications
  icon.
- Three ways to control it, each switched on or off in Preferences:
  - a **menu bar item**: red dot and timer while recording, click for controls;
  - a **floating button**: a small draggable pill on top of all windows with
    dot, timer, pause, stop and folder buttons;
  - the **main window**, opened from the Dock.
- Defaults **(my call)**: menu bar on, floating button shown only while
  recording, window opens from the Dock icon.
- While recording, every surface shows: red dot, timer, **Pause/Resume**, **Stop**,
  and the folder being written to with a button to show it in Finder.
- Pause resumes into the same recording. The timer counts recorded time only, and
  transcript times are in recorded time **(my call)**.
- The `meetingbox` command and the Shortcuts hotkey keep working, and the app and
  the command always agree on whether a recording is running. From stage 2 the
  command is a thin client: it starts the app if needed and hands over, and the app
  owns recording and the one-at-a-time processing queue **(my call)**. `meetingbox
  process <file>` still runs in the terminal for scripting.
- meetingbox is a public project, so "Me" is a name setting, defaulting to the
  Contacts "Me" card or the calendar's own account, not hard-coded **(my call)**.

### After Stop

- The window shows progress ("Transcribing", "Finding speakers", "Writing
  minutes"), then the **minutes open in the meetingbox window** with a button to
  show the files in Finder.
- A new recording can start while the previous one is still being processed.
  Processing runs one meeting at a time in the background **(my call)**.

### Speakers

- **Video calls:** your microphone and the call's audio are recorded as separate
  channels, transcribed separately and merged by time into "Me" and "Them".
- **Speakerphone calls:** everyone is on the microphone, so the microphone channel
  is split by voice (diarisation). A one-time voice sample, recorded in setup or
  Preferences, identifies which voice is "Me". Others become "Caller",
  "Caller 2" and so on.
- No call type to choose. The microphone channel is always split by voice and the
  voice sample always picks out "Me", so a video call with a colleague in the room
  works too: the colleague becomes "Room 1", not "Me" **(my call)**. Until stage 3
  ships, the whole microphone channel is "Me".
- The call channel is also split by voice when several people are on the far side,
  giving "Them 1", "Them 2" **(my call)**.
- When it cannot tell who spoke, it says "Unknown" rather than guessing.

### Meeting library

- The window lists past meetings, newest first: date, length, title, participants.
  Clicking one shows its minutes and transcript, with a button to play the audio.
- **Rename:** a meeting gets a real title. The folder on disk is renamed to match
  and keeps the date first so it still sorts: `2026-10-28 1508 Budget review`
  **(my call)**. Renaming is not allowed while that meeting is recording or being
  processed.
- **Participants:** each meeting has a list of who was there. The names are used to:
  - replace speaker labels ("Them", "Caller 2") with names, by picking a name for
    each label in the transcript view;
  - name the owner of each action in the minutes;
  - search past meetings by person.
- Title and participants can be edited during and after a meeting. Changing them
  rebuilds the minutes, without re-transcribing.
- The minutes view is read only. If `notes.md` was edited by hand since meetingbox
  wrote it, a rebuild keeps the edited copy as `notes-edited-<time>.md` rather than
  overwriting it **(my call)**.
- Search covers title, participants and transcript text.

### Calendar

- Jamie's meetings mostly live in Google Calendar, synced into the Mac's Calendar.
  meetingbox reads the Mac's calendar (EventKit), so no Google account or sign-in
  is involved.
- When a recording starts during a calendar event, or up to 5 minutes before one
  **(my call)**, the title and invite list are filled in from that event. The
  user is left off the participant list.
- Ad hoc calls get the date as the title and an empty participant list to fill in.
- For a call with exactly one other participant, "Them" is mapped to that person
  automatically **(my call)**. Otherwise Jamie picks.

## Non-goals

- Anything in the cloud: no accounts, uploads, sync or sharing.
- A browser-based control panel. Jamie listed the browser as one possible place for
  controls; the menu bar and floating button cover the same need without a local
  web server **(my call)**.
- Live transcript while recording.
- Remembering voices across meetings so people are named automatically. A natural
  later step, not this one.
- Video recording, Windows, iOS.

## Anti-goals (failure even if it technically works)

- **Data leaving the Mac.**
- **Asking for permissions again and again.** Screen Recording, Microphone and
  Calendar must stay attached to one stable app identity.
- **Losing recordings.** Deletes stay scoped to what meetingbox created and
  recorded in `~/.meetingbox/installed`; meeting folders are never deleted by
  meetingbox. Renames are atomic and refuse to overwrite.
- **Confidently wrong attribution.** A minute that pins an action on the wrong
  person is worse than one that says "Unknown".
- **Echo counted twice.** On a video call without headphones, the far side leaks
  into the microphone. Those words must not appear a second time as "Me".

## Constraints

- One bundle, `meetingbox.app`, bundle ID `com.jediconcepts.meetingbox`. The UI
  and the recorder live in the same app. Signing (Jamie chose this): setup creates a local
  self-signed code-signing certificate used only for meetingbox, records it in the
  install record, and signs every build with it, so permissions survive rebuilds
  and updates after one final round of approvals. Uninstall removes it. Creating it
  may ask for the Mac password once.
- The app is installed in `~/Applications` so it appears in Launchpad, Spotlight
  and the Dock without needing an admin password **(my call)**. It replaces the
  hidden background app in `~/.local/share/meetingbox/`.
- Built with `swiftc` from setup. SwiftPM is broken on Jamie's Mac and Xcode is not
  assumed, so no Xcode project and no asset catalogue; the icon is an `.icns`
  made with `iconutil`.
- Recording and transcription on macOS 14 and later; minutes need macOS 27 (`fm`).
- The existing bash pipeline (`transcribe`, the folded `fm` summary, `brief.json`)
  stays the engine. The app drives it rather than replacing it.
- Every tool or model setup installs is recorded and removed only through the
  existing install record.
- Existing meeting folders (`~/Meetings/2026-10-27_1430/`) must still show in the
  library, titled by date.
- British English in all user-facing text.

## Decided parts of the how

- **Own the recorder.** audio-capture (danySam, MIT, about 600 lines of Swift) is
  brought into this repo with credit and changed to (a) keep the microphone and
  call audio as separate channels on disk, plus a normal mixed `audio.m4a` for
  listening, and (b) support pause and resume.
- **Timed transcripts.** speech-analyzer already outputs word timings
  (`-f json`: `words[].start`, `end`, `text`, `confidence`); whisper-cli does the
  same with JSON output. Each channel is transcribed on its own and merged into
  speaker turns by time.
- **Echo removal.** Microphone words that overlap in time with matching call-channel
  words are dropped before merging.
- **Diarisation:** sherpa-onnx, running offline with no account or token,
  installed by setup like the other tools.
- **Per-meeting record:** each folder gets a `meeting.json` holding title, start
  time, recorded length, participants, the speaker-to-name map, the calendar event
  it came from, and its state (recording, processing, done, failed).
- **Transcript format:** `transcript.txt` becomes labelled turns,
  `[00:03:12] Priya: ...`, and the word-level data is kept alongside it.
- **Minutes:** the `fm` prompts receive the labelled transcript and the participant
  list, so decisions and actions carry names.

## Delivery order (my call)

Each stage ships on its own and is usable:

1. **Recorder and Me/Them.** Separate channels, pause, timed transcripts, echo
   removal, labelled transcript and minutes. Command line only.
2. **The app.** Window, menu bar, floating button, Preferences, progress, minutes
   view, library, rename.
3. **Speakerphone.** sherpa-onnx diarisation and the voice sample.
4. **People.** Participants, calendar fill-in, mapping labels to names, names in
   the minutes, search by person.

Version 2.0.0 once stage 2 lands.

## Left to the builder

- How the command line and the running app talk to each other (for example a URL
  scheme plus a status file), provided they never disagree about whether a
  recording is running.
- File formats for the separate channels and the word-level data.
- Merge thresholds (gap length that splits a turn, echo overlap tolerance).
- SwiftUI, AppKit or a mix.
- Which sherpa-onnx models, within an on-device, no-token constraint.
- The icon design.
- Where Preferences live on disk.

## Known risks

- Diarisation on speakerphone audio (one microphone, room echo, similar voices)
  will be imperfect. The "Unknown" rule and easy relabelling are the mitigation.
- Moving from the v1.2 ad hoc signature to the new certificate means one more round
  of permission prompts. After that, updates should keep them; this must be
  verified on a real Mac before stage 1 ships.
- Calendar access is another permission prompt. It is asked for only when
  calendar fill-in is first used **(my call)**.
