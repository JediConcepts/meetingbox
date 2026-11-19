# meetingbox

One key. Press it, have the meeting, press it again. You get the recording, a
transcript and a set of minutes, all on the Mac. The recording never leaves it.
A transcript leaves only if you choose an outside model to write the minutes,
and agree to send it there.

No account. No API key and no upload unless you choose an outside model for the
minutes. No per seat fee. Works on a plane.

## Privacy

Recordings never leave the Mac. Transcripts and minutes stay on it too unless you choose an outside model for the minutes. Then each meeting's transcript, with its date, time and length, is sent to the source you chose, and on to wherever that service sends it.

See Outside models for the minutes, below, for how a source is chosen and agreed to.

## New in 2.1.0

- **Parakeet.** Transcripts come from Parakeet, a more accurate model that runs
  on the Mac, unless you choose Apple's transcriber in Preferences. If Parakeet
  is not set up, Apple's is used and the meeting's log says why.
- **Speaker labels.** Each side of a call is split into its speakers: you are
  "Me", people in the room with you "Room 1", "Room 2", people on the call
  "Them 1", "Them 2". A recording kept as one file gets "Speaker 1", "Speaker 2".
  See What you get.
- **Your voice.** meetingbox learns your voice from your video calls, or from a
  90 second voice sample you record in Preferences, so it can tell which speaker
  is you. See Your voice.
- **Your name.** Put it in Preferences and it replaces "Me".
- **Tidy lines.** Transcript lines drop "um" and "uh" and keep short replies
  inline, such as "(Them: yeah)". It is on by default; turn it off in Preferences.
- **Redo.** Redo minutes… and Transcribe again… in the window run a meeting again,
  with the number of people in it if you know it. Everything a run replaces is
  kept in `earlier/`.
- **A choice of minutes writer.** Apple's on device model, or an outside model
  you add and agree to: the Claude API, or a standard source such as Ollama, LM
  Studio or the Local CLI Bridge.
- **The top bar.** The window's top bar holds the recording's controls while one
  runs, and a player for the selected meeting's audio otherwise.

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

Coming from 2.0, setup adds two steps: Parakeet and speaker labels (a few
minutes to build and about 630 MB of models), and outside models, which are
optional. If either cannot be set up, setup says why and carries on: Apple's
transcriber and Apple's model are used as before. Meetings already transcribed
keep their transcripts until you choose Transcribe again.

### What setup will do

It surveys first and shows you the list before asking for anything:

```
meetingbox setup v2.1.0
           ------------------------------------------------
         + macOS 27
         - Xcode Command Line Tools
         - the recorder
         - Parakeet (more accurate transcripts and speaker labels, about 630 MB)
         - outside models (optional, needs Node 20 or later)
         - a transcriber
         - a signing certificate
         + fm, licence accepted
           ------------------------------------------------
meetingbox 6 things to install. I can do all of them from here.
           some steps may ask for your Mac password, and Apple may open an installer window.
         ? go ahead? [Y/n]
```

| It installs | Why | Cost |
|---|---|---|
| Xcode Command Line Tools | compiles the recorder | one Apple installer window |
| the meetingbox app with its recorder, built from meetingbox's own source (`native/app`, `native/recorder`), plus `mb-transcript` (`native/transcript`) | the app you control recordings from; records you and the far side, and merges the two transcripts | a minute or two to compile |
| a signing certificate called "meetingbox local signing" | lets macOS recognise the app across rebuilds and updates, so it keeps your permissions | a moment, and macOS may ask for your login password once |
| Parakeet and speaker labels (on device): `mb-speech` (`native/speech`), built with `swift build` over [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.3, and its models at fixed revisions, each file's size and SHA-256 checked | more accurate transcripts and speaker labels. Optional: if it cannot be set up, Apple's transcriber is used | a few minutes to build, about 630 MB of models |
| Outside models (optional): Node 20 or later, found on your PATH, in Homebrew's folders or in nvm (offered through Homebrew if there is none), and the [AI Execution Router](https://www.npmjs.com/package/ai-execution-router) 1.1.1, installed with `npm ci` from the locked `minutes/package-lock.json` into `~/.local/share/meetingbox/minutes` | lets an outside model you choose write the minutes (see Outside models for the minutes). Nothing else in meetingbox uses Node. If it cannot be set up, Apple's model writes the minutes | a few seconds with Node already there |
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
where they are, and the window lists only the folder chosen here. Under
Transcripts: the Transcriber ("Parakeet (more accurate)" or "Apple"; "Applies to
the next meeting processed."), "Tidy transcript lines (drop 'um' and 'uh', keep
short replies inline)", Your name, and your voice (see Your voice). Under
Minutes: who writes the minutes (see Outside models for the minutes). At the foot it says which build you are running.

**The meetingbox window** lists your meetings, newest first, with a search box.
Pick one for its minutes and transcript, play its audio from the top bar (see The
top bar), open it in QuickTime Player, or show it in Finder. A recording that was
never processed has a Process button. A finished meeting has **Redo minutes…** and
**Transcribe again…** (see Redo, and earlier versions). The transcript view has a
picker of the meeting's other versions, read only: "Current", then any other
transcript in the folder, then "Earlier, <date> <time>" for each version a later
run replaced, newest first. **Rename** gives a
meeting a real title, and its folder is renamed to match with the date kept first
so it still sorts: `2026-10-28 1508 Budget review`. A title ending in something
like a file extension (`deck.key`) has that dot made a `-`, so the Finder never
takes the folder for a file. A meeting cannot be renamed while it is recording or
being processed. A rename that would give two meetings the same folder name is
refused. A folder you named by hand with an underscore and a title,
`2026-11-16_2330 Budget review`, is listed too, under that title, and keeps its
name until you rename it.

Quitting while a recording is running asks first: Stop and quit, Keep recording
and quit (the recording carries on, and meetingbox picks it up when it opens
again), or Cancel.

**Which build is this?** About meetingbox, the foot of Preferences and the last
line of the menu bar item's menu all say, for example
`meetingbox 2.1.0 (build 2026-11-19 14:30, 1a2b3c4, 9602459)`: the version, when
it was built, the start of a hash of the source it was built from, and the commit
when it was built from a git checkout. `meetingbox version` prints the same, and
says when the app and the command differ.

### The top bar

The bar beside New meeting at the top of the window does one of two things.

- **While a recording runs or is paused**, it shows the timer, Pause (Resume
  when paused) and Stop. They control that recording whichever meeting is
  selected, exactly as the menu bar item's do.
- **When nothing is recording**, it is a player for the selected meeting's
  audio: Play or Pause, Stop (back to the start), the position as
  `12:34 / 1:05:00`, and a slider to move. It plays the meeting's `audio.m4a`
  (or a 1.2 meeting's single recording) inside the app. A file it cannot play
  says "This recording cannot be played".

Playback and recording never overlap, because the call side records the Mac's
sound. Starting a recording by any route (New meeting, the menu bar, the floating
button, the hotkey or the command) stops playback first, and the player is not
available while a recording or a voice sample is being made. Selecting another
meeting stops playback too. To play a recording elsewhere, the meeting page has
"Open in QuickTime Player".

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
  notes.md          the minutes, ending with who wrote them
  notes-raw.md      per slice notes, before the final pass (an outside model's reply as received)
  brief.json        {summary, decisions, actions, open_questions, numbers_and_dates}
  meeting.json      the title and state the app keeps, and the minutes writer and people
                    counts last chosen in a sheet for this meeting; do not delete it
  capture.log       what the recorder reported while recording and saving
  .process-log      meetingbox's log of each run: the transcriber, speakers, your voice
  earlier/          what a later run replaced, kept byte for byte (see Redo)
```

Each side is transcribed on its own, its speakers are told apart, and the two are
merged by time, so the transcript says who spoke:

```
[00:03:12] Me: Can you send me the numbers after this?
[00:03:15] Them 1: Yes, I will email them this afternoon. (Them 2: yeah)
[00:03:21] Room 1: And the slides too, please.
```

The labels:

- **Me** is you: the microphone speaker whose voice matches the voice meetingbox
  has learnt (see Your voice), or on a call, the one who holds 80% or more of the
  microphone's words.
- **Room 1**, **Room 2** are other people at your end, on your microphone, in the
  order they first spoke.
- **Them**, or **Them 1**, **Them 2**, are people on the other end of the call. A
  plain "Them" beside numbered ones is someone on the call who could not be told
  apart.
- **Unknown** is speech that could not be put to anyone.

Your microphone also picks up the far side coming out of your speakers. That echo
is dropped, so nothing is counted twice, and so is your own voice coming back on
the call side. Without Parakeet set up, speakers are not told apart, and the
transcript says Me and Them as before. The minutes are told what the labels mean,
keep them as written, and never guess a real name for one: an action's owner is
the name said, else the label as written.

**Tidy lines**, on by default, drops "um", "uh" and the like, joins a speaker's
sentences into one line, and writes a short reply such as "yeah" inline in
brackets where it was said. Turned off (in Preferences, or for one meeting in
Transcribe again), a new line starts at every change of speaker and every word
stays.

**Parakeet** transcribes English meetings. A meeting set to another language
(`--locale`) uses Apple's transcriber, and the log says so.

### A recording kept as one file

A recording without the `mic.m4a` and `call.m4a` pair (a meeting whose side files
were deleted, say, or any other recording you give `meetingbox process`) has no
sides to tell apart. Its words still keep their times, from whichever transcriber
runs, and the speakers are found in the whole file:

```
[00:00:04] Me: Shall we start with the budget?
[00:00:09] Speaker 1: Yes, I have the numbers here.
```

You are "Me" when the voice meetingbox has learnt from your calls, or from a voice
sample, matches one of the speakers. Everyone else is "Speaker 1", "Speaker 2" and
so on, in the order they first spoke, and "Unknown" marks words no speaker could
be matched to (every line, when speakers cannot be found). The words, with their
times, go in `words.json` beside the transcript, and a later run keeps the one it
replaces in `earlier/`. A recording kept as one file never teaches meetingbox your
voice. Transcribe again asks for "People in the recording", you included, from
"Work it out" or 1 to 6; on the command line that is `--people N`, and without it
the number is worked out. Without Parakeet set up, every line says Unknown, with
its time.

### Your name in place of Me

Put your name in Preferences, under Your name, and the lines the voice print says
are yours carry it instead of "Me", in the transcript and in the minutes. Empty, the
default, keeps "Me". A name is letters (any script), spaces, hyphens and
apostrophes, up to 40 characters, starting with a letter, and it cannot be one of
the labels: Me, Them, Unknown, Room N, Them N or Speaker N. A name that breaks the
rule says "Use letters, spaces, hyphens and apostrophes, up to 40 characters.",
and a label says "That name is used as a label. Choose another."; neither is
saved. On the command line that is `--name NAME`, for `process` and `redo`. The
name is saved when you press Return or leave the field. Transcripts already
written keep "Me" until you transcribe them again. Redo minutes (`notes`) also
takes `--name`, so the minutes name you as the person who recorded, but it never
changes a transcript's labels. Nothing about the voice print changes. An outside
model you chose for the minutes is told your name only for a meeting whose
transcript already has a line labelled with it (or with Me); otherwise it is not
sent your name at all.

### Known limits

- In a recording kept as one file, quick exchanges can blur where one turn ends
  and the next begins: a short reply can land inside the other person's line, or
  two lines can come out swapped. A two-sided recording does not have this,
  because each side is its own file.
- In a recording kept as one file, a new voice that is heard only later in the
  recording can be merged into an existing Speaker number.
- "Unknown" in a recording kept as one file is a voice heard too little to be
  given a number.

## Your voice

To tell which speaker is you, meetingbox keeps a print of your voice, made by the
speaker model on the Mac. It is a list of numbers, not a recording, and it never
leaves the Mac: `~/.meetingbox/voice.json`, readable by you only. It is used once
it holds a minute or more of your speech, from two or more calls or from a voice
sample.

**From your video calls.** The first processing of a call adds to it, never a
redo, and only when the call makes it plain which voice is yours: one microphone
speaker holds 80% or more of the microphone's words, sounds unlike everyone on
the call side, and, once the print holds any speech, matches it. A meeting adds
to it once. While the print is not yet usable, two calls in a row that do not
match it discard it, so a first call dominated by someone else cannot lock you
out. The meeting's `.process-log` says what happened: "Learnt N s of your voice
from this call", or "This call's microphone voice did not match the voice learnt
so far, so it was not learnt". A recording kept as one file never adds to it.

**From a voice sample.** In Preferences, "Record a voice sample…" records your
microphone alone, inside the app, while you read aloud for 90 seconds ("Read
aloud for 90 seconds. 0:42 left"); Stop ends it early. "Finding your voice in the
sample…" follows, then one of:

- "Your voice is learnt from this sample (M minutes of speech)." The sample
  replaces any print learnt so far, and is usable on its own.
- "Not enough speech: N seconds of the 60 needed. Record again and read for the
  whole 90 seconds."
- "More than one voice was heard. Record again with only you speaking."
- "meetingbox is not allowed to use the microphone. Allow it in System Settings,
  under Privacy & Security, Microphone."
- "Parakeet is not set up, so a voice sample cannot be used. Run meetingbox
  setup."
- "The microphone stopped working, so the voice sample was not used. Record
  again.", "The voice sample could not be recorded: no microphone was found.",
  "The voice sample could not be recorded: meetingbox could not make a folder
  for it." or "Finding your voice in the sample took too long, so it was not
  used."

A sample can be recorded only while nothing is recording. A meeting always wins:
starting a recording by any route stops the sample ("Stopped because a meeting
started recording.") and deletes its audio, and the player stops while a sample
records. The sample's audio is kept in a private folder under `~/.meetingbox`
only until its print is made, and any left by a crash goes at the next launch.

**What Preferences says.** "Your voice: learnt from N calls (M minutes of
speech)", "Your voice: from a recorded sample (M minutes of speech)", "Your
voice: from a recorded sample and N calls (M minutes of speech)", or "Not learnt
yet: meetingbox learns it from your video calls, or record a sample". "Forget my
voice" deletes the print; a meeting being processed then does not write it back.
`meetingbox doctor` and `meetingbox engines` say the same, and from the terminal
`meetingbox voice add <audio>` makes the print from a recording of you alone and
`meetingbox voice forget` deletes it. `meetingbox reset --tools` and `meetingbox
uninstall` remove it too.

## Redo, and earlier versions

A finished meeting has two actions in the window, also on the command line:

- **Redo minutes…** (`meetingbox notes <folder>`) writes the minutes again from
  the current `transcript.txt`, with the writer you choose in its sheet. It is
  offered on a failed meeting that has a transcript too.
- **Transcribe again…** (`meetingbox redo <folder>`) transcribes again, finds the
  speakers again and writes the minutes again. Its sheet has the Transcriber,
  the number of people ("People in the room, including you", from "Work it out",
  "1 (just you)" or 2 to 6, and "People on the other end of the call", "Work it
  out" or 1 to 6; or "People in the recording" for a recording kept as one file),
  Tidy transcript lines, and Write the minutes with. A count of 1 labels that
  whole side Me (or Them); a count of 2 or more asks for that many speakers. The
  counts and the writer are kept in the meeting's `meeting.json` and used by its
  later runs. From the terminal: `--room N`, `--call N` and `--people N`.

Neither is offered for a meeting being recorded, saved, queued or processed,
including by a `meetingbox` run in the terminal ("That meeting is busy"). A redo
waits behind another meeting's processing, and may run while another meeting
records. A redo never removes audio.

**Nothing is lost.** Every run (a first processing, Redo minutes or Transcribe
again) builds its new files in a private staging folder inside the meeting folder,
named `.stage.` and six characters. Only once every file it needs is there and
well formed does it copy each file it will replace into
`earlier/<YYYY-MM-DD HHMM>/` (`-2` and so on when that minute is taken), check the
copy byte for byte, and then move the new files in. A `notes.md` you edited by hand
is also kept beside it as `notes-edited-<YYYY-MM-DD HHMM>.md`. Nothing else in the
folder is touched. Files someone else wrote there, such as `transcript-original.txt`
or `transcript-parakeet.txt`, are never changed.

**If it does not finish.** The window says why on the meeting: "The redo did not
finish: <reason>. Nothing was changed." or, when it was stopped while moving the
new files in, "The redo stopped part way: <reason>. Choose it again to finish it."
The menu bar says "Redo did not finish". The next run on that meeting finishes the
part-done move first, from its staging folder. A staging folder left by a run that
was stopped before then holds only copies; the next run on that meeting removes it,
and `meetingbox doctor` lists any left in the meetings folder.

**Restoring an earlier version** is by hand for now: copy the files you want back
from `earlier/<date> <time>/` into the meeting folder (in the Finder, or with
`cp`). The transcript picker in the window shows each earlier transcript, read
only, as "Earlier, 19 Nov 2026 14:30" for the folder `earlier/2026-11-19 1430/`,
so you can see which one you want first.

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

## Outside models for the minutes (optional)

Apple's on device model writes the minutes unless you choose another. In
Preferences, under Minutes, add a source, then pick one of its models in "Write
the minutes with": that choice is for new recordings, and for any meeting
without a writer of its own. Redo minutes… and Transcribe again… have the same
choice for one meeting, and that meeting keeps it, for that run and every later
one (Try again, another redo), whatever the Preferences choice says, until a
later sheet changes it, for as long as its source is still there, unchanged and
agreed. Removing or changing that source in Preferences sets the meeting's writer
aside at its next run, as "When a source is contacted" below explains. There are
two kinds of source:

- **Claude API**: Anthropic's Messages interface, at `https://api.anthropic.com`
  unless you change it. It always needs a key.
- **Standard (Ollama, LM Studio, Local CLI Bridge)**: the OpenAI-style chat
  interface, `<address>/chat/completions`, with its models from `<address>/models`.
  The address is the part up to `/v1`; meetingbox adds the rest. An address that
  already ends in `/chat/completions` or `/models` says "This looks like a full
  endpoint. Use the address up to /v1, for example http://127.0.0.1:8787/v1."

**Agreement first.** The first time you choose a model from a source, meetingbox
asks `Send transcripts to <host>?` and says what that means, including that the
transcript holds what other people said. No transcript is sent until you agree.
Every outside source counts as leaving the Mac, even one at `127.0.0.1`, because
a program there may pass the transcript on. Changing a source's kind or address,
or removing it, withdraws the agreement. The line under the picker is about the
Preferences choice: it says, in amber, when that choice sends transcripts, and
to which host. Switch back to "Apple, on this Mac" at any time.

**When a source is contacted.** Listing a source's models contacts it, with its
key when it has one, and sends no transcript. That happens only when you press
Check, open the picker, or save a source: never at launch, and never just
because Preferences opened. A transcript is sent only by a run told to use an
outside model, and whether that model's source is still there, unchanged and
agreed is checked at the start of each run. If it is not, Apple's model writes
the minutes, and `.process-log` in the meeting's folder (meetingbox's log of
each run) says why. A run already under way keeps the writer it started with,
even if its source is then removed.

**Keys.** Set… stores a source's key in your login keychain, and only there. The
engine reads it back through `security` and hands it to meetingbox's script on
standard input, which sends it to that source alone. It is never on a command
line, in a file, a log or the environment. Preferences
shows whether a key is stored without reading it. Changing a source's address,
or removing the source, removes its key; `meetingbox reset --tools` and
`meetingbox uninstall` remove stored keys too. From the terminal:
`meetingbox key set --address <url>` (the key on standard input),
`meetingbox key remove --address <url>` and `meetingbox key status --address <url>`.

**Node.** Outside models need Node 20 or later, and nothing else in meetingbox
does: transcription, speakers and Apple's minutes never use it. Setup's outside
models step looks for Node on the PATH, then in Homebrew's folders, then for the
newest version in nvm, and offers to install it with Homebrew if there is none.
It keeps the path of the Node it found, and then installs the AI Execution
Router, pinned at 1.1.1, which meetingbox's own small script,
`minutes/writer.mjs`, calls. The script runs with an empty environment and
follows no redirects. If that Node goes (the nvm version it found is removed,
say), Preferences says "Outside models need Node 20 or later. Run meetingbox
setup." and Apple's model writes the minutes until you do.

**Standard sources** must answer streamed requests (`stream: true`), as Ollama
and LM Studio do. meetingbox always streams, so the connection stays alive for
the whole of a long meeting's minutes, up to 15 minutes. A source that cannot
stream fails every time, and Apple's model writes those minutes instead. A
Standard source needs no key unless it asks for one: without a key it is sent no
`Authorization` header at all. If Check says "it asked for a key", set one with
Set….

**Ollama** cuts a transcript longer than its context window without saying so.
Start it with a window big enough for a long meeting, then add the source
`http://127.0.0.1:11434/v1`:

```bash
OLLAMA_CONTEXT_LENGTH=65536 ollama serve
```

The picker lists each model as "<model> at <host>". That is the host alone,
without a port or path, so two sources on one host (Ollama and LM Studio both on
`127.0.0.1`, say) read the same there; the list of sources under Minutes shows
each one's full address. The picker marks a model whose name ends in `-cloud` or
`:cloud` "(runs online)": that is meetingbox's own rule. Ollama's cloud models are named that
way, and run on Ollama's servers, not on this Mac.

**A bridge to Claude Code**, such as the Local CLI Bridge, is a Standard source
on this Mac that hands the transcript to Claude under your account. Use one only
if it does all of these:

- starts Claude Code with `--safe-mode`, `--tools ""` and
  `--no-session-persistence`, so nothing said in a meeting can make it use a
  tool, and the transcript is not kept as a session;
- removes `ANTHROPIC_BASE_URL` from the environment it starts Claude Code in, so
  the request goes to Anthropic and nowhere else;
- answers `stream: true` with an event stream, as every Standard source must.

**If an outside model fails**, for any reason (no connection, an error, a spent
quota, a reply cut short or empty, a transcript too long for the model), Apple's
model writes the minutes, and `notes.md` starts with a note saying why and
whether the transcript was sent. Choose Redo minutes to try again. Every
`notes.md` ends by naming who wrote it. The minutes view shows links as plain
text, never as links to click.

## Commands

```
meetingbox setup                 install what is missing
meetingbox                       toggle
meetingbox start | stop | status
meetingbox pause | resume
meetingbox process <file|folder> run a recording or a transcript through the pipeline
meetingbox notes <folder>        write the minutes again from its transcript (Redo minutes)
meetingbox redo <folder>         transcribe it again, then the minutes (Transcribe again)
meetingbox recover <folder>      finish a recording that was interrupted
meetingbox doctor                what is installed and what is not
meetingbox engines               which transcribers are ready, your voice, outside models
meetingbox engines --kind claude|standard --address URL
                                 also the models that source lists (this contacts it)
meetingbox key set --address URL     keep a source's key, read from stdin, in the keychain
meetingbox key remove --address URL  remove it
meetingbox key status --address URL  set or none, without reading the key
meetingbox voice add <audio>     learn your voice from a recording of you alone
meetingbox voice forget          forget your voice
meetingbox mics                  microphones the recorder can see
meetingbox reset                 clear a stuck recording, ask for permissions again
meetingbox reset --tools         also remove what setup built, to start setup afresh
meetingbox uninstall             remove meetingbox (recordings are kept)
meetingbox version               this command's version, and which build the app is
meetingbox help
```

Options: `--mic "USB"`, `--dir`, `--locale`, `--parakeet`, `--native`,
`--whisper`, `--model`, `--no-keep-audio`, each with an `MB_*` environment
equivalent (`MB_ENGINE` for the transcriber). For a run only: `--tidy` or
`--no-tidy`; `--room N` and `--call N` (redo), and `--people N` (process and redo,
for a recording kept as one file), each 1 to 6; `--name NAME`; and `--writer apple`
or `--writer outside --kind claude|standard --address URL --writer-model NAME`,
which meetingbox never takes from the environment. `meetingbox help` lists them
all. `--mic` and `--dir`
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
| "Parakeet is not set up, so Apple's transcriber is used. Run meetingbox setup." | Parakeet's step in setup did not finish, or its models are missing. Run `meetingbox setup`; `meetingbox doctor` says which part |
| "Outside models need Node 20 or later. Run meetingbox setup." | The Node setup found has gone (an nvm version removed, say). Run `meetingbox setup` again. Apple's model writes the minutes meanwhile |
| A minutes file starting "Written on this Mac by Apple's model because ..." | The outside model you chose failed; the note says why and whether the transcript was sent. Choose Redo minutes to try again |
| `meetingbox doctor` lists "staging left by a stopped run" | A run on that meeting was stopped part way. Its staging folder holds only copies, and the next run on that meeting removes it |

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
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference (Apache 2.0),
  which runs Parakeet and the speaker models on device for `mb-speech`
- Parakeet Ultra by [moondream](https://huggingface.co/moondream/parakeet-ultra), as converted to
  Core ML in [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml)
  (CC-BY-4.0). It is a post-trained version of NVIDIA's
  [parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0)
- Speaker labels: [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml),
  Core ML conversions of [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
  (CC-BY-4.0, as scoped by that repository's NOTICE.md)

- [AI Execution Router](https://www.npmjs.com/package/ai-execution-router) (MIT), pinned at
  1.1.1 by `minutes/package-lock.json`, which `minutes/writer.mjs` calls to reach an outside
  model, and [Node.js](https://nodejs.org) (MIT), which runs it. Neither is part of this
  repository: setup installs the router with npm, and uses a Node you have or Homebrew's

The models are downloaded by `meetingbox setup` from Hugging Face, at the revisions pinned in
`native/speech/models.json`, each file checked by size and SHA-256, and used as published.
They are not part of this repository. Their licences (CC-BY-4.0) ask for the credit above.

MIT licensed.
