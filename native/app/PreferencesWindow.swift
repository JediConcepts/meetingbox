import AppKit
import SwiftUI

// The Preferences window: a SwiftUI form in an `NSWindow` over `AppModel`'s settings. Each control
// binds with `Binding(get:set:)` to a model setter, which applies the change at once; the words and
// the rules come from `PreferencesPresentation`. The build's rules for SwiftUI: no `@State` or other
// property wrapper that keeps state, and no macros.

/// Opened from the menu's Preferences… and Cmd-comma. Closing it never quits the app.
@MainActor
final class PreferencesWindow: NSObject {
    private let model: AppModel
    private let window: NSWindow

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingController(rootView: PreferencesView(app: model, choose: {}))
        window = NSWindow(contentViewController: hosting)
        super.init()
        hosting.rootView = PreferencesView(app: model, choose: { [weak self] in self?.chooseFolder() })
        window.title = "meetingbox Preferences"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    /// In front, with the microphones and the engine's status read afresh (a microphone may have been
    /// plugged in since, or setup run) and no complaint left over from last time.
    func show() {
        model.preferencesOpened()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The Dock icon has just gone, which can send the app behind the others: an open window comes back.
    func keepInFront() {
        guard window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Choose…: a folder panel as a sheet on this window (nothing waits on it); the model checks the
    /// folder and applies it, or says why not.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.preferences.meetingsFolder
        panel.prompt = "Choose"
        panel.message = "Choose the folder meetingbox keeps your meetings in"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.model.setMeetingsFolder(url) }
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var app: AppModel
    let choose: () -> Void

    var body: some View {
        let shown = app.visibility
        let microphone = app.microphoneChoice
        let folder = app.preferences.meetingsFolder.path
        VStack(spacing: 16) {
            Form {
                Section {
                    Toggle("Show in the menu bar", isOn: Binding(get: { shown.menuBarItem }, set: { app.setShowMenuBar($0) }))
                        .disabled(shown.menuBarLocked)
                    if shown.menuBarLocked {
                        Text("Always shown while meetingbox is not in the Dock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show in the Dock", isOn: Binding(get: { shown.dockIcon }, set: { app.setShowInDock($0) }))
                    Picker("Floating button:", selection: Binding(get: { app.preferences.floating }, set: { app.setFloating($0) })) {
                        ForEach(FloatingMode.allCases, id: \.self) { mode in
                            Text(PreferencesPresentation.floatingTitle(mode)).tag(mode)
                        }
                    }
                }
                Section {
                    Toggle("Open the minutes when they are ready", isOn: Binding(get: { app.preferences.openMinutes }, set: { app.setOpenMinutes($0) }))
                    Toggle("Play sounds", isOn: Binding(get: { app.preferences.sounds }, set: { app.setSounds($0) }))
                }
                TranscriptsSection(app: app)
                Section {
                    Picker("Microphone:", selection: Binding(get: { microphone.selected }, set: { index in
                        if microphone.options.indices.contains(index) { app.setMicrophone(microphone.options[index].name) }
                    })) {
                        ForEach(Array(microphone.options.enumerated()), id: \.offset) { entry in
                            Text(entry.element.title).tag(entry.offset)
                        }
                    }
                    LabeledContent("Meetings folder:") {
                        HStack {
                            Text((folder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folder)
                            Button("Choose…", action: choose)
                                .disabled(!PreferencesPresentation.canChooseFolder(app.status.phase))
                        }
                    }
                    Text(PreferencesPresentation.folderMovesNothing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem = app.folderProblem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.columns)
            // Which build this is, at the foot, selectable so it can be copied into a report.
            if let build = BuildInfo.main {
                Text(build.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 480)
        // The voice sample's sheet, shown while a sample is under way or has an outcome to read.
        .sheet(isPresented: Binding(get: { app.sample != .idle }, set: { if !$0 { app.closeSample() } })) {
            VoiceSampleSheet(app: app)
        }
    }
}

/// "Transcripts": the transcriber, tidying, and the user's voice, between the minutes toggles and the
/// microphone. The words and the rules are `PreferencesPresentation`'s.
struct TranscriptsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Section("Transcripts") {
            Picker("Transcriber:", selection: Binding(get: { app.preferences.transcriber }, set: { app.setTranscriber($0) })) {
                ForEach(Transcriber.allCases, id: \.self) { transcriber in
                    Text(PreferencesPresentation.transcriberTitle(transcriber)).tag(transcriber)
                }
            }
            Text(PreferencesPresentation.transcriberNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let missing = app.parakeetNotSetUp {
                Text(missing)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(PreferencesPresentation.tidyTitle, isOn: Binding(get: { app.preferences.tidyLines }, set: { app.setTidyLines($0) }))
            if !app.voiceStatus.isEmpty {
                Text(app.voiceStatus)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(PreferencesPresentation.recordSampleTitle) { app.recordSample() }
                    .disabled(!app.canRecordSample)
                Button(PreferencesPresentation.forgetVoiceTitle) { app.forgetVoice() }
                    .disabled(!app.canForgetVoice)
            }
            if let problem = app.voiceProblem {
                Text(problem).foregroundStyle(.red)
            }
        }
    }
}

/// The voice sample: the countdown and Stop while it records, a line while the engine builds the
/// print, then the outcome and Done. It cannot be dismissed otherwise: Stop and Done are the way out.
struct VoiceSampleSheet: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 16) {
            switch app.sample {
            case .recording(let left):
                Text(PreferencesPresentation.sampleCountdown(secondsLeft: left))
                    .font(.title3)
                    .monospacedDigit()
                Button(PreferencesPresentation.sampleStopTitle) { app.stopSample() }
                    .keyboardShortcut(.defaultAction)
            case .building:
                ProgressView()
                Text(PreferencesPresentation.sampleBuilding)
            case .done(let text), .failed(let text):
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                Button(PreferencesPresentation.sampleDoneTitle) { app.closeSample() }
                    .keyboardShortcut(.defaultAction)
            case .idle:
                EmptyView()
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled(true)
    }
}
