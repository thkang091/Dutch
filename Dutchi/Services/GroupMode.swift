import SwiftUI
import Combine
import Contacts
import ContactsUI
import MessageUI
import FirebaseDatabase
import FirebaseAuth

// MARK: - Data Models

extension Notification.Name {
    static let processDeepLink = Notification.Name("dutchie.processDeepLink")
    static let showPaymentRequestBanner = Notification.Name("dutchie.showPaymentRequestBanner")
}

// MARK: - ExpenseShare Model
// NEW: Represents one member's share of an expense
struct ExpenseShare: Identifiable, Codable, Equatable {
    let id: UUID
    let memberID: UUID
    var memberName: String
    var owedAmount: Double
    var status: ShareStatus
    var paidDate: Date?
    
    enum ShareStatus: String, Codable {
        case pending
        case paid
    }
    
    init(id: UUID = UUID(), memberID: UUID, memberName: String, owedAmount: Double, status: ShareStatus = .pending, paidDate: Date? = nil) {
        self.id = id
        self.memberID = memberID
        self.memberName = memberName
        self.owedAmount = owedAmount
        self.status = status
        self.paidDate = paidDate
    }
}

struct GroupExpense: Identifiable, Codable, Equatable {
    let id: UUID
    let groupID: UUID
    var addedByID: UUID
    var addedByName: String
    var description: String
    var amount: Double
    let date: Date
    var splitAmongIDs: [UUID]
    var isArchived: Bool = false
    var settled: Bool = false  // ✅ ADD THIS LINE
    var backgroundResultToken: String? = nil
    var sourceTransactionID: UUID? = nil
    var sourceUploadSessionID: UUID? = nil
    
    // CHANGED: Removed isPaid - now using shares per member
    // Keeping this computed property for backwards compatibility
    var isPaid: Bool {
        // An expense is "fully paid" if all shares are paid
        // This is computed from shares, not stored
        return false // Will be computed from shares
    }
 
    init(
        id: UUID = UUID(), groupID: UUID, addedByID: UUID,
        addedByName: String, description: String, amount: Double,
        date: Date = Date(), splitAmongIDs: [UUID], isArchived: Bool = false,
        settled: Bool = false,  // ✅ ADD THIS PARAMETER
        backgroundResultToken: String? = nil,
        sourceTransactionID: UUID? = nil,
        sourceUploadSessionID: UUID? = nil
    ) {
        self.id = id; self.groupID = groupID; self.addedByID = addedByID
        self.addedByName = addedByName; self.description = description
        self.amount = amount; self.date = date; self.splitAmongIDs = splitAmongIDs
        self.isArchived = isArchived
        self.settled = settled  // ✅ ADD THIS LINE
        self.backgroundResultToken = backgroundResultToken
        self.sourceTransactionID = sourceTransactionID
        self.sourceUploadSessionID = sourceUploadSessionID
    }
    var formattedAmount: String { String(format: "$%.2f", amount) }
}

struct GroupMember: Identifiable, Codable, Equatable {
    let id: UUID
    private var storedName: String
    var profileName: String?
    var localDisplayName: String?
    var localImageData: Data?
    var name: String {
        get {
            if let localDisplayName = localDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !localDisplayName.isEmpty {
                return localDisplayName
            }
            if let profileName = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !profileName.isEmpty {
                return profileName
            }
            return storedName
        }
        set {
            storedName = newValue
        }
    }
    var syncedName: String {
        if let profileName = profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !profileName.isEmpty {
            return profileName
        }
        return storedName
    }
    var sharedDisplayName: String { storedName }
    var phoneNumber: String?
    var imageData: Data?
    var displayImageData: Data? {
        if !isCurrentUser, let localImageData {
            return localImageData
        }
        return imageData
    }
    var isCurrentUser: Bool
    var isPending: Bool = false
    var venmoUsername: String?
    var venmoLink: String?
    var zelleEmail: String?
    var zelleLink: String?
    var joinedAt: Date?
    var hasLeft: Bool = false
    var leftAt: Date?
    var subscriptionSourceGroupID: UUID?
    
    enum CodingKeys: String, CodingKey {
        case id, name, profileName, phoneNumber, imageData
        case isPending, venmoUsername, venmoLink, zelleEmail, zelleLink, joinedAt, hasLeft, leftAt
        case subscriptionSourceGroupID
    }

    init(
        id: UUID = UUID(), name: String, phoneNumber: String? = nil,
        imageData: Data? = nil, isCurrentUser: Bool = false,
        isPending: Bool = false,
        profileName: String? = nil,
        localDisplayName: String? = nil,
        localImageData: Data? = nil,
        venmoUsername: String? = nil, venmoLink: String? = nil,
        zelleEmail: String? = nil, zelleLink: String? = nil,
        joinedAt: Date? = nil,
        hasLeft: Bool = false,
        leftAt: Date? = nil,
        subscriptionSourceGroupID: UUID? = nil
    ) {
        self.id = id; self.storedName = name; self.profileName = profileName; self.localDisplayName = localDisplayName; self.localImageData = localImageData; self.phoneNumber = phoneNumber
        self.imageData = imageData; self.isCurrentUser = isCurrentUser
        self.isPending = isPending
        self.venmoUsername = venmoUsername; self.venmoLink = venmoLink
        self.zelleEmail = zelleEmail; self.zelleLink = zelleLink
        self.joinedAt = joinedAt
        self.hasLeft = hasLeft
        self.leftAt = leftAt
        self.subscriptionSourceGroupID = subscriptionSourceGroupID
    }

    var initials: String {
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1)) + String(parts[1].prefix(1)) }
        return String(name.prefix(2)).uppercased()
    }

    func toPerson() -> Person {
        Person(
            id: id,
            name: name,
            contactImage: displayImageData,
            phoneNumber: phoneNumber,
            isCurrentUser: isCurrentUser,
            venmoUsername: venmoUsername,
            venmoLink: venmoLink,
            zelleContact: zelleEmail,
            zelleLink: zelleLink,
            isPendingGroupMember: isPending
        )
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        storedName = try container.decode(String.self, forKey: .name)
        profileName = try? container.decode(String.self, forKey: .profileName)
        localDisplayName = nil
        localImageData = nil
        phoneNumber = try? container.decode(String.self, forKey: .phoneNumber)
        imageData = try? container.decode(Data.self, forKey: .imageData)
        isPending = (try? container.decode(Bool.self, forKey: .isPending)) ?? false
        venmoUsername = try? container.decode(String.self, forKey: .venmoUsername)
        venmoLink = try? container.decode(String.self, forKey: .venmoLink)
        zelleEmail = try? container.decode(String.self, forKey: .zelleEmail)
        zelleLink = try? container.decode(String.self, forKey: .zelleLink)
        joinedAt = try? container.decode(Date.self, forKey: .joinedAt)
        hasLeft = (try? container.decode(Bool.self, forKey: .hasLeft)) ?? false
        leftAt = try? container.decode(Date.self, forKey: .leftAt)
        subscriptionSourceGroupID = try? container.decode(UUID.self, forKey: .subscriptionSourceGroupID)
        
        isCurrentUser = false
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(syncedName, forKey: .name)
        try container.encodeIfPresent(profileName, forKey: .profileName)
        try container.encodeIfPresent(phoneNumber, forKey: .phoneNumber)
        try container.encodeIfPresent(imageData, forKey: .imageData)
        try container.encode(isPending, forKey: .isPending)
        try container.encodeIfPresent(venmoUsername, forKey: .venmoUsername)
        try container.encodeIfPresent(venmoLink, forKey: .venmoLink)
        try container.encodeIfPresent(zelleEmail, forKey: .zelleEmail)
        try container.encodeIfPresent(zelleLink, forKey: .zelleLink)
        try container.encodeIfPresent(joinedAt, forKey: .joinedAt)
        try container.encode(hasLeft, forKey: .hasLeft)
        try container.encodeIfPresent(leftAt, forKey: .leftAt)
        try container.encodeIfPresent(subscriptionSourceGroupID, forKey: .subscriptionSourceGroupID)
    }
}

extension CNContact {
    var dutchSafeImageData: Data? {
        isKeyAvailable(CNContactImageDataKey) ? imageData : nil
    }

    var dutchSafeThumbnailImageData: Data? {
        isKeyAvailable(CNContactThumbnailImageDataKey) ? thumbnailImageData : nil
    }
}

enum LocalContactNameStore {
    private static let key = "localContactDisplayNamesByPhone_v1"
    private static let imageKey = "localContactImagesByPhone_v1"
    private static let touchedKey = "localContactTouchedAtByPhone_v1"

    static func save(name: String, phoneNumber: String?, imageData: Data? = nil) {
        guard let phoneKey = phoneKey(for: phoneNumber) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var names = load()
        names[phoneKey] = trimmed
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: key)
        }

        if let imageData {
            var images = loadImages()
            images[phoneKey] = imageData.base64EncodedString()
            if let data = try? JSONEncoder().encode(images) {
                UserDefaults.standard.set(data, forKey: imageKey)
            }
        }

        touch(phoneNumber: phoneNumber)
    }

    static func name(for phoneNumber: String?) -> String? {
        guard let phoneKey = phoneKey(for: phoneNumber) else { return nil }
        if let storedName = load()[phoneKey] {
            return storedName
        }
        guard let contact = deviceContactMatch(for: phoneNumber, phoneKey: phoneKey) else { return nil }
        save(name: contact.name, phoneNumber: phoneNumber, imageData: contact.imageData)
        return contact.name
    }

    static func imageData(for phoneNumber: String?) -> Data? {
        guard let phoneKey = phoneKey(for: phoneNumber) else { return nil }
        guard let encoded = loadImages()[phoneKey] else {
            if let contact = deviceContactMatch(for: phoneNumber, phoneKey: phoneKey) {
                save(name: contact.name, phoneNumber: phoneNumber, imageData: contact.imageData)
                return contact.imageData
            }
            return nil
        }
        return Data(base64Encoded: encoded)
    }

    static func apply(to member: GroupMember) -> GroupMember {
        var localized = member
        guard !localized.isCurrentUser else {
            localized.localDisplayName = nil
            localized.localImageData = nil
            return localized
        }
        localized.localDisplayName = name(for: localized.phoneNumber)
        localized.localImageData = imageData(for: localized.phoneNumber)
        return localized
    }

    static func applyCached(to member: GroupMember) -> GroupMember {
        var localized = member
        guard !localized.isCurrentUser else {
            localized.localDisplayName = nil
            localized.localImageData = nil
            return localized
        }
        guard let phoneKey = phoneKey(for: localized.phoneNumber) else { return localized }
        localized.localDisplayName = load()[phoneKey]
        if let encoded = loadImages()[phoneKey] {
            localized.localImageData = Data(base64Encoded: encoded)
        }
        return localized
    }

    static func nonSyncedFallbackName(for phoneNumber: String?) -> String {
        let digits = phoneNumber?.filter(\.isNumber) ?? ""
        guard !digits.isEmpty else { return "Member" }
        return "Member \(digits.suffix(4))"
    }

    static func touch(phoneNumber: String?) {
        guard let phoneKey = phoneKey(for: phoneNumber) else { return }
        var touched = loadTouchedAt()
        touched[phoneKey] = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(touched) {
            UserDefaults.standard.set(data, forKey: touchedKey)
        }
    }

    static func touchedAt(for phoneNumber: String?) -> TimeInterval? {
        guard let phoneKey = phoneKey(for: phoneNumber) else { return nil }
        return loadTouchedAt()[phoneKey]
    }

    static func touchedAtSnapshot() -> [String: TimeInterval] {
        loadTouchedAt()
    }

    static func normalizedPhoneKey(for phoneNumber: String?) -> String? {
        phoneKey(for: phoneNumber)
    }

    static func hasCachedName(for phoneNumber: String?) -> Bool {
        guard let phoneKey = phoneKey(for: phoneNumber) else { return false }
        return load()[phoneKey] != nil
    }

    static func hasCachedImage(for phoneNumber: String?) -> Bool {
        guard let phoneKey = phoneKey(for: phoneNumber) else { return false }
        return loadImages()[phoneKey] != nil
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func loadImages() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: imageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func loadTouchedAt() -> [String: TimeInterval] {
        guard let data = UserDefaults.standard.data(forKey: touchedKey),
              let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func phoneKey(for phoneNumber: String?) -> String? {
        guard let digits = phoneNumber?.filter(\.isNumber), !digits.isEmpty else { return nil }
        return digits.hasPrefix("1") && digits.count == 11 ? String(digits.dropFirst()) : digits
    }

    private static func deviceContactMatch(for phoneNumber: String?, phoneKey targetPhoneKey: String) -> (name: String, imageData: Data?)? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }

        let keys = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor
        ]
        let store = CNContactStore()

        if let phoneNumber, !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let predicateContacts = try? store.unifiedContacts(
                matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phoneNumber)),
                keysToFetch: keys
           ),
           let match = predicateContacts.first(where: { contact in
               contact.phoneNumbers.contains { phoneKey(for: $0.value.stringValue) == targetPhoneKey }
           }),
           let name = resolvedContactName(match) {
            return (name, match.imageData)
        }

        let request = CNContactFetchRequest(keysToFetch: keys)
        var resolved: (name: String, imageData: Data?)?
        try? store.enumerateContacts(with: request) { contact, stop in
            guard contact.phoneNumbers.contains(where: { phoneKey(for: $0.value.stringValue) == targetPhoneKey }),
                  let name = resolvedContactName(contact) else { return }
            resolved = (name, contact.imageData)
            stop.pointee = true
        }
        return resolved
    }

    private static func resolvedContactName(_ contact: CNContact) -> String? {
        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty { return fullName }
        let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return nickname.isEmpty ? nil : nickname
    }
}

enum ContactRanking {
    static func sorted(_ contacts: [CNContact]) -> [CNContact] {
        contacts.sorted { lhs, rhs in
            let leftScore = score(lhs)
            let rightScore = score(rhs)
            if leftScore != rightScore { return leftScore > rightScore }

            let leftName = displayName(lhs).localizedLowercase
            let rightName = displayName(rhs).localizedLowercase
            if leftName != rightName { return leftName < rightName }

            let leftPhone = firstPhone(lhs)
            let rightPhone = firstPhone(rhs)
            return leftPhone < rightPhone
        }
    }

    static func sortedLightweight(_ contacts: [CNContact]) -> [CNContact] {
        let touchedAt = LocalContactNameStore.touchedAtSnapshot()
        return contacts.sorted { lhs, rhs in
            let leftTouched = mostRecentTouch(in: lhs, touchedAt: touchedAt)
            let rightTouched = mostRecentTouch(in: rhs, touchedAt: touchedAt)
            if leftTouched != rightTouched { return leftTouched > rightTouched }

            let leftName = displayName(lhs).localizedLowercase
            let rightName = displayName(rhs).localizedLowercase
            if leftName != rightName { return leftName < rightName }

            let leftPhone = firstPhone(lhs)
            let rightPhone = firstPhone(rhs)
            return leftPhone < rightPhone
        }
    }

    private static func mostRecentTouch(in contact: CNContact, touchedAt: [String: TimeInterval]) -> TimeInterval {
        contact.phoneNumbers
            .compactMap { LocalContactNameStore.normalizedPhoneKey(for: $0.value.stringValue) }
            .compactMap { touchedAt[$0] }
            .max() ?? 0
    }

    private static func score(_ contact: CNContact) -> Double {
        var score: Double = 0
        let phones = contact.phoneNumbers.map { $0.value.stringValue }

        if let lastUsed = phones.compactMap({ LocalContactNameStore.touchedAt(for: $0) }).max() {
            let ageDays = max(0, (Date().timeIntervalSince1970 - lastUsed) / 86_400)
            score += 400 + max(0, 120 - min(ageDays, 120))
        }

        if phones.contains(where: { LocalContactNameStore.hasCachedName(for: $0) }) {
            score += 220
        }

        if contact.dutchSafeImageData != nil ||
            contact.dutchSafeThumbnailImageData != nil ||
            phones.contains(where: { LocalContactNameStore.hasCachedImage(for: $0) }) {
            score += 70
        }

        if hasMobileLabeledNumber(contact) {
            score += 50
        }

        if !displayName(contact).isEmpty {
            score += 20
        }

        score += Double(min(contact.phoneNumbers.count, 3)) * 5
        return score
    }

    private static func displayName(_ contact: CNContact) -> String {
        "\(contact.givenName) \(contact.familyName)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstPhone(_ contact: CNContact) -> String {
        contact.phoneNumbers.first?.value.stringValue ?? ""
    }

    private static func hasMobileLabeledNumber(_ contact: CNContact) -> Bool {
        contact.phoneNumbers.contains { labeledNumber in
            guard let label = labeledNumber.label else { return false }
            return label == CNLabelPhoneNumberMobile
                || label == CNLabelPhoneNumberiPhone
                || label.localizedCaseInsensitiveContains("mobile")
                || label.localizedCaseInsensitiveContains("iphone")
        }
    }
}

struct BalanceSummary: Identifiable {
    let id: UUID
    let member: GroupMember
    let totalPaid: Double
    let totalOwed: Double
    var netBalance: Double { totalPaid - totalOwed }
    var isPositive: Bool { netBalance >= 0 }
    var formattedNet: String {
        let sign = netBalance >= 0 ? "+" : ""
        return "\(sign)\(String(format: "$%.2f", netBalance))"
    }
}

typealias GroupMemberBalance = BalanceSummary

struct SettlementTransfer: Identifiable {
    let id = UUID()
    let from: GroupMember
    let to: GroupMember
    let amount: Double
    var formattedAmount: String { String(format: "$%.2f", amount) }
}

struct Settlement: Identifiable, Codable, Equatable {
    let id: UUID
    let fromMemberID: UUID
    let toMemberID: UUID
    let amount: Double
    let markedDate: Date
    var isConfirmed: Bool
    var confirmedDate: Date?
    
    init(id: UUID = UUID(), fromMemberID: UUID, toMemberID: UUID, amount: Double, markedDate: Date = Date()) {
        self.id = id
        self.fromMemberID = fromMemberID
        self.toMemberID = toMemberID
        self.amount = amount
        self.markedDate = markedDate
        self.isConfirmed = false
        self.confirmedDate = nil
    }
}

// CHANGED: Group now holds in-memory state built from Firebase
struct DutchieGroup: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var members: [GroupMember]
    var expenses: [GroupExpense]
    var expenseShares: [UUID: [ExpenseShare]] // NEW: expenseID -> [shares]
    var settlements: [Settlement]
    var isArchived: Bool
    var createdByID: UUID?
    var createdAt: Date?
    var maxMemberCount: Int?
    var isSubscriptionInviteStaging: Bool
    
    enum CodingKeys: String, CodingKey {
        case id, name, members, expenses, settlements, isArchived, createdByID, createdAt, expenseShares, maxMemberCount, isSubscriptionInviteStaging
    }
    
    init(
        id: UUID = UUID(),
        name: String,
        members: [GroupMember],
        expenses: [GroupExpense] = [],
        expenseShares: [UUID: [ExpenseShare]] = [:],
        settlements: [Settlement] = [],
        isArchived: Bool = false,
        createdByID: UUID? = nil,
        createdAt: Date? = nil,
        maxMemberCount: Int? = nil,
        isSubscriptionInviteStaging: Bool = false
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.expenses = expenses
        self.expenseShares = expenseShares
        self.settlements = settlements
        self.isArchived = isArchived
        self.createdByID = createdByID
        self.createdAt = createdAt
        self.maxMemberCount = maxMemberCount
        self.isSubscriptionInviteStaging = isSubscriptionInviteStaging
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        members = try container.decode([GroupMember].self, forKey: .members)
        
        expenses = (try? container.decode([GroupExpense].self, forKey: .expenses)) ?? []
        expenseShares = (try? container.decode([UUID: [ExpenseShare]].self, forKey: .expenseShares)) ?? [:]
        settlements = (try? container.decode([Settlement].self, forKey: .settlements)) ?? []
        isArchived = (try? container.decode(Bool.self, forKey: .isArchived)) ?? false
        createdByID = try? container.decode(UUID.self, forKey: .createdByID)
        createdAt = try? container.decode(Date.self, forKey: .createdAt)
        maxMemberCount = try? container.decode(Int.self, forKey: .maxMemberCount)
        isSubscriptionInviteStaging = (try? container.decode(Bool.self, forKey: .isSubscriptionInviteStaging)) ?? false
    }

    func calculateBalances() -> [BalanceSummary] {
        let activeMembers = members.filter { !$0.hasLeft }
        let activeMemberIDs = Set(activeMembers.map(\.id))
        var paid: [UUID: Double] = [:]
        var owed: [UUID: Double] = [:]
        
        for m in activeMembers {
            paid[m.id] = 0
            owed[m.id] = 0
        }
        
        // Count only unsettled money. If per-member shares exist, paid shares drop out
        // without settling the entire expense for everyone else.
        for expense in expenses where !expense.isArchived && !expense.settled {
            let pendingShares = (expenseShares[expense.id] ?? [])
                .filter { $0.status == .pending && $0.memberID != expense.addedByID && activeMemberIDs.contains($0.memberID) }

            if !pendingShares.isEmpty {
                for share in pendingShares {
                    guard activeMemberIDs.contains(expense.addedByID) else { continue }
                    paid[expense.addedByID, default: 0] += share.owedAmount
                    owed[share.memberID, default: 0] += share.owedAmount
                }
            } else if expenseShares[expense.id]?.isEmpty != false {
                guard activeMemberIDs.contains(expense.addedByID) else { continue }
                let activeSplitIDs = expense.splitAmongIDs.filter { activeMemberIDs.contains($0) }
                let splitCount = activeSplitIDs.count
                guard splitCount > 0 else { continue }

                let perPersonAmount = expense.amount / Double(splitCount)

                for memberID in activeSplitIDs where memberID != expense.addedByID {
                    paid[expense.addedByID, default: 0] += perPersonAmount
                    owed[memberID, default: 0] += perPersonAmount
                }
            }
        }
        
        return activeMembers.map { m in
            BalanceSummary(
                id: m.id,
                member: m,
                totalPaid: paid[m.id] ?? 0,
                totalOwed: owed[m.id] ?? 0
            )
        }
    }
    
    
    func calculateSettlements() -> [SettlementTransfer] {
        let balances = calculateBalances()
        var debtors   = balances.filter { $0.netBalance < -0.01 }.map { (member: $0.member, amount: -$0.netBalance) }
        var creditors = balances.filter { $0.netBalance >  0.01 }.map { (member: $0.member, amount:  $0.netBalance) }
        var transfers: [SettlementTransfer] = []
        while !debtors.isEmpty && !creditors.isEmpty {
            debtors.sort { $0.amount > $1.amount }; creditors.sort { $0.amount > $1.amount }
            let d = debtors[0]; let c = creditors[0]; let pay = min(d.amount, c.amount)
            transfers.append(SettlementTransfer(from: d.member, to: c.member, amount: pay))
            let nd = round((d.amount - pay) * 100) / 100
            let nc = round((c.amount - pay) * 100) / 100
            debtors.removeFirst(); creditors.removeFirst()
            if nd > 0.01 { debtors.insert((d.member, nd), at: 0) }
            if nc > 0.01 { creditors.insert((c.member, nc), at: 0) }
        }
        return transfers
    }
    
    var inviteLink: String {
        let inviter = members.first(where: { $0.isCurrentUser })?.name ?? "Someone"
        var components = URLComponents()
        components.scheme = "dutch"
        components.host = "join"
        components.queryItems = [
            URLQueryItem(name: "groupId", value: id.uuidString),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "inviter", value: inviter)
        ]

        return components.url?.absoluteString ?? "dutch://join?groupId=\(id.uuidString)"
    }

    var totalExpenses: Double { expenses.reduce(0) { $0 + $1.amount } }
    var recentActivity: [GroupExpense] {
        expenses
            .sorted { $0.date > $1.date }
            .prefix(20)
            .map { $0 }
    }
    var activeMemberCount: Int { members.filter { !$0.isPending && !$0.hasLeft }.count }
    var pendingMemberCount: Int { members.filter { $0.isPending && !$0.hasLeft }.count }
    var occupiedMemberCount: Int { members.filter { !$0.hasLeft }.count }
    var remainingInviteSlots: Int? {
        guard let maxMemberCount else { return nil }
        return max(0, maxMemberCount - occupiedMemberCount)
    }
    var isInviteFull: Bool {
        guard let remainingInviteSlots else { return false }
        return remainingInviteSlots == 0
    }
}

struct GroupInviteAvailability {
    let canInvite: Bool
    let message: String?
    let remainingGroupSlots: Int?
    let remainingPlanSeats: Int?
}

enum AddPendingMemberResult: Equatable {
    case added
    case updatedExisting
    case groupNotFound
    case alreadyInGroup
    case alreadyInSubscriptionPlan
    case groupFull
    case subscriptionPlanFull
    case missingPhone

    var message: String {
        switch self {
        case .added, .updatedExisting:
            return "Invite added."
        case .groupNotFound:
            return "Could not find this group."
        case .alreadyInGroup:
            return "This person is already in this group."
        case .alreadyInSubscriptionPlan:
            return "This person is already using a seat in another subscription group."
        case .groupFull:
            return "This group is full. Remove a pending invite before adding someone new."
        case .subscriptionPlanFull:
            return "Your plan seats are full. Remove a pending invite before adding someone new."
        case .missingPhone:
            return "Choose a contact with a phone number."
        }
    }
}




// MARK: - GroupManager - REFACTORED for Firebase-first architecture
final class GroupManager: ObservableObject {
    static let shared = GroupManager()
    
    @Published var activeGroup: DutchieGroup?
    @Published var isGroupModeEnabled: Bool = false
    @Published var allGroups: [DutchieGroup] = []
    @Published private(set) var inviteAccessGroupID: UUID?

    var currentUserAvailableGroups: [DutchieGroup] {
        uniqueGroupsByID(allGroups)
            .filter { isAvailableToCurrentUser($0) && !$0.isSubscriptionInviteStaging && isCurrentUserActiveMember(of: $0) }
    }

    var currentUserSubscriptionInviteGroups: [DutchieGroup] {
        uniqueGroupsByID(allGroups)
            .filter { isAvailableToCurrentUser($0) && $0.maxMemberCount != nil && isCurrentUserActiveMember(of: $0) }
    }

    func subscriptionPlanRosterMembers(
        profile: Profile? = nil,
        currentPerson: Person? = nil,
        including preferredGroup: DutchieGroup? = nil,
        hydrateContacts: Bool = true
    ) -> [GroupMember] {
        var candidates: [GroupMember] = []

        func localize(_ member: GroupMember) -> GroupMember {
            hydrateContacts ? LocalContactNameStore.apply(to: member) : LocalContactNameStore.applyCached(to: member)
        }

        func appendCurrentUserIfNeeded(from group: DutchieGroup?) {
            guard let current = group?.members.first(where: { $0.isCurrentUser && !$0.hasLeft }) else { return }
            candidates.append(current)
        }

        appendCurrentUserIfNeeded(from: preferredGroup)
        appendCurrentUserIfNeeded(from: activeGroup)

        if let currentPerson {
            candidates.append(GroupMember(
                id: currentPerson.id,
                name: currentPerson.name,
                phoneNumber: currentPerson.phoneNumber,
                imageData: currentPerson.contactImage,
                isCurrentUser: true,
                isPending: false,
                venmoUsername: currentPerson.venmoUsername,
                venmoLink: currentPerson.venmoLink,
                zelleEmail: currentPerson.zelleContact,
                zelleLink: currentPerson.zelleLink,
                joinedAt: Date()
            ))
        } else if let profile {
            candidates.append(GroupMember(
                name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : profile.name,
                phoneNumber: profile.zelleContactInfo,
                imageData: profile.avatarImage,
                isCurrentUser: true,
                isPending: false,
                venmoUsername: profile.venmoUsername?.replacingOccurrences(of: "@", with: ""),
                venmoLink: profile.venmoPaymentLink,
                zelleEmail: profile.zelleContactInfo,
                zelleLink: profile.zellePaymentLink,
                joinedAt: Date()
            ))
        }

        let visibleSubscriptionGroups = uniqueGroupsByID(
            ([preferredGroup, activeGroup].compactMap { $0 }) +
            currentUserSubscriptionInviteGroups +
            currentUserAvailableGroups.filter { $0.maxMemberCount != nil } +
            allGroups.filter { group in
                group.maxMemberCount != nil &&
                !group.isSubscriptionInviteStaging &&
                isAvailableToCurrentUser(group)
            }
        )

        for group in visibleSubscriptionGroups {
            candidates.append(contentsOf: group.members.filter { !$0.hasLeft })
        }

        let authUID = AuthManager.shared.currentUID
        let currentPhoneKey = AuthManager.shared.phoneNumber.map(normalizePhoneNumber)
            ?? currentPerson?.phoneNumber.map(normalizePhoneNumber)
            ?? profile?.zelleContactInfo.map(normalizePhoneNumber)
        var planRosterKeys = Set<String>()
        var ownerRosterKeys = Set<String>()

        func rosterKey(for id: UUID, phone: String?) -> String {
            if let phone = phone?.trimmingCharacters(in: .whitespacesAndNewlines),
               !phone.isEmpty {
                return "phone:\(normalizePhoneNumber(phone))"
            }
            return "id:\(id.uuidString)"
        }

        for planMember in TrialManager.shared.subscriptionPlanMembers {
            let planKey = rosterKey(for: planMember.memberUUID, phone: planMember.phoneNumber)
            planRosterKeys.insert(planKey)
            if planMember.isOwner {
                ownerRosterKeys.insert(planKey)
            }

            let isCurrentUser = planMember.uid == authUID
            let isPendingInvite = planMember.isPending
                || planMember.uid.hasPrefix("pending_")
                || (!planMember.isOwner && planMember.joinedAt == nil)

            var member = GroupMember(
                id: planMember.memberUUID,
                name: planMember.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Invited Member" : planMember.name,
                phoneNumber: planMember.phoneNumber,
                imageData: isCurrentUser ? profile?.avatarImage : nil,
                isCurrentUser: isCurrentUser,
                isPending: isCurrentUser ? false : isPendingInvite,
                venmoUsername: isCurrentUser ? profile?.venmoUsername?.replacingOccurrences(of: "@", with: "") : nil,
                venmoLink: isCurrentUser ? profile?.venmoPaymentLink : nil,
                zelleEmail: isCurrentUser ? profile?.zelleContactInfo : nil,
                zelleLink: isCurrentUser ? profile?.zellePaymentLink : nil,
                joinedAt: isPendingInvite ? nil : planMember.joinedAt
            )
            member = localize(member)
            candidates.append(member)
        }

        var roster: [GroupMember] = []
        var indexByKey: [String: Int] = [:]

        func key(for member: GroupMember) -> String {
            rosterKey(for: member.id, phone: member.phoneNumber)
        }

        func merged(_ existing: GroupMember, with incoming: GroupMember) -> GroupMember {
            var merged = existing

            if incoming.isCurrentUser {
                merged.isCurrentUser = true
                merged.isPending = false
            } else if !incoming.isPending {
                merged.isPending = false
            }

            if merged.phoneNumber?.isEmpty != false {
                merged.phoneNumber = incoming.phoneNumber
            }
            if merged.joinedAt == nil {
                merged.joinedAt = incoming.joinedAt
            }
            if merged.imageData == nil {
                merged.imageData = incoming.imageData
            }
            if merged.localImageData == nil {
                merged.localImageData = incoming.localImageData
            }
            if merged.localDisplayName?.isEmpty != false {
                merged.localDisplayName = incoming.localDisplayName
            }
            if merged.venmoUsername?.isEmpty != false {
                merged.venmoUsername = incoming.venmoUsername
            }
            if merged.venmoLink?.isEmpty != false {
                merged.venmoLink = incoming.venmoLink
            }
            if merged.zelleEmail?.isEmpty != false {
                merged.zelleEmail = incoming.zelleEmail
            }
            if merged.zelleLink?.isEmpty != false {
                merged.zelleLink = incoming.zelleLink
            }

            let existingName = merged.syncedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let incomingName = incoming.syncedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if existingName.isEmpty || isGeneratedMemberName(existingName) {
                merged.name = incomingName.isEmpty ? merged.name : incomingName
            }

            return localize(merged)
        }

        for rawMember in candidates {
            var member = localize(rawMember)
            if let currentPhoneKey,
               let memberPhone = member.phoneNumber,
               normalizePhoneNumber(memberPhone) == currentPhoneKey,
               !member.isPending {
                member.isCurrentUser = true
                member.isPending = false
            }
            let memberKey = key(for: member)
            if let existingIndex = indexByKey[memberKey] {
                roster[existingIndex] = merged(roster[existingIndex], with: member)
            } else {
                indexByKey[memberKey] = roster.count
                roster.append(member)
            }
        }

        roster.sort { lhs, rhs in
            if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
            let lhsKey = key(for: lhs)
            let rhsKey = key(for: rhs)
            let lhsOwner = ownerRosterKeys.contains(lhsKey)
            let rhsOwner = ownerRosterKeys.contains(rhsKey)
            if lhsOwner != rhsOwner { return lhsOwner }
            let lhsPlanMember = planRosterKeys.contains(lhsKey)
            let rhsPlanMember = planRosterKeys.contains(rhsKey)
            if lhsPlanMember != rhsPlanMember { return lhsPlanMember }
            if lhs.isPending != rhs.isPending { return !lhs.isPending }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let limit = TrialManager.shared.hasSharedSubscriptionAccess
            ? (preferredGroup?.maxMemberCount ?? TrialManager.shared.subscriptionMemberLimit)
            : (TrialManager.shared.subscriptionMemberLimit ?? preferredGroup?.maxMemberCount)
        if let limit {
            return Array(roster.prefix(limit))
        }

        return roster
    }

    var currentUserHasSubscriptionSeat: Bool {
        allGroups.contains { group in
            group.maxMemberCount != nil &&
            isAvailableToCurrentUser(group) &&
            isCurrentUserActiveMember(of: group)
        }
    }

    var currentUserHasActiveGroupAccess: Bool {
        if let inviteAccessGroupID,
           let group = getGroup(by: inviteAccessGroupID),
           isAvailableToCurrentUser(group) {
            return true
        }

        guard isGroupModeEnabled, let activeGroup else { return false }
        return isAvailableToCurrentUser(activeGroup) && isCurrentUserActiveMember(of: activeGroup)
    }
    @Published var pendingInvite: PendingGroupInvite?
    
    private let storageKey = "dutchie_active_group_v1"
    private let allGroupsKey = "dutchie_all_groups_v2"
    private let inviteAccessGroupKey = "dutchie_invite_access_group_id_v1"
    private let userDisabledGroupModeKey = "dutchie_user_disabled_group_mode_v1"
    private let locallyHiddenGroupIDsKey = "dutchie_left_group_ids_v1"
    private let tutorialGroupName = "Weekend Trip"
    private let tutorialMemberName = "Tony"
    private let tutorialMemberPhone = "+1234567890"
    private var locallyHiddenGroupIDs: Set<String> = []

    private var userDisabledGroupMode: Bool {
        UserDefaults.standard.bool(forKey: userDisabledGroupModeKey)
    }
    
    // CHANGED: Firebase observers now track multiple paths
    private struct FirebaseObserverToken {
        let ref: DatabaseReference
        let handle: DatabaseHandle
    }

    private var groupObserverHandles: [UUID: [FirebaseObserverToken]] = [:]
    private var memberProfileObserverHandles: [UUID: [String: DatabaseHandle]] = [:]

    private var ref: DatabaseReference { FirebaseDatabase.Database.database().reference() }
    
    private init() {
        load()
        locallyHiddenGroupIDs = Set(UserDefaults.standard.stringArray(forKey: locallyHiddenGroupIDsKey) ?? [])
        pruneLocallyHiddenGroups()
    }
    
    // MARK: - Local Persistence (Cache only)
    
    func save() {
        allGroups = uniqueGroupsByID(allGroups)
        let persistedGroups = allGroups.filter { !isTutorialGroup($0) }

        if isGroupModeEnabled, let group = activeGroup, !isTutorialGroup(group), let data = try? JSONEncoder().encode(group) {
            UserDefaults.standard.set(data, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        
        UserDefaults.standard.set(isGroupModeEnabled, forKey: "\(storageKey)_enabled")
        if let inviteAccessGroupID {
            UserDefaults.standard.set(inviteAccessGroupID.uuidString, forKey: inviteAccessGroupKey)
        } else {
            UserDefaults.standard.removeObject(forKey: inviteAccessGroupKey)
        }
        
        if let data = try? JSONEncoder().encode(persistedGroups) {
            UserDefaults.standard.set(data, forKey: allGroupsKey)
        }
    }
    
    func load() {
        isGroupModeEnabled = UserDefaults.standard.bool(forKey: "\(storageKey)_enabled")
        if userDisabledGroupMode {
            isGroupModeEnabled = false
        }
        var removedSavedTutorialActiveGroup = false
        if let inviteAccessGroupString = UserDefaults.standard.string(forKey: inviteAccessGroupKey) {
            inviteAccessGroupID = UUID(uuidString: inviteAccessGroupString)
        }
        
        if isGroupModeEnabled,
           let data = UserDefaults.standard.data(forKey: storageKey),
           let group = try? JSONDecoder().decode(DutchieGroup.self, from: data) {
            if isTutorialGroup(group) {
                activeGroup = nil
                removedSavedTutorialActiveGroup = true
            } else {
                activeGroup = group
            }
        } else {
            activeGroup = nil
        }
        
        if let data = UserDefaults.standard.data(forKey: allGroupsKey),
           let groups = try? JSONDecoder().decode([DutchieGroup].self, from: data) {
            allGroups = uniqueGroupsByID(groups).filter { !isTutorialGroup($0) }
        }

        if removedSavedTutorialActiveGroup {
            UserDefaults.standard.removeObject(forKey: storageKey)
            isGroupModeEnabled = false
        }

        if userDisabledGroupMode {
            activeGroup = nil
            isGroupModeEnabled = false
        }
    }

    // MARK: - Firebase Write Operations
    
    /// Firebase path: groups/{groupID}
    func createGroupInFirebase(_ group: DutchieGroup) {
        print("Creating group in Firebase: \(group.name) with \(group.members.count) member(s)")
        
        let groupRef = ref.child("groups").child(group.id.uuidString)
        
        var groupData: [String: Any] = [
            "id": group.id.uuidString,
            "name": group.name,
            "createdByID": group.createdByID?.uuidString ?? "",
            "active": true,
            "isArchived": group.isArchived,
            "isSubscriptionInviteStaging": group.isSubscriptionInviteStaging,
            "createdAt": ISO8601DateFormatter().string(from: group.createdAt ?? Date())
        ]
        if let maxMemberCount = group.maxMemberCount {
            groupData["maxMemberCount"] = maxMemberCount
        }
        
        groupRef.setValue(groupData) { error, _ in
            if let error = error {
                print("Failed to create group: \(error.localizedDescription)")
            } else {
                print("✅ Created group in Firebase: \(group.name)")
            }
        }
        
        // Add members (already deduplicated)
        for member in group.members {
            self.addMemberToFirebase(member, groupID: group.id)
        }
    }
    
    /// Firebase path: groups/{groupID}/members/{memberID}
    func addMemberToFirebase(_ member: GroupMember, groupID: UUID) {
        print("Syncing member to Firebase: \(member.name)")
        
        let memberRef = ref.child("groups").child(groupID.uuidString).child("members").child(member.id.uuidString)
        let firebaseName: String = {
            if member.isPending,
               !member.isCurrentUser,
               let localDisplayName = member.localDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !localDisplayName.isEmpty {
                return localDisplayName
            }
            let sharedName = member.sharedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let profileName = member.profileName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sharedName.isEmpty,
               profileName?.isEmpty == false,
               sharedName.localizedCaseInsensitiveCompare(profileName!) != .orderedSame,
               !isGeneratedMemberName(sharedName) {
                return sharedName
            }
            return member.syncedName
        }()
        
        var memberData: [String: Any] = [
            "id": member.id.uuidString,
            "name": firebaseName,
            "isPending": member.isPending,
            "hasLeft": member.hasLeft
        ]
        if let joinedAt = member.joinedAt {
            memberData["joinedAt"] = ISO8601DateFormatter().string(from: joinedAt)
        }
        if let profileName = member.profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !profileName.isEmpty {
            memberData["profileName"] = profileName
        }
        
        if let phone = member.phoneNumber {
            memberData["phoneNumber"] = phone
        }
        if let imageData = member.imageData {
            memberData["imageData"] = imageData.base64EncodedString()
        }
        if let venmo = member.venmoUsername {
            memberData["venmoUsername"] = venmo
        }
        if let venmoLink = member.venmoLink {
            memberData["venmoLink"] = venmoLink
        }
        if let zelle = member.zelleEmail {
            memberData["zelleEmail"] = zelle
        }
        if let zelleLink = member.zelleLink {
            memberData["zelleLink"] = zelleLink
        }
        if let leftAt = member.leftAt {
            memberData["leftAt"] = ISO8601DateFormatter().string(from: leftAt)
        }
        if let sourceGroupID = member.subscriptionSourceGroupID {
            memberData["subscriptionSourceGroupID"] = sourceGroupID.uuidString
        }
        
        memberRef.setValue(memberData) { error, _ in
            if let error = error {
                print("Failed to add member: \(error.localizedDescription)")
            } else {
                print("✅ Added member to Firebase: \(member.name)")
            }
        }
    }
    
    /// Firebase path: groups/{groupID}/members/{memberID}
    func updateMemberInFirebase(_ member: GroupMember, groupID: UUID) {
        addMemberToFirebase(member, groupID: groupID)
    }
    
    /// Firebase path: groups/{groupID}/expenses/{expenseID}
    func addExpenseToFirebase(_ expense: GroupExpense) {
        let expenseRef = ref.child("groups").child(expense.groupID.uuidString)
            .child("expenses").child(expense.id.uuidString)
        
        var expenseData: [String: Any] = [
            "id": expense.id.uuidString,
            "groupID": expense.groupID.uuidString,
            "addedByID": expense.addedByID.uuidString,
            "addedByName": expense.addedByName,
            "description": expense.description,
            "amount": expense.amount,
            "date": ISO8601DateFormatter().string(from: expense.date),
            "splitAmongIDs": expense.splitAmongIDs.map { $0.uuidString },
            "isArchived": expense.isArchived,
            "settled": expense.settled
        ]
        if let backgroundResultToken = expense.backgroundResultToken {
            expenseData["backgroundResultToken"] = backgroundResultToken
        }
        if let sourceTransactionID = expense.sourceTransactionID {
            expenseData["sourceTransactionID"] = sourceTransactionID.uuidString
        }
        if let sourceUploadSessionID = expense.sourceUploadSessionID {
            expenseData["sourceUploadSessionID"] = sourceUploadSessionID.uuidString
        }
        
        expenseRef.setValue(expenseData) { error, _ in
            if let error = error {
                print("Failed to add expense: \(error.localizedDescription)")
            } else {
                print("✅ Added expense to Firebase: \(expense.description)")
            }
        }
        
        // Create shares for each member
        self.createSharesForExpense(expense)
    }
     
    
    /// Firebase path: groups/{groupID}/expenses/{expenseID}/shares/{memberID}
    func createSharesForExpense(_ expense: GroupExpense) {
        guard !expense.splitAmongIDs.isEmpty else { return }
        
        let shareAmount = expense.amount / Double(expense.splitAmongIDs.count)
        let sharesRef = ref.child("groups").child(expense.groupID.uuidString)
            .child("expenses").child(expense.id.uuidString).child("shares")
        
        guard let group = activeGroup ?? allGroups.first(where: { $0.id == expense.groupID }) else { return }
        
        for memberID in expense.splitAmongIDs {
            guard let member = group.members.first(where: { $0.id == memberID }) else { continue }
            
            let shareData: [String: Any] = [
                "memberID": memberID.uuidString,
                "memberName": member.syncedName,
                "owedAmount": shareAmount,
                "status": ExpenseShare.ShareStatus.pending.rawValue
            ]
            
            sharesRef.child(memberID.uuidString).setValue(shareData) { error, _ in
                if let error = error {
                    print("Failed to create share: \(error.localizedDescription)")
                } else {
                    print("✅ Created share for \(member.name): \(String(format: "$%.2f", shareAmount))")
                }
            }
        }
    }
    

    
    func markShareAsPaid(expenseID: UUID, memberID: UUID, groupID: UUID) {
        setSharePaidStatus(expenseID: expenseID, memberID: memberID, groupID: groupID, isPaid: true)
    }

    func markShareAsUnpaid(expenseID: UUID, memberID: UUID, groupID: UUID) {
        setSharePaidStatus(expenseID: expenseID, memberID: memberID, groupID: groupID, isPaid: false)
    }

    func setSharePaidStatus(expenseID: UUID, memberID: UUID, groupID: UUID, isPaid: Bool) {
        let shareRef = ref.child("groups").child(groupID.uuidString)
            .child("expenses").child(expenseID.uuidString)
            .child("shares").child(memberID.uuidString)

        var values: [String: Any] = [
            "status": isPaid ? ExpenseShare.ShareStatus.paid.rawValue : ExpenseShare.ShareStatus.pending.rawValue
        ]

        if isPaid {
            values["paidDate"] = ISO8601DateFormatter().string(from: Date())
        }

        shareRef.updateChildValues(values) { error, _ in
            if let error = error {
                print("Failed to update share paid status: \(error.localizedDescription)")
            } else {
                if !isPaid {
                    shareRef.child("paidDate").removeValue()
                }
                print("✅ Marked share as \(isPaid ? "paid" : "pending")")
                DispatchQueue.main.async {
                    self.updateBadgeCount()
                    self.objectWillChange.send()
                }
            }
        }
    }
    
    
    // MARK: - Firebase Observers
    
    /// Observe group and rebuild activeGroup from Firebase in real-time
    func observeGroup(groupID: UUID, onChange: @escaping (DutchieGroup) -> Void) {
        stopObservingGroup(groupID: groupID)
        
        var handles: [FirebaseObserverToken] = []
        
        // 1. Observe group basic info: groups/{groupID}
        let groupInfoRef = ref.child("groups").child(groupID.uuidString)
        let groupInfoHandle = groupInfoRef.observe(.value) { [weak self] snapshot in
            self?.handleGroupInfoUpdate(snapshot: snapshot, groupID: groupID, onChange: onChange)
        }
        handles.append(FirebaseObserverToken(ref: groupInfoRef, handle: groupInfoHandle))
        
        // 2. Observe members: groups/{groupID}/members
        let membersRef = ref.child("groups").child(groupID.uuidString).child("members")
        let membersHandle = membersRef.observe(.value) { [weak self] snapshot in
            self?.handleMembersUpdate(snapshot: snapshot, groupID: groupID, onChange: onChange)
        }
        handles.append(FirebaseObserverToken(ref: membersRef, handle: membersHandle))
        
        // 3. Observe expenses: groups/{groupID}/expenses
        let expensesRef = ref.child("groups").child(groupID.uuidString).child("expenses")
        let expensesHandle = expensesRef.observe(.value) { [weak self] snapshot in
            self?.handleExpensesUpdate(snapshot: snapshot, groupID: groupID, onChange: onChange)
        }
        handles.append(FirebaseObserverToken(ref: expensesRef, handle: expensesHandle))
        
        groupObserverHandles[groupID] = handles
        
        print("✅ Started observing group: \(groupID)")
    }

    func fetchGroupForInvite(groupID: UUID, completion: @escaping (DutchieGroup?) -> Void) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to open this invite.") else {
            completion(nil)
            return
        }

        ref.child("groups").child(groupID.uuidString).observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self,
                  let group = self.parseGroupSnapshot(snapshot, fallbackID: groupID) else {
                completion(nil)
                return
            }

            var verifiedGroup = group
            self.markCurrentUserInGroup(&verifiedGroup, authenticatedPhone: AuthManager.shared.phoneNumber)
            self.updateGroupInMemory(verifiedGroup)
            self.save()
            self.objectWillChange.send()
            completion(verifiedGroup)
        }
    }

    func refreshGroupFromFirebase(groupID: UUID, completion: ((DutchieGroup?) -> Void)? = nil) {
        guard NetworkStatusMonitor.shared.isOnline else {
            completion?(getGroup(by: groupID))
            return
        }

        ref.child("groups").child(groupID.uuidString).observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self,
                  var group = self.parseGroupSnapshot(snapshot, fallbackID: groupID) else {
                completion?(nil)
                return
            }

            self.markCurrentUserInGroup(&group, authenticatedPhone: AuthManager.shared.phoneNumber)
            self.updateGroupInMemory(group)
            completion?(group)
        }
    }

    private func parseGroupSnapshot(_ snapshot: DataSnapshot, fallbackID: UUID) -> DutchieGroup? {
        guard let dict = snapshot.value as? [String: Any] else { return nil }

        let groupID = (dict["id"] as? String).flatMap(UUID.init(uuidString:)) ?? fallbackID
        let name = dict["name"] as? String ?? "Dutch Group"
        let createdByID = (dict["createdByID"] as? String).flatMap(UUID.init(uuidString:))
        let isArchived = (dict["isArchived"] as? Bool) ?? false
        let isSubscriptionInviteStaging = (dict["isSubscriptionInviteStaging"] as? Bool) ?? false
        let maxMemberCount = dict["maxMemberCount"] as? Int
        let createdAt = (dict["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

        var members: [GroupMember] = []
        if let membersDict = dict["members"] as? [String: Any] {
            for (_, value) in membersDict {
                guard let memberDict = value as? [String: Any],
                      let member = parseGroupMember(memberDict) else { continue }
                members.append(member)
            }
        }

        var expenses: [GroupExpense] = []
        var expenseShares: [UUID: [ExpenseShare]] = [:]
        if let expensesDict = dict["expenses"] as? [String: Any] {
            for (expenseKey, value) in expensesDict {
                guard let expenseDict = value as? [String: Any],
                      let expense = parseGroupExpense(expenseDict, fallbackExpenseIDString: expenseKey, fallbackGroupID: groupID) else { continue }
                expenses.append(expense)

                if let sharesDict = expenseDict["shares"] as? [String: Any] {
                    expenseShares[expense.id] = sharesDict.compactMap { shareKey, value -> ExpenseShare? in
                        guard let shareDict = value as? [String: Any] else { return nil }
                        return parseExpenseShare(shareDict, fallbackMemberIDString: shareKey)
                    }
                }
            }
        }

        var group = DutchieGroup(
            id: groupID,
            name: name,
            members: deduplicateMembersByPhone(members),
            expenses: expenses,
            expenseShares: expenseShares,
            isArchived: isArchived,
            createdByID: createdByID,
            createdAt: createdAt,
            maxMemberCount: maxMemberCount,
            isSubscriptionInviteStaging: isSubscriptionInviteStaging
        )
        markCurrentUserInGroup(&group, authenticatedPhone: AuthManager.shared.phoneNumber)
        return group
    }

    private func parseGroupMember(_ dict: [String: Any]) -> GroupMember? {
        guard let idStr = dict["id"] as? String,
              let id = UUID(uuidString: idStr),
              let name = dict["name"] as? String else { return nil }

        let phoneNumber = dict["phoneNumber"] as? String
        var imageData: Data?
        if let imageDataStr = dict["imageData"] as? String {
            imageData = Data(base64Encoded: imageDataStr)
        }

        let joinedAt = (dict["joinedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let leftAt = (dict["leftAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let subscriptionSourceGroupID = (dict["subscriptionSourceGroupID"] as? String).flatMap(UUID.init(uuidString:))
        let profileName = dict["profileName"] as? String
        let hasLocalDisplayName = LocalContactNameStore.name(for: phoneNumber) != nil
        let shouldHideLegacySyncedName = profileName == nil && phoneNumber != nil && !hasLocalDisplayName
        let syncedName = shouldHideLegacySyncedName
            ? LocalContactNameStore.nonSyncedFallbackName(for: phoneNumber)
            : name

        return LocalContactNameStore.apply(to: GroupMember(
            id: id,
            name: syncedName,
            phoneNumber: phoneNumber,
            imageData: imageData,
            isCurrentUser: false,
            isPending: (dict["isPending"] as? Bool) ?? false,
            profileName: profileName,
            venmoUsername: dict["venmoUsername"] as? String,
            venmoLink: dict["venmoLink"] as? String,
            zelleEmail: dict["zelleEmail"] as? String,
            zelleLink: dict["zelleLink"] as? String,
            joinedAt: joinedAt,
            hasLeft: (dict["hasLeft"] as? Bool) ?? false,
            leftAt: leftAt,
            subscriptionSourceGroupID: subscriptionSourceGroupID
        ))
    }

    private func parseGroupExpense(
        _ dict: [String: Any],
        fallbackExpenseIDString: String,
        fallbackGroupID: UUID
    ) -> GroupExpense? {
        let idString = (dict["id"] as? String) ?? fallbackExpenseIDString
        guard let expenseID = UUID(uuidString: idString),
              let addedByIDStr = dict["addedByID"] as? String,
              let addedByID = UUID(uuidString: addedByIDStr),
              let description = dict["description"] as? String,
              let amount = doubleValue(dict["amount"]),
              let dateStr = dict["date"] as? String,
              let date = ISO8601DateFormatter().date(from: dateStr),
              let splitAmongIDsStrs = dict["splitAmongIDs"] as? [String] else { return nil }

        let groupID = (dict["groupID"] as? String).flatMap(UUID.init(uuidString:)) ?? fallbackGroupID
        let splitAmongIDs = splitAmongIDsStrs.compactMap { UUID(uuidString: $0) }

        return GroupExpense(
            id: expenseID,
            groupID: groupID,
            addedByID: addedByID,
            addedByName: dict["addedByName"] as? String ?? "Member",
            description: description,
            amount: amount,
            date: date,
            splitAmongIDs: splitAmongIDs,
            isArchived: (dict["isArchived"] as? Bool) ?? false,
            settled: (dict["settled"] as? Bool) ?? false,
            backgroundResultToken: dict["backgroundResultToken"] as? String,
            sourceTransactionID: (dict["sourceTransactionID"] as? String).flatMap(UUID.init(uuidString:)),
            sourceUploadSessionID: (dict["sourceUploadSessionID"] as? String).flatMap(UUID.init(uuidString:))
        )
    }
    
    private func handleGroupInfoUpdate(snapshot: DataSnapshot, groupID: UUID, onChange: @escaping (DutchieGroup) -> Void) {
        guard let dict = snapshot.value as? [String: Any] else { return }
        
        var group = getOrCreateGroup(groupID: groupID)
        
        if let name = dict["name"] as? String {
            group.name = name
        }
        if let isArchived = dict["isArchived"] as? Bool {
            group.isArchived = isArchived
        }
        if let createdByIDStr = dict["createdByID"] as? String,
           let createdByID = UUID(uuidString: createdByIDStr) {
            group.createdByID = createdByID
        }
        if let createdAtStr = dict["createdAt"] as? String,
           let createdAt = ISO8601DateFormatter().date(from: createdAtStr) {
            group.createdAt = createdAt
        }
        if let maxMemberCount = dict["maxMemberCount"] as? Int {
            group.maxMemberCount = maxMemberCount
        }
        group.isSubscriptionInviteStaging = (dict["isSubscriptionInviteStaging"] as? Bool) ?? false
        
        updateGroupInMemory(group)
        DispatchQueue.main.async {
            onChange(group)
        }
    }
    
    private func handleMembersUpdate(snapshot: DataSnapshot, groupID: UUID, onChange: @escaping (DutchieGroup) -> Void) {
        var members: [GroupMember] = []
        
        for child in snapshot.children {
            guard let childSnapshot = child as? DataSnapshot,
                  let dict = childSnapshot.value as? [String: Any],
                  let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let name = dict["name"] as? String else { continue }
            
            let phoneNumber = dict["phoneNumber"] as? String
            let isPending = (dict["isPending"] as? Bool) ?? false
            let hasLeft = (dict["hasLeft"] as? Bool) ?? false
            
            var imageData: Data?
            if let imageDataStr = dict["imageData"] as? String {
                imageData = Data(base64Encoded: imageDataStr)
            }
            
            let venmoUsername = dict["venmoUsername"] as? String
            let venmoLink = dict["venmoLink"] as? String
            let zelleEmail = dict["zelleEmail"] as? String
            let zelleLink = dict["zelleLink"] as? String
            
            var joinedAt: Date?
            if let joinedAtStr = dict["joinedAt"] as? String {
                joinedAt = ISO8601DateFormatter().date(from: joinedAtStr)
            }

            var leftAt: Date?
            if let leftAtStr = dict["leftAt"] as? String {
                leftAt = ISO8601DateFormatter().date(from: leftAtStr)
            }
            let subscriptionSourceGroupID = (dict["subscriptionSourceGroupID"] as? String).flatMap(UUID.init(uuidString:))
            
            let profileName = dict["profileName"] as? String
            let hasLocalDisplayName = LocalContactNameStore.name(for: phoneNumber) != nil
            let shouldHideLegacySyncedName = profileName == nil && phoneNumber != nil && !hasLocalDisplayName
            let syncedName = shouldHideLegacySyncedName
                ? LocalContactNameStore.nonSyncedFallbackName(for: phoneNumber)
                : name

            let member = LocalContactNameStore.apply(to: GroupMember(
                id: id,
                name: syncedName,
                phoneNumber: phoneNumber,
                imageData: imageData,
                isCurrentUser: false,
                isPending: isPending,
                profileName: profileName,
                venmoUsername: venmoUsername,
                venmoLink: venmoLink,
                zelleEmail: zelleEmail,
                zelleLink: zelleLink,
                joinedAt: joinedAt,
                hasLeft: hasLeft,
                leftAt: leftAt,
                subscriptionSourceGroupID: subscriptionSourceGroupID
            ))
            
            members.append(member)
        }
        
        var group = getOrCreateGroup(groupID: groupID)
        group.members = members
        
        markCurrentUserInGroup(&group, authenticatedPhone: AuthManager.shared.phoneNumber)
        observeMemberPaymentProfiles(for: group)
        
        updateGroupInMemory(group)
        DispatchQueue.main.async {
            onChange(group)
        }
    }

    private func observeMemberPaymentProfiles(for group: DutchieGroup) {
        var handles = memberProfileObserverHandles[group.id] ?? [:]
        let validPhoneKeys = Set(group.members.compactMap { member -> String? in
            guard let phone = member.phoneNumber else { return nil }
            let key = phoneIndexKey(for: phone)
            return key.isEmpty ? nil : key
        })

        for (phoneKey, handle) in handles where !validPhoneKeys.contains(phoneKey) {
            ref.child("members").child(phoneKey).removeObserver(withHandle: handle)
            handles.removeValue(forKey: phoneKey)
        }

        for phoneKey in validPhoneKeys where handles[phoneKey] == nil {
            let handle = ref.child("members").child(phoneKey).observe(.value) { [weak self] snapshot in
                guard let self,
                      let dict = snapshot.value as? [String: Any] else { return }
                self.applyVerifiedMemberProfile(dict, phoneKey: phoneKey, groupID: group.id)
            }
            handles[phoneKey] = handle
        }

        memberProfileObserverHandles[group.id] = handles
    }

    private func stopObservingMemberProfiles(groupID: UUID) {
        guard let handles = memberProfileObserverHandles[groupID] else { return }
        for (phoneKey, handle) in handles {
            ref.child("members").child(phoneKey).removeObserver(withHandle: handle)
        }
        memberProfileObserverHandles.removeValue(forKey: groupID)
    }

    private func applyVerifiedMemberProfile(_ dict: [String: Any], phoneKey: String, groupID: UUID) {
        guard let groupIndex = allGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var group = allGroups[groupIndex]
        guard let memberIndex = group.members.firstIndex(where: { member in
            guard let phone = member.phoneNumber else { return false }
            return phoneIndexKey(for: phone) == phoneKey
        }) else { return }

        var member = group.members[memberIndex]
        var changed = false

        if let name = dict["name"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           member.profileName != name {
            member.profileName = name
            member.name = name
            changed = true
        }
        if let phone = dict["phoneNumber"] as? String,
           !phone.isEmpty,
           member.phoneNumber != phone {
            member.phoneNumber = phone
            changed = true
        }
        if let imageDataStr = dict["imageData"] as? String,
           let imageData = Data(base64Encoded: imageDataStr),
           member.imageData != imageData {
            member.imageData = imageData
            changed = true
        }
        if let venmoUsername = dict["venmoUsername"] as? String,
           member.venmoUsername != venmoUsername {
            member.venmoUsername = venmoUsername
            changed = true
        }
        if let venmoLink = dict["venmoLink"] as? String,
           member.venmoLink != venmoLink {
            member.venmoLink = venmoLink
            changed = true
        }
        if let zelleContact = dict["zelleContact"] as? String,
           member.zelleEmail != zelleContact {
            member.zelleEmail = zelleContact
            changed = true
        }
        if let zelleLink = dict["zelleLink"] as? String,
           member.zelleLink != zelleLink {
            member.zelleLink = zelleLink
            changed = true
        }
        if member.isPending {
            member.isPending = false
            changed = true
        }

        guard changed else { return }

        group.members[memberIndex] = LocalContactNameStore.apply(to: member)
        allGroups[groupIndex] = group
        if activeGroup?.id == groupID {
            activeGroup = group
        }
        save()
        updateMemberInFirebase(member, groupID: groupID)
        objectWillChange.send()
    }
    
    private func handleExpensesUpdate(snapshot: DataSnapshot, groupID: UUID, onChange: @escaping (DutchieGroup) -> Void) {
        var expenses: [GroupExpense] = []
        var allShares: [UUID: [ExpenseShare]] = [:]
        
        for child in snapshot.children {
            guard let expenseSnapshot = child as? DataSnapshot,
                  let dict = expenseSnapshot.value as? [String: Any],
                  let idStr = dict["id"] as? String,
                  let expenseID = UUID(uuidString: idStr),
                  let groupIDStr = dict["groupID"] as? String,
                  let addedByIDStr = dict["addedByID"] as? String,
                  let addedByID = UUID(uuidString: addedByIDStr),
                  let addedByName = dict["addedByName"] as? String,
                  let description = dict["description"] as? String,
                  let amount = doubleValue(dict["amount"]),
                  let dateStr = dict["date"] as? String,
                  let date = ISO8601DateFormatter().date(from: dateStr),
                  let splitAmongIDsStrs = dict["splitAmongIDs"] as? [String] else { continue }
            
            let splitAmongIDs = splitAmongIDsStrs.compactMap { UUID(uuidString: $0) }
            let isArchived = (dict["isArchived"] as? Bool) ?? false
            let settled = (dict["settled"] as? Bool) ?? false
            let backgroundResultToken = dict["backgroundResultToken"] as? String
            let sourceTransactionID = (dict["sourceTransactionID"] as? String).flatMap(UUID.init(uuidString:))
            let sourceUploadSessionID = (dict["sourceUploadSessionID"] as? String).flatMap(UUID.init(uuidString:))
             
            let expense = GroupExpense(
                id: expenseID,
                groupID: UUID(uuidString: groupIDStr) ?? groupID,
                addedByID: addedByID,
                addedByName: addedByName,
                description: description,
                amount: amount,
                date: date,
                splitAmongIDs: splitAmongIDs,
                isArchived: isArchived,
                settled: settled,
                backgroundResultToken: backgroundResultToken,
                sourceTransactionID: sourceTransactionID,
                sourceUploadSessionID: sourceUploadSessionID
            )
            
            expenses.append(expense)

            if let sharesDict = dict["shares"] as? [String: Any] {
                let shares = sharesDict.compactMap { shareKey, value -> ExpenseShare? in
                    guard let shareDict = value as? [String: Any] else { return nil }
                    return parseExpenseShare(shareDict, fallbackMemberIDString: shareKey)
                }
                allShares[expenseID] = shares
            }
        }
        
        var group = getOrCreateGroup(groupID: groupID)
        group.expenses = expenses
        group.expenseShares = allShares
        
        updateGroupInMemory(group)
        DispatchQueue.main.async {
            onChange(group)
        }
    }

    private func parseExpenseShare(_ dict: [String: Any], fallbackMemberIDString: String) -> ExpenseShare? {
        let memberIDString = (dict["memberID"] as? String) ?? fallbackMemberIDString
        guard let memberID = UUID(uuidString: memberIDString),
              let owedAmount = doubleValue(dict["owedAmount"]),
              let statusStr = dict["status"] as? String,
              let status = ExpenseShare.ShareStatus(rawValue: statusStr) else { return nil }

        let memberName = dict["memberName"] as? String ?? "Member"
        let paidDate = (dict["paidDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

        return ExpenseShare(
            id: memberID,
            memberID: memberID,
            memberName: memberName,
            owedAmount: owedAmount,
            status: status,
            paidDate: paidDate
        )
    }
    
    func stopObservingGroup(groupID: UUID) {
        guard let handles = groupObserverHandles[groupID] else { return }

        for token in handles {
            token.ref.removeObserver(withHandle: token.handle)
        }
        
        groupObserverHandles.removeValue(forKey: groupID)
        stopObservingMemberProfiles(groupID: groupID)
        print("✅ Stopped observing group: \(groupID)")
    }
    
    // MARK: - Helper Methods
    
    private func getOrCreateGroup(groupID: UUID) -> DutchieGroup {
        if let existing = activeGroup, existing.id == groupID {
            return existing
        }
        if let existing = allGroups.first(where: { $0.id == groupID }) {
            return existing
        }
        return DutchieGroup(id: groupID, name: "", members: [])
    }
    
    private func updateGroupInMemory(_ group: DutchieGroup) {
        if isLocallyHidden(group.id) || currentUserHasLeft(group) {
            hideGroupLocally(group.id)
            allGroups.removeAll { $0.id == group.id }
            if activeGroup?.id == group.id {
                activeGroup = nil
                isGroupModeEnabled = false
            }
            save()
            objectWillChange.send()
            return
        }

        upsertGroup(group)
        
        if activeGroup?.id == group.id {
            activeGroup = group
        }
        
        save()
    }

    private func upsertGroup(_ group: DutchieGroup) {
        allGroups.removeAll { $0.id == group.id }
        allGroups.append(group)
        allGroups = uniqueGroupsByID(allGroups)
    }

    private func uniqueGroupsByID(_ groups: [DutchieGroup]) -> [DutchieGroup] {
        var seen = Set<UUID>()
        var unique: [DutchieGroup] = []

        for group in groups.reversed() {
            guard !seen.contains(group.id) else { continue }
            seen.insert(group.id)
            unique.insert(group, at: 0)
        }

        return unique
    }

    func isAvailableToCurrentUser(_ group: DutchieGroup) -> Bool {
        !group.isArchived && !isLocallyHidden(group.id) && !currentUserHasLeft(group)
    }

    private func isCurrentUserActiveMember(of group: DutchieGroup) -> Bool {
        if group.members.contains(where: { $0.isCurrentUser && !$0.isPending && !$0.hasLeft }) {
            return true
        }

        guard let phone = AuthManager.shared.phoneNumber, !phone.isEmpty else { return false }
        let normalizedCurrentPhone = normalizePhoneNumber(phone)
        return group.members.contains { member in
            guard !member.isPending, !member.hasLeft, let memberPhone = member.phoneNumber else {
                return false
            }
            return normalizePhoneNumber(memberPhone) == normalizedCurrentPhone
        }
    }

    private func currentUserHasLeft(_ group: DutchieGroup) -> Bool {
        if isLocallyHidden(group.id) { return true }

        if let currentMember = group.members.first(where: { $0.isCurrentUser }) {
            return currentMember.hasLeft
        }

        guard let phone = AuthManager.shared.phoneNumber, !phone.isEmpty else { return false }
        let normalizedCurrentPhone = normalizePhoneNumber(phone)
        return group.members.contains { member in
            guard let memberPhone = member.phoneNumber else { return false }
            return normalizePhoneNumber(memberPhone) == normalizedCurrentPhone && member.hasLeft
        }
    }

    private func isLocallyHidden(_ groupID: UUID) -> Bool {
        locallyHiddenGroupIDs.contains(groupID.uuidString)
    }

    private func hideGroupLocally(_ groupID: UUID) {
        locallyHiddenGroupIDs.insert(groupID.uuidString)
        UserDefaults.standard.set(Array(locallyHiddenGroupIDs), forKey: locallyHiddenGroupIDsKey)
    }

    private func unhideGroupLocally(_ groupID: UUID) {
        locallyHiddenGroupIDs.remove(groupID.uuidString)
        UserDefaults.standard.set(Array(locallyHiddenGroupIDs), forKey: locallyHiddenGroupIDsKey)
    }

    private func pruneLocallyHiddenGroups() {
        allGroups.removeAll { isLocallyHidden($0.id) }
        if let activeGroup, isLocallyHidden(activeGroup.id) {
            self.activeGroup = nil
            isGroupModeEnabled = false
        }
        save()
    }
    
    func markCurrentUserInGroup(_ group: inout DutchieGroup, authenticatedPhone: String?) {
        guard let currentPhone = authenticatedPhone else {
            print("⚠️ No authenticated phone number")
            return
        }
        
        let normalizedCurrentPhone = normalizePhoneNumber(currentPhone)
        
        for index in group.members.indices {
            if let memberPhone = group.members[index].phoneNumber {
                let normalizedMemberPhone = normalizePhoneNumber(memberPhone)
                let isMatch = normalizedMemberPhone == normalizedCurrentPhone
                
                group.members[index].isCurrentUser = isMatch
            } else {
                group.members[index].isCurrentUser = false
            }
        }
    }

    // Helper function to normalize phone numbers
    private func normalizePhoneNumber(_ phone: String) -> String {
        let digitsOnly = phone.filter { $0.isNumber }
        
        if digitsOnly.count == 10 {
            return "+1" + digitsOnly
        }
        
        if digitsOnly.count == 11, digitsOnly.first == "1" {
            return "+" + digitsOnly
        }
        
        if phone.hasPrefix("+") {
            return "+" + digitsOnly
        }
        
        return digitsOnly.isEmpty ? phone : "+" + digitsOnly
    }

    private func phoneIndexKey(for phone: String?) -> String {
        (phone ?? "").filter { $0.isNumber }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func isGeneratedMemberName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Member") else { return false }
        let suffix = trimmed.dropFirst("Member".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty || suffix.allSatisfy { $0.isNumber }
    }
    
    // MARK: - Public API (adapted to Firebase-first)
    
    func createGroup(name: String, members: [GroupMember], maxMemberCount: Int? = nil) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to create a group.") else {
            return
        }

        guard AuthManager.shared.canUseGroupMode else {
            print("🚫 Group mode requires a verified phone number")
            return
        }

        guard canCreatePersonalGroup(maxMemberCount: maxMemberCount) else {
            print("🚫 Free group limit reached. Start Dutch Pro to create another active group.")
            return
        }

        let deduplicatedMembers = deduplicateMembersByPhone(members)
        
        let currentUserID = deduplicatedMembers.first(where: { $0.isCurrentUser })?.id
        
        let group = DutchieGroup(
            name: name,
            members: deduplicatedMembers,
            createdByID: currentUserID,
            createdAt: Date(),
            maxMemberCount: maxMemberCount
        )
        
        activeGroup = group
        isGroupModeEnabled = true
        
        if !allGroups.contains(where: { $0.id == group.id }) {
            allGroups.append(group)
        }
        
        save()
        
        // Write to Firebase
        createGroupInFirebase(group)
        
        // Start observing
        observeGroup(groupID: group.id) { [weak self] updatedGroup in
            self?.handleGroupUpdate(updatedGroup)
        }
        
        objectWillChange.send()
    }
    
    func createFreshGroup(name: String, members: [GroupMember]) {
        createGroup(name: name, members: members)
    }

    // MARK: - Tutorial-only helpers (no auth, no network, no Firebase)

    func createTutorialGroup(name: String, members: [GroupMember]) {
        let group = DutchieGroup(
            name: name,
            members: members,
            createdByID: members.first(where: { $0.isCurrentUser })?.id,
            createdAt: Date(),
            maxMemberCount: nil
        )
        activeGroup = group
        isGroupModeEnabled = true
        if !allGroups.contains(where: { $0.id == group.id }) {
            allGroups.append(group)
        }
        objectWillChange.send()
    }

    func addTutorialExpense(_ expense: GroupExpense) {
        guard var group = activeGroup else { return }
        group.expenses.append(expense)
        activeGroup = group
        if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[index] = group
        }
        objectWillChange.send()
    }

    func removeTutorialGroup(named name: String) {
        let groupsToRemove = allGroups.filter { isTutorialGroup($0) }
        let groupIDsToRemove = Set(groupsToRemove.map(\.id))

        allGroups.removeAll { group in
            groupIDsToRemove.contains(group.id) || isTutorialGroup(group)
        }
        if let activeGroup, activeGroup.name == name && isTutorialGroup(activeGroup) {
            purgeTutorialGroupEverywhere(activeGroup)
            self.activeGroup = nil
            isGroupModeEnabled = false
        }
        for group in groupsToRemove {
            purgeTutorialGroupEverywhere(group)
        }
        save()
        objectWillChange.send()
    }

    private func isTutorialGroup(_ group: DutchieGroup) -> Bool {
        guard group.name == tutorialGroupName else { return false }

        let hasTutorialMember = group.members.contains { member in
            member.name == tutorialMemberName ||
            member.phoneNumber?.filter(\.isNumber) == tutorialMemberPhone.filter(\.isNumber)
        }
        let hasTutorialExpense = group.expenses.contains { expense in
            expense.description == "Dinner" || expense.description == "Groceries"
        }

        return hasTutorialMember || hasTutorialExpense
    }

    private func purgeTutorialGroupEverywhere(_ group: DutchieGroup) {
        stopObservingGroup(groupID: group.id)
        ActivityStore.shared.purgeGroups([group.id.uuidString])

        ref.child("groups").child(group.id.uuidString).removeValue()
        ref.child("groupActivity").child(group.id.uuidString).removeValue()

        ref.child("groups")
            .queryOrdered(byChild: "name")
            .queryEqual(toValue: tutorialGroupName)
            .observeSingleEvent(of: .value) { [weak self] snapshot in
                guard let self else { return }

                for child in snapshot.children {
                    guard let groupSnapshot = child as? DataSnapshot,
                          let leakedGroupID = UUID(uuidString: groupSnapshot.key) else { continue }

                    let parsedGroup = self.parseGroupSnapshot(groupSnapshot, fallbackID: leakedGroupID)
                    guard parsedGroup.map(self.isTutorialGroup) ?? false else { continue }

                    self.stopObservingGroup(groupID: leakedGroupID)
                    self.ref.child("groups").child(groupSnapshot.key).removeValue()
                    self.ref.child("groupActivity").child(groupSnapshot.key).removeValue()
                    ActivityStore.shared.purgeGroups([groupSnapshot.key])
                }
            }
    }

    private func canCreatePersonalGroup(maxMemberCount: Int?) -> Bool {
        if maxMemberCount != nil {
            return true
        }
        if TrialManager.shared.hasActiveSubscription || TrialManager.shared.activeSubscriptionPoolGroupID != nil {
            return true
        }
        return currentUserAvailableGroups.count < TrialManager.shared.freeActiveGroupLimit
    }

    @discardableResult
    func activateSubscriptionGroupForCurrentUser(preferredGroupID: UUID? = nil) -> Bool {
        guard AuthManager.shared.canUseGroupMode else {
            print("🚫 Group mode requires a verified phone number")
            return false
        }
        guard !userDisabledGroupMode else {
            return false
        }

        let resolvedPreferredGroupID = preferredGroupID ?? TrialManager.shared.activeSubscriptionPoolGroupID
        let candidate =
            resolvedPreferredGroupID.flatMap { id in allGroups.first(where: { $0.id == id }) }
            ?? currentUserSubscriptionInviteGroups.first(where: { !$0.isSubscriptionInviteStaging })
            ?? allGroups.first(where: { $0.maxMemberCount != nil && !$0.isArchived && !$0.isSubscriptionInviteStaging })
            ?? currentUserSubscriptionInviteGroups.first
            ?? allGroups.first(where: { $0.maxMemberCount != nil && !$0.isArchived })

        guard var group = candidate, group.maxMemberCount != nil else { return false }

        unhideGroupLocally(group.id)
        markCurrentUserInGroup(&group, authenticatedPhone: AuthManager.shared.phoneNumber)
        mergeSubscriptionPlanMembersIntoGroup(&group, syncFirebase: true)

        if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[index] = group
        } else {
            allGroups.append(group)
        }

        activeGroup = group
        isGroupModeEnabled = true
        save()
        observeGroup(groupID: group.id) { [weak self] updatedGroup in
            self?.handleGroupUpdate(updatedGroup)
        }
        objectWillChange.send()
        return true
    }
    
    func setActiveGroup(_ group: DutchieGroup) {
        guard AuthManager.shared.canUseGroupMode else {
            activeGroup = nil
            isGroupModeEnabled = false
            save()
            objectWillChange.send()
            return
        }

        guard isAvailableToCurrentUser(group) else {
            allGroups.removeAll { $0.id == group.id }
            if activeGroup?.id == group.id {
                activeGroup = nil
                isGroupModeEnabled = false
            }
            save()
            objectWillChange.send()
            return
        }

        print("Setting active group: \(group.name)")
        
        activeGroup = group
        
        if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[index] = group
        } else {
            allGroups.append(group)
        }
        
        save()
        
        observeGroup(groupID: group.id) { [weak self] updatedGroup in
            self?.handleGroupUpdate(updatedGroup)
        }
        
        objectWillChange.send()
    }

    func grantInviteAccess(to group: DutchieGroup) {
        var groupForCurrentUser = group
        markCurrentUserInGroup(&groupForCurrentUser, authenticatedPhone: AuthManager.shared.phoneNumber)
        activeGroup = groupForCurrentUser
        isGroupModeEnabled = true
        inviteAccessGroupID = groupForCurrentUser.id

        if let index = allGroups.firstIndex(where: { $0.id == groupForCurrentUser.id }) {
            allGroups[index] = groupForCurrentUser
        } else {
            allGroups.append(groupForCurrentUser)
        }

        save()
        observeGroup(groupID: groupForCurrentUser.id) { [weak self] updatedGroup in
            self?.handleGroupUpdate(updatedGroup)
        }
        objectWillChange.send()
    }

    func cacheInviteGroupForActivation(_ group: DutchieGroup) {
        var groupForCurrentUser = group
        markCurrentUserInGroup(&groupForCurrentUser, authenticatedPhone: AuthManager.shared.phoneNumber)

        if let index = allGroups.firstIndex(where: { $0.id == groupForCurrentUser.id }) {
            allGroups[index] = groupForCurrentUser
        } else {
            allGroups.append(groupForCurrentUser)
        }

        if activeGroup?.id == groupForCurrentUser.id {
            activeGroup = groupForCurrentUser
        }

        save()
        objectWillChange.send()
    }

    func updateGroupPreservingCurrentMode(_ group: DutchieGroup) {
        upsertGroup(group)
        if activeGroup?.id == group.id {
            activeGroup = group
        }
        save()
        objectWillChange.send()
    }

    func ensureSubscriptionGroupVisible(groupID: UUID, groupName: String, profile: Profile, activate: Bool = false) {
        guard NetworkStatusMonitor.shared.isOnline else {
            if let existing = getGroup(by: groupID) {
                if activate {
                    setActiveGroup(existing)
                }
            }
            return
        }

        refreshGroupFromFirebase(groupID: groupID) { [weak self] fetchedGroup in
            guard let self else { return }

            var group = fetchedGroup ?? self.getGroup(by: groupID) ?? DutchieGroup(
                id: groupID,
                name: groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Dutch Group" : groupName,
                members: [],
                createdAt: Date(),
                maxMemberCount: TrialManager.shared.subscriptionMemberLimit,
                isSubscriptionInviteStaging: false
            )

            if group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                group.name = groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Dutch Group" : groupName
            }
            group.isSubscriptionInviteStaging = false
            if group.maxMemberCount == nil {
                group.maxMemberCount = TrialManager.shared.subscriptionMemberLimit
            }

            self.updateGroupInMemory(group)
            if self.shouldActivateCurrentUserForVisibleSubscriptionGroup(groupID: groupID, profile: profile) {
                _ = self.activateMember(
                    phoneNumber: AuthManager.shared.phoneNumber ?? profile.zelleContactInfo ?? "",
                    in: groupID,
                    currentUserProfile: profile
                )
            }

            if activate, let visibleGroup = self.getGroup(by: groupID) {
                self.setActiveGroup(visibleGroup)
            }

            self.ref.child("groups")
                .child(groupID.uuidString)
                .updateChildValues([
                    "name": group.name,
                    "isSubscriptionInviteStaging": false,
                    "maxMemberCount": group.maxMemberCount ?? TrialManager.shared.subscriptionMemberLimit ?? 6
                ])

            if self.groupObserverHandles[groupID] == nil {
                self.observeGroup(groupID: groupID) { [weak self] updatedGroup in
                    self?.handleGroupUpdate(updatedGroup)
                }
            }
        }
    }

    private func shouldActivateCurrentUserForVisibleSubscriptionGroup(groupID: UUID, profile: Profile) -> Bool {
        guard let group = getGroup(by: groupID) else { return true }
        let candidatePhone = AuthManager.shared.phoneNumber ?? profile.zelleContactInfo ?? ""
        let phoneKey = normalizePhoneNumber(candidatePhone)
        guard !phoneKey.isEmpty else { return false }

        if let activeMember = group.members.first(where: { member in
            guard !member.isPending, !member.hasLeft, let memberPhone = member.phoneNumber else { return false }
            return normalizePhoneNumber(memberPhone) == phoneKey
        }) {
            return !activeMember.isCurrentUser
        }

        return group.members.contains { member in
            guard member.isPending, !member.hasLeft, let memberPhone = member.phoneNumber else { return false }
            return normalizePhoneNumber(memberPhone) == phoneKey
        }
    }
    
    func addExpense(_ expense: GroupExpense) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to sync this expense with your group.") else {
            return
        }

        guard var group = activeGroup else { return }

        group.expenses.append(expense)
        activeGroup = group

        if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[index] = group
        }

        save()
        addExpenseToFirebase(expense)
        objectWillChange.send()

        // Notify teammates when someone else adds an expense
        let currentUserID = group.members.first(where: { $0.isCurrentUser })?.id
        if expense.addedByID != currentUserID {
            NotificationManager.shared.notifyExpenseAdded(
                byName: expense.addedByName,
                groupName: group.name,
                description: expense.description,
                amount: expense.amount
            )
        }

        ActivityStore.write(
            groupID: group.id.uuidString,
            groupName: group.name,
            type: .expenseAdded,
            actorName: expense.addedByName,
            detail: expense.description,
            amount: expense.amount,
            receiptBatchID: expense.backgroundResultToken
        )
    }

    func upsertReviewExpense(_ expense: GroupExpense) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to sync this expense with your group.") else {
            return
        }

        guard let sourceTransactionID = expense.sourceTransactionID else {
            addExpense(expense)
            return
        }

        guard var group = activeGroup else { return }

        if let existingIndex = group.expenses.firstIndex(where: {
            $0.sourceTransactionID == sourceTransactionID &&
            $0.sourceUploadSessionID == expense.sourceUploadSessionID
        }) {
            let existingID = group.expenses[existingIndex].id
            group.expenses[existingIndex].addedByID = expense.addedByID
            group.expenses[existingIndex].addedByName = expense.addedByName
            group.expenses[existingIndex].description = expense.description
            group.expenses[existingIndex].amount = expense.amount
            group.expenses[existingIndex].splitAmongIDs = expense.splitAmongIDs
            group.expenses[existingIndex].isArchived = false
            group.expenses[existingIndex].backgroundResultToken = expense.backgroundResultToken
            group.expenses[existingIndex].sourceTransactionID = sourceTransactionID
            group.expenses[existingIndex].sourceUploadSessionID = expense.sourceUploadSessionID

            activeGroup = group
            if let groupIndex = allGroups.firstIndex(where: { $0.id == group.id }) {
                allGroups[groupIndex] = group
            }

            save()
            updateExpenseInFirebase(group.expenses[existingIndex])
            replaceSharesForExpense(group.expenses[existingIndex])
            objectWillChange.send()
            print("✅ Updated existing review expense: \(expense.description) (\(existingID))")
            return
        }

        addExpense(expense)
    }

    func syncReviewExpenses(
        _ reviewExpenses: [GroupExpense],
        keeping sourceTransactionIDs: Set<UUID>,
        uploadSessionID: UUID,
        groupID: UUID,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to sync this split with your group.") else {
            completion(.failure(NSError(
                domain: "Dutch.GroupSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Turn on Wi-Fi or cellular data to sync this split with your group."]
            )))
            return
        }

        guard var group = activeGroup ?? allGroups.first(where: { $0.id == groupID }) else {
            completion(.failure(NSError(
                domain: "Dutch.GroupSync",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No active group found. Please create or join a group first."]
            )))
            return
        }

        guard !reviewExpenses.isEmpty else {
            completion(.failure(NSError(
                domain: "Dutch.GroupSync",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "There are no expenses to sync."]
            )))
            return
        }

        var syncedExpenses: [GroupExpense] = []
        var newActivityExpenses: [GroupExpense] = []

        for incomingExpense in reviewExpenses {
            var expenseToSave = incomingExpense

            if let sourceTransactionID = incomingExpense.sourceTransactionID,
               let existingIndex = group.expenses.firstIndex(where: {
                   $0.sourceTransactionID == sourceTransactionID &&
                   $0.sourceUploadSessionID == incomingExpense.sourceUploadSessionID
               }) {
                let existingExpense = group.expenses[existingIndex]
                expenseToSave = GroupExpense(
                    id: existingExpense.id,
                    groupID: existingExpense.groupID,
                    addedByID: incomingExpense.addedByID,
                    addedByName: incomingExpense.addedByName,
                    description: incomingExpense.description,
                    amount: incomingExpense.amount,
                    date: existingExpense.date,
                    splitAmongIDs: incomingExpense.splitAmongIDs,
                    isArchived: false,
                    settled: existingExpense.settled,
                    backgroundResultToken: incomingExpense.backgroundResultToken,
                    sourceTransactionID: sourceTransactionID,
                    sourceUploadSessionID: incomingExpense.sourceUploadSessionID
                )
                group.expenses[existingIndex] = expenseToSave
            } else {
                group.expenses.append(expenseToSave)
                newActivityExpenses.append(expenseToSave)
            }

            group.expenseShares[expenseToSave.id] = localShares(for: expenseToSave, in: group)
            syncedExpenses.append(expenseToSave)
        }

        var archivedExpenses: [GroupExpense] = []
        for index in group.expenses.indices {
            guard let sourceTransactionID = group.expenses[index].sourceTransactionID,
                  group.expenses[index].sourceUploadSessionID == uploadSessionID,
                  !sourceTransactionIDs.contains(sourceTransactionID),
                  !group.expenses[index].isArchived else {
                continue
            }

            group.expenses[index].isArchived = true
            archivedExpenses.append(group.expenses[index])
        }

        var updates: [String: Any] = [:]
        let groupPath = "groups/\(group.id.uuidString)"

        for expense in syncedExpenses {
            updates["\(groupPath)/expenses/\(expense.id.uuidString)"] = firebasePayload(for: expense, in: group)
        }

        for expense in archivedExpenses {
            updates["\(groupPath)/expenses/\(expense.id.uuidString)/isArchived"] = true
        }

        if activeGroup?.id == group.id {
            activeGroup = group
        }
        if let groupIndex = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[groupIndex] = group
        }
        save()
        objectWillChange.send()

        ref.updateChildValues(updates) { [weak self] error, _ in
            DispatchQueue.main.async {
                if let error = error {
                    print("Failed to sync review expenses: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }

                print("✅ Synced \(syncedExpenses.count) review expense(s) to Firebase")
                if !archivedExpenses.isEmpty {
                    print("🗂️ Archived \(archivedExpenses.count) review expense(s) removed from the current split")
                }

                for expense in newActivityExpenses {
                    ActivityStore.write(
                        groupID: group.id.uuidString,
                        groupName: group.name,
                        type: .expenseAdded,
                        actorName: expense.addedByName,
                        detail: expense.description,
                        amount: expense.amount,
                        receiptBatchID: expense.backgroundResultToken
                    )
                }

                self?.objectWillChange.send()
                completion(.success(syncedExpenses.count))
            }
        }
    }

    private func localShares(for expense: GroupExpense, in group: DutchieGroup) -> [ExpenseShare] {
        guard !expense.splitAmongIDs.isEmpty else { return [] }

        let shareAmount = expense.amount / Double(expense.splitAmongIDs.count)
        return expense.splitAmongIDs.compactMap { memberID in
            guard let member = group.members.first(where: { $0.id == memberID }) else { return nil }
            return ExpenseShare(
                memberID: memberID,
                memberName: member.syncedName,
                owedAmount: shareAmount,
                status: .pending
            )
        }
    }

    private func firebasePayload(for expense: GroupExpense, in group: DutchieGroup) -> [String: Any] {
        var expenseData: [String: Any] = [
            "id": expense.id.uuidString,
            "groupID": expense.groupID.uuidString,
            "addedByID": expense.addedByID.uuidString,
            "addedByName": expense.addedByName,
            "description": expense.description,
            "amount": expense.amount,
            "date": ISO8601DateFormatter().string(from: expense.date),
            "splitAmongIDs": expense.splitAmongIDs.map { $0.uuidString },
            "isArchived": expense.isArchived,
            "settled": expense.settled
        ]

        if let backgroundResultToken = expense.backgroundResultToken {
            expenseData["backgroundResultToken"] = backgroundResultToken
        }
        if let sourceTransactionID = expense.sourceTransactionID {
            expenseData["sourceTransactionID"] = sourceTransactionID.uuidString
        }
        if let sourceUploadSessionID = expense.sourceUploadSessionID {
            expenseData["sourceUploadSessionID"] = sourceUploadSessionID.uuidString
        }

        let shares = localShares(for: expense, in: group)
        if !shares.isEmpty {
            var sharesData: [String: Any] = [:]
            for share in shares {
                sharesData[share.memberID.uuidString] = [
                    "memberID": share.memberID.uuidString,
                    "memberName": share.memberName,
                    "owedAmount": share.owedAmount,
                    "status": share.status.rawValue
                ]
            }
            expenseData["shares"] = sharesData
        }

        return expenseData
    }

    func archiveReviewExpensesNotIn(_ sourceTransactionIDs: Set<UUID>, uploadSessionID: UUID, groupID: UUID) {
        guard var group = activeGroup ?? allGroups.first(where: { $0.id == groupID }) else { return }
        var archivedExpenses: [GroupExpense] = []

        for index in group.expenses.indices {
            guard let sourceTransactionID = group.expenses[index].sourceTransactionID,
                  group.expenses[index].sourceUploadSessionID == uploadSessionID,
                  !sourceTransactionIDs.contains(sourceTransactionID),
                  !group.expenses[index].isArchived else {
                continue
            }

            group.expenses[index].isArchived = true
            archivedExpenses.append(group.expenses[index])
        }

        guard !archivedExpenses.isEmpty else { return }

        if activeGroup?.id == group.id {
            activeGroup = group
        }
        if let groupIndex = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[groupIndex] = group
        }

        save()
        for expense in archivedExpenses {
            ref.child("groups").child(group.id.uuidString)
                .child("expenses").child(expense.id.uuidString)
                .child("isArchived").setValue(true)
        }
        objectWillChange.send()
        print("🗂️ Archived \(archivedExpenses.count) review expense(s) removed from the current split")
    }

    private func updateExpenseInFirebase(_ expense: GroupExpense) {
        let expenseRef = ref.child("groups").child(expense.groupID.uuidString)
            .child("expenses").child(expense.id.uuidString)

        var values: [String: Any] = [
            "addedByID": expense.addedByID.uuidString,
            "addedByName": expense.addedByName,
            "description": expense.description,
            "amount": expense.amount,
            "splitAmongIDs": expense.splitAmongIDs.map { $0.uuidString },
            "isArchived": expense.isArchived,
            "settled": expense.settled
        ]

        if let backgroundResultToken = expense.backgroundResultToken {
            values["backgroundResultToken"] = backgroundResultToken
        }
        if let sourceTransactionID = expense.sourceTransactionID {
            values["sourceTransactionID"] = sourceTransactionID.uuidString
        }
        if let sourceUploadSessionID = expense.sourceUploadSessionID {
            values["sourceUploadSessionID"] = sourceUploadSessionID.uuidString
        }

        expenseRef.updateChildValues(values) { error, _ in
            if let error = error {
                print("Failed to update expense: \(error.localizedDescription)")
            } else {
                print("✅ Updated expense in Firebase: \(expense.description)")
            }
        }
    }

    private func replaceSharesForExpense(_ expense: GroupExpense) {
        let sharesRef = ref.child("groups").child(expense.groupID.uuidString)
            .child("expenses").child(expense.id.uuidString).child("shares")

        sharesRef.removeValue { [weak self] _, _ in
            self?.createSharesForExpense(expense)
        }
    }

    func updateReceiptBackedExpense(backgroundResultToken token: String, amount: Double, description: String?) {
        guard var group = activeGroup ?? allGroups.first(where: { group in
            group.expenses.contains { $0.backgroundResultToken == token }
        }),
              let expenseIndex = group.expenses.firstIndex(where: { $0.backgroundResultToken == token }) else {
            return
        }

        group.expenses[expenseIndex].amount = amount
        let expense = group.expenses[expenseIndex]
        if activeGroup?.id == group.id {
            activeGroup = group
        }

        if let groupIndex = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[groupIndex] = group
        }

        save()

        let expenseRef = ref.child("groups").child(group.id.uuidString)
            .child("expenses").child(expense.id.uuidString)
        var values: [String: Any] = ["amount": amount]
        if let description, !description.isEmpty {
            values["description"] = description
        }
        expenseRef.updateChildValues(values)

        let shareAmount = expense.splitAmongIDs.isEmpty ? 0 : amount / Double(expense.splitAmongIDs.count)
        let sharesRef = expenseRef.child("shares")
        for memberID in expense.splitAmongIDs {
            sharesRef.child(memberID.uuidString).child("owedAmount").setValue(shareAmount)
        }

        objectWillChange.send()
    }
    
    func enableGroupMode() {
        guard AuthManager.shared.canUseGroupMode else {
            activeGroup = nil
            isGroupModeEnabled = false
            save()
            objectWillChange.send()
            print("🚫 Group mode requires a verified phone number")
            return
        }

        UserDefaults.standard.set(false, forKey: userDisabledGroupModeKey)
        isGroupModeEnabled = true
        save()
    }
    
    func disableGroupMode(clearActiveGroup: Bool = false) {
        UserDefaults.standard.set(true, forKey: userDisabledGroupModeKey)
        if clearActiveGroup {
            activeGroup = nil
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        isGroupModeEnabled = false
        save()
    }

    func fullReset() {
        // Stop ALL Firebase group observers
        let observedGroupIDs = Array(groupObserverHandles.keys)
        for groupID in observedGroupIDs { stopObservingGroup(groupID: groupID) }

        // If we still have a Firebase user, delete owned subscription data from Firebase
        if let uid = Auth.auth().currentUser?.uid {
            let database = Database.database().reference()
            database.child("subscriptionMemberships").child(uid).removeValue()
            database.child("subscriptions").child(uid).removeValue()
            // Delete any subscription-invite staging groups the user created
            for group in allGroups where group.isSubscriptionInviteStaging {
                database.child("groups").child(group.id.uuidString).removeValue()
                database.child("subscriptions").child(group.id.uuidString).removeValue()
            }
        }

        // Clear all in-memory state
        allGroups = []
        activeGroup = nil
        pendingInvite = nil
        isGroupModeEnabled = false
        locallyHiddenGroupIDs = []
        inviteAccessGroupID = nil
        groupObserverHandles = [:]
        memberProfileObserverHandles = [:]

        // Explicitly remove all group UserDefaults keys so removePersistentDomain
        // isn't the only thing standing between reset and stale group data
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: "\(storageKey)_enabled")
        UserDefaults.standard.removeObject(forKey: allGroupsKey)
        UserDefaults.standard.removeObject(forKey: inviteAccessGroupKey)
        UserDefaults.standard.removeObject(forKey: userDisabledGroupModeKey)
        UserDefaults.standard.removeObject(forKey: locallyHiddenGroupIDsKey)

        objectWillChange.send()
    }
    
    func leaveAndClearGroup() {
        if let group = activeGroup, isProtectedSubscriptionGroup(group) {
            print("Subscription group cannot be left or hidden: \(group.name)")
            return
        }

        if let group = activeGroup {
            hideGroupLocally(group.id)
            stopObservingGroup(groupID: group.id)
            allGroups.removeAll { $0.id == group.id }
        }
        
        activeGroup = nil
        isGroupModeEnabled = false
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: "\(storageKey)_enabled")
        NotificationCenter.default.post(name: .groupDidLeave, object: nil)
    }

    @discardableResult
    func leaveActiveGroupForCurrentUser(groupID: UUID? = nil) -> DutchieGroup? {
        let targetID = groupID ?? activeGroup?.id
        guard let targetID,
              var group = (activeGroup?.id == targetID ? activeGroup : nil) ?? allGroups.first(where: { $0.id == targetID }) else {
            if let targetID {
                if allGroups.contains(where: { $0.id == targetID && isProtectedSubscriptionGroup($0) }) {
                    print("Subscription group cannot be left or hidden: \(targetID)")
                    return nil
                }
                hideGroupLocally(targetID)
                allGroups.removeAll { $0.id == targetID }
                if activeGroup?.id == targetID {
                    activeGroup = nil
                    isGroupModeEnabled = false
                }
                save()
                objectWillChange.send()
                NotificationCenter.default.post(name: .groupDidLeave, object: nil)
            } else {
                leaveAndClearGroup()
            }
            return nil
        }

        if isProtectedSubscriptionGroup(group) {
            print("Subscription group cannot be left or hidden: \(group.name)")
            return group
        }

        let currentIndex = indexOfCurrentUser(in: group)
        let leavingMember = currentIndex.map { group.members[$0] }

        if let currentIndex {
            group.members[currentIndex].hasLeft = true
            group.members[currentIndex].leftAt = Date()
            group.members[currentIndex].isPending = false
            updateMemberInFirebase(group.members[currentIndex], groupID: group.id)
        }

        ActivityStore.write(
            groupID: group.id.uuidString,
            groupName: group.name,
            type: .memberLeft,
            actorName: leavingMember?.name ?? "A member",
            detail: "\(leavingMember?.name ?? "A member") left the group"
        )

        stopObservingGroup(groupID: group.id)
        hideGroupLocally(group.id)
        allGroups.removeAll { $0.id == group.id }
        if activeGroup?.id == group.id {
            activeGroup = nil
            isGroupModeEnabled = false
        }
        save()
        objectWillChange.send()
        NotificationCenter.default.post(name: .groupDidLeave, object: nil)
        NotificationCenter.default.post(name: .groupDidLeaveWithUndo, object: nil, userInfo: ["group": group])
        return group
    }

    private func indexOfCurrentUser(in group: DutchieGroup) -> Int? {
        if let index = group.members.firstIndex(where: { $0.isCurrentUser }) {
            return index
        }

        guard let phone = AuthManager.shared.phoneNumber, !phone.isEmpty else { return nil }
        let normalizedCurrentPhone = normalizePhoneNumber(phone)
        return group.members.firstIndex { member in
            guard let memberPhone = member.phoneNumber else { return false }
            return normalizePhoneNumber(memberPhone) == normalizedCurrentPhone
        }
    }

    func restoreLeftGroup(_ group: DutchieGroup) {
        var restored = group
        unhideGroupLocally(restored.id)
        if let index = restored.members.firstIndex(where: { $0.isCurrentUser }) {
            restored.members[index].hasLeft = false
            restored.members[index].leftAt = nil
            restored.members[index].isPending = false
            updateMemberInFirebase(restored.members[index], groupID: restored.id)

        }

        if let allIndex = allGroups.firstIndex(where: { $0.id == restored.id }) {
            allGroups[allIndex] = restored
        } else {
            allGroups.append(restored)
        }
        activeGroup = restored
        isGroupModeEnabled = true
        save()
        observeGroup(groupID: restored.id) { [weak self] updatedGroup in
            self?.handleGroupUpdate(updatedGroup)
        }
        objectWillChange.send()
    }
    
    func deleteGroup(_ group: DutchieGroup) {
        if isProtectedSubscriptionGroup(group) {
            print("Subscription group cannot be deleted: \(group.name)")
            return
        }

        stopObservingGroup(groupID: group.id)
        allGroups.removeAll { $0.id == group.id }
        
        if activeGroup?.id == group.id {
            activeGroup = nil
            isGroupModeEnabled = false
        }
        
        save()
        objectWillChange.send()
    }

    @discardableResult
    func deleteSubscriptionSplitGroup(_ group: DutchieGroup) -> DutchieGroup? {
        guard group.maxMemberCount != nil else {
            deleteGroup(group)
            return activeGroup
        }

        guard !TrialManager.shared.hasSharedSubscriptionAccess else {
            print("Shared subscription users cannot delete subscription split groups.")
            return group
        }

        stopObservingGroup(groupID: group.id)
        allGroups.removeAll { $0.id == group.id }

        let fallbackGroup = allGroups.first {
            $0.maxMemberCount != nil && !$0.isArchived && !$0.isSubscriptionInviteStaging
        } ?? allGroups.first {
            $0.maxMemberCount != nil && !$0.isArchived
        }

        if activeGroup?.id == group.id {
            activeGroup = fallbackGroup
            isGroupModeEnabled = fallbackGroup != nil
        }

        save()
        ref.child("groups").child(group.id.uuidString).removeValue()

        if let fallbackGroup,
           TrialManager.shared.ownedSubscriptionGroupID == group.id {
            TrialManager.shared.activateOwnedSubscriptionGroup(groupID: fallbackGroup.id, groupName: fallbackGroup.name)
        }

        objectWillChange.send()
        return fallbackGroup
    }

    private func isProtectedSubscriptionGroup(_ group: DutchieGroup) -> Bool {
        guard !group.isSubscriptionInviteStaging else { return false }
        let trialManager = TrialManager.shared
        return group.maxMemberCount != nil
            || trialManager.ownedSubscriptionGroupID == group.id
            || trialManager.sharedSubscriptionGroupID == group.id
            || trialManager.activeSubscriptionPoolGroupID == group.id
    }
    
    func upsertCurrentUserMember(_ member: GroupMember) {
        guard var group = activeGroup else { return }
        
        if let index = group.members.firstIndex(where: { $0.isCurrentUser }) {
            group.members[index] = member
        } else {
            group.members.insert(member, at: 0)
        }
        
        updateMemberInFirebase(member, groupID: group.id)
        setActiveGroup(group)
    }

    @discardableResult
    private func mergeSubscriptionPlanMembersIntoGroup(
        _ group: inout DutchieGroup,
        planMembers: [SubscriptionPlanMember]? = nil,
        syncFirebase: Bool,
        appendMissingMembers: Bool = false
    ) -> Bool {
        guard group.maxMemberCount != nil else { return false }
        if planMembers == nil,
           let subscriptionGroupID = TrialManager.shared.activeSubscriptionPoolGroupID,
           subscriptionGroupID != group.id {
            return false
        }

        let planMembers = planMembers ?? TrialManager.shared.subscriptionPlanMembers
        guard !planMembers.isEmpty else { return false }

        var changed = false
        var membersToSync: [GroupMember] = []

        for planMember in planMembers {
            let normalizedPlanPhone = planMember.phoneNumber.map(normalizePhoneNumber)
            let isPendingInvite = planMember.isPending
                || planMember.uid.hasPrefix("pending_")
                || (!planMember.isOwner && planMember.joinedAt == nil)

            if let existingIndex = group.members.firstIndex(where: { member in
                if member.id == planMember.memberUUID { return true }
                guard let normalizedPlanPhone,
                      let memberPhone = member.phoneNumber,
                      !memberPhone.isEmpty else { return false }
                return normalizePhoneNumber(memberPhone) == normalizedPlanPhone
            }) {
                var existing = group.members[existingIndex]
                var memberChanged = false

                if existing.phoneNumber?.isEmpty != false,
                   let phoneNumber = planMember.phoneNumber {
                    existing.phoneNumber = phoneNumber
                    memberChanged = true
                }

                let localName = LocalContactNameStore.name(for: existing.phoneNumber ?? planMember.phoneNumber)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let planName = planMember.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let preferredName = localName?.isEmpty == false ? localName! : planName
                if !preferredName.isEmpty,
                   (existing.syncedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isGeneratedMemberName(existing.syncedName)) {
                    existing.name = preferredName
                    existing.localDisplayName = localName?.isEmpty == false ? localName : existing.localDisplayName
                    memberChanged = true
                }

                if !existing.isCurrentUser {
                    if existing.isPending != isPendingInvite {
                        existing.isPending = isPendingInvite
                        memberChanged = true
                    }
                    if isPendingInvite,
                       existing.subscriptionSourceGroupID == nil {
                        existing.subscriptionSourceGroupID = group.id
                        memberChanged = true
                    }
                    let joinedAt = isPendingInvite ? nil : planMember.joinedAt
                    if existing.joinedAt != joinedAt {
                        existing.joinedAt = joinedAt
                        memberChanged = true
                    }
                    if existing.hasLeft {
                        existing.hasLeft = false
                        existing.leftAt = nil
                        memberChanged = true
                    }
                }

                if memberChanged {
                    group.members[existingIndex] = existing
                    membersToSync.append(existing)
                    changed = true
                }

                continue
            }

            guard appendMissingMembers || planMember.isOwner else {
                continue
            }

            if planMember.isOwner,
               group.members.contains(where: { $0.isCurrentUser }) {
                continue
            }

            let member = LocalContactNameStore.apply(to: GroupMember(
                id: planMember.memberUUID,
                name: planMember.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Invited Member" : planMember.name,
                phoneNumber: planMember.phoneNumber,
                isCurrentUser: false,
                isPending: isPendingInvite,
                joinedAt: isPendingInvite ? nil : planMember.joinedAt,
                subscriptionSourceGroupID: isPendingInvite ? group.id : nil
            ))

            group.members.append(member)
            membersToSync.append(member)
            changed = true
        }

        guard changed else { return false }

        group.members = deduplicateMembersByPhone(group.members)
        if syncFirebase {
            for member in membersToSync where !member.isCurrentUser {
                addMemberToFirebase(member, groupID: group.id)
            }
        }
        return true
    }

    private func hydrateSubscriptionMembersFromFirebase(for groupID: UUID) {
        guard NetworkStatusMonitor.shared.isOnline else { return }
        ref.child("subscriptions")
            .child(groupID.uuidString)
            .child("members")
            .observeSingleEvent(of: .value) { [weak self] snapshot in
                guard let self,
                      let membersData = snapshot.value as? [String: Any],
                      var group = self.activeGroup?.id == groupID
                        ? self.activeGroup
                        : self.allGroups.first(where: { $0.id == groupID }) else { return }

                let applyHydratedMembers: (Set<String>) -> Void = { excludedPoolKeys in
                    let scopedMembersData = self.groupScopedSubscriptionMembersData(
                        membersData,
                        groupID: groupID,
                        excludingPoolAssignedKeys: excludedPoolKeys
                    )
                    let planMembers = self.parseSubscriptionPlanMembers(scopedMembersData)
                    let removedBleedMembers = self.removeSubscriptionRosterBleed(from: &group, validPlanMembers: planMembers)
                    guard self.mergeSubscriptionPlanMembersIntoGroup(
                        &group,
                        planMembers: planMembers,
                        syncFirebase: false,
                        appendMissingMembers: true
                    ) || removedBleedMembers else { return }

                    if let index = self.allGroups.firstIndex(where: { $0.id == group.id }) {
                        self.allGroups[index] = group
                    } else {
                        self.allGroups.append(group)
                    }
                    if self.activeGroup?.id == group.id {
                        self.activeGroup = group
                    }
                    self.save()
                    self.objectWillChange.send()
                }

                guard groupID == TrialManager.shared.ownedSubscriptionGroupID else {
                    applyHydratedMembers([])
                    return
                }

                self.subscriptionMemberKeysAssignedOutsidePool(poolGroupID: groupID) { excludedKeys in
                    applyHydratedMembers(excludedKeys)
                }
            }
    }

    private func groupScopedSubscriptionMembersData(
        _ membersData: [String: Any],
        groupID: UUID,
        excludingPoolAssignedKeys excludedPoolKeys: Set<String>
    ) -> [String: Any] {
        membersData.filter { _, rawValue in
            guard let data = rawValue as? [String: Any] else { return false }
            if data["isOwner"] as? Bool == true { return true }
            if data["hasLeft"] as? Bool == true { return false }

            if let sourceGroupIDString = data["sourceGroupID"] as? String,
               let sourceGroupID = UUID(uuidString: sourceGroupIDString) {
                return sourceGroupID == groupID
            }

            guard !excludedPoolKeys.isEmpty,
                  let key = subscriptionMemberRawKey(data) else {
                return true
            }
            return !excludedPoolKeys.contains(key)
        }
    }

    private func subscriptionMemberKeysAssignedOutsidePool(
        poolGroupID: UUID,
        completion: @escaping (Set<String>) -> Void
    ) {
        ref.child("subscriptions").observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self,
                  let records = snapshot.value as? [String: Any] else {
                completion([])
                return
            }

            var keys = Set<String>()
            for (subscriptionID, rawValue) in records where subscriptionID != poolGroupID.uuidString {
                guard let record = rawValue as? [String: Any],
                      let members = record["members"] as? [String: Any] else { continue }

                for (_, rawMember) in members {
                    guard let data = rawMember as? [String: Any],
                          data["isOwner"] as? Bool != true,
                          data["hasLeft"] as? Bool != true,
                          let key = self.subscriptionMemberRawKey(data) else { continue }
                    keys.insert(key)
                }
            }
            completion(keys)
        }
    }

    private func subscriptionMemberRawKey(_ data: [String: Any]) -> String? {
        if let phone = data["phoneNumber"] as? String,
           !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "phone:\(normalizePhoneNumber(phone))"
        }
        if let uuid = data["memberUUID"] as? String,
           !uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "id:\(uuid)"
        }
        return nil
    }

    @discardableResult
    private func removeSubscriptionRosterBleed(
        from group: inout DutchieGroup,
        validPlanMembers: [SubscriptionPlanMember]
    ) -> Bool {
        guard group.maxMemberCount != nil else { return false }

        func memberKey(id: UUID, phone: String?) -> String {
            if let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "phone:\(normalizePhoneNumber(phone))"
            }
            return "id:\(id.uuidString)"
        }

        let validKeys = Set(validPlanMembers.map { memberKey(id: $0.memberUUID, phone: $0.phoneNumber) })
        let validOwnerKeys = Set(validPlanMembers.filter(\.isOwner).map { memberKey(id: $0.memberUUID, phone: $0.phoneNumber) })

        var removedMembers: [GroupMember] = []
        group.members.removeAll { member in
            guard member.isPending, !member.isCurrentUser, !member.hasLeft else { return false }
            let key = memberKey(id: member.id, phone: member.phoneNumber)
            let shouldRemove = validKeys.isEmpty || !validKeys.contains(key) || validOwnerKeys.contains(key)
            if shouldRemove {
                removedMembers.append(member)
            }
            return shouldRemove
        }

        guard !removedMembers.isEmpty else { return false }

        for member in removedMembers {
            ref.child("groups")
                .child(group.id.uuidString)
                .child("members")
                .child(member.id.uuidString)
                .removeValue()
        }

        return true
    }

    private func parseSubscriptionPlanMembers(_ membersData: [String: Any]) -> [SubscriptionPlanMember] {
        membersData.compactMap { uid, rawValue in
            guard let data = rawValue as? [String: Any] else { return nil }
            if data["hasLeft"] as? Bool == true { return nil }
            let memberUUID = (data["memberUUID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let joinedAt = (data["joinedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
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
    }
    
    func syncMembersToAppState(_ appState: AppState) {
        guard var group = activeGroup, isGroupModeEnabled else { return }

        if group.maxMemberCount != nil {
            hydrateSubscriptionMembersFromFirebase(for: group.id)
        }

        if group.maxMemberCount == nil,
           mergeSubscriptionPlanMembersIntoGroup(&group, syncFirebase: false) {
            activeGroup = group
            if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
                allGroups[index] = group
            } else {
                allGroups.append(group)
            }
            save()
            objectWillChange.send()
        }
        
        var uniqueMembers: [GroupMember] = []
        var seenIDs = Set<UUID>()
        
        for member in group.members {
            if !seenIDs.contains(member.id) {
                uniqueMembers.append(member)
                seenIDs.insert(member.id)
            }
        }
        
        var newPeople: [Person] = []
        
        if let currentUserInGroup = uniqueMembers.first(where: { $0.isCurrentUser }) {
            newPeople.append(Person(
                id: currentUserInGroup.id,
                name: currentUserInGroup.name,
                contactImage: currentUserInGroup.displayImageData,
                phoneNumber: currentUserInGroup.phoneNumber,
                isCurrentUser: true,
                venmoUsername: currentUserInGroup.venmoUsername,
                venmoLink: currentUserInGroup.venmoLink,
                zelleContact: currentUserInGroup.zelleEmail,
                zelleLink: currentUserInGroup.zelleLink,
                isPendingGroupMember: currentUserInGroup.isPending
            ))
        }
        
        for member in uniqueMembers where !member.isCurrentUser && !member.hasLeft {
            newPeople.append(Person(
                id: member.id,
                name: member.name,
                contactImage: member.displayImageData,
                phoneNumber: member.phoneNumber,
                isCurrentUser: false,
                venmoUsername: member.venmoUsername,
                venmoLink: member.venmoLink,
                zelleContact: member.zelleEmail,
                zelleLink: member.zelleLink,
                isPendingGroupMember: member.isPending
            ))
        }
        
        appState.people = newPeople
    }
    
    func removeDuplicateMembers() {
        guard var group = activeGroup else { return }
        
        let deduplicatedMembers = deduplicateMembersByPhone(group.members)
        
        if deduplicatedMembers.count != group.members.count {
            print("🧹 Removed \(group.members.count - deduplicatedMembers.count) duplicate members")
            group.members = deduplicatedMembers
            activeGroup = group
            
            if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
                allGroups[index] = group
            }
            
            save()
            
            // Update Firebase
            for member in deduplicatedMembers {
                updateMemberInFirebase(member, groupID: group.id)
            }
            
            objectWillChange.send()
        }
    }
    
    func currentUserNetBalance(currentUserID: UUID) -> Double? {
        activeGroup?.calculateBalances()
            .first(where: { $0.member.id == currentUserID })?
            .netBalance
    }
    
    private func phoneNumberExists(in members: [GroupMember], phone: String?) -> Bool {
        guard let phone = phone, !phone.isEmpty else { return false }
        let normalizedPhone = normalizePhoneNumber(phone)
        
        return members.contains { member in
            guard let memberPhone = member.phoneNumber, !memberPhone.isEmpty else { return false }
            return normalizePhoneNumber(memberPhone) == normalizedPhone
        }
    }

    private func memberMatches(_ lhs: GroupMember, _ rhs: GroupMember) -> Bool {
        if lhs.id == rhs.id { return true }
        guard let lhsPhone = lhs.phoneNumber,
              let rhsPhone = rhs.phoneNumber,
              !lhsPhone.isEmpty,
              !rhsPhone.isEmpty else { return false }
        return normalizePhoneNumber(lhsPhone) == normalizePhoneNumber(rhsPhone)
    }

    func inviteAvailability(for groupID: UUID, proposedMember: GroupMember? = nil) -> GroupInviteAvailability {
        guard let group = allGroups.first(where: { $0.id == groupID }) else {
            return GroupInviteAvailability(canInvite: false, message: "Could not find this group.", remainingGroupSlots: nil, remainingPlanSeats: nil)
        }

        let remainingGroupSlots = group.remainingInviteSlots

        if let proposedMember,
           group.members.contains(where: { !$0.hasLeft && memberMatches($0, proposedMember) }) {
            return GroupInviteAvailability(canInvite: false, message: AddPendingMemberResult.alreadyInGroup.message, remainingGroupSlots: remainingGroupSlots, remainingPlanSeats: nil)
        }

        guard let maxMemberCount = group.maxMemberCount else {
            return GroupInviteAvailability(canInvite: true, message: nil, remainingGroupSlots: remainingGroupSlots, remainingPlanSeats: nil)
        }

        let remainingInGroup = max(0, maxMemberCount - group.occupiedMemberCount)
        if remainingInGroup <= 0 {
            return GroupInviteAvailability(canInvite: false, message: AddPendingMemberResult.groupFull.message, remainingGroupSlots: 0, remainingPlanSeats: nil)
        }

        let planLimit = TrialManager.shared.subscriptionMemberLimit
            ?? TrialManager.shared.subscriptionPlanMemberLimit
            ?? maxMemberCount
        let activePlanRoster = subscriptionPlanRosterMembers(including: group).filter { !$0.hasLeft }
        let remainingPlanSeats = max(0, planLimit - activePlanRoster.count)

        if let proposedMember,
           activePlanRoster.contains(where: { !$0.isCurrentUser && memberMatches($0, proposedMember) }) {
            return GroupInviteAvailability(
                canInvite: false,
                message: AddPendingMemberResult.alreadyInSubscriptionPlan.message,
                remainingGroupSlots: remainingInGroup,
                remainingPlanSeats: remainingPlanSeats
            )
        }

        if remainingPlanSeats <= 0 {
            return GroupInviteAvailability(
                canInvite: false,
                message: AddPendingMemberResult.subscriptionPlanFull.message,
                remainingGroupSlots: remainingInGroup,
                remainingPlanSeats: 0
            )
        }

        return GroupInviteAvailability(
            canInvite: true,
            message: "\(remainingInGroup) group \(remainingInGroup == 1 ? "seat" : "seats") open · \(remainingPlanSeats) plan \(remainingPlanSeats == 1 ? "seat" : "seats") open",
            remainingGroupSlots: remainingInGroup,
            remainingPlanSeats: remainingPlanSeats
        )
    }
    
    private func deduplicateMembersByPhone(_ members: [GroupMember]) -> [GroupMember] {
        var uniqueMembers: [GroupMember] = []
        var seenPhones = Set<String>()
        
        for member in members {
            guard let phone = member.phoneNumber, !phone.isEmpty else {
                uniqueMembers.append(member)
                continue
            }
            
            let normalizedPhone = normalizePhoneNumber(phone)
            
            if !seenPhones.contains(normalizedPhone) {
                seenPhones.insert(normalizedPhone)
                uniqueMembers.append(member)
            }
        }
        
        return uniqueMembers
    }
    
    func syncCurrentUserPaymentInfo(from profile: Profile) {
        guard var group = activeGroup,
              let index = group.members.firstIndex(where: { $0.isCurrentUser }) else {
            return
        }
        
        let currentMember = group.members[index]
        
        let venmoUsername = profile.venmoUsername?
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespaces)
        
        let zelleContact = profile.zelleContactInfo?.trimmingCharacters(in: .whitespaces)
        let displayName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // ✅ CRITICAL: Only update if something actually changed
        var needsUpdate = false

        if !displayName.isEmpty, currentMember.profileName != displayName {
            group.members[index].profileName = displayName
            group.members[index].name = displayName
            needsUpdate = true
        }

        if group.members[index].localDisplayName != nil || group.members[index].localImageData != nil {
            group.members[index].localDisplayName = nil
            group.members[index].localImageData = nil
            needsUpdate = true
        }

        if let avatar = profile.avatarImage, currentMember.imageData != avatar {
            group.members[index].imageData = avatar
            needsUpdate = true
        }
        
        if let v = venmoUsername, !v.isEmpty, currentMember.venmoUsername != v {
            group.members[index].venmoUsername = v
            needsUpdate = true
        }
        
        if let link = profile.venmoPaymentLink, !link.isEmpty, currentMember.venmoLink != link {
            group.members[index].venmoLink = link
            needsUpdate = true
        }
        
        if let zc = zelleContact, !zc.isEmpty, currentMember.zelleEmail != zc {
            group.members[index].zelleEmail = zc
            needsUpdate = true
        }
        
        if let link = profile.zellePaymentLink, !link.isEmpty, currentMember.zelleLink != link {
            group.members[index].zelleLink = link
            needsUpdate = true
        }
        
        if !needsUpdate {
            print("✅ Payment info already synced - no update needed")
            return
        }
        
        print("🔄 Updating current user payment info")
        activeGroup = group
        
        if let allIndex = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[allIndex] = group
        }
        
        save()
        
        // ✅ ONLY write to Firebase if something changed
        updateMemberInFirebase(group.members[index], groupID: group.id)
        
        objectWillChange.send()
    }
    
    @discardableResult
    func addPendingMember(_ member: GroupMember, to groupID: UUID) -> AddPendingMemberResult {
        guard member.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .missingPhone
        }
        guard let index = allGroups.firstIndex(where: { $0.id == groupID }) else { return .groupNotFound }
        var group = allGroups[index]
        
        let normalizedPhone = member.phoneNumber.map(normalizePhoneNumber)
        let existingMemberIndex = group.members.firstIndex { existingMember in
            if existingMember.id == member.id { return true }
            guard let normalizedPhone,
                  let existingPhone = existingMember.phoneNumber,
                  !existingPhone.isEmpty else { return false }
            return normalizePhoneNumber(existingPhone) == normalizedPhone
        }

        if let existingMemberIndex {
            guard !group.members[existingMemberIndex].isCurrentUser else {
                print("🚫 Current user already exists in group")
                return .alreadyInGroup
            }

            if !group.members[existingMemberIndex].hasLeft {
                print("🚫 Member already exists in group")
                return .alreadyInGroup
            }

            let availability = inviteAvailability(for: groupID, proposedMember: member)
            guard availability.canInvite else {
                print("🚫 \(availability.message ?? "Invite blocked")")
                if availability.message == AddPendingMemberResult.alreadyInSubscriptionPlan.message {
                    return .alreadyInSubscriptionPlan
                }
                if availability.message == AddPendingMemberResult.subscriptionPlanFull.message {
                    return .subscriptionPlanFull
                }
                return .groupFull
            }

            group.members[existingMemberIndex].isCurrentUser = false
            group.members[existingMemberIndex].isPending = true
            group.members[existingMemberIndex].joinedAt = nil
            group.members[existingMemberIndex].hasLeft = false
            group.members[existingMemberIndex].subscriptionSourceGroupID = groupID
            if group.members[existingMemberIndex].phoneNumber?.isEmpty != false {
                group.members[existingMemberIndex].phoneNumber = member.phoneNumber
            }
            if group.members[existingMemberIndex].localDisplayName?.isEmpty != false {
                group.members[existingMemberIndex].localDisplayName = member.localDisplayName
            }
            if group.members[existingMemberIndex].localImageData == nil {
                group.members[existingMemberIndex].localImageData = member.localImageData
            }

            allGroups[index] = group
            if activeGroup?.id == groupID {
                activeGroup = group
            }
            save()
            addMemberToFirebase(group.members[existingMemberIndex], groupID: groupID)
            observeMemberPaymentProfiles(for: group)
            objectWillChange.send()
            print("✅ Re-synced pending invited member: \(group.members[existingMemberIndex].name)")
            if group.maxMemberCount != nil {
                TrialManager.shared.syncPendingSubscriptionInviteMembers([group.members[existingMemberIndex]], groupID: groupID, sourceGroupID: groupID)
            }
            return .updatedExisting
        }

        let availability = inviteAvailability(for: groupID, proposedMember: member)
        guard availability.canInvite else {
            print("🚫 \(availability.message ?? "Invite blocked")")
            if availability.message == AddPendingMemberResult.alreadyInSubscriptionPlan.message {
                return .alreadyInSubscriptionPlan
            }
            if availability.message == AddPendingMemberResult.subscriptionPlanFull.message {
                return .subscriptionPlanFull
            }
            return .groupFull
        }
        
        var invitedMember = member
        invitedMember.isPending = true
        invitedMember.isCurrentUser = false
        invitedMember.joinedAt = nil
        invitedMember.subscriptionSourceGroupID = groupID
        group.members.append(invitedMember)
        allGroups[index] = group
        
        if activeGroup?.id == groupID {
            activeGroup = group
        }
        
        save()
        
        // Add to Firebase immediately so splits, balances, and payment setup can sync before the person opens Dutch.
        addMemberToFirebase(invitedMember, groupID: groupID)
        observeMemberPaymentProfiles(for: group)
        
        objectWillChange.send()
        
        print("✅ Added pending invited member: \(member.name)")
        if group.maxMemberCount != nil {
            TrialManager.shared.syncPendingSubscriptionInviteMembers([invitedMember], groupID: groupID, sourceGroupID: groupID)
        }
        return .added
    }
    
    @discardableResult
    func activateMember(
        phoneNumber: String,
        in groupID: UUID,
        currentUserProfile: Profile,
        notifyInviteAcceptance: Bool = false
    ) -> Bool {
        guard let groupIndex = allGroups.firstIndex(where: { $0.id == groupID }) else {
            print("❌ Group not found: \(groupID)")
            return false
        }
        var group = allGroups[groupIndex]
        
        let normalizedPhone = normalizePhoneNumber(phoneNumber)
        let matchingPendingIndex = group.members.firstIndex(where: { member in
            guard member.isPending, let memberPhone = member.phoneNumber else { return false }
            return normalizePhoneNumber(memberPhone) == normalizedPhone
        })
        let pendingSeatIndex = matchingPendingIndex
        let existingActiveIndex = group.members.firstIndex(where: { member in
            guard !member.isPending, !member.hasLeft, let memberPhone = member.phoneNumber else { return false }
            return normalizePhoneNumber(memberPhone) == normalizedPhone
        })
        let alreadyActiveMemberExists = existingActiveIndex != nil

        if let maxMemberCount = group.maxMemberCount {
            let sharedInviteLimit = maxMemberCount
            if group.activeMemberCount >= sharedInviteLimit && !alreadyActiveMemberExists {
                print("❌ Subscription invite reached shared member limit for group: \(group.name)")
                return false
            }
            let occupiedMemberCount = group.members.filter { !$0.hasLeft }.count
            if occupiedMemberCount >= sharedInviteLimit && pendingSeatIndex == nil && !alreadyActiveMemberExists {
                print("❌ Subscription invite reached shared member limit for group: \(group.name)")
                return false
            }
        }

        if group.isInviteFull && pendingSeatIndex == nil && !alreadyActiveMemberExists {
            print("❌ Invite is full for group: \(group.name)")
            return false
        }

        let venmo = currentUserProfile.venmoUsername?
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespaces)
        let zelle = currentUserProfile.zelleContactInfo?.trimmingCharacters(in: .whitespaces)
        
        if pendingSeatIndex == nil, let memberIndex = existingActiveIndex {
            print("✅ Found existing active member by phone at index \(memberIndex); syncing verified profile")

            let displayName = currentUserProfile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            group.members[memberIndex].isPending = false
            group.members[memberIndex].hasLeft = false
            group.members[memberIndex].leftAt = nil
            group.members[memberIndex].phoneNumber = normalizedPhone
            group.members[memberIndex].isCurrentUser = true
            group.members[memberIndex].localDisplayName = nil
            group.members[memberIndex].localImageData = nil
            if group.members[memberIndex].joinedAt == nil {
                group.members[memberIndex].joinedAt = Date()
            }
            if !displayName.isEmpty {
                group.members[memberIndex].profileName = displayName
            }

            if let v = venmo, !v.isEmpty {
                group.members[memberIndex].venmoUsername = v
            }
            if let link = currentUserProfile.venmoPaymentLink, !link.isEmpty {
                group.members[memberIndex].venmoLink = link
            }
            if let z = zelle, !z.isEmpty {
                group.members[memberIndex].zelleEmail = z
            }
            if let link = currentUserProfile.zellePaymentLink, !link.isEmpty {
                group.members[memberIndex].zelleLink = link
            }
            if let imageData = currentUserProfile.avatarImage {
                group.members[memberIndex].imageData = imageData
            }

            allGroups[groupIndex] = group
            if activeGroup?.id == groupID {
                activeGroup = group
            }

            save()
            updateMemberInFirebase(group.members[memberIndex], groupID: groupID)
            objectWillChange.send()
            return true
        }

        if let memberIndex = pendingSeatIndex {
            print("✅ Found pending member at index \(memberIndex)")
            let wasPendingInvite = group.members[memberIndex].isPending && !group.members[memberIndex].hasLeft
            
            let displayName = currentUserProfile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            group.members[memberIndex].isPending = false
            group.members[memberIndex].phoneNumber = normalizedPhone
            group.members[memberIndex].isCurrentUser = true
            group.members[memberIndex].localDisplayName = nil
            group.members[memberIndex].localImageData = nil
            group.members[memberIndex].joinedAt = Date()
            if !displayName.isEmpty {
                group.members[memberIndex].profileName = displayName
            }
            
            if let v = venmo, !v.isEmpty {
                group.members[memberIndex].venmoUsername = v
            }
            if let link = currentUserProfile.venmoPaymentLink, !link.isEmpty {
                group.members[memberIndex].venmoLink = link
            }
            if let z = zelle, !z.isEmpty {
                group.members[memberIndex].zelleEmail = z
            }
            if let link = currentUserProfile.zellePaymentLink, !link.isEmpty {
                group.members[memberIndex].zelleLink = link
            }
            if let imageData = currentUserProfile.avatarImage {
                group.members[memberIndex].imageData = imageData
            }
            
            allGroups[groupIndex] = group
            
            if activeGroup?.id == groupID {
                activeGroup = group
            }
            
            save()
            
            // Update Firebase
            updateMemberInFirebase(group.members[memberIndex], groupID: groupID)
            
            objectWillChange.send()
            
            let memberName = group.members[memberIndex].name
            let groupName = group.name
            let totalMembers = group.maxMemberCount ?? group.members.count
            let isLastMember = group.isInviteFull || group.pendingMemberCount == 0

            if notifyInviteAcceptance && wasPendingInvite {
                NotificationCenter.default.post(
                    name: .showGroupJoinBanner,
                    object: nil,
                    userInfo: [
                        "memberName": memberName,
                        "groupName": groupName,
                        "isLastMember": isLastMember
                    ]
                )
                NotificationManager.shared.notifyGroupMemberJoined(
                    groupID: groupID,
                    groupName: groupName,
                    memberName: memberName,
                    isLastMember: isLastMember,
                    totalMembers: totalMembers,
                    activeMembers: group.activeMemberCount
                )
                ActivityStore.write(
                    groupID: groupID.uuidString,
                    groupName: groupName,
                    type: .memberJoined,
                    actorName: memberName,
                    detail: isLastMember ? "Everyone's in — ready to split" : "Joined the group"
                )
            }
            return true
        } else if !group.members.contains(where: { member in
            guard let memberPhone = member.phoneNumber else { return false }
            return normalizePhoneNumber(memberPhone) == normalizedPhone
        }) {
            var newMember = GroupMember(
                name: currentUserProfile.name.isEmpty ? "Member" : currentUserProfile.name,
                phoneNumber: normalizedPhone,
                imageData: currentUserProfile.avatarImage,
                isCurrentUser: true,
                isPending: false,
                profileName: currentUserProfile.name.isEmpty ? nil : currentUserProfile.name,
                venmoUsername: venmo,
                venmoLink: currentUserProfile.venmoPaymentLink,
                zelleEmail: zelle,
                zelleLink: currentUserProfile.zellePaymentLink,
                joinedAt: Date()
            )
            if newMember.name.trimmingCharacters(in: .whitespaces).isEmpty {
                newMember.name = "Member"
            }

            group.members.append(newMember)
            allGroups[groupIndex] = group

            if activeGroup?.id == groupID {
                activeGroup = group
            }

            save()
            addMemberToFirebase(newMember, groupID: groupID)
            objectWillChange.send()

            return true
        } else {
            print("✅ Member already exists in group")
            return true
        }
    }
    
    func toggleExpensePaidStatus(groupID: UUID, expenseID: UUID, memberID: UUID? = nil) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to update this payment.") else {
            return
        }

        let expenseRef = ref.child("groups").child(groupID.uuidString)
            .child("expenses").child(expenseID.uuidString)
        
        // Check current settled state
        expenseRef.child("settled").observeSingleEvent(of: .value) { snapshot in
            let currentSettled = snapshot.value as? Bool ?? false
            
            print("🔄 Toggling expense \(expenseID): \(currentSettled) → \(!currentSettled)")
            self.setExpensesSettledStatus(
                groupID: groupID,
                expenseIDs: [expenseID],
                isSettled: !currentSettled
            )
        }
    }

    @discardableResult
    func createSubscriptionInviteGroup(planName: String, maxMemberCount: Int, profile: Profile, currentPerson: Person?, existingMembers: [GroupMember] = []) -> DutchieGroup {
        let authorizedMaxMemberCount = max(2, min(maxMemberCount, 8))
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to create a subscription group.") else {
            let fallbackMember = GroupMember(
                id: currentPerson?.id ?? UUID(),
                name: currentPerson?.name ?? profile.name,
                phoneNumber: currentPerson?.phoneNumber ?? profile.zelleContactInfo,
                imageData: currentPerson?.contactImage ?? profile.avatarImage,
                isCurrentUser: true,
                isPending: false
            )
            return DutchieGroup(
                name: "\(planName) Share",
                members: [fallbackMember],
                createdByID: fallbackMember.id,
                createdAt: Date(),
                maxMemberCount: authorizedMaxMemberCount,
                isSubscriptionInviteStaging: true
            )
        }

        let phone = currentPerson?.phoneNumber ?? profile.zelleContactInfo
        let memberName = currentPerson?.name.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? currentPerson?.name ?? profile.name
            : (profile.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Me" : profile.name)
        let currentMember = GroupMember(
            id: currentPerson?.id ?? UUID(),
            name: memberName,
            phoneNumber: phone,
            imageData: currentPerson?.contactImage ?? profile.avatarImage,
            isCurrentUser: true,
            isPending: false,
            venmoUsername: profile.venmoUsername?.replacingOccurrences(of: "@", with: ""),
            venmoLink: profile.venmoPaymentLink,
            zelleEmail: profile.zelleContactInfo,
            zelleLink: profile.zellePaymentLink,
            joinedAt: Date()
        )
        let groupID = UUID()
        var members = [currentMember]
        for member in existingMembers {
            guard !member.isCurrentUser, !member.hasLeft else { continue }
            if phoneNumberExists(in: members, phone: member.phoneNumber) { continue }
            var pendingMember = member
            pendingMember.isCurrentUser = false
            pendingMember.isPending = true
            pendingMember.joinedAt = nil
            pendingMember.subscriptionSourceGroupID = groupID
            members.append(pendingMember)
        }
        members = deduplicateMembersByPhone(members)
        members.sort { lhs, rhs in
            if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
            if lhs.isPending != rhs.isPending { return !lhs.isPending }
            return lhs.name < rhs.name
        }
        if members.count > authorizedMaxMemberCount {
            members = Array(members.prefix(authorizedMaxMemberCount))
        }

        let group = DutchieGroup(
            id: groupID,
            name: "\(planName) Share",
            members: members,
            createdByID: members.first(where: { $0.isCurrentUser })?.id ?? currentMember.id,
            createdAt: Date(),
            maxMemberCount: authorizedMaxMemberCount,
            isSubscriptionInviteStaging: true
        )

        if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[index] = group
        } else {
            allGroups.append(group)
        }

        save()
        createGroupInFirebase(group)
        observeGroup(groupID: group.id) { [weak self] updatedGroup in
            self?.handleGroupUpdate(updatedGroup)
        }
        objectWillChange.send()
        return group
    }

    @discardableResult
    func updateSubscriptionGroupPlan(groupID: UUID, maxMemberCount: Int, profile: Profile, currentPerson: Person?, existingMembers: [GroupMember] = []) -> DutchieGroup? {
        let authorizedMaxMemberCount = max(2, min(maxMemberCount, 8))
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to update your subscription group.") else {
            return nil
        }

        guard let index = allGroups.firstIndex(where: { $0.id == groupID }) else { return nil }

        let phone = currentPerson?.phoneNumber ?? profile.zelleContactInfo
        let memberName = currentPerson?.name.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? currentPerson?.name ?? profile.name
            : (profile.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Me" : profile.name)
        let currentMember = GroupMember(
            id: currentPerson?.id ?? allGroups[index].members.first(where: { $0.isCurrentUser })?.id ?? UUID(),
            name: memberName,
            phoneNumber: phone,
            imageData: currentPerson?.contactImage ?? profile.avatarImage,
            isCurrentUser: true,
            isPending: false,
            venmoUsername: profile.venmoUsername?.replacingOccurrences(of: "@", with: ""),
            venmoLink: profile.venmoPaymentLink,
            zelleEmail: profile.zelleContactInfo,
            zelleLink: profile.zellePaymentLink,
            joinedAt: Date()
        )

        var group = allGroups[index]
        // Plan updates should preserve this group's own membership only.
        // Passing members from another subscription/group must not implicitly add
        // those people to this group.
        var members = group.members.filter { !$0.hasLeft }
        if members.isEmpty {
            members = [currentMember]
        } else if let currentIndex = members.firstIndex(where: { $0.isCurrentUser }) {
            members[currentIndex] = currentMember
        } else {
            members.insert(currentMember, at: 0)
        }

        members = deduplicateMembersByPhone(members)
        members.sort { lhs, rhs in
            if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
            if lhs.isPending != rhs.isPending { return !lhs.isPending }
            return lhs.name < rhs.name
        }
        if members.count > authorizedMaxMemberCount {
            members = Array(members.prefix(authorizedMaxMemberCount))
        }

        group.maxMemberCount = authorizedMaxMemberCount
        group.members = members
        allGroups[index] = group
        if activeGroup?.id == groupID {
            activeGroup = group
        }
        save()

        let groupRef = ref.child("groups").child(group.id.uuidString)
        groupRef.updateChildValues([
            "maxMemberCount": authorizedMaxMemberCount
        ])
        for member in members {
            updateMemberInFirebase(member, groupID: group.id)
        }
        objectWillChange.send()
        return group
    }

    @discardableResult
    func finalizeSubscriptionInviteGroup(groupID: UUID, name: String) -> DutchieGroup? {
        guard AuthManager.shared.canUseGroupMode else {
            print("🚫 Group mode requires a verified phone number")
            return nil
        }

        guard let index = allGroups.firstIndex(where: { $0.id == groupID }) else {
            return nil
        }

        var group = allGroups[index]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        group.name = trimmedName.isEmpty ? "Dutch Group" : trimmedName
        group.isSubscriptionInviteStaging = false
        group.members = group.members.map { member in
            var updated = member
            if updated.isCurrentUser && !updated.hasLeft {
                updated.isPending = false
                if updated.joinedAt == nil {
                    updated.joinedAt = Date()
                }
            }
            return updated
        }

        allGroups[index] = group
        activeGroup = group
        isGroupModeEnabled = true
        save()

        let groupRef = ref.child("groups").child(group.id.uuidString)
        groupRef.updateChildValues([
            "name": group.name,
            "isSubscriptionInviteStaging": false
        ])

        for member in group.members {
            updateMemberInFirebase(member, groupID: group.id)
        }

        observeGroup(groupID: group.id) { [weak self] updatedGroup in
            self?.handleGroupUpdate(updatedGroup)
        }
        objectWillChange.send()
        return group
    }

    func removeMemberFromSubscriptionInvite(groupID: UUID, memberID: UUID) {
        removePendingInvitedMember(groupID: groupID, memberID: memberID)
    }

    func removePendingInvitedMember(groupID: UUID, memberID: UUID) {
        guard let index = allGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var group = allGroups[index]
        guard let memberIndex = group.members.firstIndex(where: { $0.id == memberID }),
              !group.members[memberIndex].isCurrentUser,
              group.members[memberIndex].isPending else {
            return
        }

        let removedMember = group.members.remove(at: memberIndex)
        let removedID = removedMember.id

        for expenseIndex in group.expenses.indices {
            group.expenses[expenseIndex].splitAmongIDs.removeAll { $0 == removedID }
            if var shares = group.expenseShares[group.expenses[expenseIndex].id] {
                shares.removeAll { $0.memberID == removedID }
                group.expenseShares[group.expenses[expenseIndex].id] = shares
            }
        }

        allGroups[index] = group
        if activeGroup?.id == groupID {
            activeGroup = group
        }
        save()

        let groupRef = ref.child("groups").child(groupID.uuidString)
        groupRef.child("members").child(memberID.uuidString).removeValue()
        for expense in group.expenses {
            let expenseRef = groupRef.child("expenses").child(expense.id.uuidString)
            expenseRef.child("splitAmongIDs").setValue(expense.splitAmongIDs.map(\.uuidString))
            expenseRef.child("shares").child(memberID.uuidString).removeValue()
        }

        if group.maxMemberCount != nil {
            TrialManager.shared.removePendingSubscriptionInviteMember(removedMember, groupID: groupID)
        }

        ActivityStore.write(
            groupID: groupID.uuidString,
            groupName: group.name,
            type: .memberLeft,
            actorName: removedMember.name,
            detail: "\(removedMember.name) was removed from the invite"
        )

        objectWillChange.send()
    }

    @discardableResult
    func renameSubscriptionGroup(groupID: UUID, name: String) -> DutchieGroup? {
        guard let index = allGroups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return allGroups[index] }

        var group = allGroups[index]
        group.name = trimmedName
        allGroups[index] = group
        if activeGroup?.id == groupID {
            activeGroup = group
        }
        save()

        ref.child("groups").child(groupID.uuidString).child("name").setValue(trimmedName)
        objectWillChange.send()
        return group
    }

    @discardableResult
    func enforceSubscriptionMemberLimit(for groupID: UUID) -> DutchieGroup? {
        guard let index = allGroups.firstIndex(where: { $0.id == groupID }) else { return nil }
        var group = allGroups[index]
        guard let maxMemberCount = group.maxMemberCount else { return group }

        let activeMembers = group.members.filter { !$0.hasLeft }.sorted { lhs, rhs in
            if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
            if lhs.isPending != rhs.isPending { return !lhs.isPending }
            return lhs.name < rhs.name
        }

        guard activeMembers.count > maxMemberCount else { return group }

        let keepIDs = Set(activeMembers.prefix(maxMemberCount).map(\.id))
        var removedMembers: [GroupMember] = []
        let leftAt = Date()

        for memberIndex in group.members.indices.reversed() where !group.members[memberIndex].hasLeft && !keepIDs.contains(group.members[memberIndex].id) {
            if group.isSubscriptionInviteStaging {
                removedMembers.append(group.members.remove(at: memberIndex))
            } else {
                group.members[memberIndex].hasLeft = true
                group.members[memberIndex].leftAt = leftAt
                removedMembers.append(group.members[memberIndex])
            }
        }

        allGroups[index] = group
        if activeGroup?.id == groupID {
            activeGroup = group
        }
        save()

        for member in removedMembers {
            if group.isSubscriptionInviteStaging {
                ref.child("groups")
                    .child(groupID.uuidString)
                    .child("members")
                    .child(member.id.uuidString)
                    .removeValue()
            } else {
                updateMemberInFirebase(member, groupID: groupID)
            }
        }

        objectWillChange.send()
        return group
    }

    func setExpensesSettledStatus(
        groupID: UUID,
        expenseIDs: [UUID],
        isSettled: Bool,
        completion: ((Error?) -> Void)? = nil
    ) {
        let uniqueExpenseIDs = Array(Set(expenseIDs))
        guard !uniqueExpenseIDs.isEmpty else {
            completion?(nil)
            return
        }

        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to sync settled status.") else {
            let error = NSError(
                domain: "Dutch.GroupSettlement",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Turn on Wi-Fi or cellular data to sync settled status."]
            )
            completion?(error)
            return
        }

        guard var group = activeGroup?.id == groupID
                ? activeGroup
                : allGroups.first(where: { $0.id == groupID }) else {
            let error = NSError(
                domain: "Dutch.GroupSettlement",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Group not found."]
            )
            completion?(error)
            return
        }

        let paidDate = ISO8601DateFormatter().string(from: Date())
        let idSet = Set(uniqueExpenseIDs)
        var locallyMatchedIDs = Set<UUID>()
        var updates: [String: Any] = [:]
        let groupPath = "groups/\(groupID.uuidString)"

        for index in group.expenses.indices where idSet.contains(group.expenses[index].id) {
            let expense = group.expenses[index]
            locallyMatchedIDs.insert(expense.id)
            group.expenses[index].settled = isSettled
            updates["\(groupPath)/expenses/\(expense.id.uuidString)/settled"] = isSettled

            let existingShares = group.expenseShares[expense.id] ?? localShares(for: expense, in: group)
            let updatedShares = existingShares.map { share in
                var updatedShare = share
                updatedShare.status = isSettled ? .paid : .pending
                updatedShare.paidDate = isSettled ? Date() : nil
                return updatedShare
            }
            group.expenseShares[expense.id] = updatedShares

            for share in updatedShares where share.memberID != expense.addedByID {
                let sharePath = "\(groupPath)/expenses/\(expense.id.uuidString)/shares/\(share.memberID.uuidString)"
                updates["\(sharePath)/status"] = share.status.rawValue
                updates["\(sharePath)/paidDate"] = isSettled ? paidDate : NSNull()
            }
        }

        for expenseID in uniqueExpenseIDs where !locallyMatchedIDs.contains(expenseID) {
            updates["\(groupPath)/expenses/\(expenseID.uuidString)/settled"] = isSettled
        }

        if activeGroup?.id == group.id {
            activeGroup = group
        }
        if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[index] = group
        }

        save()
        updateBadgeCount()
        objectWillChange.send()

        ref.updateChildValues(updates) { [weak self] error, _ in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Failed to batch set settled status: \(error.localizedDescription)")
                    completion?(error)
                    return
                }

                print("✅ Batch set \(uniqueExpenseIDs.count) expense(s) settled to \(isSettled)")
                self?.updateBadgeCount()
                self?.objectWillChange.send()
                completion?(nil)
            }
        }
    }

    private func applyLocalSettledState(groupID: UUID, expenseIDs: [UUID], isSettled: Bool) {
        let idSet = Set(expenseIDs)

        func update(_ group: inout DutchieGroup) {
            for index in group.expenses.indices where idSet.contains(group.expenses[index].id) {
                let expenseID = group.expenses[index].id
                group.expenses[index].settled = isSettled

                if var shares = group.expenseShares[expenseID] {
                    for shareIndex in shares.indices {
                        shares[shareIndex].status = isSettled ? .paid : .pending
                        shares[shareIndex].paidDate = isSettled ? Date() : nil
                    }
                    group.expenseShares[expenseID] = shares
                }
            }
        }

        if var group = activeGroup, group.id == groupID {
            update(&group)
            activeGroup = group
        }

        if let index = allGroups.firstIndex(where: { $0.id == groupID }) {
            var group = allGroups[index]
            update(&group)
            allGroups[index] = group
        }

        save()
        updateBadgeCount()
        objectWillChange.send()
    }

    func setAllGroupExpensesSettledStatus(
        groupID: UUID,
        isSettled: Bool,
        completion: (([UUID], Error?) -> Void)? = nil
    ) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to sync settled status.") else {
            let error = NSError(
                domain: "Dutch.GroupSettlement",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Turn on Wi-Fi or cellular data to sync settled status."]
            )
            completion?([], error)
            return
        }

        let groupPath = "groups/\(groupID.uuidString)"
        let expensesRef = ref.child("groups").child(groupID.uuidString).child("expenses")
        expensesRef.observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self else { return }

            let paidDate = ISO8601DateFormatter().string(from: Date())
            var changedExpenseIDs: [UUID] = []
            var updates: [String: Any] = [:]

            for child in snapshot.children {
                guard let expenseSnapshot = child as? DataSnapshot,
                      let dict = expenseSnapshot.value as? [String: Any] else { continue }

                let idString = (dict["id"] as? String) ?? expenseSnapshot.key
                guard let expenseID = UUID(uuidString: idString) else { continue }

                let isArchived = (dict["isArchived"] as? Bool) ?? false
                let currentlySettled = (dict["settled"] as? Bool) ?? false
                guard !isArchived, currentlySettled != isSettled else { continue }

                changedExpenseIDs.append(expenseID)
                updates["\(groupPath)/expenses/\(expenseID.uuidString)/settled"] = isSettled

                if let shares = dict["shares"] as? [String: Any] {
                    for (shareKey, value) in shares {
                        let memberID = ((value as? [String: Any])?["memberID"] as? String) ?? shareKey
                        updates["\(groupPath)/expenses/\(expenseID.uuidString)/shares/\(memberID)/status"] = isSettled ? ExpenseShare.ShareStatus.paid.rawValue : ExpenseShare.ShareStatus.pending.rawValue
                        updates["\(groupPath)/expenses/\(expenseID.uuidString)/shares/\(memberID)/paidDate"] = isSettled ? paidDate : NSNull()
                    }
                }
            }

            guard !changedExpenseIDs.isEmpty else {
                completion?([], nil)
                return
            }

            self.applyLocalSettledState(groupID: groupID, expenseIDs: changedExpenseIDs, isSettled: isSettled)

            self.ref.updateChildValues(updates) { error, _ in
                DispatchQueue.main.async {
                    if let error {
                        print("❌ Failed to settle all group expenses: \(error.localizedDescription)")
                        completion?(changedExpenseIDs, error)
                        return
                    }

                    print("✅ Firebase-backed settle all updated \(changedExpenseIDs.count) expense(s) to \(isSettled)")
                    self.updateBadgeCount()
                    self.objectWillChange.send()
                    completion?(changedExpenseIDs, nil)
                }
            }
        }
    }

    func setUploadSessionSettledStatus(
        groupID: UUID,
        uploadSessionID: UUID,
        isSettled: Bool,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to sync settled status.") else {
            let error = NSError(
                domain: "Dutch.GroupSettlement",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Turn on Wi-Fi or cellular data to sync settled status."]
            )
            completion?(error)
            return
        }

        let groupPath = "groups/\(groupID.uuidString)"
        let expensesRef = ref.child("groups").child(groupID.uuidString).child("expenses")
        expensesRef.observeSingleEvent(of: .value) { [weak self] snapshot in
            guard let self else { return }

            let paidDate = ISO8601DateFormatter().string(from: Date())
            var changedExpenseIDs: [UUID] = []
            var updates: [String: Any] = [:]

            for child in snapshot.children {
                guard let expenseSnapshot = child as? DataSnapshot,
                      let dict = expenseSnapshot.value as? [String: Any] else { continue }

                let idString = (dict["id"] as? String) ?? expenseSnapshot.key
                guard let expenseID = UUID(uuidString: idString) else { continue }

                let sourceUploadSessionID = (dict["sourceUploadSessionID"] as? String).flatMap(UUID.init(uuidString:))
                let isArchived = (dict["isArchived"] as? Bool) ?? false
                let currentlySettled = (dict["settled"] as? Bool) ?? false
                guard sourceUploadSessionID == uploadSessionID,
                      !isArchived,
                      currentlySettled != isSettled else { continue }

                changedExpenseIDs.append(expenseID)
                updates["\(groupPath)/expenses/\(expenseID.uuidString)/settled"] = isSettled

                if let shares = dict["shares"] as? [String: Any] {
                    for (shareKey, value) in shares {
                        let memberID = ((value as? [String: Any])?["memberID"] as? String) ?? shareKey
                        updates["\(groupPath)/expenses/\(expenseID.uuidString)/shares/\(memberID)/status"] = isSettled ? ExpenseShare.ShareStatus.paid.rawValue : ExpenseShare.ShareStatus.pending.rawValue
                        updates["\(groupPath)/expenses/\(expenseID.uuidString)/shares/\(memberID)/paidDate"] = isSettled ? paidDate : NSNull()
                    }
                }
            }

            guard !changedExpenseIDs.isEmpty else {
                completion?(nil)
                return
            }

            self.applyLocalSettledState(groupID: groupID, expenseIDs: changedExpenseIDs, isSettled: isSettled)

            self.ref.updateChildValues(updates) { error, _ in
                DispatchQueue.main.async {
                    if let error {
                        print("❌ Failed to settle upload session: \(error.localizedDescription)")
                        completion?(error)
                        return
                    }

                    print("✅ Settled \(changedExpenseIDs.count) upload-session expense(s) to \(isSettled)")
                    self.updateBadgeCount()
                    self.objectWillChange.send()
                    completion?(nil)
                }
            }
        }
    }

    func setExpenseSettledStatus(groupID: UUID, expenseID: UUID, isSettled: Bool) {
        setExpensesSettledStatus(
            groupID: groupID,
            expenseIDs: [expenseID],
            isSettled: isSettled
        )
    }

    private func syncShareStatusesForExpense(groupID: UUID, expenseID: UUID, isSettled: Bool) {
        let group = activeGroup?.id == groupID
            ? activeGroup
            : allGroups.first(where: { $0.id == groupID })
        guard let expense = group?.expenses.first(where: { $0.id == expenseID }) else { return }

        let sharesRef = ref.child("groups").child(groupID.uuidString)
            .child("expenses").child(expenseID.uuidString)
            .child("shares")

        for memberID in expense.splitAmongIDs where memberID != expense.addedByID {
            let shareRef = sharesRef.child(memberID.uuidString)
            shareRef.updateChildValues([
                "status": isSettled ? ExpenseShare.ShareStatus.paid.rawValue : ExpenseShare.ShareStatus.pending.rawValue
            ])

            if isSettled {
                shareRef.child("paidDate").setValue(ISO8601DateFormatter().string(from: Date()))
            } else {
                shareRef.child("paidDate").removeValue()
            }
        }
    }
     

    
    
    
    // Add this method to start observing when app launches
    func startObservingActiveGroup() {
        guard NetworkStatusMonitor.shared.isOnline else { return }
        guard let group = activeGroup else { return }
        guard groupObserverHandles[group.id] == nil else { return }
        
        observeGroup(groupID: group.id) { [weak self] updatedGroup in
            self?.handleGroupUpdate(updatedGroup)
        }
    }

    func startObservingAvailableGroups() {
        guard NetworkStatusMonitor.shared.isOnline else { return }

        let activeGroups = activeGroup.map { [$0] } ?? []
        let groups = uniqueGroupsByID(
            currentUserAvailableGroups +
            currentUserSubscriptionInviteGroups +
            activeGroups
        )
        let groupIDs = Set(groups.map(\.id))

        for groupID in groupIDs where groupObserverHandles[groupID] == nil {
            observeGroup(groupID: groupID) { [weak self] updatedGroup in
                self?.handleGroupUpdate(updatedGroup)
            }
        }

        for observedID in Array(groupObserverHandles.keys) where !groupIDs.contains(observedID) {
            stopObservingGroup(groupID: observedID)
        }
    }
    
    func markSettlementPaid(from: Person, to: Person, amount: Double) {
        guard var group = activeGroup,
              let idx = allGroups.firstIndex(where: { $0.id == group.id }),
              let fromMember = group.members.first(where: { $0.name == from.name }),
              let toMember = group.members.first(where: { $0.name == to.name }) else { return }
        
        var settlement = Settlement(
            fromMemberID: fromMember.id,
            toMemberID: toMember.id,
            amount: amount,
            markedDate: Date()
        )
        settlement.isConfirmed = true
        settlement.confirmedDate = Date()
        
        group.settlements.append(settlement)
        allGroups[idx] = group
        activeGroup = group
        
        save()
        objectWillChange.send()
    }
    
    func getGroup(by id: UUID) -> DutchieGroup? {
        allGroups.first(where: { $0.id == id })
    }

    func discardUnjoinedInviteGroup(groupID: UUID) {
        guard let group = getGroup(by: groupID),
              !isCurrentUserActiveMember(of: group) else { return }
        forceDiscardInviteGroup(groupID: groupID)
    }

    func forceDiscardInviteGroup(groupID: UUID) {
        stopObservingGroup(groupID: groupID)
        allGroups.removeAll { $0.id == groupID }

        if activeGroup?.id == groupID {
            activeGroup = nil
            isGroupModeEnabled = false
        }
        if inviteAccessGroupID == groupID {
            inviteAccessGroupID = nil
        }

        save()
        objectWillChange.send()
    }
    
    func startListeningForExpenseUpdates(groupID: UUID) {
        // Already handled by observeGroup
    }
    
    func updateBadgeCount() {
        guard let group = activeGroup,
              let currentUser = group.members.first(where: { $0.isCurrentUser }) else {
            UIApplication.shared.applicationIconBadgeNumber = 0
            return
        }
        
        var unpaidCount = 0
        
        for (expenseID, shares) in group.expenseShares {
            guard let expense = group.expenses.first(where: { $0.id == expenseID }),
                  !expense.isArchived else { continue }
            
            if let myShare = shares.first(where: { $0.memberID == currentUser.id }),
               myShare.status == .pending,
               expense.addedByID != currentUser.id {
                unpaidCount += 1
            }
        }
        
        UIApplication.shared.applicationIconBadgeNumber = unpaidCount
    }
    
    // ✅ CRITICAL FIX: Stop infinite duplicate loop
    private func handleGroupUpdate(_ updatedGroup: DutchieGroup) {
        var group = updatedGroup
        
        // Mark current user
        markCurrentUserInGroup(&group, authenticatedPhone: AuthManager.shared.phoneNumber)

        if group.maxMemberCount != nil {
            let removedWrongSource = removeMembersWithWrongSubscriptionSource(from: &group)
            if removedWrongSource {
                print("🧹 Removed pending members that belonged to another subscription group")
            }
        }

        // ✅ ONLY deduplicate in memory. Subscription invite backfill below is the
        // one exception because Review/Settle Share read group members, not the
        // subscription member list directly.
        let deduplicatedMembers = deduplicateMembersByPhone(group.members)
        
        if deduplicatedMembers.count != group.members.count {
            print("🔍 Found \(group.members.count - deduplicatedMembers.count) duplicates in local state - cleaning in memory only")
        }
        
        if group.maxMemberCount != nil {
            group.members = deduplicatedMembers
            hydrateSubscriptionMembersFromFirebase(for: group.id)
        } else {
            group.members = deduplicatedMembers
            mergeSubscriptionPlanMembersIntoGroup(&group, syncFirebase: false)
        }
        
        // Update local state
        if let index = allGroups.firstIndex(where: { $0.id == group.id }) {
            allGroups[index] = group
        } else {
            allGroups.append(group)
        }
        
        if activeGroup?.id == group.id {
            activeGroup = group
        }
        
        save()
        objectWillChange.send()
        
        // ✅ DO NOT CALL updateMemberInFirebase for every observer update here.
    }

    @discardableResult
    private func removeMembersWithWrongSubscriptionSource(from group: inout DutchieGroup) -> Bool {
        var removedMembers: [GroupMember] = []
        group.members.removeAll { member in
            guard member.isPending,
                  !member.isCurrentUser,
                  !member.hasLeft,
                  let sourceGroupID = member.subscriptionSourceGroupID,
                  sourceGroupID != group.id else { return false }
            removedMembers.append(member)
            return true
        }

        guard !removedMembers.isEmpty else { return false }

        for member in removedMembers {
            ref.child("groups")
                .child(group.id.uuidString)
                .child("members")
                .child(member.id.uuidString)
                .removeValue()
        }
        return true
    }
}
// MARK: - Pending Group Invite
struct PendingGroupInvite: Identifiable {
    let id = UUID()
    let groupID: UUID
    let groupName: String
    let inviterName: String
    let phoneNumber: String
}

// MARK: - Deep Link Handler
class DeepLinkHandler {
    @Published var showPaymentLanding = false
    @Published var landingFromName = ""
    @Published var landingToName = ""
    @Published var landingAmount = 0.0
    @Published var landingReceiptId = UUID()
    @Published var pendingReceiptId: UUID? = nil

    static let shared = DeepLinkHandler()
    
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "dutch" || url.scheme == "dutchie" else { return }
        let components = url.pathComponents
        
        if components.count >= 3 && components[1] == "receipt",
           let id = UUID(uuidString: components[2]) {
            pendingReceiptId = id
            HapticManager.notification(type: .success)
            return
        }
        
        if components.count >= 2 && components[1] == "pay",
           let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            let from    = queryItems.first(where: { $0.name == "from" })?.value ?? ""
            let to      = queryItems.first(where: { $0.name == "to" })?.value ?? ""
            let amount  = Double(queryItems.first(where: { $0.name == "amount" })?.value ?? "0") ?? 0
            let receipt = queryItems.first(where: { $0.name == "receipt" })?.value ?? ""
            landingFromName  = from
            landingToName    = to
            landingAmount    = amount
            landingReceiptId = UUID(uuidString: receipt) ?? UUID()
            HapticManager.notification(type: .success)
            showPaymentLanding = true
        }
    }
    
    func stopListeningForExpenseUpdates(groupID: UUID) {
        FirebaseDatabase.Database.database().reference()
            .child("groups").child(groupID.uuidString).child("expenses")
            .removeAllObservers()
    }
}
