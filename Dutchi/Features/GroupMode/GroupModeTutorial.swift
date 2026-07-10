// GroupModeTutorial.swift - FINAL with Scroll-First Timing
// Changes:
// 1. Scroll FIRST, spotlight AFTER scroll completes
// 2. Added notification badge state for Activity section

import SwiftUI
import Combine

// MARK: - Group Mode Tutorial Steps

struct GroupModeTutorialStep: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let description: String
    let targetView: GroupModeTutorialTarget
    let action: GroupModeTutorialAction?
    
    static func == (lhs: GroupModeTutorialStep, rhs: GroupModeTutorialStep) -> Bool {
        lhs.id == rhs.id
    }
    
    enum GroupModeTutorialTarget {
        case groupModeIcon
        case groupNameInput
        case contactPicker
        case inviteButton
        case reviewView
        case settleShareSection
        case createGroupButton
        case payNowButton
        case requestButton
        case quickSettleSection
        case quickSettleNewestTransaction
        case quickSettleAllActivity
        case activitySection
        case balanceSummary
        case fullScreen
    }
    
    enum GroupModeTutorialAction {
        case none
        case openGroupCreation
        case navigateToContacts
        case showInviteFlow
        case navigateToReview
        case navigateToSettle
        case returnToUpload
        case scrollToActivity
    }
}

// MARK: - Group Mode Tutorial Manager

class GroupModeTutorialManager: ObservableObject {
    @Published var isActive = false
    @Published var currentStepIndex = 0
    @Published var spotlightFrame: CGRect = .zero
    @Published var spotlightFrames: [GroupModeTutorialStep.GroupModeTutorialTarget: CGRect] = [:]
    @Published var frameUpdateTick: Int = 0
    
    // Mock state for tutorial
    @Published var shouldOpenGroupCreation = false
    @Published var shouldShowContactPicker = false
    @Published var mockGroupName = ""
    @Published var mockSelectedContacts: [String] = []
    @Published var shouldShowGroupQuickController = false
    
    // Scroll trigger for activity section
    @Published var shouldScrollToActivity = false
    
    // NEW: Show notification badge on Activity header
    @Published var showActivityNotification = false
    
    // NEW: Hide spotlight until scroll completes
    @Published var hideSpotlightDuringScroll = false
    
    @AppStorage("hasSeenGroupModeTutorial") var hasCompletedGroupModeTutorial = false
    @AppStorage("dutchie.onboardingGroupModeTutorialRequired") var onboardingGroupModeTutorialRequired = false
    
    weak var router: Router?
    weak var appState: AppState?
    weak var groupManager: GroupManager?
    
    let steps: [GroupModeTutorialStep] = [
        // Step 0 - Welcome
        GroupModeTutorialStep(
            title: "Welcome to Group Mode",
            description: "Let me show you how to create a group and split expenses with friends instantly!",
            targetView: .fullScreen,
            action: .none
        ),
        
        // Step 1 - Upload quick controller
        GroupModeTutorialStep(
            title: "Use the Group Menu",
            description: "This is where you turn Weekend Trip on or off, add or delete groups, and jump into Pay Now / Settle when you need to review balances.",
            targetView: .groupModeIcon,
            action: .none
        ),
        
        // Step 2 - Initial Balance View (You are owed)
        GroupModeTutorialStep(
            title: "You Added an Expense",
            description: "You paid $50 for dinner. Tony owes you $25. Tap Request to send him a payment request.",
            targetView: .settleShareSection,
            action: .navigateToSettle
        ),
        
        // Step 3 - Tony Added Transaction (Now you owe)
        GroupModeTutorialStep(
            title: "Tony Just Added $60!",
            description: "Tony added a new expense, and now you only owe him $5. Since he has Venmo and Zelle, you can pay instantly.",
            targetView: .settleShareSection,
            action: .none
        ),
        
        // Step 4 - Activity & Mark as Paid
        GroupModeTutorialStep(
            title: "Track Everything",
            description: "Use Settle newest transaction for the latest item, or Settle all group activity when the whole group is paid.",
            targetView: .activitySection,
            action: .scrollToActivity
        ),
        
        // Step 5 - Loop Back (NO SPOTLIGHT)
        GroupModeTutorialStep(
            title: "You're All Set!",
            description: "Start a new group anytime to split and settle with friends. When you enable Group Mode, you can always check how much you owe or are owed.",
            targetView: .fullScreen,
            action: .returnToUpload
        )
    ]
    
    var currentStep: GroupModeTutorialStep? {
        guard currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }
    
    var isLastStep: Bool { currentStepIndex >= steps.count - 1 }
    var totalSteps: Int { steps.count }
    
    // MARK: - Multi-spotlight helpers
    
    var isMultiSpotlight: Bool {
        guard let step = currentStep else { return false }
        return step.targetView == .settleShareSection || step.targetView == .activitySection
    }
    
    func registerFrame(_ frame: CGRect, for target: GroupModeTutorialStep.GroupModeTutorialTarget) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.spotlightFrames[target] != frame {
                self.spotlightFrames[target] = frame
                self.frameUpdateTick += 1
                print("🎯 Group Tutorial: Registered frame for \(target): \(frame)")
            }
        }
    }
    
    var activeMultiFrames: [CGRect] {
        guard isMultiSpotlight, let step = currentStep else { return [] }
        
        // NEW: Don't show spotlight if hiding during scroll
        if hideSpotlightDuringScroll {
            return []
        }
        
        if step.targetView == .settleShareSection {
            if currentStepIndex == 2 {
                return [
                    spotlightFrames[.balanceSummary],
                    spotlightFrames[.requestButton]
                ].compactMap { $0 }.filter { $0 != .zero }
            }
            else if currentStepIndex == 3 {
                return [
                    spotlightFrames[.balanceSummary],
                    spotlightFrames[.payNowButton],
                    spotlightFrames[.requestButton]
                ].compactMap { $0 }.filter { $0 != .zero }
            }
        }
        else if step.targetView == .activitySection {
            return [
                spotlightFrames[.quickSettleSection],
                spotlightFrames[.activitySection]
            ].compactMap { $0 }.filter { $0 != .zero }
        }

        return []
    }
    
    // MARK: - Lifecycle
    
    func start() {
        print("🎯 Starting Group Mode Tutorial")
        hasCompletedGroupModeTutorial = false
        onboardingGroupModeTutorialRequired = true
        isActive = true
        currentStepIndex = 0
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        mockGroupName = ""
        mockSelectedContacts = []
        shouldScrollToActivity = false
        showActivityNotification = false
        hideSpotlightDuringScroll = false
        shouldShowGroupQuickController = false
        shouldShowGroupQuickController = false
        setupMockData()
    }
    
    func nextStep() {
        print("🎯 Group Tutorial nextStep called - current: \(currentStepIndex), total steps: \(steps.count)")
        print("🎯 Tutorial isActive: \(isActive)")
        print("🔍 GroupModeTutorial instance ID: \(ObjectIdentifier(self))")
        
        guard currentStepIndex < steps.count else {
            print("⚠️ Already at or past last step")
            return
        }
        
        // CRITICAL: Ensure tutorial stays active
        if !isActive {
            print("⚠️ Tutorial was inactive, reactivating")
            isActive = true
        }
        
        // Step 0 → Step 1: Create mock Weekend Trip and open the group quick controller
        if currentStepIndex == 0 {
            spotlightFrame = .zero
            spotlightFrames = [:]
            setupMockData()
            createMockGroupStep3()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.router?.resetToUpload()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.shouldShowGroupQuickController = true
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        self.currentStepIndex = 1
                    }
                    self.frameUpdateTick += 1
                }
            }
            return
        }
        
        // Step 1 → Step 2: Close quick controller and navigate to Settle Share
        if currentStepIndex == 1 {
            print("🔄 Step 1 → 2: Opening Settle Share from quick controller")
            print("🔄 Tutorial isActive before transition: \(self.isActive)")
            
            spotlightFrame = .zero
            spotlightFrames = [:]
            shouldShowGroupQuickController = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                
                print("🔄 Navigating to Settle Share with mock Weekend Trip")
                print("🔄 Tutorial isActive during navigation: \(self.isActive)")
                
                self.isActive = true
                self.router?.navigateToSettle()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    print("✅ Navigation complete, activating step 2")
                    self.isActive = true
                    
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        self.currentStepIndex = 2
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.frameUpdateTick += 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.frameUpdateTick += 1
                    }
                }
            }
            return
        }
        
        // Step 2 → Step 3: Tony adds expense
        if currentStepIndex == 2 {
            print("🔄 Step 2 → 3: Tony adding expense")
            
            // Add Tony's expense
            addTonyExpenseStep4()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.isActive = true
                
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    self.currentStepIndex = 3
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.frameUpdateTick += 1
                }
            }
            return
        }
        
        // Step 3 → Step 4: Show activity section (SCROLL FIRST, THEN SPOTLIGHT)
        if currentStepIndex == 3 {
            print("🔄 Step 3 → 4: Starting scroll-first transition")
            
            // STEP 1: Hide spotlight during transition
            hideSpotlightDuringScroll = true
            
            // STEP 2: Advance to step 4 (renders Activity section)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                self.currentStepIndex = 4
            }
            
            // STEP 3: Show notification badge on Activity
            showActivityNotification = true
            
            // STEP 4: Wait for view to render, then trigger scroll
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                print("📜 Triggering scroll to activity")
                self.shouldScrollToActivity = true
                
                // STEP 5: After scroll completes, show spotlight
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    print("✅ Scroll complete, showing spotlight")
                    self.hideSpotlightDuringScroll = false
                    self.frameUpdateTick += 1
                    
                    // Update frames again after short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.frameUpdateTick += 1
                    }
                }
            }
            
            return
        }
        
        // Step 4 → Step 5: Navigate back to upload
        if currentStepIndex == 4 {
            print("🔄 Step 4 → 5: Navigating back to upload")
            spotlightFrame = .zero
            spotlightFrames = [:]
            shouldScrollToActivity = false
            showActivityNotification = false
            hideSpotlightDuringScroll = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                self.router?.resetToUpload()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        self.currentStepIndex = 5
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.frameUpdateTick += 1
                    }
                }
            }
            return
        }
        
        // Step 5 → Complete
        if currentStepIndex == 5 {
            print("🏁 Tutorial complete")
            complete()
            return
        }
    }
    
    func skip() {
        print("🛑 Tutorial skipped - cleaning up")
        
        // Clear mock data FIRST
        clearMockData()
        
        // Reset all tutorial state
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        shouldOpenGroupCreation = false
        shouldShowContactPicker = false
        shouldScrollToActivity = false
        showActivityNotification = false
        hideSpotlightDuringScroll = false
        shouldShowGroupQuickController = false
        
        // Close any open sheets
        router?.closeGroupCreationSheet()
        
        // Navigate back to upload
        router?.resetToUpload()
        
        // Mark as completed (so it doesn't show again) and deactivate
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isActive = false
            hasCompletedGroupModeTutorial = true
            onboardingGroupModeTutorialRequired = false
        }
        
        print("✅ Tutorial skipped and cleaned up")
    }

    func complete() {
        print("🏁 Tutorial completing - cleaning up mock data")
        
        // Clear mock data FIRST
        clearMockData()
        
        // Reset all tutorial state
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        shouldOpenGroupCreation = false
        shouldShowContactPicker = false
        shouldScrollToActivity = false
        showActivityNotification = false
        hideSpotlightDuringScroll = false
        shouldShowGroupQuickController = false
        
        // Close any open sheets
        router?.closeGroupCreationSheet()
        
        // Navigate back to upload (clean state)
        router?.resetToUpload()
        
        // Mark tutorial as completed and deactivate
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isActive = false
            hasCompletedGroupModeTutorial = true
            onboardingGroupModeTutorialRequired = false
        }
        
        print("✅ Tutorial completed and cleaned up - user can start fresh")
    }
    

    func reset() {
        currentStepIndex = 0
        hasCompletedGroupModeTutorial = false
        spotlightFrame = .zero
        spotlightFrames = [:]
        frameUpdateTick = 0
        shouldScrollToActivity = false
        showActivityNotification = false
        hideSpotlightDuringScroll = false
    }
    
    // MARK: - Mock Data
    
    private func setupMockData() {
        guard let appState = appState else { return }
        appState.transactions.removeAll()
        // Isolate tutorial — remove stale people from previous sessions
        appState.people.removeAll { !$0.isCurrentUser }
    }
    
    // Step 3: You paid $50, Tony owes you $25
    private func createMockGroupStep3() {
        guard let appState = appState,
              let groupManager = groupManager else { return }
        
        // Create Tony as ACCEPTED member (not pending)
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        let currentUserMember = GroupMember(
            id: currentUser?.id ?? UUID(),
            name: currentUser?.name ?? "Me",
            phoneNumber: appState.profile.zelleContactInfo,
            imageData: appState.profile.avatarImage,
            isCurrentUser: true,
            isPending: false,
            venmoUsername: appState.profile.venmoUsername,
            venmoLink: appState.profile.venmoPaymentLink,
            zelleEmail: appState.profile.zelleContactInfo,
            zelleLink: appState.profile.zellePaymentLink
        )
        
        let tonyMember = GroupMember(
            id: UUID(),
            name: "Tony",
            phoneNumber: "+1234567890",
            imageData: nil,
            isCurrentUser: false,
            isPending: false,
            venmoUsername: nil,
            venmoLink: nil,
            zelleEmail: nil,
            zelleLink: nil
        )
        
        groupManager.createTutorialGroup(name: "Weekend Trip", members: [currentUserMember, tonyMember])

        if let group = groupManager.allGroups.first(where: { $0.name == "Weekend Trip" }) {
            // Add initial expense: You paid $50 for dinner
            let dinnerExpense = GroupExpense(
                id: UUID(),
                groupID: group.id,
                addedByID: currentUserMember.id,
                addedByName: currentUserMember.name,
                description: "Dinner",
                amount: 50.00,
                date: Date(),
                splitAmongIDs: [currentUserMember.id, tonyMember.id],
                isArchived: false
            )

            groupManager.addTutorialExpense(dinnerExpense)
        }

        groupManager.syncMembersToAppState(appState)
        
        print("✅ Mock group created: Weekend Trip (Step 3 - You are owed $25)")
    }
    
    // Step 4: Tony adds $60 expense, now you owe him $5
    private func addTonyExpenseStep4() {
        guard let groupManager = groupManager,
              let group = groupManager.activeGroup else { return }
        
        let tonyMember = group.members.first(where: { $0.name == "Tony" })
        let currentUserMember = group.members.first(where: { $0.isCurrentUser })
        
        guard let tony = tonyMember, let currentUser = currentUserMember else { return }
        
        // Update Tony to have Venmo and Zelle
        var updatedTony = tony
        updatedTony.venmoUsername = "@tony-venmo"
        updatedTony.venmoLink = "venmo://paycharge?txn=pay&recipients=tony-venmo"
        updatedTony.zelleEmail = "tony@example.com"
        updatedTony.zelleLink = "zelle://payment?token=tony@example.com"
        
        // Update the member in the group
        if let index = groupManager.activeGroup?.members.firstIndex(where: { $0.id == tony.id }) {
            groupManager.activeGroup?.members[index] = updatedTony
        }
        if let groupIndex = groupManager.allGroups.firstIndex(where: { $0.id == group.id }),
           let memberIndex = groupManager.allGroups[groupIndex].members.firstIndex(where: { $0.id == tony.id }) {
            groupManager.allGroups[groupIndex].members[memberIndex] = updatedTony
        }
        
        // Tony adds $60 expense
        let groceriesExpense = GroupExpense(
            id: UUID(),
            groupID: group.id,
            addedByID: tony.id,
            addedByName: tony.name,
            description: "Groceries",
            amount: 60.00,
            date: Date(),
            splitAmongIDs: [currentUser.id, tony.id],
            isArchived: false
        )
        
        groupManager.addTutorialExpense(groceriesExpense)

        print("✅ Tony added $60 expense - Balance updated (Step 4 - You owe $5)")
    }
    
    private func clearMockData() {
        print("🧹 Clearing all mock tutorial data")
        
        guard let appState = appState,
              let groupManager = groupManager else {
            print("⚠️ Missing appState or groupManager")
            return
        }
        
        // 1. Remove the tutorial mock group from local state (no Firebase deletion)
        groupManager.removeTutorialGroup(named: "Weekend Trip")
        print("✅ Removed mock group 'Weekend Trip'")
        
        // 2. Ensure Group Mode is disabled
        if groupManager.isGroupModeEnabled {
            groupManager.disableGroupMode()
            print("✅ Disabled Group Mode")
        }
        
        // 3. Remove mock Tony from people list
        if let tonyIndex = appState.people.firstIndex(where: { $0.name == "Tony" && !$0.isCurrentUser }) {
            appState.people.remove(at: tonyIndex)
            print("✅ Removed mock Tony from people")
        }
        
        // 4. Clear any tutorial transactions
        appState.transactions.removeAll()
        print("✅ Cleared transactions")
        
        // 5. Reset any tutorial-specific state
        mockGroupName = ""
        mockSelectedContacts = []
        
        print("✅ Mock data cleanup complete - app is in fresh state")
    }
}

// Rest of the overlay code stays the same...
struct GroupModeTutorialOverlay: View {
    let context: GroupModeTutorialViewContext
    @ObservedObject var tutorialManager: GroupModeTutorialManager
    
    enum GroupModeTutorialViewContext {
        case upload
        case groupCreation
        case settle
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if tutorialManager.isActive,
                   let step = tutorialManager.currentStep,
                   isCurrentStep(in: context) {
                    let isQuickControllerStep = step.targetView == .groupModeIcon

                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .allowsHitTesting(true)
                        .zIndex(0)
                    
                    // Dark overlay with spotlight cutouts only when the target is
                    // reliably visible. Covered steps use a plain dim overlay.
                    if !isQuickControllerStep && shouldShowOverlay(for: step.targetView) {
                        if tutorialManager.isMultiSpotlight {
                            multiSpotlightOverlay
                                .allowsHitTesting(true)
                                .zIndex(1)
                        } else {
                            overlayWithCutout(step: step)
                                .allowsHitTesting(true)
                                .zIndex(1)
                        }
                    } else if !isQuickControllerStep && shouldShowPlainOverlay(for: step.targetView) {
                        plainOverlay
                            .allowsHitTesting(true)
                            .zIndex(1)
                    }
                    
                    // Tutorial card
                    tutorialCardPositioned(step: step, in: geometry)
                        .zIndex(3)
                }
            }
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
    }
    
    private func isCurrentStep(in context: GroupModeTutorialViewContext) -> Bool {
        guard let step = tutorialManager.currentStep else {
            print("❌ No current step")
            return false
        }
        
        let isMatch: Bool
        switch context {
        case .upload:
            isMatch = (step.targetView == .fullScreen && (tutorialManager.currentStepIndex == 0 || tutorialManager.currentStepIndex == 5)) ||
                      step.targetView == .groupModeIcon
        case .groupCreation:
            isMatch = step.targetView == .groupNameInput || (step.targetView == .fullScreen && tutorialManager.currentStepIndex == 2)
        case .settle:
            isMatch = step.targetView == .settleShareSection || step.targetView == .activitySection
        }
        
        print("🎯 Overlay isCurrentStep check - Context: \(context), Step: \(tutorialManager.currentStepIndex), Target: \(step.targetView), Match: \(isMatch)")
        
        return isMatch
    }
    
    private func shouldShowOverlay(for target: GroupModeTutorialStep.GroupModeTutorialTarget) -> Bool {
        switch target {
        case .groupModeIcon:
            return false
        case .groupNameInput:
            return tutorialManager.spotlightFrames[.groupNameInput] != nil
        case .settleShareSection:
            return !tutorialManager.activeMultiFrames.isEmpty
        case .activitySection:
            return !tutorialManager.activeMultiFrames.isEmpty
        default:
            return false
        }
    }

    private func shouldShowPlainOverlay(for target: GroupModeTutorialStep.GroupModeTutorialTarget) -> Bool {
        switch target {
        case .groupModeIcon:
            return false
        case .groupNameInput:
            return tutorialManager.spotlightFrames[.groupNameInput] == nil
        case .activitySection:
            return tutorialManager.activeMultiFrames.isEmpty
        case .settleShareSection:
            return tutorialManager.activeMultiFrames.isEmpty
        default:
            return false
        }
    }

    private var plainOverlay: some View {
        Color.black.opacity(0.75)
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
    
    private func overlayWithCutout(step: GroupModeTutorialStep) -> some View {
        let _ = tutorialManager.frameUpdateTick
        
        var frame: CGRect = .zero
        var pad: CGFloat = 18
        
        switch step.targetView {
        case .groupModeIcon:
            frame = tutorialManager.spotlightFrames[.groupModeIcon] ?? .zero
            pad = 10
        case .groupNameInput:
            frame = tutorialManager.spotlightFrames[.groupNameInput] ?? .zero
            frame = frame.offsetBy(dx: 0, dy: -55)
            pad = 10
            
        case .settleShareSection:
            frame = tutorialManager.spotlightFrames[.settleShareSection] ?? .zero
        case .activitySection:
            frame = tutorialManager.spotlightFrames[.activitySection] ?? .zero
            pad = 14
        default:
            frame = .zero
        }
        
        let hasHole = frame != .zero
        let cutout = hasHole
            ? CGRect(
                x: frame.minX - pad,
                y: frame.minY - pad,
                width: frame.width + pad * 2,
                height: frame.height + pad * 2
              )
            : .zero
        
        print("🎯 Overlay cutout for \(step.targetView): frame=\(frame), hasHole=\(hasHole)")
        
        return Color.black.opacity(0.75)
            .ignoresSafeArea()
            .mask(SpotlightMask(cutoutRect: cutout, cornerRadius: 18))
    }
    
    @ViewBuilder
    private func tutorialCardPositioned(step: GroupModeTutorialStep, in geometry: GeometryProxy) -> some View {
        // For fullScreen steps, always position at bottom
        if step.targetView == .fullScreen {
            VStack {
                Spacer()
                tutorialCard(step: step)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 44)
            }
        } else if step.targetView == .settleShareSection &&
                    (tutorialManager.currentStepIndex == 2 || tutorialManager.currentStepIndex == 3) {
            VStack {
                tutorialCard(step: step)
                    .padding(.horizontal, 20)
                    .padding(.top, 60)
                Spacer()
            }
        } else if step.targetView == .activitySection {
            VStack {
                Spacer()
                tutorialCard(step: step)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 44)
            }
        } else if step.targetView == .groupModeIcon {
            VStack {
                Spacer()
                tutorialCard(step: step)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        } else {
            // Get frame based on target
            let sf: CGRect = {
                switch step.targetView {
                case .groupModeIcon:
                    return tutorialManager.spotlightFrames[.groupModeIcon] ?? .zero
                case .groupNameInput:
                    return tutorialManager.spotlightFrames[.groupNameInput] ?? .zero
                case .settleShareSection:
                    return tutorialManager.spotlightFrames[.settleShareSection] ?? .zero
                case .activitySection:
                    return tutorialManager.spotlightFrames[.activitySection] ?? .zero
                default:
                    return .zero
                }
            }()
            
            let screenHeight = geometry.size.height
            let inBottomHalf = sf != .zero && sf.midY > screenHeight / 2
            
            let forcedBottom: [GroupModeTutorialStep.GroupModeTutorialTarget] = [
                .groupModeIcon,
                .groupNameInput,
                .settleShareSection
            ]
            
            let forcedTop: [GroupModeTutorialStep.GroupModeTutorialTarget] = [
            ]
            
            if forcedBottom.contains(step.targetView) || (!forcedTop.contains(step.targetView) && !inBottomHalf) {
                VStack {
                    Spacer()
                    tutorialCard(step: step)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 140)
                }
            } else {
                VStack {
                    tutorialCard(step: step)
                        .padding(.horizontal, 20)
                        .padding(.top, 60)
                    Spacer()
                }
            }
        }
    }
    
    
    private func tutorialCard(step: GroupModeTutorialStep) -> some View {
        VStack(spacing: 16) {
            // Progress bar
            HStack(spacing: 6) {
                ForEach(0..<tutorialManager.totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= tutorialManager.currentStepIndex
                              ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color.white.opacity(0.25))
                        .frame(height: 4)
                        .frame(maxWidth: .infinity)
                }
            }
            
            Text(step.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            
            Text(step.description)
                .font(.system(size: descriptionFontSize, weight: .medium))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.88))
                .multilineTextAlignment(.center)
                .lineSpacing(tutorialManager.currentStepIndex == 2 || tutorialManager.currentStepIndex == 3 ? 1 : 2)
                .lineLimit(tutorialManager.currentStepIndex == 2 || tutorialManager.currentStepIndex == 3 ? 5 : 4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, tutorialManager.currentStepIndex == 1 ? 18 : 0)
            
            // Buttons
            HStack(spacing: 12) {
                if tutorialManager.isLastStep {
                    Button(action: {
                        HapticManager.notification(type: .success)
                        tutorialManager.complete()
                    }) {
                        HStack(spacing: 8) {
                            Text("Get Started")
                                .font(.system(size: 15, weight: .bold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .cornerRadius(12)
                        .shadow(color: Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.3), radius: 8, y: 4)
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
                            Text(nextButtonLabel)
                                .font(.system(size: 14, weight: .bold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .bold))
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
    }
    
    private var nextButtonLabel: String {
        switch tutorialManager.currentStepIndex {
        case 0: return "Start"
        default: return "Next"
        }
    }

    private var descriptionFontSize: CGFloat {
        switch tutorialManager.currentStepIndex {
        case 2, 3:
            return 10
        default:
            return 12
        }
    }
}


struct GroupModeTutorialSpotlight: ViewModifier {
    let isHighlighted: Bool
    let target: GroupModeTutorialStep.GroupModeTutorialTarget
    @EnvironmentObject var groupModeTutorial: GroupModeTutorialManager
    
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
                    DispatchQueue.main.async {
                        groupModeTutorial.registerFrame(frame, for: target)
                    }
                }
            }
    }
}

extension View {
    func groupModeTutorialSpotlight(
        isHighlighted: Bool,
        target: GroupModeTutorialStep.GroupModeTutorialTarget
    ) -> some View {
        modifier(GroupModeTutorialSpotlight(isHighlighted: isHighlighted, target: target))
    }
}
