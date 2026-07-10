import SwiftUI
import UserNotifications
import Combine
import UIKit

class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()
    
    @Published var hasNotificationPermission = false
    private let hideScanBackgroundReminderKey = "dutchie.hideScanBackgroundReminder"
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
    }

    var shouldShowScanBackgroundReminder: Bool {
        !UserDefaults.standard.bool(forKey: hideScanBackgroundReminderKey)
    }

    private var shouldSendScanStatusNotification: Bool {
        UIApplication.shared.applicationState != .active
    }

    func setScanBackgroundReminderHidden(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: hideScanBackgroundReminderKey)
    }
    
    // MARK: - Permission
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                self.hasNotificationPermission = granted
                completion(granted)
            }
        }
    }
    
    func checkPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                let granted = settings.authorizationStatus == .authorized
                self.hasNotificationPermission = granted
                completion(granted)
            }
        }
    }

    func requestPermissionIfNeeded(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    self.hasNotificationPermission = true
                    completion?(true)
                }
            case .notDetermined:
                self.requestPermission { granted in
                    completion?(granted)
                }
            case .denied:
                DispatchQueue.main.async {
                    self.hasNotificationPermission = false
                    completion?(false)
                }
            @unknown default:
                DispatchQueue.main.async {
                    self.hasNotificationPermission = false
                    completion?(false)
                }
            }
        }
    }
    
    // MARK: - Payment Setup Reminders
    
    func schedulePaymentSetupReminders(profile: Profile) {
        let hasVenmo = !(profile.venmoUsername?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(profile.venmoPaymentLink?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || profile.venmoQRCode != nil
        let hasZelle = !(profile.zelleContactInfo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(profile.zellePaymentLink?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || profile.zelleQRCode != nil
        
        guard !hasVenmo && !hasZelle else {
            cancelPaymentSetupReminders()
            return
        }
        
        checkPermission { granted in
            guard granted else { return }
            
            // Cancel existing reminders
            self.cancelPaymentSetupReminders()
            
            // Schedule twice daily: 10 AM and 6 PM
            self.scheduleDailyReminder(
                identifier: "payment-setup-morning",
                hour: 10,
                minute: 0,
                needsVenmo: true,
                needsZelle: true
            )
            
            self.scheduleDailyReminder(
                identifier: "payment-setup-evening",
                hour: 18,
                minute: 0,
                needsVenmo: true,
                needsZelle: true
            )
        }
    }
    
    private func scheduleDailyReminder(
        identifier: String,
        hour: Int,
        minute: Int,
        needsVenmo: Bool,
        needsZelle: Bool
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Complete Your Payment Setup"
        
        if needsVenmo && needsZelle {
            content.body = "Add your Venmo or Zelle info to receive payments instantly"
        } else if needsVenmo {
            content.body = "Add your Venmo username to receive payments instantly"
        } else {
            content.body = "Add your Zelle info to receive payments instantly"
        }
        
        content.sound = .default
        content.categoryIdentifier = "PAYMENT_SETUP"
        content.userInfo = ["type": "payment_setup"]
        
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling payment reminder: \(error.localizedDescription)")
            }
        }
    }
    
    func cancelPaymentSetupReminders() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["payment-setup-morning", "payment-setup-evening"]
        )
    }

    // MARK: - Trial Reminders

    func scheduleTrialLastDayReminder(trialEndsAt: Date) {
        let reminderDate = Calendar.current.date(byAdding: .day, value: -1, to: trialEndsAt) ?? trialEndsAt
        let scheduledDate = max(reminderDate, Date().addingTimeInterval(60))

        checkPermission { granted in
            guard granted else { return }

            self.cancelTrialLastDayReminder()

            let content = UNMutableNotificationContent()
            content.title = "Last day of your Dutch trial"
            content.body = "Your trial ends tomorrow. Your plan renews automatically unless you cancel from Apple subscriptions."
            content.sound = .default
            content.categoryIdentifier = "TRIAL_LAST_DAY"
            content.userInfo = ["type": "trial_last_day"]

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: "trial-last-day", content: content, trigger: trigger)

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error scheduling trial last-day reminder: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelTrialLastDayReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["trial-last-day"])
    }

    // MARK: - Receipt Scan Background Reminder

    func notifyReceiptScanContinuesInBackground() {
        cancelReceiptScanBackgroundReminder()
    }

    func cancelReceiptScanBackgroundReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["receipt-scan-background-reminder"]
        )
    }

    func notifyReceiptScanCompleted(documentName: String) {
        requestPermissionIfNeeded { granted in
            guard granted else { return }

            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["receipt-scan-completed"]
            )

            let content = UNMutableNotificationContent()
            content.title = "\(documentName) scan finished"
            content.body = "Your scan finished. Open Dutch to continue."
            content.sound = .default
            content.categoryIdentifier = "RECEIPT_SCAN_COMPLETED"
            content.userInfo = [
                "type": "receipt_scan_completed",
                "documentName": documentName
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "receipt-scan-completed",
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error sending scan completion notification: \(error.localizedDescription)")
                }
            }
        }
    }

    func scheduleScanReadyFollowUpReminder() {
        requestPermissionIfNeeded { granted in
            guard granted else { return }

            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["receipt-scan-ready-follow-up"]
            )

            let content = UNMutableNotificationContent()
            content.title = "Don't forget to settle up"
            content.body = "Your scanned item is ready in Dutch. Open it when you are ready to review and split."
            content.sound = .default
            content.categoryIdentifier = "RECEIPT_SCAN_COMPLETED"
            content.userInfo = ["type": "receipt_scan_follow_up"]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60 * 60, repeats: false)
            let request = UNNotificationRequest(
                identifier: "receipt-scan-ready-follow-up",
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error scheduling scan follow-up reminder: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelScanReadyFollowUpReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["receipt-scan-ready-follow-up"]
        )
    }

    func notifyOfflineUploadsProcessing(count: Int) {
        requestPermissionIfNeeded { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Dutch is processing saved uploads"
            content.body = count == 1
                ? "Your saved receipt or statement is online now and being scanned."
                : "\(count) saved receipts or statements are online now and being scanned."
            content.sound = .default
            content.userInfo = ["type": "offline_uploads_processing"]

            let request = UNNotificationRequest(
                identifier: "offline-uploads-processing",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error sending offline upload processing notification: \(error.localizedDescription)")
                }
            }
        }
    }

    func notifyOfflineUploadsReady(count: Int) {
        requestPermissionIfNeeded { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = count == 1 ? "Your upload is ready" : "Your uploads are ready"
            content.body = "Open Dutch to review and split."
            content.sound = .default
            content.categoryIdentifier = "RECEIPT_SCAN_COMPLETED"
            content.userInfo = ["type": "offline_uploads_ready"]

            let request = UNNotificationRequest(
                identifier: "offline-uploads-ready",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error sending offline upload ready notification: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Group Join Notifications
    
    func notifyGroupMemberJoined(
        groupID: UUID,
        groupName: String,
        memberName: String,
        isLastMember: Bool,
        totalMembers: Int,
        activeMembers: Int
    ) {
        checkPermission { granted in
            guard granted else { return }
            
            let content = UNMutableNotificationContent()
            
            if isLastMember {
                content.title = "Everyone's In!"
                content.body = "All \(totalMembers) members of \(groupName) have joined. Ready to split!"
                content.sound = .defaultCritical
            } else {
                content.title = "\(memberName) Joined!"
                content.body = "\(memberName) just joined \(groupName). \(activeMembers)/\(totalMembers) members ready"
                content.sound = .default
            }
            
            content.categoryIdentifier = "GROUP_MEMBER_JOINED"
            content.userInfo = [
                "type": "group_member_joined",
                "groupId": groupID.uuidString,
                "groupName": groupName,
                "memberName": memberName,
                "isLastMember": isLastMember
            ]
            
            // Show immediately
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let identifier = "group-joined-\(groupID.uuidString)-\(UUID().uuidString)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error sending join notification: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func notifyPaymentOwed(
        expenseID: UUID,
        groupName: String,
        payerName: String,
        expenseDescription: String,
        totalAmount: Double,
        yourShare: Double
    ) {
        checkPermission { granted in
            guard granted else { return }
            
            let content = UNMutableNotificationContent()
            content.title = "Payment Request: \(groupName)"
            content.body = "\(payerName) paid \(String(format: "$%.2f", totalAmount)) for \(expenseDescription). Your share: \(String(format: "$%.2f", yourShare))"
            content.sound = .default
            content.categoryIdentifier = "PAYMENT_REQUEST"
            content.userInfo = [
                "type": "payment_request",
                "expenseId": expenseID.uuidString,
                "groupName": groupName,
                "amount": yourShare
            ]
            
            // Show immediately
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let identifier = "payment-request-\(expenseID.uuidString)-\(UUID().uuidString)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error sending payment reminder: \(error.localizedDescription)")
                } else {
                    print("✅ Payment reminder sent successfully")
                }
            }
        }
    }
    
    /// Notify someone that an expense has been marked as paid
    /// This is sent to people who are OWED money (to let them know payment is coming)
    func notifyExpenseMarkedPaid(
        expenseID: UUID,
        groupName: String,
        markerName: String,
        expenseDescription: String,
        amount: Double
    ) {
        checkPermission { granted in
            guard granted else { return }
            
            let content = UNMutableNotificationContent()
            content.title = "Payment Confirmed: \(groupName)"
            content.body = "\(markerName) marked \(expenseDescription) as paid (\(String(format: "$%.2f", amount)))"
            content.sound = .default
            content.categoryIdentifier = "PAYMENT_CONFIRMED"
            content.userInfo = [
                "type": "payment_confirmed",
                "expenseId": expenseID.uuidString,
                "groupName": groupName
            ]
            
            // Show immediately
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let identifier = "payment-confirmed-\(expenseID.uuidString)-\(UUID().uuidString)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error sending payment confirmation: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Group Activity Notifications

    /// Fires when a teammate (not the current user) adds an expense to a shared group.
    func notifyExpenseAdded(
        byName: String,
        groupName: String,
        description: String,
        amount: Double
    ) {
        checkPermission { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = groupName
            content.body = "\(byName) added \(description) — \(String(format: "$%.2f", amount))"
            content.sound = .default
            content.categoryIdentifier = "GROUP_ACTIVITY"
            content.userInfo = [
                "type": "expense_added",
                "groupName": groupName
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "expense-added-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Fires when every balance in a group reaches zero — completion, not debt collection.
    func notifyGroupFullySettled(groupName: String) {
        checkPermission { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "\(groupName) is fully settled"
            content.body = "Every balance is cleared. Nothing owed, nothing due."
            content.sound = .defaultCritical
            content.categoryIdentifier = "GROUP_SETTLED"
            content.userInfo = [
                "type": "group_settled",
                "groupName": groupName
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "group-settled-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Fires a quiet, non-accusatory signal when the current user has been covering
    /// a disproportionate share of group expenses. Surfaces awareness without confrontation.
    func notifyFairnessSignal(groupName: String) {
        checkPermission { granted in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = groupName
            content.body = "You've covered more shared expenses recently. Worth a check-in."
            content.sound = nil
            content.categoryIdentifier = "FAIRNESS_SIGNAL"
            content.userInfo = [
                "type": "fairness_signal",
                "groupName": groupName
            ]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "fairness-\(groupName.lowercased().replacingOccurrences(of: " ", with: "-"))",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - In-App Banner (for when app is open)
    
    func showInAppJoinBanner(
        memberName: String,
        groupName: String,
        isLastMember: Bool
    ) {
        // Post notification for in-app banner
        let userInfo: [String: Any] = [
            "memberName": memberName,
            "groupName": groupName,
            "isLastMember": isLastMember
        ]
        
        NotificationCenter.default.post(
            name: .showGroupJoinBanner,
            object: nil,
            userInfo: userInfo
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    // Called when notification is received while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let type = notification.request.content.userInfo["type"] as? String
        if type == "receipt_scan_completed" {
            completionHandler([.banner, .sound])
            return
        }

        if type == "receipt_scan_background"
            || type == "receipt_scan_follow_up" {
            completionHandler([])
            return
        }

        // Show banner even when app is open
        completionHandler([.banner, .sound])
    }
    
    // Called when user taps on notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        
        if let type = userInfo["type"] as? String {
            switch type {
            case "payment_setup":
                // Navigate to profile payment section
                NotificationCenter.default.post(name: .openPaymentSetup, object: nil)
                
            case "group_member_joined":
                // Navigate to group detail
                if let groupIdString = userInfo["groupId"] as? String,
                   let groupId = UUID(uuidString: groupIdString) {
                    NotificationCenter.default.post(
                        name: .openGroupDetail,
                        object: nil,
                        userInfo: ["groupId": groupId]
                    )
                }
                
            case "payment_request":
                // Navigate to group detail to pay
                if let expenseIdString = userInfo["expenseId"] as? String {
                    NotificationCenter.default.post(
                        name: .openPaymentRequest,
                        object: nil,
                        userInfo: ["expenseId": expenseIdString]
                    )
                }
                
            case "payment_confirmed":
                if let expenseIdString = userInfo["expenseId"] as? String {
                    NotificationCenter.default.post(
                        name: .openGroupDetail,
                        object: nil,
                        userInfo: ["expenseId": expenseIdString]
                    )
                }

            case "expense_added", "group_settled", "fairness_signal":
                NotificationCenter.default.post(name: .openGroupDetail, object: nil)

            case "receipt_scan_background":
                if response.actionIdentifier == "NEVER_SHOW_SCAN_BACKGROUND" {
                    setScanBackgroundReminderHidden(true)
                } else {
                    NotificationCenter.default.post(name: .openUpload, object: nil)
                }

            case "receipt_scan_completed":
                cancelScanReadyFollowUpReminder()
                NotificationCenter.default.post(name: .openUpload, object: nil)

            case "receipt_scan_follow_up":
                NotificationCenter.default.post(name: .openUpload, object: nil)

            default:
                break
            }
        }
        
        completionHandler()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showGroupJoinBanner = Notification.Name("dutchie.showGroupJoinBanner")
    static let openPaymentSetup = Notification.Name("dutchie.openPaymentSetup")
    static let openGroupDetail = Notification.Name("dutchie.openGroupDetail")
    static let openPaymentRequest = Notification.Name("dutchie.openPaymentRequest")
    static let openUpload = Notification.Name("dutchie.openUpload")
    static let openBalances = Notification.Name("dutchie.openBalances")
    static let showOfflineNetworkAlert = Notification.Name("dutchie.showOfflineNetworkAlert")
    static let dutchieFullReset = Notification.Name("dutchie.fullReset")
    static let subscriptionPurchased = Notification.Name("dutchie.subscriptionPurchased")
}

// MARK: - Notification Categories

extension NotificationManager {
    func registerNotificationCategories() {
        // Payment Setup Category
        let paymentSetupCategory = UNNotificationCategory(
            identifier: "PAYMENT_SETUP",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        // Group Member Joined Category
        let groupJoinedCategory = UNNotificationCategory(
            identifier: "GROUP_MEMBER_JOINED",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        // Payment Request Category
        let paymentRequestCategory = UNNotificationCategory(
            identifier: "PAYMENT_REQUEST",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        // Payment Confirmed Category
        let paymentConfirmedCategory = UNNotificationCategory(
            identifier: "PAYMENT_CONFIRMED",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        let groupActivityCategory = UNNotificationCategory(
            identifier: "GROUP_ACTIVITY",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        let groupSettledCategory = UNNotificationCategory(
            identifier: "GROUP_SETTLED",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        let fairnessCategory = UNNotificationCategory(
            identifier: "FAIRNESS_SIGNAL",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        let trialLastDayCategory = UNNotificationCategory(
            identifier: "TRIAL_LAST_DAY",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        let neverShowScanBackgroundAction = UNNotificationAction(
            identifier: "NEVER_SHOW_SCAN_BACKGROUND",
            title: "Never Show Again",
            options: []
        )

        let scanBackgroundCategory = UNNotificationCategory(
            identifier: "RECEIPT_SCAN_BACKGROUND",
            actions: [neverShowScanBackgroundAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        let scanCompletedCategory = UNNotificationCategory(
            identifier: "RECEIPT_SCAN_COMPLETED",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            paymentSetupCategory,
            groupJoinedCategory,
            paymentRequestCategory,
            paymentConfirmedCategory,
            groupActivityCategory,
            groupSettledCategory,
            fairnessCategory,
            trialLastDayCategory,
            scanBackgroundCategory,
            scanCompletedCategory
        ])
    }
}
