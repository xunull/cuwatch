import AppKit
import SwiftUI
import Combine
import CuwatchCore

/// Owns the menu bar status item, the popover (dashboard + preferences shell),
/// and the three ServiceMonitors.
///
/// Reactive wiring:
/// - StateStore → DialView (per-frame fraction + colorState via Combine)
/// - PreferencesStore.minimaxEndpoint → MinimaxClient is rebuilt + monitor
///   restarts so the next poll hits the new host.
/// - PreferencesStore.pollIntervalSeconds → each monitor is restarted with
///   the new cadence so the user-facing change takes effect immediately
///   without waiting for the current backoff window to elapse.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Real entry point. Storyboard-template AppDelegates rely on
    /// `NSApplicationMain` reading `Main.storyboard` from Info.plist; since we
    /// deleted both, we wire the run loop ourselves.
    /// `.accessory` activation policy = menu bar app (no Dock icon).
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var dialView: DialView!
    private let popover = NSPopover()

    private let stateStore = StateStore()
    private lazy var popoverViewModel: PopoverViewModel = {
        PopoverViewModel(
            stateStore: stateStore,
            scheduler: DispatchQueueMainScheduler()
        )
    }()
    private let keychain = KeychainStore()
    private let preferencesStore = PreferencesStore()
    private lazy var preferencesViewModel: PreferencesViewModel = {
        let history = try? HistoryStore()
        return PreferencesViewModel(
            store: preferencesStore,
            keychain: keychain,
            historyStore: history
        )
    }()

    private var claudeMonitor: BaseServiceMonitor<ClaudeReaderAdapter>?
    private var codexMonitor: BaseServiceMonitor<CodexReaderAdapter>?
    private var minimaxMonitor: BaseServiceMonitor<MinimaxReaderAdapter>?

    /// Reads the Codex Logbook from `~/.codex/state_5.sqlite` on demand.
    /// Owned here so the SQLite open/close stays per-popover-open rather
    /// than held across the app's lifetime. See docs/codex-logbook-design.md.
    private let codexLogbookReader = CodexLogbookReader()

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        configureStatusItem()
        configurePopover()
        cleanupHistoryStoreOrphans()
        bindStateStoreToDial()
        startMonitors()
        observePreferenceChanges()
    }

    /// Without a main menu, `.accessory` apps have no Edit menu, and macOS has
    /// nowhere to dispatch Cmd+V / Cmd+C / Cmd+A from. SwiftUI TextFields rely
    /// on the standard `paste:` / `cut:` / `copy:` / `selectAll:` actions
    /// flowing through the responder chain via the Edit menu's key
    /// equivalents — without the menu, the keystroke is literally a no-op.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu placeholder (required for the menu bar layout even though
        // accessory apps don't display it).
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit cuwatch",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Edit menu — this is the one that actually matters for paste support.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo",
                                        action: Selector(("redo:")),
                                        keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await claudeMonitor?.stop()
            await codexMonitor?.stop()
            await minimaxMonitor?.stop()
        }
    }

    // MARK: - Status item

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.toolTip = "cuwatch"
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        // Receive BOTH left and right mouse-up events so we can split the
        // behavior: left = toggle popover (primary action), right = show a
        // small context menu with Quit / Preferences. This is the standard
        // macOS menu-bar-app convention used by Slack, Bartender, Stats, etc.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let size = Tokens.Layout.menuBarIconSize
        let dial = DialView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        dial.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dial)
        NSLayoutConstraint.activate([
            dial.widthAnchor.constraint(equalToConstant: size),
            dial.heightAnchor.constraint(equalToConstant: size),
            dial.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            dial.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        self.dialView = dial
        dial.setSnapshot(fraction: 0.0, state: .neutralGrey, animated: false)
    }

    /// Routes left vs right clicks to popover toggle vs context menu.
    @objc private func handleStatusItemClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showStatusItemContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // .accessory activation policy keeps cuwatch out of the Dock, but
            // it also means macOS routes Cmd+key shortcuts (notably Cmd+V) to
            // whichever app IS active — usually the browser the user copied
            // the token from. Explicitly activate cuwatch first so the popover
            // becomes part of the active responder chain and Cmd+V lands in
            // the SwiftUI TextField.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Right-click on the menu bar icon → standard macOS context menu with
    /// "Open cuwatch" + "Quit cuwatch". We don't permanently bind
    /// `statusItem.menu` because doing so makes EVERY click (left and right)
    /// show the menu, breaking the popover-on-left convention. Instead we
    /// transiently set/clear `statusItem.menu` around `button.performClick`
    /// so the menu appears exactly once.
    ///
    /// Preferences stays inside the popover (reachable via the footer link
    /// or Cmd+,) — putting it here too would duplicate UI without payoff.
    private func showStatusItemContextMenu() {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open cuwatch",
                                  action: #selector(openItemSelected),
                                  keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit cuwatch",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Clear the menu after the click so subsequent left clicks go back
        // to the popover.
        statusItem.menu = nil
    }

    @objc private func openItemSelected() {
        if !popover.isShown {
            togglePopover(nil)
        }
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let shell = PopoverShell(
            dashboardViewModel: popoverViewModel,
            preferencesViewModel: preferencesViewModel,
            onGrantFDA: { [weak self] in self?.openFDASystemSettings() },
            onOpenCodexSetup: { [weak self] in self?.openCodexSetupReadme() },
            onOpenReadmePrivacy: { [weak self] in self?.openPrivacyReadme() },
            loadLogbook: { [weak self] in self?.codexLogbookReader.read() }
        )
        let hosting = NSHostingController(rootView: shell)
        hosting.view.frame = NSRect(
            x: 0, y: 0,
            width: Tokens.Layout.popoverWidth, height: 440
        )
        popover.contentViewController = hosting
    }

    // MARK: - External openers (FDA prompt, README sections)

    private func openFDASystemSettings() {
        // macOS 13+ uses the new URL scheme; 12 uses the older one. The
        // documented universal scheme below works on both.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        // After the user grants access, the next ClaudeMonitor poll will
        // pick it up. Force one in 4 seconds so the card auto-dismisses
        // quickly without waiting on the 30s cadence.
        Task {
            try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
            await self.claudeMonitor?.pollNow()
        }
    }

    private func openCodexSetupReadme() {
        if let url = URL(string: "https://github.com/xunull/cuwatch#codex-setup") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openPrivacyReadme() {
        if let url = URL(string: "https://github.com/xunull/cuwatch#privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Housekeeping

    private func cleanupHistoryStoreOrphans() {
        guard let store = try? HistoryStore() else { return }
        let removed = store.cleanupOrphans()
        if removed > 0 {
            NSLog("[cuwatch] cleaned up \(removed) orphan tmp file(s) from a previous run")
        }
    }

    // MARK: - Dial wiring

    private func bindStateStoreToDial() {
        popoverViewModel.$dialColorState
            .combineLatest(popoverViewModel.$mainService, popoverViewModel.$snapshots)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] color, main, snapshots in
                let fraction = main.flatMap { snapshots[$0]?.usedFraction } ?? 0.0
                self?.dialView.setSnapshot(fraction: fraction, state: color, animated: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - Monitors

    private func startMonitors() {
        if let claudeReader = ClaudeReader.userDefault() {
            let monitor = BaseServiceMonitor<ClaudeReaderAdapter>.claude(
                store: stateStore,
                reader: claudeReader,
                interval: preferencesStore.pollIntervalSeconds
            )
            claudeMonitor = monitor
            Task { await monitor.start() }
        }

        let codexReader = CodexReader()
        let codex = BaseServiceMonitor<CodexReaderAdapter>.codex(
            store: stateStore,
            reader: codexReader,
            interval: preferencesStore.pollIntervalSeconds
        )
        codexMonitor = codex
        Task { await codex.start() }

        let minimaxClient = MinimaxClient(endpoint: preferencesStore.minimaxEndpoint)
        let minimax = BaseServiceMonitor<MinimaxReaderAdapter>.minimax(
            store: stateStore,
            client: minimaxClient,
            keychain: keychain,
            interval: preferencesStore.pollIntervalSeconds
        )
        minimaxMonitor = minimax
        Task { await minimax.start() }

        observeSleepWake()
    }

    /// Rebuild the Minimax monitor with a fresh `MinimaxClient` so the
    /// endpoint switch takes effect immediately. Poll-interval changes
    /// trigger a similar rebuild across all three so the new cadence applies
    /// without waiting on the existing schedule to expire.
    private func observePreferenceChanges() {
        // Endpoint — only affects the Minimax monitor.
        preferencesStore.$minimaxEndpoint
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] endpoint in
                guard let self else { return }
                Task {
                    await self.minimaxMonitor?.stop()
                    let client = MinimaxClient(endpoint: endpoint)
                    let monitor = BaseServiceMonitor<MinimaxReaderAdapter>.minimax(
                        store: self.stateStore,
                        client: client,
                        keychain: self.keychain,
                        interval: self.preferencesStore.pollIntervalSeconds
                    )
                    self.minimaxMonitor = monitor
                    await monitor.start()
                }
            }
            .store(in: &cancellables)

        // Polling interval — rebuilds all three so they pick up the new cadence.
        preferencesStore.$pollIntervalSeconds
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.restartAllMonitors()
            }
            .store(in: &cancellables)
    }

    private func restartAllMonitors() {
        Task {
            await claudeMonitor?.stop()
            await codexMonitor?.stop()
            await minimaxMonitor?.stop()
            startMonitors()
        }
    }

    /// On sleep, stop scheduling new polls. On wake, prompt-poll all three so
    /// the popover doesn't show 8-hour-stale data the moment the user opens
    /// their laptop.
    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task {
                    await self?.claudeMonitor?.pollNow()
                    await self?.codexMonitor?.pollNow()
                    await self?.minimaxMonitor?.pollNow()
                }
            }
            .store(in: &cancellables)
    }
}
