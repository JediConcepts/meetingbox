import AppKit
import SwiftUI

// The meetingbox window: a sidebar of meetings and, beside it, the selected meeting's minutes or
// transcript (any version of it, read only), with the rename and redo sheets. A SwiftUI
// `NavigationSplitView` in an `NSWindow`, drawing `LibraryModel` and deciding
// nothing: every word, badge and action comes from `LibraryPresentation`. The views take the model as
// an `@ObservedObject` and bind to it with `Binding(get:set:)`; the build's rules for SwiftUI are no
// `@State` or other property wrapper that keeps state, and no macros.

/// The window itself. Closing it never quits the app; "Open meetingbox", the Dock icon and a second
/// launch bring it back.
@MainActor
final class LibraryWindow: NSObject {
    private let window: NSWindow
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel) {
        let hosting = NSHostingController(rootView: LibraryView(model: model.library, app: model))
        hosting.title = "meetingbox"
        hosting.sizingOptions = [] // the window's size is the user's (saved below), not the content's
        // The view's toolbar (New meeting) becomes the window's; the title stays the one set below.
        if #available(macOS 14.0, *) { hosting.sceneBridgingOptions = [.toolbars] }
        window = NSWindow(contentViewController: hosting)
        super.init()
        window.title = "meetingbox"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 980, height: 640))
        window.contentMinSize = NSSize(width: 720, height: 420)
        // Centred first, then the saved frame: where the user left it wins, and the first open is centred.
        window.center()
        window.setFrameAutosaveName("meetingbox.library")
        // Read again whenever it becomes the window in front: what a job or another process did meanwhile shows.
        // No queue: told on the thread that made it key (the main one).
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { [weak model] _ in
            MainActor.assumeIsolated { model?.library.reload() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// In front of every other window, whatever app was in front.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    let app: AppModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
        } detail: {
            // The redo sheet hangs here, so that it and the rename sheet are on different views.
            LibraryDetail(model: model, app: app)
                .sheet(isPresented: Binding(get: { model.redoing != nil }, set: { if !$0 { model.cancelRedo() } })) {
                    RedoSheet(model: model, app: app)
                }
        }
        .frame(minWidth: 720, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                TopBarControls(app: app, player: app.player, library: model)
            }
            ToolbarItem(placement: .primaryAction) {
                NewMeetingButton(app: app)
            }
        }
        .sheet(isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.cancelRename() } })) {
            RenameSheet(model: model)
        }
    }
}

/// The top bar beside New meeting (spec 6.6), as `AppModel.topBar` (TopBarPresentation) has it: while a
/// recording runs or is paused, its time, Pause or Resume, and Stop, the menu bar's own actions through
/// `AppModel.perform`, whichever meeting is selected; and the selected meeting's player: Play or Pause,
/// Stop, a slider and the position, or why it cannot be played. Only this view follows the player, so
/// the rest of the window is not redrawn every second while a meeting plays.
struct TopBarControls: View {
    @ObservedObject var app: AppModel
    @ObservedObject var player: Player
    @ObservedObject var library: LibraryModel

    var body: some View {
        let bar = app.topBar
        HStack(spacing: 10) {
            if let recording = bar.recording {
                Text(recording.timer)
                    .monospacedDigit()
                    .foregroundStyle(.red)
                Button(recording.toggle.title) { app.perform(recording.toggleAction) }
                    .disabled(!recording.toggle.enabled)
                Button(recording.stop.title) { app.perform(recording.stopAction) }
                    .disabled(!recording.stop.enabled)
            }
            if let playback = bar.player {
                Button {
                    app.togglePlayer()
                } label: {
                    Label(playback.toggle.title, systemImage: playback.playing ? "pause.fill" : "play.fill")
                }
                .labelStyle(.iconOnly)
                .help(playback.toggle.title)
                .disabled(!playback.toggle.enabled)
                Button {
                    app.stopPlayer()
                } label: {
                    Label(playback.stop.title, systemImage: "stop.fill")
                }
                .labelStyle(.iconOnly)
                .help(playback.stop.title)
                .disabled(!playback.stop.enabled)
                Slider(value: Binding(get: { playback.value }, set: { app.seekPlayer(to: $0) }), in: 0...playback.length)
                    .frame(width: 160)
                    .disabled(!playback.canSeek)
                Text(playback.problem ?? playback.position)
                    .monospacedDigit()
                    .foregroundStyle(playback.problem == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
        }
    }
}

/// New meeting, at the top of the window: the menus' Start recording, through `AppModel.newMeeting`,
/// enabled only while nothing is recording (the top bar's recording controls cover Pause and Stop).
/// Only this view and the top bar follow the app's changes, so the rest of the window is not redrawn
/// every second.
struct NewMeetingButton: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Button {
            app.newMeeting()
        } label: {
            Label(app.newMeetingTitle, systemImage: "record.circle")
        }
        .labelStyle(.titleAndIcon)
        .disabled(!app.canStartNewMeeting)
        .help("Start recording a new meeting")
    }
}

// MARK: sidebar

struct LibrarySidebar: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search meetings", text: Binding(get: { model.searchText }, set: { model.search($0) }))
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(model.rows) { row in
                    LibraryRowView(row: row).tag(row.id)
                }
            }
            .overlay {
                if model.hasScanned && model.rows.isEmpty {
                    Text(model.meetings.isEmpty ? "No meetings yet" : "No meetings match")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
    }
}

struct LibraryRowView: View {
    let row: LibraryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title).lineLimit(1)
            HStack(spacing: 6) {
                if !row.caption.isEmpty {
                    Text(row.caption).foregroundStyle(.secondary)
                }
                if let badge = row.badge {
                    BadgeView(badge: badge)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

struct BadgeView: View {
    let badge: LibraryBadge

    var body: some View {
        Text(badge.text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private var tint: Color {
        switch badge {
        case .recording: return .red
        case .paused, .failed: return .orange
        case .finalising, .queued, .processing, .unprocessed: return .secondary
        }
    }
}

// MARK: detail

struct LibraryDetail: View {
    @ObservedObject var model: LibraryModel
    let app: AppModel

    var body: some View {
        if let meeting = model.selectedMeeting {
            let row = model.row(meeting)
            let actions = model.actions(for: meeting)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(.title2).bold().lineLimit(2)
                    Text(subtitle(row)).foregroundStyle(.secondary)
                    // In full and selectable: one may be a command to copy into Terminal.
                    ForEach(model.notes(for: meeting), id: \.self) { note in
                        Text(note).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                HStack {
                    ForEach(actions, id: \.self) { action in
                        Button(action.title) { model.perform(action) }
                    }
                }
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.secondary)
                }
                if actions.contains(.pause) || actions.contains(.resume) {
                    RecordingTimer(app: app)
                } else {
                    HStack {
                        Picker("", selection: Binding(get: { model.pane }, set: { model.pane = $0 })) {
                            ForEach(LibraryModel.Pane.allCases, id: \.self) { pane in
                                Text(pane.title).tag(pane)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        if model.pane == .transcript {
                            VersionPicker(model: model)
                        }
                    }
                    LibraryText(pane: model.pane, content: model.shownContent)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if model.hasScanned {
            Text(model.meetings.isEmpty ? "No meetings yet" : "Select a meeting")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The caption and the badge, as the row has them.
    private func subtitle(_ row: LibraryRow) -> String {
        [row.caption, row.badge?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Which transcript the Transcript view shows: Current, another transcript in the folder, or an earlier
/// version, read only, when `LibraryModel.versionChoices` offers any.
struct VersionPicker: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        if let current = model.versionChoices.first {
            Picker("", selection: Binding(get: { model.version ?? current.url }, set: { model.chooseVersion($0) })) {
                ForEach(model.versionChoices, id: \.url) { version in
                    Text(version.title).tag(version.url)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// The time recorded so far. Only this view follows the clock, so the rest of the window is not
/// redrawn every second.
struct RecordingTimer: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Text(Preferences.timerText(app.status.seconds))
            .font(.system(size: 44, weight: .light, design: .rounded))
            .monospacedDigit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The minutes (inline markdown, drawn) or the transcript (plain, monospaced). Read only, selectable.
struct LibraryText: View {
    let pane: LibraryModel.Pane
    let content: LibraryModel.Content?

    var body: some View {
        ScrollView {
            Group {
                if let content = content {
                    switch pane {
                    case .minutes:
                        if let minutes = content.minutes { Text(minutes) } else { Text("No minutes yet").foregroundStyle(.secondary) }
                    case .transcript:
                        if let transcript = content.transcript {
                            Text(transcript).font(.system(.body, design: .monospaced))
                        } else {
                            Text("No transcript yet").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: rename

struct RenameSheet: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename meeting").font(.headline)
            TextField("Title", text: Binding(get: { model.renaming?.text ?? "" }, set: { model.renameText($0) }))
                .onSubmit { model.commitRename() }
            if let error = model.renaming?.error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelRename() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { model.commitRename() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: redo

/// Redo minutes and Transcribe again. Transcribe again chooses the transcriber, the two counts and
/// tidying for this meeting; both choose who writes the minutes, starting at the meeting's own writer,
/// else the Preferences one. Each control binds to `LibraryModel.redoing`; the writer goes through
/// `setRedoWriter`, so an outside one whose source is not agreed asks first, in a sheet over this one.
/// The button queues it after the model's check, and a refusal is said under the meeting's actions.
struct RedoSheet: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft = model.redoing {
                Text(LibraryPresentation.redoTitle(draft.kind)).font(.headline)
                let options = app.redoWriterOptions
                Form {
                    LabeledContent(PreferencesPresentation.writerLabel) {
                        WriterPopUp(options: options, selected: app.redoWriterSelection, opened: { app.writerPickerOpened() }, chose: { index in
                            if options.indices.contains(index) { model.setRedoWriter(options[index].writer.map(MeetingWriter.outside) ?? .apple) }
                        })
                    }
                    ModelNameFields(app: app, origin: .redo)
                    if let notice = model.writerNotice {
                        Text(notice).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Fixed while Redo's check runs, so the job runs with what the sheet shows.
                .disabled(model.redoChecking)
                if draft.kind == .transcribe {
                    Form {
                        Picker(LibraryPresentation.transcriberLabel, selection: Binding(
                            get: { model.redoing?.transcriber ?? .parakeet },
                            set: { choice in model.updateRedo { $0.transcriber = choice } })) {
                            ForEach(Transcriber.allCases, id: \.self) { transcriber in
                                Text(PreferencesPresentation.transcriberTitle(transcriber)).tag(transcriber)
                            }
                        }
                        if draft.bothSides {
                            Picker(LibraryPresentation.roomLabel, selection: Binding(
                                get: { model.redoing?.room },
                                set: { count in model.updateRedo { $0.room = count } })) {
                                ForEach(LibraryPresentation.countChoices, id: \.self) { count in
                                    Text(LibraryPresentation.roomChoice(count)).tag(count)
                                }
                            }
                            Picker(LibraryPresentation.callLabel, selection: Binding(
                                get: { model.redoing?.call },
                                set: { count in model.updateRedo { $0.call = count } })) {
                                ForEach(LibraryPresentation.countChoices, id: \.self) { count in
                                    Text(LibraryPresentation.callChoice(count)).tag(count)
                                }
                            }
                        } else {
                            Picker(LibraryPresentation.recordingLabel, selection: Binding(
                                get: { model.redoing?.recording },
                                set: { count in model.updateRedo { $0.recording = count } })) {
                                ForEach(LibraryPresentation.countChoices, id: \.self) { count in
                                    Text(LibraryPresentation.recordingChoice(count)).tag(count)
                                }
                            }
                        }
                        Toggle(PreferencesPresentation.tidyTitle, isOn: Binding(
                            get: { model.redoing?.tidy ?? true },
                            set: { on in model.updateRedo { $0.tidy = on } }))
                    }
                    .disabled(model.redoChecking)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelRedo() }
                        .keyboardShortcut(.cancelAction)
                    Button(LibraryPresentation.redoTitle(draft.kind)) { model.commitRedo() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.redoChecking)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        // Agreement asked for from this sheet, and only over it: "Send transcripts to <host>?".
        .sheet(isPresented: Binding(get: { app.redoConsentShown }, set: { if !$0 { app.cancelConsent() } })) {
            ConsentSheet(app: app)
        }
    }
}
