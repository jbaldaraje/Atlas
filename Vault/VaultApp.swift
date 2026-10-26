import SwiftUI

@main
struct VaultApp: App {
    @AppStorage("appearance") private var appearance = "dark"
    @StateObject private var store = LibraryStore()
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var secure = SecureStore()
    @StateObject private var trash = NativeTrashService()
    @StateObject private var notes = AppleNotesStore()
    @StateObject private var preferences = WorkspacePreferencesStore()
    var body: some Scene {
        WindowGroup {
            WorkspaceView().environmentObject(store).environmentObject(workspace).environmentObject(secure).environmentObject(trash).environmentObject(notes).environmentObject(preferences)
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
        Settings { PreferencesView().padding(28).frame(width: 440).buttonStyle(CinematicButtonStyle()).preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light) }
    }
}
