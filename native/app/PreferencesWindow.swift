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
    private var observers: [NSObjectProtocol] = []

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
        // The model hears the window close, as it hears a redo sheet close: a choice still waiting there
        // then asks nothing. No queue: told on the thread that closes it (the main one).
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak model] _ in
            MainActor.assumeIsolated { model?.preferencesClosed() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

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
    /// folder and applies it, or says why not. The model is told while the panel is open, so it counts it
    /// as a sheet over Preferences.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.preferences.meetingsFolder
        panel.prompt = "Choose"
        panel.message = "Choose the folder meetingbox keeps your meetings in"
        model.folderPanelOpened()
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.model.folderPanelClosed()
                guard response == .OK, let url = panel.url else { return }
                self?.model.setMeetingsFolder(url)
            }
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
                MinutesSection(app: app)
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
        .frame(width: 520)
        // One sheet at a time, as `AppModel.preferencesSheet` says: the voice sample (while it is under way
        // or has an outcome to read), agreement to send transcripts, a source's key, or a source.
        .sheet(isPresented: Binding(get: { app.preferencesSheet != nil }, set: { if !$0 { app.closePreferencesSheet() } })) {
            switch app.preferencesSheet {
            case .sample?: VoiceSampleSheet(app: app)
            case .consent?: ConsentSheet(app: app)
            case .key?: KeySheet(app: app)
            case .source?: SourceSheet(app: app)
            case nil: EmptyView()
            }
        }
    }
}

/// "Minutes": who writes them, the line under that, and the outside sources with their keys and models.
/// The words and the rules are `PreferencesPresentation`'s and `AppModel`'s; a source is contacted only on
/// Check, on opening the picker, or on saving it.
struct MinutesSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        let options = app.writerOptions
        let sources = app.preferences.sources
        let privacy = app.privacy
        Section("Minutes") {
            LabeledContent(PreferencesPresentation.writerLabel) {
                WriterPopUp(options: options, selected: app.writerSelection, opened: { app.writerPickerOpened() }, chose: { index in
                    if options.indices.contains(index) { app.chooseWriter(options[index].writer) }
                })
            }
            ModelNameFields(app: app, origin: .preferences)
            if let notice = app.writerNotice {
                Text(notice).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text(privacy.text)
                .font(.caption)
                .foregroundStyle(privacy.amber ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let line = app.outsideRuntimeLine {
                Text(line).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if sources.isEmpty {
                Text(PreferencesPresentation.noSources)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(sources.enumerated()), id: \.element.address) { entry in
                SourceRow(app: app, index: entry.offset, source: entry.element)
            }
            Button(PreferencesPresentation.addSourceTitle) { app.beginAddSource() }
            if let problem = app.minutesProblem {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One source: its kind and address, Check, Edit… and Remove; whether it has a key, with Set… and
/// Remove; and what Check last found.
struct SourceRow: View {
    @ObservedObject var app: AppModel
    let index: Int
    let source: Source

    var body: some View {
        let known = app.keys[source.address]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PreferencesPresentation.kindTitle(source.kind))
                    Text(source.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let hint = PreferencesPresentation.addressHint(source.address) {
                        Text(hint).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button(PreferencesPresentation.checkTitle) { app.refreshListing(at: index) }
                Button(PreferencesPresentation.editSourceTitle) { app.beginEditSource(at: index) }
                Button(PreferencesPresentation.removeTitle) { app.removeSource(at: index) }
            }
            HStack {
                if let line = PreferencesPresentation.keyLine(known) {
                    Text(line).font(.caption)
                }
                Button(PreferencesPresentation.setKeyTitle) { app.beginKey(at: index) }
                    .controlSize(.small)
                Button(PreferencesPresentation.removeTitle) { app.removeKey(for: source.address) }
                    .controlSize(.small)
                    .disabled(known == false)
            }
            if let problem = app.keyProblems[source.address] {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let found = PreferencesPresentation.listingLine(app.listings[source.address]) {
                Text(found).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A Model name field, "at <host>" and Use, for each source that lists no models or cannot list them.
/// The name is chosen where the field is: in Preferences, or in a redo sheet.
struct ModelNameFields: View {
    @ObservedObject var app: AppModel
    let origin: ConsentOrigin

    var body: some View {
        ForEach(app.preferences.sources.filter { PreferencesPresentation.showsModelField(app.listings[$0.address]) }, id: \.address) { source in
            HStack {
                TextField(PreferencesPresentation.modelNameLabel, text: Binding(get: { app.modelNames[source.address] ?? "" },
                                                                                set: { app.setModelName($0, for: source.address) }))
                    .onSubmit { app.useModelName(for: source.address, origin: origin) }
                Text(PreferencesPresentation.atHost(source.address)).foregroundStyle(.secondary)
                Button(PreferencesPresentation.useModelTitle) { app.useModelName(for: source.address, origin: origin) }
            }
        }
    }
}

/// "Write the minutes with" as an AppKit pop-up button, so the app is told the moment its menu opens
/// (`NSPopUpButton.willPopUpNotification`): opening the picker is one of the three times sources are
/// listed, and a SwiftUI Picker does not say when it opens. Its items are the options, disabled where
/// they cannot be chosen; choosing one hands its index back.
struct WriterPopUp: NSViewRepresentable {
    let options: [WriterOption]
    let selected: Int
    let opened: () -> Void
    let chose: (Int) -> Void

    @MainActor
    final class Coordinator: NSObject {
        var opened: () -> Void = {}
        var chose: (Int) -> Void = { _ in }
        var observer: NSObjectProtocol?

        @objc func choose(_ sender: NSPopUpButton) { chose(sender.indexOfSelectedItem) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        let coordinator = context.coordinator
        button.target = coordinator
        button.action = #selector(Coordinator.choose(_:))
        coordinator.observer = NotificationCenter.default.addObserver(forName: NSPopUpButton.willPopUpNotification, object: button,
                                                                      queue: nil) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.opened() }
        }
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.opened = opened
        context.coordinator.chose = chose
        let shown = button.itemArray.map { "\($0.isEnabled ? 1 : 0)\($0.title)" }
        if shown != options.map({ "\($0.available ? 1 : 0)\($0.title)" }) {
            button.removeAllItems()
            for option in options {
                // Added to the menu, not with addItem(withTitle:), which drops an item of the same title.
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.isEnabled = option.available
                button.menu?.addItem(item)
            }
        }
        if options.indices.contains(selected), button.indexOfSelectedItem != selected { button.selectItem(at: selected) }
    }

    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        coordinator.observer = nil
    }
}

/// Agreement before anything leaves the Mac, from Preferences or (over the redo sheet) from the window:
/// the title, the text, Cancel and "Send transcripts to <host>".
struct ConsentSheet: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let request = app.consent {
                let host = PreferencesPresentation.shownHost(request.writer.address)
                Text(PreferencesPresentation.consentTitle(host: host)).font(.headline)
                Text(PreferencesPresentation.consentText(address: request.writer.address))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(PreferencesPresentation.consentCancel) { app.cancelConsent() }
                        .keyboardShortcut(.cancelAction)
                    Button(PreferencesPresentation.consentButton(host: host)) { app.agree() }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Set…: a key for one source, typed out of sight and handed to the engine on stdin. The sheet waits
/// while the engine stores it, and says why when it could not.
struct KeySheet: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft = app.keyDraft {
                Text(PreferencesPresentation.keySheetTitle(host: PreferencesPresentation.shownHost(draft.address))).font(.headline)
                SecureField(PreferencesPresentation.keyLabel, text: Binding(get: { app.keyDraft?.text ?? "" }, set: { app.keyText($0) }))
                    .disabled(draft.saving)
                    .onSubmit { app.saveKey(app.keyDraft?.text ?? "", for: draft.address) }
                if let problem = draft.problem {
                    Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(PreferencesPresentation.cancelTitle) { app.cancelKey() }
                        .keyboardShortcut(.cancelAction)
                    Button(PreferencesPresentation.setKeyButton) { app.saveKey(app.keyDraft?.text ?? "", for: draft.address) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.saving)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Add… and Edit…: a source's kind and address. Add… starts at the Claude API's own address.
struct SourceSheet: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft = app.sourceDraft {
                Text(PreferencesPresentation.sourceSheetTitle(adding: draft.editing == nil)).font(.headline)
                Picker(PreferencesPresentation.kindLabel, selection: Binding(get: { app.sourceDraft?.kind ?? .claude },
                                                                             set: { kind in app.updateSourceDraft { $0.kind = kind } })) {
                    ForEach(PreferencesPresentation.kinds, id: \.self) { kind in
                        Text(PreferencesPresentation.kindTitle(kind)).tag(kind)
                    }
                }
                TextField(PreferencesPresentation.addressLabel, text: Binding(get: { app.sourceDraft?.address ?? "" },
                                                                              set: { text in app.updateSourceDraft { $0.address = text } }))
                    .onSubmit { app.saveSourceDraft() }
                if let hint = draft.hint {
                    Text(hint).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let problem = draft.problem {
                    Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(PreferencesPresentation.cancelTitle) { app.cancelSourceDraft() }
                        .keyboardShortcut(.cancelAction)
                    Button(PreferencesPresentation.sourceSheetButton(adding: draft.editing == nil)) { app.saveSourceDraft() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// "Transcripts": the transcriber, tidying, your name in place of Me, and the user's voice, between the minutes toggles and the
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
            // Saved only on commit: Return, or the field losing focus (the end of editing).
            TextField(PreferencesPresentation.yourNameLabel, text: Binding(get: { app.userNameText }, set: { app.editUserName($0) }),
                      onEditingChanged: { editing in if !editing { app.commitUserName() } }, onCommit: { app.commitUserName() })
            if let problem = app.userNameProblem {
                Text(problem).foregroundStyle(.red)
            }
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
