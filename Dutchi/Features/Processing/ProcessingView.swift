import SwiftUI

struct ProcessingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme
    
    @State private var isProcessing = true
    @State private var progress: Double = 0
    @State private var currentItem = 0
    @State private var totalItems = 0
    
    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
    private let chalk = Color(red: 0.96, green: 0.96, blue: 0.94)
    
    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                VStack(spacing: 32) {
                    ZStack {
                        Circle()
                            .stroke(ink.opacity(0.1), lineWidth: 6)
                            .frame(width: 120, height: 120)
                        
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(ink, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 120, height: 120)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: progress)
                        
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundColor(ink)
                    }
                    
                    VStack(spacing: 12) {
                        Text("Creating transactions...")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(ink)
                        
                        if totalItems > 0 {
                            Text("\(currentItem) of \(totalItems)")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear { processTransactions() }
    }
    
    // MARK: - Processing
    
    private func processTransactions() {
        if tutorialManager.isActive && !appState.transactions.isEmpty {
            print("Tutorial mode: transactions already set up, skipping processing")
            // IMPORTANT: Ensure all transactions are split with everyone
            ensureAllTransactionsSplitWithEveryone()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { router.navigateToReview() }
            return
        }
        
        totalItems = appState.uploadedReceipts.count
            + appState.manualTransactions.count
            + (appState.uploadedTransactions?.count ?? 0)
        print("Total items to process: \(totalItems)")
        print("  Receipts: \(appState.uploadedReceipts.count)")
        print("  Manual entries: \(appState.manualTransactions.count)")
        print("  Statements: \(appState.uploadedTransactions?.count ?? 0)")
        
        let totalSteps = 20
        let stepDuration = 0.05
        var currentStep = 0
        
        Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { timer in
            currentStep += 1
            progress = Double(currentStep) / Double(totalSteps)
            if currentStep >= totalSteps {
                timer.invalidate()
                createTransactionsFromProcessedData()
                // IMPORTANT: Ensure all transactions are split with everyone
                ensureAllTransactionsSplitWithEveryone()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { router.navigateToReview() }
            }
        }
    }
    
    // MARK: - Ensure Split With Everyone
    
    private func ensureAllTransactionsSplitWithEveryone() {
        print("🔍 Ensuring all transactions are split with everyone...")
        for index in appState.transactions.indices {
            if appState.transactions[index].splitWith.count != appState.people.count {
                print("  ⚠️ Transaction \(index) had \(appState.transactions[index].splitWith.count) people, updating to \(appState.people.count)")
                appState.transactions[index].splitWith = appState.people
            }
        }
        print("✅ All transactions now split with \(appState.people.count) people")
    }
    
    // MARK: - Create Transactions
    
    private func createTransactionsFromProcessedData() {
        print("\n=== CREATING TRANSACTIONS FROM PRE-PROCESSED DATA ===")
        appState.transactions.removeAll()
        
        guard let currentUser = appState.people.first(where: { $0.isCurrentUser }) else {
            print("ERROR: No current user found"); return
        }
        
        // 1. Process receipts
        for (index, receipt) in appState.uploadedReceipts.enumerated() {
            currentItem = index + 1
            print("\nProcessing receipt \(currentItem):")
            print("  Merchant:    \(receipt.merchant)")
            print("  Total:       $\(receipt.total)")
            print("  Line items:  \(receipt.lineItems.count)")
            print("  Image size:  \(receipt.image.size)")
            print("  Data size:   \(receipt.imageData.count) bytes")
            
            var transaction = appState.makeTransaction(from: receipt)
            transaction.splitWith = appState.people
            print("  Transaction: $\(transaction.amount), split with \(transaction.splitWith.count) people")
            appState.transactions.append(transaction)
        }
        
        // 2. Process manual entries
        for (index, manual) in appState.manualTransactions.enumerated() {
            currentItem = appState.uploadedReceipts.count + index + 1
            print("\nProcessing manual entry \(index + 1): \(manual.name) $\(manual.amount)")
            
            let transaction = Transaction(
                amount:         manual.amount,
                merchant:       manual.name,
                paidBy:         currentUser,
                splitWith:      appState.people,
                receiptImage:   nil,
                includeInSplit: true,
                isManual:       true,
                lineItems:      [],
                sourceDocumentType: .manual
            )
            print("  Transaction created with \(transaction.splitWith.count) people")
            appState.transactions.append(transaction)
        }
        
        // 3. Process bank statements
        if let uploadedTransactions = appState.uploadedTransactions {
            for uploadedTx in uploadedTransactions {
                print("\n📊 Processing statement: \(uploadedTx.accountType == .creditCard ? "Credit" : "Debit") card")
                print("  Total debits: $\(uploadedTx.totalDebits)")
                print("  Items: \(uploadedTx.items.count)")

                let total = statementSplitTotal(uploadedTx)
                guard total > 0 else { continue }

                let transaction = Transaction(
                    amount: total,
                    merchant: "Statement",
                    paidBy: currentUser,
                    splitWith: appState.people,
                    receiptImage: nil,
                    includeInSplit: true,
                    isManual: false,
                    lineItems: statementBreakdownLineItems(from: uploadedTx),
                    currency: "USD",
                    sourceDocumentType: .statement
                )
                appState.transactions.append(transaction)
            }
        }
        
        print("\n=== TRANSACTIONS CREATED: \(appState.transactions.count) total ===")
        print("  - From receipts: \(appState.uploadedReceipts.count)")
        print("  - From manual: \(appState.manualTransactions.count)")
        print("  - From statements: \(appState.uploadedTransactions?.count ?? 0)")
        print("=== ALL TRANSACTIONS SPLIT WITH: \(appState.people.count) PEOPLE ===\n")
        
        // ✅ KEEP the upload data for thumbnails - DON'T clear it
        // Only clear uploadedImages which isn't needed
        appState.uploadedImages.removeAll()
        print("Kept upload data for navigation (thumbnails will remain visible)\n")
    }

    private func statementSplitTotal(_ transaction: UploadedTransaction) -> Double {
        if transaction.totalDebits > 0 {
            return round2(transaction.totalDebits)
        }
        return round2(transaction.items.reduce(0.0) { $0 + abs($1.amount) })
    }

    private func statementBreakdownLineItems(from statement: UploadedTransaction) -> [ReceiptLineItem] {
        let rows = statement.items.filter { $0.isDebit || statement.totalDebits <= 0 }
        return rows.map {
            ReceiptLineItem(
                name: $0.description.isEmpty ? "Statement Transaction" : $0.description,
                originalPrice: abs($0.amount),
                discount: 0,
                amount: abs($0.amount),
                taxPortion: 0,
                isSelected: true,
                category: .merchandise,
                discountLabel: nil
            )
        }
    }
}
