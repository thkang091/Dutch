import SwiftUI
import UIKit
import Messages
import MessageUI
import UserNotifications

// MARK: - Message Compose Coordinator
class MessageComposeCoordinator: NSObject, MFMessageComposeViewControllerDelegate {
    static let shared = MessageComposeCoordinator()
    
    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
    }
}

struct MessageComposePayload: Identifiable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

private enum GroupSettleTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case balances = "Balances"
    case members = "Members"

    var id: String { rawValue }
}

private struct ActivityMonthSection: Identifiable {
    let id: String
    let title: String
    let expenses: [GroupExpense]
}

private struct ExpenseSessionSummary: Identifiable {
    let uploadSessionID: UUID
    let expenses: [GroupExpense]
    let total: Double
    let latestDate: Date

    var id: UUID { uploadSessionID }

    init(uploadSessionID: UUID, expenses: [GroupExpense]) {
        self.uploadSessionID = uploadSessionID
        self.expenses = expenses
        self.total = expenses.reduce(0) { $0 + $1.amount }
        self.latestDate = expenses.map(\.date).max() ?? Date()
    }
}

private struct GroupMemberSectionSnapshot {
    let groupID: UUID
    let inviteAvailability: GroupInviteAvailability
    let balances: [BalanceSummary]
    let leftMembers: [GroupMember]
    let canManagePendingInvites: Bool
}

private struct ActivityRenderSnapshot {
    let groupID: UUID
    let signature: String
    let sections: [ActivityMonthSection]
    let sessionSummaries: [ExpenseSessionSummary]
}

struct SettleShareView: View {
    @State private var hasCreatedReceipt = false
    @State private var hasSavedSplitHistory = false

    

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @StateObject private var groupManager = GroupManager.shared
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var showPaymentLanding = false
    @State private var refreshTrigger: UUID = UUID()
    @State private var tutorialRefresh = false

    @State private var landingFromName: String = ""
    @State private var landingToName: String = ""
    @State private var landingAmount: Double = 0
    @State private var landingReceiptId: UUID = UUID()
    @State private var isLoadingReceipt = false
    
    private let ivory  = Color(red: 1.0,  green: 0.992, blue: 0.969)
    private let ink    = Color(red: 0.10, green: 0.10,  blue: 0.10)
    private let chalk  = Color(red: 0.95, green: 0.945, blue: 0.933)
    private let border = Color(red: 0.82, green: 0.80,  blue: 0.776)
    
    @State private var settlements: [PaymentLink] = []
    @State private var receiptId: UUID? = nil  // ✅ Start as nil
    @State private var showReceiptView = false
    @State private var showCopyToast = false
    @State private var copyToastMessage = "COPIED TO CLIPBOARD"
    @State private var activeNormalModeActionID: String?
    @State private var hasAppeared = false
    @State private var showAddMember = false
    @State private var composePayload: MessageComposePayload?
    @State private var currentGroup: DutchieGroup?
    @State private var selectedGroupTab: GroupSettleTab = .balances
    @State private var selectedGroupCardID: UUID?
    @State private var receiptGroupForSheet: DutchieGroup?
    @State private var showGroupJumpPicker = false
    @State private var activitySearchText = ""
    @State private var activityMinAmount = ""
    @State private var activityMaxAmount = ""
    @State private var collapsedActivityMonthIDs: Set<String> = []
    @GestureState private var groupCardDragOffset: CGFloat = 0
    
    // ✅ NEW: Make these state variables instead of computed properties
    @State private var cachedCurrentUserBalance: Double = 0.0
    @State private var cachedAmountToPay: Double = 0.0
    @State private var cachedAmountToReceive: Double = 0.0
    @State private var cachedGroupBalances: [BalanceSummary] = []
    @State private var cachedVisibleGroups: [DutchieGroup] = []
    @State private var groupSnapshotsByID: [UUID: GroupPresentationSnapshot] = [:]
    @State private var memberSectionSnapshotsByID: [UUID: GroupMemberSectionSnapshot] = [:]
    @State private var currentGroupSnapshot: GroupPresentationSnapshot?
    @State private var lastGroupRenderSignature = ""
    @State private var isApplyingSettlementChange = false
    @State private var cachedActivitySnapshot: ActivityRenderSnapshot?
    @State private var activitySnapshotWorkItem: DispatchWorkItem?
    @State private var settleRenderWorkItem: DispatchWorkItem?
    
    private let canSendText = MFMessageComposeViewController.canSendText()
    
    private var groupModeTutorial: GroupModeTutorialManager {
        guard let tutorial = router.groupModeTutorial else {
            fatalError("❌ FATAL: GroupModeTutorialManager not set in router!")
        }
        return tutorial
    }

    private var shouldUseGroupModeUI: Bool {
        groupManager.isGroupModeEnabled && (!tutorialManager.isActive || groupModeTutorial.isActive)
    }

    private var activeGroupIsProtectedSubscriptionGroup: Bool {
        guard let group = currentGroup ?? groupManager.activeGroup else { return false }
        guard !group.isSubscriptionInviteStaging else { return false }
        return group.maxMemberCount != nil ||
            TrialManager.shared.ownedSubscriptionGroupID == group.id ||
            TrialManager.shared.sharedSubscriptionGroupID == group.id ||
            TrialManager.shared.activeSubscriptionPoolGroupID == group.id
    }
    
    
    private func registerBalanceSummaryFrameIfNeeded(_ frame: CGRect) {
        if groupModeTutorial.isActive &&
           (groupModeTutorial.currentStepIndex == 2 || groupModeTutorial.currentStepIndex == 3) &&
           frame != .zero {
            DispatchQueue.main.async {
                groupModeTutorial.registerFrame(frame, for: .balanceSummary)
            }
        }
    }

    private func registerRequestFrameIfNeeded(_ frame: CGRect) {
        if groupModeTutorial.isActive &&
           (groupModeTutorial.currentStepIndex == 2 || groupModeTutorial.currentStepIndex == 3) &&
           frame != .zero {
            DispatchQueue.main.async {
                groupModeTutorial.registerFrame(frame, for: .requestButton)
            }
        }
    }

    private func registerActivityFrameIfNeeded(_ frame: CGRect) {
        if groupModeTutorial.isActive &&
           groupModeTutorial.currentStepIndex == 4 &&
           frame != .zero {
            DispatchQueue.main.async {
                groupModeTutorial.registerFrame(frame, for: .activitySection)
            }
        }
    }

    private func registerQuickSettleFrameIfNeeded(_ frame: CGRect) {
        if groupModeTutorial.isActive &&
           groupModeTutorial.currentStepIndex == 4 &&
           frame != .zero {
            DispatchQueue.main.async {
                groupModeTutorial.registerFrame(frame, for: .quickSettleSection)
            }
        }
    }

    private func registerQuickSettleRowFrameIfNeeded(
        _ frame: CGRect,
        for target: GroupModeTutorialStep.GroupModeTutorialTarget
    ) {
        if groupModeTutorial.isActive &&
           groupModeTutorial.currentStepIndex == 4 &&
           frame != .zero {
            DispatchQueue.main.async {
                groupModeTutorial.registerFrame(frame, for: target)
            }
        }
    }
    
      
    // MARK: - Computed Properties
    
    private var effectiveTransactions: [Transaction] {
        if shouldUseGroupModeUI,
           let group = groupManager.activeGroup {
            return group.expenses.map { expense in
                let payer = appState.people.first(where: { $0.id == expense.addedByID })
                         ?? appState.people.first(where: { $0.name == expense.addedByName })
                         ?? appState.people[0]
                
                let splitWithPeople = expense.splitAmongIDs.compactMap { id in
                    appState.people.first(where: { $0.id == id })
                }
                
                return Transaction(
                    amount: expense.amount,
                    merchant: expense.description,
                    paidBy: payer,
                    splitWith: splitWithPeople,
                    receiptImage: nil,
                    includeInSplit: true,
                    isManual: false,
                    lineItems: []
                )
            }
        } else {
            return appState.transactions
        }
    }
    
    var currentUserBalance: Double {
        if shouldUseGroupModeUI, let group = currentGroup {
            guard let userId = currentMemberID(in: group) else { return 0 }

            if let cached = cachedGroupBalances.first(where: { $0.member.id == userId }) {
                return cached.netBalance
            }

            return 0
        } else {
            var balance: Double = 0
            let currentUserId = appState.people.first(where: { $0.isCurrentUser })?.id
            for settlement in settlements {
                if settlement.from.id == currentUserId { balance -= settlement.amount }
                else if settlement.to.id == currentUserId { balance += settlement.amount }
            }
            return balance
        }
    }
    
    var totalAmount: Double {
        if shouldUseGroupModeUI, let group = currentGroup {
            return group.totalExpenses
        } else {
            return effectiveTransactions.filter { $0.includeInSplit }.reduce(0.0) { $0 + $1.amount }
        }
    }
    
    var settlementsYouOwe: [PaymentLink] {
        let currentUserId = currentGroup.flatMap { currentMemberID(in: $0) }
            ?? appState.people.first(where: { $0.isCurrentUser })?.id
        return settlements.filter { $0.from.id == currentUserId }
    }
    
    var settlementsYouReceive: [PaymentLink] {
        let currentUserId = currentGroup.flatMap { currentMemberID(in: $0) }
            ?? appState.people.first(where: { $0.isCurrentUser })?.id
        return settlements.filter { $0.to.id == currentUserId }
    }
    
    var amountToPay: Double {
        currentUserBalance < 0 ? abs(currentUserBalance) : 0
    }
    
    var amountToReceive: Double {
        currentUserBalance > 0 ? currentUserBalance : 0
    }
    
    private func updateCachedBalances() {
        cachedCurrentUserBalance = currentUserBalance
        cachedAmountToPay = amountToPay
        cachedAmountToReceive = amountToReceive
    }
    
    // MARK: - Share Status Helpers
    
    private func isSharePaid(expenseID: UUID, memberID: UUID) -> Bool {
        guard let group = currentGroup,
              let shares = group.expenseShares[expenseID],
              let share = shares.first(where: { $0.memberID == memberID }) else {
            return false
        }
        return share.status == .paid
    }
    
    private func allSharesPaid(expenseID: UUID) -> Bool {
        guard let group = currentGroup,
              let expense = group.expenses.first(where: { $0.id == expenseID }) else {
            return false
        }

        if expense.settled {
            return true
        }

        guard let shares = group.expenseShares[expenseID], !shares.isEmpty else {
            return false
        }

        return shares
            .filter { $0.memberID != expense.addedByID }
            .allSatisfy { $0.status == .paid }
    }
    
    private func currentUserShareIsPaid(expenseID: UUID) -> Bool {
        guard let currentUserID = appState.people.first(where: { $0.isCurrentUser })?.id else {
            return false
        }
        return isSharePaid(expenseID: expenseID, memberID: currentUserID)
    }
    
    private func isExpensePaid(_ transaction: Transaction) -> Bool {
        guard let group = currentGroup,
              let expense = group.expenses.first(where: { $0.description == transaction.merchant }) else {
            return false
        }
        
        if let currentUserID = appState.people.first(where: { $0.isCurrentUser })?.id {
            return isSharePaid(expenseID: expense.id, memberID: currentUserID)
        }
        
        return false
    }
    
    
    private var normalModeContent: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("YOU PAID")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ink.opacity(0.45))
                        .tracking(1.5)
                    
                    Text(String(format: "$%.2f", totalAmount))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(ink)
                        .tracking(-0.5)
                }
                
                HStack(spacing: 0) {
                    statCell(value: "\(appState.people.count)", label: "PEOPLE")
                    Rectangle().fill(border.opacity(0.6)).frame(width: 1, height: 32)
                    statCell(value: "\(settlements.count)", label: "PAYMENTS")
                    Rectangle().fill(border.opacity(0.6)).frame(width: 1, height: 32)
                    statCell(value: String(format: "$%.0f", totalAmount), label: "TOTAL")
                }
                .padding(.top, 4)
                .overlay(
                    Rectangle().fill(border.opacity(0.5)).frame(height: 1),
                    alignment: .top
                )
                
                Button(action: {
                    HapticManager.impact(style: .light)
                    openReceipt(for: currentGroup)
                }) {
                    HStack(spacing: 8) {
                        ReceiptIcon(size: 11)
                        Text("VIEW RECEIPT")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1)
                    }
                    .foregroundColor(ink.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.clear)
                    .cornerRadius(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundColor(border)
                    )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.98))
            }
            .padding(18)
            .background(chalk)
            .cornerRadius(3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(border, lineWidth: 1))
            
            // Tutorial-only: Mock Group Mode Payment Card
            if tutorialManager.isActive && tutorialManager.currentStepIndex == 7 {
                mockGroupModePaymentCard
            }
            
            if !settlementsYouOwe.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("YOU OWE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(red: 0.78, green: 0.25, blue: 0.18))
                            .tracking(1.5)
                        Spacer()
                        Text(String(format: "$%.2f", abs(currentUserBalance)))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(red: 0.78, green: 0.25, blue: 0.18))
                    }
                    .padding(.horizontal, 4)

                    if shouldShowShareAllInline {
                        shareAllInlineButton
                    }
                    
                    ForEach(settlementsYouOwe) { settlement in
                        normalModePaymentRow(settlement: settlement)
                    }
                }
            }
            
            if !settlementsYouReceive.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(settlementsYouOwe.isEmpty ? "YOU ARE OWED" : "RECEIVING")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(ink.opacity(0.40))
                            .tracking(1.5)
                        Spacer()
                        if settlementsYouOwe.isEmpty {
                            Text(String(format: "$%.2f", currentUserBalance))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
                        }
                    }
                    .padding(.horizontal, 4)

                    if settlementsYouOwe.isEmpty && shouldShowShareAllInline {
                        shareAllInlineButton
                    }
                    
                    ForEach(settlementsYouReceive) { settlement in
                        normalModeRequestRow(settlement: settlement)
                    }
                }
            }
        }
    }
    
    
    private var shouldHighlightRequestCard: Bool {
        tutorialManager.isActive && tutorialManager.currentStepIndex == 7
    }

    private var shouldHighlightPaymentCard: Bool {
        tutorialManager.isActive && tutorialManager.currentStepIndex == 7
    }

    private var shouldShowShareAllInline: Bool {
        !shouldUseGroupModeUI && settlements.count > 1
    }

    private var shareAllInlineButton: some View {
        Button(action: {
            HapticManager.impact(style: .medium)
            shareAllPayments()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .bold))
                Text("SHARE ALL")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.9)
            }
            .foregroundColor(ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(ivory)
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .foregroundColor(border)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }
    
    
    private var mockGroupModePaymentCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(
                    imageData: nil,
                    initials: "A",
                    size: 44
                )
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Alex")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ink)
                    Text("You owe (when your friend has Dutch)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ink.opacity(0.45))
                }
                
                Spacer()
                
                Text("$23.14")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(red: 0.78, green: 0.25, blue: 0.18))
            }
            
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    VenmoIcon(size: 14)
                    Text("VENMO")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.5)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(red: 0.18, green: 0.50, blue: 0.90))
                .cornerRadius(2)
                
                HStack(spacing: 6) {
                    ZelleIcon(size: 14)
                    Text("ZELLE")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.5)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(red: 0.38, green: 0.16, blue: 0.58))
                .cornerRadius(2)
            }
        }
        .padding(16)
        .background(Color(red: 0.97, green: 0.89, blue: 0.87))
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color(red: 0.78, green: 0.25, blue: 0.18).opacity(0.3), lineWidth: 1.5)
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TutorialFrameKey.self,
                    value: shouldHighlightPaymentCard ? geo.frame(in: .global) : .zero
                )
            }
        )
        .onPreferenceChange(TutorialFrameKey.self) { frame in
            if shouldHighlightPaymentCard && frame != .zero {
                DispatchQueue.main.async {
                    tutorialManager.registerFrame(frame, for: .settlePayment)
                }
            }
        }
    }
    var body: some View {
        ZStack {
            // Main content
            ZStack {
                ivory.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    headerSection
                    dashedDivider.padding(.horizontal, 20)
                    
                    // ✅ UPDATED SCROLLVIEW WITH READER
                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 20) {
                                if shouldUseGroupModeUI {
                                    groupModeContent
                                } else {
                                    normalModeContent
                                }
                            }
                            .padding(20)
                            .padding(.bottom, 140)
                        }
                        .onChange(of: groupModeTutorial.shouldScrollToActivity) { oldValue, newValue in
                            if newValue {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                                    selectedGroupTab = .activity
                                }

                                // The Activity section only exists after the tab switch lays out.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    withAnimation(.easeInOut(duration: 0.8)) {
                                        scrollProxy.scrollTo("activitySection", anchor: .top)
                                    }
                                }

                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                                    groupModeTutorial.frameUpdateTick += 1
                                    groupModeTutorial.shouldScrollToActivity = false
                                }
                            }
                        }
                    }
                    
                    dashedDivider.padding(.horizontal, 20)
                    bottomCTA
                }
                if showCopyToast {
                    VStack {
                        Spacer()
                        copyToastView
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .zIndex(100)
                }
            }
            
            // Tutorial overlays...
            if tutorialManager.isActive && !groupModeTutorial.isActive {
                TutorialOverlay(context: .settle)
                    .zIndex(1000)
            }
            
            
            // Group Mode Tutorial overlay - SHOW WHENEVER ACTIVE
            if groupModeTutorial.isActive {
                GroupModeTutorialOverlay(
                    context: .settle,
                    tutorialManager: groupModeTutorial
                )
                .zIndex(2000)
                .id("tutorial-\(tutorialRefresh)")  // Force rebuild when tutorialRefresh changes
            }
        }
        .id("settle-\(groupModeTutorial.isActive)-\(groupModeTutorial.currentStepIndex)")  // ADD THIS
        .navigationBarBackButtonHidden(true)
        .keyboardDoneToolbar()
        .onAppear {
            if shouldUseGroupModeUI {
                selectedGroupTab = .balances
            }

            guard !hasAppeared else { return }
            hasAppeared = true
            
            if shouldUseGroupModeUI {
                currentGroup = groupManager.activeGroup
                selectedGroupCardID = groupManager.activeGroup?.id
                cachedVisibleGroups = resolvedVisibleGroups()
                scheduleSettleRenderRefresh(reason: "appear-group", after: 0.18)
            } else {
                scheduleSettleRenderRefresh(reason: "appear-normal", after: 0.05)
            }

            if !shouldUseGroupModeUI {
                saveSplitHistoryIfNeeded()
            }
            
            ensureReceiptReadyForBalances()
            
            setupNotificationActions()

            if !shouldUseGroupModeUI {
                sendAllPaymentNotifications()
            }
        }
        
        
        .onChange(of: groupModeTutorial.currentStepIndex) { oldValue, newValue in
            if newValue == 4 {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    selectedGroupTab = .activity
                }
            }

            if newValue == 2 || newValue == 3 || newValue == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    refreshTrigger = UUID()
                    groupModeTutorial.frameUpdateTick += 1
                }
            }
        }
        .onChange(of: groupModeTutorial.isActive) { oldValue, newValue in
            tutorialRefresh.toggle() // Force view refresh
            
            if newValue && (groupModeTutorial.currentStepIndex == 2 || groupModeTutorial.currentStepIndex == 3) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    refreshTrigger = UUID()
                    groupModeTutorial.frameUpdateTick += 1
                }
            }
        }
        .onChange(of: activitySearchText) { _, _ in
            scheduleActivitySnapshotRefresh()
        }
        .onChange(of: activityMinAmount) { _, _ in
            scheduleActivitySnapshotRefresh()
        }
        .onChange(of: activityMaxAmount) { _, _ in
            scheduleActivitySnapshotRefresh()
        }
        .onReceive(groupManager.$activeGroup) { updatedGroup in
            if let updated = updatedGroup, groupManager.isGroupModeEnabled {
                guard !isApplyingSettlementChange else { return }

                if groupModeTutorial.isActive {
                    selectedGroupCardID = updated.id
                    setCurrentGroupFromCachedSnapshotOrRaw(updated)
                    scheduleSettleRenderRefresh(for: updated, reason: "tutorial-active-group", after: 0.08)
                    return
                }

                if let selectedGroupCardID, selectedGroupCardID != updated.id {
                    return
                }

                let signature = groupRenderSignature(updated)
                guard signature != lastGroupRenderSignature else { return }
                lastGroupRenderSignature = signature
                currentGroup = updated
                if selectedGroupCardID == nil {
                    selectedGroupCardID = updated.id
                }
                cachedVisibleGroups = resolvedVisibleGroups()
                scheduleSettleRenderRefresh(for: updated, reason: "active-group", after: 0.10)
            }
        }
        .onReceive(groupManager.$allGroups) { groups in
            guard groupManager.isGroupModeEnabled,
                  !isApplyingSettlementChange,
                  let selectedID = selectedGroupCardID ?? currentGroup?.id,
                  let updated = groups.first(where: { $0.id == selectedID }) else { return }

            let signature = groupRenderSignature(updated)
            guard signature != lastGroupRenderSignature else { return }
            lastGroupRenderSignature = signature
            currentGroup = updated
            cachedVisibleGroups = resolvedVisibleGroups()
            scheduleSettleRenderRefresh(for: updated, reason: "all-groups", after: 0.12)
        }
        .onDisappear {
            activitySnapshotWorkItem?.cancel()
            activitySnapshotWorkItem = nil
            settleRenderWorkItem?.cancel()
            settleRenderWorkItem = nil
        }
        .sheet(isPresented: $showReceiptView, onDismiss: {
            receiptGroupForSheet = nil
        }) {
            NavigationView {
                if let receiptId = receiptId {
                    ReceiptView(receiptId: receiptId)
                        .id(receiptId)
                        .environmentObject(appState)
                        .environmentObject(router)
                        .environmentObject(tutorialManager)
                } else {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.3)
                        Text("Loading receipt...")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            if receiptId == nil {
                                showReceiptView = false
                            }
                        }
                    }
                }
            }
        }
         
        
        .sheet(isPresented: $showPaymentLanding) {
            PaymentLandingSheet(
                fromName:  landingFromName,
                toName:    landingToName,
                amount:    landingAmount,
                receiptId: landingReceiptId
            )
            .environmentObject(appState)
            .environmentObject(router)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddMember) {
            if let group = currentGroup {
                AddMemberSheet(groupManager: groupManager, groupID: group.id)
            }
        }
        .sheet(item: $composePayload) { payload in
            GroupMessageComposeView(
                recipients: payload.recipients,
                messageBody: payload.body,
                isPresented: Binding(get: { composePayload != nil }, set: { if !$0 { composePayload = nil } })
            )
            .ignoresSafeArea()
        }
    }
    
    // MARK: - Fairness Signal

    private func checkFairnessSignal() {
        guard let group = currentGroup else { return }
        guard let currentUserID = currentGroup.flatMap({ currentMemberID(in: $0) }) else { return }

        // Sum what the current user has paid vs what they owe across all expenses
        var totalPaid: Double = 0
        var totalOwed: Double = 0

        let balances = balancesForDisplay(group)
        for balance in balances where balance.member.id == currentUserID {
            totalPaid = balance.totalPaid
            totalOwed = balance.totalOwed
        }

        // Signal fires when the user has paid at least $20 more than their share
        // and has covered a meaningfully larger portion than average
        let surplus = totalPaid - totalOwed
        guard surplus >= 20 else { return }

        let avgPaid = group.totalExpenses / Double(max(1, group.activeMemberCount))
        guard totalPaid > avgPaid * 1.25 else { return }

        NotificationManager.shared.notifyFairnessSignal(groupName: group.name)
    }

    // MARK: - Group Mode Payment Notifications
    
    /// ✅ NEW: Send payment notifications in Group Mode when others owe you money
    private func sendGroupModePaymentNotifications() {
        guard let group = currentGroup else { return }
        
        // Only send notifications for people who owe YOU money
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        
        for settlement in settlementsYouReceive {
            // settlement.from owes you money
            guard let member = group.members.first(where: { $0.name == settlement.from.name }),
                  let phone = member.phoneNumber,
                  !phone.isEmpty else {
                continue
            }
            
            // Find all expenses this person hasn't paid yet
            let unpaidExpenses = group.expenses.filter { expense in
                // Expense includes this person
                expense.splitAmongIDs.contains(member.id) &&
                // Person hasn't paid their share yet
                !isSharePaid(expenseID: expense.id, memberID: member.id) &&
                // Expense is not settled
                !expense.settled
            }
            
            guard !unpaidExpenses.isEmpty else { continue }
            
            // Send notification for the first unpaid expense
            // (or you could send one for each, or combine them)
            if let firstExpense = unpaidExpenses.first {
                let payerName = currentUser?.name ?? "Someone"
                let shareAmount = firstExpense.amount / Double(firstExpense.splitAmongIDs.count)
                
                NotificationManager.shared.notifyPaymentOwed(
                    expenseID: firstExpense.id,
                    groupName: group.name,
                    payerName: payerName,
                    expenseDescription: firstExpense.description,
                    totalAmount: firstExpense.amount,
                    yourShare: shareAmount
                )
                
                print("📲 Sent payment request notification to \(member.name) for \(String(format: "$%.2f", shareAmount))")
            }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 16) {
            Button(action: {
                HapticManager.impact(style: .light)
                router.navigateBack()
            }) {
                HStack(spacing: 6) {
                    ChevronLeftIcon(size: 12)
                    Text("BACK")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.5)
                }
                .foregroundColor(ink.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(ink.opacity(0.20), lineWidth: 1)
                )
            }
            .buttonStyle(ScaleButtonStyle())
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(shouldUseGroupModeUI ? "GROUP" : "SETTLE")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(ink.opacity(0.45))
                    .tracking(2)
                Text(shouldUseGroupModeUI ? "BALANCE" : "UP")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(ink)
                    .tracking(0.5)
            }
            
            Spacer()
            
            if shouldUseGroupModeUI && !activeGroupIsProtectedSubscriptionGroup {
                Menu {
                    Button(role: .destructive, action: {
                        HapticManager.impact(style: .medium)
                        leaveGroup()
                    }) {
                        Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    EllipsisIcon(size: 28)
                        .foregroundColor(ink.opacity(0.55))
                        .frame(width: 36, height: 36)
                }
            } else {
                Button(action: { router.presentProfile() }) {
                    if let currentUser = appState.people.first(where: { $0.isCurrentUser }) {
                        AvatarView(
                            imageData: currentUser.contactImage,
                            initials: currentUser.initials,
                            size: 36
                        )
                        .overlay(Circle().stroke(ink.opacity(0.15), lineWidth: 1))
                    } else {
                        AvatarView(imageData: nil, initials: "ME", size: 36)
                            .overlay(Circle().stroke(ink.opacity(0.15), lineWidth: 1))
                    }
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(ivory)
    }
    
    // MARK: - Normal Mode Content
    
   
    private var groupModeContent: some View {
        VStack(spacing: 20) {
            if let group = currentGroup {
                groupSummaryCarousel
                groupSegmentedControl
                selectedGroupSection(for: group)
            }
        }
    }

    private var visibleGroups: [DutchieGroup] {
        if !cachedVisibleGroups.isEmpty {
            return cachedVisibleGroups
        }

        return resolvedVisibleGroups()
    }

    private func resolvedVisibleGroups() -> [DutchieGroup] {
        var groups = groupManager.currentUserAvailableGroups

        if let active = groupManager.activeGroup, groupManager.isAvailableToCurrentUser(active) {
            groups.removeAll { $0.id == active.id }
            groups.insert(active, at: 0)
        } else if let group = currentGroup,
                  groupManager.isAvailableToCurrentUser(group),
                  !groups.contains(where: { $0.id == group.id }) {
            groups.insert(group, at: 0)
        }

        return groups
    }

    private func currentPersonForPresentation() -> Person? {
        appState.people.first(where: { $0.isCurrentUser })
    }

    private func makePresentationSnapshot(for group: DutchieGroup) -> GroupPresentationSnapshot {
        GroupPresentationService.shared.snapshot(
            for: group,
            trialManager: TrialManager.shared,
            groupManager: groupManager,
            profile: appState.profile,
            currentPerson: currentPersonForPresentation()
        )
    }

    private func refreshVisibleGroupSnapshots() {
        guard shouldUseGroupModeUI else {
            cachedVisibleGroups = []
            groupSnapshotsByID = [:]
            memberSectionSnapshotsByID = [:]
            currentGroupSnapshot = nil
            cachedGroupBalances = []
            cachedActivitySnapshot = nil
            return
        }

        let groups = resolvedVisibleGroups()
        cachedVisibleGroups = groups

        let selectedID = selectedGroupCardID ?? currentGroup?.id ?? groupManager.activeGroup?.id ?? groups.first?.id
        guard let selectedID,
              let selectedGroup = groups.first(where: { $0.id == selectedID }) else {
            currentGroupSnapshot = nil
            cachedGroupBalances = []
            cachedActivitySnapshot = nil
            return
        }

        let snapshot = makePresentationSnapshot(for: selectedGroup)
        groupSnapshotsByID = [selectedID: snapshot]
        memberSectionSnapshotsByID = [
            selectedID: makeMemberSectionSnapshot(for: snapshot.group, balances: snapshot.balances)
        ]
        currentGroupSnapshot = snapshot
        currentGroup = snapshot.group
        cachedGroupBalances = snapshot.balances
        refreshActivitySnapshotNow(for: snapshot.group)
        if selectedGroupCardID == nil {
            selectedGroupCardID = selectedID
        }
    }

    private func setCurrentGroupFromCachedSnapshotOrRaw(_ group: DutchieGroup) {
        selectedGroupCardID = group.id
        if let snapshot = groupSnapshotsByID[group.id] {
            currentGroupSnapshot = snapshot
            currentGroup = snapshot.group
            cachedGroupBalances = snapshot.balances
        } else {
            currentGroup = group
            currentGroupSnapshot = nil
            cachedGroupBalances = []
        }
    }

    private func scheduleSettleRenderRefresh(
        for group: DutchieGroup? = nil,
        reason: String,
        after delay: TimeInterval = 0.08
    ) {
        settleRenderWorkItem?.cancel()
        let targetGroup = group ?? currentGroup ?? groupManager.activeGroup
        let workItem = DispatchWorkItem {
            let start = CFAbsoluteTimeGetCurrent()

            if shouldUseGroupModeUI {
                if let targetGroup {
                    setCurrentGroupFromCachedSnapshotOrRaw(targetGroup)
                }
                refreshVisibleGroupSnapshots()
                recalculateSettlements()
            } else {
                recalculateSettlements()
            }
            updateCachedBalances()

            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if elapsedMs > 16 {
                print("🧭 PERF [settle:scheduled-render] reason=\(reason) ms=\(elapsedMs)")
            }
        }
        settleRenderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeMemberSectionSnapshot(
        for group: DutchieGroup,
        balances: [BalanceSummary]? = nil
    ) -> GroupMemberSectionSnapshot {
        let resolvedBalances = balances ?? groupSnapshotsByID[group.id]?.balances ?? cachedGroupBalances
        return GroupMemberSectionSnapshot(
            groupID: group.id,
            inviteAvailability: groupManager.inviteAvailability(for: group.id),
            balances: resolvedBalances,
            leftMembers: group.members.filter { $0.hasLeft },
            canManagePendingInvites: canManagePendingInvites(in: group)
        )
    }

    private func refreshMemberSectionSnapshot(for group: DutchieGroup) {
        let snapshotGroup = groupSnapshotsByID[group.id]?.group ?? group
        memberSectionSnapshotsByID[group.id] = makeMemberSectionSnapshot(
            for: snapshotGroup,
            balances: groupSnapshotsByID[group.id]?.balances ?? (group.id == currentGroup?.id ? cachedGroupBalances : nil)
        )
    }

    private func activitySnapshotSignature(for group: DutchieGroup) -> String {
        [
            groupRenderSignature(group),
            activitySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            activityMinAmount.trimmingCharacters(in: .whitespacesAndNewlines),
            activityMaxAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "|")
    }

    private func refreshActivitySnapshotNow(for group: DutchieGroup? = nil) {
        guard shouldUseGroupModeUI, let group = group ?? currentGroup else {
            cachedActivitySnapshot = nil
            return
        }

        let start = CFAbsoluteTimeGetCurrent()
        let signature = activitySnapshotSignature(for: group)
        guard cachedActivitySnapshot?.groupID != group.id ||
              cachedActivitySnapshot?.signature != signature else {
            return
        }

        cachedActivitySnapshot = ActivityRenderSnapshot(
            groupID: group.id,
            signature: signature,
            sections: activitySections(for: group),
            sessionSummaries: unsettledSessionSummaries(for: group)
        )

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        if elapsedMs > 16 {
            print("🧭 PERF [settle:activity-snapshot] ms=\(elapsedMs)")
        }
    }

    private func scheduleActivitySnapshotRefresh(for group: DutchieGroup? = nil, after delay: TimeInterval = 0.12) {
        activitySnapshotWorkItem?.cancel()
        let targetGroup = group ?? currentGroup
        let workItem = DispatchWorkItem {
            refreshActivitySnapshotNow(for: targetGroup)
        }
        activitySnapshotWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func currentMemberID(in group: DutchieGroup) -> UUID? {
        if let appUserID = appState.people.first(where: { $0.isCurrentUser })?.id,
           group.members.contains(where: { $0.id == appUserID }) {
            return appUserID
        }

        return group.members.first(where: { $0.isCurrentUser })?.id
    }

    private func groupAmounts(for group: DutchieGroup) -> (pay: Double, receive: Double) {
        guard let currentUserID = currentMemberID(in: group),
              let balance = balancesForDisplay(group).first(where: { $0.member.id == currentUserID }) else {
            return (0, 0)
        }

        return (
            pay: balance.netBalance < 0 ? abs(balance.netBalance) : 0,
            receive: balance.netBalance > 0 ? balance.netBalance : 0
        )
    }

    private func balancesForDisplay(_ group: DutchieGroup) -> [BalanceSummary] {
        if group.id == currentGroupSnapshot?.group.id {
            return cachedGroupBalances
        }

        return groupSnapshotsByID[group.id]?.balances ?? []
    }

    private func nextGroup(after group: DutchieGroup) -> DutchieGroup? {
        let groups = visibleGroups
        guard groups.count > 1,
              let index = groups.firstIndex(where: { $0.id == group.id }) else {
            return nil
        }

        return groups[(index + 1) % groups.count]
    }

    private func switchToGroup(_ group: DutchieGroup) {
        setCurrentGroupFromCachedSnapshotOrRaw(group)
        deferSettleAction {
            groupManager.setActiveGroup(group)
            scheduleSettleRenderRefresh(for: group, reason: "switch-group", after: 0.06)
        }
    }

    private func groupRenderSignature(_ group: DutchieGroup) -> String {
        let expenseSignature = group.expenses
            .map { expense in
                "\(expense.id.uuidString):\(expense.amount):\(expense.settled):\(expense.isArchived):\(expense.splitAmongIDs.count)"
            }
            .joined(separator: "|")
        let pendingShareCount = group.expenseShares.values
            .flatMap { $0 }
            .filter { $0.status == .pending }
            .count

        return "\(group.id.uuidString):\(group.members.count):\(group.expenses.count):\(pendingShareCount):\(expenseSignature)"
    }

    private var groupSummaryCarousel: some View {
        let groups = visibleGroups

        return GeometryReader { proxy in
            let cardWidth = proxy.size.width
            let selectedID = selectedGroupCardID ?? currentGroup?.id ?? groups.first?.id
            let selectedIndex = groups.firstIndex(where: { $0.id == selectedID }) ?? 0

            HStack(spacing: 0) {
                ForEach(groups) { group in
                    groupSummaryCard(group: group)
                        .padding(.horizontal, 2)
                        .frame(width: cardWidth)
                }
            }
            .offset(x: -CGFloat(selectedIndex) * cardWidth + groupCardDragOffset)
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.86, blendDuration: 0.08), value: selectedGroupCardID)
            .gesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .updating($groupCardDragOffset) { value, state, _ in
                        guard groups.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                        let rubberBandLimit = cardWidth * 0.34
                        state = max(-rubberBandLimit, min(rubberBandLimit, value.translation.width))
                    }
                    .onEnded { value in
                        guard groups.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }

                        let threshold = cardWidth * 0.18
                        let projected = value.predictedEndTranslation.width
                        let shouldMove = abs(value.translation.width) > threshold || abs(projected) > threshold
                        guard shouldMove else { return }

                        let direction = value.translation.width < 0 ? 1 : -1
                        let newIndex = min(max(selectedIndex + direction, 0), groups.count - 1)
                        guard newIndex != selectedIndex else { return }

                        HapticManager.impact(style: .light)
                        switchToGroup(groups[newIndex])
                    }
            )
        }
        .frame(height: visibleGroups.count > 1 ? 342 : 304)
        .onAppear {
            if selectedGroupCardID == nil {
                selectedGroupCardID = currentGroup?.id ?? groups.first?.id
            }
        }
    }

    private func groupSummaryCard(group: DutchieGroup) -> some View {
        let amounts = groupAmounts(for: group)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GROUP")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ink.opacity(0.45))
                        .tracking(1.5)

                    Text(group.name)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer()

                HStack(spacing: 5) {
                    Text(nextGroup(after: group).map { "SWIPE TO \($0.name.uppercased())" } ?? "ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                    if visibleGroups.count > 1 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundColor(ink.opacity(0.45))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(ink.opacity(0.06))
                .cornerRadius(2)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .onLongPressGesture(minimumDuration: 0.45) {
                    HapticManager.impact(style: .medium)
                    showGroupJumpPicker = true
                }
            }

            if visibleGroups.count > 1 {
                groupSummaryGroupStrip(activeGroup: group)
            }

            HStack(spacing: 12) {
                groupAmountTile(
                    label: "I HAVE TO PAY",
                    amount: amounts.pay,
                    color: Color(red: 0.78, green: 0.25, blue: 0.18)
                )
                .background(balanceSummaryRegistrationBackground(step: 3))

                groupAmountTile(
                    label: "I HAVE TO RECEIVE",
                    amount: amounts.receive,
                    color: Color(red: 0.18, green: 0.50, blue: 0.32)
                )
                .background(balanceSummaryRegistrationBackground(step: 2))
            }

            HStack(spacing: 0) {
                statCell(value: String(format: "$%.0f", group.totalExpenses), label: "TOTAL SPENT")
                Rectangle().fill(border.opacity(0.6)).frame(width: 1, height: 32)
                statCell(value: "\(group.activeMemberCount)", label: "MEMBERS")
                Rectangle().fill(border.opacity(0.6)).frame(width: 1, height: 32)
                statCell(value: "\(group.expenses.count)", label: "EXPENSES")
            }
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            Button(action: {
                HapticManager.impact(style: .light)
                openReceipt(for: group)
            }) {
                HStack(spacing: 8) {
                    ReceiptIcon(size: 11)
                    Text("VIEW RECEIPT")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                }
                .foregroundColor(ink.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.clear)
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundColor(border)
                )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.98))
        }
        .padding(20)
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: Color.primary.opacity(0.06), radius: 12, y: 4)
        .confirmationDialog("Switch group", isPresented: $showGroupJumpPicker, titleVisibility: .visible) {
            ForEach(visibleGroups) { option in
                Button(option.name) {
                    HapticManager.impact(style: .light)
                    switchToGroup(option)
                }
            }

            Button("Cancel", role: .cancel) {}
        }
    }

    private func groupSummaryGroupStrip(activeGroup: DutchieGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleGroups) { group in
                    Button(action: {
                        HapticManager.impact(style: .light)
                        switchToGroup(group)
                    }) {
                        Text(group.name)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(group.id == activeGroup.id ? ivory : ink.opacity(0.58))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(group.id == activeGroup.id ? ink : ink.opacity(0.06))
                            .cornerRadius(3)
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.96))
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func groupAmountTile(label: String, amount: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .tracking(1.5)

            Text(String(format: "$%.2f", amount))
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(amount > 0 ? color : ink.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func balanceSummaryRegistrationBackground(step: Int) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    if groupModeTutorial.isActive && groupModeTutorial.currentStepIndex == step {
                        registerBalanceSummaryFrameIfNeeded(geo.frame(in: .global))
                    }
                }
                .onChange(of: groupModeTutorial.currentStepIndex) { _, newValue in
                    if newValue == step {
                        registerBalanceSummaryFrameIfNeeded(geo.frame(in: .global))
                    }
                }
                .onChange(of: groupModeTutorial.isActive) { _, _ in
                    if groupModeTutorial.currentStepIndex == step {
                        registerBalanceSummaryFrameIfNeeded(geo.frame(in: .global))
                    }
                }
                .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in
                    if groupModeTutorial.currentStepIndex == step {
                        registerBalanceSummaryFrameIfNeeded(geo.frame(in: .global))
                    }
                }
        }
    }

    private var groupSegmentedControl: some View {
        HStack(spacing: 4) {
            ForEach(GroupSettleTab.allCases) { tab in
                Button(action: {
                    HapticManager.impact(style: .light)
                    if tab == .members, let group = currentGroup {
                        refreshMemberSectionSnapshot(for: group)
                        selectedGroupTab = tab
                    } else {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                            selectedGroupTab = tab
                        }
                    }
                }) {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(selectedGroupTab == tab ? ivory : ink.opacity(0.62))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedGroupTab == tab ? ink : Color.clear)
                        .cornerRadius(3)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.97))
            }
        }
        .padding(4)
        .background(chalk)
        .cornerRadius(5)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: 1))
    }

    @ViewBuilder
    private func selectedGroupSection(for group: DutchieGroup) -> some View {
        switch selectedGroupTab {
        case .activity:
            groupActivitySection(group: group)
        case .balances:
            groupBalancesSection(group: group)
        case .members:
            groupMembersSection(group: group)
        }
    }

    private func groupBalancesSection(group: DutchieGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if cachedAmountToPay > 0 {
                paymentsDueSection
            } else if cachedAmountToReceive > 0 {
                moneyToReceiveSection
            } else {
                settledEmptyState
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Balances")

                VStack(spacing: 8) {
                    ForEach(balancesForDisplay(group)) { balance in
                        memberBalanceRow(balance: balance, canManagePendingInvites: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settleAllGroupSection(group: DutchieGroup) -> some View {
        let unsettled = unsettledExpenses(in: group).sorted { $0.date > $1.date }
        let latestExpense = unsettled.first
        let latestSession = unsettledSessionSummaries(for: group).first

        if !unsettled.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("QUICK SETTLE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(ink.opacity(0.40))
                    .tracking(1.5)

                if let latestExpense {
                    quickSettleRow(
                        title: "Settle newest transaction",
                        detail: "\(latestExpense.description) · \(formatCurrency(latestExpense.amount))",
                        actionTitle: "SETTLE",
                        tutorialTarget: .quickSettleNewestTransaction,
                        action: {
                            settleExpenses([latestExpense], in: group, message: "Newest transaction marked settled.")
                        }
                    )
                }

                if let latestSession, latestSession.expenses.count > 1 {
                    quickSettleRow(
                        title: "Settle newest review session",
                        detail: "\(latestSession.expenses.count) transaction\(latestSession.expenses.count == 1 ? "" : "s") · \(formatCurrency(latestSession.total))",
                        actionTitle: "SETTLE SESSION",
                        action: {
                            settleExpenses(latestSession.expenses, in: group, message: "Newest review session marked settled.")
                        }
                    )
                }

                quickSettleRow(
                    title: "Settle all group activity",
                    detail: "\(unsettled.count) transaction\(unsettled.count == 1 ? "" : "s") · \(formatCurrency(unsettled.reduce(0) { $0 + $1.amount }))",
                    actionTitle: "SETTLE ALL",
                    tutorialTarget: .quickSettleAllActivity,
                    action: {
                        settleAllGroupExpenses(in: group)
                    }
                )
            }
            .background(quickSettleRegistrationBackground)
        }
    }

    private func quickSettleRow(
        title: String,
        detail: String,
        actionTitle: String,
        tutorialTarget: GroupModeTutorialStep.GroupModeTutorialTarget? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            HapticManager.impact(style: .medium)
            action()
        }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(ink)

                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(actionTitle)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(ivory)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.18, green: 0.50, blue: 0.32))
                    .cornerRadius(4)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .background {
            if let tutorialTarget {
                quickSettleRowRegistrationBackground(for: tutorialTarget)
            }
        }
    }

    private var paymentsDueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PAYMENTS DUE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ink.opacity(0.40))
                .tracking(1.5)
                .padding(.horizontal, 4)

            Text("After you pay, press Settled so this stops showing as unpaid.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 0.78, green: 0.25, blue: 0.18))
                .padding(.horizontal, 4)

            ForEach(settlementsYouOwe) { settlement in
                groupModePaymentRow(settlement: settlement)
            }
        }
        .background(paymentRegistrationBackground)
    }

    private var moneyToReceiveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MONEY TO RECEIVE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ink.opacity(0.40))
                .tracking(1.5)
                .padding(.horizontal, 4)

            ForEach(settlementsYouReceive) { settlement in
                groupModeReceiveRow(settlement: settlement)
            }
        }
        .background(requestRegistrationBackground)
    }

    private var settledEmptyState: some View {
        Text("All balances are settled for this group.")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
    }

    private var paymentRegistrationBackground: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { registerPaymentFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.currentStepIndex) { _, _ in registerPaymentFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.isActive) { _, _ in registerPaymentFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in registerPaymentFrameIfNeeded(geo.frame(in: .global)) }
        }
    }

    private var requestRegistrationBackground: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { registerRequestFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.currentStepIndex) { _, _ in registerRequestFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.isActive) { _, _ in registerRequestFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in registerRequestFrameIfNeeded(geo.frame(in: .global)) }
        }
    }

    private var quickSettleRegistrationBackground: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { registerQuickSettleFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.currentStepIndex) { _, _ in registerQuickSettleFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.isActive) { _, _ in registerQuickSettleFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in registerQuickSettleFrameIfNeeded(geo.frame(in: .global)) }
        }
    }

    private func quickSettleRowRegistrationBackground(
        for target: GroupModeTutorialStep.GroupModeTutorialTarget
    ) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { registerQuickSettleRowFrameIfNeeded(geo.frame(in: .global), for: target) }
                .onChange(of: groupModeTutorial.currentStepIndex) { _, _ in registerQuickSettleRowFrameIfNeeded(geo.frame(in: .global), for: target) }
                .onChange(of: groupModeTutorial.isActive) { _, _ in registerQuickSettleRowFrameIfNeeded(geo.frame(in: .global), for: target) }
                .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in registerQuickSettleRowFrameIfNeeded(geo.frame(in: .global), for: target) }
        }
    }

    private var activitySectionRegistrationBackground: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { registerActivityFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.currentStepIndex) { _, _ in registerActivityFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.isActive) { _, _ in registerActivityFrameIfNeeded(geo.frame(in: .global)) }
                .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in registerActivityFrameIfNeeded(geo.frame(in: .global)) }
        }
    }

    @ViewBuilder
    private func groupMembersSection(group: DutchieGroup) -> some View {
        if let snapshot = memberSectionSnapshotsByID[group.id] {
            let inviteAvailability = snapshot.inviteAvailability
            VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionTitle("Members")
                Spacer()
                Button(action: {
                    guard inviteAvailability.canInvite else {
                        HapticManager.notification(type: .error)
                        return
                    }
                    HapticManager.impact(style: .light)
                    showAddMember = true
                }) {
                    HStack(spacing: 4) {
                        PlusIcon(size: 12)
                        Text("ADD")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                    }
                    .foregroundColor(ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ink.opacity(inviteAvailability.canInvite ? 0.08 : 0.03))
                    .cornerRadius(2)
                    .opacity(inviteAvailability.canInvite ? 1 : 0.45)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.95))
                .disabled(!inviteAvailability.canInvite)
            }
            .padding(.leading, 2)

            if let message = inviteAvailability.message, group.maxMemberCount != nil {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(inviteAvailability.canInvite ? .secondary : .orange)
                    .padding(.horizontal, 2)
            }

            if group.maxMemberCount != nil || group.pendingMemberCount > 0 {
                groupInviteLinkCard(group: group)
            }

            VStack(spacing: 8) {
                ForEach(snapshot.balances) { balance in
                    memberBalanceRow(
                        balance: balance,
                        canManagePendingInvites: snapshot.canManagePendingInvites
                    )
                }
            }

            if !snapshot.leftMembers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Left the group")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 2)
                        .padding(.top, 8)

                    VStack(spacing: 8) {
                        ForEach(snapshot.leftMembers) { member in
                            leftMemberRow(member: member)
                        }
                    }
                }
            }
            }
        } else {
            memberSectionLoadingView
                .onAppear {
                    refreshMemberSectionSnapshot(for: group)
                }
        }
    }

    private var memberSectionLoadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Members")
            Text("Loading members...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(14)
        }
    }

    private func groupInviteLinkCard(group: DutchieGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ink.opacity(0.55))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite link for \(group.name)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(ink)
                    Text("Send this exact link to invited members.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text(group.inviteLink)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(ink.opacity(0.7))
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                ShareLink(item: inviteMessage(for: group)) {
                    Text("SHARE LINK")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(ink)
                        .cornerRadius(3)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.96))

                Button {
                    UIPasteboard.general.string = group.inviteLink
                    HapticManager.notification(type: .success)
                } label: {
                    Text("COPY")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.75))
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(ink.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.96))
            }
        }
        .padding(12)
        .background(ink.opacity(0.045))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ink.opacity(0.12), lineWidth: 1)
        )
    }

    private func groupActivitySection(group: DutchieGroup) -> some View {
        let snapshot = cachedActivitySnapshot?.groupID == group.id ? cachedActivitySnapshot : nil
        let sections = snapshot?.sections ?? []
        let sessionSummaries = snapshot?.sessionSummaries ?? []

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ClockIcon(size: 14)
                    .foregroundColor(.secondary)
                Text("Activity")
                    .font(.system(size: 18, weight: .bold))

                if groupModeTutorial.showActivityNotification {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .transition(.scale.combined(with: .opacity))
                }

                Spacer()
            }
            .padding(.leading, 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: groupModeTutorial.showActivityNotification)

            activityFilterBar

            settleAllGroupSection(group: group)

            if !sessionSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Settle by upload session")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(ink.opacity(0.72))
                        .padding(.leading, 2)

                    ForEach(sessionSummaries) { summary in
                        uploadSessionSettleRow(summary: summary, group: group)
                    }
                }
            }

            if snapshot == nil && !group.expenses.isEmpty {
                Text("Loading activity...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)
                    .onAppear {
                        scheduleActivitySnapshotRefresh(for: group, after: 0.01)
                    }
            } else if group.expenses.isEmpty {
                Text("No expenses yet. Add one from the Upload screen.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)
            } else if sections.isEmpty {
                Text("No activity matches your filters.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            activityMonthHeader(section)

                            if shouldShowCollapsedMonth(section) {
                                collapsedMonthRow(section)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(section.expenses) { expense in
                                        expenseRow(expense: expense)
                                    }

                                }
                            }
                        }
                    }
                }
                .background(activitySectionRegistrationBackground)
            }
        }
        .id("activitySection")
    }

    private var activityFilterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)

                TextField("Search item or amount", text: $activitySearchText)
                    .font(.system(size: 14, weight: .medium))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                if !activitySearchText.isEmpty {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        activitySearchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)

            HStack(spacing: 8) {
                amountFilterField(title: "MIN", text: $activityMinAmount)
                amountFilterField(title: "MAX", text: $activityMaxAmount)
            }
        }
    }

    private func amountFilterField(title: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(ink.opacity(0.42))
                .tracking(1)

            TextField("$0", text: text)
                .font(.system(size: 13, weight: .semibold))
                .keyboardType(.decimalPad)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(9)
    }

    private func activitySections(for group: DutchieGroup) -> [ActivityMonthSection] {
        let filtered = filteredActivityExpenses(for: group)
        var sections: [ActivityMonthSection] = []
        let calendar = Calendar.current

        for expense in filtered {
            let components = calendar.dateComponents([.year, .month], from: expense.date)
            let id = "\(components.year ?? 0)-\(components.month ?? 0)"

            if let index = sections.firstIndex(where: { $0.id == id }) {
                var expenses = sections[index].expenses
                expenses.append(expense)
                sections[index] = ActivityMonthSection(
                    id: id,
                    title: monthHeader(for: expense.date),
                    expenses: expenses
                )
            } else {
                sections.append(ActivityMonthSection(
                    id: id,
                    title: monthHeader(for: expense.date),
                    expenses: [expense]
                ))
            }
        }

        return sections
    }

    private func filteredActivityExpenses(for group: DutchieGroup) -> [GroupExpense] {
        let query = activitySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minAmount = Double(activityMinAmount.trimmingCharacters(in: .whitespacesAndNewlines))
        let maxAmount = Double(activityMaxAmount.trimmingCharacters(in: .whitespacesAndNewlines))

        return group.expenses
            .sorted { $0.date > $1.date }
            .filter { expense in
                if let minAmount, expense.amount < minAmount { return false }
                if let maxAmount, expense.amount > maxAmount { return false }

                guard !query.isEmpty else { return true }
                let amountText = String(format: "%.2f", expense.amount)
                return expense.description.lowercased().contains(query)
                    || expense.addedByName.lowercased().contains(query)
                    || amountText.contains(query)
            }
    }

    private var isActivityFilteringActive: Bool {
        !activitySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        Double(activityMinAmount.trimmingCharacters(in: .whitespacesAndNewlines)) != nil ||
        Double(activityMaxAmount.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private func shouldShowCollapsedMonth(_ section: ActivityMonthSection) -> Bool {
        section.expenses.count > 10 &&
        collapsedActivityMonthIDs.contains(section.id) &&
        !isActivityFilteringActive
    }

    private func shouldOfferMonthCollapse(_ section: ActivityMonthSection) -> Bool {
        section.expenses.count > 10 &&
        !collapsedActivityMonthIDs.contains(section.id) &&
        !isActivityFilteringActive
    }

    private func activityMonthHeader(_ section: ActivityMonthSection) -> some View {
        HStack(spacing: 8) {
            Text(section.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(ink)

            if section.expenses.count > 10 && !isActivityFilteringActive {
                Text("\(section.expenses.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(4)

                Image(systemName: collapsedActivityMonthIDs.contains(section.id) ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.72))
            }

            Spacer()
        }
        .padding(.leading, 2)
        .padding(.top, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard section.expenses.count > 10 && !isActivityFilteringActive else { return }
            HapticManager.impact(style: .light)
            toggleActivityMonth(section.id)
        }
    }

    private func collapsedMonthRow(_ section: ActivityMonthSection) -> some View {
        Button(action: {
            HapticManager.impact(style: .light)
            toggleActivityMonth(section.id)
        }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(section.expenses.count) transactions")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(ink)

                    Text("Tap to view \(section.title) activity")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(formatCurrency(section.expenses.reduce(0) { $0 + $1.amount }))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ink)

                Text("VIEW")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(ink.opacity(0.62))
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }

    private func collapseMonthButton(_ section: ActivityMonthSection) -> some View {
        Button(action: {
            HapticManager.impact(style: .light)
            toggleActivityMonth(section.id)
        }) {
            Text("COLLAPSE \(section.title.uppercased())")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }

    private func toggleActivityMonth(_ id: String) {
        if collapsedActivityMonthIDs.contains(id) {
            collapsedActivityMonthIDs.remove(id)
        } else {
            collapsedActivityMonthIDs.insert(id)
        }
    }

    private func unsettledExpenses(in group: DutchieGroup) -> [GroupExpense] {
        group.expenses.filter { !$0.isArchived && !$0.settled }
    }

    private func unsettledSessionSummaries(for group: DutchieGroup) -> [ExpenseSessionSummary] {
        let grouped = Dictionary(grouping: unsettledExpenses(in: group).filter { $0.sourceUploadSessionID != nil }) {
            $0.sourceUploadSessionID!
        }

        return grouped
            .map { ExpenseSessionSummary(uploadSessionID: $0.key, expenses: $0.value.sorted { $0.date > $1.date }) }
            .filter { $0.expenses.count > 1 }
            .sorted { $0.latestDate > $1.latestDate }
    }

    private func uploadSessionSettleRow(summary: ExpenseSessionSummary, group: DutchieGroup) -> some View {
        Button(action: {
            HapticManager.impact(style: .medium)
            settleExpenses(
                summary.expenses,
                in: group,
                isSettled: true,
                message: "Upload session marked settled."
            )
        }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("One review session")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(ink)

                    Text("\(summary.expenses.count) transaction\(summary.expenses.count == 1 ? "" : "s") · \(shortDate(summary.latestDate))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(formatCurrency(summary.total))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ink)

                Text("SETTLE SESSION")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(ivory)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.18, green: 0.50, blue: 0.32))
                    .cornerRadius(4)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(ink)
    }
    

    // MARK: - Helper Methods for Frame Registration

    private func registerPaymentFrameIfNeeded(_ frame: CGRect) {
        if groupModeTutorial.isActive &&
           groupModeTutorial.currentStepIndex == 3 &&
           frame != .zero {
            DispatchQueue.main.async {
                groupModeTutorial.registerFrame(frame, for: .payNowButton)
            }
        }
    }

    private func registerCreateGroupFrameIfNeeded(_ frame: CGRect) {
        if groupModeTutorial.isActive &&
           groupModeTutorial.currentStepIndex == 3 &&
           frame != .zero {
            DispatchQueue.main.async {
                groupModeTutorial.registerFrame(frame, for: .createGroupButton)
            }
        }
    }
    
    
   
    private func normalModePaymentRow(settlement: PaymentLink) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                AvatarView(
                    imageData: settlement.to.contactImage,
                    initials: settlement.to.initials,
                    size: 40
                )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(settlement.to.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ink)
                    Text("I owe this much")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ink.opacity(0.45))
                }
                
                Spacer()
                
                Text(settlement.formattedAmount)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(ink)
            }
            
            HStack(spacing: 8) {
                normalModeActionButton(
                    id: "pay-message-\(settlement.id)",
                    title: "Message",
                    icon: "message.fill",
                    foreground: ivory,
                    background: ink,
                    borderColor: ink,
                    isPrimary: true
                ) {
                    sendPaymentMessage(settlement: settlement)
                }

                normalModeActionButton(
                    id: "pay-share-\(settlement.id)",
                    title: "Share",
                    icon: "square.and.arrow.up",
                    foreground: ink,
                    background: ivory,
                    borderColor: ink.opacity(0.30),
                    isPrimary: false
                ) {
                    sharePaymentMessage(settlement: settlement)
                }
            }
        }
        .padding(14)
        .background(ivory)
        .cornerRadius(3)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(border, lineWidth: 1))
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TutorialFrameKey.self,
                    value: shouldHighlightPayButton ? geo.frame(in: .global) : .zero
                )
            }
        )
        .onPreferenceChange(TutorialFrameKey.self) { frame in
            if shouldHighlightPayButton && frame != .zero {
                DispatchQueue.main.async {
                    tutorialManager.registerFrame(frame, for: .settlePayment)
                }
            }
        }
    }

    private func normalModeRequestRow(settlement: PaymentLink) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                AvatarView(
                    imageData: settlement.from.contactImage,
                    initials: settlement.from.initials,
                    size: 40
                )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(settlement.from.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ink)
                    Text("Owes you")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ink.opacity(0.45))
                }
                
                Spacer()
                
                Text(settlement.formattedAmount)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
            }
            
            HStack(spacing: 8) {
                normalModeActionButton(
                    id: "request-message-\(settlement.id)",
                    title: "Request",
                    icon: "paperplane.fill",
                    foreground: ivory,
                    background: Color(red: 0.18, green: 0.50, blue: 0.32),
                    borderColor: Color(red: 0.18, green: 0.50, blue: 0.32),
                    isPrimary: true
                ) {
                    sendRequestMessage(settlement: settlement)
                }

                normalModeActionButton(
                    id: "request-share-\(settlement.id)",
                    title: "Share",
                    icon: "square.and.arrow.up",
                    foreground: Color(red: 0.18, green: 0.50, blue: 0.32),
                    background: ivory,
                    borderColor: Color(red: 0.18, green: 0.50, blue: 0.32).opacity(0.30),
                    isPrimary: false
                ) {
                    shareRequestMessage(settlement: settlement)
                }
            }
        }
        .padding(14)
        .background(ivory)
        .cornerRadius(3)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(border, lineWidth: 1))
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TutorialFrameKey.self,
                    value: shouldHighlightRequestCard ? geo.frame(in: .global) : .zero
                )
            }
        )
        .onPreferenceChange(TutorialFrameKey.self) { frame in
            if shouldHighlightRequestCard && frame != .zero {
                DispatchQueue.main.async {
                    tutorialManager.registerFrame(frame, for: .settleRequest)
                }
            }
        }
    }

    private func normalModeActionButton(
        id: String,
        title: String,
        icon: String,
        foreground: Color,
        background: Color,
        borderColor: Color,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isLoading = activeNormalModeActionID == id

        return Button(action: {
            guard activeNormalModeActionID == nil else { return }
            HapticManager.impact(style: .medium)
            activeNormalModeActionID = id
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if activeNormalModeActionID == id {
                    activeNormalModeActionID = nil
                }
            }
        }) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView()
                        .tint(foreground)
                        .scaleEffect(0.78)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                }
                Text(isLoading ? "OPENING" : title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(borderColor, lineWidth: isPrimary ? 0 : 1.5)
            )
            .cornerRadius(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .disabled(activeNormalModeActionID != nil && !isLoading)
    }
    
    private func shareRequestMessage(settlement: PaymentLink) {
        showCopyToastWithMessage("Opening share")
        prepareRequestMessage(for: settlement) { text, _ in
            presentShareSheet(text: text)
            UIPasteboard.general.string = settlement.formattedAmount
            activeNormalModeActionID = nil
        }
    }

    private func presentShareSheet(text: String) {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
                  let rootViewController = window.rootViewController else {
                activeNormalModeActionID = nil
                return
            }
            
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }
            
            let activityVC = UIActivityViewController(
                activityItems: [text],
                applicationActivities: nil
            )
            
            activityVC.excludedActivityTypes = [
                .addToReadingList,
                .assignToContact,
                .print,
                .saveToCameraRoll
            ]
            activityVC.completionWithItemsHandler = { _, _, _, _ in
                activeNormalModeActionID = nil
            }
            
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topController.view
                popover.sourceRect = CGRect(
                    x: topController.view.bounds.midX,
                    y: topController.view.bounds.maxY - 100,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = .down
            }
            
            topController.present(activityVC, animated: true) {
                HapticManager.impact(style: .light)
            }
        }
    }
    
    
    private func sharePaymentMessage(settlement: PaymentLink) {
        let text = generateMessageText(for: settlement)
        showCopyToastWithMessage("Opening share")
        presentShareSheet(text: text)
        UIPasteboard.general.string = settlement.formattedAmount
    }
    
    
    
    // MARK: - Group Mode Rows
    
    private func groupModePaymentRow(settlement: PaymentLink) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(
                    imageData: settlement.to.contactImage,
                    initials: settlement.to.initials,
                    size: 44
                )
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(settlement.to.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ink)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("You owe")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ink.opacity(0.45))
                        pendingInviteBadgeIfNeeded(for: settlement.to)
                    }
                }
                
                Spacer()
                
                Text(settlement.formattedAmount)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(red: 0.78, green: 0.25, blue: 0.18))
            }
            
            if hasPaymentMethods(for: settlement.to) {
                HStack(spacing: 8) {
                    if hasVenmo(for: settlement.to) {
                        Button(action: {
                            HapticManager.impact(style: .medium)
                            openVenmo(settlement: settlement)
                        }) {
                            HStack(spacing: 6) {
                                VenmoIcon(size: 14)
                                Text("VENMO")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(0.5)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(red: 0.18, green: 0.50, blue: 0.90))
                            .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.98))
                    }
                    
                    if hasZelle(for: settlement.to) {
                        Button(action: {
                            HapticManager.impact(style: .medium)
                            openZelle(settlement: settlement)
                        }) {
                            HStack(spacing: 6) {
                                ZelleIcon(size: 14)
                                Text("ZELLE")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(0.5)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(red: 0.38, green: 0.16, blue: 0.58))
                            .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.98))
                    }
                }
            } else {
                Button(action: {
                    HapticManager.impact(style: .medium)
                    sendPaymentMessage(settlement: settlement)
                }) {
                    HStack(spacing: 8) {
                        MessageIcon(size: 12, filled: true)
                        Text("SEND MESSAGE")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.8)
                    }
                    .foregroundColor(ivory)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(ink)
                    .cornerRadius(2)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.98))
            }

            HStack(spacing: 10) {
                Text("You haven't paid yet. Tap Settled after payment.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.78, green: 0.25, blue: 0.18))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                Spacer()

                Button(action: {
                    HapticManager.impact(style: .medium)
                    markSettlementAsSettled(settlement)
                }) {
                    HStack(spacing: 5) {
                        CheckmarkCircleIcon(size: 11)
                        Text("SETTLED")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.6)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(red: 0.18, green: 0.50, blue: 0.32))
                    .cornerRadius(2)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.96))
            }
            .padding(10)
            .background(Color.white.opacity(0.65))
            .cornerRadius(3)
        }
        .padding(16)
        .background(Color(red: 0.97, green: 0.89, blue: 0.87))
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color(red: 0.78, green: 0.25, blue: 0.18).opacity(0.3), lineWidth: 1.5)
        )
    }
    
    private func groupModeReceiveRow(settlement: PaymentLink) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                AvatarView(
                    imageData: settlement.from.contactImage,
                    initials: settlement.from.initials,
                    size: 40
                )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(settlement.from.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ink)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Owes you")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ink.opacity(0.45))
                        pendingInviteBadgeIfNeeded(for: settlement.from)
                    }
                }
                
                Spacer()
                
                Text(settlement.formattedAmount)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
            }
            
            Button(action: {
                HapticManager.impact(style: .light)
                sendRequestMessage(settlement: settlement)
            }) {
                HStack(spacing: 6) {
                    Text("REQUEST")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                }
                .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(red: 0.87, green: 0.95, blue: 0.90))
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(red: 0.18, green: 0.50, blue: 0.32).opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.98))

            Text("Not settled until \(settlement.from.name) marks this paid.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(14)
        .background(ivory)
        .cornerRadius(3)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(border, lineWidth: 1))
    }
    
    // MARK: - Member Rows
    
    private func memberBalanceRow(
        balance: GroupMemberBalance,
        canManagePendingInvites: Bool
    ) -> some View {
        HStack(spacing: 12) {
            AvatarView(imageData: balance.member.displayImageData, initials: balance.member.initials, size: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(memberDisplayName(balance.member, in: currentGroup))
                    .font(.system(size: 15, weight: .semibold))

                if balance.member.isPending {
                    Text("Invited, not joined yet")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundColor(.orange)
                }

                Text(String(format: "Paid $%.2f · Share $%.2f", balance.totalPaid, balance.totalOwed))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text(memberSettlementStatusText(for: balance))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(memberSettlementStatusColor(for: balance))

                if balance.member.isPending {
                    pendingInviteActions(
                        member: balance.member,
                        canManageRemoval: canManagePendingInvites
                    )
                        .padding(.top, 8)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 6) {
                Text(balance.formattedNet)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(balance.isPositive ? .green : .red)

                Text(abs(balance.netBalance) < 0.01 ? "SETTLED" : "NOT SETTLED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(abs(balance.netBalance) < 0.01 ? .green : Color(red: 0.78, green: 0.25, blue: 0.18))
                    .tracking(0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background((abs(balance.netBalance) < 0.01 ? Color.green : Color(red: 0.78, green: 0.25, blue: 0.18)).opacity(0.12))
                    .cornerRadius(4)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .shadow(color: Color.primary.opacity(0.04), radius: 6, y: 2)
    }

    private func pendingInviteActions(
        member: GroupMember,
        canManageRemoval: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                HapticManager.impact(style: .light)
                resendInvite(to: member)
            }) {
                Text("RESEND INVITE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(4)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.96))

            if let group = currentGroup, canManageRemoval {
                Button(action: {
                    HapticManager.impact(style: .light)
                    deferSettleAction {
                        groupManager.removePendingInvitedMember(groupID: group.id, memberID: member.id)
                        refreshCurrentGroupAfterPendingRemoval(groupID: group.id)
                    }
                }) {
                    Text("REMOVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .lineLimit(1)
                        .foregroundColor(Color(red: 0.78, green: 0.25, blue: 0.18))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color(red: 0.78, green: 0.25, blue: 0.18).opacity(0.10))
                        .cornerRadius(4)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.96))
            }
        }
    }

    private func canManagePendingInvites(in group: DutchieGroup) -> Bool {
        guard let currentMember = group.members.first(where: { $0.isCurrentUser && !$0.hasLeft }) else {
            return false
        }
        guard let createdByID = group.createdByID else { return true }
        return createdByID == currentMember.id
    }

    private func refreshCurrentGroupAfterPendingRemoval(groupID: UUID) {
        if let updated = groupManager.getGroup(by: groupID) {
            currentGroup = updated
        }
        recalculateSettlements()
        if let currentGroup {
            refreshMemberSectionSnapshot(for: currentGroup)
        }
        updateCachedBalances()
    }

    private func memberSettlementStatusText(for balance: GroupMemberBalance) -> String {
        if abs(balance.netBalance) < 0.01 {
            return "Settled net"
        }

        if balance.netBalance > 0 {
            return "Settled net to \(balance.member.name) when paid"
        }

        return "Not settled"
    }

    private func memberSettlementStatusColor(for balance: GroupMemberBalance) -> Color {
        if abs(balance.netBalance) < 0.01 {
            return .green
        }

        return balance.netBalance > 0
            ? Color(red: 0.18, green: 0.50, blue: 0.32)
            : Color(red: 0.78, green: 0.25, blue: 0.18)
    }

    @ViewBuilder
    private func pendingInviteBadgeIfNeeded(for person: Person) -> some View {
        let isPending = person.isPendingGroupMember == true ||
            groupMember(for: person)?.isPending == true

        if isPending {
            Text("INVITED · NOT JOINED")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(4)
        }
    }
    
    
    private func pendingMemberRow(member: GroupMember) -> some View {
        HStack(spacing: 12) {
            AvatarView(imageData: member.displayImageData, initials: member.initials, size: 40)
                .overlay(Circle().stroke(Color.orange.opacity(0.3), lineWidth: 2))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(memberDisplayName(member, in: currentGroup))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                if let phone = member.phoneNumber {
                    Text(phone)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            
            Spacer()
            
            HStack(spacing: 6) {
                Text("PENDING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
                    .tracking(0.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 74, height: 32)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(3)
                
                Button(action: {
                    HapticManager.impact(style: .light)
                    resendInvite(to: member)
                }) {
                    Text("RESEND")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    .foregroundColor(.orange)
                    .frame(width: 74, height: 32)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(3)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.95))

                if groupManager.activeGroup?.maxMemberCount != nil {
                    Button(action: {
                        guard let groupID = groupManager.activeGroup?.id else { return }
                        HapticManager.impact(style: .light)
                        deferSettleAction {
                            groupManager.removeMemberFromSubscriptionInvite(groupID: groupID, memberID: member.id)
                            refreshCurrentGroupAfterPendingRemoval(groupID: groupID)
                        }
                    }) {
                        Text("REMOVE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundColor(.orange)
                            .frame(width: 74, height: 32)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(3)
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.95))
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.3), lineWidth: 1.5))
        .shadow(color: Color.orange.opacity(0.06), radius: 6, y: 2)
    }

    private func leftMemberRow(member: GroupMember) -> some View {
        HStack(spacing: 12) {
            AvatarView(imageData: member.displayImageData, initials: member.initials, size: 40)
                .opacity(0.55)

            VStack(alignment: .leading, spacing: 2) {
                Text(memberDisplayName(member, in: currentGroup))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ink.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text("Left the group")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .layoutPriority(1)

            Spacer()

            Text("LEFT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(0.5)
                .frame(width: 74, height: 32)
                .background(Color.secondary.opacity(0.10))
                .cornerRadius(3)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.14), lineWidth: 1))
        .shadow(color: Color.primary.opacity(0.03), radius: 6, y: 2)
    }
    
    // MARK: - Expense Row
    
    private func expenseRow(expense: GroupExpense) -> some View {
        let currentUserID = appState.people.first(where: { $0.isCurrentUser })?.id
        let allPaid = allSharesPaid(expenseID: expense.id)
        
        // NEW: Check if current user is the one who paid (to show remind button)
        let currentUserPaid = expense.addedByID == currentUserID
        
        return HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(dayMonth(for: expense.date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text(dayNumber(for: expense.date))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(ink.opacity(0.78))
                    .monospacedDigit()
            }
            .frame(width: 44)

            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 40, height: 40)
                Text(String(expense.addedByName.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\(expense.addedByName.components(separatedBy: " ").first ?? expense.addedByName) added \(expense.description)")
                    .font(.system(size: 14, weight: .medium))
                
                HStack(spacing: 8) {
                    Text(expense.formattedAmount)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.accentColor)
                    
                    if allPaid {
                        HStack(spacing: 4) {
                            CheckmarkCircleIcon(size: 10)
                                .foregroundColor(.green)
                            Text("SETTLED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                                .tracking(0.5)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 10) {
                    // NEW: Remind/Notification Button (only show if current user paid and not all paid)
                    if currentUserPaid && !allPaid {
                        Button(action: {
                            HapticManager.impact(style: .light)
                            sendPaymentReminder(for: expense)
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.1))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "bell.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.orange)
                            }
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.92))
                    }
                    
                    // Any member can toggle a transaction between settled and unsettled.
                    Button(action: {
                        HapticManager.impact(style: .light)
                        togglePaidStatus(expense: expense)
                    }) {
                        ZStack {
                            Circle()
                                .fill(allPaid ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
                                .frame(width: 40, height: 40)
                            CheckmarkCircleIcon(size: 18)
                                .foregroundColor(allPaid ? .green : .secondary)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.92))
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .shadow(color: Color.primary.opacity(0.04), radius: 6, y: 2)
        // NEW: Add spotlight for tutorial step 5
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TutorialFrameKey.self,
                    value: shouldHighlightExpenseRow(expense) ? geo.frame(in: .global) : .zero
                )
            }
        )
        .onPreferenceChange(TutorialFrameKey.self) { frame in
            if shouldHighlightExpenseRow(expense) && frame != .zero {
                DispatchQueue.main.async {
                    groupModeTutorial.registerFrame(frame, for: .activitySection)
                }
            }
        }
    }
    
    
    private func shouldHighlightExpenseRow(_ expense: GroupExpense) -> Bool {
        guard groupModeTutorial.isActive && groupModeTutorial.currentStepIndex == 4 else {
            return false
        }
        
        // Highlight the first expense in the tutorial (the one user paid for)
        let currentUserID = appState.people.first(where: { $0.isCurrentUser })?.id
        return expense.addedByID == currentUserID
    }

    private func memberDisplayName(_ member: GroupMember, in group: DutchieGroup?) -> String {
        let trimmed = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Member" : trimmed
        if member.isCurrentUser {
            return baseName.localizedCaseInsensitiveCompare("You") == .orderedSame ? "You (Me)" : "\(baseName) (You)"
        }
        if baseName.localizedCaseInsensitiveCompare("You") == .orderedSame {
            if group?.createdByID == member.id { return "Plan owner" }
            if let phone = member.phoneNumber?.filter(\.isNumber), phone.count >= 4 {
                return "Member \(phone.suffix(4))"
            }
            return "Member"
        }
        return baseName
    }
     
     
    // MARK: - Payment Method Helpers

    private func groupMember(for person: Person) -> GroupMember? {
        if let group = currentGroup,
           let member = group.members.first(where: { $0.id == person.id && !$0.hasLeft }) {
            return member
        }

        if let group = currentGroup,
           let member = group.members.first(where: { $0.name == person.name && !$0.hasLeft }) {
            return member
        }

        if let group = currentGroup,
           let phone = person.phoneNumber,
           let member = group.members.first(where: { $0.phoneNumber?.filter(\.isNumber) == phone.filter(\.isNumber) && !$0.hasLeft }) {
            return member
        }

        if let member = groupManager.activeGroup?.members.first(where: { $0.id == person.id && !$0.hasLeft }) {
            return member
        }

        return groupManager.activeGroup?.members.first(where: { $0.name == person.name && !$0.hasLeft })
    }

    private func hasValue(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    
    private func hasPaymentMethods(for person: Person) -> Bool {
        return hasVenmo(for: person) || hasZelle(for: person)
    }
    
    private func hasVenmo(for person: Person) -> Bool {
        if let member = groupMember(for: person) {
            return hasValue(member.venmoUsername) || hasValue(member.venmoLink)
        }
        return hasValue(person.venmoUsername) || hasValue(person.venmoLink)
    }
    
    private func hasZelle(for person: Person) -> Bool {
        if let member = groupMember(for: person) {
            let zelleEmail = member.zelleEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return hasValue(member.zelleLink) || (zelleEmail.contains("@") && !zelleEmail.isEmpty)
        }
        let zelleContact = person.zelleContact?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hasValue(person.zelleLink) || (zelleContact.contains("@") && !zelleContact.isEmpty)
    }
    
    private func openVenmo(settlement: PaymentLink) {
        let venmoUsername = groupMember(for: settlement.to)?.venmoUsername ?? settlement.to.venmoUsername
        let venmoLink = groupMember(for: settlement.to)?.venmoLink ?? settlement.to.venmoLink
        
        if let username = venmoUsername?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            let clean = username.replacingOccurrences(of: "@", with: "")
            let amt = String(format: "%.2f", settlement.amount)
            let note = "Split payment".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Split%20payment"
            
            if let venmoURL = URL(string: "venmo://paycharge?txn=pay&recipients=\(clean)&amount=\(amt)&note=\(note)") {
                UIApplication.shared.open(venmoURL) { success in
                    if !success {
                        if let appStoreURL = URL(string: "https://apps.apple.com/app/venmo/id351727428") {
                            UIApplication.shared.open(appStoreURL)
                        }
                    }
                }
            }
        } else if let link = venmoLink?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty, let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }
    
    private func openZelle(settlement: PaymentLink) {
        let zelleLink = groupMember(for: settlement.to)?.zelleLink ?? settlement.to.zelleLink
        let zelleEmail = groupMember(for: settlement.to)?.zelleEmail ?? settlement.to.zelleContact
        
        if let zelleLink = zelleLink?.trimmingCharacters(in: .whitespacesAndNewlines), !zelleLink.isEmpty, let url = URL(string: zelleLink) {
            UIApplication.shared.open(url)
        } else if let email = zelleEmail?.trimmingCharacters(in: .whitespacesAndNewlines), email.contains("@"), !email.isEmpty {
            let amount = String(format: "%.2f", settlement.amount)
            let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
            if let zelleURL = URL(string: "zelle://payment?token=\(encoded)&amount=\(amount)") {
                UIApplication.shared.open(zelleURL)
            }
        }
    }
    
    private func resendInvite(to member: GroupMember) {
        guard let phone = member.phoneNumber, !phone.isEmpty, let group = currentGroup else { return }
        let body = """
        Hi! I want to activate Group Mode on Dutch so we can send money in a single tap.
        
        Join "\(group.name)" by downloading the app:
        
        App Store: https://apps.apple.com/app/dutchie
        
        Dutch invite link (full link):
        \(group.inviteLink)
        
        Split expenses together, settle up instantly.
        """
        if canSendText {
            composePayload = MessageComposePayload(recipients: [phone], body: dutchSignedMessage(body))
        }
    }

    private func inviteMessage(for group: DutchieGroup) -> String {
        dutchSignedMessage("""
        Join my Dutch group "\(group.name)".

        Dutch invite link (full link):
        \(group.inviteLink)
        """)
    }
    
    private func sendPaymentReminder(for expense: GroupExpense) {
        guard let group = currentGroup else { return }
        
        let peopleWhoOwe = group.members.filter { member in
            expense.splitAmongIDs.contains(member.id) && member.id != expense.addedByID
        }
        
        guard !peopleWhoOwe.isEmpty else { return }
        
        let share = expense.amount / Double(expense.splitAmongIDs.count)
        let payer = group.members.first(where: { $0.id == expense.addedByID })?.name ?? "Someone"
        
        for member in peopleWhoOwe {
            NotificationManager.shared.notifyPaymentOwed(
                expenseID: expense.id,
                groupName: group.name,
                payerName: payer,
                expenseDescription: expense.description,
                totalAmount: expense.amount,
                yourShare: share
            )
            
            if let phone = member.phoneNumber, !phone.isEmpty, canSendText {
                let body = """
                Payment Reminder: \(group.name)
                
                \(payer) paid \(expense.formattedAmount) for \(expense.description).
                Your share: \(String(format: "$%.2f", share))
                
                Tap to pay now.
                """
                
                composePayload = MessageComposePayload(recipients: [phone], body: dutchSignedMessage(body))
            }
        }
        
        HapticManager.notification(type: .success)
    }
    
    

    
   private func togglePaidStatus(expense: GroupExpense) {
       guard let group = currentGroup else {
           return
       }
       
       let shouldSettle = !allSharesPaid(expenseID: expense.id)
       let targetExpenses = [expense].filter { !$0.isArchived && $0.settled != shouldSettle }
       let message = shouldSettle ? "Transaction marked settled." : "Transaction reopened."

       settleExpenses(targetExpenses, in: group, isSettled: shouldSettle, message: message)
   }
    
    
    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func formatCurrency(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    private func monthHeader(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    private func dayMonth(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f.string(from: date)
    }

    private func dayNumber(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd"
        return f.string(from: date)
    }
    
    // MARK: - Bottom CTA
    private var bottomCTA: some View {
        VStack(spacing: 8) {
            Text("THANK YOU FOR USING DUTCH")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(ink.opacity(0.25))
                .tracking(1)
                .padding(.top, 14)
            
            if shouldUseGroupModeUI {
                HStack(spacing: 10) {
                    Button(action: {
                        HapticManager.impact(style: .medium)
                        markNewestTransactionAsPaid()
                    }) {
                        Text("SETTLED")
                            .font(.system(size: 13, weight: .bold))
                            .tracking(0.8)
                        .foregroundColor(ivory)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color(red: 0.18, green: 0.50, blue: 0.32))
                        .cornerRadius(3)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    registerCreateGroupFrameIfNeeded(geo.frame(in: .global))
                                }
                                .onChange(of: groupModeTutorial.currentStepIndex) { _, _ in
                                    registerCreateGroupFrameIfNeeded(geo.frame(in: .global))
                                }
                                .onChange(of: groupModeTutorial.isActive) { _, _ in
                                    registerCreateGroupFrameIfNeeded(geo.frame(in: .global))
                                }
                                .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in
                                    registerCreateGroupFrameIfNeeded(geo.frame(in: .global))
                                }
                        }
                    )
                    
                    Button(action: {
                        HapticManager.impact(style: .medium)
                        leaveSettleForLater()
                        deferSettleAction {
                            scheduleLaterReminder()
                        }
                    }) {
                        Text("LATER")
                            .font(.system(size: 13, weight: .bold))
                            .tracking(0.8)
                        .foregroundColor(ivory)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(ink)
                        .cornerRadius(3)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            } else {
                // Normal mode: Done + Later buttons
                HStack(spacing: 10) {
                    Button(action: {
                        HapticManager.impact(style: .medium)
                        if tutorialManager.isActive {
                            tutorialManager.nextStep()
                        } else {
                            saveBalancesBeforeLeavingSettleShare()
                            appState.resetUploadSession()
                            router.reset()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Text(tutorialManager.isActive ? "CONTINUE" : "DONE!")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(0.8)
                        }
                        .foregroundColor(ivory)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color(red: 0.18, green: 0.50, blue: 0.32))
                        .cornerRadius(3)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .tutorialSpotlight(isHighlighted: shouldHighlightDoneButton, cornerRadius: 3)
                    
                    Button(action: {
                        HapticManager.impact(style: .medium)
                        leaveSettleForLater()
                    }) {
                        HStack(spacing: 8) {
                            Text("LATER")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(0.8)
                        }
                        .foregroundColor(ivory)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(ink)
                        .cornerRadius(3)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(ivory)
    }
    
    
    
    private var shouldHighlightDoneButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStepIndex == 8
    }

    private func leaveSettleForLater() {
        saveBalancesBeforeLeavingSettleShare()
        appState.resetUploadSession()
        router.reset()
    }
    
    
    private var shouldHighlightRequestButton: Bool {
            tutorialManager.isActive &&
            tutorialManager.currentStep?.targetView == .groupModeSettle &&
            currentUserBalance > 0
        }
        
    private var shouldHighlightPayButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStepIndex == 7
    }
    
    
    private func shareAllPayments() {
        deferSettleAction {
            let combinedMessage = generateCombinedSettlementShareMessage()

            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first,
                  let rootViewController = window.rootViewController else {
                return
            }

            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }

            let activityVC = UIActivityViewController(
                activityItems: [combinedMessage],
                applicationActivities: nil
            )

            activityVC.excludedActivityTypes = [
                .addToReadingList,
                .assignToContact,
                .print,
                .saveToCameraRoll
            ]

            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topController.view
                popover.sourceRect = CGRect(
                    x: topController.view.bounds.midX,
                    y: topController.view.bounds.maxY - 100,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = .down
            }

            topController.present(activityVC, animated: true) {
                HapticManager.impact(style: .light)
            }
        }
    }

    private func generateCombinedSettlementShareMessage() -> String {
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        var lines: [String] = ["Hey everyone involved,", "", "Here is the split:"]

        let owedToCurrentUser = settlements.filter { $0.to.id == currentUser?.id }
        let currentUserOwes = settlements.filter { $0.from.id == currentUser?.id }
        let otherSettlements = settlements.filter {
            $0.to.id != currentUser?.id && $0.from.id != currentUser?.id
        }

        if !owedToCurrentUser.isEmpty {
            lines.append("")
            lines.append("Please send:")
            for settlement in owedToCurrentUser {
                lines.append("\(settlement.from.name): \(settlement.formattedAmount)")
                let paymentLines = paymentOptionLines(amount: settlement.amount)
                if !paymentLines.isEmpty {
                    lines.append(contentsOf: paymentLines.map { "  \($0)" })
                }
            }
        }

        if !currentUserOwes.isEmpty {
            lines.append("")
            lines.append("I will send:")
            for settlement in currentUserOwes {
                lines.append("\(settlement.to.name): \(settlement.formattedAmount)")
            }
        }

        if !otherSettlements.isEmpty {
            lines.append("")
            lines.append("Between others:")
            for settlement in otherSettlements {
                lines.append("\(settlement.from.name) pays \(settlement.to.name): \(settlement.formattedAmount)")
            }
        }

        let receipt = receiptPromptText().trimmingCharacters(in: .whitespacesAndNewlines)
        if !receipt.isEmpty {
            lines.append("")
            lines.append(receipt)
        }

        lines.append("")
        lines.append("Thanks!")

        return dutchSignedMessage(lines.joined(separator: "\n"))
    }
    
    
    // MARK: - Helper Views
    
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
                    .stroke(ink.opacity(0.25), lineWidth: 1.5)
                }
            )
    }
    
    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(ink)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ink.opacity(0.40))
                .tracking(1.2)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var copyToastView: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.18, green: 0.50, blue: 0.32))
                    .frame(width: 28, height: 28)
                CheckmarkIcon(size: 12)
                    .foregroundColor(.white)
            }
            Text(copyToastMessage)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(ivory)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ink)
        .cornerRadius(3)
        .padding(.horizontal, 20)
        .padding(.bottom, 120)
    }
    
    // MARK: - Actions
    
    private func leaveGroup() {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to leave this group.") else {
            return
        }

        guard !activeGroupIsProtectedSubscriptionGroup else {
            showCopyToastWithMessage("Subscription group cannot be left")
            return
        }

        let groupID = currentGroup?.id ?? groupManager.activeGroup?.id
        currentGroup = nil
        selectedGroupCardID = nil
        router.resetToUpload()
        deferSettleAction {
            groupManager.leaveActiveGroupForCurrentUser(groupID: groupID)
        }
    }
    

    
    private func scheduleLaterReminder() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            
            let content = UNMutableNotificationContent()
            content.title = "Dutch Reminder"
            content.body = "Don't forget to settle your payments!"
            content.sound = .default
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
            let request = UNNotificationRequest(
                identifier: "dutchie-reminder-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
    }
    
    private func requestAll() {
        let targets = settlementsYouReceive
        guard !targets.isEmpty else { return }

        showCopyToastWithMessage("Preparing requests")
        for (index, settlement) in targets.enumerated() {
            deferSettleAction(after: 0.08 * Double(index + 1)) {
                sendRequestMessage(settlement: settlement)
            }
        }
    }
    
    private func sendPaymentMessage(settlement: PaymentLink) {
        showCopyToastWithMessage("Opening message")
        let text = generateMessageText(for: settlement)

        if let phoneNumber = settlement.to.phoneNumber, !phoneNumber.isEmpty {
            sendMessage(to: settlement.to, body: text)
        } else {
            if MFMessageComposeViewController.canSendText() {
                let controller = MFMessageComposeViewController()
                controller.recipients = []
                controller.body = text
                controller.messageComposeDelegate = MessageComposeCoordinator.shared
                presentController(controller)
            } else {
                sharePaymentMessage(settlement: settlement)
            }
        }

        UIPasteboard.general.string = settlement.formattedAmount
    }
    
    
    private func sendRequestMessage(settlement: PaymentLink) {
        showCopyToastWithMessage("Opening request")
        prepareRequestMessage(for: settlement) { text, sentViaDutch in
            if sentViaDutch {
                UIPasteboard.general.string = settlement.formattedAmount
                showCopyToastWithMessage("Request sent via Dutch")
                activeNormalModeActionID = nil
                return
            }

            if let phoneNumber = settlement.from.phoneNumber, !phoneNumber.isEmpty {
                sendMessage(to: settlement.from, body: text)
            } else {
                if MFMessageComposeViewController.canSendText() {
                    let controller = MFMessageComposeViewController()
                    controller.recipients = []
                    controller.body = text
                    controller.messageComposeDelegate = MessageComposeCoordinator.shared
                    presentController(controller)
                } else {
                    presentShareSheet(text: text)
                }
            }

            UIPasteboard.general.string = settlement.formattedAmount
        }
    }
    
    
    private func sendMessage(to person: Person, body: String) {
        if let phoneNumber = person.phoneNumber, !phoneNumber.isEmpty {
            // Has phone number - send to specific recipient
            if MFMessageComposeViewController.canSendText() {
                let controller = MFMessageComposeViewController()
                controller.recipients = [phoneNumber]
                controller.body = body
                controller.messageComposeDelegate = MessageComposeCoordinator.shared
                presentController(controller)
            } else {
                let sms = "sms:\(phoneNumber)&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                if let url = URL(string: sms) {
                    UIApplication.shared.open(url)
                    activeNormalModeActionID = nil
                }
            }
        } else {
            // No phone number - open with pre-filled message but empty recipients
            if MFMessageComposeViewController.canSendText() {
                let controller = MFMessageComposeViewController()
                controller.recipients = [] // Empty - user adds recipient manually
                controller.body = body
                controller.messageComposeDelegate = MessageComposeCoordinator.shared
                presentController(controller)
            } else {
                // Fallback - open empty iMessage
                if let url = URL(string: "sms:&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                    UIApplication.shared.open(url)
                    activeNormalModeActionID = nil
                }
            }
        }
    }
    
    private func presentController(_ controller: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController else {
            activeNormalModeActionID = nil
            return
        }
        
        if let presented = root.presentedViewController {
            presented.dismiss(animated: true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    root.present(controller, animated: true)
                    activeNormalModeActionID = nil
                }
            }
        } else {
            root.present(controller, animated: true)
            activeNormalModeActionID = nil
        }
    }
    
    private func showCopyToastWithMessage(_ message: String) {
        HapticManager.notification(type: .success)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            copyToastMessage = message.uppercased()
            showCopyToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showCopyToast = false
            }
        }
    }

    private func deferSettleAction(after delay: TimeInterval = 0.05, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let start = CFAbsoluteTimeGetCurrent()
            work()
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if elapsedMs > 16 {
                print("🧭 PERF [settle:tap-action] ms=\(elapsedMs)")
            }
        }
    }
    
    // MARK: - Message Generation

    private func refreshCurrentGroupAfterSettlement(groupID: UUID) {
        if let updatedGroup = GroupManager.shared.activeGroup, updatedGroup.id == groupID {
            currentGroup = updatedGroup
        } else if let updatedGroup = GroupManager.shared.getGroup(by: groupID) {
            currentGroup = updatedGroup
        }

        if let currentGroup {
            lastGroupRenderSignature = groupRenderSignature(currentGroup)
        }
        recalculateSettlements()
        updateCachedBalances()
    }

    private func applyLocalSettledState(expenseIDs: [UUID], isSettled: Bool) {
        guard var group = currentGroup else { return }
        let ids = Set(expenseIDs)

        isApplyingSettlementChange = true

        for index in group.expenses.indices where ids.contains(group.expenses[index].id) {
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

        currentGroup = group
        lastGroupRenderSignature = groupRenderSignature(group)
    }

    private func settleExpenses(_ expenses: [GroupExpense], in group: DutchieGroup, message: String) {
        settleExpenses(expenses, in: group, isSettled: true, message: message)
    }

    private func settleAllGroupExpenses(in group: DutchieGroup) {
        let localUnsettled = unsettledExpenses(in: group)

        isApplyingSettlementChange = true
        if !localUnsettled.isEmpty {
            applyLocalSettledState(expenseIDs: localUnsettled.map(\.id), isSettled: true)
        }

        deferSettleAction {
            GroupManager.shared.setAllGroupExpensesSettledStatus(
                groupID: group.id,
                isSettled: true
            ) { changedIDs, error in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isApplyingSettlementChange = false
                    refreshCurrentGroupAfterSettlement(groupID: group.id)

                    guard error == nil else { return }

                    let settledExpenses = group.expenses.filter { changedIDs.contains($0.id) }
                    if !settledExpenses.isEmpty {
                        writeSettlementActivity(for: settledExpenses, in: group)
                    } else {
                        writeSettlementActivity(for: localUnsettled, in: group)
                    }

                    let count = changedIDs.isEmpty ? localUnsettled.count : changedIDs.count
                    if count > 0 {
                        showCopyToastWithMessage("All group activity settled (\(count) transaction\(count == 1 ? "" : "s")).")
                    }
                }
            }
        }
    }

    private func settleExpenses(_ expenses: [GroupExpense], in group: DutchieGroup, isSettled: Bool, message: String) {
        let expenseIDs = expenses
            .filter { !$0.isArchived && $0.settled != isSettled }
            .map(\.id)

        guard !expenseIDs.isEmpty else { return }

        applyLocalSettledState(expenseIDs: expenseIDs, isSettled: isSettled)

        deferSettleAction {
            GroupManager.shared.setExpensesSettledStatus(
                groupID: group.id,
                expenseIDs: expenseIDs,
                isSettled: isSettled
            ) { error in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isApplyingSettlementChange = false
                    refreshCurrentGroupAfterSettlement(groupID: group.id)
                    if error == nil {
                        if isSettled {
                            writeSettlementActivity(for: expenses, in: group)
                        }
                        showCopyToastWithMessage(message)
                    }
                }
            }
        }
    }

    private func settlementTargetExpenses(for expense: GroupExpense, in group: DutchieGroup, isSettled: Bool) -> [GroupExpense] {
        if let sessionID = expense.sourceUploadSessionID {
            let sessionExpenses = group.expenses.filter {
                !$0.isArchived &&
                $0.sourceUploadSessionID == sessionID &&
                $0.settled != isSettled
            }

            if !sessionExpenses.isEmpty {
                return sessionExpenses
            }
        }

        guard !expense.isArchived, expense.settled != isSettled else { return [] }
        return [expense]
    }

    private func writeSettlementActivity(for expenses: [GroupExpense], in group: DutchieGroup) {
        let activeExpenses = expenses.filter { !$0.isArchived }
        guard !activeExpenses.isEmpty else { return }

        let actorName = appState.people.first(where: { $0.isCurrentUser })?.name
            ?? group.members.first(where: { $0.isCurrentUser })?.name
            ?? "Someone"
        let total = activeExpenses.reduce(0) { $0 + $1.amount }
        let sessionID = activeExpenses.compactMap(\.sourceUploadSessionID).first?.uuidString
        let detail: String

        if activeExpenses.count == 1, let expense = activeExpenses.first {
            detail = "\(expense.description) settled"
        } else {
            detail = "\(activeExpenses.count) transactions settled"
        }

        ActivityStore.write(
            groupID: group.id.uuidString,
            groupName: group.name,
            type: .paymentConfirmed,
            actorName: actorName,
            detail: detail,
            amount: total,
            receiptBatchID: sessionID
        )
    }

    private func markSettlementAsSettled(_ settlement: PaymentLink) {
        guard let group = currentGroup,
              let currentUserID = currentMemberID(in: group) else { return }

        let directExpenses = group.expenses.filter { expense in
            !expense.isArchived &&
            !expense.settled &&
            expense.addedByID == settlement.to.id &&
            expense.splitAmongIDs.contains(currentUserID)
        }

        let fallbackExpenses = group.expenses.filter { expense in
                !expense.isArchived &&
                !expense.settled &&
                expense.addedByID != currentUserID &&
                expense.splitAmongIDs.contains(currentUserID)
            }
        let targetExpense = (directExpenses.isEmpty ? fallbackExpenses : directExpenses)
            .sorted { $0.date > $1.date }
            .first
        let expensesToMark = targetExpense.map { [$0] } ?? []

        settleExpenses(expensesToMark, in: group, message: "Settlement marked complete.")
        if let targetExpense {
            markRelatedPaymentActivityPaid(
                group: group,
                expense: targetExpense,
                payerPhone: group.members.first(where: { $0.id == currentUserID })?.phoneNumber
            )
        }

        GroupManager.shared.markSettlementPaid(
            from: settlement.from,
            to: settlement.to,
            amount: settlement.amount
        )

        HapticManager.notification(type: .success)

        refreshCurrentGroupAfterSettlement(groupID: group.id)
    }

    private func newestUnpaidExpense(for settlement: PaymentLink, in group: DutchieGroup?) -> GroupExpense? {
        guard let group else { return nil }

        let directExpenses = group.expenses.filter { expense in
            !expense.isArchived &&
            !expense.settled &&
            expense.addedByID == settlement.to.id &&
            expense.splitAmongIDs.contains(settlement.from.id)
        }

        let fallbackExpenses = group.expenses.filter { expense in
            !expense.isArchived &&
            !expense.settled &&
            expense.addedByID != settlement.from.id &&
            expense.splitAmongIDs.contains(settlement.from.id)
        }

        return (directExpenses.isEmpty ? fallbackExpenses : directExpenses)
            .sorted { $0.date > $1.date }
            .first
    }

    private func markRelatedPaymentActivityPaid(group: DutchieGroup, expense: GroupExpense, payerPhone: String?) {
        ActivityStore.markPaymentRequestPaid(
            groupID: group.id.uuidString,
            expenseID: expense.id.uuidString,
            recipientPhone: payerPhone
        )
    }

    private func markNewestTransactionAsPaid() {
        guard let group = currentGroup,
              let newestExpense = group.expenses
                .filter({ !$0.isArchived && !$0.settled })
                .sorted(by: { $0.date > $1.date })
                .first else {
            router.reset()
            return
        }

        HapticManager.notification(type: .success)
        router.reset()

        deferSettleAction {
            GroupManager.shared.setExpensesSettledStatus(
                groupID: group.id,
                expenseIDs: [newestExpense.id],
                isSettled: true
            )

            ActivityStore.markPaymentRequestPaid(
                groupID: group.id.uuidString,
                expenseID: newestExpense.id.uuidString
            )

            ActivityStore.write(
                groupID: group.id.uuidString,
                groupName: group.name,
                type: .paymentConfirmed,
                actorName: appState.people.first(where: { $0.isCurrentUser })?.name
                    ?? group.members.first(where: { $0.isCurrentUser })?.name
                    ?? "Someone",
                detail: "\(newestExpense.description) settled",
                amount: newestExpense.amount,
                receiptBatchID: newestExpense.sourceUploadSessionID?.uuidString
            )

            refreshCurrentGroupAfterSettlement(groupID: group.id)
        }
    }

    private func markAllAsPaid() {
        guard let group = currentGroup,
              let currentUserID = currentMemberID(in: group) else { return }
        
        // Mark all expenses the current user owes into as settled so later share refreshes
        // cannot bring the same money back.
        let expensesToSettle = group.expenses.filter { expense in
            expense.splitAmongIDs.contains(currentUserID) &&
            expense.addedByID != currentUserID &&
            !expense.isArchived &&
            !expense.settled
        }

        HapticManager.notification(type: .success)
        router.reset()

        deferSettleAction {
            GroupManager.shared.setExpensesSettledStatus(
                groupID: group.id,
                expenseIDs: expensesToSettle.map(\.id),
                isSettled: true
            )
            refreshCurrentGroupAfterSettlement(groupID: group.id)

            if let receiptId = receiptId {
                ReceiptManager.shared.settleGroupReceipt(receiptID: receiptId)
            }

            NotificationManager.shared.notifyGroupFullySettled(groupName: group.name)
            ActivityStore.write(
                groupID: group.id.uuidString,
                groupName: group.name,
                type: .groupSettled,
                actorName: appState.people.first(where: { $0.isCurrentUser })?.name ?? "Someone",
                detail: "All balances cleared"
            )
        }
    }

    private func prepareRequestMessage(for settlement: PaymentLink, completion: @escaping (String, Bool) -> Void) {
        let isInGroup = groupManager.isGroupModeEnabled &&
            groupManager.activeGroup?.members.contains(where: { $0.name == settlement.from.name }) == true

        guard !isInGroup else {
            completion(generateMessageText(for: settlement), false)
            return
        }

        let localPhone = settlement.from.phoneNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        AuthManager.shared.lookupVerifiedDutchieUser(
            phoneNumber: localPhone,
            name: settlement.from.name
        ) { verifiedUser in
            guard let verifiedUser else {
                print("ℹ️ No Dutch member found for request recipient: \(settlement.from.name)")
                completion(generateMessageText(for: settlement), false)
                return
            }

            let payerPhone = (localPhone?.isEmpty == false ? localPhone : verifiedUser.phoneNumber) ?? verifiedUser.phoneNumber
            let payerPhoneKey = ActivityStore.phoneKey(for: payerPhone)
            let currentPhoneKey = ActivityStore.phoneKey(for: AuthManager.shared.phoneNumber ?? "")
            let isCurrentUserMatch = verifiedUser.uid == AuthManager.shared.currentUID ||
                (!currentPhoneKey.isEmpty && payerPhoneKey == currentPhoneKey)

            guard !isCurrentUserMatch else {
                print("⚠️ Dutch request lookup matched the current user for \(settlement.from.name); falling back to normal request.")
                completion(generateMessageText(for: settlement), false)
                return
            }

            print("✅ Dutch member found for request recipient: \(settlement.from.name) (\(payerPhone))")

            createPaymentRequest(for: settlement, payerPhone: payerPhone) { payURL, downloadURL, requestID in
                // Build venmo deep link so the payer can act directly from the activity feed
                var venmoActionURL: String? = nil
                if let venmoUser = self.appState.profile.venmoUsername?
                    .replacingOccurrences(of: "@", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !venmoUser.isEmpty {
                    let groupLabel = self.currentGroup?.name ?? "Dutch split"
                    let note = "Payment via Dutch — \(groupLabel)"
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    venmoActionURL = "venmo://paycharge?txn=pay&recipients=\(venmoUser)&amount=\(String(format: "%.2f", settlement.amount))&note=\(note)"
                } else if let link = self.appState.profile.venmoPaymentLink, !link.isEmpty {
                    venmoActionURL = link
                }

                let activityDetail = "Requested \(String(format: "$%.2f", settlement.amount)) from \(settlement.from.name)"
                let requestActionURL = payURL ?? venmoActionURL
                let requestID = requestID ?? payURL.flatMap(paymentRequestID(from:))
                let targetExpense = newestUnpaidExpense(for: settlement, in: self.currentGroup)
                let balanceItemID = requestID.map { "request-\($0)" }
                let balancesURL = balanceItemID.map { "dutchie://balances?item=\($0)" }

                if let balanceItemID,
                   !verifiedUser.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.appState.writeBalanceItemToFirebase(
                        uid: verifiedUser.uid,
                        item: self.remotePayerBalanceItem(
                            id: balanceItemID,
                            settlement: settlement,
                            payerPhone: payerPhone,
                            requestID: requestID
                        ),
                        phoneKey: payerPhoneKey
                    )
                }

                if let group = self.currentGroup {
                    // Group mode: write to shared group feed with recipientPhone so only payer sees "PAY NOW"
                    ActivityStore.write(
                        groupID: group.id.uuidString,
                        groupName: group.name,
                        type: .paymentRequested,
                        actorName: settlement.to.name,
                        detail: activityDetail,
                        amount: settlement.amount,
                        actionURL: requestActionURL,
                        recipientPhone: payerPhone,
                        receiptBatchID: targetExpense?.sourceUploadSessionID?.uuidString,
                        expenseID: targetExpense?.id.uuidString,
                        requestID: requestID,
                        status: "pending"
                    )
                } else {
                    // Non-group mode: write directly to the payer's personal inbox
                    let requesterName = settlement.to.name
                    let groupLabel = requesterName.isEmpty ? "Dutch" : requesterName
                    ActivityStore.writeToUserInbox(
                        phoneKey: payerPhoneKey,
                        groupName: groupLabel,
                        type: .paymentRequested,
                        actorName: requesterName,
                        detail: activityDetail,
                        amount: settlement.amount,
                        actionURL: requestActionURL,
                        recipientPhone: payerPhone,
                        expenseID: targetExpense?.id.uuidString,
                        requestID: requestID,
                        status: "pending"
                    )
                }
                completion(generateMessageText(
                    for: settlement,
                    dutchiePayURL: balancesURL ?? payURL,
                    dutchieDownloadURL: downloadURL
                ), payURL != nil || requestActionURL != nil)
            }
        }
    }

    private func paymentRequestID(from payURL: String) -> String? {
        guard let url = URL(string: payURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "request" })?.value
    }

    private func createPaymentRequest(
        for settlement: PaymentLink,
        payerPhone: String,
        completion: @escaping (String?, String?, String?) -> Void
    ) {
        let receiptString = receiptId?.uuidString ?? "pending"
        let payeePhone = appState.people.first(where: { $0.isCurrentUser })?.phoneNumber ?? appState.profile.zelleContactInfo
        let venmoUsername = appState.profile.venmoUsername?
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        AuthManager.shared.createPaymentRequest(
            fromName: settlement.from.name,
            fromPhone: payerPhone,
            toName: settlement.to.name,
            amount: settlement.amount,
            receiptId: receiptString,
            payeePhone: payeePhone,
            venmoUsername: venmoUsername,
            venmoLink: appState.profile.venmoPaymentLink,
            zelleContact: appState.profile.zelleContactInfo,
            zelleLink: appState.profile.zellePaymentLink,
            completion: completion
        )
    }

    private func remotePayerBalanceItem(
        id: String,
        settlement: PaymentLink,
        payerPhone: String,
        requestID: String?
    ) -> BalanceItem {
        let now = ISO8601DateFormatter().string(from: Date())
        let title = receiptTitleForBalances()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        let sourceDate = dateFormatter.string(from: Date())
        let requester = appState.people.first(where: { $0.isCurrentUser }) ?? settlement.to

        return BalanceItem(
            id: id,
            type: .owe,
            amount: settlement.amount,
            personName: requester.name,
            personPhone: requester.phoneNumber,
            personVenmo: appState.profile.venmoUsername?
                .replacingOccurrences(of: "@", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            personVenmoLink: appState.profile.venmoPaymentLink,
            personZelleContact: appState.profile.zelleContactInfo,
            personZelleLink: appState.profile.zellePaymentLink,
            receiptId: receiptId?.uuidString,
            receiptTitle: title,
            groupId: nil,
            groupName: nil,
            status: .unpaid,
            createdAt: now,
            updatedAt: now,
            lastReminderAt: nil,
            sourceDate: sourceDate,
            relatedExpenseIds: requestID.map { [$0] } ?? []
        )
    }
     
    private func generateMessageText(
        for settlement: PaymentLink,
        dutchiePayURL: String? = nil,
        dutchieDownloadURL: String? = nil
    ) -> String {
        let currentUser  = appState.people.first(where: { $0.isCurrentUser })
        let userIsPaying = settlement.from.id == currentUser?.id
        
        let receiptPrompt = receiptPromptText()
        let closing = "\n\nThanks!"
     
        if userIsPaying {
            return dutchSignedMessage("Hey \(settlement.to.name),\n\nI owe you \(settlement.formattedAmount) from our recent split. Can you send me your Venmo or Zelle?\(receiptPrompt)\(closing)")
        } else {
            let isInGroup = groupManager.isGroupModeEnabled &&
                            groupManager.activeGroup?.members.contains(where: { $0.name == settlement.from.name }) == true
            
            if isInGroup {
                // ✅ Safely unwrap receiptId for payURL
                let receiptParam = receiptId != nil ? receiptId!.uuidString : "pending"
                let payURL = "dutchie://pay?from=\(settlement.from.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? settlement.from.name)&to=\(settlement.to.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? settlement.to.name)&amount=\(String(format: "%.2f", settlement.amount))&receipt=\(receiptParam)"
                
                return dutchSignedMessage("Hey \(settlement.from.name),\n\nYou owe me \(settlement.formattedAmount) from our recent split.\n\nTap here to pay in the app:\n\(payURL)\(receiptPrompt)\(closing)")
            } else {
                let paymentLines = paymentOptionLines(amount: settlement.amount)
     
                if let dutchiePayURL {
                    let download = dutchieDownloadURL.map { "\n\nDon't have Dutch? Download it free:\n\($0)" } ?? ""
                    return dutchSignedMessage("Hey \(settlement.from.name),\n\nYou owe me \(settlement.formattedAmount) from our recent split.\n\nOpen this in Dutch:\n\(dutchiePayURL)\n\nThis opens your Balances tab and highlights this request.\(receiptPrompt)\(download)\(closing)")
                } else if paymentLines.isEmpty {
                    return dutchSignedMessage("Hey \(settlement.from.name),\n\nYou owe me \(settlement.formattedAmount) from our recent split.\n\nPlease send it when you get a chance.\(receiptPrompt)\(closing)")
                } else {
                    return dutchSignedMessage("Hey \(settlement.from.name),\n\nYou owe me \(settlement.formattedAmount) from our recent split.\n\nTap to pay (amount is already filled in):\n\(paymentLines.joined(separator: "\n"))\(receiptPrompt)\(closing)")
                }
            }
        }
    }

    private func receiptPromptText() -> String {
        guard let receiptId else { return "\n\n" }
        return "\n\nView Full Receipt:\ndutchie://receipt/\(receiptId.uuidString)\n\nDon't have Dutch? Download it free:\nhttps://dutchieapp.com/download?receipt=\(receiptId.uuidString)\n\n"
    }

    private func dutchSignedMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix("via dutch") {
            return trimmed
        }
        return "\(trimmed)\n\nVia Dutch"
    }

    private func paymentOptionLines(amount: Double) -> [String] {
        var paymentLines: [String] = []

        if let username = appState.profile.venmoUsername?.trimmingCharacters(in: .whitespacesAndNewlines),
           !username.isEmpty {
            let clean = username.replacingOccurrences(of: "@", with: "")
            let amt = String(format: "%.2f", amount)
            let note = "Split payment".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Split%20payment"
            paymentLines.append("Venmo: venmo://paycharge?txn=pay&recipients=\(clean)&amount=\(amt)&note=\(note)")
        } else if let link = appState.profile.venmoPaymentLink?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !link.isEmpty {
            paymentLines.append("Venmo: \(link)")
        }

        if let zelle = generateZelleDeepLink(amount: amount), !zelle.isEmpty {
            paymentLines.append("Zelle: \(zelle)")
        }

        return paymentLines
    }
     
    

    private func generateZelleDeepLink(amount: Double) -> String? {
        if let link = appState.profile.zellePaymentLink, !link.isEmpty {
            return link
        }
        if let contact = appState.profile.zelleContactInfo,
           !contact.isEmpty,
           contact.contains("@") {
            let amt     = String(format: "%.2f", amount)
            let encoded = contact.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? contact
            return "zelle://payment?token=\(encoded)&amount=\(amt)"
        }
        return nil
    }
    
    // MARK: - Data Management
    
    private func recalculateSettlements() {
        if groupManager.isGroupModeEnabled, let group = currentGroup {
            let start = CFAbsoluteTimeGetCurrent()
            let snapshot = makePresentationSnapshot(for: group)
            currentGroupSnapshot = snapshot
            currentGroup = snapshot.group
            cachedGroupBalances = snapshot.balances
            groupSnapshotsByID[group.id] = snapshot
            settlements = calculateSettlementsFromGroupBalances(snapshot.group, balances: snapshot.balances)

            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if elapsedMs > 16 {
                print("🧭 PERF [settle:snapshot] group=\(snapshot.group.name) members=\(snapshot.group.members.count) expenses=\(snapshot.group.expenses.count) ms=\(elapsedMs)")
            }
        } else {
            cachedGroupBalances = []
            cachedVisibleGroups = []
            groupSnapshotsByID = [:]
            currentGroupSnapshot = nil
            settlements = appState.calculateSettlements()
        }
    }

    private func saveSplitHistoryIfNeeded() {
        guard !hasSavedSplitHistory else { return }

        let includedTransactions = effectiveTransactions.filter { $0.includeInSplit }
        let splitTotal = includedTransactions.reduce(0.0) { $0 + $1.amount }
        guard splitTotal > 0, !includedTransactions.isEmpty else {
            print("ℹ️ Split history skipped: no completed split total.")
            return
        }

        let snapshots = settlements.map {
            SettlementSnapshot(
                id: $0.id,
                fromName: $0.from.name,
                toName: $0.to.name,
                amount: $0.amount
            )
        }

        let participantCount: Int
        let historyGroupID: UUID?
        let historyGroupName: String?
        let historyTransactions: [TransactionSnapshot]
        if groupManager.isGroupModeEnabled, let group = currentGroup {
            participantCount = group.activeMemberCount
            historyGroupID = group.id
            historyGroupName = group.name
            historyTransactions = group.expenses
                .filter { !$0.isArchived }
                .sorted { $0.date < $1.date }
                .map { receiptTransactionSnapshot(for: $0, in: group) }
        } else {
            participantCount = Set(includedTransactions.flatMap { $0.splitWith.map(\.id) }).count
            historyGroupID = nil
            historyGroupName = nil
            historyTransactions = includedTransactions
                .sorted { $0.merchant.localizedCaseInsensitiveCompare($1.merchant) == .orderedAscending }
                .map {
                    TransactionSnapshot(
                        id: $0.id,
                        merchant: $0.merchant,
                        amount: $0.amount,
                        splitCount: max($0.splitWith.count, 1),
                        assignmentLabel: $0.splitWith.count == appState.people.count ? "All" : $0.splitWith.map(\.name).joined(separator: ", ")
                    )
                }
        }

        let record = SplitRecord(
            date: Date(),
            totalAmount: splitTotal,
            participantCount: max(1, participantCount),
            transactionCount: includedTransactions.count,
            settlements: snapshots,
            yourBalance: currentUserBalance,
            groupID: historyGroupID,
            groupName: historyGroupName,
            transactions: historyTransactions
        )

        if !tutorialManager.isActive {
            appState.recordSplitHistory(record)
        }
        hasSavedSplitHistory = true
    }
     
    
    
    private func calculateSettlementsFromGroupBalances(_ group: DutchieGroup, balances: [BalanceSummary]) -> [PaymentLink] {
        var creditors: [(id: UUID, amount: Double)] = balances
            .filter { $0.netBalance > 0.01 }
            .map { (id: $0.member.id, amount: $0.netBalance) }
            .sorted { $0.amount > $1.amount }
        
        var debtors: [(id: UUID, amount: Double)] = balances
            .filter { $0.netBalance < -0.01 }
            .map { (id: $0.member.id, amount: abs($0.netBalance)) }
            .sorted { $0.amount > $1.amount }

        let membersByID = Dictionary(uniqueKeysWithValues: group.members.map { ($0.id, $0) })
        let peopleByID = Dictionary(uniqueKeysWithValues: appState.people.map { ($0.id, $0) })
        
        var settlements: [PaymentLink] = []
        
        while !creditors.isEmpty && !debtors.isEmpty {
            var creditor = creditors[0]
            var debtor = debtors[0]
            
            let paymentAmount = min(creditor.amount, debtor.amount)

            if let debtorMember = membersByID[debtor.id],
               let creditorMember = membersByID[creditor.id] {
                let fromPerson = peopleByID[debtorMember.id] ?? debtorMember.toPerson()
                let toPerson = peopleByID[creditorMember.id] ?? creditorMember.toPerson()
                
                settlements.append(PaymentLink(from: fromPerson, to: toPerson, amount: paymentAmount))
            }
            
            creditor.amount -= paymentAmount
            debtor.amount -= paymentAmount
            
            creditors.removeFirst()
            debtors.removeFirst()
            
            if creditor.amount > 0.01 {
                creditors.insert(creditor, at: 0)
                creditors.sort { $0.amount > $1.amount }
            }
            
            if debtor.amount > 0.01 {
                debtors.insert(debtor, at: 0)
                debtors.sort { $0.amount > $1.amount }
            }
        }
        return settlements
    }
    
    
    private func calculateSettlementsFromTransactions(_ transactions: [Transaction]) -> [PaymentLink] {
        var balances: [UUID: Double] = [:]
        
        for transaction in transactions where transaction.includeInSplit {
            let payer = transaction.paidBy
            let splitCount = transaction.splitWith.count
            guard splitCount > 0 else { continue }
            
            let perPersonAmount = transaction.amount / Double(splitCount)
            
            for person in transaction.splitWith {
                if person.id != payer.id {
                    balances[person.id, default: 0] -= perPersonAmount
                }
            }
            
            balances[payer.id, default: 0] += transaction.amount - perPersonAmount
        }
        
        var links: [PaymentLink] = []
        var creditors = balances.filter { $0.value > 0.01 }.sorted { $0.value > $1.value }
        var debtors = balances.filter { $0.value < -0.01 }.sorted { $0.value < $1.value }
        
        while !creditors.isEmpty && !debtors.isEmpty {
            let creditor = creditors[0]
            let debtor = debtors[0]
            
            let amount = min(creditor.value, abs(debtor.value))
            
            if let fromPerson = appState.people.first(where: { $0.id == debtor.key }),
               let toPerson = appState.people.first(where: { $0.id == creditor.key }) {
                links.append(PaymentLink(from: fromPerson, to: toPerson, amount: amount))
            }
            
            creditors[0].value -= amount
            debtors[0].value += amount
            
            if creditors[0].value < 0.01 { creditors.removeFirst() }
            if abs(debtors[0].value) < 0.01 { debtors.removeFirst() }
        }
        
        return links
    }
    
    private func openReceipt(for group: DutchieGroup?) {
        receiptGroupForSheet = group
        showReceiptView = true

        if groupManager.isGroupModeEnabled, let group {
            if receiptId == nil {
                isLoadingReceipt = true
                if !hasCreatedReceipt {
                    deferSettleAction {
                        hasCreatedReceipt = true
                        createPrintableGroupReceipt(for: group)
                    }
                }
            } else {
                isLoadingReceipt = false
            }
        } else if receiptId == nil {
            deferSettleAction {
                storeCurrentReceipt()
            }
        }
    }

    private func prepareReceiptForCurrentContext() {
        if groupManager.isGroupModeEnabled, let group = currentGroup {
            hasCreatedReceipt = true
            createPrintableGroupReceipt(for: group)
        } else {
            storeCurrentReceipt()
        }
    }

    private func ensureReceiptReadyForBalances() {
        if receiptId != nil { return }

        if shouldUseGroupModeUI {
            guard !hasCreatedReceipt, let group = currentGroup else { return }
            hasCreatedReceipt = true
            createPrintableGroupReceipt(for: group)
        } else if !hasCreatedReceipt {
            storeCurrentReceipt()
        }
    }

    private func saveBalancesBeforeLeavingSettleShare() {
        recalculateSettlements()

        if shouldUseGroupModeUI {
            ensureReceiptReadyForBalances()
            return
        }

        if receiptId == nil {
            storeCurrentReceipt()
        } else if let receiptId {
            appState.upsertBalanceItems(
                from: settlements,
                receiptId: receiptId,
                receiptTitle: receiptTitleForBalances()
            )
        }
    }

    private func receiptTitleForBalances() -> String {
        let title = effectiveTransactions
            .filter { $0.includeInSplit }
            .first?
            .merchant
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (title?.isEmpty == false) ? title! : "Quick Split"
    }

    private func createPrintableGroupReceipt(for group: DutchieGroup) {
        isLoadingReceipt = true

        let transactionSnapshots = group.expenses
            .filter { !$0.isArchived && !$0.settled }
            .sorted { $0.date < $1.date }
            .map { receiptTransactionSnapshot(for: $0, in: group) }

        let settlementSnapshots = group.calculateSettlements()
            .filter { $0.amount > 0.01 }
            .map {
                SettlementSnapshot(
                    id: $0.id,
                    fromName: $0.from.name,
                    toName: $0.to.name,
                    amount: $0.amount
                )
            }

        let currentUserID = appState.people.first(where: { $0.isCurrentUser })?.id
            ?? group.members.first(where: { $0.isCurrentUser })?.id
            ?? UUID()

        ReceiptManager.shared.getOrCreateGroupReceiptFromSnapshots(
            groupID: group.id,
            createdByID: currentUserID,
            settlementSnapshots: settlementSnapshots,
            transactionSnapshots: transactionSnapshots,
            participantCount: max(group.activeMemberCount, 1)
        ) { receipt in
            DispatchQueue.main.async {
                self.receiptId = receipt.id
                self.saveReceiptIDToGroup(receiptID: receipt.id, groupID: group.id)
                self.appState.upsertBalanceItems(
                    from: self.settlements,
                    receiptId: receipt.id,
                    receiptTitle: group.name,
                    groupId: group.id,
                    groupName: group.name
                )
                self.isLoadingReceipt = false
                print("✅ Printable group receipt ready: \(receipt.id)")
                ReceiptManager.shared.observeGroupReceipt(receiptID: receipt.id)
            }
        }
    }

    private func receiptTransactionSnapshot(for expense: GroupExpense, in group: DutchieGroup) -> TransactionSnapshot {
        return TransactionSnapshot(
            id: expense.id,
            merchant: expense.description,
            amount: expense.amount,
            splitCount: max(expense.splitAmongIDs.count, 1),
            assignmentLabel: groupAssignmentLabel(for: expense, in: group)
        )
    }

    private func groupAssignmentLabel(for expense: GroupExpense, in group: DutchieGroup) -> String {
        let activeMembers = group.members.filter { !$0.isPending && !$0.hasLeft }
        let activeIDs = Set(activeMembers.map(\.id))
        let splitIDs = expense.splitAmongIDs.filter { activeIDs.contains($0) }

        if splitIDs.isEmpty {
            return "Unassigned"
        }

        if splitIDs.count >= activeMembers.count, activeMembers.count > 1 {
            return "All"
        }

        if splitIDs.count == 1 {
            guard let member = group.members.first(where: { $0.id == splitIDs[0] }) else {
                return "Member"
            }
            return member.isCurrentUser ? "Me" : member.name
        }

        return splitIDs.compactMap { id in
            group.members.first(where: { $0.id == id }).map { $0.isCurrentUser ? "Me" : $0.name }
        }.joined(separator: ", ")
    }

    private func storeCurrentReceipt() {
        // ✅ PREVENT DUPLICATE CALLS - check flag first
        guard !hasCreatedReceipt else {
            print("⚠️ Receipt already created for this session, skipping")
            return
        }
        
        // ✅ SET FLAG IMMEDIATELY (before async call starts)
        hasCreatedReceipt = true
        print("🔒 Locked receipt creation flag")
        
        let unpaidTransactions = effectiveTransactions.filter { $0.includeInSplit && !isExpensePaid($0) }
        
        if groupManager.isGroupModeEnabled, let group = currentGroup {
            print("🟢 GROUP MODE: Creating printable shared receipt for group: \(group.name)")
            createPrintableGroupReceipt(for: group)
            
        } else {
            // 🟡 LOCAL MODE
            print("🟡 LOCAL MODE: Creating/updating receipt")
            
            let receipt = ReceiptManager.shared.createOrUpdateLocalReceipt(
                settlements: settlements,
                transactions: unpaidTransactions,
                participantCount: appState.people.count
            )
            
            receiptId = receipt.id
            appState.upsertBalanceItems(
                from: settlements,
                receiptId: receipt.id,
                receiptTitle: unpaidTransactions.first?.merchant ?? "Quick Split"
            )
            print("✅ Local receipt saved: \(receipt.id)")
        }
    }
    
   
  
    // ✅ NEW HELPER: Check if group already has a receipt
    private func getExistingGroupReceiptID(groupID: UUID) -> UUID? {
        // Check UserDefaults for stored receipt ID
        let key = "groupReceipt_\(groupID.uuidString)"
        if let storedID = UserDefaults.standard.string(forKey: key),
           let receiptID = UUID(uuidString: storedID) {
            return receiptID
        }
        return nil
    }
     
    // ✅ NEW HELPER: Save receipt ID to group
    private func saveReceiptIDToGroup(receiptID: UUID, groupID: UUID) {
        let key = "groupReceipt_\(groupID.uuidString)"
        UserDefaults.standard.set(receiptID.uuidString, forKey: key)
        print("💾 Saved receipt \(receiptID) for group \(groupID)")
    }

    

    
  
    
    private func sendAllPaymentNotifications() {
        for settlement in settlements {
            let currentUser = appState.people.first(where: { $0.isCurrentUser })
            let userIsPaying = settlement.from.id == currentUser?.id
            
            if !userIsPaying {
                let recipientPhone = settlement.from.phoneNumber
                let payeeName = settlement.to.name
                
                guard let phone = recipientPhone, !phone.isEmpty else {
                    continue
                }
                
                sendPaymentNotification(
                    amount: settlement.formattedAmount,
                    recipient: settlement.from.name,
                    toPhone: phone,
                    payeeName: payeeName
                )
            }
        }
    }
    
    private func sendPaymentNotification(amount: String, recipient: String, toPhone: String?, payeeName: String) {
        guard let phone = toPhone, !phone.isEmpty else {
            return
        }
        
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            
            let content = UNMutableNotificationContent()
            content.title = "Dutch Payment Due"
            content.body = "You owe \(payeeName) \(amount)"
            content.sound = .default
            content.badge = 1
            content.categoryIdentifier = "PAYMENT_AMOUNT"
            content.userInfo = [
                "amount": amount,
                "recipient": payeeName,
                "debtor": recipient,
                "phone": phone
            ]
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "dutchie-payment-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
    }
    
    private func setupNotificationActions() {
        let center = UNUserNotificationCenter.current()
        let copyAction = UNNotificationAction(
            identifier: "COPY_AMOUNT",
            title: "Copy Amount",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "PAYMENT_AMOUNT",
            actions: [copyAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }
}

// MARK: - Canvas-Based Icons (Dutch Icon System)

struct ReceiptIcon: View {
    let size: CGFloat
    let inkColor = Color(red: 0.15, green: 0.15, blue: 0.15)
    
    var body: some View {
        Image(systemName: "receipt")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundColor(inkColor)
        .frame(width: size, height: size)
    }
}

struct MessageIcon: View {
    let size: CGFloat
    let filled: Bool
    let inkColor = Color(red: 0.15, green: 0.15, blue: 0.15)
    
    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(x: self.size * 0.1, y: self.size * 0.2,
                            width: self.size * 0.8, height: self.size * 0.6)
            let bubble = Path(roundedRect: rect, cornerRadius: 2)
            
            let tail = Path { p in
                p.move(to: CGPoint(x: self.size * 0.3, y: self.size * 0.8))
                p.addLine(to: CGPoint(x: self.size * 0.2, y: self.size * 0.95))
                p.addLine(to: CGPoint(x: self.size * 0.4, y: self.size * 0.8))
            }
            
            if filled {
                context.fill(bubble, with: .color(inkColor))
                context.fill(tail, with: .color(inkColor))
            } else {
                context.stroke(bubble, with: .color(inkColor), lineWidth: 1.5)
                context.stroke(tail, with: .color(inkColor), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ArrowDownCircleIcon: View {
    let size: CGFloat
    let filled: Bool
    let inkColor = Color(red: 0.15, green: 0.15, blue: 0.15)
    
    var body: some View {
        Canvas { context, canvasSize in
            let circle = Circle().path(in: CGRect(origin: .zero, size: CGSize(width: self.size, height: self.size)))
            
            if filled {
                context.fill(circle, with: .color(inkColor))
            } else {
                context.stroke(circle, with: .color(inkColor), lineWidth: 1.5)
            }
            
            let arrowColor = filled ? Color.white : inkColor
            let arrowPath = Path { p in
                p.move(to: CGPoint(x: self.size * 0.5, y: self.size * 0.3))
                p.addLine(to: CGPoint(x: self.size * 0.5, y: self.size * 0.7))
                p.move(to: CGPoint(x: self.size * 0.35, y: self.size * 0.55))
                p.addLine(to: CGPoint(x: self.size * 0.5, y: self.size * 0.7))
                p.addLine(to: CGPoint(x: self.size * 0.65, y: self.size * 0.55))
            }
            context.stroke(arrowPath, with: .color(arrowColor), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}

struct PeopleGroupIcon: View {
    let size: CGFloat
    let inkColor = Color(red: 0.15, green: 0.15, blue: 0.15)
    
    var body: some View {
        Canvas { context, canvasSize in
            // Two standing figures with shared ground line
            let headRadius = self.size * 0.12
            let shoulderWidth = self.size * 0.25
            let bodyHeight = self.size * 0.35
            
            // Figure 1 (left)
            let head1 = Circle().path(in: CGRect(x: self.size * 0.15, y: self.size * 0.15,
                                                 width: headRadius * 2, height: headRadius * 2))
            let body1 = Path { p in
                p.move(to: CGPoint(x: self.size * 0.15 + headRadius, y: self.size * 0.15 + headRadius * 2))
                p.addLine(to: CGPoint(x: self.size * 0.08, y: self.size * 0.15 + headRadius * 2 + bodyHeight))
                p.addLine(to: CGPoint(x: self.size * 0.15 + headRadius + shoulderWidth - self.size * 0.08,
                                    y: self.size * 0.15 + headRadius * 2 + bodyHeight))
                p.closeSubpath()
            }
            
            // Figure 2 (right)
            let head2 = Circle().path(in: CGRect(x: self.size * 0.54, y: self.size * 0.15,
                                                 width: headRadius * 2, height: headRadius * 2))
            let body2 = Path { p in
                p.move(to: CGPoint(x: self.size * 0.54 + headRadius, y: self.size * 0.15 + headRadius * 2))
                p.addLine(to: CGPoint(x: self.size * 0.47, y: self.size * 0.15 + headRadius * 2 + bodyHeight))
                p.addLine(to: CGPoint(x: self.size * 0.54 + headRadius + shoulderWidth - self.size * 0.08,
                                    y: self.size * 0.15 + headRadius * 2 + bodyHeight))
                p.closeSubpath()
            }
            
            // Ground line
            let ground = Path { p in
                p.move(to: CGPoint(x: self.size * 0.05, y: self.size * 0.85))
                p.addLine(to: CGPoint(x: self.size * 0.95, y: self.size * 0.85))
            }
            
            context.fill(head1, with: .color(inkColor))
            context.fill(body1, with: .color(inkColor))
            context.fill(head2, with: .color(inkColor))
            context.fill(body2, with: .color(inkColor))
            context.stroke(ground, with: .color(inkColor), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}

struct CheckmarkIcon: View {
    let size: CGFloat
    let inkColor = Color(red: 0.15, green: 0.15, blue: 0.15)
    
    var body: some View {
        Canvas { context, canvasSize in
            let path = Path { p in
                p.move(to: CGPoint(x: self.size * 0.2, y: self.size * 0.5))
                p.addLine(to: CGPoint(x: self.size * 0.4, y: self.size * 0.7))
                p.addLine(to: CGPoint(x: self.size * 0.8, y: self.size * 0.3))
            }
            context.stroke(path, with: .color(inkColor), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}

struct RefreshIcon: View {
    let size: CGFloat
    let inkColor = Color(red: 0.15, green: 0.15, blue: 0.15)
    
    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: self.size / 2, y: self.size / 2)
            let radius = self.size * 0.35
            
            // Circular arrow
            let arc = Path { p in
                p.addArc(center: center, radius: radius,
                        startAngle: .degrees(45), endAngle: .degrees(315), clockwise: false)
            }
            context.stroke(arc, with: .color(inkColor), lineWidth: 1.5)
            
            // Arrow head
            let arrowHead = Path { p in
                p.move(to: CGPoint(x: center.x + radius * 0.5, y: center.y - radius * 0.866))
                p.addLine(to: CGPoint(x: center.x + radius * 0.707, y: center.y - radius * 0.707))
                p.addLine(to: CGPoint(x: center.x + radius * 0.866, y: center.y - radius * 0.5))
            }
            context.stroke(arrowHead, with: .color(inkColor), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}

struct DollarCircleIcon: View {
    let size: CGFloat
    let filled: Bool
    let inkColor = Color(red: 0.15, green: 0.15, blue: 0.15)
    
    var body: some View {
        Canvas { context, canvasSize in
            let circle = Circle().path(in: CGRect(origin: .zero, size: CGSize(width: self.size, height: self.size)))
            
            if filled {
                context.fill(circle, with: .color(inkColor))
            } else {
                context.stroke(circle, with: .color(inkColor), lineWidth: 1.5)
            }
            
            let dollarColor = filled ? Color.white : inkColor
            let dollar = Path { p in
                // $ symbol
                p.move(to: CGPoint(x: self.size * 0.5, y: self.size * 0.25))
                p.addLine(to: CGPoint(x: self.size * 0.5, y: self.size * 0.75))
                // Top curve
                p.move(to: CGPoint(x: self.size * 0.35, y: self.size * 0.35))
                p.addLine(to: CGPoint(x: self.size * 0.65, y: self.size * 0.35))
                // Bottom curve
                p.move(to: CGPoint(x: self.size * 0.35, y: self.size * 0.65))
                p.addLine(to: CGPoint(x: self.size * 0.65, y: self.size * 0.65))
            }
            context.stroke(dollar, with: .color(dollarColor), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}
