import Foundation

struct BalanceItem: Identifiable, Codable, Equatable {
    enum ItemType: String, Codable {
        case owe
        case receive
    }

    enum Status: String, Codable {
        case unpaid
        case requested
        case settled
        case archived
    }

    var id: String
    var type: ItemType
    var amount: Double
    var personName: String
    var personPhone: String?
    var personVenmo: String?
    var personVenmoLink: String?
    var personZelleContact: String?
    var personZelleLink: String?
    var receiptId: String?
    var receiptTitle: String?
    var groupId: String?
    var groupName: String?
    var status: Status
    var createdAt: String
    var updatedAt: String?
    var lastReminderAt: String?
    var sourceDate: String?
    var relatedExpenseIds: [String]

    var isActive: Bool {
        status == .unpaid || status == .requested
    }

    var receiptUUID: UUID? {
        guard let receiptId else { return nil }
        return UUID(uuidString: receiptId)
    }

    var formattedAmount: String {
        String(format: "$%.2f", amount)
    }

    var primaryText: String {
        switch type {
        case .owe:
            return "You owe \(personName) \(formattedAmount)"
        case .receive:
            return "\(personName) owes you \(formattedAmount)"
        }
    }

    var secondaryText: String {
        var parts: [String] = []
        if let groupName, !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(groupName)
            if let receiptTitle, !receiptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(receiptTitle)
            }
        } else if let receiptTitle, !receiptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(receiptTitle)
        } else {
            parts.append("Quick Split")
        }
        if let sourceDate, !sourceDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(sourceDate)
        }
        return parts.joined(separator: " · ")
    }
}
