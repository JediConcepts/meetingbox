# meetingbox Stage 3, part 1: Parakeet, speakers, redo and the choice of minutes writer

Status: written 11 November 2026 for the user's approval, with its plan. Revised the same day after an adversarial review from seven angles (121 findings; every blocker and nearly every other finding taken in).

The direction was approved in conversation on 10 and 11 November:
- "I think from what your tests show Parakeet should be default with speak labelling" and "maybe we should have a prefernce option for the transcription option".
- "we also need a button to redo the summary based on the new transcription. If we update the latest with a new model or update speakers."
- On the minutes: "as an option in preferences to choose between available models".
- "yes to The plan for Parakeet as the default transcriber. It covers the setting to switch back to Apple, speaker labels, and your redo-summary button."

The user's answers to the design questions, 11 November:
- **Per meeting:** pick the writer per redo, with the Preferences choice as the default.
- **Models:** Apple, plus Ollama's local models, Claude through the Local CLI Bridge, "also via the claude API - in fact this is what our AI router is for". Then: "Use the router (adds Node). we now have a use case to add node".
- **Sources:** several sources listed together.
- **Your voice:** learnt from calls, and also a record button.
- **Lines:** "option to clean up. Option to repreocess with different options". Tidying is on by default.
- **Window:** "Option to have the meeting controls (play, pause, stop) in the meetingbox gui where the new meeting button is", meaning recording controls and an audio player.

Mark used below: **(my call)** means Claude decided, and the user has not yet seen the choice.

## Relation to the earlier designs

- **2026-10-28 (meetingbox 2.0):** this part delivers that design's stage 3, "Speakerphone": speaker labels on both channels and a voice print that picks out "Me". FluidAudio replaces sherpa-onnx, after the hands-on test the 5 November design asked for.
- **2026-11-05 (Stage 3, approved):** this part delivers two of its pieces now:
  - Redo (its 6.4), with every replaced file kept;
  - the choice of where the minutes are written (its 6.3), widened to several sources, including a per-meeting choice when redoing;
  - the core of its player (its 6.5): play, pause, stop and position, in the window's top bar beside the recording controls.
- **Left for part 2:**
  - from the 5 November design: the meeting info file, calendar, the people-and-terms list, new instructions tested against the gold lists, quotation checking, the player's speed and volume and jumping from transcript lines and minutes, restoring earlier versions from the window, and the "Keep on this Mac" mark;
  - the hotkey setting.
- **Changed from the 5 November design:**
  - meetingbox now uses Node, for outside models only, so it can use the user's AI Execution Router;
  - the Claude API is reached directly with the user's key, as well as through a bridge.

## 1. Why

- **Transcription is where meaning is lost first.** Test: 10 November, 36 minutes of the user's own meetings (12 clips), 81 hand-judged meaning-changing errors.
  - Apple's transcriber got 31 right (38%).
  - NVIDIA Parakeet Ultra, running on the Mac through FluidAudio, got 69 right (85%), level with the best engine tested.
  - It transcribed a 1 h 48 min side in 39.5 s, with no loops or dropped stretches.
  - Full results: `~/Downloads/Appdir/meetingbox-research/2026-11-10-transcriber-trial/plan-research/accuracy.md`, outside the repository because it quotes private meetings.
- **Who said what is missing.** Today the microphone is "Me" and the call is "Them". An in-person meeting or a speakerphone demo puts several voices on the microphone.
  - The stand-in labeller outside the app over-split single voices, and stopped working when macOS cleared its folder.
  - FluidAudio found three speakers on the user's 2 h 9 min room recording.
  - A voice print taken from the user's side of a video call matched the user's cluster at 0.857, against 0.361 for the next person.
  - Report: `speakers.md` in the same folder.
- **Lines are too choppy.** Every "yeah" from the other side splits a sentence: on one meeting, 65% of lines were three words or fewer.
- **No redo, and overwriting without a copy.**
  - There is no way to redo anything for a finished meeting except from Terminal.
  - Every run of `meetingbox process` overwrites the transcript and minutes without keeping a copy.
- **The minutes writer is fixed** to Apple's small on-device model.

## 2. Goals

1. Parakeet Ultra transcribes by default, on the Mac. Apple's transcriber is a Preferences choice and the automatic fallback.
2. Speaker labels on both channels:
   - "Me" for the user, picked out by voice;
   - "Room 1", "Room 2" for other people in the room;
   - "Them", or "Them 1" and "Them 2", for the far side of a call;
   - "Unknown" when it cannot tell.
3. **Tidy lines,** an option that is on by default: transcript lines read as sentences, with fillers dropped and short replies kept inline.
4. **Redo minutes** and **Transcribe again** on any finished meeting, from the window and from Terminal. Transcribe again takes its own options: transcriber, people counts, tidying and minutes writer.
5. Nothing meetingbox does ever overwrites a transcript or minutes without keeping the earlier copy.
6. **A Preferences choice of minutes writer,** with the same choice for one meeting when redoing it:
   - Apple on this Mac (the default);
   - or any model from the outside sources the user adds: the Claude API with the user's key, Ollama or LM Studio, or the Local CLI Bridge, all listed together.
7. **The window's top bar** carries:
   - the recording controls: timer, Pause or Resume, and Stop;
   - a simple player for the selected meeting's audio.
8. **Your voice:** learnt from video calls, or recorded on purpose in Preferences.
9. **Transcript versions,** read only: the meeting page can show any transcript in the folder or in `earlier/`. The user approved this on 11 November, after another session started writing `transcript-parakeet.txt` with MLX Parakeet.

## 3. Non-goals for this part

- Everything listed for part 2 above.
- Giving speakers names (mapping "Room 1" to a person). Part 2, with the info file.
- Remembering anyone's voice except the user's. Speaker vectors are used during processing and never kept in meeting folders.
- Names-and-terms boosting in the transcriber. Tested on 11 November: two false insertions for every fix.
- Speaker labels for v1.2 meetings that have only one mixed file. They get Parakeet text without labels.
- Running Claude through the user's Claude Code login from inside meetingbox. That stays the Local CLI Bridge's job.
- Gemini, Vertex and Bedrock sources. The router supports them, so they are a small later step.
- Node anywhere but the outside minutes writer.
- Any change to recording, crash safety or finalising.

## 4. Anti-goals: failure even if it works

- **Confidently wrong attribution.**
  - A line on the wrong person is worse than "Unknown".
  - Never guess that the biggest voice is the user, except where the channel itself proves it: the microphone side of a video call.
  - Never learn someone else's voice as the user's.
- **Losing or overwriting meeting data.** That includes:
  - a redo, or a first processing, that cannot be undone;
  - touching files meetingbox did not write (`transcript-original.txt`, `transcript-parakeet.txt` and the stand-in's files exist in many folders);
  - a folder left half old and half new with no way to finish it.
- **Meeting content leaving the Mac without the user choosing that,** or going anywhere other than the endpoint the user set.
  - With the on-device choices, meetingbox itself makes no network request while processing and sends nothing.
  - Apple's transcriber may fetch its language files through macOS the first time a language is used.
- **Downloads during processing.** Models are fetched by setup only, at pinned versions.
- **A failed Parakeet build stopping setup, or deleting a working one.**
- **A recording slowed or interrupted** by any of this.

## 5. Constraints

All of Stage 2's still apply:
- one owner for recording commands;
- never block the main queue;
- the app and mb-transcript built with `swiftc`, SwiftUI without macros;
- private files (0600 files, 0700 folders);
- atomic renames that refuse to overwrite;
- meeting folders and audio never deleted;
- every tool, model or keychain item setup or the engine creates outside a meeting folder recorded in `~/.meetingbox/installed`, and removed only through it;
- one-command setup;
- British English.

New:
- **The speech helper is the one Swift package.**
  - FluidAudio is about 97,000 lines of Swift with a C++ part, too big to vendor and compile with `swiftc`.
  - The helper, `mb-speech`, is a small package in the repository built by setup with `swift build`. Swift Package Manager has worked on this Mac since 28 October.
  - Every SwiftPM cache, clone and configuration lives in setup's temporary folder, so nothing lands in the user's shared Swift folders.
  - If the build fails on any Mac, setup says so and carries on with Apple's transcriber, keeping any working helper it had **(my call)**.
- **Pinned versions:**
  - FluidAudio exactly v0.18.3 (Apache 2.0), with only the features ASR and offline speaker labelling need (no text-to-speech, no downloaded text normaliser), and its resolved commit checked in;
  - each model at a fixed Hugging Face revision, with every file's size and SHA-256 checked in and verified after download.
- **Licences:** Parakeet Ultra is CC-BY-4.0, so the README credits it. The README names the licence of every model and of FluidAudio.
- **Models live under `~/.local/share/meetingbox/models`,** recorded before download.
  - Processing runs the helper with FluidAudio's offline mode on and every revision pinned, so it cannot download anything.
  - A missing or wrong model means "use Apple".
- **The helper reads a 16 kHz mono WAV** that the engine makes with macOS's own `afconvert` in the run's private staging folder, and its temporary files go there too. So no decoded audio is ever left outside the meeting folder.
- **English only for Parakeet.** A meeting with a non-English `MB_LOCALE` uses Apple's transcriber.
- **Outside models go through Node and the user's AI Execution Router,** and through nothing else:
  - the router (MIT, no dependencies) is pinned at exactly version 1.1.1 and installed with its install scripts disabled;
  - a small script in the repository, `minutes/writer.mjs`, calls it;
  - Node 20 or later is needed for outside models only. Transcription, speakers and Apple's minutes never need Node.
- **Two kinds of source:**
  - "Claude API": Anthropic's Messages interface, at `https://api.anthropic.com` unless the user changes it;
  - "Standard": the OpenAI-style chat interface (`<address>/chat/completions`, models from `<address>/models`), as served by Ollama, LM Studio and the Local CLI Bridge.
- **How the script runs:**
  - The engine runs it with an empty environment.
  - The key and the request arrive on standard input.
  - Every network call refuses redirects.
  - The address is checked by the same rule as the app's.
  - Listing models uses the provider's own list call, because the router only runs requests.
- **Address rule**, applied identically by the engine and the app, with one shared table of test cases:
  - lower-case `https://` or `http://`, then a host with an optional `:port` (1 to 65535), then an optional path;
  - no user information (`@`), no `?`, no `#`, no spaces, quotes, backslashes or control characters, and at most 2048 characters;
  - `http` only for the hosts `127.0.0.1`, `localhost` and `[::1]`, exactly;
  - `https` for a DNS name or a bracketed IPv6 literal.

  Every host shown to the user is the host parsed by this rule **(my call)**.
- **A key for a source, if needed** (the Claude API always needs one):
  - it is 1 to 4096 characters from `A-Za-z0-9._~+/=-`;
  - it is kept in the login keychain only, stored and read by the engine through `security`, and handed to the script on standard input;
  - it is never in a command line, a file, a log or the environment;
  - a key read back that breaks the rule is not used.
- **Every request to an outside source:**
  - follows no redirects;
  - is limited to the address's own protocol;
  - for a local `http` address, uses no proxy.
- **The README's promise:** "Recordings never leave the Mac. Transcripts and minutes stay on it too unless you choose an outside model for the minutes. Then each meeting's transcript, with its date, time and length, is sent to the source you chose, and on to wherever that service sends it."

## 6. What is decided

### 6.1 The transcriber

- **Preferences gains "Transcriber":**
  - "Parakeet (more accurate)" is the default; "Apple" is the other choice.
  - The choice applies from the next job.
  - If Parakeet is chosen but not set up, a line under the picker says so and that Apple's transcriber is being used.
- **Fallback, per side of a meeting:** the chosen transcriber, then Apple's, then whisper.cpp if installed. If Parakeet is not set up or its model is missing, Apple's is used and the meeting's log says why.
- **How the choice reaches the engine:**
  - The app passes the choice to the engine explicitly with each job.
  - In Terminal: `--parakeet` or `--native` (Apple), else `MB_ENGINE`, else the app's preference, else Parakeet if ready.
- **Output shape:** Parakeet's words are saved as `mic.words.json` and `call.words.json` in the same shape as Apple's, so everything after transcription reads one format.

### 6.2 Speakers

- **When it runs:**
  - on each side separately, after transcription, with either transcriber's words;
  - the progress line "Finding speakers" covers it;
  - without the speech helper, transcripts are "Me" and "Them" as today;
  - a side whose transcription succeeded but found no words is skipped;
  - a side that every transcriber failed on is still labelled, so it can count towards "What counts as a call" below.
- **Pipeline settings:**
  - FluidAudio's offline pipeline with default clustering and overlapping segments;
  - a speaker's talk time and median segment length are measured on an exclusive copy of the segments, as the thresholds below were;
  - a people count, when given, asks for that many speakers. FluidAudio may find fewer.
- **What is kept:** the speaker results, with their voice vectors, live only in the run's staging folder. Nothing about speakers is kept in the meeting folder except the labels in the transcript.
- **What counts as a call:** the call side holds 20 s or more of speech, measured from its speaker results, or from its words when there are none.
- **The voice print is usable** only when it holds 60 s or more of speech from 2 or more meetings, made by the same speaker model as this run.
- **Names, on the call side.** The first rule that matches wins:
  1. The speaker matches a usable print (cosine 0.60 or more). This is the user's voice coming back.
     - Its words are left out of echo removal, so the user's own microphone words stay "Me".
     - Its words are dropped where they repeat kept microphone words.
     - Any left are "Unknown", and the log says the user's voice was heard on the call side.
  2. Without a people count: a speaker with under 5% of the side's talk, or a median segment under 2.5 s, or a cosine of 0.45 or more with the print, is plain "Them".
  3. The rest: one speaker is "Them", several are "Them 1", "Them 2" in order of their first word.
- **One voice heard on both sides, on a call.** A microphone speaker and a call-side speaker whose cosine is 0.60 or more, neither matching the print, are one voice heard twice.
  - Their shared words are the pairs echo removal matches. Whichever side's copies of those words mostly come later is the echo.
  - **If the microphone speaker is the echo:** the far side leaked into the microphone. Its remaining words are dropped, the log gives the count, and its talk is left out of the microphone totals below.
  - **If the call-side speaker is the echo:** the user's voice came back. That speaker is treated as in call-side rule 1, and the microphone speaker is named by the rules below.
  - With no shared words, the microphone speaker is "Unknown".
- **Shares and order.**
  - A speaker's share of a side counts only that side's words whose sole candidate is that speaker, after echo removal. Words with no candidate or with several count for nobody.
  - Speakers are numbered by the first such word. A speaker with no such word gets no number.
- **Names, on the microphone side.** The first rule that matches wins:
  1. The speaker matches a usable print, with 10 s or more of talk: "Me".
  2. On a call, the speaker holds 80% or more of the microphone words kept after echo removal, and either there is no usable print or its cosine with the print is 0.45 or more: "Me". The channel proves it.
  3. The speaker's cosine with a usable print is 0.45 or more: "Unknown".
  4. Without a people count: under 5% of the side's talk, or a median segment under 2.5 s: "Unknown".
  5. Otherwise "Room 1", "Room 2", numbered by first word. Only speakers that keep at least one word are numbered, so there are no gaps.

  When a usable print exists and no microphone speaker becomes "Me" by rule 1 or 2, the log says "Your voice was not recognised on the microphone side (best match 0.52)". In a room recording with no usable print, the log says the user's voice has not been learnt yet.
- **Words to speakers:**
  1. **Load:** a word's end is capped at its start plus 1.2 s.
  2. **Candidates:** the speakers whose segments contain the word's midpoint (start at or before it, end after it). If there are none, the speaker of the segment whose nearer edge is closest to the midpoint, if within 1.0 s.
  3. **Name the speakers** by the rules above. Words whose only candidate is an echo speaker are dropped.
  4. **A word with no candidate** takes the side's label when every speaker on that side has the same label. Otherwise it is "Unknown" on the microphone side and "Them" on the call side.
  5. **A word with two or more different candidate labels** takes the label held by most words of its sentence that have exactly one candidate label. A tie goes to the label of the latest-starting segment. A sentence runs up to and including a word ending in `.`, `?` or `!`.
  6. **Smoothing:** the runs of equal labels in each sentence are computed once. Then, in one pass, a run of one or two words with the same label on both sides takes that label. A single word at a sentence's start or end takes the label of its neighbouring run when that run has three or more words.
- **The user's voice print** is learnt from video calls, or recorded on purpose.
  - **"Record a voice sample…" in Preferences:**
    - Recording: the user reads aloud for 90 s, with a countdown. Only the microphone is recorded, by the same recorder and permission meetings use, into a private temporary folder outside the meetings folder.
    - Building the print: the engine finds the speech in it. A sample with 60 s or more of one voice becomes a usable print on its own, replacing any print learnt so far, and counts as one meeting. A sample with less, or with more than one voice, is refused with the reason.
    - Clean-up: the sample's audio is deleted afterwards.
    - Availability: it is offered only while nothing is recording.
  - **When a meeting adds to it:** only first processing does (never a redo), and only if all of these hold:
    - the meeting is a call, and its call side has speaker results with at least one speaker;
    - its dominant microphone speaker holds 80% or more of the microphone words kept after echo removal;
    - that speaker's cosine with every call-side speaker is under 0.40;
    - if the print already holds any speech, the speaker's cosine with the print is 0.60 or more;
    - this meeting has not added to the print before.
  - **How it is stored:**
    - each vector is scaled to length 1 before it joins a talk-weighted mean;
    - the print is at `~/.meetingbox/voice.json` (0600), with the seconds, the meetings that made it and the speaker model;
    - setup records the path; if the file exists but is not on the record, nothing is learnt and the log says why;
    - the engine writes it only if it is unchanged since it read it, so "Forget my voice" during processing holds. It writes through `voice.json.tmp` beside it, which forgetting, reset and uninstall also remove;
    - while the print is not yet usable, two refused calls in a row discard it, so a first call dominated by someone else cannot lock the user out. The log says so.
  - **The meeting's log says** "Learnt N s of your voice from this call", or "This call's microphone voice did not match the voice learnt so far, so it was not learnt".
  - **In Preferences:**
    - "Your voice: learnt from N calls (M minutes of speech)", with singular forms, or "Your voice: from a recorded sample (M minutes of speech)";
    - or "Not learnt yet: meetingbox learns it from your video calls, or record a sample";
    - "Record a voice sample…" and "Forget my voice" buttons, which work through the engine.
  - **`meetingbox doctor`** shows the same.
- **People counts for one meeting.** "Transcribe again" asks:
  - "People in the room, including you": Work it out, 1 (just you), 2 to 6;
  - "People on the other end of the call": Work it out, 1 to 6.
  - **A count of 1** means no speaker labelling on that side and no voice print used or learnt there. The whole microphone side is "Me", or the whole call side is "Them".
  - **A count of 2 or more** asks for that many speakers and turns off the share and segment-length tests on that side. The voice print tests still apply.
  - Counts are saved in the meeting's `meeting.json` and used by later redos of that meeting from the window. From Terminal, `--room` and `--call` give them; without them it works them out.

### 6.3 Tidy lines (an option, on by default)

- **Where it is set:** Preferences gains "Tidy transcript lines (drop 'um' and 'uh', keep short replies inline)", on by default. Transcribe again has the same switch for one meeting, starting at the Preferences choice.
- **When it is on:** the joiner below replaces today's turn merging. The 10 November prototype took lines of three words or fewer from 65% to 7%.
- **When it is off:** today's merging is kept, with speaker labels. A new line starts at every change of speaker, and every filler stays.
- **The 1.2 s cap** on word ends applies either way, because the speaker rules need it.

- **Word timings and noise:**
  - a word's end is capped at its start plus 1.2 s;
  - tokens starting with `#` are dropped;
  - the fillers "um", "uh", "erm", "er", "umm" and "uhm" are dropped.
- **Utterances:** each speaker's words form utterances, split:
  - where the gap exceeds 1.5 s;
  - after 45 s at a sentence end;
  - and before any word of another speaker that is not part of a short reply.
- **Lines:** a line takes in the same speaker's next utterance, starting within 4 s with nobody in between, while the line so far spans under 60 s. Short replies do not count as somebody in between.
- **Short replies inline:** a short reply from another speaker is written inline in time order, for example "(Them: yeah)".
  - "Short" means three words or fewer, all from a fixed list of acknowledgements. "No" is not on it.
  - The reply's host is the latest-starting utterance of another speaker that contains the reply's start, or ended within 0.5 s before it.
- **The line format is unchanged:** `[HH:MM:SS] Label: text`. Every reader accepts any label.
- **The minutes instructions explain the labels,** including that a plain "Them" beside numbered ones is someone who could not be told apart. Where nobody is "Me", the person who recorded may be one of the "Room" speakers.

### 6.4 Redo, and keeping everything replaced

- **Engine commands:**
  - `meetingbox notes <folder>` writes the minutes again from the current `transcript.txt`;
  - `meetingbox redo <folder>` transcribes again, finds speakers again and writes the minutes again;
  - `meetingbox process` keeps its job.

  All three work the same way:
  - they take the processing lock, report progress and write `.process-result`;
  - they refuse an unfinished recording;
  - `notes` and `redo` never remove audio, whatever `--no-keep-audio` or `MB_KEEP_AUDIO` say.
- **One way of writing for every run.** Every run builds its new files in a private staging folder inside the meeting folder. Only when every required file is there, non-empty and well formed:
  1. **Keep:** every existing file it will replace is copied into the staging folder and compared byte for byte. Only then is that copy renamed to `earlier/<YYYY-MM-DD HHMM>/` (with `-2` and so on if taken), so it appears whole or not at all.
  2. **Hand edits:** a hand-edited `notes.md` is also copied to `notes-edited-<YYYY-MM-DD HHMM>.md` beside it. "Hand-edited" means its SHA-256 differs from `.notes-written`, or there is no `.notes-written`.
  3. **Swap:** the engine writes a `.swap` marker, then moves each new file over its old one, one rename at a time, and removes the marker.
     - The marker names the job kind and the staging folder and ends with an end line. It is written to a temporary name and renamed into place, so it is complete or absent.
     - A listed file that this run did not make (a brief that failed, for example) has its old copy moved into the same `earlier/` folder. So old and new are never mixed.
     - `.notes-written` is written with the notes and moved in last. It is never kept in `earlier/`.
     - Interrupt signals are ignored during the swap.
- **Interrupted runs:**
  - A run killed before the swap changes nothing.
  - A run killed during the swap leaves the marker. The next `notes`, `redo` or `process` on that folder finishes that swap first, from the staging folder, and marks each file it moves as written now.
    - A run of the same kind then stops with success, because its result is in place.
    - A run of another kind goes on with its own work.
  - A marker without its end line is discarded, because no file had moved yet.
  - Staging folders left by killed runs, other than one a marker names, are removed under the lock. They hold only copies.
  - A run whose folder was moved mid-run stops before changing anything.
- **Which files are replaced:**
  - **Minutes:** `notes.md`, `notes-raw.md`, `brief.json`, `.notes-written`.
  - **A transcription:** those, plus `transcript.txt`, `mic.words.json`, `call.words.json`.
  - **A side that every transcriber failed on** is written as a words file with no words, as today's empty file is, and the run goes on with the other side.
  - **Failure:** a redo in which a side that has words today produces none is a failure, and nothing is changed.
  - **First processing whose minutes fail:** the transcription files are still swapped in, keeping what they replace. The run then reports failure, so the meeting is Failed with a transcript, as today, and Redo minutes can finish it.
  - Nothing else in the folder is touched.
- **Restoring an earlier version** is by hand for now: copy back from `earlier/`. The README says so.
- **Seeing other versions.** The Transcript view gains a picker, read only.
  - It lists:
    - "Current" (`transcript.txt`);
    - every other `transcript*.txt` in the folder, by file name, with `transcript-parakeet.txt` as "Parakeet (MLX)" and `transcript-original.txt` as "Original";
    - "Earlier, <date> <time>" for each `earlier/*/transcript.txt`, newest first.
  - Choosing one only shows it.
  - Search and the minutes still use `transcript.txt` alone.
  - The picker resets to "Current" when another meeting is selected.
- **In the window:**
  - **"Redo minutes…"** on a finished meeting, and on a failed one that has a transcript.
    - It opens a small sheet: "Write the minutes with", starting at the meeting's own choice if it has one, else the Preferences choice.
    - Choosing an outside model there asks for agreement, as Preferences does.
    - The choice, Apple included, is kept in the meeting's `meeting.json` and used by every later run on that meeting (Process, Try again and redos) until another sheet changes it.
  - **"Transcribe again…"** on a finished meeting whose recording can be processed. It opens a sheet with:
    - Transcriber, starting at the Preferences choice;
    - the two people counts, starting at the meeting's saved counts;
    - "Tidy transcript lines", starting at the Preferences choice;
    - "Write the minutes with";
    - Cancel and Transcribe again.
  - **Busy meetings:** neither action is offered, or accepted at the click, for a meeting being recorded, saved, queued or processed, including by a `meetingbox` run in Terminal.
  - **Queueing:** a redo queues behind another meeting's processing, and may run while another meeting records.
- **The queue:**
  - **Job kinds:** a redo's kind and choices are written to `meeting.json` before it runs, so after a crash the same kind of job runs again. They are cleared on every final outcome, and by Process or Try again, which always run a full process.
  - **Success:**
    - for Redo minutes, a new `notes.md`;
    - for Transcribe again, a new `transcript.txt` and `notes.md`.
  - **Killed engine:** a redo's engine stopped by a signal, or one that reports a swap it could not finish, is run again as the same kind, up to the usual three attempts.
  - **Failure:** the meeting goes back to Done if it has `notes.md` (else Failed), and the window shows the reason on the meeting.
    - When nothing changed: "The redo did not finish: <reason>. Nothing was changed."
    - When a swap was left part done: "The redo stopped part way: <reason>. Choose it again to finish it."
    - The menu bar's amber line says "Redo did not finish".

### 6.5 The minutes writer

- **Sources.** Preferences gains a "Minutes" section with a short list of outside sources (Add… and Remove). Each source has:
  - a kind: "Claude API", or "Standard (Ollama, LM Studio, Local CLI Bridge)";
  - an address, with `https://api.anthropic.com` filled in for the Claude API;
  - a key, with Set… and Remove: needed for the Claude API, optional for Standard;
  - a Check button that lists the source's models ("Found 3 models", "Found 1 model", or why not).
  - No two sources share an address.
  - **With no sources**, the section says: "To use another model, add a source: the Claude API with your key, or a standard address such as Ollama (http://127.0.0.1:11434/v1) or the Local CLI Bridge."
- **"Write the minutes with":**
  - "Apple, on this Mac" (the default), then every model of every source, as "<model> at <host>";
  - a model whose name ends in `-cloud` or `:cloud` is shown with "(runs online)";
  - a saved choice no longer listed stays, as "(not available)";
  - a source that lists no models, or cannot list them, gets a "Model name" field.
- **When sources are contacted:** only when the user presses Check, opens the picker, or saves a source. Never at launch, and never just because Preferences opened.
- **The line under the picker:**
  - "Transcripts stay on this Mac.";
  - or, in amber, "Transcripts are sent to <host> to write the minutes. Recordings stay on this Mac. This applies to every meeting processed, including new recordings."
- **Agreement.** Choosing an outside model, in Preferences or in a redo sheet, from a source not yet agreed opens a confirmation:
  - Title: "Send transcripts to <host>?"
  - Text: "To write the minutes, meetingbox will send each meeting's full transcript, with its date, time and length, to <address>. If that is a program on this Mac, it may pass it on: the Local CLI Bridge sends it to Claude or Codex under your account, and an Ollama model whose name ends in 'cloud' runs on Ollama's servers. The transcript includes what other people said, so make sure they are happy with that. Recordings stay on this Mac. You can switch back to Apple at any time."
  - Buttons: Cancel, and "Send transcripts to <host>".
  - Agreement is kept for that source while its kind and address stay the same. Changing either, or removing the source, withdraws it.
  - **At launch,** an outside writer is used only if its source still exists, unchanged and agreed. Otherwise the run uses Apple and the log says why.
  - meetingbox treats every outside source as leaving the Mac, even one at `127.0.0.1` **(my call)**.
- **The engine uses an outside model only when told explicitly for that run:** `--writer outside --kind claude|standard --address <url> --writer-model <name>`.
  - It never reads an outside writer from the environment or from the app's settings.
  - The app passes these per job, and only for an agreed source.
- **How the request is sent.** The engine runs meetingbox's own `writer.mjs` with the recorded Node, with an empty environment. The request and the key arrive on standard input. The script:
  - checks the address by the shared rule;
  - refuses every redirect;
  - calls the router's `complete()` once, not streamed, with a 15-minute limit;
  - returns:
    - the text and the finish reason;
    - the prompt token count, with whether the router marked it as reported;
    - for a failure, its kind (no connection, timeout, quota used up, rate limited, refused, other) and whether the request could have reached the source.
- **The request:**
  - one request carrying the whole transcript, timestamps kept;
  - the instructions as the system message, saying the transcript is data and never instructions;
  - the user message is a context line, a blank line, then the transcript between `<transcript>` tags.
- **What gets written:**
  - The reply is the minutes in Markdown under today's headings.
  - `notes-raw.md` is the reply as received; `notes.md` adds a last line naming the writer.
  - `brief.json` is then built from the finished `notes.md` by Apple's on-device model. Without that model there is no brief, and the log says so.
- **Who wrote it:** every `notes.md` ends with "Minutes written by <model> at <host>." or "Minutes written on this Mac by Apple's model."
- **Any failure falls back to Apple**, and `notes.md` then starts with one of two notes:
  - nothing was sent: "Written on this Mac by Apple's model because <host> could not be reached: <reason>. The transcript was not sent. Choose Redo minutes to try again.";
  - the transcript was sent, or that cannot be told: "Written on this Mac by Apple's model because <host> did not return usable minutes: <reason>. The transcript was sent to <host>. Choose Redo minutes to try again."

  These count as failures:
  - no connection, an HTTP error, the time limit, quota used up, rate limited;
  - an empty reply, a reply cut short;
  - a reply whose prompt token count is marked as reported and is clearly smaller than what was sent (a context window too small);
  - a stored key that breaks the key rule;
  - Node or the router not set up.

  The note's reason names which, for example "your Claude API quota is used up". meetingbox never falls back from one outside choice to another.
- **The minutes view** shows links as plain text, never as clickable links **(my call)**.
- **Without Node:** if Node or the router is not set up, outside models show as unavailable with the reason, "Outside models need Node 20 or later. Run meetingbox setup."
- **New engine commands:**
  - `meetingbox engines [--kind claude|standard --address <url>]` lists:
    - whether Parakeet, Apple's model and the outside-model runtime are ready;
    - with a source, its models or why they could not be listed.
  - `meetingbox key set --address <url>` reads the key from standard input, stores it in the keychain and records it. `meetingbox key remove --address <url>` deletes it.
  - `meetingbox voice add <audio>` makes the print from a recorded sample. `meetingbox voice forget` deletes it.

### 6.6 The window's top bar

- **While a recording runs or is paused,** the bar beside New meeting shows the timer, Pause (Resume when paused) and Stop.
  - They control that recording whichever meeting is selected.
  - They go through the same single owner as the menu bar.
- **When nothing is recording,** the bar holds a player for the selected meeting's audio:
  - Play or Pause, and Stop (back to the start);
  - the position as "12:34 / 1:05:00", with a slider to move.
  - It plays the combined `audio.m4a` (or a v1.2 meeting's single file) inside the app.
- **Playback and recording never overlap:**
  - starting a recording stops playback, and the player is unavailable while recording, because the call side records the Mac's sound;
  - selecting another meeting stops playback **(my call)**.
- **The meeting page's "Play audio" button,** which opened QuickTime Player, becomes "Open in QuickTime Player" **(my call)**.
- **Left for part 2:** speed, volume, and jumping to a moment from the transcript or minutes.

## 7. Install and setup

- **A new setup step, "Parakeet and speaker labels (on device)"**, after the recorder step.
  - Survey line: "+ Parakeet", or "- Parakeet (more accurate transcripts and speaker labels, about 630 MB)".
  - **Source:** it fetches the meetingbox source first.
  - **Build:** `mb-speech` is built from `native/speech` in a temporary folder that holds every SwiftPM cache and clone. Only then does it replace the installed helper at `~/.local/share/meetingbox/mb-speech`, which is claimed and recorded the first time.
  - **Models:** the models folder is claimed and recorded when first created. The models are downloaded only when the folder's check fails or its manifest differs from the source's, into a part folder, verified, then swapped in.
  - **Cache:** the folder Core ML uses for the helper's prepared models is recorded if it did not exist before. It is recorded only if the path the helper reports ends in `/Library/Caches/mb-speech`, so a shared folder is never recorded.
  - **Voice print:** the voice print's path is recorded if the file does not exist yet.
  - **Warm-up:** the helper then prepares the models once (about 30 s).
- **If any step fails:** "Parakeet could not be set up: <reason>. Carrying on with Apple's transcriber." Setup continues, and a working helper or model already installed is left in place.
- **Ready check:**
  - the helper's source hash matches;
  - the installed manifest matches the source's;
  - every model file is present at its size.
  - On a release update, the Parakeet step is checked whenever the recorder step is due, so a changed helper is rebuilt.
- **A second new step, "Outside models (optional)"**, after the Parakeet step.
  - Survey line: "+ outside models (Node 22.22.2)", or "- outside models (optional, needs Node 20 or later)".
  - **Finding Node 20 or later:** looked for on the app's PATH, then in Homebrew's folders, then the newest nvm version. Its absolute path is kept in `~/.meetingbox/node`, which is recorded. If there is none, setup offers to install Node with Homebrew, as it offers whisper.cpp. Declining skips the step.
  - **Installing the router:** `minutes/` (`writer.mjs`, `package.json`, `package-lock.json`) is copied to `~/.local/share/meetingbox/minutes`, which is claimed and recorded. Then that Node's npm runs `ci --ignore-scripts --omit=dev` there, with npm's cache in a temporary folder that is removed afterwards. The lock file pins ai-execution-router 1.1.1 by its integrity hash.
  - **Ready check:** the recorded Node runs, at version 20 or later, and `writer.mjs version` reports router 1.1.1.
  - **If any step fails:** "Outside models could not be set up: <reason>. Apple's on-device model still writes the minutes." Setup continues.
  - **If nvm's Node later moves or goes,** outside models show as unavailable until setup is run again.
- **Other commands:**
  - `meetingbox doctor` reports:
    - the helper, the models, the cache folder and the voice print;
    - Node and the router;
    - any staging folder left behind.
  - `reset --tools` and `uninstall` remove all of these, plus stored keys, through the install record. Node itself is left alone; a Homebrew Node is listed as installed by Homebrew, as whisper.cpp is today.

## 8. How we will know it worked

- **Transcription:**
  - on the 12 clips from 10 November, each clip's word count from Parakeet in meetingbox is within 1% of the test run's;
  - one side run from its `.m4a` through the engine is within 1% of the WAV run.
- **Speakers, in one scratch home, on copies of the four 10 November meetings:**
  - The 17:54 and 10:20 calls are processed first.
    - Afterwards `voice.json` holds 60 s or more from 2 meetings.
    - 17:54's microphone side is all "Me" and its call side all "Them".
  - Then the 13:35 room recording gives "Me", "Room 1" and "Room 2", with "Me" on 70% or more of the words.
  - 20:02 gives "Me" and "Them", with "Unknown" on under 2% of lines.
- **Lines:** on 17:54, lines of three words or fewer are under 15% of all lines.
- **Safety:**
  - on disposable meetings, a `kill -9` at every stage of `process`, `notes` and `redo` leaves the folder as it was, or finished by the next run, never with a file missing;
  - `earlier/` holds the replaced files byte for byte;
  - a hand-edited `notes.md` is kept as `notes-edited-<stamp>.md`.
- **Minutes writer:**
  - with Apple chosen, processing makes no network request (a test fails if Node or `curl` is called);
  - with an outside writer at a dead address, the minutes come from Apple with the "not sent" note;
  - against a local test source, the script refuses a redirect and reports the reason;
  - a Standard source (Ollama) and a Claude API source with the user's key each write minutes for a synthetic transcript.
- **Your voice:** a recorded 90 s sample makes "Me" appear in a room recording without any call.
- **The user, without help, on the final build:**
  - records a video call and an in-person conversation and reads labelled transcripts;
  - pauses, resumes and stops from the window's top bar, then plays a meeting there;
  - transcribes a spare meeting again with "2" people in the room and tidying off;
  - redoes a spare meeting's minutes with an outside model;
  - switches the transcriber to Apple and back.

## 9. Risks

- **The voice print rests on one day of audio and one microphone.** The 0.60 bar left about 0.25 of headroom on each side.
- **One-example rules:**
  - The rule that turns a call-side over-split into plain "Them" rests on one example. The people count is the user's override.
  - Ultra invented one phrase in 36 minutes, during a run of "yeah"s.
- **Ollama silently cuts a transcript longer than its context window.**
  - The token check catches large cuts.
  - The README's Ollama example sets a 64K context.
- **On another Mac:**
  - Swift Package Manager may fail there. Apple's transcriber is the fallback.
  - If macOS clears Core ML's cache, the next run spends about 30 s preparing the model again.
- **Node:**
  - an nvm version switch or removal breaks outside minutes until setup runs again;
  - other users of the public project need Node for outside models.
- **The router's provider classification** rests on provider message text. An unclassified quota error reads as a rate limit, so the note's reason may say "rate limited" when the quota is spent.

## 10. Calls Claude made for the user to check

- Every outside source counts as leaving the Mac, even one at `127.0.0.1`.
- Hosts shown to the user are the ones parsed by the address rule.
- A failed Parakeet build keeps the working helper and models it had.
- The minutes view shows links as plain text.
- With tidying off, lines follow today's merging, with speaker labels added.
- A recorded voice sample replaces a learnt print.
- Choosing another meeting stops playback.
- The meeting page's "Play audio" becomes "Open in QuickTime Player".
- Node is found on the app's PATH, then Homebrew, then nvm. Without it, setup offers Homebrew.
