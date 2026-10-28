import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let navigation = WindowNavigation()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
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
