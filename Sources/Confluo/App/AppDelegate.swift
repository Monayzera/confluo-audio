import AppKit
import Observation
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private let navigation = WindowNavigation()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?
    private var windowCountsForMeters = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.endHotkeyRecording()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refreshLoginItem()
            }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel("Confluo")
        statusItem = item

        let content = NSHostingController(rootView: PopoverView(model: model) { [weak self] section in
            self?.showWindow(section)
        })
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        model.onOpenMixerRequest = { [weak self] in
            self?.togglePopover()
        }
        model.start()
        observeStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(.mixer)
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, button.window != nil else {
            showWindow(.mixer)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        model.meterClientAppeared()
    }

    func popoverDidClose(_ notification: Notification) {
        model.meterClientDisappeared()
    }

    private func showWindow(_ section: MainSection) {
        if popover.isShown {
            popover.performClose(nil)
        }
        navigation.section = section
        if window == nil {
            let controller = NSHostingController(rootView: MainWindowView(model: model, navigation: navigation))
            let created = NSWindow(contentViewController: controller)
            created.title = "Confluo"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 820, height: 600))
            created.setFrameAutosaveName("ConfluoMainWindow")
            created.delegate = self
            if !created.setFrameUsingName("ConfluoMainWindow") {
                created.center()
            }
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if !windowCountsForMeters {
            windowCountsForMeters = true
            model.meterClientAppeared()
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.endHotkeyRecording()
        if windowCountsForMeters {
            windowCountsForMeters = false
            model.meterClientDisappeared()
        }
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.string("action.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.string("menu.edit"))
        editMenu.addItem(withTitle: L10n.string("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.string("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.string("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.string("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.string("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.string("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.string("menu.window"))
        windowMenu.addItem(withTitle: L10n.string("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L10n.string("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    private func observeStatusIcon() {
        withObservationTracking {
            updateStatusIcon()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.observeStatusIcon()
            }
        }
    }

    private func updateStatusIcon() {
        let external = model.airPlaySources
        let symbol: String
        if case .failed = model.receiverState {
            symbol = "exclamationmark.circle"
        } else if external.isEmpty {
            symbol = "waveform.circle"
        } else if external.allSatisfy({ $0.muted }) {
            symbol = "speaker.slash.circle"
        } else {
            symbol = "waveform.circle.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Confluo")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }
}
