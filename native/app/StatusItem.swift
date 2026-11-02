import AppKit
import Combine

/// The menu bar item: a thin AppKit view over `StatusPresentation`. It draws what the model says
/// and hands each choice back to `AppModel.perform`; no decision is made here.
///
/// The menu is rebuilt only when its entries change, never on a tick, so it does not flicker or
/// lose its highlight while it is open and the timer runs.
@MainActor
final class StatusItem: NSObject {
    private let model: AppModel
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var shown: StatusPresentation?
    private var subscription: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.autoenablesItems = false
        item.menu = menu
        // After the change has been made, not before: `objectWillChange` fires first.
        subscription = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let now = model.presentation
        guard now != shown else { return }
        let before = shown
        shown = now
        if before?.button != now.button { draw(now.button) }
        if before?.menu != now.menu {
            // Only titles changed (a stream flapped): update the open menu in place, so nothing is taken from under the pointer.
            if let old = before?.menu, MenuEntry.sameShape(old, now.menu), menu.items.count == now.menu.count {
                for (item, entry) in zip(menu.items, now.menu) where item.title != entry.title { item.title = entry.title }
            } else {
                rebuild(now.menu)
            }
        }
    }

    private func draw(_ b: StatusButton) {
        guard let button = item.button else { return }
        var image = NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.help)
        switch b.tint {
        case .plain:
            image?.isTemplate = true // follows the menu bar, light or dark
        case .red:
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        case .amber:
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        }
        button.image = image
        button.imagePosition = b.title.isEmpty ? .imageOnly : .imageLeft
        // Digits of equal width, so the item does not jitter as the timer counts.
        button.attributedTitle = NSAttributedString(
            string: b.title, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
        button.toolTip = b.help
        button.setAccessibilityLabel(b.help)
    }

    private func rebuild(_ entries: [MenuEntry]) {
        menu.removeAllItems()
        for entry in entries {
            if entry.action == .separator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: entry.title, action: entry.enabled ? #selector(chosen(_:)) : nil,
                                      keyEquivalent: entry.action == .quit ? "q" : "")
            menuItem.target = self
            menuItem.isEnabled = entry.enabled
            menuItem.representedObject = entry.action
            menu.addItem(menuItem)
        }
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        model.perform(action)
    }
}
