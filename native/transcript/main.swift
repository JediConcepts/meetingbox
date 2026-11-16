// mb-transcript --mic F --call F [--mic-speakers F] [--call-speakers F] [--mic-count N] [--call-count N]
//               [--voice F] [--learn ID] [--plain] [--me-name NAME]
// prints the transcript, its lines labelled Me, Room N, Them, Them N or Unknown (spec 6.2). Lines follow
// sentences, with short replies inline and fillers dropped; with --plain (tidying off), a new line
// starts at every change of label and every word is kept. With --learn (first processing only), a call
// may add to the voice print in --voice. With --me-name, every line that would say Me says NAME instead
// (the engine has checked it); nothing else changes.
// Warnings go to stderr with an "mb-transcript: " prefix; the meeting's log lines go there without one.
//
// mb-transcript --one FILE [--one-speakers FILE] [--one-count N] [--voice FILE] [--plain] [--me-name NAME]
// prints the transcript of a recording kept as one file, in the same timed lines, labelled Me (by the
// microphone side's rules: a print match with 10 s of talk), Speaker 1, Speaker 2 and so on (everyone else, in the order they first spoke)
// or Unknown (words no speaker covers, or every word with no speakers file). --one-count 1 gives every line
// one label. It never learns the voice, and takes none of the options for two sides or a sample.
//
// mb-transcript --voice-sample F --voice V
// makes the voice print V from a recorded sample's speakers file F, replacing any print, and prints
// `sample <seconds>`. It takes no --me-name. A refusal is one line on stderr, in Preferences' words, and exit 1, writing nothing.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mb-transcript: \(message)\n".utf8))
    exit(1)
}
func warn(_ message: String) { FileHandle.standardError.write(Data("mb-transcript: \(message)\n".utf8)) }
func log(_ line: String) { FileHandle.standardError.write(Data("\(line)\n".utf8)) }

let usage = "usage: mb-transcript --mic FILE --call FILE [--mic-speakers FILE] [--call-speakers FILE] [--mic-count N] "
    + "[--call-count N] [--voice FILE] [--learn ID] [--plain] [--me-name NAME], or mb-transcript --one FILE [--one-speakers FILE] "
    + "[--one-count N] [--voice FILE] [--plain] [--me-name NAME], or mb-transcript --voice-sample FILE --voice FILE"
var samplePath: String?
var micPath: String?
var callPath: String?
var micSpeakersPath: String?
var callSpeakersPath: String?
var micCount: Int?
var callCount: Int?
var onePath: String?
var oneSpeakersPath: String?
var oneCount: Int?
var voicePath: String?
var learnID: String?
var plain = false
var meName: String?
var args = Array(CommandLine.arguments.dropFirst())
func value() -> String {
    guard !args.isEmpty else { fail(usage) }
    return args.removeFirst()
}
func count() -> Int {
    guard let n = Int(value()), (1...6).contains(n) else { fail(usage) }
    return n
}
while !args.isEmpty {
    switch args.removeFirst() {
    case "--mic": micPath = value()
    case "--call": callPath = value()
    case "--mic-speakers": micSpeakersPath = value()
    case "--call-speakers": callSpeakersPath = value()
    case "--mic-count": micCount = count()
    case "--call-count": callCount = count()
    case "--one": onePath = value()
    case "--one-speakers": oneSpeakersPath = value()
    case "--one-count": oneCount = count()
    case "--voice": voicePath = value()
    case "--learn": learnID = value()
    case "--plain": plain = true
    case "--me-name": meName = value()
    case "--voice-sample": samplePath = value()
    default: fail(usage)
    }
}

// A recording kept as one file takes none of the options for two sides, learning or a sample; and its own
// options need it.
let sideOptions = micPath != nil || callPath != nil || micSpeakersPath != nil || callSpeakersPath != nil || micCount != nil
    || callCount != nil || learnID != nil || samplePath != nil
if onePath != nil && sideOptions { fail(usage) }
if onePath == nil && (oneSpeakersPath != nil || oneCount != nil) { fail(usage) }

// A recorded sample: nothing else is read, and only the print is written.
if let samplePath = samplePath {
    guard let voicePath = voicePath, micPath == nil, callPath == nil, micSpeakersPath == nil, callSpeakersPath == nil,
          micCount == nil, callCount == nil, learnID == nil, !plain, meName == nil else { fail(usage) }
    switch saveSample(speakers: FileManager.default.contents(atPath: samplePath), from: samplePath,
                      voice: URL(fileURLWithPath: voicePath), now: Date()) {
    case .saved(let seconds):
        print("sample \(seconds)")
        exit(0)
    case .refused(let line):
        log(line)
        exit(1)
    case .failed(let reason):
        fail(reason)
    }
}

/// A missing, empty or unreadable file counts as no words, so one bad side
/// still leaves the other side's transcript. Word ends are capped as they load.
func words(_ path: String?) -> [Word] {
    guard let path = path, let data = FileManager.default.contents(atPath: path) else { return [] }
    do { return capEnds(try loadWords(data)) } catch {
        warn("cannot read \(path), carrying on without it: \(error)")
        return []
    }
}

/// A speakers file, for `place` ("on the call side", "in the recording"). Missing or unreadable, that place is
/// left unlabelled (Me, or Them, on a side; Unknown in a recording kept as one file), with a warning.
func speakers(_ path: String?, _ place: String) -> SideSpeakers? {
    guard let path = path else { return nil }
    do {
        guard let data = FileManager.default.contents(atPath: path) else { throw TranscriptError(description: "no such file") }
        let s = try loadSpeakers(data)
        return SideSpeakers(model: s.model, segments: s.segments, speakers: s.speakers)
    } catch {
        warn("cannot read \(path), carrying on without speaker labels \(place): \(error)")
        return nil
    }
}

// 1. Load, capping word ends. A count of 1 means no labels on that side. A recording kept as one file
// keeps its speakers with a count of 1 too: whether its one person is you takes their voice.
let mic = words(micPath)
let call = words(callPath)
let micSpeakers = micCount == 1 ? nil : speakers(micSpeakersPath, "on the microphone side")
let callSpeakers = callCount == 1 ? nil : speakers(callSpeakersPath, "on the call side")
let one = words(onePath)
let oneSpeakers = speakers(oneSpeakersPath, "in the recording")

// The voice print as read, and what the file was then, so it is written back only if unchanged.
var voice: VoicePrint?
var voiceState: FileState?
var voiceReadable = true
let voiceURL = voicePath.map { URL(fileURLWithPath: $0) }
if let url = voiceURL, let state = fileState(at: url) {
    voiceState = state
    do {
        guard state.regular else { throw TranscriptError(description: "not a plain file") }
        voice = try decodePrint(state.contents)
    } catch {
        voiceReadable = false
        warn("cannot read your voice print \(url.path), so it is not used or learnt: \(error)")
    }
}

// A recording kept as one file: its labels and lines, and nothing learnt.
if onePath != nil {
    let labelled = labelOne(one, speakers: oneSpeakers, print: voice, onePerson: oneCount == 1,
                            counted: (oneCount ?? 0) >= 2)
    labelled.log.forEach(log)
    let turns = transcriptLines(renameMe(labelled, to: meName), plain: plain)
    if turns.isEmpty { fail("no speech found in the recording") }
    print(render(turns), terminator: "")
    exit(0)
}

// 2 to 7. Candidates, print matches, echo, names, labels.
let labelled = labelWords(mic: mic, call: call, micSpeakers: micSpeakers, callSpeakers: callSpeakers, print: voice,
                          micCounted: (micCount ?? 0) >= 2, callCounted: (callCount ?? 0) >= 2)
labelled.log.forEach(log)

// 8. Learn, then save or discard only if the file is unchanged.
if let source = learnID, let url = voiceURL, voiceReadable, micSpeakers != nil, !labelled.model.isEmpty {
    let (outcome, reason) = learnWithReason(voice, mic: labelled.micSpeakers, keptWords: labelled.micKept, call: labelled.callSpeakers,
                                            isCall: labelled.isCall, model: labelled.model, source: source, now: Date())
    learnLog(reason).forEach(log)
    let changed = "Your voice print changed while this meeting was processed, so it was left as it is"
    do {
        switch outcome {
        case .unchanged: break
        case .write(let print):
            if !(try savePrintIfUnchanged(print, at: url, readState: voiceState)) { log(changed) }
        case .discard:
            if try discardPrintIfUnchanged(at: url, readState: voiceState) {
                log("That is two calls in a row, so the voice learnt so far is discarded and will be learnt again from later calls")
            } else { log(changed) }
        }
    } catch {
        warn("could not save your voice print: \(error)")
    }
}

// 9 and 10. Lines, then the transcript.
let turns = transcriptLines(renameMe(labelled, to: meName), plain: plain)
if turns.isEmpty { fail("no speech found on either channel") }
print(render(turns), terminator: "")
