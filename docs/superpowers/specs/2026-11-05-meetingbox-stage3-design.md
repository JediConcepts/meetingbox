# meetingbox Stage 3: notes worth reading, and a library you can work in

Status: approved by the user, 5 November 2026 ("Design looks good for now"). Builds on Stage 2 (the app: menu bar item, floating button, the meetingbox window with its library, Preferences, the New meeting button and the Recording menu). Stage 2 is not finished yet; Stage 3 starts after it ships.

**Relation to the original design** (docs/superpowers/specs/2026-10-28-meetingbox-app-and-speakers-design.md): its delivery order was 3 Speakerphone (diarisation and the voice sample) and 4 People (participants, calendar fill-in, mapping labels to names, names in the minutes). This design takes over stage 4's people and calendar parts, adds the notes writer, Redo and the player, and comes first. Speakerphone becomes the stage after it; its tool choice is reopened by the speaker detection research of 5 November (Argmax SpeakerKit against the original's sherpa-onnx; Swift packages also build on this Mac again, which reopens FluidAudio), to be settled by a hands-on test.

## 1. Why

The recordings and transcripts are good. The notes are not. An analysis of six recent calls (2 to 4 November) found:

- **The transcripts held every important point.** A careful reader recovered all 83 key points from the six transcripts.
- **The minutes step lost two thirds of them** (55 of 83) and added 192 mistakes: chat filed as decisions, owners reversed, quotation marks round words nobody said, and invented items.
- **Most of that is how meetingbox uses Apple's on-device model**, not the model alone: plainer instructions took the share of points caught from about 16% to about 53% on the same passages. But even at its best the 3 billion parameter model, with a window of about 4,000 tokens, catches only about half of what matters and gets owners and agreement wrong.
- **The notes step has almost no context.** It does not know who "Them" is, what the call was for, or that a recording may be an in-room conversation rather than a call.

The user's decisions:
- **Private by default.** The on-device model stays the default notes writer, improved with what the analysis showed works, and nothing leaves the Mac unless the user chooses.
- **An outside model on demand, or by default once switched on.** Any meeting can be sent to an outside model for its notes. A Preferences switch, off by default, makes the chosen outside model the default writer for new meetings.
- **Any standard endpoint.** The outside model is reached through a standard chat endpoint the user sets up. The user's own Local CLI Bridge (public on GitHub and npm) serves exactly that: it hands each request to Claude Code or Codex under the user's own subscription, or to a local model through its command mode. The user's AI Execution Router (also public) is the other option they named.

The full analysis, and the six calls cleared by the user as private test material, are kept on the Mac at `~/Library/Application Support/meetingbox-eval/` (not in the repository; not synced).

## 2. Goals

1. **Notes that are right and useful:** every important point of a call, owners and agreement stated only as far as the call shows them, nothing invented, and every item traceable to its moment in the recording.
2. **Context for each meeting:** who was there, which side each person was on, what the meeting was, taken from the calendar when there is an entry, and easy to fill in or correct by hand when there is not.
3. **The user chooses where the notes are written,** per meeting and by default, and meeting content never leaves the Mac without that choice.
4. **Redo:** the notes, or the transcript and the notes, can be made again at any time, without losing what was there before.
5. **Listen in the window:** a proper player for a meeting's audio, tied to the transcript and the notes.

## 3. Non-goals for this stage

- **Telling voices apart on one channel** (two people in the room on the mic, several people on the far side of a call). Research is under way; it becomes its own design after a hands-on test. This stage must not block it: the info file and the notes already allow more than one person per side.
- Sharing, exporting or sending notes anywhere (email, CRM, Docs).
- Editing transcripts by hand.
- Any change to recording, crash safety or finalising, which Stage 2 settled.
- Building or hosting a model service: meetingbox only calls an endpoint the user already runs.

## 4. Anti-goals: failure even if it works

- Notes that state something that did not happen: a decision nobody agreed, an action with the wrong owner, a quotation nobody said.
- Any loss or overwrite of meeting data. A redo that cannot be undone.
- Meeting content leaving the Mac without the user choosing that, or going anywhere other than the endpoint the user set.
- A recording slowed, interrupted or polluted by anything in this stage (for example, playback captured into a live recording).
- Having to fill anything in before notes are produced. Context improves notes; its absence must never block them.

## 5. Constraints (all of Stage 2's still apply)

- macOS 27 on Apple Silicon. The engine is bash 3.2; native code is Swift compiled with swiftc (Swift Package Manager is broken on this Mac). SwiftUI without macros (`Binding(get:set:)`, `ObservableObject`).
- Meeting folders and their audio are never deleted by meetingbox. Renames are atomic and refuse to overwrite. One owner for recording commands (the ControlHandler path); never block the main queue.
- Setup stays one command for a non-developer. meetingbox gains no Node or Python dependency of its own; the bridge, if used, is the user's own install.
- A key for the endpoint, if one is needed, is kept in the login keychain, never in a plain file.
- British English in all user-facing text. The README's promise becomes: nothing leaves the Mac unless you switch on an outside model or send a meeting to one.

## 6. What the user decided

### 6.1 The meeting info file

Each meeting folder gets a small JSON file describing the meeting, separate from `meeting.json` (which the app rewrites as a recording moves through its states; keeping them apart stops one overwriting the other).

It holds:
- **people:** each with a name, and where known an organisation or role, which side they were on (`me`, `room` for someone in the room with the user, `call` for the far side), and where the entry came from (`calendar`, `you`, or `notes` when the notes step inferred it, which counts as a guess until the user confirms it);
- **when:** start time and length;
- **kind:** call, in-room meeting, or unknown;
- **description:** a line or a paragraph;
- **calendar:** the matching calendar entry's title, description, organiser, attendees and link, if there was one;
- **privacy:** whether this meeting is kept on the Mac (see 6.3).

It is filled in when a recording starts if a calendar entry matches, and otherwise starts nearly empty. The user edits it from an Info section on the meeting's page in the window. Editing it and redoing the notes gives notes that use the new context. The title stays where Stage 2 keeps it (the folder name and `meeting.json`); the Info section's title field uses Stage 2's rename.

### 6.2 Writing the notes

- **meetingbox gathers the context itself,** then asks the chosen writer for the notes. In order: the info file; the user's people-and-terms list; the notes of earlier meetings with the same people (matched through their info files); then the whole transcript.
- **The outside model gets the whole transcript in one request** (no slicing), with one set of instructions kept in the repository. The same instructions are also packaged as a Claude Code skill, so a meeting folder can be processed by hand in Claude Code: the outside route the user asked for.
- **The on-device model** keeps slicing (its window is small) but uses the improved instructions, with a place for what was discussed, and gets the same context in a shortened form.
- **Me and Them:** Me is the user's microphone: the user, plus anyone in the room. Them is everyone on the far side of a call, mixed. The notes name Them from the info file, else from the call itself (greetings, names used, introductions), else from earlier meetings on the same topics, and otherwise write "the other person" and say so. Any inferred name is marked as a guess and written back to the info file as `notes`-sourced for the user to confirm.
- **Kinds of recording:** the notes recognise a call that is not a meeting (for example a personal call) and do not force it into decisions and actions; they recognise an in-room conversation (the call side silent) and do not attribute everything on the mic to the user.
- **The layout of the notes:**
  - Who and what: who was there and what it was for, in a line or two.
  - Summary: a short paragraph.
  - Actions: owner, task and when, each with its time in the call.
  - Decisions: only what was clearly agreed, with its time.
  - Topics: each with its key details, numbers and names.
  - Open questions.
  - Unsure: anything misheard, or where it is unclear who said what.
- **Quotations:** only words that are in the transcript go in quotation marks. Code checks every quoted span against the transcript and removes the quotation marks from any that are not there, whichever writer produced the notes.
- **brief.json** is built from the finished notes, so the two always agree.
- **The people-and-terms list** is a plain file the user can edit. It also lets the notes correct names the transcriber mishears (a name heard as an ordinary word). The writer may suggest additions; meetingbox never edits the list without the user.

### 6.3 Choosing where the notes are written

- **Preferences, "Outside model":** an on and off switch (off by default), the endpoint address, the model name (offered from the endpoint's own model list where it has one), an optional key, and a Test button that sends a tiny request and shows what came back.
- **Off (the default):** every meeting's notes are written on the Mac. Nothing leaves it. Any meeting can still be sent on demand with "Redo notes with <model>" on its page.
- **On:** new meetings' notes are written by the outside model. A meeting marked "Keep on this Mac" is written on the Mac instead. The mark can be set while recording (menu bar, Recording menu, the window's live controls) and on the meeting's page, and it is stored in the info file.
- **When the endpoint cannot be reached, or fails:** the notes are written on the Mac instead, and the meeting's page says so, with a Redo button to try the outside model again.

### 6.4 Redo

- Each meeting's page has a Redo button with three choices: **Redo the notes** (with the default writer), **Redo the notes with <model>** (the outside model, on demand), and **Redo the transcript and notes** (transcribe the audio again, then the notes).
- The same from Terminal: `meetingbox notes <folder>` (with a choice of writer) and `meetingbox redo <folder>`; and running the Claude Code skill by hand is the outside route.
- **Nothing is thrown away:** the notes, brief and transcript being replaced are kept in the folder as an earlier version before the new ones are written, and the window can show or restore an earlier version.
- A redo goes through the same processing queue as normal processing, with the same progress in the menu bar and the window. Like normal processing in Stage 2, it may run while another meeting is recording.

### 6.5 The player

- Play becomes a player bar on the meeting's page: play and pause, stop (back to the start), a timeline to drag with time played and total, volume, and speed 1x, 1.5x and 2x keeping the voice's pitch.
- It plays the combined audio (and a v1.2 meeting's single file).
- The meeting that is playing shows a speaker symbol in the list, so it can always be found and stopped.
- Clicking a transcript line jumps to that moment; each item in the notes carries its time and jumps there too.
- **Starting a recording stops playback, and Play is unavailable while recording,** because the call side of a recording captures the Mac's sound.

## 7. Left to the builder

- The info file's name and exact JSON shape (with a version field), and where the people-and-terms list lives (suggestion: in the meetings folder, so it travels with the meetings).
- How the calendar entry is matched (overlap with the recording's start; what to do with two overlapping entries) and how the Mac's calendar is read (the app reading the Mac's own Calendar, with the Calendar permission).
- The endpoint call: the standard chat completions request (`/v1/chat/completions`, as the Local CLI Bridge serves), not streamed, with a long time limit (the bridge allows 15 minutes); how a transcript too large for the model is handled; and whether the app or the engine makes the call.
- The exact instructions for both writers, tested against the gold lists in the private eval folder.
- How earlier versions are stored and named in the folder.
- Player implementation (AVFoundation) and the window layout.
- Whether setup offers to install the bridge from npm when the user switches the outside model on (it needs Node), or only points to its instructions.

## 8. How we will know it worked

- On the six calls in the private eval folder, notes from the outside model (Claude through the bridge) catch at least 80% of the key points in the gold lists, with no invented items, no reversed owners and no unverified quotations, and every item has a working time link. Notes from the on-device model with the new instructions do at least as well as the plainer instructions did in the analysis (about half the key points), with no unverified quotations.
- With the switch off, no network request is made while processing; verified by test.
- A meeting with no calendar entry and an empty info file still gets notes, with "the other person" where a name cannot be found.
- Redo leaves the previous version restorable, every time.
- The user records a call, edits the info file, redoes the notes with the outside model and listens to a moment from the notes, without help.

## 9. Open points

- **Calendar:** the user is not sure the work (Google) calendar shows in the Mac's Calendar app. Check when meetingbox first asks for the Calendar permission; if it does not, the user adds the Google account in System Settings, Internet Accounts.
- **Speaker detection:** research report due; its own design follows a hands-on test.
