import Foundation
import SwiftUI

// MARK: - Transaction Model

enum TransactionSourceDocumentType: String, Codable {
    case receipt
    case statement
    case manual
}

struct Transaction: Identifiable, Codable {
    let id: UUID
    var amount: Double
    var merchant: String
    var paidBy: Person
    var splitWith: [Person]
    var receiptImage: Data?
    var includeInSplit: Bool
    var isManual: Bool
    var backgroundResultToken: String?
    var lineItems: [ReceiptLineItem]
    var receiptDate: String?
    var currency: String
    var splitQuantities: [UUID: Int]
    var isBreakdownChild: Bool
    var sourceDocumentType: TransactionSourceDocumentType

    init(
        amount: Double,
        merchant: String,
        paidBy: Person,
        splitWith: [Person],
        receiptImage: Data? = nil,
        includeInSplit: Bool = true,
        isManual: Bool = false,
        backgroundResultToken: String? = nil,
        lineItems: [ReceiptLineItem] = [],
        receiptDate: String? = nil,
        currency: String = "USD",
        splitQuantities: [UUID: Int] = [:],
        isBreakdownChild: Bool = false,
        sourceDocumentType: TransactionSourceDocumentType = .receipt
    ) {
        self.id                    = UUID()
        self.amount                = amount
        self.merchant              = merchant
        self.paidBy                = paidBy
        self.splitWith             = splitWith
        self.receiptImage          = receiptImage
        self.includeInSplit        = includeInSplit
        self.isManual              = isManual
        self.backgroundResultToken = backgroundResultToken
        self.lineItems             = lineItems
        self.receiptDate           = receiptDate
        self.currency              = currency
        self.splitQuantities       = splitQuantities
        self.isBreakdownChild      = isBreakdownChild
        self.sourceDocumentType    = isManual ? .manual : sourceDocumentType
    }

    // MARK: - Computed

    var formattedAmount: String {
        String(format: "$%.2f", amount)
    }

    /// Equal per-person share — used when no custom split is active.
    var perPersonAmount: Double {
        guard !splitWith.isEmpty else { return amount }
        return amount / Double(splitWith.count)
    }

    /// Weighted share owed by a specific person.
    /// Falls back to equal split if no splitQuantities are set.
    func weightedAmount(for person: Person) -> Double {
        guard !splitQuantities.isEmpty else { return perPersonAmount }
        let totalUnits = splitWith.reduce(0) { $0 + (splitQuantities[$1.id] ?? 1) }
        guard totalUnits > 0 else { return perPersonAmount }
        let myUnits = splitQuantities[person.id] ?? 1
        return amount * (Double(myUnits) / Double(totalUnits))
    }

    /// True when any person has a multiplier greater than 1.
    var hasCustomSplit: Bool {
        !splitQuantities.isEmpty && splitQuantities.values.contains { $0 > 1 }
    }

    // MARK: - Codable
    //
    // Swift CANNOT auto-synthesize Codable for [UUID: Int] because
    // UUID is not a String-keyed dictionary key in JSON.
    // We manually encode it as [String: Int] (UUID → lowercased string)
    // and decode back with UUID(uuidString:).

    enum CodingKeys: String, CodingKey {
        case id, amount, merchant, paidBy, splitWith, receiptImage
        case includeInSplit, isManual, backgroundResultToken
        case lineItems, receiptDate, currency, splitQuantities, isBreakdownChild
        case sourceDocumentType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                    = try c.decode(UUID.self,             forKey: .id)
        amount                = try c.decode(Double.self,           forKey: .amount)
        merchant              = try c.decode(String.self,           forKey: .merchant)
        paidBy                = try c.decode(Person.self,           forKey: .paidBy)
        splitWith             = try c.decode([Person].self,         forKey: .splitWith)
        receiptImage          = try c.decodeIfPresent(Data.self,    forKey: .receiptImage)
        includeInSplit        = try c.decode(Bool.self,             forKey: .includeInSplit)
        isManual              = try c.decode(Bool.self,             forKey: .isManual)
        backgroundResultToken = try c.decodeIfPresent(String.self,  forKey: .backgroundResultToken)
        lineItems             = try c.decode([ReceiptLineItem].self, forKey: .lineItems)
        receiptDate           = try c.decodeIfPresent(String.self,  forKey: .receiptDate)
        currency              = try c.decode(String.self,           forKey: .currency)
        isBreakdownChild      = try c.decodeIfPresent(Bool.self,    forKey: .isBreakdownChild) ?? false
        sourceDocumentType    = try c.decodeIfPresent(TransactionSourceDocumentType.self, forKey: .sourceDocumentType)
            ?? (isManual ? .manual : .receipt)

        // Decode [String: Int] → [UUID: Int], silently dropping malformed keys
        let raw = try c.decodeIfPresent([String: Int].self, forKey: .splitQuantities) ?? [:]
        splitQuantities = Dictionary(uniqueKeysWithValues:
            raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } }
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                           forKey: .id)
        try c.encode(amount,                       forKey: .amount)
        try c.encode(merchant,                     forKey: .merchant)
        try c.encode(paidBy,                       forKey: .paidBy)
        try c.encode(splitWith,                    forKey: .splitWith)
        try c.encodeIfPresent(receiptImage,        forKey: .receiptImage)
        try c.encode(includeInSplit,               forKey: .includeInSplit)
        try c.encode(isManual,                     forKey: .isManual)
        try c.encodeIfPresent(backgroundResultToken, forKey: .backgroundResultToken)
        try c.encode(lineItems,                    forKey: .lineItems)
        try c.encodeIfPresent(receiptDate,         forKey: .receiptDate)
        try c.encode(currency,                     forKey: .currency)
        try c.encode(isBreakdownChild,             forKey: .isBreakdownChild)
        try c.encode(sourceDocumentType,           forKey: .sourceDocumentType)

        // Encode [UUID: Int] → [String: Int]
        let stringKeyed = Dictionary(uniqueKeysWithValues:
            splitQuantities.map { ($0.key.uuidString, $0.value) }
        )
        try c.encode(stringKeyed, forKey: .splitQuantities)
    }
}
