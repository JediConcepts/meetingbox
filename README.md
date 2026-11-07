# meetingbox

One key. Press it, have the meeting, press it again. You get the recording, a
transcript and a set of minutes. None of it leaves the Mac.

No account. No API key. No upload. No per seat fee. Works on a plane.

## Install

```bash
cd ~/Downloads/Appdir/meetingbox
chmod +x install.sh
./install.sh
```

That is the whole thing. `install.sh` puts `meetingbox` on your PATH and hands
over to `meetingbox setup`, which checks what is missing, tells you what it wants
to install, and does it when you say yes. Click through two Apple prompts and you
are done: setup ends by opening the meetingbox app.

Nothing to configure. No audio devices to create. No reboot.

The app is `~/Applications/meetingbox.app`. Up to 1.3.1 it lived in
`~/.local/share/meetingbox`; once the new one is in place, setup removes the old
one, and only if setup itself installed it there.

### Updating

Run `./install.sh` again (or `meetingbox setup`). Setup rebuilds the app when the
version has changed or, for a build from a checkout (`./install.sh` there), when
its source or its build recipe has. A running meetingbox is quit just before it is
replaced and opened again at the end, so an old copy never carries on running.
Setup will not replace the app while a recording is running, finishing or being
recovered: it says so and changes nothing. That includes a recording an older
meetingbox is still making; setup names its folder and how to stop it.

### What setup will do

It surveys first and shows you the list before asking for anything:

```
meetingbox setup v2.0.0
           ------------------------------------------------
         + macOS 27
         - Xcode Command Line Tools
         - the recorder
         - a transcriber
         - a signing certificate
         + fm, licence accepted
           ------------------------------------------------
meetingbox 4 things to install. I can do all of them from here.
           some steps may ask for your Mac password, and Apple may open an installer window.
         ? go ahead? [Y/n]
```

| It installs | Why | Cost |
|---|---|---|
| Xcode Command Line Tools | compiles the recorder | one Apple installer window |
| the meetingbox app with its recorder, built from meetingbox's own source (`native/app`, `native/recorder`), plus `mb-transcript` (`native/transcript`) | the app you control recordings from; records you and the far side, and merges the two transcripts | a minute or two to compile |
| a signing certificate called "meetingbox local signing" | lets macOS recognise the app across rebuilds and updates, so it keeps your permissions | a moment, and macOS may ask for your login password once |
| [speech-analyzer](https://github.com/simonw/speech-analyzer-cli) | Apple's on device transcriber | a few seconds, no model download |
| or whisper.cpp instead | if you would rather run your own model | 1.6GB download |
| `sudo fm license` | accepts Apple's model licence, once | your Mac password |

The certificate is self-signed and lives in your login keychain. Setup records its SHA-1 in
`~/.meetingbox/installed`, and `meetingbox reset --tools` and `meetingbox uninstall`
remove it. If it cannot be made, setup falls back to an ad hoc signature and warns
you, and macOS will then ask for permissions again after each rebuild. Running
`meetingbox setup` again retries: it makes the certificate if it is missing and
re-signs the app, without a rebuild. If macOS asks for your login password while
setup signs the app, choose Always Allow.

Then it does a four second test recording to make macOS throw its Screen Recording
and Microphone prompts now, in setup, rather than halfway through a real meeting.
Say yes to both.

The permissions are asked for, and listed in System Settings, as **meetingbox**, not
Terminal. The recorder runs as its own small app, so one grant covers Terminal, a
Shortcuts hotkey and Raycast alike.

macOS asks one at a time: Screen Recording first, and only once that is on does
the recorder reach the microphone, so meetingbox cannot show up under Microphone
before then. If a prompt is missed, setup opens Privacy & Security at the one
still missing and tests again when you press enter. For Screen Recording, turn on
**meetingbox** in the top list (not "System Audio Recording Only"). If it is not
listed, drag in the meetingbox app from the Finder window setup opens. No need to
restart anything.

## The app

meetingbox is a Mac app. Recording, the timer, the list of meetings and the
minutes all live in it, and it processes one meeting at a time in the background,
so a new recording can start while the last one is still being written up.

Three ways to control it, each switched on or off in Preferences:

| Control | What it does | Default |
|---|---|---|
| The menu bar item | A dot and the timer while recording; click for Start, Pause or Resume, Stop, the recording folder, and how each side of the call is coming through | on |
| The floating button | A small pill on top of every window, with the dot, the timer, Pause, Stop and the folder. Drag it where you like | shown while recording |
| The meetingbox window | Opened from the Dock icon: your meetings, their minutes and transcripts | the Dock icon is on |

The menu bar item stays on while the Dock icon is off, so there is always a way in.

The hotkey is not a Preference: it is a shortcut in the Shortcuts app that runs
`meetingbox` (see On a hotkey).

**Preferences** (meetingbox menu, or Cmd-comma): the menu bar item, the Dock icon,
the floating button (Always, While recording, Never), open the minutes when they
are ready (on; never while a recording is running), sounds (on), the microphone
(System default unless you pick one) and the meetings folder (`~/Meetings` unless
you choose another; it can be changed once nothing is recording or being
finished). Choosing a new folder moves nothing: meetings already recorded stay
where they are, and the window lists only the folder chosen here. At the foot it
says which build you are running.

**The meetingbox window** lists your meetings, newest first, with a search box.
Pick one for its minutes and transcript, play its audio in QuickTime Player (not
while a recording is running, which would record it), or show it in Finder. A
recording that was never processed has a Process button. **Rename** gives a
meeting a real title, and its folder is renamed to match with the date kept first
so it still sorts: `2026-10-28 1508 Budget review`. A title ending in something
like a file extension (`deck.key`) has that dot made a `-`, so the Finder never
takes the folder for a file. A meeting cannot be renamed while it is recording or
being processed. A rename that would give two meetings the same folder name is
refused.

Quitting while a recording is running asks first: Stop and quit, Keep recording
and quit (the recording carries on, and meetingbox picks it up when it opens
again), or Cancel.

**Which build is this?** About meetingbox, the foot of Preferences and the last
line of the menu bar item's menu all say, for example
`meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4, 9602459)`: the version, when
it was built, the start of a hash of the source it was built from, and the commit
when it was built from a git checkout. `meetingbox version` prints the same, and
says when the app and the command differ.

## Use it

The app, the hotkey and the command all drive the same recording, and always
agree on what is going on.

```bash
meetingbox          # start
meetingbox          # stop; the minutes follow
meetingbox pause    # stop recording for a bit, same file
meetingbox resume   # carry on
meetingbox status   # what is going on, and the folder
```

The command is a client of the app: it opens the app if it is not running and
hands over. `meetingbox stop` returns at once, as soon as the recording is
stopped. The app then finishes the audio, transcribes and writes the minutes,
showing how far it has got in the menu bar (Saving the recording, Transcribing,
Finding speakers, Writing minutes) and in the meetingbox window, whose badge reads
Saving, then the same stages. The minutes open in the window when they are ready.
The recorded length counts recorded time only.

A start that fails, from the hotkey, the command or the app, shows
`Could not start: <reason>` in amber in the menu bar item; from the hotkey or the
command, the failure sound plays too (when sounds are on).

While the last recording is still being saved, a new one does not start: the
command says so and exits with an error, the app plays its failure sound (when
sounds are on), and the menus show Saving the last recording… where Start would
be. Try again in a moment.

`meetingbox process <file>` still runs in the terminal, for scripting.

## Crash safety

While it records, meetingbox writes uncompressed working files, `mic.caf` and
`call.caf`, which keep every second captured even if the recorder is killed or the
Mac crashes. They take about 0.7 GB an hour together. A recording will not start
with less than 2 GB free; below about 1 GB the menu bar warns that disk space is
low, and close to full the recording is stopped and finished cleanly rather than
lost. When you stop, the working files become the three `.m4a` files below and are
removed only once those are checked and readable. Nothing is processed before then.

The recorder runs on its own, so if the app crashes or is force quit, the
recording carries on, and the next time the app opens it picks the recording up
with the right timer. If the recorder stopped too, the app finishes the recording
from its working files and queues it; if nothing can be rebuilt, the meeting is
marked failed and every file is kept. A recording that stops without being asked
while the app is running (the recorder stopped, or the disk nearly filled), one
that could not be finished, and minutes that could not be written are each said in
the menu bar item, in amber and with the failure sound when sounds are on; click
the line to open that meeting. A recorder that stopped while the app was closed is
finished at the next launch and queued, or marked failed, without the Recording
stopped line. While another recording is running the line waits in the menu, and the
icon keeps showing that recording until it ends. The window says why, and for a
recording never finished, how to finish it. To finish an interrupted recording by hand:

```bash
meetingbox recover ~/Meetings/2026-10-27_1430
```

`meetingbox process` refuses a folder that was never finished, and says to run this.
Files meetingbox writes in a meeting folder are readable by you only. meetingbox
never deletes a meeting folder. It deletes a meeting's audio only when asked to,
with `--no-keep-audio` (or `MB_KEEP_AUDIO=0`) for `meetingbox process`, and only
after the minutes are written.

## On a hotkey

The hotkey is unchanged from earlier versions: it runs the `meetingbox` command,
which hands over to the app. Shortcuts app, new shortcut, add a **Run Shell
Script** action, shell `/bin/bash`:

```bash
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
meetingbox
```

Set a keyboard shortcut in the details pane and tick **Pin in Menu Bar**. First
press records, second press writes the minutes. Hyper plus R is a good binding
because nothing else claims it.

The `PATH` line matters. Shortcuts hands a script a bare environment, so without
it nothing is found.

If you add the shortcut to the Dock, call it something other than meetingbox. A
shortcut in the Dock becomes an app in `~/Applications` under its own name, which
is where the meetingbox app goes, and setup will not replace it.

Raycast users: `extras/raycast-meeting-toggle.sh`, drop it in a script directory
and bind a hotkey.

## What you get

```
~/Meetings/2026-10-27_1430/
  audio.m4a         the recording, both sides mixed
  mic.m4a           your side only
  call.m4a          the other side only
  mic.words.json    your words, with timings
  call.words.json   their words, with timings
  transcript.txt    full text, your source of truth
  notes.md          the minutes
  notes-raw.md      per slice notes, before the final pass
  brief.json        {summary, decisions, actions, open_questions, numbers_and_dates}
  meeting.json      the title and state the app keeps; do not delete it
  capture.log       what the recorder reported while recording and saving
```

Each side is transcribed on its own and the two are merged by time, so the
transcript says who spoke:

```
[00:03:12] Me: Can you send me the numbers after this?
[00:03:15] Them: Yes, I will email them this afternoon.
```

Your microphone also picks up the far side coming out of your speakers. That echo
is dropped, so nothing is counted twice. The minutes name Me or Them as the owner
of an action where no name was said.

## How it captures both sides without a virtual audio driver

This is the part that normally defeats people. A meeting has two sides, and macOS
hands you one. The usual answer is BlackHole plus a Multi Output Device plus an
Aggregate Device, three things to create by hand in Audio MIDI Setup, plus a
reboot, plus changing the output device inside Zoom, and getting any of it wrong
gives you a recording of yourself talking into a void.

None of that here. The recorder takes the far side through **ScreenCaptureKit**,
which is the same API screen recording uses, and your microphone through
AVCaptureSession, and mixes them on a shared clock into one mix, and keeps each side as its own file too. No new
audio devices appear on your system. Zoom, Teams and Meet need no settings
changed. Nothing to reboot.

The cost is that Screen Recording permission is what unlocks system audio, which
is why macOS asks for it even though no video is recorded.

## Why the summary is folded rather than piped

Apple's on device model has roughly a 4000 token window. A 45 minute meeting is
about 7000 words, call it 9500 tokens. Pipe that straight in and you do not get a
bad summary, you get a confident summary of the first eight minutes.

So meetingbox folds instead. Slice the transcript at sentence boundaries into
~1500 word pieces, summarise each one, concatenate, and if the notes are still
over the ceiling, summarise those too. Repeat until it fits, then write the
minutes from what is left. Sizes come from `fm count-tokens`, so the loop
terminates on a measurement rather than on optimism.

Three properties fall out of that:

- **Checkable.** `transcript.txt` stays on disk next to the minutes. Every claim
  has a source you can grep.
- **Parseable.** `brief.json` comes back against a schema, so the next script in
  the chain parses it instead of interpreting it.
- **Bounded.** The only thing that grows with meeting length is the number of
  passes. The window never overflows.

The probabilistic bit sits between two deterministic ones: audio in, structured
record out, transcript kept.

## Commands

```
meetingbox setup                 install what is missing
meetingbox                       toggle
meetingbox start | stop | status
meetingbox pause | resume
meetingbox process <audio|txt>   run an existing file through the pipeline
meetingbox recover <folder>      finish a recording that was interrupted
meetingbox doctor                what is installed and what is not
meetingbox mics                  microphones the recorder can see
meetingbox reset                 clear a stuck recording, ask for permissions again
meetingbox reset --tools         also remove what setup built, to start setup afresh
meetingbox uninstall             remove meetingbox (recordings are kept)
meetingbox version               this command's version, and which build the app is
meetingbox help
```

Options: `--mic "USB"`, `--dir`, `--locale`, `--whisper`, `--native`, `--model`,
`--no-keep-audio`. Each has an `MB_*` environment equivalent. `--mic` and `--dir`
go to the app with each start; without them the app uses its Preferences. The app
remembers each `--dir` folder: a meeting there is picked up after a crash and
opens when its minutes are ready, but the window lists only the meetings folder.

meetingbox plays a short sound when a recording starts (Tink), when it stops (Pop)
and when the minutes are ready (Glass), so a hotkey press is heard to work.
Play sounds in Preferences turns them off (`MB_SOUNDS=0` for `meetingbox process`
in the terminal).

In the minutes, each decision and action ends with the words from the transcript
that show it, so you can check it. Apple's on device model is small and can still
mistake a story about the past for a decision; the quote makes that easy to spot.

`reset --tools` and `uninstall` delete only what setup itself created. Setup keeps
a list in `~/.meetingbox/installed` as it goes, so a whisper model, a
speech-analyzer or a folder that was already on your Mac is left where it is.
Both commands show the exact paths, and anything they are leaving alone, before
asking. Neither goes ahead while a recording is running, finishing or being
recovered. Once you say yes they quit the meetingbox app, then remove it (if setup
installed it) and its socket in `~/.meetingbox`. Your meetings are never touched.

`meetingbox reset` on its own leaves the app installed. If the app is running, it
asks the app to stop any recording (the app finishes it and clears its own state)
rather than clearing that state behind it; only with no app answering does it
stop a recorder and clear the state itself.

## When it misbehaves

Start with `meetingbox doctor`.

| Symptom | Cause |
|---|---|
| Recorder stops immediately | Screen Recording or Microphone not granted to **meetingbox**. Turn it on in Privacy & Security, retry |
| "The screen is asleep or locked, so the call side cannot be recorded" | The call side comes through screen capture, which needs a display awake. Wake the screen (or unlock the Mac) and start again |
| "meetingbox is starting or quitting. Try again in a moment." | The command reached the app while it was opening or closing. Run the command again |
| "this is a Shortcuts app named meetingbox" | A shortcut called meetingbox was added to the Dock, so it sits where the app goes. Rename the shortcut or remove it from the Dock, then run `meetingbox setup` |
| "an older meetingbox is still recording into ..." | A recording started before the update is still running. Stop it as setup says (its audio is kept), then run setup again |
| Not sure which build is running | `meetingbox version`, or About meetingbox. If the app and the command differ, run `meetingbox setup` |
| Permissions look granted but still fail | `meetingbox reset`, then `meetingbox setup` to be asked afresh |
| Asked for permission again after an update | Expected once, on the move from 1.2 to 1.3 (Screen Recording and Microphone). Setup clears the old 1.2 approvals first, because they still show as on in Privacy settings but no longer apply to the newly signed app. From then on the signing certificate keeps the grants across rebuilds. If it keeps happening, run `meetingbox doctor`. If the 'signing certificate' line is missing, run `meetingbox setup`, which makes it and re-signs the app |
| Apple's transcriber did not build | Setup builds it with `swiftc` directly, so a broken SwiftPM ("Invalid manifest") no longer matters. If `swiftc` itself fails, reinstall the Command Line Tools: `sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`. meetingbox carries on with whisper meanwhile |
| `swiftc: command not found` | Command Line Tools still downloading. Let the Apple installer finish |
| `speech-analyzer` fails | Speech Recognition permission, or the first run needs a network fetch for the language model |
| Minutes feel thin | `MB_CHUNK_WORDS=900 meetingbox process <file>`, more slices and more detail |
| Want to see the working | `MB_DEBUG=1 meetingbox` keeps the `.work.*` folder |

Requires macOS 27 for the summary (`fm` arrived then). Recording and transcribing
work on macOS 14 and up.

## Legal, briefly

Recording a call usually needs the other side to know. Say it out loud at the top
of the meeting. In the UK, recording for your own personal use is one thing and
sharing or processing it is another, and GDPR has opinions about the second.
Transcribing on device rather than shipping audio to a vendor is a genuinely
better position to be in, but it is not a substitute for telling people.

## Credits

- [audio-capture](https://github.com/danySam/audio-capture) by danySam (MIT), the
  ScreenCaptureKit recorder that makes the whole thing painless. It is vendored
  and extended in `native/recorder`, with its licence kept alongside
- [speech-analyzer-cli](https://github.com/simonw/speech-analyzer-cli) by Simon
  Willison, a CLI over Apple's SpeechAnalyzer
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) by Georgi Gerganov

MIT licensed.
