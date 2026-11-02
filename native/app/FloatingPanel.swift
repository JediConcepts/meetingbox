import AppKit
import Combine

/// The floating record button: a thin AppKit view over `StatusPresentation.panel`. A borderless,
/// non-activating panel above other windows, on every Space and over full screen apps, that never
/// takes focus from the call app. Its position is saved in `Preferences` as it is moved.
@MainActor
final class FloatingPanel: NSObject {
    private let model: AppModel
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let dot = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var actions: [MenuAction] = []
    private var shown: PanelPresentation?
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var placing = false
    private var pendingSave: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: FloatingPlacement.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false // the app is never the active one while the user is on a call
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.setAccessibilityLabel("meetingbox")
        build()
        // Saved as it is moved by hand, after a short pause so a drag is one write.
        // No queue: told on the thread that moved it (the main one), so `placing` still holds then.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        })
        subscription = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func build() {
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background

        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        // Digits of equal width, so the timer does not jitter as it counts.
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [dot, label, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    private func refresh() {
        let now = model.presentation.panel
        guard now != shown else { return }
        let before = shown
        shown = now
        dot.contentTintColor = tint(now.dot)
        label.stringValue = now.label
        background.toolTip = now.help
        if before?.controls != now.controls { rebuildButtons(now.controls) }
        if now.visible {
            if !panel.isVisible {
                place()
                panel.orderFrontRegardless() // in front, without making meetingbox the active app
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func tint(_ t: StatusTint) -> NSColor {
        switch t {
        case .plain: return .secondaryLabelColor
        case .red: return .systemRed
        case .amber: return .systemOrange
        }
    }

    private func rebuildButtons(_ controls: [MenuAction]) {
        actions = controls
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, action) in controls.enumerated() {
            let image = NSImage(systemSymbolName: FloatingPanel.symbol(action), accessibilityDescription: action.title)
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(pressed(_:)))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .labelColor
            button.tag = index
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            buttons.addArrangedSubview(button)
        }
    }

    private static func symbol(_ action: MenuAction) -> String {
        switch action {
        case .start: return "record.circle"
        case .pause: return "pause.fill"
        case .resume: return "play.fill"
        case .stop: return "stop.fill"
        default: return "folder"
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        model.perform(actions[sender.tag])
    }

    // MARK: position

    /// Where the user left it, or the top right of the main screen the first time or when that
    /// place is no longer on any screen.
    private func place() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let main = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        placing = true
        panel.setFrameOrigin(FloatingPlacement.origin(saved: model.preferences.floatingOrigin, screens: screens, main: main))
        placing = false
    }

    private func moved() {
        guard !placing, panel.isVisible else { return }
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.model.preferences.floatingOrigin = self.panel.frame.origin }
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: save)
    }
}
