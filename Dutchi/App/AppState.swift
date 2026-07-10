import Foundation
import SwiftUI
import Combine
import UIKit
import RevenueCat
import FirebaseAuth
import FirebaseDatabase

struct SubscriptionPlanMember: Identifiable, Equatable {
    let uid: String
    let memberUUID: UUID
    var name: String
    var phoneNumber: String?
    var isOwner: Bool
    var isPending: Bool
    var joinedAt: Date?

    var id: String { uid }

    var initials: String {
        let parts = name.split(separator: " ")
        let raw = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return raw.isEmpty ? "?" : raw.uppercased()
    }
}

struct DevRemoteUser: Identifiable, Equatable {
    let id: String
    var uid: String?
    var phoneKey: String?
    var phoneNumber: String?
    var name: String
    var sources: [String]
    var groups: [String]
    var isPending: Bool
    var isOwner: Bool

    var resetIdentifier: String {
        phoneNumber?.isEmpty == false ? phoneNumber! : (phoneKey ?? uid ?? id)
    }

    var subtitle: String {
        let phone = phoneNumber?.isEmpty == false ? phoneNumber! : (phoneKey ?? "no phone")
        let uidLabel = uid.map { "uid \($0.prefix(8))" } ?? "no uid"
        return "\(phone) · \(uidLabel)"
    }

    var sourceSummary: String {
        sources.isEmpty ? "remote user" : sources.joined(separator: " · ")
    }

    var groupSummary: String? {
        guard !groups.isEmpty else { return nil }
        return groups.prefix(3).joined(separator: ", ") + (groups.count > 3 ? " +\(groups.count - 3)" : "")
    }
}

@MainActor
final class TrialManager: ObservableObject {
    static let shared = TrialManager()

    struct ScanCreditDebit {
        fileprivate enum Source {
            case subscription
            case trial
            case purchased
        }

        fileprivate let source: Source
        fileprivate let credits: Int
    }

    @Published private(set) var trialStartedAt: Date?
    @Published private(set) var receiptOCRSessionsUsed: Int = 0
    @Published private(set) var subscriptionStartedAt: Date?
    @Published private(set) var subscriptionRenewsAt: Date?
    @Published private(set) var subscriptionPlanName: String?
    @Published private(set) var subscriptionScanAllowance: String?
    @Published private(set) var subscriptionOCRSessionsUsed: Int = 0
    @Published private(set) var subscriptionCreditPeriodStartedAt: Date?
    @Published private(set) var purchasedOCRCreditsRemaining: Int = 0
    @Published private(set) var sharedSubscriptionGroupID: UUID?
    @Published private(set) var sharedSubscriptionGroupName: String?
    @Published private(set) var ownedSubscriptionGroupID: UUID?
    @Published private(set) var ownedSubscriptionGroupName: String?
    @Published private(set) var subscriptionPlanMembers: [SubscriptionPlanMember] = []
    @Published private(set) var subscriptionPlanMemberLimit: Int?
    @Published private(set) var devOverrideActive: Bool = false
    @Published var devDateOverride: Date? = nil {
        didSet { promoteScheduledSubscriptionIfNeeded() }
    }

    var currentDate: Date { devDateOverride ?? Date() }

    private let startedKey = "dutchie_trial_started_at_v1"
    private let receiptOCRKey = "dutchie_trial_receipt_ocr_used_v1"
    private let subscriptionStartedKey = "dutchie_subscription_started_at_v1"
    private let subscriptionRenewsKey = "dutchie_subscription_renews_at_v1"
    private let subscriptionPlanKey = "dutchie_subscription_plan_name_v1"
    private let subscriptionScanAllowanceKey = "dutchie_subscription_scan_allowance_v1"
    private let subscriptionOCRUsedKey = "dutchie_subscription_receipt_ocr_used_v1"
    private let subscriptionCreditPeriodStartedKey = "dutchie_subscription_credit_period_started_at_v1"
    private let purchasedOCRCreditsKey = "dutchie_purchased_ocr_credits_remaining_v1"
    private let subscriptionUpdatedKey = "dutchie_subscription_updated_at_v1"
    private let sharedSubscriptionGroupIDKey = "dutchie_shared_subscription_group_id_v1"
    private let sharedSubscriptionGroupNameKey = "dutchie_shared_subscription_group_name_v1"
    private let ownedSubscriptionGroupIDKey = "dutchie_owned_subscription_group_id_v1"
    private let ownedSubscriptionGroupNameKey = "dutchie_owned_subscription_group_name_v1"
    private let subscriptionMemberUUIDPrefix = "dutchie_subscription_member_uuid_v1"
    private let devOverrideKey = "dutchie_dev_override_active_v1"
    private let ref = Database.database().reference()
    private let isoFormatter = ISO8601DateFormatter()
    private var subscriptionPoolHandle: DatabaseHandle?
    private var observedSubscriptionPoolGroupID: UUID?
    let maxReceiptOCRSessions = 20
    let trialDurationDays = 3
    let freeActiveGroupLimit = 1
    let freeSplitHistoryLimit = 5
    let paidSplitHistoryLimit = 100

    private init() {
        trialStartedAt = UserDefaults.standard.object(forKey: startedKey) as? Date
        receiptOCRSessionsUsed = UserDefaults.standard.integer(forKey: receiptOCRKey)
        subscriptionStartedAt = UserDefaults.standard.object(forKey: subscriptionStartedKey) as? Date
        subscriptionRenewsAt = UserDefaults.standard.object(forKey: subscriptionRenewsKey) as? Date
        subscriptionPlanName = UserDefaults.standard.string(forKey: subscriptionPlanKey)
        subscriptionScanAllowance = UserDefaults.standard.string(forKey: subscriptionScanAllowanceKey)
        subscriptionOCRSessionsUsed = UserDefaults.standard.integer(forKey: subscriptionOCRUsedKey)
        subscriptionCreditPeriodStartedAt = UserDefaults.standard.object(forKey: subscriptionCreditPeriodStartedKey) as? Date
        purchasedOCRCreditsRemaining = UserDefaults.standard.integer(forKey: purchasedOCRCreditsKey)
        if let sharedGroupIDString = UserDefaults.standard.string(forKey: sharedSubscriptionGroupIDKey) {
            sharedSubscriptionGroupID = UUID(uuidString: sharedGroupIDString)
        }
        sharedSubscriptionGroupName = UserDefaults.standard.string(forKey: sharedSubscriptionGroupNameKey)
        if let ownedGroupIDString = UserDefaults.standard.string(forKey: ownedSubscriptionGroupIDKey) {
            ownedSubscriptionGroupID = UUID(uuidString: ownedGroupIDString)
        }
        ownedSubscriptionGroupName = UserDefaults.standard.string(forKey: ownedSubscriptionGroupNameKey)
        promoteScheduledSubscriptionIfNeeded()
        observeSubscriptionPoolIfNeeded()
    }

    var hasStartedTrial: Bool { trialStartedAt != nil }
    var hasScheduledSubscription: Bool { subscriptionStartedAt != nil }
    var hasFutureScheduledSubscription: Bool {
        guard let subscriptionStartedAt else { return false }
        return currentDate < subscriptionStartedAt
    }

    var hasActiveSubscription: Bool {
        if hasSharedSubscriptionAccess { return true }
        guard let subscriptionStartedAt else { return false }
        guard currentDate >= subscriptionStartedAt else { return false }
        guard let subscriptionRenewsAt else { return true }
        return currentDate < subscriptionRenewsAt
    }

    var hasSharedSubscriptionAccess: Bool {
        sharedSubscriptionGroupID != nil
    }

    var activeSubscriptionPoolGroupID: UUID? {
        ownedSubscriptionGroupID ?? sharedSubscriptionGroupID
    }

    private func normalizeSubscriptionOwnershipState() {
        if let ownedSubscriptionGroupID,
           sharedSubscriptionGroupID == ownedSubscriptionGroupID {
            sharedSubscriptionGroupID = nil
            sharedSubscriptionGroupName = nil
            UserDefaults.standard.removeObject(forKey: sharedSubscriptionGroupIDKey)
            UserDefaults.standard.removeObject(forKey: sharedSubscriptionGroupNameKey)
            return
        }

        if sharedSubscriptionGroupID != nil,
           ownedSubscriptionGroupID != nil {
            ownedSubscriptionGroupID = nil
            ownedSubscriptionGroupName = nil
            UserDefaults.standard.removeObject(forKey: ownedSubscriptionGroupIDKey)
            UserDefaults.standard.removeObject(forKey: ownedSubscriptionGroupNameKey)
        }
    }

    var hasProAccess: Bool {
        hasActiveSubscription || isTrialActive
    }

    var hasRecurringSubscriptionAccess: Bool {
        hasActiveSubscription || hasFutureScheduledSubscription || hasSharedSubscriptionAccess
    }

    var hasUsableCredits: Bool {
        refreshSubscriptionCreditPeriodIfNeeded()
        return purchasedOCRCreditsRemaining > 0 || (isTrialActive && receiptOCRSessionsRemaining > 0)
    }

    var hasAppEntitlement: Bool {
        hasRecurringSubscriptionAccess || hasUsableCredits
    }

    var trialEndsAt: Date? {
        guard let trialStartedAt else { return nil }
        return Calendar.current.date(byAdding: .day, value: trialDurationDays, to: trialStartedAt)
    }

    var isTrialActive: Bool {
        guard let trialEndsAt else { return false }
        return currentDate < trialEndsAt
    }

    var isTrialExpired: Bool {
        hasStartedTrial && !isTrialActive
    }

    var daysRemaining: Int {
        guard let trialEndsAt else { return trialDurationDays }
        let start = Calendar.current.startOfDay(for: currentDate)
        let end = Calendar.current.startOfDay(for: trialEndsAt)
        return max(0, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0)
    }

    var receiptOCRSessionsRemaining: Int {
        max(0, maxReceiptOCRSessions - receiptOCRSessionsUsed)
    }

    var subscriptionOCRSessionLimit: Int? {
        if let subscriptionScanAllowance {
            let digits = subscriptionScanAllowance.prefix { $0.isNumber }
            if let explicitLimit = Int(digits) {
                return explicitLimit
            }
        }

        return inferredSubscriptionOCRLimit
    }

    private var inferredSubscriptionOCRLimit: Int? {
        guard let subscriptionPlanName else { return nil }
        let plan = subscriptionPlanName.lowercased()

        if plan.contains("6 people") || plan.contains("6-person") {
            if plan.contains("week") {
                return 60
            }
            return 250
        }

        if plan.contains("monthly group")
            || plan.contains("yearly group")
            || plan.contains("shared dutch pro")
            || plan.contains("shared dutchi pro") {
            return 250
        }

        if plan.contains("group pass") {
            return 60
        }

        if plan.contains("group") {
            if plan.contains("week") {
                return 60
            }
            return 250
        }

        if plan.contains("5 people") || plan.contains("5-person") {
            return 100
        }

        if plan.contains("lite") || plan.contains("3 people") || plan.contains("3-person") {
            return 100
        }

        if plan.contains("week") {
            return 40
        }

        if plan.contains("house") || plan.contains("8 people") || plan.contains("8-person") {
            return 250
        }

        return nil
    }

    var subscriptionOCRSessionsRemaining: Int? {
        refreshSubscriptionCreditPeriodIfNeeded()
        guard let subscriptionOCRSessionLimit else { return nil }
        return max(0, subscriptionOCRSessionLimit - subscriptionOCRSessionsUsed)
    }

    var subscriptionMemberLimit: Int? {
        // Plan name is derived from the actual purchase and is always authoritative.
        // subscriptionPlanMemberLimit (restored from Firebase) can carry stale values from
        // a prior session with a different plan, so plan-name parsing wins when available.
        if let planName = subscriptionPlanName {
            let lp = planName.lowercased()
            if lp.contains("weekly group pass") || lp.contains("monthly group")
                || lp.contains("yearly group") || lp.contains("group pass") { return 6 }
            if lp.contains("lite") || lp.contains("3 people") || lp.contains("3-person") { return 3 }
            if lp.contains("group") || lp.contains("6 people") || lp.contains("6-person")
                || lp.contains("5 people") || lp.contains("5-person") { return 6 }
            if lp.contains("house") || lp.contains("8 people") || lp.contains("8-person") { return 8 }
        }
        // Fall back to Firebase-restored value only when plan name is absent or unrecognised.
        return subscriptionPlanMemberLimit
    }

    var canUseReceiptOCR: Bool {
        canUseReceiptOCRCredits(1)
    }

    func canUseReceiptOCRCredits(_ credits: Int) -> Bool {
        refreshSubscriptionCreditPeriodIfNeeded()
        let requiredCredits = max(1, credits)
        if hasActiveSubscription {
            if let subscriptionOCRSessionsRemaining,
               subscriptionOCRSessionsRemaining >= requiredCredits {
                return true
            }
            return purchasedOCRCreditsRemaining >= requiredCredits
        }
        return isTrialActive && receiptOCRSessionsRemaining >= requiredCredits
            || purchasedOCRCreditsRemaining >= requiredCredits
    }

    var receiptOCRAllowanceText: String {
        if hasActiveSubscription {
            if let remaining = subscriptionOCRSessionsRemaining,
               let limit = subscriptionOCRSessionLimit {
                let extra = purchasedOCRCreditsRemaining > 0 ? " + \(purchasedOCRCreditsRemaining)" : ""
                return "\(remaining)/\(limit)\(extra)"
            }
            return subscriptionScanAllowance ?? "Pro limit"
        }
        let extra = purchasedOCRCreditsRemaining > 0 ? " + \(purchasedOCRCreditsRemaining)" : ""
        return "\(receiptOCRSessionsRemaining)/\(maxReceiptOCRSessions)\(extra)"
    }

    func startTrialIfNeeded() {
        guard trialStartedAt == nil else { return }
        let now = Date()
        trialStartedAt = now
        receiptOCRSessionsUsed = 0
        UserDefaults.standard.set(now, forKey: startedKey)
        UserDefaults.standard.set(0, forKey: receiptOCRKey)
        if let trialEndsAt {
            NotificationManager.shared.scheduleTrialLastDayReminder(trialEndsAt: trialEndsAt)
        }
        pushSubscriptionStateToFirebase()
    }

    var isOutOfIncludedOCRCredits: Bool {
        refreshSubscriptionCreditPeriodIfNeeded()
        if purchasedOCRCreditsRemaining > 0 { return false }
        if hasActiveSubscription {
            return (subscriptionOCRSessionsRemaining ?? Int.max) <= 0
        }
        if isTrialActive {
            return receiptOCRSessionsRemaining <= 0
        }
        return isTrialExpired
    }

    var creditResetDescription: String {
        if hasActiveSubscription,
           let resetDate = subscriptionCreditPeriodEndsAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: resetDate)
        }
        if isTrialExpired { return "the trial has ended" }
        return "your credits reset"
    }

    var subscriptionCreditPeriodEndsAt: Date? {
        guard let start = subscriptionCreditPeriodStartedAt ?? subscriptionStartedAt else { return nil }
        let lowercasedPlan = (subscriptionPlanName ?? "").lowercased()
        let component: Calendar.Component = lowercasedPlan.contains("week") ? .day : .month
        let value = lowercasedPlan.contains("week") ? 7 : 1
        return Calendar.current.date(byAdding: component, value: value, to: start)
    }

    func addPurchasedOCRCredits(_ credits: Int) {
        let creditsToAdd = max(0, credits)
        guard creditsToAdd > 0 else { return }
        purchasedOCRCreditsRemaining += creditsToAdd
        UserDefaults.standard.set(purchasedOCRCreditsRemaining, forKey: purchasedOCRCreditsKey)
        markLocalSubscriptionStateChanged()
        pushSubscriptionStateToFirebase()
        objectWillChange.send()
    }

    @discardableResult
    func consumeReceiptOCRSession(credits: Int = 1) -> Bool {
        consumeReceiptOCRCredits(credits: credits) != nil
    }

    @discardableResult
    func consumeReceiptOCRCredits(credits: Int = 1) -> ScanCreditDebit? {
        refreshSubscriptionCreditPeriodIfNeeded()
        let requiredCredits = max(1, credits)
        guard canUseReceiptOCRCredits(requiredCredits) else { return nil }

        if hasActiveSubscription {
            if let subscriptionOCRSessionsRemaining,
               subscriptionOCRSessionsRemaining >= requiredCredits {
                subscriptionOCRSessionsUsed += requiredCredits
                UserDefaults.standard.set(subscriptionOCRSessionsUsed, forKey: subscriptionOCRUsedKey)
                markLocalSubscriptionStateChanged()
                objectWillChange.send()
                return ScanCreditDebit(source: .subscription, credits: requiredCredits)
            }
            purchasedOCRCreditsRemaining -= requiredCredits
            UserDefaults.standard.set(purchasedOCRCreditsRemaining, forKey: purchasedOCRCreditsKey)
            markLocalSubscriptionStateChanged()
            objectWillChange.send()
            return ScanCreditDebit(source: .purchased, credits: requiredCredits)
        }

        if isTrialActive && receiptOCRSessionsRemaining >= requiredCredits {
            receiptOCRSessionsUsed += requiredCredits
            UserDefaults.standard.set(receiptOCRSessionsUsed, forKey: receiptOCRKey)
            markLocalSubscriptionStateChanged()
            objectWillChange.send()
            return ScanCreditDebit(source: .trial, credits: requiredCredits)
        }

        purchasedOCRCreditsRemaining -= requiredCredits
        UserDefaults.standard.set(purchasedOCRCreditsRemaining, forKey: purchasedOCRCreditsKey)
        markLocalSubscriptionStateChanged()
        objectWillChange.send()
        return ScanCreditDebit(source: .purchased, credits: requiredCredits)
    }

    func commitReceiptOCRCredits(_ debit: ScanCreditDebit?) {
        guard let debit else { return }
        switch debit.source {
        case .subscription:
            if activeSubscriptionPoolGroupID != nil {
                incrementSharedSubscriptionOCRUsage(by: debit.credits)
            } else {
                pushSubscriptionStateToFirebase()
            }
        case .trial, .purchased:
            pushSubscriptionStateToFirebase()
        }
    }

    func refundReceiptOCRCredits(_ debit: ScanCreditDebit?) {
        guard let debit else { return }
        let credits = max(1, debit.credits)

        switch debit.source {
        case .subscription:
            subscriptionOCRSessionsUsed = max(0, subscriptionOCRSessionsUsed - credits)
            UserDefaults.standard.set(subscriptionOCRSessionsUsed, forKey: subscriptionOCRUsedKey)
        case .trial:
            receiptOCRSessionsUsed = max(0, receiptOCRSessionsUsed - credits)
            UserDefaults.standard.set(receiptOCRSessionsUsed, forKey: receiptOCRKey)
        case .purchased:
            purchasedOCRCreditsRemaining += credits
            UserDefaults.standard.set(purchasedOCRCreditsRemaining, forKey: purchasedOCRCreditsKey)
        }

        markLocalSubscriptionStateChanged()
        objectWillChange.send()
    }

    private func markLocalSubscriptionStateChanged() {
        UserDefaults.standard.set(Date(), forKey: subscriptionUpdatedKey)
    }

    private func refreshSubscriptionCreditPeriodIfNeeded() {
        guard hasActiveSubscription,
              let periodStart = subscriptionCreditPeriodStartedAt ?? subscriptionStartedAt,
              let periodEnd = subscriptionCreditPeriodEndsAt,
              currentDate >= periodEnd else { return }

        var nextStart = periodStart
        var nextEnd = periodEnd
        while currentDate >= nextEnd,
              let advancedStart = nextPeriodStart(after: nextStart),
              let advancedEnd = nextPeriodStart(after: nextEnd) {
            nextStart = advancedStart
            nextEnd = advancedEnd
        }

        subscriptionCreditPeriodStartedAt = nextStart
        subscriptionOCRSessionsUsed = 0
        // Clear purchased credits on renewal — packs are per-period, not permanent carry-over
        purchasedOCRCreditsRemaining = 0
        UserDefaults.standard.set(nextStart, forKey: subscriptionCreditPeriodStartedKey)
        UserDefaults.standard.set(0, forKey: subscriptionOCRUsedKey)
        UserDefaults.standard.set(0, forKey: purchasedOCRCreditsKey)
        pushSubscriptionStateToFirebase()
        objectWillChange.send()
    }

    private func nextPeriodStart(after date: Date) -> Date? {
        let lowercasedPlan = (subscriptionPlanName ?? "").lowercased()
        if lowercasedPlan.contains("week") {
            return Calendar.current.date(byAdding: .day, value: 7, to: date)
        }
        return Calendar.current.date(byAdding: .month, value: 1, to: date)
    }

    private func incrementSharedSubscriptionOCRUsage(by credits: Int) {
        guard NetworkStatusMonitor.shared.isOnline,
              let groupID = activeSubscriptionPoolGroupID else {
            pushSubscriptionStateToFirebase()
            return
        }

        let usageRef = ref.child("subscriptions")
            .child(groupID.uuidString)
            .child("subscriptionOCRSessionsUsed")

        usageRef.runTransactionBlock { currentData in
            let currentValue = Self.remoteInt(currentData.value) ?? 0
            currentData.value = currentValue + max(1, credits)
            return TransactionResult.success(withValue: currentData)
        } andCompletionBlock: { [weak self] error, committed, snapshot in
            guard let manager = self else { return }
            Task { @MainActor in
                if let error {
                    print("Failed to update shared OCR usage: \(error.localizedDescription)")
                    manager.publishOwnedSubscriptionPoolIfNeeded()
                    manager.pushSubscriptionStateToFirebase()
                    return
                }

                if committed,
                   let sharedUsage = Self.remoteInt(snapshot?.value) {
                    manager.subscriptionOCRSessionsUsed = sharedUsage
                    UserDefaults.standard.set(sharedUsage, forKey: manager.subscriptionOCRUsedKey)
                    manager.ref.child("subscriptions")
                        .child(groupID.uuidString)
                        .child("subscriptionOCRCreditsUsed")
                        .setValue(sharedUsage)
                    manager.ref.child("groups")
                        .child(groupID.uuidString)
                        .child("subscription")
                        .child("subscriptionOCRSessionsUsed")
                        .setValue(sharedUsage)
                    manager.ref.child("groups")
                        .child(groupID.uuidString)
                        .child("subscription")
                        .child("subscriptionOCRCreditsUsed")
                        .setValue(sharedUsage)
                }

                manager.pushSubscriptionStateToFirebase()
                manager.objectWillChange.send()
            }
        }
    }

    private func decrementSharedSubscriptionOCRUsage(by credits: Int) {
        guard NetworkStatusMonitor.shared.isOnline,
              let groupID = activeSubscriptionPoolGroupID else {
            pushSubscriptionStateToFirebase()
            return
        }

        let usageRef = ref.child("subscriptions")
            .child(groupID.uuidString)
            .child("subscriptionOCRSessionsUsed")

        usageRef.runTransactionBlock { currentData in
            let currentValue = Self.remoteInt(currentData.value) ?? 0
            currentData.value = max(0, currentValue - max(1, credits))
            return TransactionResult.success(withValue: currentData)
        } andCompletionBlock: { [weak self] error, committed, snapshot in
            guard let manager = self else { return }
            Task { @MainActor in
                if let error {
                    print("Failed to refund shared OCR usage: \(error.localizedDescription)")
                    manager.publishOwnedSubscriptionPoolIfNeeded()
                    manager.pushSubscriptionStateToFirebase()
                    return
                }

                if committed,
                   let sharedUsage = Self.remoteInt(snapshot?.value) {
                    manager.subscriptionOCRSessionsUsed = sharedUsage
                    UserDefaults.standard.set(sharedUsage, forKey: manager.subscriptionOCRUsedKey)
                    manager.ref.child("subscriptions")
                        .child(groupID.uuidString)
                        .child("subscriptionOCRCreditsUsed")
                        .setValue(sharedUsage)
                    manager.ref.child("groups")
                        .child(groupID.uuidString)
                        .child("subscription")
                        .child("subscriptionOCRSessionsUsed")
                        .setValue(sharedUsage)
                    manager.ref.child("groups")
                        .child(groupID.uuidString)
                        .child("subscription")
                        .child("subscriptionOCRCreditsUsed")
                        .setValue(sharedUsage)
                }

                manager.pushSubscriptionStateToFirebase()
                manager.objectWillChange.send()
            }
        }
    }

    // MARK: - Developer Controls (restricted to dev phone)

    // MARK: - Developer Controls (restricted to dev phone)

    func devResetAll() {
        devEngageOverride()
        devDetachPoolObserver()
        // Zero all state first so Firebase receives the wiped values
        trialStartedAt = nil; receiptOCRSessionsUsed = 0
        subscriptionStartedAt = nil; subscriptionRenewsAt = nil
        subscriptionPlanName = nil; subscriptionScanAllowance = nil
        subscriptionOCRSessionsUsed = 0; subscriptionCreditPeriodStartedAt = nil
        purchasedOCRCreditsRemaining = 0
        sharedSubscriptionGroupID = nil; sharedSubscriptionGroupName = nil
        ownedSubscriptionGroupID = nil; ownedSubscriptionGroupName = nil
        subscriptionPlanMembers = []; subscriptionPlanMemberLimit = nil
        // Keep devOverrideActive = true (set by devEngageOverride above) to block
        // syncSubscriptionStatusWithFirebase from re-activating via RevenueCat after reset.
        // devPushStateToFirebase doesn't check devOverrideActive, so it still runs.
        devPushStateToFirebase()
        // Stop all group observers and delete owned group Firebase data while still signed in
        GroupManager.shared.fullReset()
        // Wipe ALL local data and signal the app to navigate to fresh start
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        objectWillChange.send()
        NotificationCenter.default.post(name: .dutchieFullReset, object: nil)
    }

    func wipeAllLocalData() {
        devDetachPoolObserver()
        // Stop all group observers and delete owned group Firebase data while still signed in
        GroupManager.shared.fullReset()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        trialStartedAt = nil; receiptOCRSessionsUsed = 0
        subscriptionStartedAt = nil; subscriptionRenewsAt = nil
        subscriptionPlanName = nil; subscriptionScanAllowance = nil
        subscriptionOCRSessionsUsed = 0; subscriptionCreditPeriodStartedAt = nil
        purchasedOCRCreditsRemaining = 0
        sharedSubscriptionGroupID = nil; sharedSubscriptionGroupName = nil
        ownedSubscriptionGroupID = nil; ownedSubscriptionGroupName = nil
        subscriptionPlanMembers = []; subscriptionPlanMemberLimit = nil
        // Do NOT touch devOverrideActive here — if devResetAll() set it true we must keep it
        // true so that syncSubscriptionStatusWithFirebase() stays blocked after sign-out.
        objectWillChange.send()
        NotificationCenter.default.post(name: .dutchieFullReset, object: nil)
    }

    func devClearSubscription() {
        devEngageOverride()
        subscriptionStartedAt = nil; subscriptionRenewsAt = nil
        subscriptionPlanName = nil; subscriptionScanAllowance = nil
        subscriptionOCRSessionsUsed = 0; subscriptionCreditPeriodStartedAt = nil
        let ud = UserDefaults.standard
        [subscriptionStartedKey, subscriptionRenewsKey, subscriptionPlanKey,
         subscriptionScanAllowanceKey, subscriptionCreditPeriodStartedKey].forEach { ud.removeObject(forKey: $0) }
        ud.set(0, forKey: subscriptionOCRUsedKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devResetTrial() {
        devEngageOverride()
        trialStartedAt = nil; receiptOCRSessionsUsed = 0
        UserDefaults.standard.removeObject(forKey: startedKey)
        UserDefaults.standard.set(0, forKey: receiptOCRKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devForceTrialStart() {
        devEngageOverride()
        let now = Date()
        trialStartedAt = now; receiptOCRSessionsUsed = 0
        UserDefaults.standard.set(now, forKey: startedKey)
        UserDefaults.standard.set(0, forKey: receiptOCRKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devForceSubscriptionActive(days: Int = 30) {
        devEngageOverride()
        let now = Date()
        let renewsAt = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        if trialStartedAt == nil { trialStartedAt = now; UserDefaults.standard.set(now, forKey: startedKey) }
        subscriptionStartedAt = now; subscriptionRenewsAt = renewsAt
        subscriptionPlanName = "Dev Pro"; subscriptionScanAllowance = "250 credits/month"
        subscriptionOCRSessionsUsed = 0; subscriptionCreditPeriodStartedAt = now
        let ud = UserDefaults.standard
        ud.set(now, forKey: subscriptionStartedKey); ud.set(renewsAt, forKey: subscriptionRenewsKey)
        ud.set("Dev Pro", forKey: subscriptionPlanKey)
        ud.set("250 credits/month", forKey: subscriptionScanAllowanceKey)
        ud.set(0, forKey: subscriptionOCRUsedKey); ud.set(now, forKey: subscriptionCreditPeriodStartedKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devForceSubscriptionExpired() {
        devEngageOverride()
        let past = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        subscriptionRenewsAt = past
        UserDefaults.standard.set(past, forKey: subscriptionRenewsKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devSetOCRCredits(_ count: Int) {
        devEngageOverride()
        purchasedOCRCreditsRemaining = count
        UserDefaults.standard.set(count, forKey: purchasedOCRCreditsKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devSetSubscriptionOCRRemaining(_ remaining: Int) {
        devEngageOverride()
        let limit = subscriptionOCRSessionLimit ?? 250
        subscriptionOCRSessionsUsed = max(0, limit - max(0, remaining))
        UserDefaults.standard.set(subscriptionOCRSessionsUsed, forKey: subscriptionOCRUsedKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devSetTrialOCRRemaining(_ remaining: Int) {
        devEngageOverride()
        receiptOCRSessionsUsed = max(0, maxReceiptOCRSessions - max(0, remaining))
        UserDefaults.standard.set(receiptOCRSessionsUsed, forKey: receiptOCRKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devSetOCRUsed(_ count: Int) {
        devEngageOverride()
        subscriptionOCRSessionsUsed = max(0, count)
        receiptOCRSessionsUsed = max(0, count)
        UserDefaults.standard.set(subscriptionOCRSessionsUsed, forKey: subscriptionOCRUsedKey)
        UserDefaults.standard.set(receiptOCRSessionsUsed, forKey: receiptOCRKey)
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devClearGroupState() {
        devEngageOverride()
        devDetachPoolObserver()
        sharedSubscriptionGroupID = nil; sharedSubscriptionGroupName = nil
        ownedSubscriptionGroupID = nil; ownedSubscriptionGroupName = nil
        subscriptionPlanMembers = []; subscriptionPlanMemberLimit = nil
        let ud = UserDefaults.standard
        [sharedSubscriptionGroupIDKey, sharedSubscriptionGroupNameKey,
         ownedSubscriptionGroupIDKey, ownedSubscriptionGroupNameKey].forEach { ud.removeObject(forKey: $0) }
        devPushStateToFirebase()
        objectWillChange.send()
    }

    func devFetchRemoteUsers(completion: @escaping ([DevRemoteUser], String?) -> Void) {
        guard NetworkStatusMonitor.shared.isOnline else {
            completion([], "Turn on Wi-Fi or cellular data first.")
            return
        }

        struct RemoteUserAccumulator {
            var uid: String?
            var phoneKey: String?
            var phoneNumber: String?
            var name: String?
            var sources: Set<String> = []
            var groups: Set<String> = []
            var isPending = false
            var isOwner = false
        }

        ref.observeSingleEvent(of: .value) { snapshot in
            guard let root = snapshot.value as? [String: Any] else {
                completion([], "No remote data found.")
                return
            }

            var users: [String: RemoteUserAccumulator] = [:]

            func normalizePhone(_ phone: String?) -> String? {
                guard let digits = phone?.filter(\.isNumber), !digits.isEmpty else { return nil }
                return digits.hasPrefix("1") && digits.count == 11 ? String(digits.dropFirst()) : digits
            }

            func normalizedName(_ data: [String: Any]) -> String? {
                let raw = data["profileName"] as? String
                    ?? data["displayName"] as? String
                    ?? data["name"] as? String
                    ?? data["fullName"] as? String
                let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }

            func merge(
                uid: String?,
                phoneNumber: String?,
                phoneKey explicitPhoneKey: String? = nil,
                name: String?,
                source: String,
                group: String? = nil,
                isPending: Bool = false,
                isOwner: Bool = false
            ) {
                let normalizedPhone = normalizePhone(phoneNumber) ?? normalizePhone(explicitPhoneKey)
                let key = normalizedPhone.map { "phone:\($0)" }
                    ?? uid.map { "uid:\($0)" }
                    ?? "unknown:\(source):\(name ?? UUID().uuidString)"

                var user = users[key] ?? RemoteUserAccumulator()
                if user.uid == nil, let uid, !uid.isEmpty { user.uid = uid }
                if user.phoneKey == nil, let normalizedPhone { user.phoneKey = normalizedPhone }
                if user.phoneNumber == nil {
                    if let phoneNumber, !phoneNumber.isEmpty {
                        user.phoneNumber = phoneNumber
                    } else if let normalizedPhone {
                        user.phoneNumber = normalizedPhone
                    }
                }
                if let name, !name.isEmpty, user.name == nil || user.name?.hasPrefix("Member ") == true {
                    user.name = name
                }
                user.sources.insert(source)
                if let group, !group.isEmpty { user.groups.insert(group) }
                user.isPending = user.isPending || isPending
                user.isOwner = user.isOwner || isOwner
                users[key] = user
            }

            if let members = root["members"] as? [String: Any] {
                for (phoneKey, rawValue) in members {
                    guard let data = rawValue as? [String: Any] else { continue }
                    merge(
                        uid: data["uid"] as? String,
                        phoneNumber: data["phoneNumber"] as? String,
                        phoneKey: phoneKey,
                        name: normalizedName(data),
                        source: "members"
                    )
                }
            }

            if let verifiedUsers = root["verifiedUsers"] as? [String: Any] {
                for (uid, rawValue) in verifiedUsers {
                    guard let data = rawValue as? [String: Any] else { continue }
                    merge(
                        uid: uid,
                        phoneNumber: data["phoneNumber"] as? String,
                        name: normalizedName(data),
                        source: "verified"
                    )
                }
            }

            if let verifiedByPhone = root["verifiedUsersByPhone"] as? [String: Any] {
                for (phoneKey, rawValue) in verifiedByPhone {
                    guard let data = rawValue as? [String: Any] else { continue }
                    merge(
                        uid: data["uid"] as? String,
                        phoneNumber: data["phoneNumber"] as? String,
                        phoneKey: phoneKey,
                        name: normalizedName(data),
                        source: "verified phone"
                    )
                }
            }

            if let memberships = root["subscriptionMemberships"] as? [String: Any] {
                for (uid, rawValue) in memberships {
                    guard let data = rawValue as? [String: Any] else { continue }
                    merge(
                        uid: uid,
                        phoneNumber: data["phoneNumber"] as? String,
                        name: normalizedName(data),
                        source: "subscription access"
                    )
                }
            }

            if let subscriptions = root["subscriptions"] as? [String: Any] {
                for (subscriptionID, rawValue) in subscriptions {
                    guard let data = rawValue as? [String: Any] else { continue }
                    let groupName = data["groupName"] as? String ?? data["name"] as? String ?? String(subscriptionID.prefix(8))
                    merge(
                        uid: data["uid"] as? String ?? (subscriptionID.contains("-") ? nil : subscriptionID),
                        phoneNumber: data["phoneNumber"] as? String,
                        name: normalizedName(data),
                        source: "subscription owner",
                        group: groupName,
                        isOwner: true
                    )

                    guard let members = data["members"] as? [String: Any] else { continue }
                    for (memberKey, memberRawValue) in members {
                        guard let memberData = memberRawValue as? [String: Any] else { continue }
                        merge(
                            uid: memberData["uid"] as? String ?? (memberKey.hasPrefix("pending_") ? nil : memberKey),
                            phoneNumber: memberData["phoneNumber"] as? String,
                            name: normalizedName(memberData),
                            source: "subscription member",
                            group: groupName,
                            isPending: memberData["isPending"] as? Bool ?? memberKey.hasPrefix("pending_"),
                            isOwner: memberData["isOwner"] as? Bool ?? false
                        )
                    }
                }
            }

            if let groups = root["groups"] as? [String: Any] {
                for (groupID, rawValue) in groups {
                    guard let groupData = rawValue as? [String: Any],
                          let members = groupData["members"] as? [String: Any] else { continue }
                    let groupName = groupData["name"] as? String ?? groupData["groupName"] as? String ?? String(groupID.prefix(8))
                    for (memberID, memberRawValue) in members {
                        guard let memberData = memberRawValue as? [String: Any] else { continue }
                        merge(
                            uid: memberData["uid"] as? String,
                            phoneNumber: memberData["phoneNumber"] as? String,
                            name: normalizedName(memberData),
                            source: "group member",
                            group: groupName,
                            isPending: memberData["isPending"] as? Bool ?? memberID.hasPrefix("pending_"),
                            isOwner: memberData["isOwner"] as? Bool ?? false
                        )
                    }
                }
            }

            let remoteUsers = users.map { key, user in
                DevRemoteUser(
                    id: key,
                    uid: user.uid,
                    phoneKey: user.phoneKey,
                    phoneNumber: user.phoneNumber,
                    name: user.name ?? user.phoneNumber.map { "Member \($0.suffix(4))" } ?? user.uid.map { "UID \($0.prefix(8))" } ?? "Unknown user",
                    sources: Array(user.sources).sorted(),
                    groups: Array(user.groups).sorted(),
                    isPending: user.isPending,
                    isOwner: user.isOwner
                )
            }
            .sorted { lhs, rhs in
                if lhs.isOwner != rhs.isOwner { return lhs.isOwner }
                if lhs.isPending != rhs.isPending { return !lhs.isPending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

            completion(remoteUsers, nil)
        }
    }

    func devResetRemoteUser(identifier rawIdentifier: String, completion: @escaping (String) -> Void) {
        guard NetworkStatusMonitor.shared.isOnline else {
            completion("Turn on Wi-Fi or cellular data first.")
            return
        }

        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Enter a UID or phone number.")
            return
        }

        let digits = trimmed.filter(\.isNumber)
        let phoneKey = normalizedPhoneKey(digits)
        let uidCandidate = digits.count >= 10 ? nil : trimmed

        func performReset(uid: String?, phoneKey: String?) {
            var updates: [String: Any?] = [:]
            if let uid, !uid.isEmpty {
                updates["subscriptionMemberships/\(uid)"] = nil
                updates["subscriptions/\(uid)"] = nil
                updates["verifiedUsers/\(uid)"] = nil
            }
            if let phoneKey, !phoneKey.isEmpty {
                updates["verifiedUsersByPhone/\(phoneKey)"] = nil
                updates["members/\(phoneKey)"] = nil
            }

            let firebaseUpdates = updates.mapValues { $0 ?? NSNull() }
            ref.updateChildValues(firebaseUpdates)

            ref.child("subscriptions").observeSingleEvent(of: .value) { snapshot in
                guard let subscriptions = snapshot.value as? [String: Any] else { return }
                for (subscriptionID, rawValue) in subscriptions {
                    guard let subscription = rawValue as? [String: Any],
                          let members = subscription["members"] as? [String: Any] else { continue }
                    for (memberKey, memberRawValue) in members {
                        guard let memberData = memberRawValue as? [String: Any] else { continue }
                        let memberUID = memberData["uid"] as? String
                        let memberPhoneKey = self.normalizedPhoneKey(memberData["phoneNumber"] as? String)
                        let uidMatches = uid?.isEmpty == false && (memberKey == uid || memberUID == uid)
                        let phoneMatches = phoneKey?.isEmpty == false && memberPhoneKey == phoneKey
                        guard uidMatches || phoneMatches else { continue }
                        self.ref.child("subscriptions").child(subscriptionID).child("members").child(memberKey).removeValue()
                    }
                }
            }

            ref.child("groups").observeSingleEvent(of: .value) { snapshot in
                guard let groups = snapshot.value as? [String: Any] else { return }
                for (groupID, rawValue) in groups {
                    guard let group = rawValue as? [String: Any],
                          let members = group["members"] as? [String: Any] else { continue }
                    for (memberID, memberRawValue) in members {
                        guard let memberData = memberRawValue as? [String: Any] else { continue }
                        let memberUID = memberData["uid"] as? String
                        let memberPhoneKey = self.normalizedPhoneKey(memberData["phoneNumber"] as? String)
                        let uidMatches = uid?.isEmpty == false && (memberID == uid || memberUID == uid)
                        let phoneMatches = phoneKey?.isEmpty == false && memberPhoneKey == phoneKey
                        guard uidMatches || phoneMatches else { continue }
                        self.ref.child("groups").child(groupID).child("members").child(memberID).removeValue()
                    }
                }
            }

            completion("Remote reset requested for \(uid ?? phoneKey ?? trimmed).")
        }

        if let phoneKey, digits.count >= 10 {
            ref.child("verifiedUsersByPhone").child(phoneKey).observeSingleEvent(of: .value) { snapshot in
                let uid = (snapshot.value as? [String: Any])?["uid"] as? String
                performReset(uid: uid, phoneKey: phoneKey)
            }
        } else if let uidCandidate, !uidCandidate.isEmpty {
            ref.child("verifiedUsers").child(uidCandidate).observeSingleEvent(of: .value) { snapshot in
                let userData = snapshot.value as? [String: Any]
                let lookupPhoneKey = self.normalizedPhoneKey(userData?["phoneNumber"] as? String) ?? phoneKey
                performReset(uid: uidCandidate, phoneKey: lookupPhoneKey)
            }
        } else {
            performReset(uid: uidCandidate, phoneKey: phoneKey)
        }
    }

    func devDisableOverride() {
        devOverrideActive = false
        UserDefaults.standard.removeObject(forKey: devOverrideKey)
        objectWillChange.send()
    }

    func devSyncFromFirebase() {
        guard !devOverrideActive else { return }
        syncSubscriptionStatusWithFirebase()
        observeSubscriptionPoolIfNeeded()
    }

    private func devEngageOverride() {
        devOverrideActive = true
        // Deliberately NOT persisting — override is session-only.
        // Surviving an app restart would cause confusing stuck states.
    }

    private func devDetachPoolObserver() {
        if let id = observedSubscriptionPoolGroupID, let handle = subscriptionPoolHandle {
            ref.child("subscriptions").child(id.uuidString).removeObserver(withHandle: handle)
        }
        subscriptionPoolHandle = nil
        observedSubscriptionPoolGroupID = nil
    }

    private func devPushStateToFirebase() {
        guard let user = Auth.auth().currentUser,
              NetworkStatusMonitor.shared.isOnline else { return }
        let now = Date()
        UserDefaults.standard.set(now, forKey: subscriptionUpdatedKey)

        var data: [String: Any] = [
            "uid": user.uid,
            "status": subscriptionStatus,
            "receiptOCRSessionsUsed": receiptOCRSessionsUsed,
            "receiptOCRCreditsUsed": receiptOCRSessionsUsed,
            "subscriptionOCRSessionsUsed": subscriptionOCRSessionsUsed,
            "subscriptionOCRCreditsUsed": subscriptionOCRSessionsUsed,
            "purchasedOCRCreditsRemaining": purchasedOCRCreditsRemaining,
            "updatedAt": isoFormatter.string(from: now)
        ]
        // Explicitly null out cleared optional fields so Firebase reflects the reset
        data["trialStartedAt"]     = trialStartedAt.map { isoFormatter.string(from: $0) } ?? NSNull()
        data["subscriptionStartedAt"] = subscriptionStartedAt.map { isoFormatter.string(from: $0) } ?? NSNull()
        data["subscriptionRenewsAt"]  = subscriptionRenewsAt.map { isoFormatter.string(from: $0) } ?? NSNull()
        data["subscriptionPlanName"]  = subscriptionPlanName ?? NSNull()
        data["subscriptionScanAllowance"] = subscriptionScanAllowance ?? NSNull()
        data["sharedSubscriptionGroupID"] = sharedSubscriptionGroupID.map { $0.uuidString } ?? NSNull()
        data["ownedSubscriptionGroupID"]  = ownedSubscriptionGroupID.map { $0.uuidString } ?? NSNull()

        ref.child("subscriptionMemberships").child(user.uid).updateChildValues(data)
        ref.child("subscriptions").child(user.uid).updateChildValues(data)
    }

    func activateSubscription(planName: String, scanAllowance: String, startsAt: Date = Date(), renewsAt: Date?) {
        guard !hasSharedSubscriptionAccess else {
            pushSubscriptionStateToFirebase()
            observeSubscriptionPoolIfNeeded()
            objectWillChange.send()
            return
        }

        startTrialIfNeeded()
        let normalizedRenewsAt = normalizedRenewalDate(from: renewsAt, startsAt: startsAt, planName: planName)
        subscriptionStartedAt = startsAt
        subscriptionRenewsAt = normalizedRenewsAt
        subscriptionPlanName = planName
        subscriptionScanAllowance = scanAllowance
        subscriptionOCRSessionsUsed = 0
        subscriptionCreditPeriodStartedAt = startsAt

        UserDefaults.standard.set(startsAt, forKey: subscriptionStartedKey)
        if let normalizedRenewsAt {
            UserDefaults.standard.set(normalizedRenewsAt, forKey: subscriptionRenewsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: subscriptionRenewsKey)
        }
        UserDefaults.standard.set(planName, forKey: subscriptionPlanKey)
        UserDefaults.standard.set(scanAllowance, forKey: subscriptionScanAllowanceKey)
        UserDefaults.standard.set(0, forKey: subscriptionOCRUsedKey)
        UserDefaults.standard.set(startsAt, forKey: subscriptionCreditPeriodStartedKey)
        UserDefaults.standard.set(Date(), forKey: subscriptionUpdatedKey)
        if startsAt <= Date() {
            NotificationManager.shared.cancelTrialLastDayReminder()
        } else if let trialEndsAt {
            NotificationManager.shared.scheduleTrialLastDayReminder(trialEndsAt: trialEndsAt)
        }
        pushSubscriptionStateToFirebase()
        publishOwnedSubscriptionPoolIfNeeded()
        observeSubscriptionPoolIfNeeded()
    }

    func activateSharedSubscriptionAccess(groupID: UUID, groupName: String, ownerPhone: String? = nil) {
        sharedSubscriptionGroupID = groupID
        sharedSubscriptionGroupName = groupName
        ownedSubscriptionGroupID = nil
        ownedSubscriptionGroupName = nil
        subscriptionStartedAt = Date()
        subscriptionRenewsAt = nil
        subscriptionPlanName = "Shared Dutch Pro"
        subscriptionScanAllowance = "Pro limit"
        subscriptionOCRSessionsUsed = 0
        subscriptionCreditPeriodStartedAt = subscriptionStartedAt

        UserDefaults.standard.set(groupID.uuidString, forKey: sharedSubscriptionGroupIDKey)
        UserDefaults.standard.set(groupName, forKey: sharedSubscriptionGroupNameKey)
        UserDefaults.standard.removeObject(forKey: ownedSubscriptionGroupIDKey)
        UserDefaults.standard.removeObject(forKey: ownedSubscriptionGroupNameKey)
        UserDefaults.standard.set(subscriptionStartedAt, forKey: subscriptionStartedKey)
        UserDefaults.standard.removeObject(forKey: subscriptionRenewsKey)
        UserDefaults.standard.set(subscriptionPlanName, forKey: subscriptionPlanKey)
        UserDefaults.standard.set(subscriptionScanAllowance, forKey: subscriptionScanAllowanceKey)
        UserDefaults.standard.set(0, forKey: subscriptionOCRUsedKey)
        UserDefaults.standard.set(subscriptionCreditPeriodStartedAt, forKey: subscriptionCreditPeriodStartedKey)
        UserDefaults.standard.set(Date(), forKey: subscriptionUpdatedKey)
        NotificationManager.shared.cancelTrialLastDayReminder()
        pushSubscriptionStateToFirebase()
        objectWillChange.send()
        observeSubscriptionPoolIfNeeded()
        syncSharedSubscriptionFromOwner(phoneNumber: ownerPhone, groupID: groupID, groupName: groupName)
    }

    func rollbackFailedSharedSubscriptionJoin(groupID: UUID, phoneNumber: String? = nil) {
        let wasActiveSharedGroup = sharedSubscriptionGroupID == groupID
        let currentUID = Auth.auth().currentUser?.uid
        let currentPhoneKeys = Set([
            normalizedPhoneKey(Auth.auth().currentUser?.phoneNumber),
            normalizedPhoneKey(phoneNumber)
        ].compactMap { $0 })

        if let uid = currentUID, NetworkStatusMonitor.shared.isOnline {
            ref.child("subscriptions")
                .child(groupID.uuidString)
                .child("members")
                .child(uid)
                .removeValue()

            ref.child("subscriptionMemberships").child(uid).removeValue()
            ref.child("verifiedUsers").child(uid).child("subscription").removeValue()
        }

        if NetworkStatusMonitor.shared.isOnline {
            for currentPhoneKey in currentPhoneKeys {
                ref.child("verifiedUsersByPhone").child(currentPhoneKey).child("subscription").removeValue()
                ref.child("members").child(currentPhoneKey).child("subscription").removeValue()
            }
        }

        subscriptionPlanMembers.removeAll { member in
            if let currentUID, member.uid == currentUID { return true }
            guard let memberPhoneKey = normalizedPhoneKey(member.phoneNumber) else { return false }
            return currentPhoneKeys.contains(memberPhoneKey) && !member.isOwner
        }

        guard wasActiveSharedGroup else {
            objectWillChange.send()
            return
        }

        if let observedSubscriptionPoolGroupID,
           observedSubscriptionPoolGroupID == groupID,
           let subscriptionPoolHandle {
            ref.child("subscriptions")
                .child(groupID.uuidString)
                .removeObserver(withHandle: subscriptionPoolHandle)
            self.observedSubscriptionPoolGroupID = nil
            self.subscriptionPoolHandle = nil
        }

        sharedSubscriptionGroupID = nil
        sharedSubscriptionGroupName = nil
        UserDefaults.standard.removeObject(forKey: sharedSubscriptionGroupIDKey)
        UserDefaults.standard.removeObject(forKey: sharedSubscriptionGroupNameKey)

        if subscriptionPlanMembers.allSatisfy({ !$0.isOwner }) {
            subscriptionPlanMembers.removeAll()
            subscriptionPlanMemberLimit = nil
        }

        objectWillChange.send()
    }

    func activateOwnedSubscriptionGroup(groupID: UUID, groupName: String) {
        guard !hasSharedSubscriptionAccess else {
            return
        }

        if sharedSubscriptionGroupID == groupID {
            sharedSubscriptionGroupID = nil
            sharedSubscriptionGroupName = nil
            UserDefaults.standard.removeObject(forKey: sharedSubscriptionGroupIDKey)
            UserDefaults.standard.removeObject(forKey: sharedSubscriptionGroupNameKey)
        }
        ownedSubscriptionGroupID = groupID
        ownedSubscriptionGroupName = groupName
        UserDefaults.standard.set(groupID.uuidString, forKey: ownedSubscriptionGroupIDKey)
        UserDefaults.standard.set(groupName, forKey: ownedSubscriptionGroupNameKey)
        publishOwnedSubscriptionPoolIfNeeded()
        observeSubscriptionPoolIfNeeded()
        objectWillChange.send()
    }

    func syncCurrentSubscriptionMember(profile: Profile, groupID explicitGroupID: UUID? = nil, groupName explicitGroupName: String? = nil, isOwner: Bool) {
        guard NetworkStatusMonitor.shared.isOnline,
              let user = Auth.auth().currentUser else {
            return
        }

        let groupID = explicitGroupID ?? activeSubscriptionPoolGroupID
        guard let groupID else { return }

        let groupName = explicitGroupName ?? sharedSubscriptionGroupName ?? ownedSubscriptionGroupName ?? "Dutch Group"
        let canWriteAsOwner = isOwner && !hasSharedSubscriptionAccess && ownedSubscriptionGroupID == groupID
        let canWriteGroupOwnerMember = isOwner && !hasSharedSubscriptionAccess
        let memberUUID = subscriptionMemberUUID(forGroupID: groupID, uid: user.uid)
        let displayName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user.displayName! : "Member")
            : profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = user.phoneNumber ?? profile.zelleContactInfo
        let now = isoFormatter.string(from: Date())

        var memberData: [String: Any] = [
            "uid": user.uid,
            "memberUUID": memberUUID.uuidString,
            "name": displayName,
            "isOwner": canWriteGroupOwnerMember,
            "joinedAt": now,
            "updatedAt": now
        ]
        if let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            memberData["phoneNumber"] = phone
        }

        let planRef = ref.child("subscriptions").child(groupID.uuidString)
        let limit = subscriptionMemberLimit ?? subscriptionPlanMemberLimit ?? 6
        if canWriteAsOwner {
            var planData: [String: Any] = [
                "uid": user.uid,
                "groupID": groupID.uuidString,
                "groupName": groupName,
                "status": subscriptionStatus,
                "subscriptionMemberLimit": limit,
                "subscriptionOCRSessionsUsed": subscriptionOCRSessionsUsed,
                "subscriptionOCRCreditsUsed": subscriptionOCRSessionsUsed,
                "ocrCreditUnit": "page",
                "updatedAt": now
            ]
            if let subscriptionStartedAt { planData["subscriptionStartedAt"] = isoFormatter.string(from: subscriptionStartedAt) }
            if let subscriptionRenewsAt { planData["subscriptionRenewsAt"] = isoFormatter.string(from: subscriptionRenewsAt) }
            if let subscriptionCreditPeriodStartedAt { planData["subscriptionCreditPeriodStartedAt"] = isoFormatter.string(from: subscriptionCreditPeriodStartedAt) }
            if let subscriptionPlanName { planData["subscriptionPlanName"] = subscriptionPlanName }
            if let subscriptionScanAllowance { planData["subscriptionScanAllowance"] = subscriptionScanAllowance }
            if let subscriptionOCRSessionLimit { planData["subscriptionOCRSessionLimit"] = subscriptionOCRSessionLimit }
            planRef.updateChildValues(planData)
            planRef.child("members").child(user.uid).updateChildValues(memberData)
        } else if canWriteGroupOwnerMember {
            planRef.updateChildValues([
                "groupID": groupID.uuidString,
                "groupName": groupName,
                "updatedAt": now
            ])
            planRef.child("members").child(user.uid).updateChildValues(memberData)
        } else {
            var nonOwnerMemberData = memberData
            nonOwnerMemberData["isOwner"] = false
            nonOwnerMemberData.removeValue(forKey: "isOwner")
            planRef.observeSingleEvent(of: .value) { snapshot in
                guard snapshot.exists() else { return }
                planRef.child("updatedAt").setValue(now)
                planRef.child("members").child(user.uid).updateChildValues(nonOwnerMemberData)
            }
        }

        var localMembers = subscriptionPlanMembers.filter { $0.uid != user.uid }
        localMembers.append(SubscriptionPlanMember(
            uid: user.uid,
            memberUUID: memberUUID,
            name: displayName,
            phoneNumber: phone,
            isOwner: canWriteAsOwner,
            isPending: false,
            joinedAt: Date()
        ))
        subscriptionPlanMembers = localMembers.sorted { lhs, rhs in
            if lhs.isOwner != rhs.isOwner { return lhs.isOwner }
            return lhs.name < rhs.name
        }
        subscriptionPlanMemberLimit = limit
    }

    func joinSharedSubscriptionPlan(
        groupID: UUID,
        groupName: String,
        ownerPhone: String?,
        profile: Profile,
        fallbackMemberLimit: Int?,
        expectedInvitePhone: String? = nil,
        verifiedPhoneNumber: String? = nil,
        repairMissingInviteSeat: Bool = false,
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard NetworkStatusMonitor.shared.isOnline,
              let user = Auth.auth().currentUser else {
            completion(false, "Turn on Wi-Fi or cellular data to join this plan.")
            return
        }

        let memberUUID = subscriptionMemberUUID(forGroupID: groupID, uid: user.uid)
        let displayName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user.displayName! : "Member")
            : profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = user.phoneNumber ?? verifiedPhoneNumber ?? AuthManager.shared.phoneNumber ?? profile.zelleContactInfo
        let verifiedPhoneKeys = Set([
            normalizedPhoneKey(user.phoneNumber),
            normalizedPhoneKey(profile.zelleContactInfo),
            normalizedPhoneKey(verifiedPhoneNumber),
            normalizedPhoneKey(AuthManager.shared.phoneNumber),
            normalizedPhoneKey(phone)
        ].compactMap { $0 })
        let expectedInvitePhoneKey = normalizedPhoneKey(expectedInvitePhone)
        var candidatePhoneKeys = verifiedPhoneKeys
        if let expectedInvitePhoneKey, verifiedPhoneKeys.contains(expectedInvitePhoneKey) {
            candidatePhoneKeys.insert(expectedInvitePhoneKey)
        }
        let now = isoFormatter.string(from: Date())
        var memberData: [String: Any] = [
            "uid": user.uid,
            "memberUUID": memberUUID.uuidString,
            "name": displayName,
            "profileName": displayName,
            "isOwner": false,
            "isPending": false,
            "sourceGroupID": groupID.uuidString,
            "joinedAt": now,
            "updatedAt": now
        ]
        if let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            memberData["phoneNumber"] = phone
        }
        let localFallbackLimit = fallbackMemberLimit ?? subscriptionMemberLimit ?? 6
        var transactionFailureReason = "Join transaction did not commit."

        print("""
        🔎 SUBSCRIPTION JOIN DEBUG [firebase-start]
        groupID=\(groupID.uuidString)
        groupName=\(groupName)
        firebaseUserUID=\(user.uid)
        firebaseUserPhone=\(user.phoneNumber ?? "nil")
        verifiedPhoneNumber=\(verifiedPhoneNumber ?? "nil")
        authManagerPhone=\(AuthManager.shared.phoneNumber ?? "nil")
        profileZelle=\(profile.zelleContactInfo ?? "nil")
        expectedInvitePhone=\(expectedInvitePhone ?? "nil")
        verifiedPhoneKeys=\(Array(verifiedPhoneKeys).sorted())
        expectedInvitePhoneKey=\(expectedInvitePhoneKey ?? "nil")
        candidatePhoneKeys=\(Array(candidatePhoneKeys).sorted())
        repairMissingInviteSeat=\(repairMissingInviteSeat)
        fallbackLimit=\(localFallbackLimit)
        """)

        let planRef = ref.child("subscriptions").child(groupID.uuidString)
        pruneForeignPendingSubscriptionMembers(groupID: groupID)
        planRef.runTransactionBlock { currentData in
            var repairedMissingRecord = false
            var data = currentData.value as? [String: Any] ?? [:]
            if data.isEmpty {
                guard repairMissingInviteSeat,
                      let expectedInvitePhoneKey,
                      candidatePhoneKeys.contains(expectedInvitePhoneKey) else {
                    transactionFailureReason = "No Firebase subscription record exists at subscriptions/\(groupID.uuidString), and repair is not allowed because the verified phone did not match a group pending invite."
                    print("❌ SUBSCRIPTION JOIN DEBUG [firebase-abort] \(transactionFailureReason)")
                    return TransactionResult.abort()
                }

                repairedMissingRecord = true
                data = [
                    "groupID": groupID.uuidString,
                    "groupName": groupName,
                    "subscriptionMemberLimit": localFallbackLimit,
                    "status": "repaired_from_group_invite",
                    "updatedAt": now,
                    "members": [:]
                ]
                print("🛠️ SUBSCRIPTION JOIN DEBUG [firebase-repair] Created missing subscription shell for \(groupID.uuidString) from matching group invite.")
            }

            var members = data["members"] as? [String: Any] ?? [:]
            let hasOwnerBackedPlan = data["subscriptionStartedAt"] != nil
                || data["subscriptionPlanName"] != nil
                || data["subscriptionMemberLimit"] != nil
                || members.values.contains { rawValue in
                    (rawValue as? [String: Any])?["isOwner"] as? Bool == true
                }
            guard hasOwnerBackedPlan || repairedMissingRecord || repairMissingInviteSeat else {
                transactionFailureReason = "Subscription record exists but is missing owner/plan metadata. keys=\(Array(data.keys).sorted()) memberCount=\(members.count)"
                print("❌ SUBSCRIPTION JOIN DEBUG [firebase-abort] \(transactionFailureReason)")
                return TransactionResult.abort()
            }

            let limit = Self.remoteInt(data["subscriptionMemberLimit"])
                ?? localFallbackLimit
            func sourceMatchesThisGroup(_ member: [String: Any]) -> Bool {
                guard let sourceGroupID = member["sourceGroupID"] as? String,
                      !sourceGroupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return true
                }
                return sourceGroupID == groupID.uuidString
            }
            func debugPhoneKey(_ phone: String?) -> String? {
                guard let digits = phone?.filter(\.isNumber), !digits.isEmpty else { return nil }
                return digits.hasPrefix("1") && digits.count == 11 ? String(digits.dropFirst()) : digits
            }
            func debugRows() -> String {
                members.map { key, rawValue -> String in
                    guard let member = rawValue as? [String: Any] else {
                        return "  - \(key): non-dictionary row"
                    }
                    let rawPhone = member["phoneNumber"] as? String
                    let phoneKey = debugPhoneKey(rawPhone)
                    let sourceGroupID = member["sourceGroupID"] as? String
                    let sourceOK = sourceMatchesThisGroup(member)
                    let phoneOK = phoneKey.map { candidatePhoneKeys.contains($0) } ?? false
                    return """
                      - key=\(key) name=\(member["name"] as? String ?? "nil") pending=\(member["isPending"] as? Bool ?? false) owner=\(member["isOwner"] as? Bool ?? false) left=\(member["hasLeft"] as? Bool ?? false) phone=\(rawPhone ?? "nil") phoneKey=\(phoneKey ?? "nil") phoneMatch=\(phoneOK) source=\(sourceGroupID ?? "nil") sourceOK=\(sourceOK)
                    """
                }
                .sorted()
                .joined(separator: "\n")
            }
            let currentUserMember = members[user.uid] as? [String: Any]
            let isAlreadyMember = currentUserMember.map(sourceMatchesThisGroup) ?? false
            let matchingActiveEntry = members.first { key, rawValue in
                guard key != user.uid,
                      !key.hasPrefix("pending_"),
                      let member = rawValue as? [String: Any],
                      member["isOwner"] as? Bool != true,
                      member["hasLeft"] as? Bool != true,
                      sourceMatchesThisGroup(member),
                      let memberPhoneKey = self.normalizedPhoneKey(member["phoneNumber"] as? String) else {
                    return false
                }
                return candidatePhoneKeys.contains(memberPhoneKey)
            }
            let matchingPendingEntry = members.first { key, rawValue in
                guard key.hasPrefix("pending_"),
                      let pendingData = rawValue as? [String: Any],
                      pendingData["hasLeft"] as? Bool != true,
                      sourceMatchesThisGroup(pendingData),
                      let pendingPhoneKey = self.normalizedPhoneKey(pendingData["phoneNumber"] as? String) else {
                    return false
                }
                return candidatePhoneKeys.contains(pendingPhoneKey)
            }

            let canClaimExistingSeat = isAlreadyMember || matchingActiveEntry != nil || matchingPendingEntry != nil
            let canRepairMissingInviteSeat = repairMissingInviteSeat
                && matchingActiveEntry == nil
                && matchingPendingEntry == nil
                && expectedInvitePhoneKey != nil
                && expectedInvitePhoneKey.map { candidatePhoneKeys.contains($0) } == true

            guard canClaimExistingSeat || canRepairMissingInviteSeat else {
                let expectedMismatchText: String
                if let expectedInvitePhoneKey, !verifiedPhoneKeys.contains(expectedInvitePhoneKey) {
                    expectedMismatchText = "Expected invite phone key \(expectedInvitePhoneKey) is not in verified phone keys \(Array(verifiedPhoneKeys).sorted())."
                } else if expectedInvitePhoneKey == nil {
                    expectedMismatchText = "No expected invite phone key was provided."
                } else {
                    expectedMismatchText = "Expected invite phone key matched verified keys, but no matching subscription member row was found and repairMissingInviteSeat=\(repairMissingInviteSeat)."
                }
                transactionFailureReason = """
                No claimable subscription member row.
                isAlreadyMember=\(isAlreadyMember)
                matchingActiveKey=\(matchingActiveEntry?.key ?? "nil")
                matchingPendingKey=\(matchingPendingEntry?.key ?? "nil")
                canRepairMissingInviteSeat=\(canRepairMissingInviteSeat)
                \(expectedMismatchText)
                subscriptionLimit=\(limit)
                subscriptionMembers:
                \(debugRows())
                """
                print("❌ SUBSCRIPTION JOIN DEBUG [firebase-abort]\n\(transactionFailureReason)")
                return TransactionResult.abort()
            }

            var existingMember = members[user.uid] as? [String: Any]
                ?? matchingActiveEntry?.value as? [String: Any]
                ?? matchingPendingEntry?.value as? [String: Any]
                ?? [:]
            let existingSharedName = (existingMember["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            func isGeneratedMemberName(_ name: String) -> Bool {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("Member") else { return false }
                let suffix = trimmed.dropFirst("Member".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return suffix.isEmpty || suffix.allSatisfy { $0.isNumber }
            }
            if existingMember["joinedAt"] == nil {
                existingMember["joinedAt"] = now
            }
            memberData.forEach { key, value in
                if key == "joinedAt", existingMember["joinedAt"] != nil { return }
                if key == "memberUUID", existingMember["memberUUID"] != nil { return }
                if key == "name",
                   matchingPendingEntry != nil,
                   let existingSharedName,
                   !existingSharedName.isEmpty,
                   !isGeneratedMemberName(existingSharedName) {
                    return
                }
                existingMember[key] = value
            }
            existingMember["uid"] = user.uid
            existingMember["isPending"] = false
            if let activeKey = matchingActiveEntry?.key, activeKey != user.uid {
                members.removeValue(forKey: activeKey)
            }
            if let pendingKey = matchingPendingEntry?.key, pendingKey != user.uid {
                members.removeValue(forKey: pendingKey)
            }
            members[user.uid] = existingMember

            if data["groupID"] == nil { data["groupID"] = groupID.uuidString }
            if data["groupName"] == nil { data["groupName"] = groupName }
            if data["subscriptionMemberLimit"] == nil { data["subscriptionMemberLimit"] = limit }
            if data["updatedAt"] == nil { data["updatedAt"] = now }
            data["members"] = members
            currentData.value = data
            print("""
            ✅ SUBSCRIPTION JOIN DEBUG [firebase-claim]
            isAlreadyMember=\(isAlreadyMember)
            matchingActiveKey=\(matchingActiveEntry?.key ?? "nil")
            matchingPendingKey=\(matchingPendingEntry?.key ?? "nil")
            repairedMissingSeat=\(canRepairMissingInviteSeat)
            repairedMissingRecord=\(repairedMissingRecord)
            wroteUID=\(user.uid)
            """)
            return TransactionResult.success(withValue: currentData)
        } andCompletionBlock: { [weak self] error, committed, snapshot in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    print("❌ SUBSCRIPTION JOIN DEBUG [firebase-error] \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                    return
                }

                guard committed,
                      let data = snapshot?.value as? [String: Any] else {
                    print("❌ SUBSCRIPTION JOIN DEBUG [firebase-not-committed] \(transactionFailureReason)")
                    completion(false, transactionFailureReason)
                    return
                }

                self.activateSharedSubscriptionAccess(groupID: groupID, groupName: groupName, ownerPhone: ownerPhone)
                self.applySubscriptionPoolState(data)
                self.observeSubscriptionPoolIfNeeded()
                completion(true, nil)
            }
        }
    }

    func syncPendingSubscriptionInviteMembers(_ members: [GroupMember], groupID: UUID, sourceGroupID: UUID? = nil) {
        guard NetworkStatusMonitor.shared.isOnline else { return }

        let planRef = ref.child("subscriptions").child(groupID.uuidString).child("members")
        let now = isoFormatter.string(from: Date())
        let sourceGroupIDString = (sourceGroupID ?? groupID).uuidString

        for member in members where !member.isCurrentUser && !member.hasLeft {
            let phone = member.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "pending_\(member.id.uuidString)"
            let name = member.localDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? member.localDisplayName!
                : member.name

            var memberData: [String: Any] = [
                "uid": key,
                "memberUUID": member.id.uuidString,
                "name": name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Invited Member" : name,
                "isOwner": false,
                "isPending": true,
                "sourceGroupID": sourceGroupIDString,
                "updatedAt": now
            ]
            if let phone, !phone.isEmpty {
                memberData["phoneNumber"] = phone
            }

            planRef.child(key).updateChildValues(memberData)
        }
        pruneForeignPendingSubscriptionMembers(groupID: groupID)
    }

    private func pruneForeignPendingSubscriptionMembers(groupID: UUID) {
        guard NetworkStatusMonitor.shared.isOnline else { return }

        let membersRef = ref.child("subscriptions").child(groupID.uuidString).child("members")
        membersRef.observeSingleEvent(of: .value) { snapshot in
            guard let membersData = snapshot.value as? [String: Any] else { return }

            for (key, rawValue) in membersData {
                guard key.hasPrefix("pending_"),
                      let data = rawValue as? [String: Any],
                      data["hasLeft"] as? Bool != true,
                      let sourceGroupID = data["sourceGroupID"] as? String,
                      !sourceGroupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      sourceGroupID != groupID.uuidString else {
                    continue
                }
                membersRef.child(key).removeValue()
            }
        }
    }

    func removePendingSubscriptionInviteMember(_ member: GroupMember, groupID: UUID) {
        guard NetworkStatusMonitor.shared.isOnline else { return }

        let candidateGroupIDs = Set([
            groupID,
            ownedSubscriptionGroupID,
            sharedSubscriptionGroupID
        ].compactMap { $0 })
        let memberUUID = member.id.uuidString
        let phoneKey = normalizedPhoneKey(member.phoneNumber)

        subscriptionPlanMembers.removeAll { planMember in
            guard !planMember.isOwner, planMember.isPending || planMember.joinedAt == nil else { return false }
            if planMember.memberUUID.uuidString == memberUUID { return true }
            guard let phoneKey,
                  let planPhoneKey = normalizedPhoneKey(planMember.phoneNumber) else { return false }
            return phoneKey == planPhoneKey
        }

        for candidateGroupID in candidateGroupIDs {
            let membersRef = ref.child("subscriptions").child(candidateGroupID.uuidString).child("members")
            membersRef.child("pending_\(memberUUID)").removeValue()
            membersRef.observeSingleEvent(of: .value) { [weak self] snapshot in
                guard let self,
                      let membersData = snapshot.value as? [String: Any] else { return }

                for (key, rawValue) in membersData {
                    guard let data = rawValue as? [String: Any] else { continue }
                    let isOwner = data["isOwner"] as? Bool ?? false
                    let isPending = data["isPending"] as? Bool ?? false
                    let joinedAt = data["joinedAt"]
                    guard !isOwner, isPending || joinedAt == nil else { continue }

                    let storedUUID = data["memberUUID"] as? String
                    let storedPhoneKey = self.normalizedPhoneKey(data["phoneNumber"] as? String)
                    let matchesUUID = storedUUID == memberUUID
                    let matchesPhone = phoneKey != nil && storedPhoneKey == phoneKey

                    if matchesUUID || matchesPhone {
                        membersRef.child(key).removeValue()
                    }
                }
            }
        }

        objectWillChange.send()
    }

    func refreshSharedSubscriptionMetadata(groupID: UUID, groupName: String, ownerPhone: String?) {
        guard ownedSubscriptionGroupID != groupID else {
            normalizeSubscriptionOwnershipState()
            observeSubscriptionPoolIfNeeded()
            objectWillChange.send()
            return
        }

        sharedSubscriptionGroupID = groupID
        sharedSubscriptionGroupName = groupName
        normalizeSubscriptionOwnershipState()
        UserDefaults.standard.set(groupID.uuidString, forKey: sharedSubscriptionGroupIDKey)
        UserDefaults.standard.set(groupName, forKey: sharedSubscriptionGroupNameKey)
        observeSubscriptionPoolIfNeeded()
        syncSharedSubscriptionFromOwner(phoneNumber: ownerPhone, groupID: groupID, groupName: groupName)
        objectWillChange.send()
    }

    private func syncSharedSubscriptionFromOwner(phoneNumber: String?, groupID: UUID, groupName: String) {
        guard NetworkStatusMonitor.shared.isOnline,
              let phoneNumber,
              !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let phoneKey = phoneNumber.filter { $0.isNumber }
        guard !phoneKey.isEmpty else { return }

        ref.child("verifiedUsersByPhone").child(phoneKey).observeSingleEvent(of: .value) { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                if let rootData = snapshot.value as? [String: Any],
                   let subscriptionData = rootData["subscription"] as? [String: Any] {
                    self.syncRemoteSubscriptionOwnerMember(rootData, groupID: groupID, groupName: groupName)
                    self.applySharedOwnerSubscriptionState(subscriptionData, groupID: groupID, groupName: groupName)
                    return
                }

                self.ref.child("members").child(phoneKey).observeSingleEvent(of: .value) { [weak self] memberSnapshot in
                    Task { @MainActor in
                        guard let self,
                              let rootData = memberSnapshot.value as? [String: Any],
                              let subscriptionData = rootData["subscription"] as? [String: Any] else { return }
                        self.syncRemoteSubscriptionOwnerMember(rootData, groupID: groupID, groupName: groupName)
                        self.applySharedOwnerSubscriptionState(subscriptionData, groupID: groupID, groupName: groupName)
                    }
                }
            }
        }
    }

    private func syncRemoteSubscriptionOwnerMember(_ data: [String: Any], groupID: UUID, groupName: String) {
        guard NetworkStatusMonitor.shared.isOnline,
              let ownerUID = data["uid"] as? String,
              !ownerUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let now = isoFormatter.string(from: Date())
        let displayName = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = data["phoneNumber"] as? String
        let memberUUID = subscriptionPlanMembers.first(where: { $0.uid == ownerUID })?.memberUUID ?? UUID()
        var memberData: [String: Any] = [
            "uid": ownerUID,
            "memberUUID": memberUUID.uuidString,
            "name": displayName?.isEmpty == false ? displayName! : "Plan owner",
            "isOwner": true,
            "joinedAt": (data["subscription"] as? [String: Any])?["subscriptionStartedAt"] as? String ?? now,
            "updatedAt": now
        ]
        if let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            memberData["phoneNumber"] = phone
        }

        ref.child("subscriptions")
            .child(groupID.uuidString)
            .child("members")
            .child(ownerUID)
            .updateChildValues(memberData)
    }

    private func applySharedOwnerSubscriptionState(_ data: [String: Any], groupID: UUID, groupName: String) {
        guard ownedSubscriptionGroupID != groupID else {
            normalizeSubscriptionOwnershipState()
            observeSubscriptionPoolIfNeeded()
            objectWillChange.send()
            return
        }

        sharedSubscriptionGroupID = groupID
        sharedSubscriptionGroupName = groupName
        normalizeSubscriptionOwnershipState()

        if let startedAt = remoteDate(data["subscriptionStartedAt"]) {
            subscriptionStartedAt = min(startedAt, Date())
        } else {
            subscriptionStartedAt = Date()
        }

        if let renewsAt = remoteDate(data["subscriptionRenewsAt"]) {
            subscriptionRenewsAt = renewsAt
        }

        if let planName = data["subscriptionPlanName"] as? String,
           !planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subscriptionPlanName = planName
        }

        if let scanAllowance = data["subscriptionScanAllowance"] as? String,
           !scanAllowance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subscriptionScanAllowance = scanAllowance
        }

        if let subscriptionUsed = Self.remoteInt(data["subscriptionOCRCreditsUsed"])
            ?? Self.remoteInt(data["subscriptionOCRSessionsUsed"]) {
            subscriptionOCRSessionsUsed = subscriptionUsed
        }
        if let periodStartedAt = remoteDate(data["subscriptionCreditPeriodStartedAt"]) {
            subscriptionCreditPeriodStartedAt = periodStartedAt
        } else {
            subscriptionCreditPeriodStartedAt = subscriptionStartedAt
        }

        UserDefaults.standard.set(groupID.uuidString, forKey: sharedSubscriptionGroupIDKey)
        UserDefaults.standard.set(groupName, forKey: sharedSubscriptionGroupNameKey)
        UserDefaults.standard.set(subscriptionStartedAt, forKey: subscriptionStartedKey)
        if let subscriptionRenewsAt {
            UserDefaults.standard.set(subscriptionRenewsAt, forKey: subscriptionRenewsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: subscriptionRenewsKey)
        }
        if let subscriptionPlanName {
            UserDefaults.standard.set(subscriptionPlanName, forKey: subscriptionPlanKey)
        }
        if let subscriptionScanAllowance {
            UserDefaults.standard.set(subscriptionScanAllowance, forKey: subscriptionScanAllowanceKey)
        }
        UserDefaults.standard.set(subscriptionOCRSessionsUsed, forKey: subscriptionOCRUsedKey)
        if let subscriptionCreditPeriodStartedAt {
            UserDefaults.standard.set(subscriptionCreditPeriodStartedAt, forKey: subscriptionCreditPeriodStartedKey)
        }
        UserDefaults.standard.set(Date(), forKey: subscriptionUpdatedKey)

        pushSubscriptionStateToFirebase()
        observeSubscriptionPoolIfNeeded()
        objectWillChange.send()
    }

    private func publishOwnedSubscriptionPoolIfNeeded() {
        guard !hasSharedSubscriptionAccess,
              let groupID = ownedSubscriptionGroupID,
              let groupName = ownedSubscriptionGroupName,
              hasScheduledSubscription || hasActiveSubscription else {
            return
        }

        publishCurrentSubscriptionPool(groupID: groupID, groupName: groupName)
    }

    private func publishCurrentSubscriptionPool(groupID: UUID, groupName: String) {
        guard NetworkStatusMonitor.shared.isOnline,
              !hasSharedSubscriptionAccess else { return }

        var data: [String: Any] = [
            "groupID": groupID.uuidString,
            "groupName": groupName,
            "status": subscriptionStatus,
            "subscriptionOCRSessionsUsed": subscriptionOCRSessionsUsed,
            "subscriptionOCRCreditsUsed": subscriptionOCRSessionsUsed,
            "ocrCreditUnit": "page",
            "updatedAt": isoFormatter.string(from: Date())
        ]

        if let subscriptionStartedAt { data["subscriptionStartedAt"] = isoFormatter.string(from: subscriptionStartedAt) }
        if let subscriptionRenewsAt { data["subscriptionRenewsAt"] = isoFormatter.string(from: subscriptionRenewsAt) }
        if let subscriptionCreditPeriodStartedAt { data["subscriptionCreditPeriodStartedAt"] = isoFormatter.string(from: subscriptionCreditPeriodStartedAt) }
        if let subscriptionPlanName { data["subscriptionPlanName"] = subscriptionPlanName }
        if let subscriptionScanAllowance { data["subscriptionScanAllowance"] = subscriptionScanAllowance }
        if let subscriptionOCRSessionLimit { data["subscriptionOCRSessionLimit"] = subscriptionOCRSessionLimit }
        if let subscriptionMemberLimit { data["subscriptionMemberLimit"] = subscriptionMemberLimit }

        ref.child("groups")
            .child(groupID.uuidString)
            .child("subscription")
            .updateChildValues(data)

        ref.child("subscriptions")
            .child(groupID.uuidString)
            .updateChildValues(data)
        ensureSubscriptionRecordHasCurrentMember(subscriptionID: groupID.uuidString, groupName: groupName, isOwner: true)
    }

    private func observeSubscriptionPoolIfNeeded() {
        guard NetworkStatusMonitor.shared.isOnline,
              let groupID = activeSubscriptionPoolGroupID else {
            return
        }

        guard observedSubscriptionPoolGroupID != groupID else { return }

        if let observedSubscriptionPoolGroupID,
           let subscriptionPoolHandle {
            ref.child("subscriptions")
                .child(observedSubscriptionPoolGroupID.uuidString)
                .removeObserver(withHandle: subscriptionPoolHandle)
        }

        observedSubscriptionPoolGroupID = groupID
        subscriptionPoolHandle = ref.child("subscriptions")
            .child(groupID.uuidString)
            .observe(.value) { [weak self] snapshot in
                Task { @MainActor in
                    guard let self,
                          let data = snapshot.value as? [String: Any] else { return }
                    self.applySubscriptionPoolState(data)
                }
            }
    }

    private func applySubscriptionPoolState(_ data: [String: Any]) {
        guard !devOverrideActive else { return }
        if let startedAt = remoteDate(data["subscriptionStartedAt"]) {
            subscriptionStartedAt = startedAt
            UserDefaults.standard.set(startedAt, forKey: subscriptionStartedKey)
        }

        if let renewsAt = remoteDate(data["subscriptionRenewsAt"]) {
            subscriptionRenewsAt = renewsAt
            UserDefaults.standard.set(renewsAt, forKey: subscriptionRenewsKey)
        }

        if let planName = data["subscriptionPlanName"] as? String,
           !planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subscriptionPlanName = planName
            UserDefaults.standard.set(planName, forKey: subscriptionPlanKey)
        }

        if let scanAllowance = data["subscriptionScanAllowance"] as? String,
           !scanAllowance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subscriptionScanAllowance = scanAllowance
            UserDefaults.standard.set(scanAllowance, forKey: subscriptionScanAllowanceKey)
        }

        if let subscriptionUsed = Self.remoteInt(data["subscriptionOCRCreditsUsed"])
            ?? Self.remoteInt(data["subscriptionOCRSessionsUsed"]) {
            subscriptionOCRSessionsUsed = subscriptionUsed
            UserDefaults.standard.set(subscriptionUsed, forKey: subscriptionOCRUsedKey)
        }
        if let periodStartedAt = remoteDate(data["subscriptionCreditPeriodStartedAt"]) {
            subscriptionCreditPeriodStartedAt = periodStartedAt
            UserDefaults.standard.set(periodStartedAt, forKey: subscriptionCreditPeriodStartedKey)
        } else if subscriptionCreditPeriodStartedAt == nil,
                  let subscriptionStartedAt {
            subscriptionCreditPeriodStartedAt = subscriptionStartedAt
            UserDefaults.standard.set(subscriptionStartedAt, forKey: subscriptionCreditPeriodStartedKey)
        }

        if let memberLimit = Self.remoteInt(data["subscriptionMemberLimit"]) {
            subscriptionPlanMemberLimit = memberLimit
        }

        subscriptionPlanMembers = parseSubscriptionMembers(from: data["members"])

        UserDefaults.standard.set(Date(), forKey: subscriptionUpdatedKey)
        pushSubscriptionStateToFirebase()
        objectWillChange.send()
    }

    func refreshSubscriptionStatusFromStore() {
        guard !devOverrideActive else { return }
        guard NetworkStatusMonitor.shared.isOnline else { return }

        guard Purchases.isConfigured else {
            promoteScheduledSubscriptionIfNeeded()
            return
        }

        Purchases.shared.getCustomerInfo { [weak self] customerInfo, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    print("Error refreshing subscription status: \(error.localizedDescription)")
                    self.promoteScheduledSubscriptionIfNeeded()
                    return
                }

                let hasActiveEntitlement = customerInfo?.entitlements.active.isEmpty == false
                let hasActiveSubscription = customerInfo?.activeSubscriptions.isEmpty == false

                if hasActiveEntitlement || hasActiveSubscription {
                    // Only auto-sync from RevenueCat if the user has already explicitly
                    // started a trial through our UI. Without this guard, old RevenueCat
                    // sandbox subscriptions (or subscriptions from a previous install)
                    // would silently activate "Pro limit" and lock users into phone
                    // verification even if they never purchased in this session.
                    // Users who need to restore on a new device can tap "Restore Purchases".
                    guard self.hasStartedTrial else {
                        self.promoteScheduledSubscriptionIfNeeded()
                        return
                    }
                    self.syncActiveStoreSubscription(renewsAt: customerInfo?.latestExpirationDate)
                } else if self.isScheduledSubscriptionPastStart {
                    self.promoteScheduledSubscriptionIfNeeded()
                } else {
                    self.promoteScheduledSubscriptionIfNeeded()
                }
            }
        }
    }

    func syncSubscriptionStatusWithFirebase() {
        guard !devOverrideActive else { return }
        guard NetworkStatusMonitor.shared.isOnline else { return }

        guard let user = Auth.auth().currentUser else {
            refreshSubscriptionStatusFromStore()
            return
        }

        backfillMissingSubscriptionMemberSections()

        ref.child("subscriptionMemberships").child(user.uid).observeSingleEvent(of: .value) { [weak self] membershipSnapshot in
            Task { @MainActor in
                guard let self else { return }
                if let data = membershipSnapshot.value as? [String: Any] {
                    self.applyRemoteSubscriptionStateIfUseful(data)
                } else {
                    self.ref.child("subscriptions").child(user.uid).observeSingleEvent(of: .value) { [weak self] snapshot in
                        Task { @MainActor in
                            guard let self else { return }
                            if let data = snapshot.value as? [String: Any] {
                                self.applyRemoteSubscriptionStateIfUseful(data)
                                return
                            }

                            self.refreshSubscriptionStateFromMemberPhoneDocument(user: user)
                        }
                    }
                }

                if self.hasStartedTrial || self.hasScheduledSubscription || self.purchasedOCRCreditsRemaining > 0 {
                    self.pushSubscriptionStateToFirebase()
                }

                self.refreshSubscriptionStatusFromStore()
            }
        }
    }

    private func refreshSubscriptionStateFromMemberPhoneDocument(user: User) {
        guard let phone = user.phoneNumber else { return }
        let phoneKey = phone.filter { $0.isNumber }
        guard !phoneKey.isEmpty else { return }

        ref.child("members")
            .child(phoneKey)
            .child("subscription")
            .observeSingleEvent(of: .value) { [weak self] snapshot in
                Task { @MainActor in
                    guard let self,
                          let data = snapshot.value as? [String: Any] else { return }
                    self.applyRemoteSubscriptionStateIfUseful(data)
                }
            }
    }

    private var isScheduledSubscriptionPastStart: Bool {
        guard let subscriptionStartedAt else { return false }
        return currentDate >= subscriptionStartedAt
    }

    private func syncActiveStoreSubscription(renewsAt: Date?) {
        guard let scheduledStart = subscriptionStartedAt else {
            activateSubscription(
                planName: subscriptionPlanName ?? "Dutch Pro",
                scanAllowance: subscriptionScanAllowance ?? "Pro limit",
                startsAt: Date(),
                renewsAt: renewsAt
            )
            return
        }

        if currentDate >= scheduledStart {
            subscriptionStartedAt = scheduledStart
            subscriptionRenewsAt = normalizedRenewalDate(
                from: renewsAt,
                startsAt: scheduledStart,
                planName: subscriptionPlanName ?? "Dutch Pro"
            )
            UserDefaults.standard.set(scheduledStart, forKey: subscriptionStartedKey)
            if let subscriptionRenewsAt {
                UserDefaults.standard.set(subscriptionRenewsAt, forKey: subscriptionRenewsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: subscriptionRenewsKey)
            }
            NotificationManager.shared.cancelTrialLastDayReminder()
            UserDefaults.standard.set(Date(), forKey: subscriptionUpdatedKey)
            pushSubscriptionStateToFirebase()
            objectWillChange.send()
        } else if let trialEndsAt {
            NotificationManager.shared.scheduleTrialLastDayReminder(trialEndsAt: trialEndsAt)
            pushSubscriptionStateToFirebase()
        }
    }

    private func promoteScheduledSubscriptionIfNeeded() {
        guard !hasSharedSubscriptionAccess else {
            pushSubscriptionStateToFirebase()
            objectWillChange.send()
            return
        }
        guard isScheduledSubscriptionPastStart else { return }
        if subscriptionRenewsAt == nil || (subscriptionRenewsAt ?? .distantPast) <= currentDate {
            subscriptionRenewsAt = normalizedRenewalDate(
                from: subscriptionRenewsAt,
                startsAt: subscriptionStartedAt ?? currentDate,
                planName: subscriptionPlanName ?? "Dutch Pro"
            )
            if let subscriptionRenewsAt {
                UserDefaults.standard.set(subscriptionRenewsAt, forKey: subscriptionRenewsKey)
            }
        }
        NotificationManager.shared.cancelTrialLastDayReminder()
        pushSubscriptionStateToFirebase()
        objectWillChange.send()
    }

    private func clearScheduledSubscription() {
        subscriptionStartedAt = nil
        subscriptionRenewsAt = nil
        subscriptionPlanName = nil
        subscriptionScanAllowance = nil
        subscriptionOCRSessionsUsed = 0
        subscriptionCreditPeriodStartedAt = nil
        sharedSubscriptionGroupID = nil
        sharedSubscriptionGroupName = nil
        ownedSubscriptionGroupID = nil
        ownedSubscriptionGroupName = nil

        UserDefaults.standard.removeObject(forKey: subscriptionStartedKey)
        UserDefaults.standard.removeObject(forKey: subscriptionRenewsKey)
        UserDefaults.standard.removeObject(forKey: subscriptionPlanKey)
        UserDefaults.standard.removeObject(forKey: subscriptionScanAllowanceKey)
        UserDefaults.standard.removeObject(forKey: subscriptionCreditPeriodStartedKey)
        UserDefaults.standard.removeObject(forKey: sharedSubscriptionGroupIDKey)
        UserDefaults.standard.removeObject(forKey: sharedSubscriptionGroupNameKey)
        UserDefaults.standard.removeObject(forKey: ownedSubscriptionGroupIDKey)
        UserDefaults.standard.removeObject(forKey: ownedSubscriptionGroupNameKey)
        UserDefaults.standard.set(0, forKey: subscriptionOCRUsedKey)
        UserDefaults.standard.set(Date(), forKey: subscriptionUpdatedKey)
        NotificationManager.shared.cancelTrialLastDayReminder()
        pushSubscriptionStateToFirebase()
    }

    private func normalizedRenewalDate(from storeDate: Date?, startsAt: Date, planName: String) -> Date? {
        let lowercasedPlan = planName.lowercased()
        let component: Calendar.Component
        let value: Int
        if lowercasedPlan.contains("year") {
            component = .year
            value = 1
        } else if lowercasedPlan.contains("week") {
            component = .day
            value = 7
        } else {
            component = .month
            value = 1
        }

        // Future-starting subscription (during trial): always base renewal on the start
        // date so monthly on Jun 19 → Jul 19, not whatever sandbox gives.
        if startsAt > currentDate {
            return Calendar.current.date(byAdding: component, value: value, to: startsAt)
        }

        // Active subscription: trust the store date only if it's reasonable (≤ 1 period away)
        if let storeDate, storeDate > currentDate, storeDate > startsAt,
           let cap = Calendar.current.date(byAdding: component, value: value, to: startsAt),
           storeDate <= cap {
            return storeDate
        }

        return Calendar.current.date(byAdding: component, value: value, to: max(startsAt, currentDate))
    }

    private func applyRemoteSubscriptionStateIfUseful(_ data: [String: Any]) {
        guard !devOverrideActive else { return }
        guard let remoteUpdatedAt = remoteDate(data["updatedAt"]) else { return }
        let localUpdatedAt = UserDefaults.standard.object(forKey: subscriptionUpdatedKey) as? Date ?? .distantPast

        let remoteHasAccess = (data["trialStartedAt"] as? String) != nil
            || (data["subscriptionStartedAt"] as? String) != nil
            || (Self.remoteInt(data["purchasedOCRCreditsRemaining"]) ?? 0) > 0
        guard remoteHasAccess else { return }
        guard remoteUpdatedAt >= localUpdatedAt || !hasStartedTrial && !hasScheduledSubscription else { return }

        if let trialDate = remoteDate(data["trialStartedAt"]) {
            trialStartedAt = trialDate
            UserDefaults.standard.set(trialDate, forKey: startedKey)
        }
        if let receiptUsed = Self.remoteInt(data["receiptOCRCreditsUsed"])
            ?? Self.remoteInt(data["receiptOCRSessionsUsed"]) {
            receiptOCRSessionsUsed = receiptUsed
            UserDefaults.standard.set(receiptUsed, forKey: receiptOCRKey)
        }
        if let startedAt = remoteDate(data["subscriptionStartedAt"]) {
            subscriptionStartedAt = startedAt
            UserDefaults.standard.set(startedAt, forKey: subscriptionStartedKey)
        }
        if let periodStartedAt = remoteDate(data["subscriptionCreditPeriodStartedAt"]) {
            subscriptionCreditPeriodStartedAt = periodStartedAt
            UserDefaults.standard.set(periodStartedAt, forKey: subscriptionCreditPeriodStartedKey)
        }
        if let renewsAt = remoteDate(data["subscriptionRenewsAt"]) {
            subscriptionRenewsAt = normalizedRenewalDate(
                from: renewsAt,
                startsAt: subscriptionStartedAt ?? Date(),
                planName: subscriptionPlanName ?? (data["subscriptionPlanName"] as? String ?? "Dutch Pro")
            )
            if let subscriptionRenewsAt {
                UserDefaults.standard.set(subscriptionRenewsAt, forKey: subscriptionRenewsKey)
            }
        }
        if let planName = data["subscriptionPlanName"] as? String {
            subscriptionPlanName = planName
            UserDefaults.standard.set(planName, forKey: subscriptionPlanKey)
        }
        if let scanAllowance = data["subscriptionScanAllowance"] as? String {
            subscriptionScanAllowance = scanAllowance
            UserDefaults.standard.set(scanAllowance, forKey: subscriptionScanAllowanceKey)
        }
        if let subscriptionUsed = Self.remoteInt(data["subscriptionOCRCreditsUsed"])
            ?? Self.remoteInt(data["subscriptionOCRSessionsUsed"]) {
            subscriptionOCRSessionsUsed = subscriptionUsed
            UserDefaults.standard.set(subscriptionUsed, forKey: subscriptionOCRUsedKey)
        }
        if let purchasedCredits = Self.remoteInt(data["purchasedOCRCreditsRemaining"]) {
            purchasedOCRCreditsRemaining = max(0, purchasedCredits)
            UserDefaults.standard.set(purchasedOCRCreditsRemaining, forKey: purchasedOCRCreditsKey)
        }
        if let sharedGroupIDString = data["sharedSubscriptionGroupID"] as? String,
           let sharedGroupID = UUID(uuidString: sharedGroupIDString) {
            sharedSubscriptionGroupID = sharedGroupID
            UserDefaults.standard.set(sharedGroupIDString, forKey: sharedSubscriptionGroupIDKey)
        }
        if let sharedGroupName = data["sharedSubscriptionGroupName"] as? String {
            sharedSubscriptionGroupName = sharedGroupName
            UserDefaults.standard.set(sharedGroupName, forKey: sharedSubscriptionGroupNameKey)
        }
        if let ownedGroupIDString = data["ownedSubscriptionGroupID"] as? String,
           let ownedGroupID = UUID(uuidString: ownedGroupIDString) {
            ownedSubscriptionGroupID = ownedGroupID
            UserDefaults.standard.set(ownedGroupIDString, forKey: ownedSubscriptionGroupIDKey)
        }
        if let ownedGroupName = data["ownedSubscriptionGroupName"] as? String {
            ownedSubscriptionGroupName = ownedGroupName
            UserDefaults.standard.set(ownedGroupName, forKey: ownedSubscriptionGroupNameKey)
        }
        normalizeSubscriptionOwnershipState()
        UserDefaults.standard.set(remoteUpdatedAt, forKey: subscriptionUpdatedKey)
        promoteScheduledSubscriptionIfNeeded()
        observeSubscriptionPoolIfNeeded()
        objectWillChange.send()
    }

    private func pushSubscriptionStateToFirebase() {
        guard let user = Auth.auth().currentUser else { return }
        normalizeSubscriptionOwnershipState()

        let now = Date()
        UserDefaults.standard.set(now, forKey: subscriptionUpdatedKey)

        var data: [String: Any] = [
            "uid": user.uid,
            "status": subscriptionStatus,
            "receiptOCRSessionsUsed": receiptOCRSessionsUsed,
            "receiptOCRCreditsUsed": receiptOCRSessionsUsed,
            "maxReceiptOCRSessions": maxReceiptOCRSessions,
            "maxReceiptOCRCredits": maxReceiptOCRSessions,
            "trialCreditAllowance": maxReceiptOCRSessions,
            "trialDurationDays": trialDurationDays,
            "subscriptionOCRSessionsUsed": subscriptionOCRSessionsUsed,
            "subscriptionOCRCreditsUsed": subscriptionOCRSessionsUsed,
            "purchasedOCRCreditsRemaining": purchasedOCRCreditsRemaining,
            "ocrCreditUnit": "page",
            "freeActiveGroupLimit": freeActiveGroupLimit,
            "freeSplitHistoryLimit": freeSplitHistoryLimit,
            "updatedAt": isoFormatter.string(from: now)
        ]

        if let trialStartedAt { data["trialStartedAt"] = isoFormatter.string(from: trialStartedAt) }
        if let trialEndsAt { data["trialEndsAt"] = isoFormatter.string(from: trialEndsAt) }
        if let subscriptionStartedAt { data["subscriptionStartedAt"] = isoFormatter.string(from: subscriptionStartedAt) }
        if let subscriptionRenewsAt { data["subscriptionRenewsAt"] = isoFormatter.string(from: subscriptionRenewsAt) }
        if let subscriptionCreditPeriodStartedAt { data["subscriptionCreditPeriodStartedAt"] = isoFormatter.string(from: subscriptionCreditPeriodStartedAt) }
        if let subscriptionPlanName { data["subscriptionPlanName"] = subscriptionPlanName }
        if let subscriptionScanAllowance { data["subscriptionScanAllowance"] = subscriptionScanAllowance }
        if let subscriptionMemberLimit { data["subscriptionMemberLimit"] = subscriptionMemberLimit }
        if let sharedSubscriptionGroupID { data["sharedSubscriptionGroupID"] = sharedSubscriptionGroupID.uuidString }
        if let sharedSubscriptionGroupName { data["sharedSubscriptionGroupName"] = sharedSubscriptionGroupName }
        if let ownedSubscriptionGroupID { data["ownedSubscriptionGroupID"] = ownedSubscriptionGroupID.uuidString }
        if let ownedSubscriptionGroupName { data["ownedSubscriptionGroupName"] = ownedSubscriptionGroupName }

        if hasSharedSubscriptionAccess {
            ref.child("subscriptionMemberships").child(user.uid).setValue(data)
            ref.child("subscriptions").child(user.uid).removeValue()
        } else if let ownedSubscriptionGroupID {
            ref.child("subscriptions").child(ownedSubscriptionGroupID.uuidString).updateChildValues(data)
            ref.child("subscriptions")
                .child(ownedSubscriptionGroupID.uuidString)
                .child("members")
                .child(user.uid)
                .updateChildValues(
                    currentFirebaseMemberPayload(
                        uid: user.uid,
                        groupID: ownedSubscriptionGroupID,
                        isOwner: true,
                        now: now
                    )
                )
        }

        ref.child("verifiedUsers").child(user.uid).child("subscription").setValue(data)

        if let phone = user.phoneNumber {
            let phoneKey = phone.filter { $0.isNumber }
            ref.child("verifiedUsersByPhone").child(phoneKey).child("subscription").setValue(data)
            ref.child("members").child(phoneKey).child("subscription").setValue(data)
        }
    }

    private func ensureSubscriptionRecordHasCurrentMember(subscriptionID: String, groupName: String?, isOwner: Bool) {
        guard NetworkStatusMonitor.shared.isOnline,
              let user = Auth.auth().currentUser else { return }

        let groupID = UUID(uuidString: subscriptionID)
        let now = Date()
        let memberData = currentFirebaseMemberPayload(
            uid: user.uid,
            groupID: groupID,
            isOwner: isOwner,
            now: now
        )

        let subscriptionRef = ref.child("subscriptions").child(subscriptionID)
        subscriptionRef.child("members").child(user.uid).updateChildValues(memberData)
        if let groupName, !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subscriptionRef.child("groupName").setValue(groupName)
        }
    }

    private func backfillMissingSubscriptionMemberSections() {
        guard NetworkStatusMonitor.shared.isOnline,
              let currentUser = Auth.auth().currentUser else { return }

        let activeGroupIDString = activeSubscriptionPoolGroupID?.uuidString
        let ownedGroupIDString = ownedSubscriptionGroupID?.uuidString

        ref.child("subscriptions").observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self,
                  let records = snapshot.value as? [String: Any] else { return }

            for (subscriptionID, rawValue) in records {
                guard let data = rawValue as? [String: Any] else { continue }
                let existingMembers = data["members"] as? [String: Any]
                if existingMembers?.isEmpty == false { continue }

                if let uid = data["uid"] as? String,
                   !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard uid == currentUser.uid else { continue }
                    let memberData = Self.memberPayloadForBackfill(uid: uid, data: data)
                    self.ref.child("subscriptions")
                        .child(subscriptionID)
                        .child("members")
                        .child(uid)
                        .updateChildValues(memberData)
                    continue
                }

                activeGroupIDString.map { activeGroupID in
                    if subscriptionID == activeGroupID || data["groupID"] as? String == activeGroupID {
                        Task { @MainActor in
                            self.ensureSubscriptionRecordHasCurrentMember(
                                subscriptionID: subscriptionID,
                                groupName: data["groupName"] as? String,
                                isOwner: ownedGroupIDString == activeGroupID
                            )
                        }
                    }
                }
            }

            if records[currentUser.uid] == nil && (self.ownedSubscriptionGroupID != nil || self.hasSharedSubscriptionAccess) {
                Task { @MainActor in
                    self.pushSubscriptionStateToFirebase()
                }
            }
        }
    }

    private func currentFirebaseMemberPayload(uid: String, groupID: UUID?, isOwner: Bool, now: Date) -> [String: Any] {
        let user = Auth.auth().currentUser
        let memberUUID = groupID.map { subscriptionMemberUUID(forGroupID: $0, uid: uid) } ?? UUID()
        let displayName = user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = user?.phoneNumber
        let nowString = isoFormatter.string(from: now)

        var memberData: [String: Any] = [
            "uid": uid,
            "memberUUID": memberUUID.uuidString,
            "name": displayName?.isEmpty == false ? displayName! : "Member",
            "isOwner": isOwner,
            "joinedAt": nowString,
            "updatedAt": nowString
        ]
        if let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            memberData["phoneNumber"] = phone
        }
        return memberData
    }

    private static func memberPayloadForBackfill(uid: String, data: [String: Any]) -> [String: Any] {
        let now = ISO8601DateFormatter().string(from: Date())
        let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = data["phoneNumber"] as? String
        let status = (data["status"] as? String)?.lowercased()
        var memberData: [String: Any] = [
            "uid": uid,
            "memberUUID": UUID().uuidString,
            "name": name?.isEmpty == false ? name! : "Member",
            "isOwner": status != "shared",
            "joinedAt": data["subscriptionStartedAt"] as? String ?? data["trialStartedAt"] as? String ?? now,
            "updatedAt": now
        ]
        if let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            memberData["phoneNumber"] = phone
        }
        return memberData
    }

    private var subscriptionStatus: String {
        normalizeSubscriptionOwnershipState()
        if hasSharedSubscriptionAccess { return "shared" }
        if hasActiveSubscription { return "active" }
        if hasFutureScheduledSubscription { return "scheduled" }
        if isTrialActive { return "trial" }
        if isTrialExpired { return "trialExpired" }
        return "inactive"
    }

    private func remoteDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let string = value as? String { return isoFormatter.date(from: string) }
        if let timestamp = value as? TimeInterval { return Date(timeIntervalSince1970: timestamp) }
        return nil
    }

    private static func remoteInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func parseSubscriptionMembers(from value: Any?) -> [SubscriptionPlanMember] {
        guard let membersData = value as? [String: Any] else { return [] }

        return membersData.compactMap { uid, rawValue in
            guard let data = rawValue as? [String: Any] else { return nil }
            if data["hasLeft"] as? Bool == true { return nil }
            let memberUUID = (data["memberUUID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let joinedAt = remoteDate(data["joinedAt"])
            return SubscriptionPlanMember(
                uid: data["uid"] as? String ?? uid,
                memberUUID: memberUUID,
                name: name?.isEmpty == false ? name! : "Member",
                phoneNumber: data["phoneNumber"] as? String,
                isOwner: data["isOwner"] as? Bool ?? false,
                isPending: data["isPending"] as? Bool ?? false,
                joinedAt: joinedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.isOwner != rhs.isOwner { return lhs.isOwner }
            return lhs.name < rhs.name
        }
    }

    private func normalizedPhoneKey(_ phone: String?) -> String? {
        guard let digits = phone?.filter(\.isNumber), !digits.isEmpty else { return nil }
        return digits.hasPrefix("1") && digits.count == 11 ? String(digits.dropFirst()) : digits
    }

    private func subscriptionMemberUUID(forGroupID groupID: UUID, uid: String) -> UUID {
        if let existing = subscriptionPlanMembers.first(where: { $0.uid == uid })?.memberUUID {
            return existing
        }

        let key = "\(subscriptionMemberUUIDPrefix)_\(groupID.uuidString)_\(uid)"
        if let stored = UserDefaults.standard.string(forKey: key),
           let storedUUID = UUID(uuidString: stored) {
            return storedUUID
        }

        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
        return uuid
    }
}

// MARK: - Statement Types

enum ReceiptAccountType {
    case creditCard
    case debitCard
}

struct ReceiptTransactionItem {
    var description: String
    var amount:      Double
    var date:        String?
    var isDebit:     Bool
}

struct UploadManualDraftItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var amount: String

    init(id: UUID = UUID(), name: String = "", amount: String = "") {
        self.id = id
        self.name = name
        self.amount = amount
    }
}

struct UploadDraftSummary: Identifiable, Equatable {
    var id: UUID
    var savedAt: Date
    var receiptCount: Int
    var manualCount: Int
    var statementCount: Int
    var totalAmount: Double
    var itemPreview: [String]

    var title: String {
        let itemCount = receiptCount + manualCount + statementCount
        return "\(itemCount) item\(itemCount == 1 ? "" : "s") • \(String(format: "$%.2f", totalAmount))"
    }
}

struct UploadedTransaction: Identifiable {
    let id: UUID
    let image: UIImage
    let accountType: ReceiptAccountType
    var items: [ReceiptTransactionItem]
    var allItems: [ReceiptTransactionItem]
    var totalDebits: Double
    var totalCredits: Double
    let sourceType: String
    var dateFilterLabel: String?
    var confidence: Float
    var processingMethod: String
    var processingTimeMs: Int?
    var confidenceReason: String?

    init(
        id: UUID = UUID(),
        image: UIImage,
        accountType: ReceiptAccountType,
        items: [ReceiptTransactionItem],
        allItems: [ReceiptTransactionItem]? = nil,
        totalDebits: Double,
        totalCredits: Double,
        sourceType: String,
        dateFilterLabel: String? = nil,
        confidence: Float = 1.0,
        processingMethod: String = "mistral",
        processingTimeMs: Int? = nil,
        confidenceReason: String? = nil
    ) {
        self.id = id
        self.image = image
        self.accountType = accountType
        self.items = items
        self.allItems = allItems ?? items
        self.totalDebits = totalDebits
        self.totalCredits = totalCredits
        self.sourceType = sourceType
        self.dateFilterLabel = dateFilterLabel
        self.confidence = confidence
        self.processingMethod = processingMethod
        self.processingTimeMs = processingTimeMs
        self.confidenceReason = confidenceReason
    }
}

// MARK: - Uploaded Receipt

struct UploadedReceipt: Identifiable {
    let id: UUID
    let image: UIImage
    let imageData: Data
    var merchant: String
    var total: Double
    var lineItems: [ReceiptLineItem]
    var receiptDate: String?
    var taxAmount: Double?
    var backgroundResultToken: String?
    var subtotal: Double?
    var totalSavings: Double?
    var processingMethod: OCRService.ProcessingMethod
    var currency: String
    var ocrConfidence: Float
    var ocrQualityScore: Float
    var ocrNeedsReview: Bool
    var ocrFallbackReason: String?
    var ocrTotalConfidence: OCRService.TotalConfidence
    var ocrValidationStatus: OCRService.ValidationStatus
    var ocrArithmeticGapCents: Int
    var ocrRoute: String?
    var ocrValidationIssues: [String]
    var ocrProcessingTimeMs: Int?

    init(image: UIImage, ocrResult: OCRService.ReceiptData) {
        self.id               = UUID()
        self.image            = image
        self.imageData        = image.jpegData(compressionQuality: 0.9)
            ?? image.pngData()
            ?? Data()
        self.merchant         = ocrResult.merchant.isEmpty ? "Unknown Merchant" : ocrResult.merchant
        let positiveMerchandiseTotal = ocrResult.merchandiseAmounts.first(where: { $0 > 0 })
        self.total            = ocrResult.grandTotal.flatMap { $0 > 0 ? $0 : nil } ?? positiveMerchandiseTotal ?? 0.0
        self.lineItems        = ocrResult.lineItems
        self.receiptDate      = ocrResult.receiptDate
        self.taxAmount        = ocrResult.taxAmount
        self.subtotal         = nil
        self.totalSavings     = nil
        self.processingMethod = ocrResult.processingMethod
        self.currency         = ocrResult.currency ?? "USD"
        self.backgroundResultToken = ocrResult.backgroundResultToken
        self.ocrConfidence    = ocrResult.confidence
        self.ocrQualityScore  = ocrResult.qualityScore
        self.ocrNeedsReview   = ocrResult.needsReview
        self.ocrFallbackReason = ocrResult.fallbackReason
        self.ocrTotalConfidence = ocrResult.totalConfidence
        self.ocrValidationStatus = ocrResult.validationStatus
        self.ocrArithmeticGapCents = ocrResult.arithmeticGapCents
        self.ocrValidationIssues = ocrResult.validationIssues
        self.ocrRoute = ocrResult.ocrRoute
        self.ocrProcessingTimeMs = ocrResult.processingTimeMs

        print("UploadedReceipt created:")
        print("  Merchant:          \(self.merchant)")
        print("  Total:             \(formatCurrency(self.total, currency: self.currency))")
        print("  Currency:          \(self.currency)")
        print("  Merchandise items: \(ocrResult.merchandiseItems.count)")
        print("  Line items total:  \(self.lineItems.count)")
        print("  Processing method: \(self.processingMethod)")
        print("  Validation:        \(ocrResult.validationStatus) gap=\(ocrResult.arithmeticGapCents)¢")
        if let savings = self.totalSavings, savings > 0 {
            print("  Total savings:     \(formatCurrency(savings, currency: self.currency))")
        }
        print("  Image size:        \(image.size)")
        print("  Data size:         \(imageData.count) bytes")
    }

    var bestImageData: Data {
        if !imageData.isEmpty {
            return imageData
        }
        return image.jpegData(compressionQuality: 0.9)
            ?? image.pngData()
            ?? Data()
    }

    init(
        id: UUID = UUID(),
        imageData: Data,
        merchant: String,
        total: Double,
        lineItems: [ReceiptLineItem],
        receiptDate: String?,
        taxAmount: Double?,
        backgroundResultToken: String?,
        subtotal: Double?,
        totalSavings: Double?,
        processingMethod: OCRService.ProcessingMethod,
        currency: String,
        ocrConfidence: Float = 1.0,
        ocrQualityScore: Float = 1.0,
        ocrNeedsReview: Bool = false,
        ocrFallbackReason: String? = nil,
        ocrTotalConfidence: OCRService.TotalConfidence = .high,
        ocrValidationStatus: OCRService.ValidationStatus = .notValidated,
        ocrArithmeticGapCents: Int = 0,
        ocrValidationIssues: [String] = [],
        ocrRoute: String? = nil,
        ocrProcessingTimeMs: Int? = nil
    ) {
        self.id = id
        self.imageData = imageData
        self.image = UIImage(data: imageData) ?? UIImage()
        self.merchant = merchant
        self.total = total
        self.lineItems = lineItems
        self.receiptDate = receiptDate
        self.taxAmount = taxAmount
        self.backgroundResultToken = backgroundResultToken
        self.subtotal = subtotal
        self.totalSavings = totalSavings
        self.processingMethod = processingMethod
        self.currency = currency
        self.ocrConfidence = ocrConfidence
        self.ocrQualityScore = ocrQualityScore
        self.ocrNeedsReview = ocrNeedsReview
        self.ocrFallbackReason = ocrFallbackReason
        self.ocrTotalConfidence = ocrTotalConfidence
        self.ocrValidationStatus = ocrValidationStatus
        self.ocrArithmeticGapCents = ocrArithmeticGapCents
        self.ocrValidationIssues = ocrValidationIssues
        self.ocrRoute = ocrRoute
        self.ocrProcessingTimeMs = ocrProcessingTimeMs
    }

    mutating func updateWithFullData(_ fullData: OCRService.ReceiptData) {
        if !fullData.merchant.isEmpty { self.merchant = fullData.merchant }
        if let newTotal = fullData.grandTotal, newTotal > 0 { self.total = newTotal }
        self.lineItems        = fullData.lineItems
        self.receiptDate      = fullData.receiptDate
        self.taxAmount        = fullData.taxAmount
        self.subtotal         = nil
        self.totalSavings     = nil
        self.processingMethod = fullData.processingMethod
        self.currency         = fullData.currency ?? self.currency
        self.ocrConfidence    = fullData.confidence
        self.ocrQualityScore  = fullData.qualityScore
        self.ocrNeedsReview   = fullData.needsReview
        self.ocrFallbackReason = fullData.fallbackReason
        self.ocrTotalConfidence = fullData.totalConfidence
        self.ocrValidationStatus = fullData.validationStatus
        self.ocrArithmeticGapCents = fullData.arithmeticGapCents
        self.ocrValidationIssues = fullData.validationIssues
        self.ocrRoute = fullData.ocrRoute
        self.ocrProcessingTimeMs = fullData.processingTimeMs

        print("UploadedReceipt updated:")
        print("  Line items: \(self.lineItems.count)")
        print("  Processing method: \(self.processingMethod)")
    }

    private func formatCurrency(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle  = .currency
        f.currencyCode = currency
        return f.string(from: NSNumber(value: amount)) ?? "$\(String(format: "%.2f", amount))"
    }
}

private struct UploadDraftStore: Codable {
    var drafts: [UploadDraft]
}

private struct UploadDraft: Codable {
    var id: UUID
    var savedAt: Date
    var uploadedReceipts: [UploadedReceiptDraft]
    var manualTransactions: [ManualTransactionDraft]
    var uploadedTransactions: [UploadedTransactionDraft]
    var people: [Person]
    var currentStep: Int
    var manualItems: [UploadManualDraftItem]
    var showManualEntry: Bool

    init(
        id: UUID = UUID(),
        savedAt: Date,
        uploadedReceipts: [UploadedReceiptDraft],
        manualTransactions: [ManualTransactionDraft],
        uploadedTransactions: [UploadedTransactionDraft],
        people: [Person],
        currentStep: Int,
        manualItems: [UploadManualDraftItem],
        showManualEntry: Bool
    ) {
        self.id = id
        self.savedAt = savedAt
        self.uploadedReceipts = uploadedReceipts
        self.manualTransactions = manualTransactions
        self.uploadedTransactions = uploadedTransactions
        self.people = people
        self.currentStep = currentStep
        self.manualItems = manualItems
        self.showManualEntry = showManualEntry
    }

    enum CodingKeys: String, CodingKey {
        case id, savedAt, uploadedReceipts, manualTransactions, uploadedTransactions
        case people, currentStep, manualItems, showManualEntry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        uploadedReceipts = try container.decode([UploadedReceiptDraft].self, forKey: .uploadedReceipts)
        manualTransactions = try container.decode([ManualTransactionDraft].self, forKey: .manualTransactions)
        uploadedTransactions = try container.decode([UploadedTransactionDraft].self, forKey: .uploadedTransactions)
        people = try container.decode([Person].self, forKey: .people)
        currentStep = try container.decode(Int.self, forKey: .currentStep)
        manualItems = try container.decode([UploadManualDraftItem].self, forKey: .manualItems)
        showManualEntry = try container.decode(Bool.self, forKey: .showManualEntry)
    }

    var summary: UploadDraftSummary {
        UploadDraftSummary(
            id: id,
            savedAt: savedAt,
            receiptCount: uploadedReceipts.count,
            manualCount: manualTransactions.count + completeManualItemCount,
            statementCount: uploadedTransactions.count,
            totalAmount: totalAmount,
            itemPreview: previewItems
        )
    }

    var previewItems: [String] {
        let receiptItems = uploadedReceipts.map {
            "Receipt: \($0.merchant) • \(String(format: "$%.2f", $0.total))"
        }
        let savedManualItems = manualTransactions.map {
            "Manual: \($0.name) • \(String(format: "$%.2f", $0.amount))"
        }
        let typedManualItems = manualItems.compactMap { item -> String? in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = Double(item.amount) ?? 0
            guard !name.isEmpty || amount > 0 else { return nil }
            return "Manual: \(name.isEmpty ? "Untitled item" : name) • \(String(format: "$%.2f", amount))"
        }
        let statementItems = uploadedTransactions.flatMap { statement in
            statement.items.map {
                "Statement: \($0.description) • \(String(format: "$%.2f", $0.amount))"
            }
        }

        let expenseItems = receiptItems + savedManualItems + typedManualItems + statementItems
        if !expenseItems.isEmpty {
            return Array(expenseItems.prefix(12))
        }

        return people
            .filter { !$0.isCurrentUser }
            .prefix(12)
            .map { "Person: \($0.name)" }
    }

    var contentFingerprint: String {
        [
            uploadedReceipts.map { "\($0.id.uuidString):\($0.merchant):\($0.total)" }.joined(separator: "|"),
            manualTransactions.map { "\($0.name):\($0.amount)" }.joined(separator: "|"),
            uploadedTransactions.map { "\($0.totalDebits):\($0.items.count)" }.joined(separator: "|"),
            people.map { "\($0.id.uuidString):\($0.name)" }.joined(separator: "|"),
            manualItems.map { "\($0.id.uuidString):\($0.name):\($0.amount)" }.joined(separator: "|"),
            String(showManualEntry)
        ].joined(separator: "#")
    }

    private var completeManualItemCount: Int {
        manualItems.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            Double($0.amount) != nil
        }.count
    }

    private var totalAmount: Double {
        uploadedReceipts.reduce(0) { $0 + $1.total } +
        manualTransactions.reduce(0) { $0 + $1.amount } +
        uploadedTransactions.reduce(0) { $0 + $1.totalDebits } +
        manualItems.reduce(0) { total, item in
            total + (Double(item.amount) ?? 0)
        }
    }

    struct ManualTransactionDraft: Codable {
        var name: String
        var amount: Double
    }

    struct UploadedReceiptDraft: Codable {
        var id: UUID
        var imageData: Data
        var merchant: String
        var total: Double
        var lineItems: [ReceiptLineItem]
        var receiptDate: String?
        var taxAmount: Double?
        var backgroundResultToken: String?
        var subtotal: Double?
        var totalSavings: Double?
        var processingMethod: ProcessingMethodDraft
        var currency: String
        var ocrConfidence: Float?
        var ocrQualityScore: Float?
        var ocrRoute: String?
        var ocrNeedsReview: Bool?
        var ocrFallbackReason: String?
        var ocrTotalConfidence: String?
        var ocrValidationStatus: String?
        var ocrArithmeticGapCents: Int?
        var ocrValidationIssues: [String]?
        var ocrProcessingTimeMs: Int?

        init(_ receipt: UploadedReceipt) {
            id = receipt.id
            imageData = receipt.imageData
            merchant = receipt.merchant
            total = receipt.total
            lineItems = receipt.lineItems
            receiptDate = receipt.receiptDate
            taxAmount = receipt.taxAmount
            backgroundResultToken = receipt.backgroundResultToken
            subtotal = receipt.subtotal
            totalSavings = receipt.totalSavings
            processingMethod = ProcessingMethodDraft(receipt.processingMethod)
            currency = receipt.currency
            ocrConfidence = receipt.ocrConfidence
            ocrQualityScore = receipt.ocrQualityScore
            ocrNeedsReview = receipt.ocrNeedsReview
            ocrFallbackReason = receipt.ocrFallbackReason
            ocrTotalConfidence = Self.totalConfidenceString(receipt.ocrTotalConfidence)
            ocrValidationStatus = receipt.ocrValidationStatus.rawValue
            ocrArithmeticGapCents = receipt.ocrArithmeticGapCents
            ocrValidationIssues = receipt.ocrValidationIssues
            ocrRoute = receipt.ocrRoute
            ocrProcessingTimeMs = receipt.ocrProcessingTimeMs
        }

        var uploadedReceipt: UploadedReceipt {
            UploadedReceipt(
                id: id,
                imageData: imageData,
                merchant: merchant,
                total: total,
                lineItems: lineItems,
                receiptDate: receiptDate,
                taxAmount: taxAmount,
                backgroundResultToken: backgroundResultToken,
                subtotal: subtotal,
                totalSavings: totalSavings,
                processingMethod: processingMethod.value,
                currency: currency,
                ocrConfidence: ocrConfidence ?? 1.0,
                ocrQualityScore: ocrQualityScore ?? 1.0,
                ocrNeedsReview: ocrNeedsReview ?? false,
                ocrFallbackReason: ocrFallbackReason,
                ocrTotalConfidence: Self.totalConfidence(from: ocrTotalConfidence ?? "high"),
                ocrValidationStatus: OCRService.ValidationStatus(rawValue: ocrValidationStatus ?? "") ?? .notValidated,
                ocrArithmeticGapCents: ocrArithmeticGapCents ?? 0,
                ocrValidationIssues: ocrValidationIssues ?? [],
                ocrRoute: ocrRoute,
                ocrProcessingTimeMs: ocrProcessingTimeMs
            )
        }

        private static func totalConfidenceString(_ value: OCRService.TotalConfidence) -> String {
            switch value {
            case .none: return "none"
            case .low: return "low"
            case .medium: return "medium"
            case .high: return "high"
            }
        }

        private static func totalConfidence(from rawValue: String) -> OCRService.TotalConfidence {
            switch rawValue.lowercased() {
            case "none": return .none
            case "low": return .low
            case "medium": return .medium
            case "high": return .high
            default: return .high
            }
        }
    }

    struct UploadedTransactionDraft: Codable {
        var imageData: Data
        var accountType: AccountTypeDraft
        var items: [ReceiptTransactionItemDraft]
        var allItems: [ReceiptTransactionItemDraft]?
        var totalDebits: Double
        var totalCredits: Double
        var sourceType: String?
        var dateFilterLabel: String?
        var confidence: Float?
        var processingMethod: String?
        var processingTimeMs: Int?
        var confidenceReason: String?

        init(_ transaction: UploadedTransaction) {
            imageData = transaction.image.jpegData(compressionQuality: 0.8) ?? Data()
            accountType = AccountTypeDraft(transaction.accountType)
            items = transaction.items.map(ReceiptTransactionItemDraft.init)
            allItems = transaction.allItems.map(ReceiptTransactionItemDraft.init)
            totalDebits = transaction.totalDebits
            totalCredits = transaction.totalCredits
            sourceType = transaction.sourceType
            dateFilterLabel = transaction.dateFilterLabel
            confidence = transaction.confidence
            processingMethod = transaction.processingMethod
            processingTimeMs = transaction.processingTimeMs
            confidenceReason = transaction.confidenceReason
        }

        var uploadedTransaction: UploadedTransaction {
            UploadedTransaction(
                image: UIImage(data: imageData) ?? UIImage(),
                accountType: accountType.value,
                items: items.map(\.receiptTransactionItem),
                allItems: allItems?.map(\.receiptTransactionItem),
                totalDebits: totalDebits,
                totalCredits: totalCredits,
                sourceType: sourceType ?? "screenshot",
                dateFilterLabel: dateFilterLabel,
                confidence: confidence ?? 1.0,
                processingMethod: processingMethod ?? "mistral",
                processingTimeMs: processingTimeMs,
                confidenceReason: confidenceReason
            )
        }
    }

    struct ReceiptTransactionItemDraft: Codable {
        var description: String
        var amount: Double
        var date: String?
        var isDebit: Bool

        init(_ item: ReceiptTransactionItem) {
            description = item.description
            amount = item.amount
            date = item.date
            isDebit = item.isDebit
        }

        var receiptTransactionItem: ReceiptTransactionItem {
            ReceiptTransactionItem(
                description: description,
                amount: amount,
                date: date,
                isDebit: isDebit
            )
        }
    }

    enum AccountTypeDraft: String, Codable {
        case creditCard
        case debitCard

        init(_ accountType: ReceiptAccountType) {
            switch accountType {
            case .creditCard: self = .creditCard
            case .debitCard: self = .debitCard
            }
        }

        var value: ReceiptAccountType {
            switch self {
            case .creditCard: return .creditCard
            case .debitCard: return .debitCard
            }
        }
    }

    enum ProcessingMethodDraft: String, Codable {
        case appleLocal
        case googleVision
        case tabscanner
        case gptAppleOCR
        case paddleVL

        init(_ method: OCRService.ProcessingMethod) {
            switch method {
            case .appleLocal: self = .appleLocal
            case .googleVision: self = .googleVision
            case .tabscanner: self = .tabscanner
            case .gptAppleOCR: self = .gptAppleOCR
            case .paddleVL: self = .paddleVL
            }
        }

        var value: OCRService.ProcessingMethod {
            switch self {
            case .appleLocal: return .appleLocal
            case .googleVision: return .googleVision
            case .tabscanner: return .tabscanner
            case .gptAppleOCR: return .gptAppleOCR
            case .paddleVL: return .paddleVL
            }
        }
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @Published var profile: Profile {
        didSet { saveProfile() }
    }

    @Published var uploadedImages:      [UIImage]         = []
    @Published var uploadedReceipts:    [UploadedReceipt] = []
    @Published var manualTransactions:  [(name: String, amount: Double)] = []
    @Published var uploadedTransactions: [UploadedTransaction]? = nil
    @Published var people:              [Person]          = []
    @Published var transactions:        [Transaction]     = []
    @Published var savedGroups:         [Group]           = []
    @Published var balanceItems:         [BalanceItem]     = [] {
        didSet { saveBalanceItems() }
    }
    @Published var uploadReviewSyncSessionID: UUID        = UUID()
    @Published var preserveReviewTransactionsOnNextReview = false
    @Published var forcePersonalSplitForCurrentUpload = false
    
    @Published var currentStep:         Int               = 0

    private let profileKey      = "savedProfile"
    private let splitHistoryKey = "splitHistory"
    private let balanceItemsKey = "balanceItems"
    private let remoteBalanceItemsPath = "userBalances"
    private let remoteBalanceItemsByPhonePath = "userBalancesByPhone"
    private let uploadDraftFileName = "uploadDraft.json"
    private let maxUploadDraftVersions = 5
    private let uploadDraftVersionInterval: TimeInterval = 30
    private let balanceRef = Database.database().reference()
    private var isLoadingRemoteBalanceItems = false
    private var balanceObserverRegistrations: [(DatabaseReference, DatabaseHandle)] = []

    init() {
        if let savedProfile = Self.loadProfile() {
            self.profile = savedProfile
            print("Loaded saved profile: \(savedProfile.name)")
            if let history = Self.loadSplitHistory() {
                self.profile.splitHistory = history
                print("Loaded \(history.count) split history records")
            }
        } else {
            self.profile = Profile(
                name: UIDevice.current.name,
                paymentMethods: PaymentMethod.defaultMethods()
            )
            print("Created new profile")
        }
        self.people = [Person(name: profile.name, isCurrentUser: true)]
        self.balanceItems = Self.loadBalanceItems()
    }

    // MARK: - Full Reset

    func wipeAllState() {
        // Reset in-memory state to blank
        profile = Profile()  // triggers saveProfile() via didSet
        // Explicitly delete UserDefaults keys as a safety net — ensures no stale data
        // survives even if async operations try to save after this point
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: splitHistoryKey)
        people = [Person(name: "", isCurrentUser: true)]
        transactions = []
        preserveReviewTransactionsOnNextReview = false
        uploadedImages = []
        uploadedReceipts = []
        manualTransactions = []
        uploadedTransactions = nil
        savedGroups = []
        balanceItems = []
        UserDefaults.standard.removeObject(forKey: balanceItemsKey)
        currentStep = 0
        clearUploadDraft()
        objectWillChange.send()
    }

    // MARK: - Persistence

    private func saveProfile() {
        var profileToSave = profile
        let history = profileToSave.splitHistory
        profileToSave.splitHistory = []
        do {
            let data = try JSONEncoder().encode(profileToSave)
            UserDefaults.standard.set(data, forKey: profileKey)
        } catch {
            print("Failed to save profile: \(error.localizedDescription)")
        }
        saveSplitHistory(history)
    }

    private func saveSplitHistory(_ history: [SplitRecord]) {
        do {
            let data = try JSONEncoder().encode(history)
            UserDefaults.standard.set(data, forKey: splitHistoryKey)
        } catch {
            print("Failed to save split history: \(error.localizedDescription)")
        }
    }

    func recordSplitHistory(_ record: SplitRecord) {
        var updated = profile.splitHistory
        updated.removeAll { $0.contentHash == record.contentHash }
        updated.insert(record, at: 0)
        let historyLimit = TrialManager.shared.hasActiveSubscription
            ? TrialManager.shared.paidSplitHistoryLimit
            : TrialManager.shared.freeSplitHistoryLimit
        if updated.count > historyLimit {
            updated = Array(updated.prefix(historyLimit))
        }

        var nextProfile = profile
        nextProfile.splitHistory = updated
        profile = nextProfile
        print("✅ Saved split history record: \(record.formattedTotal)")
    }

    var activeBalanceItems: [BalanceItem] {
        balanceItems
            .filter(\.isActive)
            .sorted { $0.createdAt > $1.createdAt }
    }

    var balanceOweTotal: Double {
        activeBalanceItems
            .filter { $0.type == .owe }
            .reduce(0) { $0 + $1.amount }
    }

    var balanceReceiveTotal: Double {
        activeBalanceItems
            .filter { $0.type == .receive }
            .reduce(0) { $0 + $1.amount }
    }

    var balanceNetTotal: Double {
        balanceReceiveTotal - balanceOweTotal
    }

    func upsertBalanceItems(from settlements: [PaymentLink], receiptId: UUID?, receiptTitle: String?, groupId: UUID? = nil, groupName: String? = nil, createdAt: Date = Date()) {
        guard let currentUser = people.first(where: { $0.isCurrentUser }) else { return }
        let formatter = Self.balanceISOFormatter
        let createdAtString = formatter.string(from: createdAt)
        let updatedAtString = formatter.string(from: Date())
        let receiptString = receiptId?.uuidString
        let groupString = groupId?.uuidString
        let sourceDate = Self.shortBalanceDateFormatter.string(from: createdAt)

        for settlement in settlements where settlement.amount > 0.01 {
            let userOwes = settlement.from.id == currentUser.id || settlement.from.isCurrentUser
            let userReceives = settlement.to.id == currentUser.id || settlement.to.isCurrentUser
            guard userOwes || userReceives else { continue }

            let person = userOwes ? settlement.to : settlement.from
            let type: BalanceItem.ItemType = userOwes ? .owe : .receive
            let stableId = [
                receiptString ?? groupString ?? "split",
                settlement.from.id.uuidString,
                settlement.to.id.uuidString,
                String(format: "%.2f", settlement.amount)
            ]
            .joined(separator: "-")

            let nextItem = BalanceItem(
                id: stableId,
                type: type,
                amount: settlement.amount,
                personName: person.name,
                personPhone: person.phoneNumber,
                personVenmo: person.venmoUsername,
                personVenmoLink: person.venmoLink,
                personZelleContact: person.zelleContact,
                personZelleLink: person.zelleLink,
                receiptId: receiptString,
                receiptTitle: receiptTitle,
                groupId: groupString,
                groupName: groupName,
                status: type == .receive ? .requested : .unpaid,
                createdAt: createdAtString,
                updatedAt: updatedAtString,
                lastReminderAt: nil,
                sourceDate: sourceDate,
                relatedExpenseIds: []
            )

            if let index = balanceItems.firstIndex(where: { $0.id == stableId }) {
                if balanceItems[index].status != .settled && balanceItems[index].status != .archived {
                    balanceItems[index] = nextItem
                }
            } else {
                balanceItems.append(nextItem)
            }
        }
    }

    func markBalanceItemSettled(id: String) {
        guard let index = balanceItems.firstIndex(where: { $0.id == id }) else { return }
        balanceItems[index].status = .settled
        balanceItems[index].updatedAt = Self.balanceISOFormatter.string(from: Date())
    }

    func markBalanceItemRequested(id: String) {
        guard let index = balanceItems.firstIndex(where: { $0.id == id }) else { return }
        balanceItems[index].status = .requested
        let now = Self.balanceISOFormatter.string(from: Date())
        balanceItems[index].updatedAt = now
        balanceItems[index].lastReminderAt = now
    }

    func restoreBalanceItem(id: String) {
        guard let index = balanceItems.firstIndex(where: { $0.id == id }) else { return }
        balanceItems[index].status = balanceItems[index].type == .receive ? .requested : .unpaid
        balanceItems[index].updatedAt = Self.balanceISOFormatter.string(from: Date())
    }

    private func saveBalanceItems() {
        do {
            let data = try JSONEncoder().encode(balanceItems)
            UserDefaults.standard.set(data, forKey: balanceItemsKey)
        } catch {
            print("Failed to save balance items: \(error.localizedDescription)")
        }

        pushBalanceItemsToFirebaseIfPossible()
    }

    func syncBalanceItemsFromFirebaseIfPossible() {
        guard NetworkStatusMonitor.shared.isOnline,
              let uid = Auth.auth().currentUser?.uid else { return }

        let refs = remoteBalanceItemRefs(uid: uid, phoneNumber: AuthManager.shared.phoneNumber)
        guard !refs.isEmpty else { return }

        var pendingCount = refs.count
        var collectedItems: [BalanceItem] = []

        for ref in refs {
            ref.observeSingleEvent(of: .value) { [weak self] snapshot in
                guard let self else { return }

                collectedItems.append(contentsOf: self.decodeBalanceItems(from: snapshot))
                pendingCount -= 1
                guard pendingCount == 0 else { return }

                DispatchQueue.main.async {
                    guard !collectedItems.isEmpty else {
                        self.pushBalanceItemsToFirebaseIfPossible()
                        return
                    }

                    self.mergeRemoteBalanceItems(collectedItems, pushAfterMerge: true)
                }
            }
        }
    }

    func startObservingBalanceItemsFromFirebaseIfPossible() {
        stopObservingBalanceItemsFromFirebase()

        guard NetworkStatusMonitor.shared.isOnline,
              let uid = Auth.auth().currentUser?.uid else { return }

        let refs = remoteBalanceItemRefs(uid: uid, phoneNumber: AuthManager.shared.phoneNumber)
        for ref in refs {
            let handle = ref.observe(.value) { [weak self] snapshot in
                guard let self else { return }
                let remoteItems = self.decodeBalanceItems(from: snapshot)
                DispatchQueue.main.async {
                    self.mergeRemoteBalanceItems(remoteItems, pushAfterMerge: false)
                }
            }
            balanceObserverRegistrations.append((ref, handle))
        }
    }

    func stopObservingBalanceItemsFromFirebase() {
        for (ref, handle) in balanceObserverRegistrations {
            ref.removeObserver(withHandle: handle)
        }
        balanceObserverRegistrations.removeAll()
    }

    private func mergeRemoteBalanceItems(_ remoteItems: [BalanceItem], pushAfterMerge: Bool) {
        guard !remoteItems.isEmpty else { return }

        var mergedByID = Dictionary(uniqueKeysWithValues: balanceItems.map { ($0.id, $0) })
        for remoteItem in remoteItems where remoteItem.groupId == nil {
            if let localItem = mergedByID[remoteItem.id] {
                mergedByID[remoteItem.id] = newerBalanceItem(localItem, remoteItem)
            } else {
                mergedByID[remoteItem.id] = remoteItem
            }
        }

        isLoadingRemoteBalanceItems = true
        balanceItems = mergedByID.values.sorted { $0.createdAt > $1.createdAt }
        isLoadingRemoteBalanceItems = false

        if pushAfterMerge {
            pushBalanceItemsToFirebaseIfPossible()
        }
    }

    private func decodeBalanceItems(from snapshot: DataSnapshot) -> [BalanceItem] {
        snapshot.children.compactMap { child in
            guard let childSnapshot = child as? DataSnapshot,
                  let dict = childSnapshot.value as? [String: Any],
                  JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let item = try? JSONDecoder().decode(BalanceItem.self, from: data) else {
                return nil
            }
            return item
        }
    }

    private func remoteBalanceItemRefs(uid: String, phoneNumber: String?) -> [DatabaseReference] {
        var refs: [DatabaseReference] = [
            balanceRef.child(remoteBalanceItemsPath).child(uid)
        ]

        if let phoneKey = balancePhoneKey(for: phoneNumber), !phoneKey.isEmpty {
            refs.append(balanceRef.child(remoteBalanceItemsByPhonePath).child(phoneKey))
        }

        return refs
    }

    private func balancePhoneKey(for phone: String?) -> String? {
        guard let digits = phone?.filter(\.isNumber), !digits.isEmpty else { return nil }
        if digits.count == 10 { return "1\(digits)" }
        if digits.count == 11, digits.first == "1" { return digits }
        return digits
    }

    private func pushBalanceItemsToFirebaseIfPossible() {
        guard !isLoadingRemoteBalanceItems,
              NetworkStatusMonitor.shared.isOnline,
              let uid = Auth.auth().currentUser?.uid else { return }

        var updates: [String: Any] = [:]
        for item in balanceItems where item.groupId == nil {
            guard let payload = firebasePayload(for: item) else { continue }
            updates["\(remoteBalanceItemsPath)/\(uid)/\(firebaseSafeBalanceKey(item.id))"] = payload
        }

        guard !updates.isEmpty else { return }
        balanceRef.updateChildValues(updates) { error, _ in
            if let error {
                print("Failed to sync balance items: \(error.localizedDescription)")
            }
        }
    }

    func writeBalanceItemToFirebase(uid: String, item: BalanceItem, phoneKey: String? = nil) {
        guard NetworkStatusMonitor.shared.isOnline,
              !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let payload = firebasePayload(for: item) else { return }

        let itemKey = firebaseSafeBalanceKey(item.id)
        var updates: [String: Any] = [
            "\(remoteBalanceItemsPath)/\(uid)/\(itemKey)": payload
        ]

        let normalizedPhoneKey = balancePhoneKey(for: phoneKey)
        if let normalizedPhoneKey, !normalizedPhoneKey.isEmpty {
            updates["\(remoteBalanceItemsByPhonePath)/\(normalizedPhoneKey)/\(itemKey)"] = payload
        }

        balanceRef.updateChildValues(updates) { error, _ in
            if let error {
                print("Failed to write remote balance item: \(error.localizedDescription)")
            } else {
                print("✅ Wrote remote balance item \(item.id) to uid=\(uid.prefix(8)) phoneKey=\(normalizedPhoneKey ?? "none")")
            }
        }
    }

    private func firebasePayload(for item: BalanceItem) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(item),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func newerBalanceItem(_ lhs: BalanceItem, _ rhs: BalanceItem) -> BalanceItem {
        if lhs.status == .settled || lhs.status == .archived,
           rhs.status != .settled && rhs.status != .archived,
           comparableBalanceDate(lhs) == comparableBalanceDate(rhs) {
            return lhs
        }
        if rhs.status == .settled || rhs.status == .archived,
           lhs.status != .settled && lhs.status != .archived,
           comparableBalanceDate(lhs) == comparableBalanceDate(rhs) {
            return rhs
        }
        return comparableBalanceDate(lhs) >= comparableBalanceDate(rhs) ? lhs : rhs
    }

    private func comparableBalanceDate(_ item: BalanceItem) -> Date {
        if let updatedAt = item.updatedAt,
           let date = Self.parseBalanceDate(updatedAt) {
            return date
        }
        if let date = Self.parseBalanceDate(item.createdAt) {
            return date
        }
        return .distantPast
    }

    private func firebaseSafeBalanceKey(_ key: String) -> String {
        Data(key.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func loadBalanceItems() -> [BalanceItem] {
        guard let data = UserDefaults.standard.data(forKey: "balanceItems") else { return [] }
        do {
            return try JSONDecoder().decode([BalanceItem].self, from: data)
        } catch {
            print("Failed to load balance items: \(error.localizedDescription)")
            return []
        }
    }

    private static let balanceISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let shortBalanceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static func parseBalanceDate(_ string: String) -> Date? {
        if let date = balanceISOFormatter.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func loadProfile() -> Profile? {
        guard let data = UserDefaults.standard.data(forKey: "savedProfile") else { return nil }
        do {
            return try JSONDecoder().decode(Profile.self, from: data)
        } catch {
            print("Failed to load profile: \(error.localizedDescription)"); return nil
        }
    }

    private static func loadSplitHistory() -> [SplitRecord]? {
        guard let data = UserDefaults.standard.data(forKey: "splitHistory") else { return nil }
        do {
            return try JSONDecoder().decode([SplitRecord].self, from: data)
        } catch {
            print("Failed to load split history: \(error.localizedDescription)"); return nil
        }
    }

    // MARK: - Upload Draft Persistence

    var hasUploadDraft: Bool {
        !uploadDraftSummaries.isEmpty
    }

    var uploadDraftSummaries: [UploadDraftSummary] {
        loadUploadDraftStore().drafts.map(\.summary)
    }

    func saveUploadDraft(
        manualItems: [UploadManualDraftItem],
        showManualEntry: Bool,
        forceNewVersion: Bool = false
    ) {
        let hasTypedManualItem = manualItems.contains {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !$0.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasDraftContent = !uploadedReceipts.isEmpty ||
            !manualTransactions.isEmpty ||
            !(uploadedTransactions?.isEmpty ?? true) ||
            hasTypedManualItem ||
            people.count > 1

        guard hasDraftContent else { return }

        let draft = UploadDraft(
            id: UUID(),
            savedAt: Date(),
            uploadedReceipts: uploadedReceipts.map(UploadDraft.UploadedReceiptDraft.init),
            manualTransactions: manualTransactions.map {
                UploadDraft.ManualTransactionDraft(name: $0.name, amount: $0.amount)
            },
            uploadedTransactions: (uploadedTransactions ?? []).map(UploadDraft.UploadedTransactionDraft.init),
            people: people,
            currentStep: currentStep,
            manualItems: manualItems,
            showManualEntry: showManualEntry
        )

        var store = loadUploadDraftStore()
        if let newest = store.drafts.first {
            if newest.contentFingerprint == draft.contentFingerprint ||
                (!forceNewVersion &&
                 draft.savedAt.timeIntervalSince(newest.savedAt) < uploadDraftVersionInterval) {
                var replacement = draft
                replacement.id = newest.id
                store.drafts[0] = replacement
            } else {
                store.drafts.insert(draft, at: 0)
            }
        } else {
            store.drafts = [draft]
        }
        store.drafts = Array(store.drafts.prefix(maxUploadDraftVersions))
        saveUploadDraftStore(store)
    }

    func restoreUploadDraft(id: UUID? = nil) -> (manualItems: [UploadManualDraftItem], showManualEntry: Bool)? {
        let store = loadUploadDraftStore()
        let draft: UploadDraft?
        if let id {
            draft = store.drafts.first { $0.id == id }
        } else {
            draft = store.drafts.first
        }
        guard let draft else { return nil }

        uploadedReceipts = draft.uploadedReceipts.map { $0.uploadedReceipt }
        manualTransactions = draft.manualTransactions.map { (name: $0.name, amount: $0.amount) }
        uploadedTransactions = draft.uploadedTransactions.isEmpty
            ? nil
            : draft.uploadedTransactions.map { $0.uploadedTransaction }
        people = draft.people.isEmpty ? people : draft.people
        currentStep = draft.currentStep
        transactions.removeAll()
        preserveReviewTransactionsOnNextReview = false

        return (draft.manualItems, draft.showManualEntry)
    }

    func clearUploadDraft(id: UUID? = nil) {
        guard let id else {
            guard let url = uploadDraftFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return }

            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Failed to clear upload draft: \(error.localizedDescription)")
            }
            return
        }

        var store = loadUploadDraftStore()
        store.drafts.removeAll { $0.id == id }
        if store.drafts.isEmpty {
            clearUploadDraft()
        } else {
            saveUploadDraftStore(store)
        }
    }

    private func loadUploadDraftStore() -> UploadDraftStore {
        guard let url = uploadDraftFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return UploadDraftStore(drafts: [])
        }

        do {
            let data = try Data(contentsOf: url)
            if let store = try? JSONDecoder().decode(UploadDraftStore.self, from: data) {
                return UploadDraftStore(
                    drafts: store.drafts.sorted { $0.savedAt > $1.savedAt }
                )
            }

            if let legacyDraft = try? JSONDecoder().decode(UploadDraft.self, from: data) {
                return UploadDraftStore(drafts: [legacyDraft])
            }
        } catch {
            print("Failed to load upload drafts: \(error.localizedDescription)")
        }

        return UploadDraftStore(drafts: [])
    }

    private func saveUploadDraftStore(_ store: UploadDraftStore) {
        let normalized = UploadDraftStore(drafts: Array(
            store.drafts
                .sorted { $0.savedAt > $1.savedAt }
                .prefix(maxUploadDraftVersions)
        ))

        do {
            guard let url = uploadDraftFileURL else { return }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(normalized)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Failed to save upload drafts: \(error.localizedDescription)")
        }
    }

    private var uploadDraftFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dutchi", isDirectory: true)
            .appendingPathComponent(uploadDraftFileName)
    }

    // MARK: - Receipt → Transaction

    func makeTransaction(from receipt: UploadedReceipt) -> Transaction {
        let payer = people.first(where: { $0.isCurrentUser })
            ?? people.first
            ?? Person(name: profile.name, isCurrentUser: true)
        return Transaction(
            amount:               receipt.total,
            merchant:             receipt.merchant,
            paidBy:               payer,
            splitWith:            people,
            receiptImage:         receipt.bestImageData,
            includeInSplit:       true,
            isManual:             false,
            backgroundResultToken: receipt.backgroundResultToken,
            lineItems:            receipt.lineItems,
            receiptDate:          receipt.receiptDate,
            currency:             receipt.currency,
            splitQuantities:      [:],
            sourceDocumentType:   .receipt
        )
    }

    func receiptImageData(for transaction: Transaction) -> Data? {
        if let receiptImage = transaction.receiptImage, !receiptImage.isEmpty {
            return receiptImage
        }

        if let token = transaction.backgroundResultToken,
           let receipt = uploadedReceipts.first(where: { $0.backgroundResultToken == token }) {
            let imageData = receipt.bestImageData
            return imageData.isEmpty ? nil : imageData
        }

        if let receipt = uploadedReceipts.first(where: {
            $0.id == transaction.id ||
            ($0.merchant == transaction.merchant && abs($0.total - transaction.amount) < 0.01)
        }) {
            let imageData = receipt.bestImageData
            return imageData.isEmpty ? nil : imageData
        }

        return nil
    }

    // MARK: - Public Methods

    func addPerson(_ person: Person)    { people.append(person) }
    func removePerson(_ person: Person) { people.removeAll { $0.id == person.id } }

    var needsCurrentUser: Bool { !people.contains(where: { $0.isCurrentUser }) }

    func ensureCurrentUser() {
        if needsCurrentUser {
            people.insert(Person(name: profile.name, isCurrentUser: true), at: 0)
        }
    }

    func saveGroup(name: String) { savedGroups.append(Group(name: name, members: people)) }
    func loadGroup(_ group: Group) { people = group.members }

    func updateReceipt(at index: Int, with fullData: OCRService.ReceiptData) {
        guard index < uploadedReceipts.count else {
            print("Receipt index \(index) out of bounds"); return
        }
        let token = uploadedReceipts[index].backgroundResultToken
        uploadedReceipts[index].updateWithFullData(fullData)

        if let token,
           let idx = transactions.firstIndex(where: { $0.backgroundResultToken == token }) {
            transactions[idx].lineItems = fullData.lineItems
            if transactions[idx].receiptImage?.isEmpty != false {
                let imageData = uploadedReceipts[index].bestImageData
                transactions[idx].receiptImage = imageData.isEmpty ? nil : imageData
            }
            if !fullData.merchant.isEmpty { transactions[idx].merchant = fullData.merchant }
            if let t = fullData.grandTotal, t > 0 { transactions[idx].amount = t }
        }
    }

    @discardableResult
    func updateReceipt(backgroundResultToken token: String, with fullData: OCRService.ReceiptData) -> (updated: Bool, oldTotal: Double?, newTotal: Double?) {
        guard let receiptIndex = uploadedReceipts.firstIndex(where: { $0.backgroundResultToken == token }) else {
            return (false, nil, nil)
        }

        let oldTotal = uploadedReceipts[receiptIndex].total
        uploadedReceipts[receiptIndex].updateWithFullData(fullData)
        let newTotal = uploadedReceipts[receiptIndex].total

        if let txIndex = transactions.firstIndex(where: { $0.backgroundResultToken == token }) {
            transactions[txIndex].lineItems = fullData.lineItems
            if transactions[txIndex].receiptImage?.isEmpty != false {
                let imageData = uploadedReceipts[receiptIndex].bestImageData
                transactions[txIndex].receiptImage = imageData.isEmpty ? nil : imageData
            }
            if !fullData.merchant.isEmpty { transactions[txIndex].merchant = fullData.merchant }
            if let total = fullData.grandTotal, total > 0 { transactions[txIndex].amount = total }
            transactions[txIndex].receiptDate = fullData.receiptDate
            transactions[txIndex].currency = fullData.currency ?? transactions[txIndex].currency
        }

        objectWillChange.send()
        return (true, oldTotal, newTotal)
    }

    // MARK: - Settlement Calculation

    func calculateSettlements() -> [PaymentLink] {
        var balances: [UUID: Double] = [:]
        for person in people { balances[person.id] = 0 }

        for transaction in transactions where transaction.includeInSplit {
            let paidById   = transaction.paidBy.id
            let hasCustom  = !transaction.splitQuantities.isEmpty
            let totalUnits = hasCustom
                ? Double(transaction.splitWith.reduce(0) { $0 + (transaction.splitQuantities[$1.id] ?? 1) })
                : Double(transaction.splitWith.count)
            guard totalUnits > 0 else { continue }

            for person in transaction.splitWith {
                guard person.id != paidById else { continue }
                let units = hasCustom ? Double(transaction.splitQuantities[person.id] ?? 1) : 1.0
                let share = transaction.amount * (units / totalUnits)
                balances[person.id, default: 0] -= share
                balances[paidById, default: 0]  += share
            }
        }

        var payments:  [PaymentLink] = []
        var creditors  = balances.filter { $0.value >  0.01 }.sorted { $0.value > $1.value }
        var debtors    = balances.filter { $0.value < -0.01 }.sorted { $0.value < $1.value }
        var ci = 0, di = 0

        while ci < creditors.count && di < debtors.count {
            guard let creditor = people.first(where: { $0.id == creditors[ci].key }),
                  let debtor   = people.first(where: { $0.id == debtors[di].key })
            else { break }

            let amount = min(creditors[ci].value, abs(debtors[di].value))
            payments.append(PaymentLink(from: debtor, to: creditor, amount: amount))

            creditors[ci].value -= amount
            debtors[di].value   += amount
            if creditors[ci].value    < 0.01 { ci += 1 }
            if abs(debtors[di].value) < 0.01 { di += 1 }
        }
        return payments
    }

    // MARK: - Reset

    func reset() {
        uploadedImages       = []
        uploadedReceipts     = []
        manualTransactions   = []
        uploadedTransactions = nil
        transactions         = []
        preserveReviewTransactionsOnNextReview = false
        forcePersonalSplitForCurrentUpload = false
        people               = []
        uploadReviewSyncSessionID = UUID()
        currentStep          = 0
        clearUploadDraft()
    }

    func resetUploadSession() {
        uploadedImages       = []
        uploadedReceipts     = []
        manualTransactions   = []
        uploadedTransactions = nil
        transactions         = []
        preserveReviewTransactionsOnNextReview = false
        forcePersonalSplitForCurrentUpload = false
        uploadReviewSyncSessionID = UUID()
        currentStep          = 0
        clearUploadDraft()
        ReceiptManager.shared.resetSession()
    }
}
