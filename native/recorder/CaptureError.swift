import Foundation

/// Why system audio (the call side, through ScreenCaptureKit) could not start, and what the
/// recorder says about it. Foundation only, so it is tested without capturing anything.
enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for audio capture"
        }
    }

    /// The recorder's reason when system audio does not start. The app shows its last line. No
    /// display means the screen is asleep or locked, not that a permission is missing, so it does
    /// not send anyone to Privacy & Security.
    static func systemAudioFailure(_ error: Error) -> String {
        let advice: String
        if case .noDisplay? = error as? CaptureError {
            advice = "The screen is asleep or locked, so the call side cannot be recorded. Wake the screen and try again."
        } else {
            advice = "Grant Screen Recording permission in System Settings → Privacy & Security."
        }
        return "Failed to start system audio: \(error.localizedDescription)\n\(advice)"
    }
}
