import SwiftUI
import VaultCore

struct RuntimePreferencesView: View {
    @ObservedObject var notifications: RuntimeNotifications
    @AppStorage("minimizeToMenuBar") private var minimize = false
    @AppStorage("notificationPreference") private var notification = NotificationPreference.off
    @AppStorage("thumbnailCacheMB") private var thumbnailMB = ThumbnailBudget.standard.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background & performance").font(.headline)
            Toggle("Minimize to Menu Bar", isOn: $minimize)
            Text("When enabled, closing the main window hides it and keeps ongoing work available in the menu bar. Minimize keeps its normal macOS behavior. Hide releases previews; Quit cancels work and waits for completed results to save. Vault does not prevent sleep.").font(.caption).foregroundStyle(.secondary)
            Picker("Thumbnail cache", selection: $thumbnailMB) {
                ForEach(ThumbnailBudget.allCases, id: \.rawValue) { budget in Text("\(budget.rawValue) MB").tag(budget.rawValue) }
            }.onChange(of: thumbnailMB) { _, value in ThumbnailPipeline.shared.configure(megabytes: value) }
            Text("Decoded thumbnail cache budget. The overall app also retains catalog metadata and user-requested work; this is not an app memory limit.").font(.caption).foregroundStyle(.secondary)
            Picker("Notifications", selection: $notification) {
                ForEach(NotificationPreference.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }.onChange(of: notification) { _, _ in Task { await notifications.configure() } }
            Text(notification == .off ? "Off · no notification permission is requested." : notifications.status).font(.caption).foregroundStyle(.secondary)
            Text("Optional alerts cover scan failures or completion. Routine progress stays inside Vault and its menu. macOS notification permissions still apply.").font(.caption).foregroundStyle(.secondary)
        }.task { await notifications.refreshStatus() }
    }
}
