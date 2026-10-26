import SwiftUI
import AppKit
import VaultCore

struct MenuBarWorkspace: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var runtime: RuntimeController
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var library: LibraryStore
    var body: some View {
        Button("Open Vault") { present(.workspace) }
        Button("Open Knowledge Map") { present(.graph) }
        Button("Search Vault…") { present(.search) }
        Divider()
        if runtime.quitting { Text("Finishing and saving work before quitting…") }
        else if workspace.scanIsActive, let scan = workspace.activeScan {
            Text(workspace.scanPaused ? "Scan paused" : scan.stage.title)
            Text(scan.percentCompleted.map { "\($0)% · \(scan.processed) processed" } ?? "Counting files…")
            Button("Inspect Scan") { present(.scan) }
            Button(workspace.scanPaused ? "Resume Scan" : "Pause Scan") { workspace.setScanPaused(!workspace.scanPaused) }
                .disabled(workspace.scanCancellationRequested)
            Button("Cancel Scan") { workspace.cancelScan() }.disabled(workspace.scanCancellationRequested)
        } else {
            if let scan = workspace.data.lastScan {
                Text(scan.stage.title)
                Button("Review Last Scan") { present(.scan) }
                if [.interrupted, .cancelled, .failed].contains(scan.stage) {
                    Button("Retry Last Scan") { workspace.retryScan(library: library); workspace.minimizeScan() }.disabled(workspace.working || library.busy || !workspace.scanJournalReadable)
                }
            } else { Text("No scan running") }
            if workspace.monitoringActive { Text("Refreshing changed folders") }
            else if workspace.data.locations.contains(where: { !$0.paused }) { Text("Watching approved folders for changes") }
        }
        if library.busy { Text("Import / catalog operation in progress") }
        if workspace.error != nil || library.operationFailed { Button("Review Issue in Vault") { present(.scan) } }
        Divider()
        Button("Hide to Menu Bar") { runtime.hideToMenuBar() }.disabled(!runtime.windowVisible)
        SettingsLink { Text("Settings…") }
        Button("Quit Vault") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").disabled(runtime.quitting)
    }
    private func present(_ destination: RuntimeCommand.Destination) { runtime.present(destination) { openWindow(id: "workspace") } }
}
