import Foundation

/// Which build of meetingbox this is, from its Info.plist, where setup's `build_app` writes it: the
/// version (`CFBundleShortVersionString`), the time it was built as YYYYMMDDHHMM (`CFBundleVersion`),
/// a hash of the source it was built from (`MBSourceHash`) and, for a build from a git checkout,
/// the commit (`MBCommit`). Shown as one line in About meetingbox, at the foot of Preferences and
/// as the last line of the menu bar item's menu; `meetingbox version` prints the same line from
/// the same keys. Foundation only, so it is tested without the app.
struct BuildInfo: Equatable {
    let version: String
    /// "YYYY-MM-DD HH:MM", from a build time of exactly 12 digits; nil for a build not stamped.
    let built: String?
    /// At least 7 characters, or nil.
    let sourceHash: String?
    let commit: String?

    /// Nil without a version.
    init?(_ info: [String: Any]?) {
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
        self.version = version
        let stamp = Array(info?["CFBundleVersion"] as? String ?? "")
        if stamp.count == 12, stamp.allSatisfy({ $0.isASCII && $0.isNumber }) {
            func part(_ from: Int, _ to: Int) -> String { String(stamp[from..<to]) }
            built = "\(part(0, 4))-\(part(4, 6))-\(part(6, 8)) \(part(8, 10)):\(part(10, 12))"
        } else {
            built = nil
        }
        let hash = info?["MBSourceHash"] as? String ?? ""
        sourceHash = hash.count >= 7 ? hash : nil
        let commit = info?["MBCommit"] as? String ?? ""
        self.commit = commit.isEmpty ? nil : commit
    }

    /// This app's own build.
    static let main = BuildInfo(Bundle.main.infoDictionary)

    /// "meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4, 9602459)", with the commit only when
    /// known, and the version alone for a build that was not stamped.
    var line: String {
        guard let built = built, let hash = sourceHash else { return "meetingbox \(version)" }
        let commitPart = commit.map { ", \($0)" } ?? ""
        return "meetingbox \(version) (build \(built), \(hash.prefix(7))\(commitPart))"
    }
}
