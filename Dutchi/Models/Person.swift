import Foundation
import SwiftUI

struct Person: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var contactImage: Data?
    var phoneNumber: String?  // Added for contact detection
    var isCurrentUser: Bool
    var dutchUID: String?
    var venmoUsername: String?
    var venmoLink: String?
    var zelleContact: String?
    var zelleLink: String?
    var isPendingGroupMember: Bool?
    
    init(
        id: UUID = UUID(),
        name: String,
        contactImage: Data? = nil,
        phoneNumber: String? = nil,
        isCurrentUser: Bool = false,
        dutchUID: String? = nil,
        venmoUsername: String? = nil,
        venmoLink: String? = nil,
        zelleContact: String? = nil,
        zelleLink: String? = nil,
        isPendingGroupMember: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.contactImage = contactImage
        self.phoneNumber = phoneNumber
        self.isCurrentUser = isCurrentUser
        self.dutchUID = dutchUID
        self.venmoUsername = venmoUsername
        self.venmoLink = venmoLink
        self.zelleContact = zelleContact
        self.zelleLink = zelleLink
        self.isPendingGroupMember = isPendingGroupMember
    }

    var isDutchMember: Bool {
        !(dutchUID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasPaymentMethods: Bool {
        hasValue(venmoUsername) || hasValue(venmoLink) || hasValue(zelleContact) || hasValue(zelleLink)
    }

    private func hasValue(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    
    var initials: String {
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else if let first = components.first {
            return String(first.prefix(1)).uppercased()
        }
        return "?"
    }
}
