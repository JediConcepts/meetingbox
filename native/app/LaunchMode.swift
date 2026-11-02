import Foundation

/// What this executable runs as, chosen before anything else from its first argument and the name
/// it was started under. The recorder helper is a bundle of its own with a copy of this same
/// executable, so LaunchServices, Spotlight or a click can open it with no arguments. It must then
/// refuse: run as the whole app it would take the app's lock, so the real app could not start, and
/// it could process nothing.
enum LaunchMode: Equatable {
    case record
    case recover
    case app
    /// The helper started with no mode.
    case refuse

    /// Printed to stderr by a refused helper, which then exits `refusalExit`.
    static let refusal = "this is meetingbox's recorder; open meetingbox.app instead"
    /// EX_USAGE.
    static let refusalExit: Int32 = 64

    /// `arguments` are those after the program name. The helper is told by its executable name.
    static func choose(arguments: [String], executableName: String) -> LaunchMode {
        switch arguments.first {
        case "--record": return .record
        case "--recover": return .recover
        default: return executableName == ChildRecorder.helperName ? .refuse : .app
        }
    }

    /// The name this process was started under: its executable's.
    static var currentExecutableName: String {
        Bundle.main.executableURL?.lastPathComponent
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
    }
}
