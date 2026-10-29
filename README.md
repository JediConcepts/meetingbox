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
are done.

Nothing to configure. No audio devices to create. No reboot.

### What setup will do

It surveys first and shows you the list before asking for anything:

```
meetingbox setup v1.3.0
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
| the recorder, built from meetingbox's own source (`native/recorder`), plus `mb-transcript` (`native/transcript`) | records you and the far side, and merges the two transcripts | a few seconds to compile |
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

## Use it

```bash
meetingbox          # start
meetingbox          # stop, transcribe, write the minutes
meetingbox pause    # stop recording for a bit, same file
meetingbox resume   # carry on
```

The recorded length counts recorded time only, and `meetingbox status` shows
when a recording is paused.

### On a hotkey

Shortcuts app, new shortcut, add a **Run Shell Script** action, shell `/bin/bash`:

```bash
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
meetingbox
```

Set a keyboard shortcut in the details pane and tick **Pin in Menu Bar**. First
press records, second press writes the minutes. Hyper plus R is a good binding
because nothing else claims it.

The `PATH` line matters. Shortcuts hands a script a bare environment, so without
it nothing is found.

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
meetingbox doctor                what is installed and what is not
meetingbox mics                  microphones the recorder can see
meetingbox reset                 clear a stuck recording, ask for permissions again
meetingbox reset --tools         also remove what setup built, to start setup afresh
meetingbox uninstall             remove meetingbox (recordings are kept)
meetingbox help
```

Options: `--mic "USB"`, `--dir`, `--locale`, `--whisper`, `--native`, `--model`,
`--no-keep-audio`. Each has an `MB_*` environment equivalent.

`reset --tools` and `uninstall` delete only what setup itself created. Setup keeps
a list in `~/.meetingbox/installed` as it goes, so a whisper model, a
speech-analyzer or a folder that was already on your Mac is left where it is.
Both commands show the exact paths, and anything they are leaving alone, before
asking.

## When it misbehaves

Start with `meetingbox doctor`.

| Symptom | Cause |
|---|---|
| Recorder stops immediately | Screen Recording or Microphone not granted to **meetingbox**. Turn it on in Privacy & Security, retry |
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
