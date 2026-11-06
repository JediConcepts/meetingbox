import Darwin
import Foundation

enum RenameError: Error {
    case busy
    case emptyTitle
    case exists
}

/// One meeting's folder under the Meetings root. Names are `YYYY-MM-DD_HHMM`
/// (or `_HHMMSS`, `_HHMMSS-2` on a clash) until the user gives it a title, then
/// `YYYY-MM-DD HHMM Title`. Folder names use local time. Folders are never deleted.
struct MeetingFolder {
    let url: URL
    let date: Date
    let title: String?

    // MARK: parsing

    private static let plain = try! NSRegularExpression(
        pattern: "^(\\d{4})-(\\d{2})-(\\d{2})_(\\d{2})(\\d{2})(\\d{2})?(?:-(\\d+))?$")
    private static let titled = try! NSRegularExpression(
        pattern: "^(\\d{4})-(\\d{2})-(\\d{2}) (\\d{2})(\\d{2}) (.+)$")

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
        return String(s[rr])
    }

    /// Nil for a name that is not a meeting folder's, or a date that cannot be (2026-02-31). A time the
    /// clocks skip, such as 01:30 when summer time begins, is still the meeting made then: the name came
    /// from another zone or from before the clocks changed, and it parses to the nearest real moment.
    static func parse(_ url: URL, calendar: Calendar = .current) -> MeetingFolder? {
        let name = url.lastPathComponent
        let whole = NSRange(name.startIndex..., in: name)
        var title: String? = nil
        var m = plain.firstMatch(in: name, range: whole)
        if m == nil {
            m = titled.firstMatch(in: name, range: whole)
            guard m != nil else { return nil }
            title = group(m!, 6, in: name)
        }
        guard let match = m, let y = Int(group(match, 1, in: name) ?? ""),
              let mo = Int(group(match, 2, in: name) ?? ""), let d = Int(group(match, 3, in: name) ?? ""),
              let h = Int(group(match, 4, in: name) ?? ""), let mi = Int(group(match, 5, in: name) ?? "")
        else { return nil }
        let s = title == nil ? Int(group(match, 6, in: name) ?? "0") ?? 0 : 0
        guard (0...23).contains(h), (0...59).contains(mi), (0...59).contains(s) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        guard let date = calendar.date(from: c) else { return nil }
        // Round-trip so that 2026-02-31 is refused rather than rolled into March.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == mo, back.day == d else { return nil }
        return MeetingFolder(url: url, date: date, title: title)
    }

    private static func formatter(_ format: String, locale: String = "en_US_POSIX") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = format
        return f
    }

    /// The title, or the start time as `28 October 2026, 15:08`.
    var displayTitle: String {
        if let title = title, !title.isEmpty { return title }
        return MeetingFolder.formatter("d MMMM yyyy, HH:mm", locale: "en_GB").string(from: date)
    }

    // MARK: creation

    /// Makes `YYYY-MM-DD_HHMM`, else `_HHMMSS`, else `_HHMMSS-2`, `-3` and so on.
    /// `mkdir` is the arbiter, so two callers can never be handed the same folder.
    static func create(in root: URL, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let day = formatter("yyyy-MM-dd").string(from: date)
        let hm = formatter("HHmm").string(from: date)
        let hms = formatter("HHmmss").string(from: date)
        var candidates = ["\(day)_\(hm)", "\(day)_\(hms)"]
        for n in 2...999 { candidates.append("\(day)_\(hms)-\(n)") }
        for name in candidates {
            let url = root.appendingPathComponent(name)
            if mkdir(url.path, 0o700) == 0 {
                chmod(url.path, 0o700) // mkdir honours the umask; the folder must be exactly 0700
                return url
            }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }

    // MARK: titles and renaming

    /// A title that is safe as a folder name: `/`, `:`, `\` and control characters
    /// become `-`, leading dots go, 80 characters at most. Nil when nothing is left. A final
    /// extension with a letter in it would make the Finder take the folder for a file or a package
    /// ("Q3 board deck.key" for a Keynote file), so its dot becomes `-` too ("Budget v2.0" stays).
    static func safeTitle(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            if u == "/" || u == ":" || u == "\\" || CharacterSet.controlCharacters.contains(u)
                || CharacterSet.newlines.contains(u) {
                scalars.append("-")
            } else {
                scalars.append(u)
            }
        }
        var s = String(scalars).trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 80 { s = String(s.prefix(80)).trimmingCharacters(in: .whitespaces) }
        // An extension is one word after the last dot; "Dr. Smith" and a closing full stop are not.
        if let dot = s.lastIndex(of: ".") {
            let ext = s[s.index(after: dot)...]
            if !ext.isEmpty, !ext.contains(where: \.isWhitespace), ext.contains(where: \.isLetter) {
                s.replaceSubrange(dot...dot, with: "-")
            }
        }
        return s.isEmpty ? nil : s
    }

    /// Renames to `YYYY-MM-DD HHMM Title` atomically and never over an existing item.
    /// `isBusy` is called immediately before the rename, on the caller's serial queue.
    func renamed(to rawTitle: String, isBusy: () -> Bool) throws -> MeetingFolder {
        guard let clean = MeetingFolder.safeTitle(rawTitle) else { throw RenameError.emptyTitle }
        let stamp = MeetingFolder.formatter("yyyy-MM-dd HHmm").string(from: date)
        let dest = url.deletingLastPathComponent().appendingPathComponent("\(stamp) \(clean)")
        if isBusy() { throw RenameError.busy }
        if renamex_np(url.path, dest.path, UInt32(RENAME_EXCL)) != 0 {
            let e = errno
            if e == EEXIST { throw RenameError.exists }
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        return MeetingFolder(url: dest, date: date, title: clean)
    }

    // MARK: unfinished recordings

    /// A recording the recorder has not finished: no `.recording-complete` marker, and a working
    /// `.caf` still in the folder (`recording_unfinished` in the meetingbox script says the same).
    /// Its `audio.m4a`, if there is one, is from a finalise that stopped part way. A recording from
    /// before the marker existed has neither the marker nor the working files, so it is finished.
    /// Nothing is processed or retried for an unfinished recording: it needs `meetingbox recover`.
    static func recordingUnfinished(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.appendingPathComponent(Finaliser.marker).path) else { return false }
        return Finaliser.working.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    // MARK: audio

    /// `audio.m4a`, else the newest `*_meeting.m4a`, else nil.
    var audioFile: URL? {
        let fm = FileManager.default
        let main = url.appendingPathComponent("audio.m4a")
        if fm.fileExists(atPath: main.path) { return main }
        guard let items = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return nil }
        var best: (URL, Date)? = nil
        for item in items where item.lastPathComponent.hasSuffix("_meeting.m4a") {
            let v = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard v?.isRegularFile ?? false else { continue }
            let when = v?.contentModificationDate ?? .distantPast
            if best == nil || when > best!.1 || (when == best!.1 && item.lastPathComponent > best!.0.lastPathComponent) {
                best = (item, when)
            }
        }
        return best?.0
    }
}
