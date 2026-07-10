import SwiftUI
import FirebaseDatabase
import Combine

// MARK: - Activity Model

struct GroupActivity: Identifiable, Equatable {
    let id: String
    let type: ActivityType
    let groupID: String
    let groupName: String
    let actorName: String
    let detail: String
    let amount: Double?
    let actionURL: String?
    let recipientPhone: String?   // phone of the user who should take the action
    let receiptBatchID: String?
    let expenseID: String?
    let requestID: String?
    let status: String?
    let timestamp: Date
    var isRead: Bool

    enum ActivityType: String {
        case expenseAdded     = "expense_added"
        case memberJoined     = "member_joined"
        case memberLeft       = "member_left"
        case groupSettled     = "group_settled"
        case paymentRequested = "payment_requested"
        case paymentConfirmed = "payment_confirmed"
    }

    var typeLabel: String {
        switch type {
        case .expenseAdded:       return "EXPENSE"
        case .memberJoined:       return "JOINED"
        case .memberLeft:         return "LEFT"
        case .groupSettled:       return "SETTLED"
        case .paymentRequested:   return "PAYMENT"
        case .paymentConfirmed:   return "CONFIRMED"
        }
    }

    // Returns the action label for a given viewer's phone.
    // nil = no action button shown.
    func actionLabel(for viewerPhone: String?) -> String? {
        switch type {
        case .expenseAdded, .memberJoined, .memberLeft:
            return nil
        case .groupSettled, .paymentConfirmed: return nil
        case .paymentRequested:
            guard status != "paid" else { return nil }
            guard let recipient = recipientPhone, !recipient.isEmpty else {
                // Legacy entry — no recipient stored, fall back to URL presence
                return actionURL != nil ? "PAY NOW" : nil
            }
            guard let viewer = viewerPhone, !viewer.isEmpty else { return nil }
            let digits = { (p: String) in p.filter(\.isNumber) }
            return digits(viewer) == digits(recipient)
                ? (actionURL != nil ? "PAY NOW" : "VIEW REQUEST")
                : nil
        }
    }

    func needsAttention(for viewerPhone: String?) -> Bool {
        switch type {
        case .paymentRequested:
            return actionLabel(for: viewerPhone) != nil
        case .expenseAdded, .memberJoined, .memberLeft, .groupSettled, .paymentConfirmed:
            return false
        }
    }
}

// MARK: - ActivityStore

final class ActivityStore: NSObject, ObservableObject {
    static let shared = ActivityStore()

    @Published private(set) var activities: [GroupActivity] = []
    @Published private(set) var unreadCount: Int = 0
    private var attentionPhone: String?

    private var groupListeners:  [String: DatabaseHandle] = [:]
    private var inboxListener:   DatabaseHandle?
    private var inboxPhoneKey:   String?

    private let readKey    = "dutchie.activityReadIDs"
    private let deletedKey = "dutchie.activityDeletedIDs"

    private var readIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: readKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: readKey) }
    }
    private var deletedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: deletedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: deletedKey) }
    }

    private override init() { super.init() }

    // MARK: - Group listeners

    func startListening(for groupIDs: [String]) {
        stopGroupListeners()
        guard !groupIDs.isEmpty else { return }
        let db = Database.database().reference()
        for groupID in groupIDs {
            let handle = db
                .child("groupActivity").child(groupID)
                .queryOrdered(byChild: "timestamp").queryLimited(toLast: 100)
                .observe(.value) { [weak self] snap in
                    self?.handleGroupSnapshot(snap, groupID: groupID)
                }
            groupListeners[groupID] = handle
        }
    }

    func stopGroupListeners() {
        let db = Database.database().reference()
        for (gid, h) in groupListeners {
            db.child("groupActivity").child(gid).removeObserver(withHandle: h)
        }
        groupListeners = [:]
    }

    // MARK: - User inbox listener (direct payment requests, non-group)

    func startListeningToUserInbox(phoneKey: String) {
        guard phoneKey != inboxPhoneKey else { return }
        stopInboxListener()
        inboxPhoneKey = phoneKey
        let db = Database.database().reference()
        inboxListener = db
            .child("userActivity").child(phoneKey)
            .queryOrdered(byChild: "timestamp").queryLimited(toLast: 50)
            .observe(.value) { [weak self] snap in
                self?.handleInboxSnapshot(snap)
            }
    }

    func stopInboxListener() {
        if let key = inboxPhoneKey, let h = inboxListener {
            Database.database().reference()
                .child("userActivity").child(key).removeObserver(withHandle: h)
        }
        inboxListener = nil
        inboxPhoneKey = nil
    }

    // MARK: - Snapshot parsing

    private func handleGroupSnapshot(_ snapshot: DataSnapshot, groupID: String) {
        let incoming = parse(snapshot)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activities.removeAll { $0.groupID == groupID }
            self.activities.append(contentsOf: incoming)
            self.sort()
        }
    }

    private func handleInboxSnapshot(_ snapshot: DataSnapshot) {
        let incoming = parse(snapshot)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activities.removeAll { $0.groupID == "__inbox__" }
            self.activities.append(contentsOf: incoming)
            self.sort()
        }
    }

    private func parse(_ snapshot: DataSnapshot) -> [GroupActivity] {
        let reads   = readIDs
        let deleted = deletedIDs
        var result: [GroupActivity] = []
        for child in snapshot.children {
            guard let snap = child as? DataSnapshot,
                  let dict = snap.value as? [String: Any],
                  !deleted.contains(snap.key) else { continue }
            if var a = GroupActivity(id: snap.key, dict: dict) {
                a.isRead = reads.contains(a.id)
                result.append(a)
            }
        }
        return result
    }

    private func sort() {
        activities.sort { $0.timestamp > $1.timestamp }
        unreadCount = activities.filter { !$0.isRead && $0.needsAttention(for: attentionPhone) }.count
    }

    func setAttentionPhone(_ phone: String?) {
        attentionPhone = phone
        unreadCount = activities.filter { !$0.isRead && $0.needsAttention(for: attentionPhone) }.count
    }

    // MARK: - Mark read

    func markAllRead() {
        readIDs = readIDs.union(activities.map(\.id))
        activities = activities.map { var a = $0; a.isRead = true; return a }
        unreadCount = 0
    }

    // MARK: - Delete

    func delete(id: String) {
        deletedIDs.insert(id)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            activities.removeAll { $0.id == id }
            unreadCount = activities.filter { !$0.isRead && $0.needsAttention(for: attentionPhone) }.count
        }
    }

    func clearAll() {
        deletedIDs = deletedIDs.union(activities.map(\.id))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            activities.removeAll()
            unreadCount = 0
        }
    }

    func purgeGroups(_ groupIDs: Set<String>) {
        guard !groupIDs.isEmpty else { return }
        deletedIDs = deletedIDs.union(activities.filter { groupIDs.contains($0.groupID) }.map(\.id))
        activities.removeAll { groupIDs.contains($0.groupID) }
        unreadCount = activities.filter { !$0.isRead && $0.needsAttention(for: attentionPhone) }.count
    }

    // MARK: - Write: group feed

    static func write(
        groupID: String,
        groupName: String,
        type: GroupActivity.ActivityType,
        actorName: String,
        detail: String,
        amount: Double? = nil,
        actionURL: String? = nil,
        recipientPhone: String? = nil,
        receiptBatchID: String? = nil,
        expenseID: String? = nil,
        requestID: String? = nil,
        status: String? = nil
    ) {
        guard NetworkStatusMonitor.shared.isOnline else { return }

        let ref  = Database.database().reference()
        let node = ref.child("groupActivity").child(groupID)
        let key  = node.childByAutoId().key ?? UUID().uuidString
        node.child(key).setValue(buildPayload(
            groupID: groupID, groupName: groupName, type: type,
            actorName: actorName, detail: detail,
            amount: amount, actionURL: actionURL, recipientPhone: recipientPhone,
            receiptBatchID: receiptBatchID, expenseID: expenseID,
            requestID: requestID, status: status
        ))
    }

    // MARK: - Write: per-user inbox (non-group payment requests)

    static func writeToUserInbox(
        phoneKey: String,
        groupName: String,
        type: GroupActivity.ActivityType,
        actorName: String,
        detail: String,
        amount: Double? = nil,
        actionURL: String? = nil,
        recipientPhone: String? = nil,
        receiptBatchID: String? = nil,
        expenseID: String? = nil,
        requestID: String? = nil,
        status: String? = nil
    ) {
        guard NetworkStatusMonitor.shared.isOnline else { return }

        let ref  = Database.database().reference()
        let node = ref.child("userActivity").child(phoneKey)
        let key  = node.childByAutoId().key ?? UUID().uuidString
        node.child(key).setValue(buildPayload(
            groupID: "__inbox__", groupName: groupName, type: type,
            actorName: actorName, detail: detail,
            amount: amount, actionURL: actionURL, recipientPhone: recipientPhone,
            receiptBatchID: receiptBatchID, expenseID: expenseID,
            requestID: requestID, status: status
        ))
    }

    static func markPaymentRequestPaid(
        groupID: String,
        requestID: String? = nil,
        expenseID: String? = nil,
        recipientPhone: String? = nil
    ) {
        guard NetworkStatusMonitor.shared.isOnline else { return }
        guard requestID?.isEmpty == false || expenseID?.isEmpty == false else { return }

        let node = Database.database().reference().child("groupActivity").child(groupID)
        node.observeSingleEvent(of: .value) { snapshot in
            let paidAt = ISO8601DateFormatter().string(from: Date())
            let recipientKey = recipientPhone.map(normalizedPhoneKey)

            for child in snapshot.children {
                guard let snap = child as? DataSnapshot,
                      let dict = snap.value as? [String: Any],
                      dict["type"] as? String == GroupActivity.ActivityType.paymentRequested.rawValue,
                      (dict["status"] as? String) != "paid" else { continue }

                let matchesRequest = requestID.map { dict["requestID"] as? String == $0 } ?? false
                let matchesExpense = expenseID.map { dict["expenseID"] as? String == $0 } ?? false
                guard matchesRequest || matchesExpense else { continue }

                if let recipientKey,
                   let storedRecipient = dict["recipientPhone"] as? String,
                   normalizedPhoneKey(for: storedRecipient) != recipientKey {
                    continue
                }

                node.child(snap.key).updateChildValues([
                    "status": "paid",
                    "paidAt": paidAt
                ])
            }
        }
    }

    private static func normalizedPhoneKey(for phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        if digits.count == 10 { return "1\(digits)" }
        if digits.count == 11, digits.first == "1" { return digits }
        return digits
    }

    private static func buildPayload(
        groupID: String,
        groupName: String,
        type: GroupActivity.ActivityType,
        actorName: String,
        detail: String,
        amount: Double?,
        actionURL: String?,
        recipientPhone: String?,
        receiptBatchID: String?,
        expenseID: String?,
        requestID: String?,
        status: String?
    ) -> [String: Any] {
        var p: [String: Any] = [
            "type":      type.rawValue,
            "groupID":   groupID,
            "groupName": groupName,
            "actorName": actorName,
            "detail":    detail,
            "timestamp": ServerValue.timestamp()
        ]
        if let v = amount         { p["amount"]         = v }
        if let v = actionURL      { p["actionURL"]      = v }
        if let v = recipientPhone { p["recipientPhone"] = v }
        if let v = receiptBatchID { p["receiptBatchID"] = v }
        if let v = expenseID      { p["expenseID"]      = v }
        if let v = requestID      { p["requestID"]      = v }
        if let v = status         { p["status"]         = v }
        return p
    }

    // MARK: - Phone key (mirrors AuthManager.phoneIndexKey)

    static func phoneKey(for phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        if digits.count == 10 { return "1\(digits)" }
        if digits.count == 11, digits.first == "1" { return digits }
        return digits
    }
}

// MARK: - GroupActivity Firebase init

private extension GroupActivity {
    init?(id: String, dict: [String: Any]) {
        guard
            let typeRaw   = dict["type"]      as? String,
            let type      = ActivityType(rawValue: typeRaw),
            let groupID   = dict["groupID"]   as? String,
            let groupName = dict["groupName"] as? String,
            let actorName = dict["actorName"] as? String,
            let detail    = dict["detail"]    as? String
        else { return nil }

        let ts = dict["timestamp"] as? Double ?? 0
        self.init(
            id:             id,
            type:           type,
            groupID:        groupID,
            groupName:      groupName,
            actorName:      actorName,
            detail:         detail,
            amount:         dict["amount"]         as? Double,
            actionURL:      dict["actionURL"]      as? String,
            recipientPhone: dict["recipientPhone"] as? String,
            receiptBatchID: dict["receiptBatchID"] as? String,
            expenseID:      dict["expenseID"]      as? String,
            requestID:      dict["requestID"]      as? String,
            status:         dict["status"]         as? String,
            timestamp:      ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : Date(),
            isRead:         false
        )
    }
}
