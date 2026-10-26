import SwiftUI

@main
struct VaultApp: App {
    @NSApplicationDelegateAdaptor(VaultApplicationDelegate.self) private var applicationDelegate
    @StateObject private var runtime = RuntimeController()
    @AppStorage("appearance") private var appearance = "dark"
    @StateObject private var store = LibraryStore()
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var secure = SecureStore()
    @StateObject private var trash = NativeTrashService()
    @StateObject private var notes = AppleNotesStore()
    @StateObject private var preferences = WorkspacePreferencesStore()
    var body: some Scene {
        Window("Vault", id: "workspace") {
            WorkspaceView().environmentObject(store).environmentObject(workspace).environmentObject(secure).environmentObject(trash).environmentObject(notes).environmentObject(preferences).environmentObject(runtime)
                .background { RuntimeWindowBridge(runtime: runtime).frame(width: 0, height: 0) }
                .task {
                    applicationDelegate.runtime = runtime
                    runtime.bind(library: store, workspace: workspace, secure: secure, notes: notes, preferences: preferences)
                }
                .frame(minWidth: 1000, minHeight: 680)
                .buttonStyle(CinematicButtonStyle())
                .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Files…") { store.chooseFiles() }.keyboardShortcut("i", modifiers: [.command]).disabled(store.busy || store.loadFailed || workspace.working || notes.working)
            }
        }
        MenuBarExtra("Vault", systemImage: "square.stack.3d.up") { MenuBarWorkspace(runtime: runtime, workspace: workspace, library: store) }
        Settings { ScrollView { PreferencesView().environmentObject(runtime).padding(28) }.frame(width: 520, height: 650).buttonStyle(CinematicButtonStyle()).preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light) }
    }
}
