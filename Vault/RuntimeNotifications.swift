import Foundation
import Combine
import UserNotifications
import VaultCore

@MainActor
final class RuntimeNotifications: ObservableObject {
    @Published private(set) var status = "Notifications are off."
    private let center = UNUserNotificationCenter.current()
    private var delivered: Set<UUID> = []
    var preference: NotificationPreference {
        NotificationPreference(rawValue: UserDefaults.standard.string(forKey: "notificationPreference") ?? "") ?? .off
    }
    /// Called only from the user's explicit Settings selection, never at launch.
    func configure() async {
        guard preference != .off else {
            center.removePendingNotificationRequests(withIdentifiers: ["vault.scan.result"])
            status = "Notifications are off."; return
        }
        do {
            let allowed = try await center.requestAuthorization(options: [.alert])
            guard preference != .off else { status = "Notifications are off."; return }
            status = allowed ? "Enabled for the selected events; macOS controls delivery." : "Not authorized. Enable Vault notifications in System Settings."
        } catch { status = "Notification permission could not be checked. In-app status remains available." }
    }
    func refreshStatus() async {
        guard preference != .off else { status = "Notifications are off."; return }
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus == .authorized ? "Enabled for the selected events; macOS controls delivery." : "Not authorized. Choose an event option to request permission, or check System Settings."
    }
    func scanFinished(_ job: ScanJob) async {
        guard preference.shouldNotify(stage: job.stage, hasErrors: !job.errors.isEmpty), delivered.insert(job.id).inserted else { return }
        // Limit memory; only one current job can finish at a time.
        if delivered.count > 64 { delivered = [job.id] }
        let settings = await center.notificationSettings()
        guard preference.shouldNotify(stage: job.stage, hasErrors: !job.errors.isEmpty), settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = job.stage == .completed && job.errors.isEmpty ? "Vault scan complete" : "Vault scan needs attention"
        content.body = "Open Vault to review the result."
        // Never include filenames, source paths, document text, or Secure Vault state.
        do { try await center.add(UNNotificationRequest(identifier: "vault.scan.result", content: content, trigger: nil)) }
        catch { status = "A scan alert could not be delivered. Review its result in Vault." }
    }
}
