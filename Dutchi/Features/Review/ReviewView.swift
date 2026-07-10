import SwiftUI
import UIKit
 
// MARK: - Custom Receipt Icon

struct BillIcon: View {
   let size: CGFloat
   let strokeWidth: CGFloat
   let color: Color
   
   init(size: CGFloat = 28, strokeWidth: CGFloat = 1.5, color: Color = Color(red: 0.15, green: 0.15, blue: 0.15)) {
       self.size = size
       self.strokeWidth = strokeWidth
       self.color = color
   }
   
   var body: some View {
       Canvas { context, size in
           let rectWidth: CGFloat = 18
           let rectHeight: CGFloat = 24
           let rectX = (size.width - rectWidth) / 2
           let rectY = (size.height - rectHeight) / 2
           
           // Draw receipt outline with zigzag bottom
           var path = Path()
           
           // Top edge
           path.move(to: CGPoint(x: rectX, y: rectY))
           path.addLine(to: CGPoint(x: rectX + rectWidth, y: rectY))
           
           // Right edge
           path.addLine(to: CGPoint(x: rectX + rectWidth, y: rectY + rectHeight - 3))
           
           // Zigzag bottom (4 teeth)
           let toothWidth = rectWidth / 4
           for i in 0..<4 {
               let x = rectX + rectWidth - (CGFloat(i) * toothWidth)
               let y = rectY + rectHeight - 3
               path.addLine(to: CGPoint(x: x - toothWidth/2, y: y + 3))
               path.addLine(to: CGPoint(x: x - toothWidth, y: y))
           }
           
           // Left edge
           path.addLine(to: CGPoint(x: rectX, y: rectY))
           
           context.stroke(path, with: .color(color), lineWidth: strokeWidth)
           
           // Draw line items inside
           let lineInset: CGFloat = 3
           let lineStartY = rectY + 4
           let lineSpacing: CGFloat = 4
           
           // Line 1 (widest)
           var line1 = Path()
           line1.move(to: CGPoint(x: rectX + lineInset, y: lineStartY))
           line1.addLine(to: CGPoint(x: rectX + lineInset + 11, y: lineStartY))
           context.stroke(line1, with: .color(color), lineWidth: strokeWidth)
           
           // Line 2
           var line2 = Path()
           line2.move(to: CGPoint(x: rectX + lineInset, y: lineStartY + lineSpacing))
           line2.addLine(to: CGPoint(x: rectX + lineInset + 9, y: lineStartY + lineSpacing))
           context.stroke(line2, with: .color(color), lineWidth: strokeWidth)
           
           // Line 3
           var line3 = Path()
           line3.move(to: CGPoint(x: rectX + lineInset, y: lineStartY + lineSpacing * 2))
           line3.addLine(to: CGPoint(x: rectX + lineInset + 7, y: lineStartY + lineSpacing * 2))
           context.stroke(line3, with: .color(color), lineWidth: strokeWidth)
           
           // Total line (near bottom)
           var totalLine = Path()
           let totalY = rectY + rectHeight - 7
           totalLine.move(to: CGPoint(x: rectX + lineInset, y: totalY))
           totalLine.addLine(to: CGPoint(x: rectX + lineInset + 11, y: totalY))
           context.stroke(totalLine, with: .color(color), lineWidth: strokeWidth)
       }
       .frame(width: size, height: size)
   }
}

struct StatementIcon: View {
    let size: CGFloat
    let strokeWidth: CGFloat
    let color: Color

    init(size: CGFloat = 28, strokeWidth: CGFloat = 1.6, color: Color = Color(red: 0.15, green: 0.15, blue: 0.15)) {
        self.size = size
        self.strokeWidth = strokeWidth
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let pageWidth = canvasSize.width * 0.72
            let pageHeight = canvasSize.height * 0.86
            let pageX = (canvasSize.width - pageWidth) / 2
            let pageY = (canvasSize.height - pageHeight) / 2
            let fold = canvasSize.width * 0.16
            let inset = canvasSize.width * 0.13

            var outline = Path()
            outline.move(to: CGPoint(x: pageX, y: pageY))
            outline.addLine(to: CGPoint(x: pageX + pageWidth - fold, y: pageY))
            outline.addLine(to: CGPoint(x: pageX + pageWidth, y: pageY + fold))
            outline.addLine(to: CGPoint(x: pageX + pageWidth, y: pageY + pageHeight))
            outline.addLine(to: CGPoint(x: pageX, y: pageY + pageHeight))
            outline.closeSubpath()
            context.stroke(outline, with: .color(color), lineWidth: strokeWidth)

            var foldPath = Path()
            foldPath.move(to: CGPoint(x: pageX + pageWidth - fold, y: pageY))
            foldPath.addLine(to: CGPoint(x: pageX + pageWidth - fold, y: pageY + fold))
            foldPath.addLine(to: CGPoint(x: pageX + pageWidth, y: pageY + fold))
            context.stroke(foldPath, with: .color(color), lineWidth: strokeWidth)

            func drawLine(fromX: CGFloat, toX: CGFloat, y: CGFloat, opacity: Double = 1.0) {
                var line = Path()
                line.move(to: CGPoint(x: fromX, y: y))
                line.addLine(to: CGPoint(x: toX, y: y))
                context.stroke(line, with: .color(color.opacity(opacity)), lineWidth: strokeWidth)
            }

            let leftX = pageX + inset
            let rightX = pageX + pageWidth - inset
            let headerY = pageY + pageHeight * 0.25
            drawLine(fromX: leftX, toX: rightX - pageWidth * 0.18, y: headerY)
            drawLine(fromX: leftX, toX: rightX, y: headerY + canvasSize.height * 0.15, opacity: 0.30)

            let row1Y = pageY + pageHeight * 0.56
            let row2Y = pageY + pageHeight * 0.73
            drawLine(fromX: leftX, toX: leftX + pageWidth * 0.34, y: row1Y, opacity: 0.70)
            drawLine(fromX: rightX - pageWidth * 0.22, toX: rightX, y: row1Y)
            drawLine(fromX: leftX, toX: leftX + pageWidth * 0.40, y: row2Y, opacity: 0.70)
            drawLine(fromX: rightX - pageWidth * 0.18, toX: rightX, y: row2Y)
        }
        .frame(width: size, height: size)
    }
}

 
// MARK: - PersonQuantity Model
 
struct PersonQuantity: Identifiable {
    let id: UUID
    let person: Person
    var quantity: Int
 
    init(person: Person, quantity: Int = 1) {
        self.id       = person.id
        self.person   = person
        self.quantity = quantity
    }
 
    func share(in all: [PersonQuantity]) -> Double {
        let total = all.reduce(0) { $0 + $1.quantity }
        guard total > 0 else { return 0 }
        return Double(quantity) / Double(total)
    }
 
    func amount(for transactionTotal: Double, in all: [PersonQuantity]) -> Double {
        transactionTotal * share(in: all)
    }
}
 
// MARK: - ReviewView


enum ActiveSheet: Identifiable {
    case manualAdd
    case editAmount
    case breakdown
    case advancedSplit(Transaction)
    case customPicker
    case tip

    var id: String {
        switch self {
        case .manualAdd:               return "manualAdd"
        case .editAmount:              return "editAmount"
        case .breakdown:               return "breakdown"
        case .advancedSplit(let t):    return "advancedSplit-\(t.id)"
        case .customPicker:            return "customPicker"
        case .tip:                     return "tip"
        }
    }
}

 
struct ReviewView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme
 
    @State private var showManualAdd = false
    @State private var manualMerchant = ""
    @State private var manualAmount = ""
    @State private var breakdownReceiptImage: Data? = nil
    @State private var showImageViewer = false
    @State private var selectedImage: UIImage?
    @State private var showEditAmount = false
    @StateObject private var groupManager = GroupManager.shared
    @State private var editingTransaction: Transaction?
    @State private var editAmount = ""
    @State private var showEditName = false
    @State private var editName = ""
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var undoAction: (() -> Void)?
    @State private var showBreakdownSheet = false
    @State private var breakdownTransaction: Transaction?
    @State private var breakdownDocumentType: TransactionSourceDocumentType = .receipt
    @State private var detectedLineItems: [ReceiptLineItem] = []
    @State private var showBackConfirmation = false
    @State private var isProcessingBreakdown = false
    @State private var isSyncingGroupExpenses = false
    @State private var showValidationAlert = false
    @State private var validationMessage = ""
    @State private var advancedSplitTarget: Transaction? = nil
    
    // Replace the five @State sheet booleans with:
    @State private var activeSheet: ActiveSheet? = nil

    // Keep these bindings-dependent ones:
    // @State private var showBackConfirmation  ← keep as-is (confirmationDialog)
    // @State private var showValidationAlert   ← keep as-is (alert)
    // @State private var showImageViewer       ← keep as-is (ZStack overlay)

 
    @State private var breakdownQuickTotal: Double? = nil
    @State private var breakdownQuickMerchant: String = ""
    @State private var isQuickModeEnabled = false

    private var resolvedBreakdownReceiptImage: Data? {
        if let imageData = breakdownReceiptImage, !imageData.isEmpty {
            return imageData
        }
        if let transaction = breakdownTransaction {
            return appState.receiptImageData(for: transaction)
        }
        return nil
    }
    
    // MARK: - Tutorial Auto-Play State
    @State private var tutorialAutoPlayTimer: Timer?
    @State private var tutorialAnimationInProgress = false
    
    // MARK: - Quick Assign Mode
    enum AssignMode: Equatable {
        case splitAll
        case currentUser
        case specific(Person)
        case custom([Person])
        
        var label: String {
            switch self {
            case .splitAll: return "Split All"
            case .currentUser: return "Me"
            case .specific(let person): return person.name
            case .custom(let people):
                if people.isEmpty {
                    return "Custom"
                } else if people.count == 1 {
                    return people[0].name
                } else {
                    return "Custom (\(people.count))"
                }
            }
        }
    }

    enum QuickEditMode: Equatable {
        case splitWith
        case paidBy
    }
    
    @State private var selectedAssignMode: AssignMode = .splitAll
    @State private var quickEditMode: QuickEditMode = .splitWith
    @State private var selectedPayerID: UUID? = nil
    @State private var showQuickAssignBar = false
    @State private var showCustomPicker = false
    @State private var customSelectedPeople: Set<UUID> = []

    private var selectedPayer: Person {
        if let selectedPayerID,
           let person = appState.people.first(where: { $0.id == selectedPayerID }) {
            return person
        }
        if let currentUser = appState.people.first(where: { $0.isCurrentUser }) {
            return currentUser
        }
        return appState.people.first ?? Person(name: "You", isCurrentUser: true)
    }

    private var shouldPreferSpeedMode: Bool {
        appState.transactions.count >= 4
    }

    private var transactionGrandTotal: Double {
        appState.transactions.reduce(0.0) { $0 + $1.amount }
    }

    private var unassignedTransactionCount: Int {
        appState.transactions.filter { $0.splitWith.isEmpty }.count
    }

    private var receiptBackedTransactionCount: Int {
        appState.transactions.filter {
            $0.sourceDocumentType == .receipt || transactionHasReceiptImageHint($0)
        }.count
    }

    private var statementBackedTransactionCount: Int {
        appState.transactions.filter { $0.sourceDocumentType == .statement }.count
    }

    private var reviewReadyStatusText: String {
        if appState.transactions.isEmpty {
            return "ADD ITEMS"
        }
        if unassignedTransactionCount == 0 {
            return "READY"
        }
        return "\(unassignedTransactionCount) LEFT"
    }
    
    // MARK: - Live summary tracking
    private var itemsBySplitType: [(label: String, count: Int)] {
        var results: [String: Int] = [:]
        
        for transaction in appState.transactions {
            let key: String
            if transaction.splitWith.isEmpty {
                key = "Unassigned"
            } else if transaction.splitWith.count == appState.people.count {
                key = "Shared (\(appState.people.count))"
            } else if transaction.splitWith.count == 1 {
                key = transaction.splitWith[0].isCurrentUser ? "You" : transaction.splitWith[0].name
            } else {
                key = "Split (\(transaction.splitWith.count))"
            }
            results[key, default: 0] += 1
        }
        
        return results.map { (label: $0.key, count: $0.value) }
            .sorted { $0.label < $1.label }
    }

    private var shouldHighlightQuickAssignBar: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .quickAssignBar
    }
 
    // MARK: - Warm receipt palette
    private let ink       = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory     = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let cream     = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
 
    // MARK: - Tutorial spotlight helpers
 
    private var shouldHighlightTransaction: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .reviewTransaction
    }
    private var shouldHighlightBreakdownButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .breakdownButton
    }
    private var shouldHighlightItemCard: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .reviewItemCard
    }
 
    var body: some View {
        ZStack {
            cream.ignoresSafeArea()

            mainContent

            if showImageViewer, let image = selectedImage {
                fullScreenImageViewer(image: image)
                    .transition(.opacity)
                    .zIndex(100)
            }

            if showToast {
                VStack {
                    Spacer()
                    receiptToast
                        .padding(.horizontal, 20)
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(50)
            }

            if tutorialManager.isActive {
                TutorialOverlay(context: .review).zIndex(200)
            }
        }
        .navigationBarBackButtonHidden(true)
        .keyboardDoneToolbar()
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .manualAdd:
                ManualTransactionSheet(
                    isPresented: Binding(
                        get: { activeSheet != nil },
                        set: { if !$0 { activeSheet = nil } }
                    ),
                    merchant: $manualMerchant,
                    amount: $manualAmount,
                    onAdd: addManualTransaction
                )

            case .editAmount:
                EditTransactionSheet(
                    isPresented: Binding(
                        get: { activeSheet != nil },
                        set: { if !$0 { activeSheet = nil } }
                    ),
                    name: $editName,
                    amount: $editAmount,
                    onSave: saveEditedTransaction
                )

            case .breakdown:
                ReceiptBreakdownSheet(
                    isPresented: Binding(
                        get: { activeSheet != nil },
                        set: { if !$0 {
                            activeSheet = nil
                            breakdownQuickTotal    = nil
                            breakdownQuickMerchant = ""
                            breakdownReceiptImage  = nil
                            breakdownDocumentType  = .receipt
                        }}
                    ),
                    transaction:      breakdownTransaction,
                    lineItems:        $detectedLineItems,
                    isLoading:        $isProcessingBreakdown,
                    quickTotal:       $breakdownQuickTotal,
                    quickMerchant:    $breakdownQuickMerchant,
                    receiptImageData: resolvedBreakdownReceiptImage,
                    documentType: breakdownDocumentType,
                    onUseTotal: {
                        activeSheet = nil
                        showSuccessToast("Using total amount")
                    },
                    onUseBreakdown: {
                        applyBreakdown()
                    }
                )
                .environmentObject(tutorialManager)

            case .advancedSplit(let target):
                AdvancedSplitSheet(
                    transaction: target,
                    allPeople:   appState.people,
                    onApply:     { quantities in applyAdvancedSplit(to: target, quantities: quantities) },
                    onDismiss:   { activeSheet = nil }
                )

            case .customPicker:
                CustomPeoplePickerSheet(
                    allPeople: appState.people,
                    selectedPeople: $customSelectedPeople,
                    onApply: {
                        let selected = appState.people.filter { customSelectedPeople.contains($0.id) }
                        selectedAssignMode = .custom(selected)
                        activeSheet = nil
                    }
                )

            case .tip:
                TipAmountSheet(
                    baseAmount: appState.transactions.reduce(0.0) { $0 + $1.amount },
                    onApply: { amount in
                        addTipTransaction(amount)
                        activeSheet = nil
                    },
                    onDismiss: { activeSheet = nil }
                )
            }
        }
        .confirmationDialog("Leave Review?", isPresented: $showBackConfirmation, titleVisibility: .visible) {
            Button("Keep Uploads & Go Back") {
                saveTransactionsToUpload()
                router.navigateToUpload()
            }
            Button("Discard Upload & Go Back", role: .destructive) {
                discardTransactions()
                router.navigateToUpload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep returns to Upload with these receipt uploads. Discard removes the current upload session.")
        }
        .alert("Selection Required", isPresented: $showValidationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationMessage)
        }
        .onChange(of: tutorialManager.shouldOpenBreakdownSheet) { shouldOpen in
            guard shouldOpen, tutorialManager.isActive,
                  let firstTransaction = appState.transactions.first else { return }
            tutorialManager.shouldOpenBreakdownSheet = false
            handleBreakdown(transaction: firstTransaction)
        }
        .onChange(of: tutorialManager.shouldAutoApplyBreakdown) { shouldApply in
            guard shouldApply, tutorialManager.isActive else { return }
            tutorialManager.shouldAutoApplyBreakdown = false
            applyBreakdown()
        }
        .onChange(of: tutorialManager.currentStepIndex) { newStep in
            handleTutorialStepChange(newStep)
            if newStep == 6 {
                self.runStep6Animation()
            }
        }
        .onAppear {
            print("=== Review View Loaded ===")
            print("Total transactions: \(appState.transactions.count)")
            for t in appState.transactions {
                print("  \(t.merchant) = $\(t.amount) | splitWith: \(t.splitWith.count) people | image: \(t.receiptImage != nil) | items: \(t.lineItems.count)")
            }
            syncActiveGroupMembersForReview()
            ensureDefaultSplitAll()
            if shouldPreferSpeedMode {
                isQuickModeEnabled = true
            }
            if selectedPayerID == nil {
                selectedPayerID = appState.people.first(where: { $0.isCurrentUser })?.id ?? appState.people.first?.id
            }
            if tutorialManager.isActive, tutorialManager.currentStepIndex == 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.runStep6Animation()
                }
            }
        }
        .onDisappear {
            stopTutorialAutoPlay()
        }
        .onChange(of: appState.transactions.count) { _ in
            if shouldPreferSpeedMode {
                isQuickModeEnabled = true
            }
        }
    }
    
 

    
    // MARK: - Tutorial Auto-Play Logic
    private func handleTutorialStepChange(_ stepIndex: Int) {
        guard tutorialManager.isActive else { return }
        
        stopTutorialAutoPlay()
        
        switch stepIndex {
        case 5:
            runStep5Animation()
        case 6:
            // Step 6 now handles both Quick Mode AND Select/Deselect
            // Animation starts when user presses Next
            break
        default:
            break
        }
    }
    
    // MARK: - Step 5: Assign to One Person (Slow & Accurate)
    private func runStep5Animation() {
        print("🎬 Tutorial Step 5: Assign to one person")
        
        guard let alex = appState.people.first(where: { !$0.isCurrentUser }) else {
            print("⚠️ No Alex found")
            return
        }
        
        ensureDefaultSplitAll()
        tutorialAnimationInProgress = true
        
        // Execute step 0 immediately
        let screenWidth = UIScreen.main.bounds.width
        let alexButtonX = screenWidth * 0.59
        let alexButtonY: CGFloat = 180
        
        tutorialManager.showClickAnimation(at: CGPoint(x: alexButtonX, y: alexButtonY))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.spring(response: 0.4)) {
                self.selectedAssignMode = .specific(alex)
            }
            HapticManager.impact(style: .medium)
            print("✅ Selected Alex (immediate)")
        }
        
        var step = 1
        tutorialAutoPlayTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { timer in
            guard self.tutorialManager.currentStepIndex == 5 else {
                timer.invalidate()
                return
            }
            
            switch step {
            case 1:
                DispatchQueue.main.async {
                    let transactionX = UIScreen.main.bounds.midX
                    let transactionY = UIScreen.main.bounds.height * 0.48
                    
                    self.tutorialManager.showClickAnimation(at: CGPoint(x: transactionX, y: transactionY))
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard !self.appState.transactions.isEmpty else {
                            timer.invalidate()
                            return
                        }
                        withAnimation(.spring(response: 0.4)) {
                            self.appState.transactions[0].splitWith = [alex]
                        }
                        HapticManager.impact(style: .medium)
                        print("✅ Assigned ARTISAN ROLL to Alex")
                    }
                }
                
            default:
                timer.invalidate()
                self.tutorialAnimationInProgress = false
                print("✅ Step 5 complete")
            }
            
            step += 1
        }
    }
    
 
    // MARK: - Step 6: Quick Mode (Manual trigger only - activates when user presses Next)
    private func runStep6Animation() {
        print("🎬 Tutorial Step 6+7: Quick Mode + Select/Deselect All")
        
        guard let alex = appState.people.first(where: { !$0.isCurrentUser }),
              appState.transactions.count >= 2 else {
            print("⚠️ Insufficient data for step 6")
            return
        }

        guard !tutorialAnimationInProgress else {
            print("⚠️ Step 6 animation already running")
            return
        }
        
        tutorialAnimationInProgress = true
        
        // Step 0 immediately: enable Speed Mode
        let toggleX = UIScreen.main.bounds.midX
        let toggleY: CGFloat = 260
        
        tutorialManager.showClickAnimation(at: CGPoint(x: toggleX, y: toggleY))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.spring(response: 0.4)) {
                self.showQuickAssignBar = true
                self.isQuickModeEnabled = true
            }
            HapticManager.impact(style: .medium)
            print("✅ Enabled Speed Mode")
        }
        
        var step = 1
        tutorialAutoPlayTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
            guard self.tutorialManager.currentStepIndex == 6 else {
                timer.invalidate()
                return
            }
            
            switch step {
            case 1:
                // Select Alex
                DispatchQueue.main.async {
                    let alexButtonX = UIScreen.main.bounds.width * 0.59
                    let alexButtonY: CGFloat = 180
                    self.tutorialManager.showClickAnimation(at: CGPoint(x: alexButtonX, y: alexButtonY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation(.spring(response: 0.4)) {
                            self.selectedAssignMode = .specific(alex)
                        }
                        HapticManager.impact(style: .light)
                        print("✅ Selected Alex")
                    }
                }
                
            case 2:
                // Tap Shin Ramyun
                DispatchQueue.main.async {
                    let rowX = UIScreen.main.bounds.midX + 140
                    let rowY: CGFloat = 455
                    self.tutorialManager.showClickAnimation(at: CGPoint(x: rowX, y: rowY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard self.appState.transactions.count >= 2 else { return }
                        self.applyQuickAssign(to: self.appState.transactions[1])
                        print("✅ Assigned SHIN RAMYUN to Alex")
                    }
                }
                
            case 3:
                // Tap 1895 CHERRY TOV — done assigning
                DispatchQueue.main.async {
                    let rowX = UIScreen.main.bounds.midX + 135
                    let rowY: CGFloat = 505
                    self.tutorialManager.showClickAnimation(at: CGPoint(x: rowX, y: rowY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard self.appState.transactions.count >= 3 else { return }
                        self.applyQuickAssign(to: self.appState.transactions[2])
                        print("✅ Assigned 1895 CHERRY TOV to Alex")
                    }
                }
                
            case 4:
                // Deselect All
                DispatchQueue.main.async {
                    let deselectX = UIScreen.main.bounds.width * 0.75
                    let deselectY: CGFloat = 230
                    self.tutorialManager.showClickAnimation(at: CGPoint(x: deselectX, y: deselectY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.deselectAllTransactions()
                        print("✅ Deselected all")
                    }
                }
                
            case 5:
                // Select All
                DispatchQueue.main.async {
                    let selectX = UIScreen.main.bounds.width * 0.25
                    let selectY: CGFloat = 230
                    self.tutorialManager.showClickAnimation(at: CGPoint(x: selectX, y: selectY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.applyModeToAllTransactions()
                        print("✅ Selected all")
                    }
                }
                
            default:
                timer.invalidate()
                self.tutorialAnimationInProgress = false
                print("✅ Step 6+7 complete")
            }
            
            step += 1
        }
    }
    
    
  
    
    private func ensureDefaultSplitAll() {
        // CRITICAL: Make sure all transactions are split with everyone
        // This should happen both in tutorial mode AND normal mode
        syncActiveGroupMembersForReview()
        print("🔄 Ensuring all transactions split with everyone...")
        for index in appState.transactions.indices {
            if appState.transactions[index].splitWith.count != appState.people.count {
                print("  ⚠️ Transaction \(index) (\(appState.transactions[index].merchant)) had \(appState.transactions[index].splitWith.count) people, updating to \(appState.people.count)")
                appState.transactions[index].splitWith = appState.people
            }
        }
        
        // Reset to splitAll mode
        selectedAssignMode = .splitAll
        isQuickModeEnabled = false
        showQuickAssignBar = true
        
        print("✅ All transactions now split with \(appState.people.count) people")
    }
    
    private func stopTutorialAutoPlay() {
        tutorialAutoPlayTimer?.invalidate()
        tutorialAutoPlayTimer = nil
        tutorialAnimationInProgress = false
        
    }
       
    // MARK: - Step 8: Fast switching demonstration
    private func runStep8Animation() {
        print("🎬 Tutorial Step 8: Fast switching")
        
        guard let alex = appState.people.first(where: { !$0.isCurrentUser }),
              let currentUser = appState.people.first(where: { $0.isCurrentUser }),
              appState.transactions.count >= 5 else {
            print("⚠️ Insufficient data for step 8")
            return
        }
        
        tutorialAnimationInProgress = true
        
        var step = 0
        tutorialAutoPlayTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
            guard self.tutorialManager.currentStepIndex == 8 else {
                timer.invalidate()
                return
            }
            
            switch step {
            case 0:
                // Select Alex
                withAnimation(.spring(response: 0.2)) {
                    self.selectedAssignMode = .specific(alex)
                }
                HapticManager.impact(style: .light)
                
            case 1:
                // Assign transaction 3 to Alex
                self.quickAssignAnimation(index: 3, person: alex)
                
            case 2:
                // Switch to Me
                withAnimation(.spring(response: 0.2)) {
                    self.selectedAssignMode = .currentUser
                }
                HapticManager.impact(style: .light)
                
            case 3:
                // Assign transaction 4 to Me
                self.quickAssignAnimation(index: 4, person: currentUser)
                
            case 4:
                // Switch to Split All
                withAnimation(.spring(response: 0.2)) {
                    self.selectedAssignMode = .splitAll
                }
                HapticManager.impact(style: .light)
                
            case 5:
                // Apply to all remaining (fast)
                self.rapidAssignToAll()
                
            default:
                timer.invalidate()
                self.tutorialAnimationInProgress = false
            }
            
            step += 1
        }
    }
    
    // MARK: - Animation Helpers
    
    private func rapidAssignToTransactions(indices: [Int], person: Person) {
        for (delay, index) in indices.enumerated() {
            guard index < appState.transactions.count else { continue }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) * 0.25) {
                withAnimation(.spring(response: 0.2)) {
                    self.appState.transactions[index].splitWith = [person]
                }
                HapticManager.impact(style: .light)
            }
        }
    }
    
    private func quickAssignAnimation(index: Int, person: Person) {
        guard index < appState.transactions.count else { return }
        
        withAnimation(.spring(response: 0.2)) {
            appState.transactions[index].splitWith = [person]
        }
        HapticManager.impact(style: .light)
    }
    
    private func rapidAssignToAll() {
        for index in appState.transactions.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.15) {
                withAnimation(.spring(response: 0.2)) {
                    self.appState.transactions[index].splitWith = self.appState.people
                }
                if index == 0 || index % 2 == 0 {
                    HapticManager.impact(style: .light)
                }
            }
        }
    }
    
    // MARK: - Quick Mode List (Spreadsheet Style)
    
    private var quickModeTransactionGrid: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 12) {
                Text("ITEM")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ink.opacity(0.55))
                    .tracking(1.2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Text("AMOUNT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ink.opacity(0.55))
                    .tracking(1.2)
                    .frame(minWidth: 60, alignment: .trailing)
                
                Text(quickEditMode == .paidBy ? "PAID BY" : "SPLIT WITH")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ink.opacity(0.55))
                    .tracking(1.2)
                    .padding(.horizontal, 10)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(parchment.opacity(0.70))
            
            // Rows
            LazyVStack(spacing: 0) {
                ForEach(Array($appState.transactions.enumerated()), id: \.element.id) { index, $transaction in
                    VStack(spacing: 0) {
                        QuickModeTransactionCell(
                            transaction: $transaction,
                            allPeople: appState.people,
                            currentAssignMode: selectedAssignMode,
                            editMode: quickEditMode,
                            requiresValueReview: transactionRequiresOCRReview(transaction),
                            canViewImage: transactionHasReceiptImageHint(transaction),
                            canShowBreakdown: canShowBreakdown(for: transaction),
                            onQuickAssign: { applyQuickAction(to: transaction) },
                            onEdit: { beginEditing(transaction) },
                            onImageTap: { handleImageTap(transaction: transaction) },
                            onBreakdown: { handleBreakdown(transaction: transaction) },
                            onAdvancedSplit: { activeSheet = .advancedSplit(transaction) },
                            onDelete: { deleteTransaction(transaction) }
                        )
                        
                        // Divider between rows (only if not last item)
                        if index < appState.transactions.count - 1 {
                            Rectangle()
                                .fill(ink.opacity(0.08))
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(ivory)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(0.18), lineWidth: 1.5)
        )
        .padding(.horizontal, 20)
        .animation(.spring(response: 0.3), value: isQuickModeEnabled)
    }
 
    // MARK: - Header
 
    private var headerSection: some View {
        HStack(spacing: 16) {
            Button(action: { handleBackTap() }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("BACK")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                }
                .foregroundColor(ink.opacity(0.70))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(ink.opacity(0.25), lineWidth: 1.5)
                )
            }
            .buttonStyle(ScaleButtonStyle())
 
            Spacer()
 
            VStack(spacing: 2) {
                Text("REVIEW")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(ink.opacity(0.60))
                    .tracking(1.5)
                Text("TRANSACTIONS")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ink)
                    .tracking(0.5)
            }
 
            Spacer()
 
            Button(action: { router.presentProfile() }) {
                if let currentUser = appState.people.first(where: { $0.isCurrentUser }) {
                    AvatarView(imageData: currentUser.contactImage, initials: currentUser.initials, size: 36)
                        .overlay(Circle().stroke(ink.opacity(0.15), lineWidth: 1))
                } else {
                    AvatarView(imageData: nil, initials: "ME", size: 36)
                        .overlay(Circle().stroke(ink.opacity(0.15), lineWidth: 1))
                }
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(ivory)
    }
 
    // MARK: - Dashed divider
 
    private var dashedDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        let dashWidth: CGFloat = 5
                        let dashGap:   CGFloat = 5
                        var x: CGFloat = 0
                        while x < geometry.size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: min(x + dashWidth, geometry.size.width), y: 0))
                            x += dashWidth + dashGap
                        }
                    }
                    .stroke(ink, lineWidth: 1.5)
                }
            )
            .padding(.horizontal, 20)
    }
 
    // MARK: - Add Manually button
 
  
    private var bottomButton: some View {
        VStack(spacing: 0) {
            // Dashed divider
            Rectangle()
                .fill(Color.clear)
                .frame(height: 1)
                .overlay(
                    GeometryReader { geometry in
                        Path { path in
                            let dashWidth: CGFloat = 5
                            let dashGap:   CGFloat = 5
                            var x: CGFloat = 0
                            while x < geometry.size.width {
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: min(x + dashWidth, geometry.size.width), y: 0))
                                x += dashWidth + dashGap
                            }
                        }
                        .stroke(ink, lineWidth: 1.5)
                    }
                )
                .padding(.horizontal, 20)
     
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(unassignedTransactionCount == 0 ? "READY TO SETTLE" : "REVIEW NEEDED")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(unassignedTransactionCount == 0 ? Color(red: 0.16, green: 0.38, blue: 0.16) : Color(red: 0.53, green: 0.24, blue: 0.08))
                        .tracking(1.2)
                    Text(unassignedTransactionCount == 0
                         ? "\(appState.transactions.count) transaction\(appState.transactions.count == 1 ? "" : "s") assigned"
                         : "\(unassignedTransactionCount) transaction\(unassignedTransactionCount == 1 ? "" : "s") still need people")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ink.opacity(0.62))
                }

                Spacer()

                Text(formattedDollar(transactionGrandTotal))
                    .font(.system(size: 15, weight: .black))
                    .foregroundColor(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)
     
            Button(action: {
                HapticManager.impact(style: .medium)

                guard !appState.transactions.isEmpty else {
                    validationMessage = "Add at least one transaction before continuing to payments."
                    showValidationAlert = true
                    return
                }
                
                // ✅ VALIDATE FIRST
                if !validateTransactions() {
                    return  // Validation alert will show
                }
                
                // ✅ GROUP MODE - start sync, then navigate immediately.
                // GroupManager applies the local group update before Firebase finishes,
                // so SettleShare can open without waiting on network latency.
                if groupManager.isGroupModeEnabled {
                    // Check if group exists
                    guard let group = groupManager.activeGroup else {
                        print("❌ ERROR: Group mode enabled but no active group")
                        validationMessage = "No active group found. Please create or join a group first."
                        showValidationAlert = true
                        return
                    }
                    
                    print("🟢 GROUP MODE: Starting sync for \(appState.transactions.count) transactions to group \(group.name)")
                    
                    isSyncingGroupExpenses = true
                    syncTransactionsToGroup { syncResult in
                        isSyncingGroupExpenses = false

                        if syncResult.success {
                            print("✅ Synced \(syncResult.count) transactions to group")
                        } else {
                            print("⚠️ Sync had issues: \(syncResult.message)")
                            validationMessage = syncResult.message
                            showValidationAlert = true
                        }
                    }

                    router.navigateToSettle()
                } else {
                    // ✅ NON-GROUP MODE - Just navigate
                    print("🟡 NON-GROUP MODE: Navigating to settle")
                    router.navigateToSettle()
                }
            }) {
                HStack(spacing: 8) {
                    Text(appState.transactions.isEmpty ? "ADD TRANSACTIONS FIRST" : "CONTINUE TO PAYMENTS")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(0.8)
                    if !appState.transactions.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .foregroundColor(appState.transactions.isEmpty ? ink.opacity(0.28) : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(appState.transactions.isEmpty ? ink.opacity(0.08) : ink)
                .cornerRadius(3)
            }
            .disabled(appState.transactions.isEmpty)
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(ivory)
    }
     
    // MARK: - FIXED syncTransactionsToGroup with Result Return
    
 
    private var receiptToast: some View {
        HStack(spacing: 12) {
            Text(toastMessage.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ink.opacity(0.70))
                .tracking(0.8)
            Spacer()
            if let undo = undoAction {
                Button(action: { undo() }) {
                    Text("UNDO")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ink)
                        .tracking(1.2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink, lineWidth: 1.5)
                        )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.95))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(ivory)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(ink.opacity(0.25), lineWidth: 1.5)
                )
        )
    }
 
    // MARK: - Full-screen image viewer
 
    private func fullScreenImageViewer(image: UIImage) -> some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showImageViewer = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedImage = nil }
                }
            VStack {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(4)
                    .padding(.horizontal, 20)
                Spacer()
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showImageViewer = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedImage = nil }
                    }) {
                        Text("CLOSE")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(20)
                }
                Spacer()
            }
        }
    }
 
    // MARK: - Quick Assign Logic

    private func applyQuickAction(to transaction: Transaction) {
        switch quickEditMode {
        case .splitWith:
            applyQuickAssign(to: transaction)
        case .paidBy:
            applyPayer(selectedPayer, to: transaction)
        }
    }
    
    private func applyQuickAssign(to transaction: Transaction) {
        guard let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        
        withAnimation(.spring(response: 0.3)) {
            switch selectedAssignMode {
            case .splitAll:
                appState.transactions[index].splitWith = appState.people
                
            case .currentUser:
                if let currentUser = appState.people.first(where: { $0.isCurrentUser }) {
                    appState.transactions[index].splitWith = [currentUser]
                }
                
            case .specific(let person):
                appState.transactions[index].splitWith = [person]
                
            case .custom(let people):
                if people.isEmpty {
                    // If custom is not configured, open the picker
                    customSelectedPeople = []
                    showCustomPicker = true
                } else {
                    appState.transactions[index].splitWith = people
                }
            }
        }
        
        HapticManager.impact(style: .light)
    }

    private func applyPayer(_ payer: Person, to transaction: Transaction) {
        guard let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }

        withAnimation(.spring(response: 0.25)) {
            appState.transactions[index].paidBy = payer
        }

        HapticManager.impact(style: .light)
    }
    
    private func clearAssignment(for transaction: Transaction) {
        guard let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        
        withAnimation(.spring(response: 0.3)) {
            appState.transactions[index].splitWith = []
        }
        
        HapticManager.impact(style: .light)
    }
    
    private func applyModeToAllTransactions() {
        let update = {
            for index in appState.transactions.indices {
                switch selectedAssignMode {
                case .splitAll:
                    appState.transactions[index].splitWith = appState.people
                    
                case .currentUser:
                    if let currentUser = appState.people.first(where: { $0.isCurrentUser }) {
                        appState.transactions[index].splitWith = [currentUser]
                    }
                    
                case .specific(let person):
                    appState.transactions[index].splitWith = [person]
                    
                case .custom(let people):
                    if !people.isEmpty {
                        appState.transactions[index].splitWith = people
                    }
                }
            }
        }

        if appState.transactions.count > 80 {
            update()
        } else {
            withAnimation(.spring(response: 0.3)) {
                update()
            }
        }
        
        HapticManager.impact(style: .medium)
        showSuccessToast("Applied to all \(appState.transactions.count) transaction\(appState.transactions.count == 1 ? "" : "s")")
    }

    private func applySelectedPayerToAllTransactions() {
        let payer = selectedPayer
        let update = {
            for index in appState.transactions.indices {
                appState.transactions[index].paidBy = payer
            }
        }

        if appState.transactions.count > 80 {
            update()
        } else {
            withAnimation(.spring(response: 0.3)) {
                update()
            }
        }

        HapticManager.impact(style: .medium)
        showSuccessToast("Paid by \(payer.isCurrentUser ? "You" : payer.name) for all \(appState.transactions.count) transaction\(appState.transactions.count == 1 ? "" : "s")")
    }

    private func resetPayersToCurrentUser() {
        guard let currentUser = appState.people.first(where: { $0.isCurrentUser }) else { return }
        selectedPayerID = currentUser.id
        let update = {
            for index in appState.transactions.indices {
                appState.transactions[index].paidBy = currentUser
            }
        }

        if appState.transactions.count > 80 {
            update()
        } else {
            withAnimation(.spring(response: 0.3)) {
                update()
            }
        }

        HapticManager.impact(style: .medium)
        showSuccessToast("Paid by reset to You")
    }
    
    private func deselectAllTransactions() {
        let update = {
            for index in appState.transactions.indices {
                appState.transactions[index].splitWith = []
            }
        }

        if appState.transactions.count > 80 {
            update()
        } else {
            withAnimation(.spring(response: 0.3)) {
                update()
            }
        }
        
        HapticManager.impact(style: .medium)
        showSuccessToast("Cleared all selections")
    }

    // MARK: - Validation
 
    private func validateTransactions() -> Bool {
        let without = appState.transactions.filter { $0.splitWith.isEmpty }.map(\.merchant)
        guard !without.isEmpty else { return true }
        let list = without.prefix(3).joined(separator: ", ")
        let extra = without.count > 3 ? " and \(without.count - 3) more" : ""
        validationMessage = "No one is selected for: \(list)\(extra). Please select at least one person for each item."
        showValidationAlert = true
        return false
    }
 
    private func saveTransactionsToUpload() {
        var savedReceiptTokens = Set<String>()

        for transaction in appState.transactions {
            if transaction.isManual {
                let alreadySaved = appState.manualTransactions.contains {
                    $0.name == transaction.merchant && abs($0.amount - transaction.amount) < 0.01
                }
                if !alreadySaved {
                    appState.manualTransactions.append((name: transaction.merchant, amount: transaction.amount))
                }
            } else if transaction.isBreakdownChild {
                continue
            } else if let imageData = appState.receiptImageData(for: transaction),
                      let image = UIImage(data: imageData) {
                let receiptToken = transaction.backgroundResultToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let receiptToken, !receiptToken.isEmpty {
                    guard !savedReceiptTokens.contains(receiptToken) else { continue }
                    savedReceiptTokens.insert(receiptToken)
                }

                let ocrData = OCRService.ReceiptData(
                    merchant:            transaction.merchant,
                    lineItems:           transaction.lineItems,
                    hasReceiptStructure: true,
                    confidence:          1.0,
                    grandTotal:          transaction.amount,
                    processingMethod:    .appleLocal,
                    receiptDate:         nil,
                    needsReview:         false,
                    fallbackReason:      nil,
                    currency:            "USD",
                    qualityScore:        1.0,
                    totalConfidence:     .high,
                    validationStatus:    .balanced,
                    arithmeticGapCents:  0,
                    validationIssues:    [],
                    ocrRoute:            "apple_local",
                    backgroundResultToken: transaction.backgroundResultToken
                )

                if let receiptToken,
                   !receiptToken.isEmpty,
                   let existingIndex = appState.uploadedReceipts.firstIndex(where: { $0.backgroundResultToken == receiptToken }) {
                    appState.uploadedReceipts[existingIndex].merchant = transaction.merchant
                    appState.uploadedReceipts[existingIndex].total = transaction.amount
                    appState.uploadedReceipts[existingIndex].lineItems = transaction.lineItems
                    appState.uploadedReceipts[existingIndex].receiptDate = transaction.receiptDate
                    appState.uploadedReceipts[existingIndex].currency = transaction.currency
                } else {
                    let duplicateReceiptExists = appState.uploadedReceipts.contains {
                        $0.merchant == transaction.merchant &&
                        abs($0.total - transaction.amount) < 0.01
                    }
                    if appState.uploadedReceipts.isEmpty && !duplicateReceiptExists {
                        appState.uploadedReceipts.append(UploadedReceipt(image: image, ocrResult: ocrData))
                    }
                }
            }
            // ✅ REMOVED the else block - statement transactions are already in appState.uploadedTransactions
            // They don't need to be saved anywhere else because they persist in uploadedTransactions
        }
        appState.preserveReviewTransactionsOnNextReview = true
    }
 
    private func discardTransactions() {
        appState.resetUploadSession()
    }

    private func handleBackTap() {
        if appState.transactions.isEmpty {
            router.navigateToUpload()
        } else {
            showBackConfirmation = true
        }
    }
 
    private func handleImageTap(transaction: Transaction) {
        guard let imageData = appState.receiptImageData(for: transaction),
              let image = UIImage(data: imageData) else {
            showSuccessToast("No receipt image available"); return
        }
        selectedImage = image
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showImageViewer = true }
        }
    }

    private func beginEditing(_ transaction: Transaction) {
        editingTransaction = transaction
        editName = transaction.merchant
        editAmount = String(format: "%.2f", transaction.amount)
        activeSheet = .editAmount
    }
 
    private func syncTransactionsToGroup(completion: @escaping ((success: Bool, count: Int, message: String)) -> Void) {
        guard groupManager.isGroupModeEnabled else {
            completion((false, 0, "Group mode not enabled"))
            return
        }
        
        guard let group = groupManager.activeGroup else {
            completion((false, 0, "No active group"))
            return
        }

        syncActiveGroupMembersForReview()
        
        var syncedCount = 0
        var failedCount = 0
        var failureReasons: [String] = []
        var syncedSourceTransactionIDs = Set<UUID>()
        var reviewExpenses: [GroupExpense] = []
        
        for transaction in appState.transactions {
            guard !transaction.splitWith.isEmpty else {
                failedCount += 1
                failureReasons.append("\(transaction.merchant): No split participants")
                continue
            }
            
            // Find payer in group members - match by ID first, then by isCurrentUser flag
            let payer = transaction.paidBy
            let payerMember: GroupMember
            
            if payer.isCurrentUser {
                // If payer is current user, find current user in group
                if let currentUserMember = group.members.first(where: { $0.isCurrentUser }) {
                    payerMember = currentUserMember
                } else {
                    failedCount += 1
                    failureReasons.append("\(transaction.merchant): Current user not in group")
                    continue
                }
            } else {
                // For other people, match by ID or phone number
                if let member = group.members.first(where: { $0.id == payer.id }) {
                    payerMember = member
                } else if let phone = payer.phoneNumber,
                          let member = group.members.first(where: { $0.phoneNumber == phone }) {
                    payerMember = member
                } else {
                    failedCount += 1
                    failureReasons.append("\(transaction.merchant): Payer \(payer.name) not in group")
                    continue
                }
            }
            
            // Find split participants in group members
            var splitMemberIDs: [UUID] = []
            
            for person in transaction.splitWith {
                if person.isCurrentUser {
                    // Current user - find by isCurrentUser flag
                    if let currentUserMember = group.members.first(where: { $0.isCurrentUser }) {
                        splitMemberIDs.append(currentUserMember.id)
                    }
                } else {
                    // Other people - match by ID or phone number
                    if let member = group.members.first(where: { $0.id == person.id }) {
                        splitMemberIDs.append(member.id)
                    } else if let phone = person.phoneNumber,
                              let member = group.members.first(where: { $0.phoneNumber == phone }) {
                        splitMemberIDs.append(member.id)
                    }
                }
            }
            
            guard !splitMemberIDs.isEmpty else {
                failedCount += 1
                failureReasons.append("\(transaction.merchant): No valid split participants")
                continue
            }
            
            // Create expense and immediately mark shares as pending (not paid)
            let newExpense = GroupExpense(
                groupID:       group.id,
                addedByID:     payerMember.id,
                addedByName:   payerMember.name,
                description:   transaction.merchant,
                amount:        transaction.amount,
                splitAmongIDs: splitMemberIDs,
                backgroundResultToken: transaction.backgroundResultToken,
                sourceTransactionID: transaction.id,
                sourceUploadSessionID: appState.uploadReviewSyncSessionID
            )
            
            reviewExpenses.append(newExpense)
            syncedSourceTransactionIDs.insert(transaction.id)
            syncedCount += 1
        }

        // Print summary
        if failedCount > 0 {
            print("⚠️ Failed to sync \(failedCount) transactions:")
            for reason in failureReasons.prefix(3) {
                print("  - \(reason)")
            }
            if failureReasons.count > 3 {
                print("  ... and \(failureReasons.count - 3) more")
            }
        }
        
        guard syncedCount > 0 else {
            completion((false, 0, "Failed to sync any transactions: \(failureReasons.first ?? "Unknown error")"))
            return
        }

        groupManager.syncReviewExpenses(
            reviewExpenses,
            keeping: syncedSourceTransactionIDs,
            uploadSessionID: appState.uploadReviewSyncSessionID,
            groupID: group.id
        ) { result in
            switch result {
            case .success(let persistedCount):
                print("✅ Synced \(persistedCount) transactions to group \(group.name)")
                let message = "Synced \(persistedCount)/\(appState.transactions.count) transactions"
                completion((true, persistedCount, message))
            case .failure(let error):
                let details = failureReasons.first.map { " \($0)" } ?? ""
                completion((false, 0, "Could not sync this split with your group.\(details) \(error.localizedDescription)"))
            }
        }
    }

    private func syncActiveGroupMembersForReview() {
        if groupManager.activeGroup == nil {
            groupManager.activateSubscriptionGroupForCurrentUser()
        }

        guard groupManager.isGroupModeEnabled, groupManager.activeGroup != nil else { return }
        groupManager.syncMembersToAppState(appState)
    }
     
    
    // MARK: - Breakdown helpers
 
    private func prepareBreakdownItems(
        _ raw: [ReceiptLineItem],
        receiptTotal: Double
    ) -> [ReceiptLineItem] {
        let totalKeywords: Set<String> = [
            "total","grand total","subtotal","sub total","sub-total",
            "amount due","balance due","amount paid","amount tendered",
            "grand total due","net total","order total","merch total",
            "merchandise total","item total","food total","sales total",
            "net sales","pre-tax total","before tax total","you paid",
            "total charged","total due","total amount","new total",
            "credit","visa credit","mc credit"
        ]
 
        func isTotalRow(_ item: ReceiptLineItem) -> Bool {
            let lower = item.name.lowercased().trimmingCharacters(in: .whitespaces)
            if !item.isSelected { return true }
            if totalKeywords.contains(lower) { return true }
            if lower.contains("subtotal") || lower.contains("sub total") { return true }
            return false
        }
 
        var filtered = raw.filter { !isTotalRow($0) && $0.category != .adjustment }
        filtered = filtered.filter { abs($0.amount) >= 0.01 }
        for i in filtered.indices { filtered[i].isSelected = true }
        filtered = removeNegatedItems(from: filtered)
 
        if receiptTotal > 0 {
            OCRService.enforceTotal(lineItems: &filtered, grandTotal: receiptTotal)
        }
        return filtered
    }
 
    private func removeNegatedItems(from items: [ReceiptLineItem]) -> [ReceiptLineItem] {
        let positives = items.enumerated().filter { $0.element.amount > 0 }
        let negatives = items.enumerated().filter { $0.element.amount < 0 }
        var indicesToRemove = Set<Int>()
        for (negIdx, negItem) in negatives {
            let target = (abs(negItem.amount) * 100).rounded() / 100
            if let exact = positives.first(where: { (($0.element.amount * 100).rounded() / 100) == target }) {
                indicesToRemove.insert(exact.offset); indicesToRemove.insert(negIdx); continue
            }
            if let combo = findExactCombination(
                items: positives.map { ($0.offset, $0.element.amount) }, target: target
            ) {
                combo.forEach { indicesToRemove.insert($0) }; indicesToRemove.insert(negIdx)
            }
        }
        return items.enumerated().filter { !indicesToRemove.contains($0.offset) }.map { $0.element }
    }
 
    private func findExactCombination(items: [(index: Int, amount: Double)], target: Double) -> [Int]? {
        let tCents = Int((target * 100).rounded())
        let inCents = items.map { (index: $0.index, cents: Int(($0.amount * 100).rounded())) }
        for size in 1...min(items.count, 5) {
            if let combo = findExactCombinationOfSize(inCents, target: tCents, size: size) { return combo }
        }
        return nil
    }
    private func findExactCombinationOfSize(_ items: [(index: Int, cents: Int)], target: Int, size: Int) -> [Int]? {
        var idx = Array(0..<items.count)
        return findCombinationRecursive(items, indices: &idx, target: target, size: size, start: 0, current: [])
    }
    private func findCombinationRecursive(
        _ items: [(index: Int, cents: Int)],
        indices: inout [Int], target: Int, size: Int, start: Int, current: [Int]
    ) -> [Int]? {
        if current.count == size {
            return current.reduce(0) { $0 + items[$1].cents } == target
                ? current.map { items[$0].index } : nil
        }
        for i in start..<items.count {
            var next = current; next.append(i)
            if next.reduce(0) { $0 + items[$1].cents } > target { continue }
            if let r = findCombinationRecursive(items, indices: &indices, target: target, size: size, start: i + 1, current: next) { return r }
        }
        return nil
    }
    
 
    

 
    private var mainContent: some View {
        VStack(spacing: 0) {
            headerSection
            
            QuickAssignBar(
                allPeople: appState.people,
                selectedMode: $selectedAssignMode,
                editMode: $quickEditMode,
                selectedPayerID: $selectedPayerID,
                isVisible: $showQuickAssignBar,
                onCustomTap: {
                    if case .custom(let people) = selectedAssignMode {
                        customSelectedPeople = Set(people.map { $0.id })
                    } else {
                        customSelectedPeople = []
                    }
                    activeSheet = .customPicker  // ← was showCustomPicker = true
                },
                onSelectAll: {
                    if quickEditMode == .paidBy {
                        applySelectedPayerToAllTransactions()
                    } else {
                        applyModeToAllTransactions()
                    }
                },
                onDeselectAll: {
                    if quickEditMode == .paidBy {
                        resetPayersToCurrentUser()
                    } else {
                        deselectAllTransactions()
                    }
                },
                isQuickModeEnabled: $isQuickModeEnabled
            )
            .tutorialSpotlight(isHighlighted: shouldHighlightQuickAssignBar, cornerRadius: 2)
            
            dashedDivider
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    if !appState.transactions.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("ITEMS · \(appState.transactions.count) TRANSACTION\(appState.transactions.count == 1 ? "" : "S")")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(ink.opacity(0.65))
                                    .tracking(1.5)

                                if unassignedTransactionCount > 0 {
                                    Text("\(unassignedTransactionCount) need split people")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))
                                }
                            }

                            Spacer()

                            if !ocrConfidenceWarnings.isEmpty {
                                Text("VALUE REVIEW")
                                    .font(.system(size: 8, weight: .black))
                                    .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))
                                    .tracking(0.8)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color(red: 1.0, green: 0.96, blue: 0.88))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color(red: 0.53, green: 0.24, blue: 0.08).opacity(0.26), lineWidth: 1)
                                    )
                            }

                            Button(action: {
                                HapticManager.impact(style: .light)
                                activeSheet = .tip
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 8, weight: .bold))
                                    Text("TIP")
                                        .font(.system(size: 9, weight: .bold))
                                        .tracking(1.2)
                                }
                                .foregroundColor(ink.opacity(0.72))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(ink.opacity(0.22), lineWidth: 1)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.97))
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                    }

                    if isQuickModeEnabled {
                        quickModeTransactionGrid
                    } else {
                        ForEach(Array($appState.transactions.enumerated()), id: \.element.id) { index, $transaction in
                            TransactionCardView_QuickAssign(
                                transaction:       $transaction,
                                allPeople:         appState.people,
                                currentAssignMode: selectedAssignMode,
                                quickEditMode: quickEditMode,
                                selectedPayer: selectedPayer,
                                hasReceiptImage:    transactionHasReceiptImageHint(transaction),
                                startsExpanded: transaction.sourceDocumentType == .receipt
                                    || transaction.sourceDocumentType == .statement
                                    || transactionHasReceiptImageHint(transaction),
                                requiresOCRReview: transactionRequiresOCRReview(transaction),
                                onQuickAssign: { applyQuickAction(to: transaction) },
                                onDelete:      { deleteTransaction(transaction) },
                                onEdit: { beginEditing(transaction) },
                                onImageTap:  { handleImageTap(transaction: transaction) },
                                onBreakdown: canShowBreakdown(for: transaction) ? {
                                    handleBreakdown(transaction: transaction)  // handleBreakdown sets activeSheet = .breakdown internally
                                } : nil,
                                onAdvancedSplit: {
                                    activeSheet = .advancedSplit(transaction)  // ← was advancedSplitTarget = transaction
                                }
                            )
                            .padding(.horizontal, 20)
                            .tutorialSpotlight(
                                isHighlighted: shouldHighlightTransaction && index == 0,
                                cornerRadius: 2
                            )
                            .tutorialSpotlight(
                                isHighlighted: shouldHighlightItemCard && index == 0,
                                cornerRadius: 2
                            )
                        }
                    }

                    addManuallyButton
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
                .padding(.bottom, 100)
            }
            
            bottomButton
        }
    }

    private var reviewOverviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REVIEW TOTAL")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(ink.opacity(0.52))
                        .tracking(1.6)

                    Text(formattedDollar(transactionGrandTotal))
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text(reviewReadyStatusText)
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(unassignedTransactionCount == 0 ? Color(red: 0.16, green: 0.38, blue: 0.16) : Color(red: 0.53, green: 0.24, blue: 0.08))
                        .tracking(0.7)

                    Text("\(appState.transactions.count) TRANSACTION\(appState.transactions.count == 1 ? "" : "S")")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(ink.opacity(0.55))
                        .tracking(0.8)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    reviewChip("\(appState.people.count) PEOPLE")
                    if receiptBackedTransactionCount > 0 {
                        reviewChip("\(receiptBackedTransactionCount) RECEIPT\(receiptBackedTransactionCount == 1 ? "" : "S")")
                    }
                    if statementBackedTransactionCount > 0 {
                        reviewChip("\(statementBackedTransactionCount) STATEMENT\(statementBackedTransactionCount == 1 ? "" : "S")")
                    }
                    if !itemsBySplitType.isEmpty {
                        reviewChip("\(itemsBySplitType.count) SPLIT TYPE\(itemsBySplitType.count == 1 ? "" : "S")")
                    }
                }
            }

            if shouldPreferSpeedMode {
                reviewNotice(
                    icon: "bolt.fill",
                    title: "Speed review is on",
                    detail: "Large uploads stay fast here. Tap a row to apply the selected split or payer, or use the row menu for edits."
                )
            }

            if let warning = ocrConfidenceWarnings.first {
                reviewNotice(
                    icon: "exclamationmark.triangle.fill",
                    title: warning.title,
                    detail: warning.detail
                )
            }
        }
        .padding(16)
        .background(ivory)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(ink.opacity(0.18), lineWidth: 1.5)
        )
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func reviewChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(ink.opacity(0.62))
            .tracking(0.8)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(parchment.opacity(0.40))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(0.14), lineWidth: 1)
            )
    }

    private func reviewNotice(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(ink)
                    .tracking(0.8)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(red: 1.0, green: 0.96, blue: 0.88))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color(red: 0.53, green: 0.24, blue: 0.08).opacity(0.22), lineWidth: 1)
        )
    }


    private struct OCRConfidenceWarning: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    private var ocrConfidenceWarnings: [OCRConfidenceWarning] {
        var warnings: [OCRConfidenceWarning] = []

        for receipt in appState.uploadedReceipts {
            let label = receipt.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Receipt"
                : receipt.merchant

            if receipt.ocrNeedsReview || receipt.ocrConfidence < 0.78 || receipt.ocrQualityScore < 0.72 {
                warnings.append(
                    OCRConfidenceWarning(
                        title: "Item values need review",
                        detail: "\(label) scan confidence is \(confidencePercent(receipt.ocrConfidence)). Confirm item names, prices, and discounts before settling."
                    )
                )
            }

            if receipt.ocrValidationStatus == .mismatch {
                let gap = Double(abs(receipt.ocrArithmeticGapCents)) / 100.0
                warnings.append(
                    OCRConfidenceWarning(
                        title: "Receipt total may not match",
                        detail: "Dutch found a \(formattedDollar(gap)) difference between detected items and the receipt total."
                    )
                )
            }

            for issue in receipt.ocrValidationIssues.prefix(2) {
                warnings.append(
                    OCRConfidenceWarning(
                        title: "Value review note",
                        detail: readableOCRIssue(issue)
                    )
                )
            }
        }

        let statements = appState.uploadedTransactions ?? []
        for statement in statements where statement.confidence < 0.78 {
            let label = statement.dateFilterLabel?.isEmpty == false
                ? "Statement \(statement.dateFilterLabel ?? "")"
                : "Statement"
            warnings.append(
                OCRConfidenceWarning(
                    title: "Statement values need review",
                    detail: "\(label) scan confidence is \(confidencePercent(statement.confidence)). Confirm the transaction rows and total before settling."
                )
            )
        }

        return Array(warnings.prefix(4))
    }

    private func transactionRequiresOCRReview(_ transaction: Transaction) -> Bool {
        switch transaction.sourceDocumentType {
        case .manual:
            return false
        case .receipt:
            if let token = transaction.backgroundResultToken,
               let receipt = appState.uploadedReceipts.first(where: { $0.backgroundResultToken == token }) {
                return receiptRequiresOCRReview(receipt)
            }

            return appState.uploadedReceipts.contains { receipt in
                receiptRequiresOCRReview(receipt) &&
                abs(receipt.total - transaction.amount) < 0.01 &&
                receipt.merchant.caseInsensitiveCompare(transaction.merchant) == .orderedSame
            }
        case .statement:
            return (appState.uploadedTransactions ?? []).contains { statement in
                statement.confidence < 0.78 &&
                abs(statementReviewTotal(statement) - transaction.amount) < 0.01
            }
        }
    }

    private func receiptRequiresOCRReview(_ receipt: UploadedReceipt) -> Bool {
        receipt.ocrNeedsReview ||
        receipt.ocrConfidence < 0.78 ||
        receipt.ocrQualityScore < 0.72 ||
        receipt.ocrValidationStatus == .mismatch ||
        !receipt.ocrValidationIssues.isEmpty
    }

    private func statementReviewTotal(_ statement: UploadedTransaction) -> Double {
        if statement.totalDebits > 0 {
            return statement.totalDebits
        }

        return statement.items.reduce(0.0) { total, item in
            total + (item.isDebit ? abs(item.amount) : 0)
        }
    }

    private var ocrConfidenceWarningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))

                Text("VALUE REVIEW SUGGESTED")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))
                    .tracking(1.4)

                Spacer()
            }

            ForEach(ocrConfidenceWarnings) { warning in
                VStack(alignment: .leading, spacing: 4) {
                    Text(warning.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(ink)

                    Text(warning.detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ink.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(Color(red: 1.0, green: 0.96, blue: 0.88))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color(red: 0.53, green: 0.24, blue: 0.08).opacity(0.35), lineWidth: 1.5)
        )
    }

    private func confidencePercent(_ confidence: Float) -> String {
        "\(Int((max(0, min(confidence, 1)) * 100).rounded()))%"
    }

    private func formattedDollar(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    private func readableOCRIssue(_ issue: String) -> String {
        if issue.hasPrefix("arithmetic_gap_") {
            return "Detected item totals differ from the receipt total. Review discounts, tax, fees, and adjustments."
        }
        return issue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private var addManuallyButton: some View {
        Button(action: { activeSheet = .manualAdd }) {  // ← was showManualAdd = true
            HStack(spacing: 10) {
                Text("+")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(ink)
                Text("ADD MANUALLY")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(ink)
                    .tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    .foregroundColor(ink.opacity(0.30))
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }

    private func inferredDocumentType(for transaction: Transaction) -> TransactionSourceDocumentType {
        if transaction.sourceDocumentType == .statement || transaction.sourceDocumentType == .manual {
            return transaction.sourceDocumentType
        }

        let merchant = transaction.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedMerchant = merchant.lowercased()
        if lowercasedMerchant.contains("statement")
            || lowercasedMerchant.contains("bank activity")
            || lowercasedMerchant.contains("account activity")
            || lowercasedMerchant.contains("transaction history") {
            return .statement
        }

        return transaction.sourceDocumentType
    }

    private func handleBreakdown(transaction: Transaction) {
        print("🔍 handleBreakdown called")
        print("🔍 transaction.merchant: \(transaction.merchant)")
        print("🔍 transaction.receiptImage: \(transaction.receiptImage != nil ? "PRESENT (\(transaction.receiptImage!.count) bytes)" : "NIL")")

        let resolvedImage = appState.receiptImageData(for: transaction)
        var resolvedTransaction = transaction
        resolvedTransaction.receiptImage = resolvedImage
        let resolvedDocumentType = inferredDocumentType(for: resolvedTransaction)
        resolvedTransaction.sourceDocumentType = resolvedDocumentType
        if let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) {
            appState.transactions[index].sourceDocumentType = resolvedDocumentType
            if let resolvedImage, appState.transactions[index].receiptImage?.isEmpty != false {
                appState.transactions[index].receiptImage = resolvedImage
            }
        }

        breakdownTransaction  = resolvedTransaction
        breakdownReceiptImage = resolvedImage
        breakdownDocumentType = resolvedDocumentType

        if !transaction.lineItems.isEmpty {
            let prepared = prepareBreakdownItems(transaction.lineItems, receiptTotal: transaction.amount)
            detectedLineItems      = prepared
            breakdownQuickTotal    = transaction.amount
            breakdownQuickMerchant = transaction.merchant
            isProcessingBreakdown  = false
            activeSheet            = .breakdown  // ← was showBreakdownSheet = true
            return
        }

        guard resolvedImage != nil else {
            showSuccessToast(resolvedDocumentType == .statement ? "No statement breakdown available" : "No receipt breakdown available"); return
        }

        detectedLineItems      = []
        breakdownQuickTotal    = transaction.amount
        breakdownQuickMerchant = transaction.merchant
        isProcessingBreakdown  = true
        activeSheet            = .breakdown  // ← was showBreakdownSheet = true
        runFreshOCR(for: resolvedTransaction)
    }

    private func canShowBreakdown(for transaction: Transaction) -> Bool {
        guard !transaction.isManual && !transaction.isBreakdownChild else { return false }
        if !transaction.lineItems.isEmpty { return true }
        return transactionHasReceiptImageHint(transaction)
    }

    private func transactionHasReceiptImageHint(_ transaction: Transaction) -> Bool {
        if let receiptImage = transaction.receiptImage, !receiptImage.isEmpty { return true }
        if transaction.backgroundResultToken != nil { return true }
        return transaction.sourceDocumentType == .receipt
    }

    private func runFreshOCR(for transaction: Transaction) {
        guard let imageData = appState.receiptImageData(for: transaction),
              let image     = UIImage(data: imageData) else {
            activeSheet = nil  // ← was showBreakdownSheet = false
            showSuccessToast("No receipt image available")
            return
        }

        OCRService.extractText(from: image) { result in
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    self.isProcessingBreakdown = false
                }
                switch result {
                case .success(let data):
                    guard (data.grandTotal ?? transaction.amount) > 0 else {
                        self.activeSheet = nil
                        self.showSuccessToast("Retake closer to the items, straight-on, and not tilted.")
                        return
                    }
                    let prepared = self.prepareBreakdownItems(
                        data.lineItems,
                        receiptTotal: data.grandTotal ?? transaction.amount
                    )
                    guard !prepared.isEmpty else {
                        self.activeSheet = nil  // ← was showBreakdownSheet = false
                        self.showSuccessToast("Retake closer to the items, straight-on, and not tilted.")
                        return
                    }
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        self.detectedLineItems      = prepared
                        self.breakdownQuickTotal    = data.grandTotal ?? transaction.amount
                        self.breakdownQuickMerchant = data.merchant.isEmpty ? transaction.merchant : data.merchant
                    }
                    if let idx = self.appState.transactions.firstIndex(where: { $0.id == transaction.id }) {
                        self.appState.transactions[idx].lineItems = prepared
                    }
                case .failure:
                    self.activeSheet = nil  // ← was showBreakdownSheet = false
                    self.showSuccessToast(transaction.sourceDocumentType == .statement ? "No transactions found on this statement" : "No line items found on this receipt")
                }
            }
        }
    }

    private func applyBreakdown() {
        guard let transaction = breakdownTransaction,
              let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }

        let originalTransaction = appState.transactions.remove(at: index)
        let selectedItems       = detectedLineItems.filter { $0.isSelected && $0.amount > 0.009 }
        let isTutorial          = tutorialManager.isActive
        let inheritedReceiptImage = appState.receiptImageData(for: originalTransaction)
            ?? transaction.receiptImage
            ?? breakdownReceiptImage

        guard !selectedItems.isEmpty else {
            appState.transactions.insert(originalTransaction, at: index)
            showSuccessToast("Retake closer to the items, straight-on, and not tilted.")
            return
        }

        for (itemIndex, item) in selectedItems.enumerated() {
            let name = item.name.isEmpty ? originalTransaction.merchant : item.name
            let splitWith: [Person] = isTutorial
                ? (itemIndex < 3 ? appState.people : [])
                : appState.people

            appState.transactions.append(Transaction(
                amount:         item.amount,
                merchant:       name,
                paidBy:         originalTransaction.paidBy,
                splitWith:      splitWith,
                receiptImage:   inheritedReceiptImage,
                includeInSplit: true,
                isManual:       false,
                backgroundResultToken: originalTransaction.backgroundResultToken,
                lineItems:      [],
                receiptDate:    originalTransaction.receiptDate,
                currency:       originalTransaction.currency,
                isBreakdownChild: true,
                sourceDocumentType: originalTransaction.sourceDocumentType
            ))
        }

        if tutorialManager.isActive {
            activeSheet = nil  // ← was showBreakdownSheet = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                tutorialManager.advanceToPostBreakdown()
            }
        } else {
            activeSheet = nil  // ← was showBreakdownSheet = false
            let total = selectedItems.count
            let noun = originalTransaction.sourceDocumentType == .statement ? "transaction" : "item"
            let document = originalTransaction.sourceDocumentType == .statement ? "Statement" : "Receipt"
            showSuccessToast("\(document) broken down into \(total) \(noun)\(total == 1 ? "" : "s")")
        }
    }

    private func saveEditedTransaction() {
        guard let transaction = editingTransaction,
              let amount = Double(editAmount), amount > 0,
              !editName.trimmingCharacters(in: .whitespaces).isEmpty,
              let index  = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        appState.transactions[index].amount   = amount
        appState.transactions[index].merchant = editName.trimmingCharacters(in: .whitespaces)
        activeSheet        = nil  // ← was showEditAmount = false
        editingTransaction = nil
        editAmount         = ""
        editName           = ""
    }

    private func addManualTransaction() {
        guard !manualMerchant.isEmpty, let amount = Double(manualAmount), amount > 0 else { return }
        let transaction = Transaction(
            amount:    amount,
            merchant:  manualMerchant,
            paidBy:    appState.people.first(where: { $0.isCurrentUser }) ?? appState.people[0],
            splitWith: appState.people,
            isManual:  true,
            lineItems: [],
            sourceDocumentType: .manual
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appState.transactions.append(transaction) }
        activeSheet     = nil  // ← was showManualAdd = false
        manualMerchant  = ""
        manualAmount    = ""
    }

    private func addTipTransaction(_ amount: Double) {
        guard amount > 0 else { return }
        let transaction = Transaction(
            amount: (amount * 100).rounded() / 100,
            merchant: "Tip",
            paidBy: appState.people.first(where: { $0.isCurrentUser }) ?? appState.people[0],
            splitWith: appState.people,
            isManual: true,
            lineItems: [],
            sourceDocumentType: .manual
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            appState.transactions.append(transaction)
        }
        showSuccessToast("Tip added")
    }
 
    private func applyAdvancedSplit(to transaction: Transaction, quantities: [PersonQuantity]) {
        guard let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        appState.transactions[index].splitWith = quantities.map(\.person)
        var quantityMap: [UUID: Int] = [:]
        for pq in quantities { quantityMap[pq.person.id] = pq.quantity }
        appState.transactions[index].splitQuantities = quantityMap
 
        let totalUnits = quantities.reduce(0) { $0 + $1.quantity }
        let summary = quantities.map { pq -> String in
            let pct = totalUnits > 0 ? Int((Double(pq.quantity) / Double(totalUnits) * 100).rounded()) : 0
            return "\(pq.person.name): \(pct)%"
        }.joined(separator: "  ·  ")
        showSuccessToast("Split applied — \(summary)")
    }
 
  
 
   
 
    private func deleteTransaction(_ transaction: Transaction) {
        guard let index = appState.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        let deleted = appState.transactions[index]
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { _ = appState.transactions.remove(at: index) }
        toastMessage = "Transaction removed"
        undoAction = {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appState.transactions.insert(deleted, at: index) }
            hideToast()
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { hideToast() }
    }
 
    private func showSuccessToast(_ message: String) {
        toastMessage = message; undoAction = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { hideToast() }
    }
 
    private func hideToast() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showToast = false; undoAction = nil }
    }
}
 
// MARK: - Quick Mode Transaction Cell (Spreadsheet Style)
//
// INTERACTION MODEL:
// - Tap anywhere on row → assign current preset
// - Swipe right → assign current preset
// - Swipe left → clear assignment
// - Optimized for speed with comfortable touch targets
 
struct QuickModeTransactionCell: View {
    @Binding var transaction: Transaction
    let allPeople: [Person]
    let currentAssignMode: ReviewView.AssignMode
    let editMode: ReviewView.QuickEditMode
    let requiresValueReview: Bool
    let canViewImage: Bool
    let canShowBreakdown: Bool
    let onQuickAssign: () -> Void
    let onEdit: () -> Void
    let onImageTap: () -> Void
    let onBreakdown: () -> Void
    let onAdvancedSplit: () -> Void
    let onDelete: () -> Void
    
    @State private var dragOffset: CGFloat = 0
    
    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
    private let greenInk = Color(red: 0.16, green: 0.38, blue: 0.16)
    
    private var assignmentText: String {
        if transaction.splitWith.isEmpty {
            return "Tap to assign"
        } else if transaction.splitWith.count == allPeople.count {
            return "All (\(allPeople.count))"
        } else if transaction.splitWith.count == 1 {
            return transaction.splitWith[0].name
        } else {
            return transaction.splitWith.map { $0.name }.joined(separator: ", ")
        }
    }

    private var statusText: String {
        switch editMode {
        case .splitWith:
            return assignmentText
        case .paidBy:
            return transaction.paidBy.isCurrentUser ? "You" : transaction.paidBy.name
        }
    }

    private var statusIsEmpty: Bool {
        editMode == .splitWith && transaction.splitWith.isEmpty
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Button(action: {
                HapticManager.impact(style: .light)
                onQuickAssign()
            }) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(transaction.merchant)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(ink)
                            .lineLimit(1)

                        if requiresValueReview {
                            Text("VALUE REVIEW")
                                .font(.system(size: 7, weight: .black))
                                .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))
                                .tracking(0.7)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(String(format: "$%.2f", transaction.amount))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(ink)
                        .frame(minWidth: 60, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 2) {
                        if editMode == .paidBy {
                            Text("PAID BY")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(ink.opacity(0.42))
                                .tracking(0.7)
                        }
                        Text(statusText)
                            .font(.system(size: 13, weight: statusIsEmpty ? .regular : .semibold))
                            .foregroundColor(statusIsEmpty ? ink.opacity(0.48) : greenInk)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusIsEmpty ? parchment.opacity(0.30) : greenInk.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(statusIsEmpty ? ink.opacity(0.14) : greenInk.opacity(0.28), lineWidth: 1)
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Edit Name or Amount", action: onEdit)
                Button("Advanced Split", action: onAdvancedSplit)
                if canViewImage {
                    Button("View Receipt", action: onImageTap)
                }
                if canShowBreakdown {
                    Button(transaction.sourceDocumentType == .statement ? "Statement Breakdown" : "Receipt Breakdown", action: onBreakdown)
                }
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ink.opacity(0.62))
                    .frame(width: 34, height: 34)
                    .background(parchment.opacity(0.34))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(ink.opacity(0.14), lineWidth: 1)
                    )
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(transaction.splitWith.isEmpty ? ivory : parchment.opacity(0.20))
        .offset(x: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    // Only allow horizontal drag
                    if abs(value.translation.width) > abs(value.translation.height) {
                        dragOffset = value.translation.width
                    }
                }
                .onEnded { value in
                    let threshold: CGFloat = 60
                    
                    if value.translation.width > threshold {
                        // Swipe right → assign
                        HapticManager.impact(style: .medium)
                        onQuickAssign()
                    } else if value.translation.width < -threshold {
                        // Swipe left → clear
                        HapticManager.impact(style: .light)
                        // Trigger clear via parent
                    }
                    
                    // Reset position with animation
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        dragOffset = 0
                    }
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
    }

}
 
// MARK: - Quick Assign Bar Component
 
struct QuickAssignBar: View {
    let allPeople: [Person]
    @Binding var selectedMode: ReviewView.AssignMode
    @Binding var editMode: ReviewView.QuickEditMode
    @Binding var selectedPayerID: UUID?
    @Binding var isVisible: Bool
    let onCustomTap: () -> Void
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    @Binding var isQuickModeEnabled: Bool
    
    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)

    private var selectedTargetLabel: String {
        switch editMode {
        case .splitWith:
            switch selectedMode {
            case .splitAll:
                return "Tap rows to split with everyone"
            case .currentUser:
                return "Tap rows to assign to you"
            case .specific(let person):
                return "Tap rows to assign to \(person.isCurrentUser ? "you" : person.name)"
            case .custom(let people):
                if people.isEmpty { return "Choose people for custom split" }
                return "Tap rows for custom split with \(people.count)"
            }
        case .paidBy:
            if let selectedPayerID,
               let person = allPeople.first(where: { $0.id == selectedPayerID }) {
                return "Tap rows paid by \(person.isCurrentUser ? "you" : person.name)"
            }
            return "Tap rows to set who paid"
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(editMode == .paidBy ? "WHO PAID" : "WHO SPLITS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(ink.opacity(0.48))
                            .tracking(1.4)
                        if isVisible {
                            Text(selectedTargetLabel)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(ink.opacity(0.78))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        } else {
                            Text(editMode == .paidBy ? "Paid by \(compactPayerLabel)" : selectedMode.label)
                                .font(.system(size: 12, weight: .black))
                                .foregroundColor(ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }
                    
                    Spacer()

                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            isQuickModeEnabled.toggle()
                        }
                        HapticManager.impact(style: .medium)
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: isQuickModeEnabled ? "bolt.fill" : "bolt")
                                .font(.system(size: 9, weight: .bold))
                            Text("SPEED")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.8)
                        }
                        .foregroundColor(isQuickModeEnabled ? ivory : ink.opacity(0.62))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isQuickModeEnabled ? ink : ivory)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(isQuickModeEnabled ? ink : ink.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.95))

                    Button(action: { withAnimation(.spring(response: 0.3)) { isVisible.toggle() } }) {
                        Image(systemName: isVisible ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(ink.opacity(0.48))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                
                if isVisible {
                    HStack(spacing: 0) {
                        quickModeButton("SPLIT WITH", mode: .splitWith)
                        quickModeButton("PAID BY", mode: .paidBy)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(ink.opacity(0.16), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isVisible ? 12 : 9)
            .background(parchment.opacity(0.50))
            
            if isVisible {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if editMode == .splitWith {
                                assignButton(
                                    mode: .splitAll,
                                    label: "Split All",
                                    icon: "person.2.fill"
                                )

                                if allPeople.contains(where: { $0.isCurrentUser }) {
                                    assignButton(
                                        mode: .currentUser,
                                        label: "Me",
                                        icon: "person.fill"
                                    )

                                    ForEach(allPeople.filter { !$0.isCurrentUser }) { person in
                                        assignButton(
                                            mode: .specific(person),
                                            label: person.name,
                                            icon: nil
                                        )
                                    }
                                }

                                if allPeople.count > 2 {
                                    Button(action: {
                                        HapticManager.impact(style: .light)
                                        onCustomTap()
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.system(size: 10, weight: .semibold))
                                            if case .custom(let people) = selectedMode, !people.isEmpty {
                                                Text("CUSTOM (\(people.count))")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .tracking(0.8)
                                            } else {
                                                Text("CUSTOM")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .tracking(0.8)
                                            }
                                        }
                                        .foregroundColor(ink)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(parchment.opacity(0.40))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(ink.opacity(0.20), lineWidth: 1.5)
                                        )
                                    }
                                    .buttonStyle(ScaleButtonStyle(scale: 0.95))
                                }
                            } else {
                                ForEach(allPeople) { person in
                                    payerButton(person)
                                }

                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    
                    HStack(spacing: 8) {
                        bulkActionButton(
                            label: editMode == .paidBy ? "Apply payer to all" : "Select all",
                            icon: "checkmark.circle.fill",
                            action: onSelectAll
                        )

                        bulkActionButton(
                            label: editMode == .paidBy ? "Reset payer" : "Clear splits",
                            icon: "xmark.circle.fill",
                            action: onDeselectAll
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                .background(ivory)
            }
        }
        .overlay(
            Rectangle()
                .fill(ink.opacity(0.14))
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    private func quickModeButton(_ label: String, mode: ReviewView.QuickEditMode) -> some View {
        let selected = editMode == mode
        return Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.25)) {
                editMode = mode
                if mode == .paidBy,
                   selectedPayerID == nil,
                   let currentUser = allPeople.first(where: { $0.isCurrentUser }) {
                    selectedPayerID = currentUser.id
                }
            }
        }) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.7)
                .foregroundColor(selected ? ivory : ink.opacity(0.58))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(selected ? ink : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func bulkActionButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            HapticManager.impact(style: .medium)
            action()
        }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundColor(ink.opacity(0.65))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(parchment.opacity(0.24))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(0.16), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.95))
    }

    private func payerButton(_ person: Person) -> some View {
        let isSelected = selectedPayerID == person.id || (selectedPayerID == nil && person.isCurrentUser)

        return Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.25)) {
                selectedPayerID = person.id
            }
        }) {
            HStack(spacing: 7) {
                AvatarView(imageData: person.contactImage, initials: person.initials, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.isCurrentUser ? "You" : person.name)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .lineLimit(1)
                    Text("paid")
                        .font(.system(size: 7, weight: .bold))
                        .tracking(0.7)
                        .opacity(0.65)
                }
            }
            .foregroundColor(isSelected ? ivory : ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? ink : parchment.opacity(0.40))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? ink : ink.opacity(0.20), lineWidth: 1.5)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.95))
    }

    private func assignButton(mode: ReviewView.AssignMode, label: String, icon: String?) -> some View {
        let isSelected = selectedMode == mode
        let isPendingInvite: Bool = {
            if case .specific(let person) = mode {
                return person.isPendingGroupMember == true
            }
            return false
        }()
        
        return Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.25)) {
                selectedMode = mode
            }
        }) {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(label.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                }
                if isPendingInvite {
                    Text("INVITED")
                        .font(.system(size: 7, weight: .bold))
                        .tracking(0.5)
                }
            }
            .foregroundColor(isSelected ? ivory : ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? ink : parchment.opacity(0.40))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? ink : ink.opacity(0.20), lineWidth: 1.5)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.95))
    }

    private var compactPayerLabel: String {
        if let selectedPayerID,
           let person = allPeople.first(where: { $0.id == selectedPayerID }) {
            return person.isCurrentUser ? "You" : person.name
        }
        if allPeople.contains(where: { $0.isCurrentUser }) {
            return "You"
        }
        return allPeople.first?.name ?? "You"
    }
}
 
 
// MARK: - Custom People Picker Sheet
 
struct CustomPeoplePickerSheet: View {
    let allPeople: [Person]
    @Binding var selectedPeople: Set<UUID>
    let onApply: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let cream = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
    
    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            NavigationView {
                ZStack {
                    ivory.ignoresSafeArea()
                    VStack(spacing: 0) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SELECT PEOPLE")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(ink)
                                .tracking(0.5)
                            Text("Choose who to include in this custom split")
                                .font(.system(size: 12))
                                .foregroundColor(ink.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(parchment)
                        
                        dashedDivider
                        
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(allPeople) { person in
                                    personRow(person: person)
                                    if person.id != allPeople.last?.id {
                                        Divider().background(ink.opacity(0.06))
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                        }
                        
                        applyButton
                    }
                }
                .navigationTitle("")
                .navigationBarHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { dismiss() }) {
                            Text("CANCEL")
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.5)
                                .foregroundColor(ink.opacity(0.55))
                        }
                    }
                }
            }
        }
    }
    
    private var dashedDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        let dashWidth: CGFloat = 5
                        let dashGap: CGFloat = 5
                        var x: CGFloat = 0
                        while x < geometry.size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: min(x + dashWidth, geometry.size.width), y: 0))
                            x += dashWidth + dashGap
                        }
                    }
                    .stroke(ink, lineWidth: 1.5)
                }
            )
    }
    
    private func personRow(person: Person) -> some View {
        let isSelected = selectedPeople.contains(person.id)
        
        return Button(action: {
            withAnimation(.spring(response: 0.25)) {
                if isSelected {
                    selectedPeople.remove(person.id)
                } else {
                    selectedPeople.insert(person.id)
                }
            }
            HapticManager.impact(style: .light)
        }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? ink : Color.clear)
                        .frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 1)
                        .stroke(ink, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                
                AvatarView(imageData: person.contactImage, initials: person.initials, size: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(ink)

                    if person.isPendingGroupMember == true {
                        Text("Invited, not joined yet")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                    }
                }
                
                Spacer()
                
                if person.isCurrentUser {
                    Text("YOU")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(ink.opacity(0.48))
                        .tracking(1.5)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(parchment.opacity(0.60))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.20), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(isSelected ? parchment.opacity(0.30) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var applyButton: some View {
        VStack(spacing: 0) {
            dashedDivider
            
            Button(action: {
                onApply()
                dismiss()
            }) {
                HStack(spacing: 8) {
                    Text(selectedPeople.isEmpty ? "SELECT AT LEAST ONE PERSON" : "APPLY SELECTION · \(selectedPeople.count) \(selectedPeople.count == 1 ? "PERSON" : "PEOPLE")")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1)
                    if !selectedPeople.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundColor(selectedPeople.isEmpty ? ink.opacity(0.28) : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(selectedPeople.isEmpty ? ink.opacity(0.08) : ink)
                .cornerRadius(3)
            }
            .disabled(selectedPeople.isEmpty)
            .padding(20)
            .background(ivory)
        }
    }
}
 
// MARK: - Live Split Summary Component
 
struct LiveSplitSummary: View {
    let itemsBySplitType: [(label: String, count: Int)]
    
    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("CURRENT SPLIT")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(1.5)
                
                Spacer()
                
                if itemsBySplitType.isEmpty {
                    Text("NO ITEMS YET")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(ink.opacity(0.28))
                        .tracking(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(parchment.opacity(0.50))
            
            if !itemsBySplitType.isEmpty {
                VStack(spacing: 0) {
                    ForEach(itemsBySplitType, id: \.label) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(ink.opacity(0.65))
                                .frame(width: 4, height: 4)
                            
                            Text(item.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ink)
                            
                            Spacer()
                            
                            Text("\(item.count) item\(item.count == 1 ? "" : "s")")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(ink.opacity(0.55))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        
                        if item.label != itemsBySplitType.last?.label {
                            Divider()
                                .background(ink.opacity(0.06))
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .background(ivory)
            }
        }
        .overlay(
            Rectangle()
                .fill(ink.opacity(0.14))
                .frame(height: 1),
            alignment: .top
        )
        .animation(.spring(response: 0.3), value: itemsBySplitType.count)
    }

}
 
// MARK: - Enhanced Transaction Card with Quick Assign
 
struct TransactionCardView_QuickAssign: View {
    @Binding var transaction: Transaction
    let allPeople: [Person]
    let currentAssignMode: ReviewView.AssignMode
    let quickEditMode: ReviewView.QuickEditMode
    let selectedPayer: Person
    let hasReceiptImage: Bool
    let startsExpanded: Bool
    let requiresOCRReview: Bool
    let onQuickAssign: () -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onImageTap: () -> Void
    let onBreakdown: (() -> Void)?
    let onAdvancedSplit: () -> Void
    
    @State private var isExpanded = false
    
    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
    
    var body: some View {
        VStack(spacing: 0) {
            // Quick assign tap area
            Button(action: {
                HapticManager.impact(style: .light)
                onQuickAssign()
            }) {
                VStack(spacing: 12) {
                    // Header row
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transaction.merchant.uppercased())
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(ink)
                                .tracking(0.3)
                            
                            Text(String(format: "$%.2f", transaction.amount))
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(ink)

                            if requiresOCRReview {
                                Text("ITEM VALUE REVIEW")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))
                                    .tracking(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color(red: 1.0, green: 0.96, blue: 0.88))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(Color(red: 0.53, green: 0.24, blue: 0.08).opacity(0.32), lineWidth: 1)
                                    )
                            }
                        }
                        
                        Spacer()
                        
                        // Quick assign indicator
                        VStack(spacing: 4) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(ink.opacity(0.38))
                            Text(quickEditMode == .paidBy ? "TAP PAID BY" : "TAP TO ASSIGN")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(ink.opacity(0.38))
                                .tracking(1)
                        }
                    }
                    
                    // Current assignment
                    if !transaction.splitWith.isEmpty {
                        HStack(spacing: 6) {
                            Text("SPLIT WITH:")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(ink.opacity(0.48))
                                .tracking(1.5)
                            
                            Text(transaction.splitWith.map(\.name).joined(separator: ", "))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(ink.opacity(0.65))
                            
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(parchment.opacity(0.40))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.10), lineWidth: 1)
                        )
                    }

                    HStack(spacing: 6) {
                        Text("PAID BY:")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(ink.opacity(0.48))
                            .tracking(1.5)

                        AvatarView(imageData: transaction.paidBy.contactImage, initials: transaction.paidBy.initials, size: 18)

                        Text(transaction.paidBy.isCurrentUser ? "You" : transaction.paidBy.name)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(ink.opacity(0.70))
                            .lineLimit(1)

                        Spacer()

                        if quickEditMode == .paidBy {
                            Text(selectedPayer.isCurrentUser ? "Tap to set You" : "Tap to set \(selectedPayer.name)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(ink.opacity(0.42))
                                .tracking(0.5)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(quickEditMode == .paidBy ? Color(red: 0.16, green: 0.38, blue: 0.16).opacity(0.08) : parchment.opacity(0.26))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(quickEditMode == .paidBy ? Color(red: 0.16, green: 0.38, blue: 0.16).opacity(0.22) : ink.opacity(0.10), lineWidth: 1)
                    )
                }
                .padding(16)
                .background(ivory)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.98))
            
            // Expand/collapse for more options
            if isExpanded {
                VStack(spacing: 8) {
                    Divider().background(ink.opacity(0.10))

                    // Top row: Advanced Split, View Receipt, Edit
                    HStack(spacing: 8) {
                        if hasReceiptImage {
                            // Has receipt - show receipt-specific actions
                            Button(action: {
                                isExpanded = false
                                onAdvancedSplit()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("ADVANCED")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(0.8)
                                }
                                .foregroundColor(ink.opacity(0.65))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(ink.opacity(0.20), lineWidth: 1)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.95))
                            
                            compactButton(
                                label: "View Receipt",
                                icon: "photo",
                                action: onImageTap
                            )
                            
                            compactButton(
                                label: "Edit",
                                icon: "pencil",
                                action: { isExpanded = false; onEdit() }
                            )
                        } else {
                            // No receipt - just Advanced Split
                            Button(action: {
                                isExpanded = false
                                onAdvancedSplit()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("ADVANCED SPLIT")
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(0.8)
                                }
                                .foregroundColor(ink.opacity(0.65))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(ink.opacity(0.20), lineWidth: 1)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.95))
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Bottom row: Breakdown, Delete (or just Delete & Edit if no breakdown)
                    HStack(spacing: 8) {
                        if let onBreakdown = onBreakdown {
                            compactButton(
                                label: "Breakdown",
                                icon: "list.bullet.rectangle",
                                action: onBreakdown
                            )
                        }

                        compactButton(
                            label: "Delete",
                            icon: "trash",
                            action: { isExpanded = false; onDelete() }
                        )

                        if !hasReceiptImage {
                            compactButton(
                                label: "Edit",
                                icon: "pencil",
                                action: { isExpanded = false; onEdit() }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Expand toggle
            Button(action: {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ink.opacity(0.38))
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(parchment.opacity(0.30))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(0.20), lineWidth: 1.5)
        )
        .onAppear {
            if startsExpanded {
                isExpanded = true
            }
        }
        .onChange(of: startsExpanded) { _, shouldExpand in
            if shouldExpand {
                isExpanded = true
            }
        }
        .animation(.spring(response: 0.3), value: isExpanded)
    }
    
    private func compactButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
            }
            .foregroundColor(ink.opacity(0.65))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(0.20), lineWidth: 1)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.95))
    }

}

// MARK: - Advanced Split Sheet

struct AdvancedSplitSheet: View {
    let transaction: Transaction
    let allPeople:   [Person]
    let onApply:     ([PersonQuantity]) -> Void
    let onDismiss:   () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantities: [PersonQuantity]

    private let ink       = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory     = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let cream     = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)

    init(transaction: Transaction, allPeople: [Person],
         onApply: @escaping ([PersonQuantity]) -> Void, onDismiss: @escaping () -> Void) {
        self.transaction = transaction; self.allPeople = allPeople
        self.onApply = onApply; self.onDismiss = onDismiss
        let splitIDs = Set(transaction.splitWith.map(\.id))
        self._quantities = State(initialValue: allPeople.map {
            PersonQuantity(person: $0, quantity: splitIDs.contains($0.id) ? 1 : 0)
        })
    }

    private var includedQuantities: [PersonQuantity] { quantities.filter { $0.quantity > 0 } }
    private var totalUnits: Int  { quantities.reduce(0) { $0 + $1.quantity } }
    private var hasUnits: Bool   { totalUnits > 0 }
    private var isStatementDocument: Bool {
        transaction.sourceDocumentType == .statement
        || transaction.merchant.localizedCaseInsensitiveContains("statement")
        || transaction.merchant.localizedCaseInsensitiveContains("bank activity")
        || transaction.merchant.localizedCaseInsensitiveContains("account activity")
        || transaction.merchant.localizedCaseInsensitiveContains("transaction history")
    }
    private func sharePercent(for pq: PersonQuantity) -> Double { pq.share(in: quantities) * 100 }
    private func owedAmount(for pq: PersonQuantity) -> Double   { pq.amount(for: transaction.amount, in: quantities) }

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            NavigationView {
                ZStack {
                    ivory.ignoresSafeArea()
                    VStack(spacing: 0) {
                        infoBanner
                        dashedSeparator.padding(.horizontal, 20)
                        ScrollView {
                            VStack(spacing: 20) {
                                instructionCard
                                peopleList
                                if hasUnits { summaryCard }
                            }
                            .padding(20)
                            .padding(.bottom, 100)
                        }
                        applyButton
                    }
                }
                .navigationTitle("")
                .navigationBarHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { dismiss() }) {
                            Text("CLOSE")
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.5)
                                .foregroundColor(ink.opacity(0.55))
                        }
                    }
                }
            }
        }
    }

    private var dashedSeparator: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geo in
                    Path { path in
                        var x: CGFloat = 0
                        while x < geo.size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: min(x + 5, geo.size.width), y: 0))
                            x += 10
                        }
                    }
                    .stroke(ink, lineWidth: 1.5)
                }
            )
    }

    private var infoBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                if isStatementDocument {
                    StatementIcon(size: 30, color: ink)
                } else {
                    BillIcon(size: 30, color: ink)
                }
            }
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchant.uppercased())
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ink)
                    .tracking(0.3)
                Text(String(format: "$%.2f total", transaction.amount))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(0.5)
            }
            Spacer()
        }
        .padding(20)
        .background(parchment)
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW IT WORKS")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(ink.opacity(0.48))
                .tracking(2)
            Text("Tap a person to include or exclude them. Use the × multiplier if someone owes more — e.g. Alex ate twice as much, give them 2× and everyone else 1×.")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(ink.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(parchment.opacity(0.50))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(0.14), lineWidth: 1)
        )
    }

    private var peopleList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WHO'S SPLITTING?")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(2)
                Spacer()
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        let allIn = quantities.allSatisfy { $0.quantity > 0 }
                        for i in quantities.indices { quantities[i].quantity = allIn ? 0 : 1 }
                    }
                }) {
                    Text(quantities.allSatisfy { $0.quantity > 0 } ? "DESELECT ALL" : "SELECT ALL")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(ink.opacity(0.55))
                        .tracking(1.5)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.20), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.95))
            }
            VStack(spacing: 0) {
                ForEach($quantities) { $pq in
                    advancedPersonRow(pq: $pq)
                    if pq.id != quantities.last?.id {
                        Divider().background(ink.opacity(0.06))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(0.14), lineWidth: 1)
            )
        }
    }

    private func advancedPersonRow(pq: Binding<PersonQuantity>) -> some View {
        let isIncluded = pq.wrappedValue.quantity > 0
        return HStack(spacing: 12) {
            Button(action: {
                withAnimation(.spring(response: 0.25)) {
                    pq.wrappedValue.quantity = isIncluded ? 0 : 1
                }
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isIncluded ? ink : Color.clear)
                        .frame(width: 15, height: 15)
                    RoundedRectangle(cornerRadius: 1)
                        .stroke(ink, lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if isIncluded {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            AvatarView(imageData: pq.wrappedValue.person.contactImage,
                       initials: pq.wrappedValue.person.initials, size: 30)
                .opacity(isIncluded ? 1 : 0.38)

            VStack(alignment: .leading, spacing: 2) {
                Text(pq.wrappedValue.person.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isIncluded ? ink : ink.opacity(0.38))
                if isIncluded {
                    Text(String(format: "%.0f%%  ·  $%.2f",
                                sharePercent(for: pq.wrappedValue),
                                owedAmount(for: pq.wrappedValue)))
                        .font(.system(size: 11))
                        .foregroundColor(ink.opacity(0.48))
                } else {
                    Text("NOT INCLUDED")
                        .font(.system(size: 8))
                        .foregroundColor(ink.opacity(0.28))
                        .tracking(1)
                }
            }

            Spacer()

            if isIncluded {
                HStack(spacing: 0) {
                    Button(action: {
                        withAnimation(.spring(response: 0.25)) {
                            pq.wrappedValue.quantity = max(1, pq.wrappedValue.quantity - 1)
                        }
                    }) {
                        Text("−")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(pq.wrappedValue.quantity > 1 ? ink : ink.opacity(0.24))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)

                    Text("\(pq.wrappedValue.quantity)×")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(ink)
                        .frame(minWidth: 28)

                    Button(action: {
                        withAnimation(.spring(response: 0.25)) { pq.wrappedValue.quantity += 1 }
                    }) {
                        Text("+")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(ink)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(ink.opacity(0.14), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isIncluded ? ivory : parchment.opacity(0.40))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25)) {
                pq.wrappedValue.quantity = isIncluded ? 0 : 1
            }
        }
        .animation(.spring(response: 0.25), value: pq.wrappedValue.quantity)
    }

    private var summaryCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("SPLIT SUMMARY")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(2)
                Spacer()
                Text("\(includedQuantities.count) PEOPLE")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(ink.opacity(0.38))
                    .tracking(1.5)
            }
            VStack(spacing: 0) {
                ForEach(includedQuantities) { pq in
                    HStack {
                        Text(pq.person.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(ink)
                        Spacer()
                        Text(String(format: "%.0f%%  ·  $%.2f",
                                    sharePercent(for: pq),
                                    owedAmount(for: pq)))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(ink)
                    }
                    .padding(.vertical, 8)
                    if pq.id != includedQuantities.last?.id {
                        Divider().background(ink.opacity(0.06))
                    }
                }
            }
        }
        .padding(14)
        .background(parchment.opacity(0.50))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(0.14), lineWidth: 1)
        )
    }

    private var applyButton: some View {
        VStack(spacing: 0) {
            dashedSeparator
            Button(action: { onApply(includedQuantities); dismiss() }) {
                HStack(spacing: 8) {
                    Text(hasUnits
                         ? "APPLY SPLIT · \(includedQuantities.count) \(includedQuantities.count == 1 ? "PERSON" : "PEOPLE")"
                         : "SELECT AT LEAST ONE PERSON")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1)
                    if hasUnits {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundColor(hasUnits ? .white : ink.opacity(0.28))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(hasUnits ? ink : ink.opacity(0.08))
                .cornerRadius(3)
            }
            .disabled(!hasUnits)
            .padding(20)
            .background(ivory)
        }
    }
}


// MARK: - Receipt Breakdown Sheet

struct ReceiptBreakdownSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var tutorialManager: TutorialManager

    let transaction:   Transaction?
    @Binding var lineItems:     [ReceiptLineItem]
    @Binding var isLoading:     Bool
    @Binding var quickTotal:    Double?
    @Binding var quickMerchant: String
    let receiptImageData: Data?  // Direct receipt image data
    let documentType: TransactionSourceDocumentType
    @State private var breakdownReceiptImage: Data? = nil


    let onUseTotal:     () -> Void
    let onUseBreakdown: () -> Void

    @State private var editingItemID:  UUID?     = nil
    @State private var editingField:   EditField = .none
    @State private var editNameText:   String    = ""
    @State private var editAmountText: String    = ""
    @State private var showSplitMissing = false
    @State private var showItemAttachmentPicker = false
    @State private var showTipSheet = false
    @State private var selectedAdjustmentItem: ReceiptLineItem?
    @State private var addedTipTotal: Double = 0

    private let ink       = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory     = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let cream     = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
    private let redInk    = Color(red: 0.48, green: 0.12, blue: 0.12)
    private let greenInk  = Color(red: 0.16, green: 0.38, blue: 0.16)

    enum EditField { case none, name, amount }

    private var merchandiseItems: [ReceiptLineItem] { lineItems.filter { $0.category == .merchandise } }
    private var chargeItems: [ReceiptLineItem]      { lineItems.filter { [.tax, .tip, .fee].contains($0.category) } }
    private var adjustmentItems: [ReceiptLineItem]  { lineItems.filter { $0.category == .adjustment } }

    var effectiveTotal: Double {
        lineItems.filter(\.isSelected).reduce(0.0) { $0 + $1.amount }
    }
    private var baseReceiptTotal: Double { transaction?.amount ?? quickTotal ?? 0 }
    private var receiptTotal: Double { baseReceiptTotal + addedTipTotal }
    private var gap: Double          { ((receiptTotal - effectiveTotal) * 100).rounded() / 100 }
    private var hasOverSum: Bool     { gap < -0.01 }
    private var isBalanced: Bool     { abs(gap) < 0.02 }
    private var isStatementDocument: Bool {
        documentType == .statement
        || transaction?.sourceDocumentType == .statement
        || transaction?.merchant.localizedCaseInsensitiveContains("statement") == true
        || transaction?.merchant.localizedCaseInsensitiveContains("bank activity") == true
        || transaction?.merchant.localizedCaseInsensitiveContains("account activity") == true
        || transaction?.merchant.localizedCaseInsensitiveContains("transaction history") == true
    }
    private var documentNoun: String { isStatementDocument ? "statement" : "receipt" }
    private var documentBreakdownTitle: String {
        isStatementDocument ? "STATEMENT BREAKDOWN" : "RECEIPT BREAKDOWN"
    }
    private var processingTitle: String {
        isStatementDocument ? "PROCESSING STATEMENT..." : "PROCESSING RECEIPT..."
    }
    private var detailCountText: String {
        if isStatementDocument {
            return "\(merchandiseItems.count) TRANSACTION\(merchandiseItems.count == 1 ? "" : "S")"
        }
        return "\(merchandiseItems.count) ITEM\(merchandiseItems.count == 1 ? "" : "S") · \(chargeItems.count) CHARGE\(chargeItems.count == 1 ? "" : "S")"
    }
    private var merchandiseSectionTitle: String {
        isStatementDocument ? "TRANSACTIONS" : "MERCHANDISE"
    }
    private var selectedBreakdownUnit: String {
        isStatementDocument ? "transaction" : "item"
    }

    private var shouldSpotlightItems: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .breakdownConfirm
    }

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            NavigationView {
                ZStack {
                    ivory.ignoresSafeArea()
                    VStack(spacing: 0) {
                        infoBanner
                        if hasOverSum && !isLoading { overSumBanner }
                        dashedDivider.padding(.horizontal, 20)
                        if isLoading {
                            loadingView
                        } else {
                            ScrollView {
                                VStack(spacing: 20) {
                                    itemsList
                                        .tutorialSpotlight(isHighlighted: shouldSpotlightItems, cornerRadius: 2)
                                    
                                    // Show adjustment sections
                                    if !adjustmentItems.isEmpty {
                                        ForEach(adjustmentItems) { item in
                                            adjustmentSection(item: item)
                                        }
                                    }
                                    
                                    summarySection
                                }
                                .padding(20)
                            }
                            bottomButtons
                        }
                    }
                }
                .navigationTitle("")
                .navigationBarHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { isPresented = false }) {
                            Text("CLOSE")
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.5)
                                .foregroundColor(ink.opacity(0.55))
                        }
                    }
                }
            }
            if tutorialManager.isActive && tutorialManager.isCurrentStep(in: .review) {
                TutorialOverlay(context: .review).zIndex(100)
            }
        }
        .onAppear {
            print("📸 ReceiptBreakdownSheet - Receipt image data: \(receiptImageData != nil ? "PRESENT (\(receiptImageData!.count) bytes)" : "NIL")")
            print("📸 ReceiptBreakdownSheet - Transaction: \(transaction != nil ? "PRESENT" : "NIL")")
            if let trans = transaction {
                print("📸 ReceiptBreakdownSheet - Transaction.receiptImage: \(trans.receiptImage != nil ? "PRESENT (\(trans.receiptImage!.count) bytes)" : "NIL")")
            }
        }
        .sheet(isPresented: $showSplitMissing) {
            if let adjustment = selectedAdjustmentItem {
                MissingItemSplitSheet(
                    totalAmount: adjustment.amount,
                    receiptImage: receiptImageData,
                    onApply: { newItems in
                        lineItems.removeAll { $0.id == adjustment.id }
                        lineItems.append(contentsOf: newItems)
                    }
                )
            }
        }
        .sheet(isPresented: $showItemAttachmentPicker) {
            if let adjustment = selectedAdjustmentItem {
                ItemAttachmentPicker(
                    items: merchandiseItems,
                    adjustmentAmount: adjustment.amount,
                    adjustmentName: adjustment.name,
                    receiptImage: receiptImageData,
                    onAttach: { itemId in
                        // Apply adjustment to selected item
                        if let idx = lineItems.firstIndex(where: { $0.id == itemId }) {
                            lineItems[idx].amount += adjustment.amount
                            lineItems[idx].originalPrice = lineItems[idx].amount
                        }
                        // Remove the adjustment item
                        lineItems.removeAll { $0.id == adjustment.id }
                        showItemAttachmentPicker = false
                        selectedAdjustmentItem = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showTipSheet) {
            TipAmountSheet(
                baseAmount: receiptTotal,
                onApply: { amount in
                    addTipLineItem(amount)
                    showTipSheet = false
                },
                onDismiss: { showTipSheet = false }
            )
        }
    }

    private var dashedDivider: some View {
        Rectangle().fill(Color.clear).frame(height: 1)
            .overlay(GeometryReader { geo in
                Path { path in
                    var x: CGFloat = 0
                    while x < geo.size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: min(x + 5, geo.size.width), y: 0))
                        x += 10
                    }
                }.stroke(ink, lineWidth: 1.5)
            })
    }

    private var infoBanner: some View {
        HStack(spacing: 12) {
            if isStatementDocument {
                StatementIcon(color: isLoading ? ink.opacity(0.38) : ink)
            } else {
                BillIcon(color: isLoading ? ink.opacity(0.38) : ink)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isLoading ? processingTitle : documentBreakdownTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ink)
                    .tracking(0.5)
                Text(isLoading
                     ? (isStatementDocument ? "Extracting transactions" : "Extracting line items")
                     : detailCountText)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(1.5)
            }
            Spacer()
            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: ink))
                    .scaleEffect(0.8)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("TOTAL")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(ink.opacity(0.38))
                        .tracking(2)
                    Text(String(format: "$%.2f", receiptTotal))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ink)
                }
            }
        }
        .padding(16)
        .background(parchment)
    }

    private var overSumBanner: some View {
        HStack(spacing: 8) {
            Text("!")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(redInk)
            Text(String(format: "%@ TOTAL $%.2f MORE THAN %@ — DESELECT EXTRA LINES",
                        isStatementDocument ? "TRANSACTIONS" : "ITEMS",
                        abs(gap),
                        documentNoun.uppercased()))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(redInk)
                .tracking(0.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(redInk.opacity(0.05))
        .overlay(Rectangle().fill(redInk).frame(width: 2), alignment: .leading)
    }

    private var loadingView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: ink))
                    .scaleEffect(1.3)
                if let total = quickTotal {
                    VStack(spacing: 8) {
                        Text("TOTAL FOUND")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(ink.opacity(0.48))
                            .tracking(2)
                        Text(String(format: "$%.2f", total))
                            .font(.system(size: 40, weight: .bold))
                            .foregroundColor(ink)
                        if !quickMerchant.isEmpty {
                            Text(quickMerchant.uppercased())
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(ink.opacity(0.48))
                                .tracking(1)
                        }
                    }
                    .padding(.vertical, 24).padding(.horizontal, 32)
                    .background(parchment.opacity(0.60))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1))
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                } else {
                    Text(isStatementDocument ? "READING STATEMENT DATA..." : "READING RECEIPT DATA...")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(ink.opacity(0.48))
                        .tracking(2)
                        .transition(.opacity)
                }
                Text(quickTotal != nil
                     ? (isStatementDocument ? "Breaking down transactions..." : "Breaking down line items...")
                     : "Analyzing \(documentNoun)...")
                    .font(.system(size: 12))
                    .foregroundColor(ink.opacity(0.38))
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: quickTotal)
            Spacer()
            if let total = quickTotal {
                VStack(spacing: 0) {
                    dashedDivider.padding(.horizontal, 20)
                    Button(action: { onUseTotal() }) {
                        HStack(spacing: 8) {
                            Text(String(format: "USE $%.2f AS TOTAL", total))
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(1)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(ink.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.20), lineWidth: 1))
                    }
                    .padding(20)
                    .background(ivory)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !merchandiseItems.isEmpty {
                categorySection(title: merchandiseSectionTitle, items: merchandiseItems, isCharge: false)
            }
            if !chargeItems.isEmpty {
                categorySection(title: "CHARGES · ALWAYS INCLUDED", items: chargeItems, isCharge: true)
            }
            Button(action: {
                HapticManager.impact(style: .light)
                showTipSheet = true
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ADD TIP")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.2)
                        Text("Optional. Split evenly with this \(documentNoun).")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(ink.opacity(0.42))
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(ink)
                .padding(14)
                .background(parchment.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.3, dash: [5, 5]))
                        .foregroundColor(ink.opacity(0.18))
                )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.98))
        }
    }

    private func categorySection(title: String, items: [ReceiptLineItem], isCharge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(2)
                Spacer()
                if !isCharge {
                    Text("TAP TO EDIT")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(ink.opacity(0.28))
                        .tracking(1.5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(parchment)
            .overlay(
                Rectangle()
                    .fill(ink.opacity(0.10))
                    .frame(height: 1),
                alignment: .bottom
            )

            VStack(spacing: 0) {
                ForEach(items) { item in
                    if let index = lineItems.firstIndex(where: { $0.id == item.id }) {
                        lineItemRow(item: $lineItems[index], isCharge: isCharge)
                        if item.id != items.last?.id {
                            Divider().background(ink.opacity(0.06))
                        }
                    }
                }
            }
            .background(isCharge ? parchment.opacity(0.35) : ivory)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(isCharge ? 0.10 : 0.20), lineWidth: 1.5)
        )
    }

    private func adjustmentSection(item: ReceiptLineItem) -> some View {
        let isNegative = item.amount < 0
        
        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Text(isNegative ? "DISCOUNT/ADJUSTMENT" : "UNACCOUNTED AMOUNT")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(1.5)
                Spacer()
                Text(String(format: "$%.2f", abs(item.amount)))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isNegative ? greenInk : ink)
            }

            VStack(spacing: 12) {
                // Item info
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ink)
                    Text(isNegative
                         ? "This discount should be applied to an existing item"
                         : "Not yet included in the split")
                            .font(.system(size: 11))
                            .foregroundColor(ink.opacity(0.48))
                    }
                    Spacer()
                    Text(String(format: "$%.2f", item.amount))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(isNegative ? greenInk : ink)
                }

                Rectangle().fill(ink.opacity(0.08)).frame(height: 1)

                // Action buttons - different for negative vs positive
                if isNegative {
                    // NEGATIVE ADJUSTMENT (Discount) - Only 2 options
                    VStack(spacing: 8) {
                        // Primary: Add to existing item
                        Button(action: {
                            selectedAdjustmentItem = item
                            showItemAttachmentPicker = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("ADD TO EXISTING ITEM")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.8)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(greenInk)
                            .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.98))
                        
                        // Secondary: Remove
                        Button(action: {
                            withAnimation(.spring(response: 0.3)) {
                                lineItems.removeAll { $0.id == item.id }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("REMOVE")
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.8)
                            }
                            .foregroundColor(redInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(redInk.opacity(0.38), lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.98))
                    }
                } else {
                    // POSITIVE ADJUSTMENT (Missing amount) - All 4 options
                    VStack(spacing: 8) {
                        // Row 1: Add as one item, Split into items
                        HStack(spacing: 8) {
                            Button(action: {
                                withAnimation(.spring(response: 0.3)) {
                                    if let idx = lineItems.firstIndex(where: { $0.id == item.id }) {
                                        lineItems[idx].isSelected = true
                                        lineItems[idx].category = .merchandise
                                    }
                                }
                            }) {
                                VStack(spacing: 4) {
                                    Text("ADD AS")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(1)
                                    Text("ONE ITEM")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(1)
                                }
                                .foregroundColor(ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(ink.opacity(0.28), lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.98))
                            
                            Button(action: {
                                selectedAdjustmentItem = item
                                showSplitMissing = true
                            }) {
                                VStack(spacing: 4) {
                                    Text("SPLIT INTO")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(1)
                                    Text("ITEMS")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(1)
                                }
                                .foregroundColor(ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(ink.opacity(0.28), lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.98))
                        }
                        
                        // Row 2: Add to existing item, Remove
                        HStack(spacing: 8) {
                            Button(action: {
                                selectedAdjustmentItem = item
                                showItemAttachmentPicker = true
                            }) {
                                VStack(spacing: 4) {
                                    Text("ADD TO")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(1)
                                    Text("EXISTING")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(1)
                                }
                                .foregroundColor(ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(ink.opacity(0.28), lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.98))
                            
                            Button(action: {
                                withAnimation(.spring(response: 0.3)) {
                                    lineItems.removeAll { $0.id == item.id }
                                }
                            }) {
                                VStack(spacing: 4) {
                                    Text("REMOVE")
                                        .font(.system(size: 8, weight: .bold))
                                        .tracking(1)
                                    Text(" ")
                                        .font(.system(size: 8))
                                }
                                .foregroundColor(redInk)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(redInk.opacity(0.38), lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.98))
                        }
                    }
                }
            }
            .padding(14)
            .background(isNegative ? greenInk.opacity(0.05) : parchment.opacity(0.50))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 5])
                    )
                    .foregroundColor(isNegative ? greenInk.opacity(0.30) : ink.opacity(0.20))
            )
        }
    }

    private func lineItemRow(item: Binding<ReceiptLineItem>, isCharge: Bool) -> some View {
        let isEditingThis = editingItemID == item.wrappedValue.id
        let isSelected    = item.wrappedValue.isSelected

        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: {
                    if !isCharge {
                        withAnimation(.spring(response: 0.3)) { item.wrappedValue.isSelected.toggle() }
                    }
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isSelected ? ink : Color.clear)
                            .frame(width: 15, height: 15)
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(isCharge ? ink.opacity(0.20) : ink, lineWidth: 1.5)
                            .frame(width: 15, height: 15)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .disabled(isCharge)

                VStack(alignment: .leading, spacing: 5) {
                    // Name
                    if isEditingThis && editingField == .name {
                        HStack(spacing: 6) {
                            TextField("Item name", text: $editNameText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(ink)
                                .padding(8)
                                .background(parchment.opacity(0.50))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1))
                                .onSubmit { commitNameEdit(for: item) }
                            Button(action: { commitNameEdit(for: item) }) {
                                Text("✓").font(.system(size: 13, weight: .bold)).foregroundColor(ink)
                            }
                            Button(action: { cancelEdit() }) {
                                Text("✕").font(.system(size: 13)).foregroundColor(ink.opacity(0.38))
                            }
                        }
                    } else {
                        Button(action: { if !isCharge { startNameEdit(for: item) } }) {
                            HStack(spacing: 6) {
                                if isCharge {
                                    Text(item.wrappedValue.category == .tax ? "TAX" :
                                         item.wrappedValue.category == .tip ? "TIP" : "FEE")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundColor(ink.opacity(0.48))
                                        .tracking(1)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 1).stroke(ink.opacity(0.20), lineWidth: 1))
                                }
                                Text(item.wrappedValue.name.isEmpty ? "Item" : item.wrappedValue.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(isSelected ? ink : ink.opacity(0.32))
                                    .multilineTextAlignment(.leading)
                                if !isCharge {
                                    Text("EDIT")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundColor(ink.opacity(0.28))
                                        .tracking(1)
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 1).stroke(ink.opacity(0.14), lineWidth: 1))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isCharge)
                    }

                    if !isCharge {
                        HStack(spacing: 6) {
                            if let splitCategory = item.wrappedValue.splitCategory,
                               !splitCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                itemMetaChip(
                                    text: displayName(forSplitCategory: splitCategory),
                                    foreground: ink.opacity(isSelected ? 0.58 : 0.28),
                                    border: ink.opacity(isSelected ? 0.16 : 0.08)
                                )
                            }
                            if item.wrappedValue.discount > 0 {
                                itemMetaChip(
                                    text: item.wrappedValue.discountLabel ?? "Discount applied",
                                    foreground: greenInk.opacity(isSelected ? 0.95 : 0.36),
                                    border: greenInk.opacity(isSelected ? 0.28 : 0.12)
                                )
                            }
                        }
                    }

                    // Amount
                    if isEditingThis && editingField == .amount {
                        HStack(spacing: 6) {
                            Text("$").font(.system(size: 14, weight: .bold)).foregroundColor(ink.opacity(0.48))
                            TextField("0.00", text: $editAmountText)
                                .font(.system(size: 15, weight: .bold))
                                .keyboardType(.decimalPad)
                                .foregroundColor(ink)
                                .padding(8)
                                .background(parchment.opacity(0.50))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1))
                                .frame(maxWidth: 120)
                                .onSubmit { commitAmountEdit(for: item) }
                            Button(action: { commitAmountEdit(for: item) }) {
                                Text("✓").font(.system(size: 13, weight: .bold)).foregroundColor(ink)
                            }
                            Button(action: { cancelEdit() }) {
                                Text("✕").font(.system(size: 13)).foregroundColor(ink.opacity(0.38))
                            }
                        }
                    } else {
                        Button(action: { if !isCharge { startAmountEdit(for: item) } }) {
                            HStack(spacing: 6) {
                                Text(String(format: "$%.2f", item.wrappedValue.amount))
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(isSelected ? ink : ink.opacity(0.28))
                                if !isCharge {
                                    Text("EDIT")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundColor(ink.opacity(0.28))
                                        .tracking(1)
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 1).stroke(ink.opacity(0.14), lineWidth: 1))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isCharge)
                    }
                }
                Spacer()

                if item.wrappedValue.discount > 0 {
                    Text("-$\(String(format: "%.2f", item.wrappedValue.discount))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(greenInk)
                        .opacity(isSelected ? 1 : 0.38)
                }

                if !isCharge {
                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            lineItems.removeAll { $0.id == item.wrappedValue.id }
                        }
                    }) {
                        Text("✕")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(redInk.opacity(0.65))
                            .frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 1).stroke(redInk.opacity(0.20), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isSelected ? (isCharge ? parchment.opacity(0.35) : ivory) : parchment.opacity(0.50))
        .animation(.spring(response: 0.3), value: isEditingThis)
    }

    private func itemMetaChip(text: String, foreground: Color, border: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 7, weight: .bold))
            .tracking(1)
            .lineLimit(1)
            .foregroundColor(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .stroke(border, lineWidth: 1)
            )
    }

    private func displayName(forSplitCategory category: String) -> String {
        switch category {
        case "produce": return "Produce"
        case "meat_seafood": return "Meat"
        case "dairy_eggs": return "Dairy"
        case "bakery": return "Bakery"
        case "pantry": return "Pantry"
        case "frozen": return "Frozen"
        case "beverages": return "Drinks"
        case "snacks": return "Snacks"
        case "prepared_food": return "Prepared"
        case "household": return "Household"
        case "personal_care": return "Personal"
        case "health_wellness": return "Health"
        case "pet": return "Pet"
        case "baby": return "Baby"
        case "alcohol": return "Alcohol"
        case "restaurant": return "Restaurant"
        case "general_merchandise": return "General"
        default:
            return category
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private func startNameEdit(for item: Binding<ReceiptLineItem>) {
        cancelEdit(); editingItemID = item.wrappedValue.id; editingField = .name; editNameText = item.wrappedValue.name
    }
    private func startAmountEdit(for item: Binding<ReceiptLineItem>) {
        cancelEdit(); editingItemID = item.wrappedValue.id; editingField = .amount
        editAmountText = String(format: "%.2f", item.wrappedValue.amount)
    }
    private func commitNameEdit(for item: Binding<ReceiptLineItem>) {
        let t = editNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { item.wrappedValue.name = t }
        cancelEdit()
    }
    private func commitAmountEdit(for item: Binding<ReceiptLineItem>) {
        if let v = Double(editAmountText), v > 0 {
            item.wrappedValue.amount = (v * 100).rounded() / 100
            item.wrappedValue.originalPrice = item.wrappedValue.amount
        }
        cancelEdit()
    }
    private func cancelEdit() { editingItemID = nil; editingField = .none; editNameText = ""; editAmountText = "" }

    private func addTipLineItem(_ amount: Double) {
        guard amount > 0 else { return }
        let rounded = (amount * 100).rounded() / 100
        let tip = ReceiptLineItem(
            name: "Tip",
            originalPrice: rounded,
            discount: 0,
            amount: rounded,
            taxPortion: 0,
            isSelected: true,
            category: .tip
        )
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            lineItems.append(tip)
            addedTipTotal += rounded
        }
    }

    private var summarySection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("SELECTED TOTAL")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(2)
                Spacer()
                Text(String(format: "$%.2f", effectiveTotal))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(ink)
            }
            .padding(14)
            .background(parchment.opacity(0.50))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1.5))

            if isBalanced {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(greenInk)
                        .frame(width: 10, height: 10)
                    Text("BALANCED")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(greenInk)
                        .tracking(1.5)
                    Spacer()
                }
            }
        }
    }

    private var bottomButtons: some View {
        let selectedCount = lineItems.filter(\.isSelected).count
        return VStack(spacing: 0) {
            dashedDivider.padding(.horizontal, 20)

            Button(action: { onUseBreakdown() }) {
                HStack(spacing: 8) {
                    Text("Break down into \(selectedCount) \(selectedBreakdownUnit)\(selectedCount == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(0.5)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(selectedCount > 0 ? .white : ink.opacity(0.28))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(selectedCount > 0 ? ink : ink.opacity(0.08))
                .cornerRadius(3)
            }
            .disabled(selectedCount == 0)
            .padding(20)
            .background(ivory)
        }
        .background(ivory)
    }
}

// MARK: - Tip Amount Sheet

struct TipAmountSheet: View {
    let baseAmount: Double
    let onApply: (Double) -> Void
    let onDismiss: () -> Void

    @State private var selectedPercent: Int? = 18
    @State private var customAmount = ""

    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
    private let percents = [15, 18, 20]

    private var tipAmount: Double {
        if !customAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Double(customAmount) ?? 0
        }
        guard let selectedPercent else { return 0 }
        return ((baseAmount * Double(selectedPercent) / 100) * 100).rounded() / 100
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ADD TIP")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(ink.opacity(0.45))
                        .tracking(2.5)
                    Text("Keep it optional")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(ink)
                    Text("Tip is added as its own split item, so it stays easy to edit or remove.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ink.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(parchment)

                VStack(spacing: 18) {
                    HStack(spacing: 10) {
                        ForEach(percents, id: \.self) { percent in
                            Button(action: {
                                HapticManager.impact(style: .light)
                                selectedPercent = percent
                                customAmount = ""
                            }) {
                                VStack(spacing: 4) {
                                    Text("\(percent)%")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(String(format: "$%.2f", ((baseAmount * Double(percent) / 100) * 100).rounded() / 100))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(selectedPercent == percent && customAmount.isEmpty ? ivory.opacity(0.78) : ink.opacity(0.45))
                                }
                                .foregroundColor(selectedPercent == percent && customAmount.isEmpty ? ivory : ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(selectedPercent == percent && customAmount.isEmpty ? ink : ivory)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(ink.opacity(0.18), lineWidth: 1)
                                )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.97))
                        }
                    }

                    HStack(spacing: 10) {
                        Text("$")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(ink.opacity(0.45))
                        TextField("Custom tip", text: $customAmount)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(ink)
                            .onChange(of: customAmount) { _, value in
                                if !value.isEmpty { selectedPercent = nil }
                            }
                    }
                    .padding(14)
                    .background(ivory)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(ink.opacity(0.18), lineWidth: 1)
                    )

                    VStack(spacing: 6) {
                        Text("TIP")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(ink.opacity(0.42))
                            .tracking(2)
                        Text(String(format: "$%.2f", tipAmount))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .padding(20)

                Spacer(minLength: 0)

                Button(action: {
                    HapticManager.notification(type: .success)
                    onApply(tipAmount)
                }) {
                    Text("ADD TIP")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(tipAmount > 0 ? ivory : ink.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(tipAmount > 0 ? ink : ink.opacity(0.08))
                        .cornerRadius(3)
                }
                .disabled(tipAmount <= 0)
                .padding(20)
            }
            .background(Color(red: 0.96, green: 0.94, blue: 0.91).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("CLOSE") { onDismiss() }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(ink.opacity(0.55))
                }
            }
        }
    }
}

// MARK: - Item Attachment Picker Sheet

struct ItemAttachmentPicker: View {
    let items: [ReceiptLineItem]
    let adjustmentAmount: Double
    let adjustmentName: String
    let receiptImage: Data?
    let onAttach: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    
    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
    private let greenInk = Color(red: 0.16, green: 0.38, blue: 0.16)
    private let redInk = Color(red: 0.48, green: 0.12, blue: 0.12)
    
    @State private var showFullReceipt = false
    
    private var isDiscount: Bool { adjustmentAmount < 0 }
    
    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            NavigationView {
                ZStack {
                    ivory.ignoresSafeArea()
                    VStack(spacing: 0) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isDiscount ? "APPLY DISCOUNT" : "ADD TO ITEM")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(ink)
                                .tracking(0.5)
                            Text("Select which item to adjust by \(String(format: "$%.2f", adjustmentAmount))")
                                .font(.system(size: 12))
                                .foregroundColor(ink.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(parchment)
                        
                        dashedDivider
                        
                        // Receipt image preview (if available)
                        if let imageData = receiptImage {
                            if let image = UIImage(data: imageData) {
                                VStack(spacing: 0) {
                                    HStack {
                                        Text("RECEIPT IMAGE")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(ink.opacity(0.48))
                                            .tracking(1.5)
                                        Spacer()
                                        Button(action: { showFullReceipt = true }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                    .font(.system(size: 8, weight: .semibold))
                                                Text("VIEW FULL")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .tracking(1)
                                            }
                                            .foregroundColor(ink.opacity(0.55))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 2)
                                                    .stroke(ink.opacity(0.20), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(ScaleButtonStyle(scale: 0.95))
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.top, 12)
                                    .padding(.bottom, 8)
                                    
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxHeight: 180)
                                        .cornerRadius(2)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(ink.opacity(0.14), lineWidth: 1)
                                        )
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 12)
                                        .onTapGesture {
                                            showFullReceipt = true
                                        }
                                    
                                    Rectangle()
                                        .fill(ink.opacity(0.08))
                                        .frame(height: 1)
                                        .padding(.horizontal, 20)
                                }
                                .background(parchment.opacity(0.30))
                            } else {
                                // Debug: Image data exists but can't create UIImage
                                Text("⚠️ Image data found but couldn't load")
                                    .font(.system(size: 10))
                                    .foregroundColor(redInk)
                                    .padding()
                            }
                        } else {
                            // Debug: No image data
                            Text("⚠️ No receipt image data")
                                .font(.system(size: 10))
                                .foregroundColor(redInk)
                                .padding()
                        }
                        
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(items) { item in
                                    attachmentRow(item: item)
                                    if item.id != items.last?.id {
                                        Divider().background(ink.opacity(0.06))
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                        }
                    }
                }
                .navigationTitle("")
                .navigationBarHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { dismiss() }) {
                            Text("CANCEL")
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.5)
                                .foregroundColor(ink.opacity(0.55))
                        }
                    }
                }
            }
            
            // Full screen receipt viewer
            if showFullReceipt, let imageData = receiptImage, let image = UIImage(data: imageData) {
                fullScreenImageViewer(image: image)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .onAppear {
            print("📸 ItemAttachmentPicker - Receipt image data: \(receiptImage != nil ? "PRESENT (\(receiptImage!.count) bytes)" : "NIL")")
        }
    }
    
    private var dashedDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        let dashWidth: CGFloat = 5
                        let dashGap: CGFloat = 5
                        var x: CGFloat = 0
                        while x < geometry.size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: min(x + dashWidth, geometry.size.width), y: 0))
                            x += dashWidth + dashGap
                        }
                    }
                    .stroke(ink, lineWidth: 1.5)
                }
            )
    }
    
    private func fullScreenImageViewer(image: UIImage) -> some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showFullReceipt = false
                    }
                }
            VStack {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(4)
                    .padding(.horizontal, 20)
                Spacer()
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showFullReceipt = false
                        }
                    }) {
                        Text("CLOSE")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(20)
                }
                Spacer()
            }
        }
    }
    
    private func attachmentRow(item: ReceiptLineItem) -> some View {
        let newAmount = item.amount + adjustmentAmount
        
        return Button(action: {
            HapticManager.impact(style: .medium)
            onAttach(item.id)
            dismiss()
        }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(ink)
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: 8) {
                        Text(String(format: "$%.2f", item.amount))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(ink.opacity(0.48))
                            .strikethrough()
                        
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(ink.opacity(0.38))
                        
                        Text(String(format: "$%.2f", newAmount))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(isDiscount ? greenInk : ink)
                    }
                }
                
                Spacer()
                
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(ink.opacity(0.28))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(parchment.opacity(0.20))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Edit Transaction Sheet (Combined Name + Amount)

struct EditTransactionSheet: View {
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var amount: String
    @Environment(\.colorScheme) var colorScheme
    let onSave: () -> Void

    private let ink       = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory     = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            NavigationView {
                ZStack {
                    ivory.ignoresSafeArea()
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ITEM NAME")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(ink.opacity(0.48))
                                .tracking(2)
                            TextField("Enter name", text: $name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(ink)
                                .padding(16)
                                .background(parchment.opacity(0.50))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1.5))
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AMOUNT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(ink.opacity(0.48))
                                .tracking(2)
                            HStack(spacing: 8) {
                                Text("$")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(ink)
                                TextField("0.00", text: $amount)
                                    .font(.system(size: 24, weight: .bold))
                                    .keyboardType(.decimalPad)
                                    .foregroundColor(ink)
                            }
                            .padding(16)
                            .background(parchment.opacity(0.50))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1.5))
                        }
                        Spacer()
                    }
                    .padding(24)
                }
                .navigationTitle("")
                .navigationBarHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: { isPresented = false }) {
                            Text("CANCEL")
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.5)
                                .foregroundColor(ink.opacity(0.55))
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { onSave() }) {
                            Text("SAVE")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(1.5)
                                .foregroundColor(canSave ? ink : ink.opacity(0.28))
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
    }
    
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Double(amount) ?? 0) > 0
    }
}

// MARK: - Manual Transaction Sheet

struct ManualTransactionSheet: View {
    @Binding var isPresented: Bool
    @Binding var merchant: String
    @Binding var amount: String
    @Environment(\.colorScheme) var colorScheme
    let onAdd: () -> Void

    private let ink       = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory     = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let cream     = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)

    private var canAdd: Bool {
        !merchant.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Double(amount) ?? 0) > 0
    }

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            NavigationView {
                ZStack {
                    ivory.ignoresSafeArea()
                    VStack(spacing: 0) {
                        // Fields
                        VStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("ITEM NAME")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(ink.opacity(0.48))
                                    .tracking(2)
                                TextField("e.g. Dinner, Coffee", text: $merchant)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(ink)
                                    .padding(14)
                                    .background(parchment.opacity(0.50))
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1))
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("AMOUNT")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(ink.opacity(0.48))
                                    .tracking(2)
                                HStack(spacing: 8) {
                                    Text("$")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(ink.opacity(0.48))
                                    TextField("0.00", text: $amount)
                                        .font(.system(size: 15, weight: .medium))
                                        .keyboardType(.decimalPad)
                                        .foregroundColor(ink)
                                }
                                .padding(14)
                                .background(parchment.opacity(0.50))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1))
                            }
                        }
                        .padding(24)

                        Spacer()

                        // Add button — always visible at the bottom
                        VStack(spacing: 0) {
                            Rectangle().fill(Color.clear).frame(height: 1)
                                .overlay(GeometryReader { geo in
                                    Path { path in
                                        var x: CGFloat = 0
                                        while x < geo.size.width {
                                            path.move(to: CGPoint(x: x, y: 0))
                                            path.addLine(to: CGPoint(x: min(x + 5, geo.size.width), y: 0))
                                            x += 10
                                        }
                                    }.stroke(ink, lineWidth: 1.5)
                                })

                            Button(action: {
                                if canAdd { onAdd() }
                            }) {
                                HStack(spacing: 8) {
                                    Text("ADD TRANSACTION")
                                        .font(.system(size: 13, weight: .semibold))
                                        .tracking(1)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(canAdd ? .white : ink.opacity(0.28))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .background(canAdd ? ink : ink.opacity(0.08))
                                .cornerRadius(3)
                            }
                            .disabled(!canAdd)
                            .padding(20)
                            .background(ivory)
                        }
                    }
                }
                .navigationTitle("")
                .navigationBarHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: { isPresented = false; merchant = ""; amount = "" }) {
                            Text("CANCEL")
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.5)
                                .foregroundColor(ink.opacity(0.55))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Missing Item Split Sheet

struct MissingItemSplitSheet: View {
    let totalAmount: Double
    let receiptImage: Data?
    let onApply: ([ReceiptLineItem]) -> Void
    @Environment(\.dismiss) private var dismiss

    private let ink       = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory     = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let cream     = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let parchment = Color(red: 0.93, green: 0.91, blue: 0.85)
    private let redInk    = Color(red: 0.48, green: 0.12, blue: 0.12)

    struct SubItem: Identifiable {
        let id = UUID(); var name: String = ""; var amount: String = ""
    }

    @State private var subItems: [SubItem] = [SubItem(), SubItem()]
    @State private var showFullReceipt = false
    
    private var parsedAmounts: [Double] { subItems.compactMap { Double($0.amount) } }
    private var runningTotal: Double { parsedAmounts.reduce(0, +) }
    private var remaining: Double    { ((totalAmount - runningTotal) * 100).rounded() / 100 }
    private var isBalanced: Bool     { abs(remaining) < 0.01 }
    private var canApply: Bool {
        isBalanced && subItems.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && Double($0.amount) != nil
        }
    }

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            NavigationView {
                ZStack {
                    ivory.ignoresSafeArea()
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TOTAL TO ALLOCATE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(ink.opacity(0.48))
                                    .tracking(1.5)
                                Text(String(format: "$%.2f", totalAmount))
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(ink)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(remaining >= 0 ? "REMAINING" : "OVER BY")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(ink.opacity(0.48))
                                    .tracking(1.5)
                                Text(String(format: "$%.2f", abs(remaining)))
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(
                                        isBalanced ? Color(red: 0.16, green: 0.38, blue: 0.16)
                                        : (remaining < 0 ? redInk : ink)
                                    )
                            }
                        }
                        .padding(20)
                        .background(parchment)

                        dashedSep
                        
                        // Receipt image preview (if available)
                        if let imageData = receiptImage {
                            if let image = UIImage(data: imageData) {
                                VStack(spacing: 0) {
                                    HStack {
                                        Text("RECEIPT IMAGE")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(ink.opacity(0.48))
                                            .tracking(1.5)
                                        Spacer()
                                        Button(action: { showFullReceipt = true }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                    .font(.system(size: 8, weight: .semibold))
                                                Text("VIEW FULL")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .tracking(1)
                                            }
                                            .foregroundColor(ink.opacity(0.55))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 2)
                                                    .stroke(ink.opacity(0.20), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(ScaleButtonStyle(scale: 0.95))
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.top, 12)
                                    .padding(.bottom, 8)
                                    
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxHeight: 300)
                                        .cornerRadius(2)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(ink.opacity(0.14), lineWidth: 1)
                                        )
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 12)
                                        .onTapGesture {
                                            showFullReceipt = true
                                        }
                                    
                                    Rectangle()
                                        .fill(ink.opacity(0.08))
                                        .frame(height: 1)
                                        .padding(.horizontal, 20)
                                }
                                .background(parchment.opacity(0.30))
                            } else {
                                // Debug: Image data exists but can't create UIImage
                                Text("⚠️ Image data found but couldn't load")
                                    .font(.system(size: 10))
                                    .foregroundColor(redInk)
                                    .padding()
                            }
                        } else {
                            // Debug: No image data
                            Text("⚠️ No receipt image data")
                                .font(.system(size: 10))
                                .foregroundColor(redInk)
                                .padding()
                        }

                        ScrollView {
                            VStack(spacing: 12) {
                                ForEach($subItems) { $item in subItemRow(item: $item) }
                                Button(action: {
                                    withAnimation(.spring(response: 0.3)) { subItems.append(SubItem()) }
                                }) {
                                    HStack(spacing: 8) {
                                        Text("+")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(ink.opacity(0.55))
                                        Text("ADD ANOTHER ITEM")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(ink.opacity(0.55))
                                            .tracking(1)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                                            .foregroundColor(ink.opacity(0.20))
                                    )
                                }
                                if !isBalanced && remaining > 0.01 {
                                    Button(action: {
                                        guard !subItems.isEmpty else { return }
                                        subItems[subItems.count - 1].amount = String(format: "%.2f", max(0, remaining))
                                    }) {
                                        HStack(spacing: 6) {
                                            Text("↓")
                                                .font(.system(size: 12))
                                                .foregroundColor(ink.opacity(0.48))
                                            Text(String(format: "FILL LAST ITEM WITH $%.2f", remaining))
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(ink.opacity(0.48))
                                                .tracking(0.5)
                                        }
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .background(parchment.opacity(0.50))
                                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1))
                                    }
                                }
                            }
                            .padding(20).padding(.bottom, 100)
                        }
                        applyButton
                    }
                }
                .navigationTitle("")
                .navigationBarHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("CANCEL") { dismiss() }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(ink.opacity(0.55))
                    }
                }
            }
            
            // Full screen receipt viewer
            if showFullReceipt, let imageData = receiptImage, let image = UIImage(data: imageData) {
                fullScreenImageViewer(image: image)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .onAppear {
            print("📸 MissingItemSplitSheet - Receipt image data: \(receiptImage != nil ? "PRESENT (\(receiptImage!.count) bytes)" : "NIL")")
        }
    }

    private var dashedSep: some View {
        Rectangle().fill(Color.clear).frame(height: 1)
            .overlay(GeometryReader { geo in
                Path { path in
                    var x: CGFloat = 0
                    while x < geo.size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: min(x + 5, geo.size.width), y: 0))
                        x += 10
                    }
                }.stroke(ink, lineWidth: 1.5)
            })
    }
    
    private func fullScreenImageViewer(image: UIImage) -> some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showFullReceipt = false
                    }
                }
            VStack {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(4)
                    .padding(.horizontal, 20)
                Spacer()
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showFullReceipt = false
                        }
                    }) {
                        Text("CLOSE")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .padding(20)
                }
                Spacer()
            }
        }
    }

    private func subItemRow(item: Binding<SubItem>) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Item name", text: item.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(ink)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                    Rectangle().fill(ink.opacity(0.08)).frame(height: 1)
                    HStack(spacing: 4) {
                        Text("$")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(ink.opacity(0.48))
                        TextField("0.00", text: item.amount)
                            .font(.system(size: 14))
                            .keyboardType(.decimalPad)
                            .foregroundColor(ink)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
                .background(parchment.opacity(0.40))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1))
            }
            if subItems.count > 1 {
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        subItems.removeAll { $0.id == item.wrappedValue.id }
                    }
                }) {
                    Text("✕")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(ink.opacity(0.28))
                        .frame(width: 32, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var applyButton: some View {
        VStack(spacing: 0) {
            dashedSep
            Button(action: {
                guard canApply else { return }
                let newItems = subItems.map { sub -> ReceiptLineItem in
                    ReceiptLineItem(
                        name: sub.name.trimmingCharacters(in: .whitespaces),
                        originalPrice: Double(sub.amount) ?? 0,
                        discount: 0, amount: Double(sub.amount) ?? 0,
                        taxPortion: 0, isSelected: true, category: .merchandise
                    )
                }
                onApply(newItems); dismiss()
            }) {
                Text(canApply ? "ADD \(subItems.count) ITEMS"
                     : (remaining > 0.01 ? String(format: "$%.2f STILL UNALLOCATED", remaining) : "FIX AMOUNTS TO CONTINUE"))
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(canApply ? .white : ink.opacity(0.28))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(canApply ? ink : ink.opacity(0.08))
                    .cornerRadius(3)
            }
            .disabled(!canApply)
            .padding(20)
            .background(ivory)
        }
    }
}

// MARK: - Double rounding helper

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
