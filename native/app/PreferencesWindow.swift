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

    /// In front, with the microphones listed afresh (one may have been plugged in since) and no
    /// complaint left over from last time.
    func show() {
        model.clearFolderProblem()
        model.refreshMicrophones()
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
                if let problem = app.folderProblem {
                    Text(problem).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 480)
    }
}
