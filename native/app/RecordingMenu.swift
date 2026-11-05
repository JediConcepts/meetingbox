import AppKit
import Combine

/// The recording entries the menu bar item's menu has now (Start recording, or Pause or Resume, and
/// Stop), offered in two more places, so recording never depends on the menu bar item being shown:
/// the main menu's Recording menu (`menu`, kept up to date as the phase changes) and the Dock menu
/// (`dockMenu()`, made afresh each time the Dock asks). Both come from `AppModel.recordingEntries`,
/// which is built from the same `presentation.menu` as the menu bar item's, and every choice goes to
/// `AppModel.perform`, the one path every recording command takes.
@MainActor
final class RecordingMenu: NSObject {
    /// The main menu's Recording menu.
    let menu = NSMenu(title: "Recording")
    private let model: AppModel
    private var shown: [MenuEntry]?
    private var subscription: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.autoenablesItems = false
        // After the change has been made, not before: `objectWillChange` fires first.
        subscription = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// The Dock menu: the entries that apply now, and nothing else.
    func dockMenu() -> NSMenu {
        let dock = NSMenu()
        dock.autoenablesItems = false
        fill(dock, model.recordingEntries)
        return dock
    }

    /// Rebuilt only when the entries change, never on a tick.
    private func refresh() {
        let now = model.recordingEntries
        guard now != shown else { return }
        shown = now
        fill(menu, now)
    }

    private func fill(_ target: NSMenu, _ entries: [MenuEntry]) {
        target.removeAllItems()
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.enabled
            item.representedObject = entry.action
            target.addItem(item)
        }
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        model.perform(action)
    }
}
