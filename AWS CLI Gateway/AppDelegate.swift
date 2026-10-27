import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = RoleManager.ensureAppSupportDirectory()
        ConfigManager.shared.ensureDirectoryPermissions()
        ConfigManager.shared.syncProfilesWithHistory()
        _ = ProfileHistoryManager.shared

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        UNUserNotificationCenter.current().delegate = self

        MenuBarManager.shared.setup()
        ConfigManager.shared.updateIAMProfileSourceReferences()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProfileHistoryManager.shared.persistChanges()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MenuBarManager.shared.hasActiveSession() {
            let alert = NSAlert()
            alert.messageText = "Quit Gateway"
            alert.informativeText = "Would you like to clear your active SSO session cache before quitting?"
            alert.addButton(withTitle: "Quit & Clear Cache")
            alert.addButton(withTitle: "Just Quit")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                _ = ConfigManager.shared.clearSSOCache()
                return .terminateNow
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "refresh-action" {
            let profileName = response.notification.request.content.userInfo["profileName"] as? String
            Task { @MainActor in
                if let profileName = profileName {
                    MenuBarManager.shared.refreshSession(for: profileName)
                } else {
                    MenuBarManager.shared.refreshCurrentSession()
                }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
