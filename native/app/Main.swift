import AppKit
import Foundation

// One executable, three modes, chosen by the first argument before anything else (LaunchMode):
//   --record [options]   the recorder (native/recorder/Recorder.swift)
//   --recover <dir>      finish an interrupted recording
//   anything else        the app
// The recorder and recovery never touch AppKit, so they never show in the Dock
// (Info.plist has LSUIElement). Started with no mode from the recorder helper bundle
// (meetingbox-recorder), it is not the app: it says so and exits.
@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch LaunchMode.choose(arguments: arguments, executableName: LaunchMode.currentExecutableName) {
        case .record:
            let rest = Array(arguments.dropFirst())
            Task { await runRecorder(rest) }
            dispatchMain()
        case .recover:
            runRecover(Array(arguments.dropFirst()))
        case .refuse:
            fputs(LaunchMode.refusal + "\n", stderr)
            exit(LaunchMode.refusalExit)
        case .app:
            runApp()
        }
    }

    /// NSApplication runs on the main thread, so this is plain synchronous code
    /// called from main(), not an async entry point.
    @MainActor
    private static func runApp() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate   // a weak reference, so the run keeps it alive
        withExtendedLifetime(delegate) { app.run() }
    }
}
