import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let trigger = TriggerPanel()
    private let debugItem = NSMenuItem(title: "Debug: Show Icon Frames", action: #selector(toggleDebug), keyEquivalent: "")
    private var overlays: [OverlayWindow] = []
    private var debugTimer: Timer?
    private var cleaner: CleanupController?
    private var debugOn: Bool { debugTimer != nil }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = makeMainMenu()

        trigger.pill.onHover = { [weak self] in self?.refreshCount() }
        trigger.pill.onClick = { [weak self] in self?.pillClicked() }
        trigger.pill.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        trigger.orderFrontRegardless()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        print("Tidybo started. Screens:")
        for s in NSScreen.screens { print("  \(s.localizedName) frame=\(s.frame)") }
        if !DesktopIconReader.isTrusted { askForAccessibility() }
    }

    /// Clicking the Dock icon while running brings the trigger back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        trigger.orderFrontRegardless()
        return false
    }

    /// A Dock app with no windows: quitting is the only way to "close" it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Standard app menu (About / Hide / Quit ⌘Q) plus the debug toggle.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu(title: "Tidybo")
        app.addItem(withTitle: "About Tidybo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        debugItem.target = self
        app.addItem(debugItem)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Tidybo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Tidybo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        return main
    }

    /// Right-click menu on the trigger.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let debug = NSMenuItem(title: debugItem.title, action: #selector(toggleDebug), keyEquivalent: "")
        debug.state = debugOn ? .on : .off
        debug.target = self
        menu.addItem(debug)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tidybo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    // MARK: Accessibility

    private func askForAccessibility() {
        print("No Accessibility permission.")
        let alert = NSAlert()
        alert.messageText = "Accessibility access needed"
        alert.informativeText = "Without it the app can't see your desktop icons. Turn on Tidybo in System Settings → Privacy & Security → Accessibility, then relaunch the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    // MARK: Cleanup
    //
    // Select files first, then click the pill: the click is the confirmation.

    private func cleanableSelection() -> [DesktopIcon] {
        let ownFolders = Journal.knownFolders()   // never clean up our own cleanup folders
        return DesktopIconReader.readIcons().filter {
            $0.isSelected && DesktopIconReader.isCleanable($0) && !ownFolders.contains($0.path ?? "")
        }
    }

    private func refreshCount() {
        guard cleaner == nil else { return }
        trigger.pill.mode = .ready(count: DesktopIconReader.isTrusted ? cleanableSelection().count : 0)
    }

    private func pillClicked() {
        guard cleaner == nil else { return }
        guard DesktopIconReader.isTrusted else { askForAccessibility(); return }
        let icons = cleanableSelection()
        guard !icons.isEmpty else { refreshCount(); trigger.pill.shake(); return }
        startCleanup(icons)
    }

    private func startCleanup(_ icons: [DesktopIcon]) {
        let journal: Journal
        do {
            journal = try prepareSession(icons)
        } catch {
            showError("Couldn't start cleanup", error.localizedDescription)
            return
        }
        print("Cleanup → \(journal.session.folder) (journal: \(journal.url.path))")

        freshOverlays()
        let c = CleanupController(icons: icons, overlays: overlays, journal: journal)
        c.onFinish = { [weak self] result in
            guard let self else { return }
            self.cleaner = nil
            // Leave the final folder badge visible for a moment, then remove the windows entirely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if self.cleaner == nil && !self.debugOn { self.closeOverlays() }
            }
            self.refreshCount()
            print("Cleanup finished: moved \(result.moved), failed \(result.failed.count)")
            if !result.failed.isEmpty {
                let list = result.failed.map { "• \($0.name) — \($0.reason)" }.joined(separator: "\n")
                self.showError("\(filesCount(result.failed.count)) couldn't be cleaned up", list)
            }
        }
        cleaner = c
        trigger.pill.mode = .running
        c.start()
    }

    /// Creates the cleanup folder and writes the journal *before* any file is moved.
    private func prepareSession(_ icons: [DesktopIcon]) throws -> Journal {
        let desktop = icons.compactMap(\.path).first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let folder = try FileMover.createCleanupFolder(in: desktop)
        let items = icons.compactMap { icon -> CleanupSession.Item? in
            guard let src = icon.path else { return nil }
            let dest = folder.appendingPathComponent(URL(fileURLWithPath: src).lastPathComponent).path
            return .init(source: src, destination: dest, axPosition: icon.axFrame.origin, status: .pending, error: nil)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let id = stamp + "-" + UUID().uuidString.prefix(8)
        return try Journal(session: CleanupSession(id: id, createdAt: Date(), folder: folder.path, state: .cleaning, items: items))
    }

    private func showError(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Overlays / debug

    /// Overlay windows exist only while a cleanup (or the debug view) needs them.
    /// Each run gets brand-new windows: re-showing old desktop-level windows could leave them
    /// behind the icon layer (the "invisible robot on the second run" bug).
    private func ensureOverlays() {
        guard overlays.isEmpty else { return }
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0) }
        overlays.forEach { $0.orderFrontRegardless() }
    }

    private func freshOverlays() {
        closeOverlays()
        ensureOverlays()
        if debugOn { refreshDebug() }
    }

    private func closeOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    @objc private func toggleDebug() {
        if debugOn {
            debugTimer?.invalidate(); debugTimer = nil
            overlays.forEach { $0.overlayView.icons = [] }
            if cleaner == nil { closeOverlays() }
        } else {
            guard DesktopIconReader.isTrusted else { askForAccessibility(); return }
            ensureOverlays()
            refreshDebug()
            debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshDebug() }
        }
        debugItem.state = debugOn ? .on : .off
    }

    private func refreshDebug() {
        let icons = DesktopIconReader.readIcons()
        overlays.forEach { $0.overlayView.icons = icons }
    }

    @objc private func screensChanged() {
        trigger.reposition()
        guard cleaner == nil else { return } // rebuilt after the current run
        closeOverlays()
        if debugOn { ensureOverlays(); refreshDebug() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // regular Dock app: click to launch, Quit from the Dock
app.run()
