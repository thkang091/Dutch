import Foundation
import FirebaseDatabase
import Combine


struct TransactionSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let merchant: String
    let amount: Double
    let splitCount: Int
    let assignmentLabel: String?
    
    init(
        id: UUID = UUID(),
        merchant: String,
        amount: Double,
        splitCount: Int,
        assignmentLabel: String? = nil
    ) {
        self.id = id
        self.merchant = merchant
        self.amount = amount
        self.splitCount = splitCount
        self.assignmentLabel = assignmentLabel
    }
}

struct ReceiptData: Codable, Identifiable {
    let id: UUID
    var settlements: [SettlementSnapshot]
    var transactions: [TransactionSnapshot]
    var totalAmount: Double
    var participantCount: Int
    let createdDate: Date
    var groupID: UUID?
    var createdByID: UUID?
    var lastModified: Date
    var expiresAt: Date
    
    init(
        id: UUID = UUID(),
        settlements: [SettlementSnapshot],
        transactions: [TransactionSnapshot],
        totalAmount: Double,
        participantCount: Int,
        createdDate: Date = Date(),
        groupID: UUID? = nil,
        createdByID: UUID? = nil
    ) {
        self.id = id
        self.settlements = settlements
        self.transactions = transactions
        self.totalAmount = totalAmount
        self.participantCount = participantCount
        self.createdDate = createdDate
        self.groupID = groupID
        self.createdByID = createdByID
        self.lastModified = Date()
        self.expiresAt = Calendar.current.date(byAdding: .day, value: 5, to: Date()) ?? Date()
    }
}

// MARK: - Firebase Receipt Manager

class ReceiptManager: ObservableObject {
    static let shared = ReceiptManager()
    
    private let ref = Database.database().reference()
    private var receiptObservers: [UUID: DatabaseHandle] = [:]
    
    @Published var activeReceipt: ReceiptData?
    
    // ✅ Track current session's receipt ID
    private var currentSessionReceiptID: UUID?
    
    // ✅ Track if we're currently updating to prevent observer recursion
    private var isUpdating: Set<UUID> = []
    
    private init() {
        scheduleExpiredReceiptCleanup()
    }
    
    // MARK: - Non-Group Mode (Local Draft → Firebase Snapshot)
    
    /// ✅ UPDATED: Replace existing receipt if one exists from this session
    func createOrUpdateLocalReceipt(
        settlements: [PaymentLink],
        transactions: [Transaction],
        participantCount: Int
    ) -> ReceiptData {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to create a shareable receipt.") else {
            return ReceiptData(
                settlements: [],
                transactions: [],
                totalAmount: 0,
                participantCount: participantCount
            )
        }

        let activeSettlements = settlements.filter { $0.amount > 0.01 }
        
        let settlementSnapshots = activeSettlements.map {
            SettlementSnapshot(
                id: $0.id,
                fromName: $0.from.name,
                toName: $0.to.name,
                amount: $0.amount
            )
        }
        
        let transactionSnapshots = transactions.map { transaction in
            TransactionSnapshot(
                id: transaction.id,
                merchant: transaction.merchant,
                amount: transaction.amount,
                splitCount: transaction.splitWith.count,
                assignmentLabel: Self.assignmentLabel(
                    splitWith: transaction.splitWith,
                    participantCount: participantCount
                )
            )
        }
        
        let totalAmount = transactions.reduce(0.0) { $0 + $1.amount }
        
        // ✅ DELETE OLD RECEIPT if one exists from this session
        if let oldReceiptID = currentSessionReceiptID {
            print("🗑️ Deleting old receipt from session: \(oldReceiptID)")
            deleteReceipt(receiptID: oldReceiptID)
        }
        
        // ✅ CREATE NEW RECEIPT
        let receipt = ReceiptData(
            settlements: settlementSnapshots,
            transactions: transactionSnapshots,
            totalAmount: totalAmount,
            participantCount: participantCount
        )
        
        // ✅ SAVE TO FIREBASE
        saveReceiptToFirebase(receipt)
        
        // ✅ TRACK THIS RECEIPT FOR THE SESSION
        currentSessionReceiptID = receipt.id
        
        print("✅ Created/updated local receipt: \(receipt.id)")
        return receipt
    }
    
    /// ✅ NEW: Reset session when user starts fresh
    func resetSession() {
        currentSessionReceiptID = nil
        print("🔄 Receipt session reset")
    }
    
    
    func updateGroupReceiptTransactions(
        receiptID: UUID,
        updatedTransactions: [Transaction],
        updatedSettlements: [PaymentLink]
    ) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to sync this receipt.") else {
            return
        }

        // ✅ PREVENT RECURSIVE UPDATES
        guard !isUpdating.contains(receiptID) else {
            print("⚠️ Already updating receipt \(receiptID), skipping duplicate update")
            return
        }
        
        isUpdating.insert(receiptID)
        print("🔄 Updating group receipt \(receiptID) with \(updatedTransactions.count) total transactions")
        
        // ✅ ONLY INCLUDE UNPAID TRANSACTIONS
        let participantCount = max(Set(updatedTransactions.flatMap { $0.splitWith.map(\.id) }).count, 1)
        let transactionSnapshots = updatedTransactions.map { transaction in
            TransactionSnapshot(
                id: transaction.id,
                merchant: transaction.merchant,
                amount: transaction.amount,
                splitCount: transaction.splitWith.count,
                assignmentLabel: Self.assignmentLabel(
                    splitWith: transaction.splitWith,
                    participantCount: participantCount
                )
            )
        }
        
        print("   📋 \(transactionSnapshots.count) transactions included in receipt")
        
        let settlementSnapshots = updatedSettlements.filter { $0.amount > 0.01 }.map {
            SettlementSnapshot(
                id: $0.id,
                fromName: $0.from.name,
                toName: $0.to.name,
                amount: $0.amount
            )
        }
        
        let totalAmount = updatedTransactions.reduce(0.0) { $0 + $1.amount }
        
        // ✅ FIX: Stop observing during update to prevent recursion
        let wasObserving = receiptObservers[receiptID] != nil
        if wasObserving {
            stopObservingReceipt(receiptID: receiptID)
        }
        
        let receiptRef = ref.child("receipts").child(receiptID.uuidString)
        
        // ✅ Use a dispatch group to ensure proper sequencing
        let group = DispatchGroup()
        
        // Clear transactions first
        group.enter()
        let transactionsRef = receiptRef.child("transactions")
        transactionsRef.removeValue { error, _ in
            if let error = error {
                print("❌ Failed to clear old transactions: \(error.localizedDescription)")
            }
            group.leave()
        }
        
        // Clear settlements
        group.enter()
        let settlementsRef = receiptRef.child("settlements")
        settlementsRef.removeValue { error, _ in
            if let error = error {
                print("❌ Failed to clear old settlements: \(error.localizedDescription)")
            }
            group.leave()
        }
        
        // After clearing, write new data
        group.notify(queue: .main) {
            // Write new transactions
            self.saveTransactions(transactionSnapshots, receiptID: receiptID)
            
            // Write new settlements
            self.saveSettlements(settlementSnapshots, receiptID: receiptID)
            
            // Update metadata
            receiptRef.updateChildValues([
                "totalAmount": totalAmount,
                "lastModified": ISO8601DateFormatter().string(from: Date())
            ])
            
            print("✅ Updated group receipt with \(transactionSnapshots.count) transactions")
            
            // ✅ Resume observing after update completes
            if wasObserving {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.observeGroupReceipt(receiptID: receiptID)
                }
            }
            
            // ✅ Clear updating flag
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.isUpdating.remove(receiptID)
            }
        }
    }
    
    // MARK: - Group Mode (Single Shared Receipt) - ASYNC VERSION
    func getOrCreateGroupReceipt(
        groupID: UUID,
        createdByID: UUID,
        initialSettlements: [PaymentLink],
        initialTransactions: [Transaction],
        participantCount: Int,
        completion: @escaping (ReceiptData) -> Void
    ) {
        let activeSettlements = initialSettlements.filter { $0.amount > 0.01 }
        let settlementSnapshots = activeSettlements.map {
            SettlementSnapshot(
                id: $0.id,
                fromName: $0.from.name,
                toName: $0.to.name,
                amount: $0.amount
            )
        }
        let transactionSnapshots = initialTransactions.map { transaction in
            TransactionSnapshot(
                id: transaction.id,
                merchant: transaction.merchant,
                amount: transaction.amount,
                splitCount: transaction.splitWith.count,
                assignmentLabel: Self.assignmentLabel(
                    splitWith: transaction.splitWith,
                    participantCount: participantCount
                )
            )
        }
        
        getOrCreateGroupReceiptFromSnapshots(
            groupID: groupID,
            createdByID: createdByID,
            settlementSnapshots: settlementSnapshots,
            transactionSnapshots: transactionSnapshots,
            participantCount: participantCount,
            completion: completion
        )
    }

    func getOrCreateGroupReceiptFromSnapshots(
        groupID: UUID,
        createdByID: UUID,
        settlementSnapshots: [SettlementSnapshot],
        transactionSnapshots: [TransactionSnapshot],
        participantCount: Int,
        completion: @escaping (ReceiptData) -> Void
    ) {
        print("🔍 Checking for existing group receipt for: \(groupID)")
        print("   Initial transactions: \(transactionSnapshots.count)")

        // Check for existing receipt asynchronously
        fetchActiveGroupReceiptAsync(groupID: groupID) { existingReceipt in
            if let existing = existingReceipt {
                print("✅ Found existing group receipt: \(existing.id)")

                let totalAmount = transactionSnapshots.reduce(0.0) { $0 + $1.amount }
                
                // Update Firebase receipt
                self.updateGroupReceiptTransactions(
                    receiptID: existing.id,
                    transactionSnapshots: transactionSnapshots,
                    settlementSnapshots: settlementSnapshots,
                    totalAmount: totalAmount
                )
                
                // Return updated receipt
                DispatchQueue.main.async {
                    var updated = existing
                    updated.transactions = transactionSnapshots
                    updated.settlements = settlementSnapshots
                    updated.totalAmount = totalAmount
                    completion(updated)
                }
                return
            }
            
            print("📝 Creating NEW group receipt for group: \(groupID)")

            let totalAmount = transactionSnapshots.reduce(0.0) { $0 + $1.amount }
            
            let receipt = ReceiptData(
                settlements: settlementSnapshots,
                transactions: transactionSnapshots,
                totalAmount: totalAmount,
                participantCount: participantCount,
                groupID: groupID,
                createdByID: createdByID
            )
            
            self.saveReceiptToFirebase(receipt)
            
            DispatchQueue.main.async {
                completion(receipt)
            }
        }
    }

    // Add this helper function:
    private func updateGroupReceiptTransactions(
        receiptID: UUID,
        transactionSnapshots: [TransactionSnapshot],
        settlementSnapshots: [SettlementSnapshot],
        totalAmount: Double
    ) {
        // ✅ PREVENT RECURSIVE UPDATES
        guard !isUpdating.contains(receiptID) else {
            print("⚠️ Already updating receipt \(receiptID), skipping duplicate update")
            return
        }
        
        isUpdating.insert(receiptID)
        print("🔄 Updating receipt \(receiptID): \(transactionSnapshots.count) transactions, total: $\(totalAmount)")
        
        // ✅ Stop observing during update
        let wasObserving = receiptObservers[receiptID] != nil
        if wasObserving {
            stopObservingReceipt(receiptID: receiptID)
        }
        
        let receiptRef = ref.child("receipts").child(receiptID.uuidString)
        
        let group = DispatchGroup()
        
        // Clear and replace transactions
        group.enter()
        let transactionsRef = receiptRef.child("transactions")
        transactionsRef.removeValue { error, _ in
            if error == nil {
                self.saveTransactions(transactionSnapshots, receiptID: receiptID)
            }
            group.leave()
        }
        
        // Clear and replace settlements
        group.enter()
        let settlementsRef = receiptRef.child("settlements")
        settlementsRef.removeValue { error, _ in
            if error == nil {
                self.saveSettlements(settlementSnapshots, receiptID: receiptID)
            }
            group.leave()
        }
        
        // Update metadata after clearing/writing completes
        group.notify(queue: .main) {
            receiptRef.updateChildValues([
                "totalAmount": totalAmount,
                "lastModified": ISO8601DateFormatter().string(from: Date())
            ])
            
            // ✅ Resume observing after update completes
            if wasObserving {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.observeGroupReceipt(receiptID: receiptID)
                }
            }
            
            // ✅ Clear updating flag
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.isUpdating.remove(receiptID)
            }
        }
    }
    
    // MARK: - Firebase Operations
    
    private func saveReceiptToFirebase(_ receipt: ReceiptData) {
        let receiptRef = ref.child("receipts").child(receipt.id.uuidString)
        
        let receiptData: [String: Any] = [
            "id": receipt.id.uuidString,
            "totalAmount": receipt.totalAmount,
            "participantCount": receipt.participantCount,
            "createdDate": ISO8601DateFormatter().string(from: receipt.createdDate),
            "lastModified": ISO8601DateFormatter().string(from: receipt.lastModified),
            "expiresAt": ISO8601DateFormatter().string(from: receipt.expiresAt),
            "groupID": receipt.groupID?.uuidString ?? NSNull(),
            "createdByID": receipt.createdByID?.uuidString ?? NSNull()
        ]
        
        receiptRef.setValue(receiptData) { error, _ in
            if let error = error {
                print("❌ Failed to save receipt: \(error.localizedDescription)")
            } else {
                print("✅ Saved receipt to Firebase: \(receipt.id)")
            }
        }
        
        saveSettlements(receipt.settlements, receiptID: receipt.id)
        saveTransactions(receipt.transactions, receiptID: receipt.id)
    }
    
    private func saveSettlements(_ settlements: [SettlementSnapshot], receiptID: UUID) {
        let settlementsRef = ref.child("receipts").child(receiptID.uuidString).child("settlements")
        
        for settlement in settlements {
            let settlementData: [String: Any] = [
                "id": settlement.id.uuidString,
                "fromName": settlement.fromName,
                "toName": settlement.toName,
                "amount": settlement.amount
            ]
            
            settlementsRef.child(settlement.id.uuidString).setValue(settlementData)
        }
    }
    
    private func saveTransactions(_ transactions: [TransactionSnapshot], receiptID: UUID) {
        let transactionsRef = ref.child("receipts").child(receiptID.uuidString).child("transactions")
        
        for transaction in transactions {
            let transactionData: [String: Any] = [
                "id": transaction.id.uuidString,
                "merchant": transaction.merchant,
                "amount": transaction.amount,
                "splitCount": transaction.splitCount,
                "assignmentLabel": transaction.assignmentLabel ?? NSNull()
            ]
            
            transactionsRef.child(transaction.id.uuidString).setValue(transactionData)
        }
    }
    
    // MARK: - Real-time Updates
    
    func observeGroupReceipt(receiptID: UUID) {
        guard receiptObservers[receiptID] == nil else {
            print("⚠️ Already observing receipt: \(receiptID)")
            return
        }
        
        let receiptRef = ref.child("receipts").child(receiptID.uuidString)
        
        let handle = receiptRef.observe(.value) { [weak self] snapshot in
            // ✅ Only handle updates if we're not currently updating
            guard let self = self, !self.isUpdating.contains(receiptID) else {
                return
            }
            self.handleReceiptUpdate(snapshot: snapshot)
        }
        
        receiptObservers[receiptID] = handle
        print("✅ Started observing receipt: \(receiptID)")
    }
    
    private func handleReceiptUpdate(snapshot: DataSnapshot) {
        buildReceipt(from: snapshot) { [weak self] receipt in
            guard let self = self, let receipt = receipt else { return }

            DispatchQueue.main.async {
                self.activeReceipt = receipt
                self.objectWillChange.send()
            }
        }
    }

    func fetchReceiptOnce(receiptID: UUID, completion: @escaping (ReceiptData?) -> Void) {
        ref.child("receipts").child(receiptID.uuidString).observeSingleEvent(of: .value) { [weak self] snapshot in
            self?.buildReceipt(from: snapshot, completion: completion)
        }
    }

    private func buildReceipt(from snapshot: DataSnapshot, completion: @escaping (ReceiptData?) -> Void) {
        guard let dict = snapshot.value as? [String: Any],
              let idStr = dict["id"] as? String,
              let receiptID = UUID(uuidString: idStr) else {
            completion(nil)
            return
        }
        
        let totalAmount = dict["totalAmount"] as? Double ?? 0
        let participantCount = dict["participantCount"] as? Int ?? 0
        
        var createdDate = Date()
        if let createdDateStr = dict["createdDate"] as? String {
            createdDate = ISO8601DateFormatter().date(from: createdDateStr) ?? Date()
        }
        
        var expiresAt = Calendar.current.date(byAdding: .day, value: 5, to: Date()) ?? Date()
        if let expiresAtStr = dict["expiresAt"] as? String {
            expiresAt = ISO8601DateFormatter().date(from: expiresAtStr) ?? expiresAt
        }
        
        var groupID: UUID?
        if let groupIDStr = dict["groupID"] as? String {
            groupID = UUID(uuidString: groupIDStr)
        }
        
        var createdByID: UUID?
        if let createdByIDStr = dict["createdByID"] as? String {
            createdByID = UUID(uuidString: createdByIDStr)
        }
        
        fetchSettlements(receiptID: receiptID) { settlements in
            self.fetchTransactions(receiptID: receiptID) { transactions in
                var receipt = ReceiptData(
                    id: receiptID,
                    settlements: settlements,
                    transactions: transactions,
                    totalAmount: totalAmount,
                    participantCount: participantCount,
                    createdDate: createdDate,
                    groupID: groupID,
                    createdByID: createdByID
                )
                receipt.expiresAt = expiresAt
                completion(receipt)
            }
        }
    }
    
    private func fetchSettlements(receiptID: UUID, completion: @escaping ([SettlementSnapshot]) -> Void) {
        let settlementsRef = ref.child("receipts").child(receiptID.uuidString).child("settlements")
        
        settlementsRef.observeSingleEvent(of: .value) { snapshot in
            var settlements: [SettlementSnapshot] = []
            
            for child in snapshot.children {
                guard let childSnapshot = child as? DataSnapshot,
                      let dict = childSnapshot.value as? [String: Any],
                      let idStr = dict["id"] as? String,
                      let id = UUID(uuidString: idStr),
                      let fromName = dict["fromName"] as? String,
                      let toName = dict["toName"] as? String,
                      let amount = dict["amount"] as? Double else {
                    continue
                }
                
                settlements.append(SettlementSnapshot(
                    id: id,
                    fromName: fromName,
                    toName: toName,
                    amount: amount
                ))
            }
            
            completion(settlements)
        }
    }
    
    private func fetchTransactions(receiptID: UUID, completion: @escaping ([TransactionSnapshot]) -> Void) {
        let transactionsRef = ref.child("receipts").child(receiptID.uuidString).child("transactions")
        
        transactionsRef.observeSingleEvent(of: .value) { snapshot in
            var transactions: [TransactionSnapshot] = []
            
            for child in snapshot.children {
                guard let childSnapshot = child as? DataSnapshot,
                      let dict = childSnapshot.value as? [String: Any],
                      let idStr = dict["id"] as? String,
                      let id = UUID(uuidString: idStr),
                      let merchant = dict["merchant"] as? String,
                      let amount = dict["amount"] as? Double,
                      let splitCount = dict["splitCount"] as? Int else {
                    continue
                }
                let assignmentLabel = dict["assignmentLabel"] as? String
                
                transactions.append(TransactionSnapshot(
                    id: id,
                    merchant: merchant,
                    amount: amount,
                    splitCount: splitCount,
                    assignmentLabel: assignmentLabel
                ))
            }
            
            completion(transactions)
        }
    }
    
    func stopObservingReceipt(receiptID: UUID) {
        guard let handle = receiptObservers[receiptID] else { return }
        
        ref.child("receipts").child(receiptID.uuidString).removeObserver(withHandle: handle)
        receiptObservers.removeValue(forKey: receiptID)
        
        print("✅ Stopped observing receipt: \(receiptID)")
    }
    
    // MARK: - Event-Based Updates
    
    func addTransaction(_ transaction: TransactionSnapshot, to receiptID: UUID) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to update this receipt.") else {
            return
        }

        let transactionRef = ref.child("receipts").child(receiptID.uuidString)
            .child("transactions").child(transaction.id.uuidString)
        
        let transactionData: [String: Any] = [
            "id": transaction.id.uuidString,
            "merchant": transaction.merchant,
            "amount": transaction.amount,
            "splitCount": transaction.splitCount,
            "assignmentLabel": transaction.assignmentLabel ?? NSNull()
        ]
        
        transactionRef.setValue(transactionData) { error, _ in
            if let error = error {
                print("❌ Failed to add transaction: \(error.localizedDescription)")
            } else {
                print("✅ Added transaction: \(transaction.merchant)")
                self.updateReceiptTotals(receiptID: receiptID)
            }
        }
    }
    
    func removeTransaction(transactionID: UUID, from receiptID: UUID) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to update this receipt.") else {
            return
        }

        let transactionRef = ref.child("receipts").child(receiptID.uuidString)
            .child("transactions").child(transactionID.uuidString)
        
        transactionRef.removeValue { error, _ in
            if let error = error {
                print("❌ Failed to remove transaction: \(error.localizedDescription)")
            } else {
                print("✅ Removed transaction")
                self.updateReceiptTotals(receiptID: receiptID)
            }
        }
    }
    
    func updateSettlement(_ settlement: SettlementSnapshot, in receiptID: UUID) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to update this settlement.") else {
            return
        }

        let settlementRef = ref.child("receipts").child(receiptID.uuidString)
            .child("settlements").child(settlement.id.uuidString)
        
        let settlementData: [String: Any] = [
            "id": settlement.id.uuidString,
            "fromName": settlement.fromName,
            "toName": settlement.toName,
            "amount": settlement.amount
        ]
        
        settlementRef.setValue(settlementData) { error, _ in
            if let error = error {
                print("❌ Failed to update settlement: \(error.localizedDescription)")
            } else {
                print("✅ Updated settlement")
            }
        }
    }
    
    private func updateReceiptTotals(receiptID: UUID) {
        fetchTransactions(receiptID: receiptID) { transactions in
            let totalAmount = transactions.reduce(0.0) { $0 + $1.amount }
            
            let receiptRef = self.ref.child("receipts").child(receiptID.uuidString)
            receiptRef.updateChildValues([
                "totalAmount": totalAmount,
                "lastModified": ISO8601DateFormatter().string(from: Date())
            ])
        }
    }
    
    // MARK: - Fetch Active Group Receipt - ASYNC VERSION
    
    /// ✅ FIXED: Now properly asynchronous - no blocking semaphore
    private func fetchActiveGroupReceiptAsync(groupID: UUID, completion: @escaping (ReceiptData?) -> Void) {
        let receiptsRef = ref.child("receipts")
        
        receiptsRef.queryOrdered(byChild: "groupID")
            .queryEqual(toValue: groupID.uuidString)
            .observeSingleEvent(of: .value) { snapshot in
                guard snapshot.exists(),
                      let children = snapshot.children.allObjects as? [DataSnapshot],
                      let firstChild = children.first,
                      let dict = firstChild.value as? [String: Any],
                      let idStr = dict["id"] as? String,
                      let receiptID = UUID(uuidString: idStr) else {
                    print("❌ No existing receipt found for group: \(groupID)")
                    completion(nil)
                    return
                }
                
                if let expiresAtStr = dict["expiresAt"] as? String,
                   let expiresAt = ISO8601DateFormatter().date(from: expiresAtStr),
                   expiresAt < Date() {
                    print("⚠️ Receipt \(receiptID) was past its old expiry; keeping it available for group history.")
                    self.extendReceiptAvailability(receiptID: receiptID)
                }
                
                let totalAmount = dict["totalAmount"] as? Double ?? 0
                let participantCount = dict["participantCount"] as? Int ?? 0
                
                var createdDate = Date()
                if let createdDateStr = dict["createdDate"] as? String {
                    createdDate = ISO8601DateFormatter().date(from: createdDateStr) ?? Date()
                }
                
                var createdByID: UUID?
                if let createdByIDStr = dict["createdByID"] as? String {
                    createdByID = UUID(uuidString: createdByIDStr)
                }
                
                // Fetch settlements
                self.fetchSettlements(receiptID: receiptID) { settlements in
                    // Fetch transactions
                    self.fetchTransactions(receiptID: receiptID) { transactions in
                        let receipt = ReceiptData(
                            id: receiptID,
                            settlements: settlements,
                            transactions: transactions,
                            totalAmount: totalAmount,
                            participantCount: participantCount,
                            createdDate: createdDate,
                            groupID: groupID,
                            createdByID: createdByID
                        )
                        
                        print("✅ Successfully fetched existing receipt: \(receiptID)")
                        completion(receipt)
                    }
                }
            }
    }
    
    // MARK: - Cleanup
    
    func deleteReceipt(receiptID: UUID) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to delete this receipt.") else {
            return
        }

        ref.child("receipts").child(receiptID.uuidString).removeValue { error, _ in
            if let error = error {
                print("❌ Failed to delete receipt: \(error.localizedDescription)")
            } else {
                print("✅ Deleted receipt: \(receiptID)")
            }
        }
        
        stopObservingReceipt(receiptID: receiptID)
    }
    
    private func scheduleExpiredReceiptCleanup() {
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            self.cleanupExpiredReceipts()
        }
    }
    
    private func cleanupExpiredReceipts() {
        let receiptsRef = ref.child("receipts")
        
        receiptsRef.observeSingleEvent(of: .value) { snapshot in
            for child in snapshot.children {
                guard let childSnapshot = child as? DataSnapshot,
                      let dict = childSnapshot.value as? [String: Any],
                      let idStr = dict["id"] as? String,
                      let receiptID = UUID(uuidString: idStr),
                      dict["groupID"] == nil,
                      let expiresAtStr = dict["expiresAt"] as? String,
                      let expiresAt = ISO8601DateFormatter().date(from: expiresAtStr) else {
                    continue
                }
                
                if expiresAt < Date() {
                    print("🗑️ Deleting expired receipt: \(receiptID)")
                    self.deleteReceipt(receiptID: receiptID)
                }
            }
        }
    }
    
    func settleGroupReceipt(receiptID: UUID) {
        print("✅ Marking group receipt settled without deleting it: \(receiptID)")
        ref.child("receipts").child(receiptID.uuidString).updateChildValues([
            "lastModified": ISO8601DateFormatter().string(from: Date()),
            "settledAt": ISO8601DateFormatter().string(from: Date())
        ])
    }

    private func extendReceiptAvailability(receiptID: UUID) {
        let extendedExpiry = Calendar.current.date(byAdding: .year, value: 10, to: Date()) ?? Date()
        ref.child("receipts").child(receiptID.uuidString).updateChildValues([
            "expiresAt": ISO8601DateFormatter().string(from: extendedExpiry),
            "lastModified": ISO8601DateFormatter().string(from: Date())
        ])
    }
    
    /// ✅ NEW: Update receipt to reflect paid/unpaid status changes
    func syncReceiptWithPaidStatus(
        receiptID: UUID,
        unpaidTransactions: [Transaction],
        settlements: [PaymentLink]
    ) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to sync this receipt.") else {
            return
        }

        print("🔄 Syncing receipt \(receiptID) with paid status")
        
        let transactionSnapshots = unpaidTransactions.map { transaction in
            TransactionSnapshot(
                id: transaction.id,
                merchant: transaction.merchant,
                amount: transaction.amount,
                splitCount: transaction.splitWith.count,
                assignmentLabel: Self.assignmentLabel(
                    splitWith: transaction.splitWith,
                    participantCount: max(transaction.splitWith.count, 1)
                )
            )
        }
        
        let settlementSnapshots = settlements.filter { $0.amount > 0.01 }.map {
            SettlementSnapshot(
                id: $0.id,
                fromName: $0.from.name,
                toName: $0.to.name,
                amount: $0.amount
            )
        }
        
        let totalAmount = unpaidTransactions.reduce(0.0) { $0 + $1.amount }
        
        updateGroupReceiptTransactions(
            receiptID: receiptID,
            transactionSnapshots: transactionSnapshots,
            settlementSnapshots: settlementSnapshots,
            totalAmount: totalAmount
        )
    }

    static func assignmentLabel(splitWith: [Person], participantCount: Int) -> String {
        if splitWith.isEmpty {
            return "Unassigned"
        }

        if splitWith.count >= participantCount, participantCount > 1 {
            return "All"
        }

        if splitWith.count == 1 {
            return splitWith[0].isCurrentUser ? "Me" : splitWith[0].name
        }

        return splitWith.map { $0.isCurrentUser ? "Me" : $0.name }.joined(separator: ", ")
    }
}
