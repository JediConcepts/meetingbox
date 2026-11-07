# STATUS: meetingbox

Updated 7 Nov 2026 by Claude, from the repo. Whoever drives next rewrites this page before stopping.

## State
- meetingbox records a meeting, transcribes it and writes minutes, all on the Mac. Nothing leaves the machine. Current version is v1.3.1 (`VERSION` in the `meetingbox` script).
- Stage 1 of the 2.0 design shipped as v1.3.0 and v1.3.1 on 29 Oct 2026: separate mic and call channels, pause and resume, Me and Them transcripts, echo removal, a stable local signing certificate, start, stop and done sounds.
- One script does setup: `install.sh` puts `meetingbox` on the PATH and hands over to `meetingbox setup`, which checks prerequisites and offers to install them.
- The stage 2 plan (the Mac app: menu bar, floating button, window, library, rename) was written on 29 Oct and is the last commit. No stage 2 code is in the repo yet.
- The design spec says "Status: awaiting Jamie's approval" and marks the choices Claude made as "(my call)".

## Next actions
1. Jamie: approve or change the spec in `docs/superpowers/specs/2026-10-28-meetingbox-app-and-speakers-design.md`, especially the "(my call)" items.
2. Jamie: confirm v1.3.1 works on your Mac end to end (setup, a real call, minutes), since signing and permissions can only be checked on real hardware.
3. Claude: build stage 2 from `docs/superpowers/plans/2026-10-29-stage2-the-app.md`, task by task, ending at version 2.0.0.
4. Claude: then stage 3, speaker diarisation for in person and speakerphone meetings (sherpa-onnx, offline, plus a voice sample to pick out Me), as set out in the spec.
5. Claude: keep every new tool behind `meetingbox setup`, so the user never installs anything by hand.

## Blockers
- Spec approval from Jamie before stage 2 starts.
- Open question for Jamie: the plan checkboxes for stage 1 are all still unticked although stage 1 shipped. Should they be ticked, or is anything in stage 1 unfinished?
- Open question for Jamie: is diarisation (stage 3) more urgent than the app (stage 2)? The spec orders the app first.

## Money
- Not revenue yet. The README presents it as a free, MIT licensed public tool with no account and no per seat fee.
- Open question for Jamie: is meetingbox meant to earn, for example as a showcase for consulting, or stay a free tool?

## Read next
- `README.md`: install, use, outputs, commands, troubleshooting.
- `docs/superpowers/specs/2026-10-28-meetingbox-app-and-speakers-design.md`: the 2.0 design and delivery stages.
- `docs/superpowers/plans/2026-10-29-stage2-the-app.md`: the next build plan.
