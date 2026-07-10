import SwiftUI
import Combine
import Lottie

struct TutorialStep: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let description: String
    let targetView: TutorialTarget
    let action: TutorialAction?

    static func == (lhs: TutorialStep, rhs: TutorialStep) -> Bool {
        lhs.id == rhs.id
    }

    enum TutorialTarget {
        case uploadSection
        case uploadButton
        case uploadAndManual
        case manualEntry
        case profileButton
        case receiptThumbnail
        case nextButton
        case peopleAddContact
        case peopleList
        case continueButton
        case reviewTransaction
        case breakdownButton
        case breakdownConfirm
        case reviewItemCard
        case splitSection
        case splitToggle
        case settleAll
        case settleRequest
        case settlePayment
        case shareButton
        case messageIcon
        case fullScreen
        case paymentMethods
        case quickAssignBar
        case groupModeSettle
    }
    
    enum TutorialAction {
        case none
        case navigateToProfile
        case navigateToPeople
        case navigateToReview
        case navigateToSettle
        case highlightPayAndRequestStates
    }
}

// MARK: - Which view each step belongs to
enum TutorialViewContext {
    case upload
    case profile
    case people
    case review
    case settle
}

// MARK: - Tutorial Manager
class TutorialManager: ObservableObject {
    @Published var isActive = false
    @Published var currentStepIndex = 0

    @AppStorage("hasAutoStartedOnce") var hasAutoStartedOnce = false
    @AppStorage("hasSeenTutorial") var hasCompletedTutorial = false

    @Published var shouldOpenBreakdownSheet = false
    @Published var shouldAutoApplyBreakdown = false
    @Published var shouldTriggerSplitDemo = false
    @Published var shouldShowPaywallAfterTutorial = false

    @Published var spotlightFrame: CGRect = .zero
    @Published var spotlightFrames: [TutorialStep.TutorialTarget: CGRect] = [:]
    @Published var frameUpdateTick: Int = 0
    @Published var isNavigatingToSettle: Bool = false
    
    // Click animation properties
    @Published var showClickAnimation = false
    @Published var clickAnimationPosition: CGPoint = .zero
    let steps: [TutorialStep] = [
        // Step 0 - Welcome
        TutorialStep(
            title: "Welcome to Dutch",
            description: "Hi, I'm Taehoon Kang, Founder of Dutch. Let me show you how easy it is to split bills with friends!",
            targetView: .fullScreen,
            action: .none
        ),
        
        // Step 1 - Upload
        TutorialStep(
            title: "Add Your Expenses",
            description: "Upload transactions by taking a screenshot, snapping a receipt, or selecting one from your photos. You can also use Manual Entry to type expenses.",
            targetView: .uploadAndManual,
            action: .none
        ),
        
        // Step 2 - People (skips profile)
        TutorialStep(
            title: "Add People to Your Split",
            description: "Add everyone you're splitting with. Tap Import from Contacts to quickly bring in your friends.",
            targetView: .peopleAddContact,
            action: .navigateToPeople
        ),
        
        // Step 3 - Review
        TutorialStep(
            title: "Review Your Receipt",
            description: "Your receipt is ready. Each transaction shows who paid and how it is split.",
            targetView: .reviewTransaction,
            action: .navigateToReview
        ),
        
        // Step 4 - Breakdown
        TutorialStep(
            title: "Receipt Breakdown",
            description: "We detected all items from your receipt. Each item can be split individually so everyone only pays for what they ordered.",
            targetView: .breakdownConfirm,
            action: .none
        ),
        
        // Step 5: Assign to One Person
        TutorialStep(
            title: "Assign to One Person",
            description: "All items start split with everyone. Tap a person, then tap an item to assign it only to them.",
            targetView: .quickAssignBar,
            action: .none
        ),
        
        // Step 6: Quick Mode + Select/Deselect All (COMBINED)
        TutorialStep(
            title: "Speed Mode & Bulk Actions",
            description: "Toggle Speed Mode to see all items at once for rapid assignment. Use Select All or Deselect All to quickly apply or clear assignments for all items.",
            targetView: .quickAssignBar,
            action: .navigateToSettle
        ),
        
        // Step 7 - Settle
        TutorialStep(
            title: "Pay and Request Money",
            description: "We've set up both flows for when you owe money and when others owe you. Just tap Request to send it. If your friend downloads Dutch, you can pay directly with Venmo or Zelle in one tap.",
            targetView: .settleAll,
            action: .none
        ),
        
        // Step 8 - Profile
        TutorialStep(
            title: "You're All Set",
            description: "Add your Venmo username and Zelle QR code so friends can pay you in one tap.",
            targetView: .paymentMethods,
            action: .navigateToProfile
        )
    ]
    
 
    func steps(for context: TutorialViewContext) -> [Int] {
        switch context {
        case .upload:   return [0, 1]
        case .profile:  return [8]  // Changed from 9
        case .people:   return [2]
        case .review:   return [3, 4, 5, 6]
        case .settle:   return [7]  // Changed from 8
        }
    }

    func isCurrentStep(in context: TutorialViewContext) -> Bool {
        steps(for: context).contains(currentStepIndex)
    }

    var currentStep: TutorialStep? {
        guard currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    var isLastStep: Bool { currentStepIndex >= steps.count - 1 }
    var totalSteps: Int  { steps.count }

    weak var router: Router?
    weak var appState: AppState?

    // MARK: - Multi-spotlight helpers

    var isMultiSpotlight: Bool {
        guard let step = currentStep else { return false }
        return step.targetView == .settleAll ||
               step.targetView == .uploadAndManual ||
               step.targetView == .groupModeSettle ||
               step.targetView == .paymentMethods
    }

    func registerFrame(_ frame: CGRect, for target: TutorialStep.TutorialTarget) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.spotlightFrames[target] != frame {
                self.spotlightFrames[target] = frame
                self.frameUpdateTick += 1
                print("🎯 Registered frame for \(target): \(frame)")
            }
        }
    }

    var activeMultiFrames: [CGRect] {
        guard isMultiSpotlight, let step = currentStep else { return [] }

        if step.targetView == .uploadAndManual {
            return [
                spotlightFrames[.uploadSection],
                spotlightFrames[.manualEntry]
            ].compactMap { $0 }.filter { $0 != .zero }
        }

        if step.targetView == .settleAll {
            return [
                spotlightFrames[.settleRequest],
                spotlightFrames[.settlePayment]
            ].compactMap { $0 }.filter { $0 != .zero }
        }
        
        // Payment methods spotlight (Venmo + Zelle)
        if step.targetView == .paymentMethods {
            return [
                spotlightFrames[.settlePayment],  // Venmo
                spotlightFrames[.settleRequest]   // Zelle
            ].compactMap { $0 }.filter { $0 != .zero }
        }

        // Old settle logic for single spotlight
        if step.targetView == .groupModeSettle {
            return [
                spotlightFrames[.settlePayment],
                spotlightFrames[.settleRequest]
            ].compactMap { $0 }.filter { $0 != .zero }
        }

        return []
    }
    
    // MARK: - Lifecycle

    func start() {
        isActive = true
        currentStepIndex = 0
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        isNavigatingToSettle = false
        shouldOpenBreakdownSheet = false
        shouldAutoApplyBreakdown = false
        shouldTriggerSplitDemo = false
        shouldShowPaywallAfterTutorial = false
        showClickAnimation = false
        hasAutoStartedOnce = true
        setupTutorialData()
    }

    func nextStep() {
        print("🎯 Tutorial nextStep called - current: \(currentStepIndex), active: \(isActive)")
        
        // Step 4 (breakdown confirm) — trigger auto-apply
        if currentStepIndex == 4 {
            spotlightFrame = .zero
            shouldAutoApplyBreakdown = true
            return
        }
        
        // Step 5 (Quick Mode demo) - stay on review, just advance
        if currentStepIndex == 5 {
            spotlightFrame = .zero
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                currentStepIndex += 1
            }
            print("🎯 Advanced to step \(currentStepIndex)")
            // Re-register spotlight for quick assign bar
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.frameUpdateTick += 1
            }
            return
        }
        
        // Step 6 (combined Quick Mode + Select/Deselect) - navigate to settle after animation completes
        if currentStepIndex == 6 {
            spotlightFrame = .zero
            spotlightFrames = [:]
            
            // Navigate to settle for step 7
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.router?.navigateToSettle()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        self.currentStepIndex = 7
                    }
                    
                    // Force frame refresh AFTER layout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.frameUpdateTick += 1
                    }
                }
            }
            return
        }
        
        // Step 7 (settle) — pop settle back to upload root, then open profile for step 8
        if currentStepIndex == 7 {
            spotlightFrame = .zero
            spotlightFrames = [:]
     
            router?.resetToUpload()
     
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                self.router?.presentProfile()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        self.currentStepIndex = 8
                    }
                    
                    // Force frame refresh AFTER layout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.frameUpdateTick += 1
                    }
                }
            }
            return
        }
     
        spotlightFrame = .zero
     
        let nextIndex = currentStepIndex + 1
     
        // Don't clear spotlightFrames for step 7 (settle) or step 8 (profile)
        if nextIndex != 7 && nextIndex != 8 {
            spotlightFrames = [:]
        }
     
        if nextIndex < steps.count {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                currentStepIndex = nextIndex
            }
            if nextIndex == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.shouldOpenBreakdownSheet = true
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.router?.handleTutorialNavigation(for: nextIndex)
                }
            }
        } else {
            complete()
        }
    }
    
    
    
    func advanceToPostBreakdown() {
        spotlightFrame = .zero

        isNavigatingToSettle = true

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStepIndex = 5
        }

        // Navigate to review to show the quick assign bar
        router?.handleTutorialNavigation(for: 5)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.isNavigatingToSettle = false
        }
    }

    func skip() {
        isNavigatingToSettle = false
        hasCompletedTutorial = true
        
        // Clear tutorial data first
        clearTutorialData()
        
        // Reset all tutorial state
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        isNavigatingToSettle = false
        shouldOpenBreakdownSheet = false
        shouldAutoApplyBreakdown = false
        shouldTriggerSplitDemo = false
        showClickAnimation = false
        shouldShowPaywallAfterTutorial = true
        
        // Navigate to upload root
        router?.resetToUpload()
        
        // Complete the tutorial
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isActive = false
            hasCompletedTutorial = true
        }
    }
    

    func complete() {
        guard !isNavigatingToSettle else {
            print("complete() suppressed — navigation to settle in progress")
            return
        }

        clearTutorialData()

        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        isNavigatingToSettle = false
        shouldOpenBreakdownSheet = false
        shouldAutoApplyBreakdown = false
        shouldTriggerSplitDemo = false
        showClickAnimation = false
        shouldShowPaywallAfterTutorial = true

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isActive = false
            hasCompletedTutorial = true
        }
    }

    func reset() {
        currentStepIndex = 0
        hasCompletedTutorial = false
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        isNavigatingToSettle = false
        shouldOpenBreakdownSheet = false
        shouldAutoApplyBreakdown = false
        shouldTriggerSplitDemo = false
        shouldShowPaywallAfterTutorial = false
        showClickAnimation = false
    }
    
    // MARK: - Click Animation Helper
    
    func showClickAnimation(at position: CGPoint) {
        clickAnimationPosition = position
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showClickAnimation = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) {
                self?.showClickAnimation = false
            }
        }
    }

    // MARK: - Tutorial Data

    func setupTutorialData() {
        guard let appState = appState else { return }

        // The app tutorial is always a normal split-mode demo. If the user had
        // Group Mode active, turn it off so mock Alex and the tutorial split
        // state are never replaced by group members.
        GroupManager.shared.disableGroupMode()

        appState.transactions.removeAll()
        appState.uploadedReceipts.removeAll()

        // Always reset to only Alex — clears any stale people from previous sessions
        appState.people.removeAll { !$0.isCurrentUser }
        appState.people.append(Person(name: "Alex", isCurrentUser: false))
        guard let currentUser = appState.people.first(where: { $0.isCurrentUser }) else { return }

        let sampleImage = createSampleReceiptImage()
        let imageData = sampleImage.jpegData(compressionQuality: 0.8) ?? Data()

        let lineItems = [
            ReceiptLineItem(name: "ARTISAN ROLL",    originalPrice: 6.99,  discount: 0, amount: 6.99,  taxPortion: 0.56, isSelected: true),
            ReceiptLineItem(name: "SHIN RAMYUN",     originalPrice: 15.99, discount: 0, amount: 15.99, taxPortion: 1.28, isSelected: true),
            ReceiptLineItem(name: "1895 CHERRY TOV", originalPrice: 7.49,  discount: 0, amount: 7.49,  taxPortion: 0.60, isSelected: true),
            ReceiptLineItem(name: "KS CHOPONION",    originalPrice: 4.39,  discount: 0, amount: 4.39,  taxPortion: 0.35, isSelected: true),
            ReceiptLineItem(name: "KIMCHI",          originalPrice: 7.99,  discount: 0, amount: 7.99,  taxPortion: 0.64, isSelected: true)
        ]
        let transaction = Transaction(
            amount: 46.28, merchant: "Sample Grocery Store", paidBy: currentUser,
            splitWith: appState.people, receiptImage: imageData,
            includeInSplit: true, isManual: false, lineItems: lineItems
        )
        appState.transactions.append(transaction)
        print("Tutorial data ready: 1 transaction, \(appState.people.count) people")
    }

    private func clearTutorialData() {
        guard let appState = appState else { return }

        appState.transactions.removeAll()
        appState.uploadedReceipts.removeAll()
        appState.uploadedImages.removeAll()
        appState.manualTransactions.removeAll()

        appState.people.removeAll { !$0.isCurrentUser }

        print("Tutorial data cleared — app state is clean for real use")
    }

    private func createSampleReceiptImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 500))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 500))
            let headerAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 18), .foregroundColor: UIColor.black]
            let smallAttrs: [NSAttributedString.Key: Any]  = [.font: UIFont.systemFont(ofSize: 12),     .foregroundColor: UIColor.darkGray]
            let itemAttrs: [NSAttributedString.Key: Any]   = [.font: UIFont.systemFont(ofSize: 13),     .foregroundColor: UIColor.black]
            let totalAttrs: [NSAttributedString.Key: Any]  = [.font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black]
            "SAMPLE GROCERY".draw(at: CGPoint(x: 80, y: 20), withAttributes: headerAttrs)
            "02/10/2026".draw(at: CGPoint(x: 120, y: 50), withAttributes: smallAttrs)
            let line = UIBezierPath()
            line.move(to: CGPoint(x: 20, y: 80)); line.addLine(to: CGPoint(x: 280, y: 80))
            UIColor.gray.setStroke(); line.lineWidth = 1; line.stroke()
            let items = [("ARTISAN ROLL","$6.99"),("SHIN RAMYUN","$15.99"),("1895 CHERRY TOV","$7.49"),("KS CHOPONION","$4.39"),("KIMCHI","$7.99")]
            var y = 100.0
            for (name, price) in items {
                name.draw(at: CGPoint(x: 20, y: y), withAttributes: itemAttrs)
                price.draw(at: CGPoint(x: 220, y: y), withAttributes: itemAttrs)
                y += 30
            }
            y += 20
            let div = UIBezierPath()
            div.move(to: CGPoint(x: 20, y: y)); div.addLine(to: CGPoint(x: 280, y: y))
            UIColor.gray.setStroke(); div.stroke()
            y += 15; "SUBTOTAL".draw(at: CGPoint(x: 20, y: y), withAttributes: itemAttrs); "$42.85".draw(at: CGPoint(x: 220, y: y), withAttributes: itemAttrs)
            y += 25; "TAX".draw(at: CGPoint(x: 20, y: y), withAttributes: itemAttrs); "$3.43".draw(at: CGPoint(x: 220, y: y), withAttributes: itemAttrs)
            y += 25; "TOTAL".draw(at: CGPoint(x: 20, y: y), withAttributes: totalAttrs); "$46.28".draw(at: CGPoint(x: 210, y: y), withAttributes: totalAttrs)
            y += 50; "THANK YOU!".draw(at: CGPoint(x: 105, y: y), withAttributes: smallAttrs)
        }
    }

    init() {}
}

// MARK: - Preference Key

struct TutorialFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Spotlight Masks

struct SpotlightMask: View {
    let cutoutRect: CGRect
    let cornerRadius: CGFloat
    var body: some View {
        GeometryReader { _ in
            ZStack {
                Rectangle().fill(Color.white)
                if cutoutRect != .zero {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white)
                        .frame(width: cutoutRect.width, height: cutoutRect.height)
                        .position(x: cutoutRect.midX, y: cutoutRect.midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
    }
}

struct MultiSpotlightMask: View {
    let cutoutRects: [CGRect]
    let cornerRadius: CGFloat
    var body: some View {
        GeometryReader { _ in
            ZStack {
                Rectangle().fill(Color.white)
                ForEach(cutoutRects.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white)
                        .frame(width: cutoutRects[i].width, height: cutoutRects[i].height)
                        .position(x: cutoutRects[i].midX, y: cutoutRects[i].midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
    }
}

// MARK: - Per-View Tutorial Overlay

struct TutorialOverlay: View {
    @EnvironmentObject var tutorialManager: TutorialManager
    let context: TutorialViewContext

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if tutorialManager.isActive,
                   let step = tutorialManager.currentStep,
                   tutorialManager.isCurrentStep(in: context) {

                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .allowsHitTesting(true)
                        .zIndex(0)

                    // Only show dark overlay for specific contexts
                    if context == .upload || context == .people || context == .settle || context == .profile {
                        if step.targetView == .settleAll || step.targetView == .uploadAndManual {
                            multiSpotlightOverlay
                                .allowsHitTesting(true)
                                .zIndex(1)

                            if step.targetView == .uploadAndManual {
                                VStack {
                                    Spacer()
                                    tutorialCard(step: step)
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 44)
                                }
                                .zIndex(3)
                            } else {
                                VStack {
                                    tutorialCard(step: step)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 56)
                                    Spacer()
                                }
                                .zIndex(3)
                            }

                        } else {
                            overlayWithCutout(step: step)
                                .allowsHitTesting(true)
                                .zIndex(1)

                            tutorialCardPositioned(step: step, in: geometry)
                                .zIndex(3)
                        }
                    } else {
                        // No dark overlay for review context - just tutorial card
                        tutorialCardPositioned(step: step, in: geometry)
                            .zIndex(3)
                    }
                    
                    // Add click animation overlay
                    if tutorialManager.showClickAnimation {
                        ClickAnimationView(position: tutorialManager.clickAnimationPosition)
                            .zIndex(5)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private var multiSpotlightOverlay: some View {
        let _ = tutorialManager.frameUpdateTick

        let pad: CGFloat = 12
        let cutouts = tutorialManager.activeMultiFrames.map { frame in
            CGRect(x: frame.minX - pad, y: frame.minY - pad,
                   width: frame.width + pad * 2, height: frame.height + pad * 2)
        }

        return Color.black.opacity(0.75)
            .ignoresSafeArea()
            .mask(MultiSpotlightMask(cutoutRects: cutouts, cornerRadius: 18))
    }

    @ViewBuilder
    private func tutorialCardPositioned(step: TutorialStep, in geometry: GeometryProxy) -> some View {
        let sf           = tutorialManager.spotlightFrame
        let screenHeight = geometry.size.height
        let inBottomHalf = sf != .zero && sf.midY > screenHeight / 2
     
        // Force bottom placement for these steps
        let forcedBottom: [TutorialStep.TutorialTarget] = [
            .uploadSection,
            .peopleAddContact,
            .quickAssignBar
        ]
        
        // Force top placement
        let forcedTop: [TutorialStep.TutorialTarget] = [.nextButton, .continueButton]
        
        // Special positioning for breakdown - place it lower to show items with compact card
        if step.targetView == .breakdownConfirm {
            VStack {
                compactTutorialCard(step: step)
                    .padding(.horizontal, 20)
                    .padding(.top, 450)
                Spacer()
            }
        }
        // Special card for Step 7 (Settle) with Group Mode example
        else if tutorialManager.currentStepIndex == 7 && context == .settle {
            VStack {
                tutorialCardWithGroupModeExample(step: step)
                    .padding(.horizontal, 20)
                    .padding(.top, 60)
                Spacer()
            }
        }
        // Bottom placement for specified targets (includes all Quick Mode steps)
        else if forcedBottom.contains(step.targetView) || (!forcedTop.contains(step.targetView) && !inBottomHalf) {
            VStack {
                Spacer()
                tutorialCard(step: step).padding(.horizontal, 20).padding(.bottom, 44)
            }
        }
        // Top placement for others
        else {
            VStack {
                tutorialCard(step: step)
                    .padding(.horizontal, 20)
                    .padding(.top, 60)
                Spacer()
            }
        }
    }
    
    
    private func compactTutorialCard(step: TutorialStep) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<tutorialManager.totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= tutorialManager.currentStepIndex
                              ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.18))
                        .frame(height: 3).frame(maxWidth: .infinity)
                }
            }

            Text(step.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                .multilineTextAlignment(.center)
                .lineLimit(1)

            Text(step.description)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.88))
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: {
                    HapticManager.impact(style: .light)
                    tutorialManager.skip()
                }) {
                    Text("Skip")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle())

                Button(action: {
                    HapticManager.impact(style: .medium)
                    tutorialManager.nextStep()
                }) {
                    HStack(spacing: 5) {
                        Text("Next").font(.system(size: 12, weight: .bold))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .cornerRadius(10)
                }
                .buttonStyle(ScaleButtonStyle())
            }

            Text("\(tutorialManager.currentStepIndex + 1) of \(tutorialManager.totalSteps)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.5))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.96, green: 0.96, blue: 0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.2), radius: 20, y: 5)
        )
    }
    
    
    private func tutorialCardWithGroupModeExample(step: TutorialStep) -> some View {
        VStack(spacing: 16) {
            // Progress bar
            HStack(spacing: 6) {
                ForEach(0..<tutorialManager.totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= tutorialManager.currentStepIndex
                              ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.18))
                        .frame(height: 4).frame(maxWidth: .infinity)
                }
            }

            Text(step.title)
                .font(.system(size: 20, weight: .bold)).foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                .multilineTextAlignment(.center).lineLimit(2)

            Text(step.description)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.88))
                .multilineTextAlignment(.center).lineSpacing(2).lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)

            // Group Mode Payment Example Card
            VStack(spacing: 12) {
                Text("In Group Mode:")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Mock payment card
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Text("A")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                            )
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Alex")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                            Text("You owe")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.58))
                        }
                        
                        Spacer()
                        
                        Text("$23.14")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    }
                    
                    // Payment buttons
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            VenmoIcon(size: 14)
                            Text("VENMO")
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .cornerRadius(8)
                        
                        HStack(spacing: 6) {
                            ZelleIcon(size: 14)
                            Text("ZELLE")
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .cornerRadius(8)
                    }
                }
                .padding(14)
                .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.18), lineWidth: 1.5)
                )
                
                // Educational message
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    
                    Text("But if your friend has Dutch, it's so much easier for you to pay and your friend to receive!")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.78))
                        .lineSpacing(2)
                }
                .padding(12)
                .background(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.10))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.22), lineWidth: 1)
                )
            }
            .padding(.vertical, 8)

            // Buttons
            HStack(spacing: 12) {
                Button(action: { HapticManager.impact(style: .light); tutorialManager.skip() }) {
                    Text("Skip")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color(red: 0.96, green: 0.96, blue: 0.94)).cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle())

                Button(action: { HapticManager.impact(style: .medium); tutorialManager.nextStep() }) {
                    HStack(spacing: 6) {
                        Text("Next").font(.system(size: 14, weight: .bold))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color(red: 0.15, green: 0.15, blue: 0.15)).cornerRadius(12)
                    .shadow(color: Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.25), radius: 8, y: 4)
                }
                .buttonStyle(ScaleButtonStyle())
            }

            Text("\(tutorialManager.currentStepIndex + 1) of \(tutorialManager.totalSteps)")
                .font(.system(size: 11, weight: .medium)).foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.5))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.96, green: 0.96, blue: 0.94))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5))
                .shadow(color: Color.black.opacity(0.2), radius: 20, y: 6)
        )
    }
    
    
    private func overlayWithCutout(step: TutorialStep) -> some View {
        let pad: CGFloat = 12
        let frame   = tutorialManager.spotlightFrame
        let hasHole = frame != .zero && step.targetView != .fullScreen
        let cutout  = hasHole
            ? CGRect(x: frame.minX - pad, y: frame.minY - pad,
                     width: frame.width + pad * 2, height: frame.height + pad * 2)
            : .zero
        let opacity: Double = step.targetView == .breakdownConfirm ? 0 : 0.75

        return Color.black.opacity(opacity)
            .ignoresSafeArea()
            .mask(SpotlightMask(cutoutRect: cutout, cornerRadius: 18))
    }

    private func tutorialCard(step: TutorialStep) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(0..<tutorialManager.totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= tutorialManager.currentStepIndex
                              ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.18))
                        .frame(height: 4).frame(maxWidth: .infinity)
                }
            }

            if tutorialManager.currentStepIndex == 0 {
                AnimatedProfileIconInCard()
            }

            Text(step.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(step.description)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.88))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if tutorialManager.isLastStep {
                    Button(action: {
                        HapticManager.notification(type: .success)
                        tutorialManager.complete()
                    }) {
                        HStack(spacing: 8) {
                            Text("Get Started").font(.system(size: 15, weight: .bold))
                            Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .cornerRadius(12)
                        .shadow(color: Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.25), radius: 8, y: 4)
                    }
                    .buttonStyle(ScaleButtonStyle())
                } else {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        tutorialManager.skip()
                    }) {
                        Text("Skip")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())

                    Button(action: {
                        HapticManager.impact(style: .medium)
                        tutorialManager.nextStep()
                    }) {
                        HStack(spacing: 6) {
                            Text(nextButtonLabel).font(.system(size: 14, weight: .bold))
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .cornerRadius(12)
                        .shadow(color: Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.3), radius: 8, y: 4)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }

            Text("\(tutorialManager.currentStepIndex + 1) of \(tutorialManager.totalSteps)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.5))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.96, green: 0.96, blue: 0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.2), radius: 20, y: 6)
            )
        .overlay(alignment: .top) {
            if tutorialManager.currentStepIndex == 0 {
                AnimatedProfileIconOverlay()
            }
        }
    }
    
    private var nextButtonLabel: String {
        switch tutorialManager.currentStepIndex {
        case 0:  return "Start"
        case 4:  return "Continue"
        default: return "Next"
        }
    }
}

struct AnimatedProfileIconOverlay: View {
    @State private var scale: CGFloat = 1.0
    @State private var yOffset: CGFloat = -100
    @State private var showCircleOverlay = true

    var body: some View {
        ZStack {
            Image("Picture")
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
 
            Circle()
                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.35), lineWidth: 2)
                .frame(width: 56, height: 56)
        }
        .offset(y: 45)
    }
}

struct AnimatedProfileIconInCard: View {
    var body: some View {
        Color.clear.frame(width: 56, height: 56)
    }
}

// MARK: - Click Animation View

struct ClickAnimationView: View {
    let position: CGPoint
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 1.0
    @State private var pulseScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Outer expanding ring
            Circle()
                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.8), lineWidth: 4)
                .frame(width: 60, height: 60)
                .scaleEffect(scale)
                .opacity(opacity * 0.6)
            
            // Inner solid circle with pulse
            Circle()
                .fill(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.9))
                .frame(width: 28, height: 28)
                .scaleEffect(pulseScale)
                .opacity(opacity)
            
            // Tap indicator
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .opacity(opacity)
        }
        .position(position)
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) {
                scale = 1.8
                opacity = 0
            }
            
            withAnimation(.easeInOut(duration: 0.5).repeatCount(2, autoreverses: true)) {
                pulseScale = 1.2
            }
        }
    }
}

// MARK: - Single-target Spotlight Modifier

struct TutorialSpotlight: ViewModifier {
    let isHighlighted: Bool
    @EnvironmentObject var tutorialManager: TutorialManager

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TutorialFrameKey.self,
                        value: isHighlighted ? geo.frame(in: .global) : .zero
                    )
                }
            )
            .onPreferenceChange(TutorialFrameKey.self) { frame in
                if isHighlighted && frame != .zero {
                    DispatchQueue.main.async { tutorialManager.spotlightFrame = frame }
                } else if !isHighlighted && tutorialManager.spotlightFrame != .zero {
                    DispatchQueue.main.async { tutorialManager.spotlightFrame = .zero }
                }
            }
    }
}

// MARK: - Multi-target Spotlight Modifier

struct TutorialMultiSpotlight: ViewModifier {
    let target: TutorialStep.TutorialTarget
    let isActive: Bool
    @EnvironmentObject var tutorialManager: TutorialManager
    @State private var reportedFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.frame(in: .global)) { newFrame in
                            guard isActive, newFrame.width > 0 else { return }
                            tutorialManager.registerFrame(newFrame, for: target)
                        }
                        .onAppear {
                            let frame = geo.frame(in: .global)
                            if isActive && frame.width > 0 {
                                tutorialManager.registerFrame(frame, for: target)
                            }
                        }
                        .onChange(of: isActive) { newValue in
                            guard newValue else {
                                tutorialManager.registerFrame(.zero, for: target)
                                return
                            }
                            for i in 1...20 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                                    let frame = geo.frame(in: .global)
                                    guard frame.width > 0 else { return }
                                    tutorialManager.registerFrame(frame, for: target)
                                }
                            }
                        }
                        .onChange(of: tutorialManager.currentStepIndex) { index in
                            // Changed from (index == 1 || (index >= 5 && index <= 7)) to new indices
                            guard (index == 1 || (index >= 5 && index <= 8)), isActive else { return }
                            for i in 1...20 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                                    let frame = geo.frame(in: .global)
                                    guard frame.width > 0 else { return }
                                    tutorialManager.registerFrame(frame, for: target)
                                }
                            }
                        }
                }
            )
    }
}


extension View {
    func tutorialSpotlight(isHighlighted: Bool, cornerRadius: CGFloat = 16) -> some View {
        modifier(TutorialSpotlight(isHighlighted: isHighlighted))
    }

    func tutorialMultiSpotlight(target: TutorialStep.TutorialTarget, isActive: Bool) -> some View {
        modifier(TutorialMultiSpotlight(target: target, isActive: isActive))
    }
}

// MARK: - Tutorial Welcome View

struct TutorialWelcomeView: View {
    @EnvironmentObject var tutorialManager: TutorialManager

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.88), Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.65), Color(.systemBackground)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()
                ZStack {
                    Circle().fill(Color.white).frame(width: 120, height: 120)
                        .shadow(color: Color.black.opacity(0.2), radius: 20, y: 10)
                    Image(systemName: "person.3.fill").font(.system(size: 50)).foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                }
                VStack(spacing: 12) {
                    Text("Welcome to Dutch").font(.system(size: 32, weight: .bold)).foregroundColor(.white)
                    Text("Split bills with friends effortlessly")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.9)).multilineTextAlignment(.center)
                }
                Spacer()
                VStack(spacing: 14) {
                    Button(action: { HapticManager.impact(style: .medium); tutorialManager.start() }) {
                        Text("Start Tutorial")
                            .font(.system(size: 17, weight: .bold)).foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                            .frame(maxWidth: .infinity).padding(.vertical, 18).background(Color.white)
                            .cornerRadius(14).shadow(color: Color.black.opacity(0.2), radius: 12, y: 4)
                    }.buttonStyle(ScaleButtonStyle())

                    Button(action: { HapticManager.impact(style: .light); tutorialManager.skip() }) {
                        Text("Skip")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.white.opacity(0.2)).cornerRadius(14)
                    }.buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 32).padding(.bottom, 40)
            }
        }
    }
}
