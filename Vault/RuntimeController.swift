import SwiftUI
import AppKit
import Combine

struct RuntimeCommand: Equatable {
    enum Destination: Equatable { case workspace, graph, search, scan }
    let id = UUID()
    let destination: Destination
}
@MainActor
final class RuntimeController: ObservableObject {
    @Published private(set) var command: RuntimeCommand?
    @Published private(set) var windowVisible = false
    @Published private(set) var quitting = false
    var effectsAllowed: Bool {
        windowVisible && !ProcessInfo.processInfo.isLowPowerModeEnabled && ![.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
    }
    weak var window: NSWindow?
    let notifications = RuntimeNotifications()
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var powerObservers: [NSObjectProtocol] = []
    private weak var library: LibraryStore?
    private weak var workspace: WorkspaceStore?
    private weak var secure: SecureStore?
    private weak var notes: AppleNotesStore?
    private weak var preferences: WorkspacePreferencesStore?
    private var sleepPausedScan = false
    private var cacheGeneration = UUID()
    var minimizeToMenuBar: Bool { UserDefaults.standard.bool(forKey: "minimizeToMenuBar") }
    func bind(library: LibraryStore, workspace: WorkspaceStore, secure: SecureStore, notes: AppleNotesStore, preferences: WorkspacePreferencesStore) {
        guard self.library == nil else { return }
        self.library = library; self.workspace = workspace; self.secure = secure; self.notes = notes; self.preferences = preferences
        workspace.startMonitoring(library: library)
        workspace.$activeScan.compactMap { $0 }.filter { !$0.stage.isRunning }.sink { [weak self] job in
            Task { @MainActor in await self?.notifications.scanFinished(job) }
        }.store(in: &subscriptions)
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            powerObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })
    }
    func present(_ destination: RuntimeCommand.Destination = .workspace, openWindow: () -> Void) {
        guard !quitting else { return }
        command = RuntimeCommand(destination: destination)
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else { openWindow() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateVisibility() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden } ?? false
        guard visible != windowVisible else { return }
        cacheGeneration = UUID()
        windowVisible = visible
        ThumbnailPipeline.shared.setSuspended(!visible)
        if !visible {
            secure?.lock()
            let library = library, generation = cacheGeneration
            Task {
                await preferences?.flush()
                guard !windowVisible, cacheGeneration == generation else { return }
                await library?.knowledgeGraph.releaseTransientCaches()
                guard !windowVisible, cacheGeneration == generation else { return }
                await library?.catalogBrowser.releaseTransientCaches()
            }
        }
    }
    func hideToMenuBar() { window?.orderOut(nil); updateVisibility() }
    private func willSleep() {
        sleepPausedScan = workspace?.scanIsActive == true && workspace?.scanPaused == false
        if sleepPausedScan { workspace?.setScanPaused(true) }
        workspace?.suspendMonitoring(); secure?.lock()
    }
    private func didWake() {
        workspace?.resumeMonitoring()
        if sleepPausedScan { workspace?.setScanPaused(false) }; sleepPausedScan = false
        updateVisibility()
    }
    func shutdown() async {
        guard !quitting else { return }; quitting = true; secure?.lock()
        workspace?.cancelScan(); library?.cancelImport(); notes?.cancel()
        ThumbnailPipeline.shared.setSuspended(true)
        await workspace?.shutdown(); await notes?.shutdown(); await library?.shutdown(); await preferences?.flush()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }; observers.removeAll(); subscriptions.removeAll()
        powerObservers.forEach { NotificationCenter.default.removeObserver($0) }; powerObservers.removeAll()
    }
}

@MainActor
final class VaultApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: RuntimeController?
    private var terminationPending = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { await runtime.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// Forwards SwiftUI's existing window delegate methods while intercepting optional close-to-menu-bar behavior.
@MainActor
struct RuntimeWindowBridge: NSViewRepresentable {
    @ObservedObject var runtime: RuntimeController
    func makeCoordinator() -> Coordinator { Coordinator(runtime: runtime) }
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }; return view
    }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }
    @MainActor final class Probe: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        // AppKit delegate forwarding occurs on its main thread; this bridges an immutable reference through NSObject's nonisolated API.
        private struct ForwardedDelegate: @unchecked Sendable { let value: NSWindowDelegate? }
        let runtime: RuntimeController
        weak var original: NSWindowDelegate?
        weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        init(runtime: RuntimeController) { self.runtime = runtime }
        func attach(_ window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach(); self.window = window; original = window.delegate; window.delegate = self; runtime.window = window
            let center = NotificationCenter.default
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak runtime] _ in Task { @MainActor in runtime?.updateVisibility() } })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification] {
                observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak runtime] _ in Task { @MainActor in runtime?.updateVisibility() } })
            }
            Task { @MainActor in runtime.updateVisibility() }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if runtime.minimizeToMenuBar && !runtime.quitting { runtime.hideToMenuBar(); return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        func detach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
            if window?.delegate === self { window?.delegate = original }
            if runtime.window === window { runtime.window = nil; runtime.updateVisibility() }
            window = nil; original = nil
        }
        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { original?.responds(to: selector) == true }
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            let target = MainActor.assumeIsolated { ForwardedDelegate(value: original?.responds(to: selector) == true ? original : nil) }
            if let value = target.value { return value }
            return super.forwardingTarget(for: selector)
        }
    }
}
