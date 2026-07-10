import SwiftUI
import Combine
import PhotosUI
import UIKit
import Contacts
import ContactsUI
import MessageUI
import Network
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

final class NetworkStatusMonitor: ObservableObject {
    static let shared = NetworkStatusMonitor()
    static let offlineMessage = "Turn on Wi-Fi or cellular data to use this feature."

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.dutchi.network-status")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    @discardableResult
    func requireOnline(message: String = NetworkStatusMonitor.offlineMessage) -> Bool {
        guard isOnline else {
            NotificationCenter.default.post(
                name: .showOfflineNetworkAlert,
                object: nil,
                userInfo: ["message": message]
            )
            return false
        }
        return true
    }
}




struct ReceiptTransactionData {
    var items:        [ReceiptTransactionItem]
    var accountType:  ReceiptAccountType
    var totalDebits:  Double
    var totalCredits: Double
    var confidence:   Float
    var processingMethod: String = "mistral"
    var processingTimeMs: Int? = nil
    var confidenceReason: String? = nil
}

private enum UploadManualInputField: Hashable {
    case name(UUID)
    case amount(UUID)
    case legacyName
    case legacyAmount

    var isAmountField: Bool {
        switch self {
        case .amount, .legacyAmount:
            return true
        case .name, .legacyName:
            return false
        }
    }

    var scrollID: String {
        switch self {
        case .name(let id), .amount(let id):
            return "manual-row-\(id.uuidString)"
        case .legacyName, .legacyAmount:
            return "manual-entry-scroll-anchor"
        }
    }
}

private struct PendingOfflineUpload: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case receiptImage
        case statementImage
        case statementPDF
    }

    let id: UUID
    let kind: Kind
    let filename: String
    let createdAt: Date
}

private enum UploadTopLevelTab: String, CaseIterable, Identifiable {
    case upload = "Upload"
    case balances = "Balances"

    var id: String { rawValue }
}

private enum UploadHomePage {
    case camera
    case balances
}

private enum CaptureMode: String, CaseIterable, Identifiable {
    case receiptPhoto
    case receipt
    case statement
    case manualEntry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .receiptPhoto: return "Receipt Photo"
        case .receipt: return "Receipt"
        case .statement: return "Statement"
        case .manualEntry: return "Manual Entry"
        }
    }

    var shutterTitle: String {
        switch self {
        case .receiptPhoto: return "RECEIPT PHOTO"
        case .receipt: return "RECEIPT"
        case .statement: return "STATEMENT"
        case .manualEntry: return "MANUAL ENTRY"
        }
    }

    var icon: String {
        switch self {
        case .receiptPhoto: return "photo"
        case .receipt: return "camera"
        case .statement: return "doc.text"
        case .manualEntry: return "square.and.pencil"
        }
    }
}



// MARK: - UploadView

struct UploadView: View {
    @EnvironmentObject var appState:        AppState
    @EnvironmentObject var router:          Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var authManager: AuthManager
    @AppStorage("dutchie.onboardingGroupModeTutorialRequired") private var onboardingGroupModeTutorialRequired = false
    @State private var showIncompleteItemAlert = false
    @State private var incompleteManualItemIDs: [UUID] = []
    @FocusState private var focusedManualField: UploadManualInputField?
    
    @StateObject private var activityStore = ActivityStore.shared
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var groupManager   = GroupManager.shared
    @StateObject private var trialManager = TrialManager.shared
    @EnvironmentObject var groupModeTutorial: GroupModeTutorialManager  // ← Use this instead
    @State private var manualItems: [UploadManualDraftItem] = []
    @State private var selectedTopLevelTab: UploadTopLevelTab = .upload
    @State private var isTabActionMenuExpanded = false
    @State private var selectedHomePage: UploadHomePage = .camera
    @State private var selectedCaptureMode: CaptureMode = .receipt
    @State private var selectedGroupContextID: UUID? = nil
    @GestureState private var pageDragOffset: CGFloat = 0
    @GestureState private var captureDragOffset: CGFloat = 0
    @State private var isFlashEnabled = false
    @State private var isToolRailCollapsed = false
    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var showCameraPermissionDeniedOverlay = false
    @State private var embeddedReceiptCaptureTrigger = 0
    @State private var isPresentingReceiptPhotoPicker = false
    @State private var isPresentingStatementPicker = false
    @State private var cartPulse = false
    @State private var cartFlyerMode: CaptureMode?
    @State private var cartFlyerIsAtCart = false
    @State private var hasPreparedInitialReceiptCamera = false
    
    @State private var showPhoneVerification = false
    @State private var selectedPhotos:  [PhotosPickerItem] = []
    @State private var showStatementFileImporter = false
    @State private var capturedImage:   UIImage? = nil
    @State private var showCameraForReceipt = false
    @State private var showPhotoPicker = false
    @State private var isActiveView = true
    @State private var uploadType: OCRService.DocumentType = .unknown
    @State private var showManualEntry   = false
    @State private var manualItemName    = ""
    @State private var manualItemAmount  = ""
    @State private var uploadedTransactions:           [UploadedTransaction] = []
    @State private var showReceiptViewer               = false
    @State private var selectedReceiptForViewing:      UploadedReceipt?
    @State private var showTransactionViewer           = false
    @State private var selectedTransactionForViewing:  UploadedTransaction?
    @State private var showStatementDateFilter = false
    @State private var statementDateFilterIndex: Int?
    @State private var statementFilterStartDate = Date()
    @State private var statementFilterEndDate = Date()
    @State private var isProcessingImage    = false
    @State private var processingMessage    = "Validating receipt..."
    @State private var processingSubtitle:  String? = nil
    @State private var isLowQualityGPTMode  = false
    @State private var processingToken:     Int = 0
    @State private var batchQueue:          [UIImage] = []
    @State private var batchTotal:          Int = 0
    @State private var batchDone:           Int = 0
    @State private var batchErrors:         [String] = []
    @State private var showInvalidReceiptAlert = false
    @State private var invalidReceiptMessage   = ""
    @State private var showReceiptUpdatedAlert = false
    @State private var receiptUpdatedMessage = ""
    @State private var showUploadNoticeAlert = false
    @State private var uploadNoticeTitle = ""
    @State private var uploadNoticeMessage = ""
    @State private var showLowQualityUploadAlert = false
    @State private var lowQualityUploadRequiresRetake = false
    @State private var lowQualityUploadMessage = ""
    @State private var showLowQualityProceedAlert = false
    @State private var hasPendingLowQualityScanWarning = false
    @State private var userWillHandleLowQualityScan = false
    @State private var confirmedLowQualityReviewProceed = false
    @State private var showUnsavedItemAlert    = false
    @State private var showResetUploadAlert     = false
    @State private var showPaywallSheet = false
    @State private var paywallOpenOnCredits = false
    @State private var paywallStartsPaidImmediately = false
    @State private var didDismissCreditPrompt = false
    @State private var showAccountTypePrompt   = false
    @State private var showUploadTutorial  = false
    @State private var uploadTutorialMode: ScanTutorialMode = .receipt
    @State private var pendingAction:      (() -> Void)? = nil
    @State private var accountTypeObserver: NSObjectProtocol?
    @State private var statementDataObserver: NSObjectProtocol?
    @State private var sharedImageObserver: NSObjectProtocol?
    @State private var deepLinkObserver: NSObjectProtocol?
    @State private var balancesDeepLinkObserver: NSObjectProtocol?
    @State private var groupJoinBannerObserver: NSObjectProtocol?
    @State private var openGroupDetailObserver: NSObjectProtocol?
    @State private var showGroupSelector    = false
    @State private var showGroupActiveToast = false
    @State private var activeGroupName      = ""
    @State private var showGroupDetail      = false
    @State private var showJoinBanner = false
    @State private var joinedMemberName = ""
    @State private var joinedGroupName = ""
    @State private var isLastJoinedMember = false
    @State private var showGroupJoin = false
    @State private var pendingInvite: PendingGroupInvite?
    @State private var showActivityFeed = false
    @State private var undoLeftGroup: DutchieGroup?
    @State private var showLeaveUndoBar = false
    @State private var suggestedItemName = ""
    @State private var suggestedItemAmount = ""
    @State private var showingSuggestion = false
    @State private var draftSummaries: [UploadDraftSummary] = []
    @State private var showSavedDrafts = false
    @State private var expandedDraftIDs: Set<UUID> = []
    @State private var isResettingUpload = false
    @State private var scanContinuedAfterLeaving = false
    @State private var scanCompletionNotificationSent = false
    @State private var scanBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var pendingOfflineUploads: [PendingOfflineUpload] = []
    @State private var isProcessingOfflineUploadQueue = false
    @AppStorage("hideReceiptScanTutorial") private var hideReceiptScanTutorial = false
    @AppStorage("hideStatementScanTutorial") private var hideStatementScanTutorial = false
    @AppStorage("didResetScanTutorialVisibilityV2") private var didResetScanTutorialVisibilityV2 = false

    private let receiptThumbnailImageSize: CGFloat = 100
    private let receiptThumbnailPadding: CGFloat = 6
    private var receiptThumbnailCellSize: CGFloat {
        receiptThumbnailImageSize + (receiptThumbnailPadding * 2)
    }

    var totalAmount: Double {
        appState.uploadedReceipts.reduce(0.0) { $0 + $1.total }
        + appState.manualTransactions.reduce(0.0) { $0 + $1.amount }
        + (appState.uploadedTransactions?.reduce(0.0) { $0 + $1.totalDebits } ?? 0.0)
    }

    var totalItems: Int {
        appState.uploadedReceipts.reduce(0) { $0 + $1.lineItems.count }
        + appState.manualTransactions.count
        + (appState.uploadedTransactions?.reduce(0) { $0 + $1.items.count } ?? 0)
    }

    private var readyUploadItemCount: Int {
        appState.uploadedReceipts.count +
        appState.manualTransactions.count +
        uploadedStatementCount
    }

    private var readyUploadTotal: Double {
        totalAmount
    }

    private var uploadedStatementCount: Int {
        appState.uploadedTransactions?.count ?? 0
    }

    private var canProceedFromUpload: Bool {
        readyUploadItemCount > 0
    }

    private var uploadReadinessText: String {
        if isProcessingImage {
            return "Scan in progress"
        }
        if !canProceedFromUpload {
            return "Add a receipt, statement, or manual item"
        }
        if incompleteManualDraftCount > 0 {
            return "\(incompleteManualDraftCount) manual item\(incompleteManualDraftCount == 1 ? "" : "s") need\(incompleteManualDraftCount == 1 ? "s" : "") attention"
        }
        if hasPendingLowQualityScanWarning && !userWillHandleLowQualityScan {
            return "Review scan warning before continuing"
        }
        return shouldProceedToGroupReview ? "Ready for review" : "Ready to choose people"
    }

    private var shouldShowUploadBottomCTA: Bool {
        isProcessingImage ||
        canProceedFromUpload ||
        incompleteManualDraftCount > 0 ||
        hasPendingLowQualityScanWarning
    }

    private var uploadCTAButtonTitle: String {
        if canProceedFromUpload {
            return shouldProceedToGroupReview ? "PROCEED TO REVIEW" : "PROCEED TO SPLIT"
        }
        if isProcessingImage {
            return "SCAN IN PROGRESS"
        }
        return "COMPLETE ITEMS FIRST"
    }

    private var incompleteManualDraftCount: Int {
        manualItems.filter { hasManualItemContent($0) && !isManualItemReady($0) }.count
    }

    private var shouldHighlightProfileButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .profileButton
    }
    private var shouldHighlightNextButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .nextButton
    }
    private var isUploadAndManualMultiSpotlight: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .uploadAndManual
    }
    
    private var backgroundLayer: some View {
        Color(red: 1.0, green: 0.992, blue: 0.969)
            .ignoresSafeArea()
    }
    
    @ViewBuilder
    private var overlayLayers: some View {
        if isProcessingImage {
            loadingOverlay.zIndex(50)
        }
        
        if showReceiptViewer, let receipt = selectedReceiptForViewing {
            fullScreenReceiptViewer(receipt: receipt)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(100)
        }
        
        if showTransactionViewer, let transaction = selectedTransactionForViewing {
            fullScreenTransactionViewer(transaction: transaction)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(100)
        }
        
        if showAccountTypePrompt {
            accountTypePrompt.zIndex(200)
        }
        
        if showUploadTutorial {
            CameraOverlayView(
                isVisible: $showUploadTutorial,
                mode: uploadTutorialMode,
                onNeverShowAgain: {
                    if uploadTutorialMode == .receipt {
                        hideReceiptScanTutorial = true
                    } else {
                        hideStatementScanTutorial = true
                    }
                }
            ) {
                pendingAction?(); pendingAction = nil
            }
            .transition(.opacity).zIndex(250)
        }
        
        if tutorialManager.isActive {
            TutorialOverlay(context: .upload).zIndex(300)
        }
    }

    @ViewBuilder
    private var groupSelectorOverlay: some View {
        if showGroupSelector {
            if !(groupModeTutorial.isActive && groupModeTutorial.currentStepIndex == 1) {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.3)) { showGroupSelector = false } }
                    .zIndex(400)
            }
            
            VStack {
                HStack {
                    Spacer()
                    groupSelectorMenu
                        .padding(.top, 70)
                        .padding(.trailing, 20)
                }
                Spacer()
            }
            .zIndex(401)
        }
    }
    
    private var shouldStartGroupModeTutorial: Bool {
        if onboardingGroupModeTutorialRequired || groupModeTutorial.onboardingGroupModeTutorialRequired {
            guard !tutorialManager.isActive else { return false }
            guard tutorialManager.hasCompletedTutorial else { return false }
            return true
        }
        guard authManager.isAuthenticated else { return false }
        guard !groupModeTutorial.hasCompletedGroupModeTutorial else { return false }
        
        // Don't trigger if main tutorial is active
        guard !tutorialManager.isActive else { return false }
        
        // Trigger only if main tutorial is completed (first-time app users see main tutorial first)
        guard tutorialManager.hasCompletedTutorial else { return false }
        
        return true
    }
    
    @ViewBuilder
    private var toastOverlay: some View {
        if showGroupActiveToast {
            VStack {
                groupActiveToastView
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Spacer()
            }
            .zIndex(500)
        }
    }
    
    private var joinBannerOverlay: some View {
        VStack {
            if showJoinBanner {
                GroupJoinBannerView(
                    memberName: joinedMemberName,
                    groupName: joinedGroupName,
                    isLastMember: isLastJoinedMember,
                    isVisible: $showJoinBanner,
                    onTap: {
                        withAnimation(.spring(response: 0.3)) {
                            showJoinBanner = false
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 70)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1000)
            }
            Spacer()
        }
    }

    private var leaveUndoOverlay: some View {
        VStack {
            Spacer()
            if showLeaveUndoBar, let group = undoLeftGroup {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LEFT \(group.name.uppercased())")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969))
                        Text("The group stays visible for everyone else.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969).opacity(0.72))
                    }

                    Spacer()

                    Button {
                        HapticManager.notification(type: .success)
                        groupManager.restoreLeftGroup(group)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showLeaveUndoBar = false
                        }
                    } label: {
                        Text("UNDO")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(Color(red: 0.10, green: 0.10, blue: 0.10))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color(red: 1.0, green: 0.992, blue: 0.969))
                            .cornerRadius(2)
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.96))
                }
                .padding(14)
                .background(Color(red: 0.10, green: 0.10, blue: 0.10))
                .cornerRadius(3)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1200)
            }
        }
    }

    var body: some View {
        uploadPresentationView
    }

    private var uploadRootView: some View {
        ZStack {
            backgroundLayer
            mainContent.zIndex(1)
            overlayLayers
            groupSelectorOverlay
            toastOverlay
            joinBannerOverlay
            leaveUndoOverlay
        }
        .navigationBarBackButtonHidden(true)
    }

    private var uploadLifecycleView: some View {
        uploadRootView
        .onAppear(perform: handleUploadAppear)
        
        .onDisappear {
            isActiveView = false
        }
        
        .overlay {
            if groupModeTutorial.isActive && isActiveView {
                GroupModeTutorialOverlay(
                    context: .upload,
                    tutorialManager: groupModeTutorial
                )
                .zIndex(200)
            }
        }
        .onChange(of: groupModeTutorial.shouldShowGroupQuickController) { _, shouldShow in
            withAnimation(.spring(response: 0.3)) {
                showGroupSelector = shouldShow
            }
        }
        .onChange(of: tutorialManager.isActive) { _, isActive in
            guard isActive else { return }
            prepareUploadScreenForTutorial()
        }
        .onChange(of: groupModeTutorial.isActive) { _, isActive in
            guard isActive else { return }
            prepareUploadScreenForTutorial()
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupDidLeave)) { _ in
            handleGroupDidLeave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupDidLeaveWithUndo)) { notification in
            guard let group = notification.userInfo?["group"] as? DutchieGroup else { return }
            undoLeftGroup = group
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showLeaveUndoBar = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showLeaveUndoBar = false
                }
            }
        }
        .onChange(of: selectedPhotos) { _, newPhotos in loadPhotos(newPhotos) }
        .onChange(of: appState.profile.venmoUsername)     { _, _ in groupManager.syncCurrentUserPaymentInfo(from: appState.profile) }
        .onChange(of: appState.profile.venmoPaymentLink)  { _, _ in groupManager.syncCurrentUserPaymentInfo(from: appState.profile) }
        .onChange(of: appState.profile.zelleContactInfo)  { _, _ in groupManager.syncCurrentUserPaymentInfo(from: appState.profile) }
        .onChange(of: appState.profile.zellePaymentLink)  { _, _ in groupManager.syncCurrentUserPaymentInfo(from: appState.profile) }
        .onChange(of: appState.profile.zelleQRCode)       { _, _ in groupManager.syncCurrentUserPaymentInfo(from: appState.profile) }
        .onChange(of: trialManager.sharedSubscriptionGroupID) { _, _ in
            ensureSubscriptionGroupVisibleOnUpload(activate: false)
        }
        .onChange(of: trialManager.ownedSubscriptionGroupID) { _, _ in
            ensureSubscriptionGroupVisibleOnUpload(activate: false)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: networkMonitor.isOnline) { _, isOnline in
            guard isOnline else { return }
            processPendingOfflineUploadsIfNeeded()
        }
    }

    private var uploadAlertView: some View {
        uploadLifecycleView
        .alert(invalidUploadAlertTitle, isPresented: $showInvalidReceiptAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text(invalidReceiptMessage) }
        .alert("Receipt Updated", isPresented: $showReceiptUpdatedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(receiptUpdatedMessage)
        }
        .alert(uploadNoticeTitle, isPresented: $showUploadNoticeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(uploadNoticeMessage)
        }
        .alert(lowQualityUploadRequiresRetake ? "Total Not Accurate" : "Retake Recommended", isPresented: $showLowQualityUploadAlert) {
            Button("Take It Again") {
                handleLowQualityRetake()
            }
            if lowQualityUploadRequiresRetake {
                Button("Close", role: .cancel) {
                    acceptLowQualityScanWarning()
                }
            } else {
                Button("I Will Handle It", role: .cancel) {
                    acceptLowQualityScanWarning()
                }
            }
        } message: {
            Text(lowQualityUploadMessage)
        }
        .alert(lowQualityUploadRequiresRetake ? "Total Not Accurate" : "Receipt Accuracy May Be Low", isPresented: $showLowQualityProceedAlert) {
            Button("Take It Again") {
                handleLowQualityRetake()
            }
            if lowQualityUploadRequiresRetake {
                Button("Close", role: .cancel) {
                    acceptLowQualityScanWarning()
                }
            } else {
                Button("I Will Handle It") {
                    acceptLowQualityScanWarning()
                    proceedFromUpload()
                }
                Button("Close", role: .cancel) {
                    acceptLowQualityScanWarning()
                }
            }
        } message: {
            Text(lowQualityUploadRequiresRetake
                 ? "Dutch could not confirm the receipt total. Take the receipt again before splitting."
                 : "This receipt or statement was not clear, so the extracted amounts may be inaccurate. Take it again for better accuracy, or review every item carefully before splitting.")
        }
        .alert("Unsaved Item", isPresented: $showUnsavedItemAlert) {
            Button("Discard", role: .destructive) {
                handleUnsavedDiscard()
            }
            Button("Add & Continue") {
                handleUnsavedAddAndContinue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have an unsaved item. Would you like to add it before continuing?")
        }
        .alert("Reset Upload?", isPresented: $showResetUploadAlert) {
            Button("Reset Everything", role: .destructive) {
                resetUpload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all receipts, statements, manual entries, and saved upload drafts.")
        }
    }

    private var invalidUploadAlertTitle: String {
        uploadType == .transactionHistory ? "Statement Needs Review" : "Receipt Scan"
    }

    private var uploadPresentationView: some View {
        uploadAlertView
        .sheet(isPresented: $showPhotoPicker, onDismiss: handleReceiptPhotoPickerDismissed) {
            MultiImagePicker { images in if !images.isEmpty { processImages(images) } }
        }
        .fileImporter(
            isPresented: $showStatementFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handleStatementPickerDismissed()
            handleStatementFileImport(result)
        }
        .onChange(of: showStatementFileImporter) { _, isPresented in
            if !isPresented && isPresentingStatementPicker {
                handleStatementPickerDismissed()
            }
        }
        .sheet(isPresented: $showStatementDateFilter) {
            statementDateFilterSheet
        }
        .sheet(isPresented: $showPaywallSheet, onDismiss: {
            paywallOpenOnCredits = false
            paywallStartsPaidImmediately = false
        }) {
            PaywallView(
                startsPaidImmediately: paywallStartsPaidImmediately || trialManager.hasStartedTrial,
                initialPurchaseType: paywallOpenOnCredits ? .creditPack : .subscription
            )
            .environmentObject(appState)
        }
        .onChange(of: tutorialManager.shouldShowPaywallAfterTutorial) { shouldShow in
            guard shouldShow else { return }
            tutorialManager.shouldShowPaywallAfterTutorial = false
            if presentPendingInviteIfReady() {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showPaywallSheet = true
            }
        }
        .sheet(isPresented: $showCameraForReceipt) {
            CameraImagePicker { image in
                showCameraForReceipt = false
                if let image {
                    processImage(image)
                }
            }
            .ignoresSafeArea()
            .edgesIgnoringSafeArea(.all)
        }
        .sheet(isPresented: $router.showGroupCreationSheet) {
            GroupCreationSheet(
                groupManager: groupManager,
                appState: appState,
                isPresented: $router.showGroupCreationSheet
            ) { groupName in
                showConfirmationToast(groupName: groupName)
            }
            .environmentObject(groupModeTutorial)
        }
        .sheet(isPresented: $showGroupJoin) {
            if let invite = pendingInvite {
                GroupJoinView(
                    groupManager: groupManager,
                    invite: invite,
                    onJoinComplete: {
                    }
                )
                .environmentObject(authManager)
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showPhoneVerification) {
            PhoneVerificationPromptSheet(
                authManager: authManager,
                prefilledPhone: appState.profile.zelleContactInfo ?? "",
                isPresented: $showPhoneVerification,
                onVerified: {
                    handlePhoneVerified()
                }
            )
        }
        
        .sheet(isPresented: $showGroupDetail) {
            if let group = groupManager.activeGroup,
               let currentUser = appState.people.first(where: { $0.isCurrentUser }) {
                GroupDetailSheet(
                    group: group,
                    groupManager: groupManager,
                    currentUserID: currentUser.id,
                    onLeave: {
                        groupManager.leaveAndClearGroup()
                        showGroupDetail = false
                    },
                    onDelete: {
                        if let group = groupManager.activeGroup {
                            deleteGroup(group)
                        }
                        showGroupDetail = false
                    }
                )
            }
        }
        .sheet(isPresented: $showActivityFeed) {
            ActivityFeedView(store: activityStore, currentUserPhone: authManager.phoneNumber)
        }
    }

    private var groupActiveToastView: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969))
            }
            
            Text("\(activeGroupName) active")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 1.0, green: 0.992, blue: 0.969))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.1), radius: 8, y: 4)
        )
    }
    
    private func showWelcomeToast(groupName: String) {
        activeGroupName = groupName
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showGroupActiveToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showGroupActiveToast = false
            }
        }
    }

    private var hasCurrentUploadWork: Bool {
        !appState.uploadedReceipts.isEmpty ||
        !appState.manualTransactions.isEmpty ||
        !(appState.uploadedTransactions?.isEmpty ?? true) ||
        manualItems.contains {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !$0.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func restoreUploadDraftIfNeeded() {
        guard !hasCurrentUploadWork,
              let draft = appState.restoreUploadDraft() else {
            return
        }

        manualItems = draft.showManualEntry && draft.manualItems.isEmpty
            ? [UploadManualDraftItem()]
            : draft.manualItems
        showManualEntry = draft.showManualEntry || !draft.manualItems.isEmpty
    }
    
    private func restoreUploadDraft(id: UUID) {
        guard let draft = appState.restoreUploadDraft(id: id) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            manualItems = draft.showManualEntry && draft.manualItems.isEmpty
                ? [UploadManualDraftItem()]
                : draft.manualItems
            showManualEntry = draft.showManualEntry || !draft.manualItems.isEmpty
        }
        refreshDraftSummaries()
        HapticManager.notification(type: .success)
    }

    private func deleteUploadDraft(id: UUID) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            appState.clearUploadDraft(id: id)
            expandedDraftIDs.remove(id)
            refreshDraftSummaries()
        }
        HapticManager.notification(type: .warning)
    }

    private func saveUploadDraft(forceNewVersion: Bool = false) {
        guard !isResettingUpload else { return }
        appState.saveUploadDraft(
            manualItems: manualItems,
            showManualEntry: showManualEntry,
            forceNewVersion: forceNewVersion
        )
        refreshDraftSummaries()
    }

    private func refreshDraftSummaries() {
        draftSummaries = appState.uploadDraftSummaries
    }

    private func resetUpload() {
        isResettingUpload = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            appState.uploadedImages.removeAll()
            appState.uploadedReceipts.removeAll()
            appState.manualTransactions.removeAll()
            appState.uploadedTransactions = nil
            appState.transactions.removeAll()
            appState.uploadReviewSyncSessionID = UUID()
            manualItems.removeAll()
            showManualEntry = false
            selectedPhotos.removeAll()
            capturedImage = nil
            selectedReceiptForViewing = nil
            selectedTransactionForViewing = nil
            showReceiptViewer = false
            showTransactionViewer = false
            hasPendingLowQualityScanWarning = false
            userWillHandleLowQualityScan = false
            confirmedLowQualityReviewProceed = false
            showLowQualityUploadAlert = false
            showLowQualityProceedAlert = false
            lowQualityUploadRequiresRetake = false
        }
        HapticManager.notification(type: .warning)
        DispatchQueue.main.async {
            isResettingUpload = false
        }
    }

    private func prepareUploadScreenForTutorial() {
        focusedManualField = nil
        pendingAction = nil
        incompleteManualItemIDs.removeAll()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            showManualEntry = false
            manualItems.removeAll()
            showIncompleteItemAlert = false
            showUploadTutorial = false
            showAccountTypePrompt = false
            showStatementDateFilter = false
            showReceiptViewer = false
            showTransactionViewer = false
            showGroupJoin = false
            showPhoneVerification = false
            router.showGroupCreationSheet = false
            if !groupModeTutorial.shouldShowGroupQuickController {
                showGroupSelector = false
            }
        }
        selectedPhotos.removeAll()
        capturedImage = nil
        selectedReceiptForViewing = nil
        selectedTransactionForViewing = nil
        showCameraForReceipt = false
        showPhotoPicker = false
        showStatementFileImporter = false
    }

    private func handleUploadAppear() {
        isActiveView = true
        resetScanTutorialVisibilityIfNeeded()
        refreshDraftSummaries()
        loadPendingOfflineUploads()
        processPendingOfflineUploadsIfNeeded()
        setupAccountTypeListener()
        setupSharedImageListener()
        setupStatementDataListener()

        if !tutorialManager.isActive && !tutorialManager.hasCompletedTutorial {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                tutorialManager.start()
            }
        }

        if tutorialManager.shouldShowPaywallAfterTutorial {
            tutorialManager.shouldShowPaywallAfterTutorial = false
            if presentPendingInviteIfReady() {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showPaywallSheet = true
            }
        }

        presentPendingInviteIfReady()

        if !groupManager.isGroupModeEnabled {
            appState.forcePersonalSplitForCurrentUpload = true
        }

        if !appState.forcePersonalSplitForCurrentUpload, groupManager.isGroupModeEnabled {
            groupManager.syncMembersToAppState(appState)
        }
        groupManager.syncCurrentUserPaymentInfo(from: appState.profile)
        groupManager.startObservingAvailableGroups()
        trialManager.syncSubscriptionStatusWithFirebase()
        ensureSubscriptionGroupVisibleOnUpload(activate: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            ensureSubscriptionGroupVisibleOnUpload(activate: false)
        }

        if groupManager.isGroupModeEnabled, let group = groupManager.activeGroup {
            showWelcomeToast(groupName: group.name)
        }

        setupDeepLinkListener()
        setupBalancesDeepLinkListener()
        setupGroupJoinBannerListener()
        setupOpenGroupDetailListener()

        let groupIDs = groupManager.currentUserAvailableGroups.map { $0.id.uuidString }
        activityStore.startListening(for: groupIDs)

        if let phone = authManager.phoneNumber, !phone.isEmpty {
            activityStore.startListeningToUserInbox(phoneKey: ActivityStore.phoneKey(for: phone))
        }

        if router.pendingBalanceHighlightItemID?.isEmpty == false {
            openBalancesFromDeepLink()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            enforceRequiredGroupModeTutorialIfNeeded()
        }
    }

    private func enforceRequiredGroupModeTutorialIfNeeded() {
        guard trialManager.hasAppEntitlement else {
            return
        }
        guard shouldStartGroupModeTutorial else { return }
        guard !groupModeTutorial.isActive else {
            return
        }

        showGroupSelector = false
        showGroupJoin = false
        showPhoneVerification = false
        router.showGroupCreationSheet = false

        groupModeTutorial.router = router
        groupModeTutorial.appState = appState
        groupModeTutorial.groupManager = groupManager
        groupModeTutorial.start()
    }

    private func resetScanTutorialVisibilityIfNeeded() {
        guard !didResetScanTutorialVisibilityV2 else { return }
        hideReceiptScanTutorial = false
        hideStatementScanTutorial = false
        didResetScanTutorialVisibilityV2 = true
    }

    private func setupDeepLinkListener() {
        guard deepLinkObserver == nil else { return }
        deepLinkObserver = NotificationCenter.default.addObserver(
            forName: .processDeepLink,
            object: nil,
            queue: .main
        ) { notification in
            guard let invite = notification.userInfo?["invite"] as? PendingGroupInvite else { return }
            guard tutorialManager.hasCompletedTutorial else {
                groupManager.pendingInvite = invite
                return
            }
            if authManager.canUseGroupMode {
                pendingInvite = invite
                showGroupJoin = true
            } else {
                groupManager.pendingInvite = invite
                showPhoneVerification = true
            }
        }
    }

    private func setupBalancesDeepLinkListener() {
        guard balancesDeepLinkObserver == nil else { return }
        balancesDeepLinkObserver = NotificationCenter.default.addObserver(
            forName: .openBalances,
            object: nil,
            queue: .main
        ) { notification in
            if let itemID = notification.userInfo?["itemID"] as? String {
                router.pendingBalanceHighlightItemID = itemID
            }
            openBalancesFromDeepLink()
        }
    }

    private func openBalancesFromDeepLink() {
        appState.syncBalanceItemsFromFirebaseIfPossible()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedTopLevelTab = .balances
        }
    }

    @discardableResult
    private func presentPendingInviteIfReady() -> Bool {
        guard tutorialManager.hasCompletedTutorial,
              let invite = groupManager.pendingInvite else {
            return false
        }

        pendingInvite = invite
        groupManager.pendingInvite = nil

        if authManager.canUseGroupMode {
            showGroupJoin = true
        } else {
            showPhoneVerification = true
        }

        return true
    }

    private func setupOpenGroupDetailListener() {
        guard openGroupDetailObserver == nil else { return }
        openGroupDetailObserver = NotificationCenter.default.addObserver(
            forName: .openGroupDetail,
            object: nil,
            queue: .main
        ) { _ in
            guard groupManager.isGroupModeEnabled, groupManager.activeGroup != nil else { return }
            showGroupDetail = true
        }
    }

    private func setupGroupJoinBannerListener() {
        guard groupJoinBannerObserver == nil else { return }
        groupJoinBannerObserver = NotificationCenter.default.addObserver(
            forName: .showGroupJoinBanner,
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let name = userInfo["memberName"] as? String,
                  let group = userInfo["groupName"] as? String,
                  let isLast = userInfo["isLastMember"] as? Bool else {
                return
            }

            joinedMemberName = name
            joinedGroupName = group
            isLastJoinedMember = isLast

            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showJoinBanner = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation(.spring(response: 0.3)) {
                    showJoinBanner = false
                }
            }
        }
    }

    private func handleGroupDidLeave() {
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
            ?? Person(name: appState.profile.name, isCurrentUser: true)
        appState.people = [currentUser]
        appState.transactions.removeAll()
        appState.uploadReviewSyncSessionID = UUID()
        appState.uploadedReceipts.removeAll()
        appState.manualTransactions.removeAll()
        appState.clearUploadDraft()
        refreshDraftSummaries()
    }

    private func handleUnsavedDiscard() {
        manualItemName = ""
        manualItemAmount = ""
        navigateAfterUpload()
    }

    private func handleUnsavedAddAndContinue() {
        addManualItem()
        navigateAfterUpload()
    }

    private func navigateAfterUpload() {
        if shouldProceedToGroupReview {
            appState.forcePersonalSplitForCurrentUpload = false
            prepareGroupReviewNavigation()
            convertToTransactions()
            router.navigateToReview()
        } else {
            appState.forcePersonalSplitForCurrentUpload = true
            router.navigateToPeople()
        }
    }

    private var shouldProceedToGroupReview: Bool {
        isGroupModeActiveForUploadReview
    }

    private var isGroupModeActiveForUploadReview: Bool {
        groupManager.isGroupModeEnabled && groupManager.activeGroup != nil
    }

    private var hasSubscriptionGroupContext: Bool {
        if let group = groupManager.activeGroup, isSubscriptionBackedGroup(group) {
            return true
        }

        return TrialManager.shared.sharedSubscriptionGroupID != nil ||
            TrialManager.shared.ownedSubscriptionGroupID != nil ||
            TrialManager.shared.activeSubscriptionPoolGroupID != nil ||
            groupManager.currentUserSubscriptionInviteGroups.contains { !$0.isSubscriptionInviteStaging }
    }

    private func prepareGroupReviewNavigation() {
        guard authManager.canUseGroupMode else { return }

        if groupManager.isGroupModeEnabled, groupManager.activeGroup != nil {
            return
        }

        ensureSubscriptionGroupVisibleOnUpload(activate: true)

        if groupManager.activeGroup == nil {
            _ = groupManager.activateSubscriptionGroupForCurrentUser()
        }

        guard groupManager.activeGroup == nil else { return }

        let subscriptionGroupID = TrialManager.shared.sharedSubscriptionGroupID
            ?? TrialManager.shared.ownedSubscriptionGroupID
            ?? TrialManager.shared.activeSubscriptionPoolGroupID

        if let subscriptionGroupID,
           let group = groupManager.getGroup(by: subscriptionGroupID) {
            groupManager.setActiveGroup(group)
        }
    }

    private func handlePhoneVerified() {
        if let invite = groupManager.pendingInvite {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pendingInvite = invite
                showGroupJoin = true
                groupManager.pendingInvite = nil
            }
            return
        }

        if !groupModeTutorial.hasCompletedGroupModeTutorial {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                groupModeTutorial.router = router
                groupModeTutorial.appState = appState
                groupModeTutorial.groupManager = groupManager
                groupModeTutorial.start()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.3)) {
                    showGroupSelector = true
                }
            }
        }
    }
    
    private func generateSuggestion() {
        // Common quick-add items with typical prices
        let suggestions: [(name: String, amount: String)] = [
            ("Coffee", "5.50"),
            ("Lunch", "12.00"),
            ("Dinner", "25.00"),
            ("Uber/Lyft", "15.00"),
            ("Groceries", "30.00"),
            ("Gas", "45.00"),
            ("Movie Tickets", "18.00"),
            ("Drinks", "20.00"),
            ("Parking", "10.00"),
            ("Fast Food", "9.00")
        ]
        
        // Pick a random suggestion
        if let suggestion = suggestions.randomElement() {
            suggestedItemName = suggestion.name
            suggestedItemAmount = suggestion.amount
            showingSuggestion = true
        }
    }
    
    private func showConfirmationToast(groupName: String) {
        activeGroupName = groupName
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showGroupActiveToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showGroupActiveToast = false
            }
        }
    }
    
    private func manualItemRow(itemID: UUID) -> some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
        let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
        let item = manualItems.first(where: { $0.id == itemID }) ?? UploadManualDraftItem(id: itemID)
        let needsAttention = incompleteManualItemIDs.contains(itemID)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("Item name", text: Binding(
                    get: { manualItems.first(where: { $0.id == itemID })?.name ?? "" },
                    set: { newValue in
                        guard let index = manualItems.firstIndex(where: { $0.id == itemID }) else { return }
                        manualItems[index].name = newValue
                        incompleteManualItemIDs.removeAll { $0 == itemID }
                    }
                ))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ink)
                .tint(ink)
                .focused($focusedManualField, equals: .name(itemID))
                .submitLabel(.next)
                .onSubmit { focusedManualField = .amount(itemID) }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(ink.opacity(0.14))
                    .frame(width: 1, height: 22)

                HStack(spacing: 3) {
                    Text("$")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(needsAttention ? Color.red.opacity(0.75) : ink.opacity(0.55))
                    TextField("0.00", text: Binding(
                        get: { manualItems.first(where: { $0.id == itemID })?.amount ?? "" },
                        set: { newValue in
                            guard let index = manualItems.firstIndex(where: { $0.id == itemID }) else { return }
                            manualItems[index].amount = sanitizedManualAmountInput(newValue)
                            incompleteManualItemIDs.removeAll { $0 == itemID }
                            ensureTrailingManualDraft(after: itemID)
                        }
                    ))
                    .font(.system(size: 16, weight: .black))
                    .foregroundColor(ink)
                    .tint(ink)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedManualField, equals: .amount(itemID))
                }
                .frame(width: 96)

                Button(action: {
                    HapticManager.impact(style: .light)
                    removeManualDraftItem(itemID)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(ink.opacity(0.45))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.9))
            }

            if needsAttention {
                Text(manualItemAttentionText(item))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red.opacity(0.75))
            }
        }
        .id("manual-row-\(itemID.uuidString)")
        .padding(12)
        .background(ivory)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(needsAttention ? Color.red.opacity(0.65) : ink.opacity(0.38), lineWidth: needsAttention ? 2 : 1.5)
        )
    }
    
   
    private var groupSelectorMenu: some View {
        VStack(spacing: 0) {
            let groups = stableVisibleGroups
            if !groups.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            groupSelectorRow(group: group)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 320)
                
                Rectangle()
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .frame(height: 1.5)
            }
            
            // Pay Now / Settle Now button (only show if active group exists)
            if groupManager.isGroupModeEnabled, groupManager.activeGroup != nil {
                Button(action: {
                    HapticManager.impact(style: .medium)
                    if groupModeTutorial.isActive && groupModeTutorial.currentStepIndex == 1 {
                        withAnimation(.spring(response: 0.3)) {
                            showGroupSelector = false
                        }
                        groupModeTutorial.nextStep()
                        return
                    }
                    withAnimation(.spring(response: 0.3)) {
                        showGroupSelector = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        router.navigateToSettle()
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.green)
                        Text("Pay Now / Settle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .background(Color.green.opacity(0.05))
                
                Rectangle()
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .frame(height: 1.5)
            }
            
            // Create New Group button
            Button(action: {
                HapticManager.impact(style: .medium)
                guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to create or manage groups.") else {
                    return
                }
                withAnimation(.spring(response: 0.3)) {
                    showGroupSelector = false
                }
                
                // Check if this is first time creating group
                if !groupModeTutorial.hasCompletedGroupModeTutorial && groupManager.currentUserAvailableGroups.isEmpty {
                    // First time - start tutorial
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        groupModeTutorial.router = router
                        groupModeTutorial.appState = appState
                        groupModeTutorial.groupManager = groupManager
                        groupModeTutorial.start()
                    }
                } else {
                    // Normal flow - just show group creation sheet
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        router.showGroupCreationSheet = true  // Instead of showGroupNameSheet = true
                    }
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    Text("Create New Group")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 1.0, green: 0.992, blue: 0.969))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 12, y: 6)
        )
    }
    
    
    
    private func groupSelectorRow(group: DutchieGroup) -> some View {
        HStack(spacing: 0) {
            Button(action: {
                HapticManager.impact(style: .light)
                toggleGroup(group)
            }) {
                HStack(spacing: 12) {
                    Text(group.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if groupManager.isGroupModeEnabled && groupManager.activeGroup?.id == group.id {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            
            if !isSubscriptionBackedGroup(group) {
                Button(action: {
                    HapticManager.notification(type: .warning)
                    deleteGroup(group)
                }) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.red.opacity(0.8))
                        .frame(width: 56, height: 56)
                        .background(Color.red.opacity(0.1))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .background(
            Color(red: 0.98, green: 0.98, blue: 0.96)
                .opacity(groupManager.isGroupModeEnabled && groupManager.activeGroup?.id == group.id ? 1.0 : 0.0)
        )
    }
    
    private func toggleGroup(_ group: DutchieGroup) {
        guard authManager.canUseGroupMode else {
            showPhoneVerification = true
            return
        }

        if groupManager.isGroupModeEnabled && groupManager.activeGroup?.id == group.id {
            groupManager.disableGroupMode(clearActiveGroup: true)
            appState.forcePersonalSplitForCurrentUpload = true
            withAnimation(.spring(response: 0.3)) {
                showGroupSelector = false
            }
        } else {
            appState.forcePersonalSplitForCurrentUpload = false
            groupManager.setActiveGroup(group)
            groupManager.enableGroupMode()
            groupManager.syncMembersToAppState(appState)
            
            withAnimation(.spring(response: 0.3)) {
                showGroupSelector = false
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showConfirmationToast(groupName: group.name)
            }
        }
    }

    private func deleteGroup(_ group: DutchieGroup) {
        guard !isSubscriptionBackedGroup(group) else {
            HapticManager.notification(type: .warning)
            return
        }

        if groupManager.activeGroup?.id == group.id {
            groupManager.leaveAndClearGroup()
        }
        
        groupManager.deleteGroup(group)
        
        if groupManager.currentUserAvailableGroups.isEmpty {
            withAnimation(.spring(response: 0.3)) {
                showGroupSelector = false
            }
        }
    }

    @ViewBuilder
    private var visibleGroupsSection: some View {
        let groups = stableVisibleGroups
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("GROUPS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(1.6)

                    Spacer()

                    Button {
                        HapticManager.impact(style: .light)
                        handleGroupIconTap()
                    } label: {
                        Text("SEE ALL")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.9)
                            .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.62))
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        visibleGroupRow(group)
                        if index < groups.count - 1 {
                            Rectangle()
                                .fill(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.12))
                                .frame(height: 1)
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(Color(red: 1.0, green: 0.992, blue: 0.969))
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.16), lineWidth: 1)
                )
            }
        }
    }

    private var stableVisibleGroups: [DutchieGroup] {
        uniqueGroupsByID(groupManager.currentUserAvailableGroups)
    }

    private func uniqueGroupsByID(_ groups: [DutchieGroup]) -> [DutchieGroup] {
        var seen = Set<UUID>()
        var unique: [DutchieGroup] = []

        for group in groups {
            guard !seen.contains(group.id) else { continue }
            seen.insert(group.id)
            unique.append(group)
        }

        return unique
    }

    private func visibleGroupRow(_ group: DutchieGroup) -> some View {
        let isActive = groupManager.isGroupModeEnabled && groupManager.activeGroup?.id == group.id
        return Button {
            HapticManager.impact(style: .light)
            toggleGroup(group)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(isActive ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.92, green: 0.92, blue: 0.89))
                    .frame(width: 34, height: 34)
                    .overlay(
                        groupIconShape(filled: isActive)
                            .scaleEffect(0.72)
                            .foregroundColor(isActive ? Color(red: 0.96, green: 0.96, blue: 0.94) : Color(red: 0.15, green: 0.15, blue: 0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .lineLimit(1)

                    Text(groupSubtitle(for: group, isActive: isActive))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(isActive ? "ACTIVE" : "USE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.9)
                    .foregroundColor(isActive ? Color(red: 0.96, green: 0.96, blue: 0.94) : Color(red: 0.15, green: 0.15, blue: 0.15))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isActive ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color.clear)
                    .overlay(
                        Capsule()
                            .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(isActive ? 0 : 0.25), lineWidth: 1)
                    )
                    .clipShape(Capsule())
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func groupSubtitle(for group: DutchieGroup, isActive: Bool) -> String {
        let count = group.activeMemberCount
        let memberText = "\(count) member\(count == 1 ? "" : "s")"
        if isSubscriptionBackedGroup(group) {
            return "\(memberText) · Subscription group"
        }
        return isActive ? "\(memberText) · Current group" : memberText
    }

    private func isSubscriptionBackedGroup(_ group: DutchieGroup) -> Bool {
        guard !group.isSubscriptionInviteStaging else { return false }
        return group.maxMemberCount != nil ||
            TrialManager.shared.ownedSubscriptionGroupID == group.id ||
            TrialManager.shared.sharedSubscriptionGroupID == group.id ||
            TrialManager.shared.activeSubscriptionPoolGroupID == group.id
    }

    private func ensureSubscriptionGroupVisibleOnUpload(activate: Bool = false) {
        if let groupID = TrialManager.shared.sharedSubscriptionGroupID {
            groupManager.ensureSubscriptionGroupVisible(
                groupID: groupID,
                groupName: TrialManager.shared.sharedSubscriptionGroupName ?? "Dutch Group",
                profile: appState.profile,
                activate: activate
            )
        } else if let groupID = TrialManager.shared.ownedSubscriptionGroupID {
            groupManager.ensureSubscriptionGroupVisible(
                groupID: groupID,
                groupName: TrialManager.shared.ownedSubscriptionGroupName ?? "Dutch Group",
                profile: appState.profile,
                activate: activate
            )
        }
    }
    
    // Handler for locally-parsed statement data
    private func handleTransactionData(
        _ transactionData: ReceiptTransactionData,
        image: UIImage,
        sourceType: String = "screenshot"
    ) -> Bool {
        // Prefer spending rows for expense splitting, but do not reject a server/Mistral
        // parse locally just because a page only contains credits or non-spend rows.
        let debits = transactionData.items.filter { $0.isDebit }
        let importedItems = debits.isEmpty ? transactionData.items : debits
        if isDuplicateStatement(transactionData, debitItems: importedItems) {
            print("📊 Ignored duplicate statement OCR result")
            showDuplicateUploadNotice(
                title: "Statement Already Added",
                message: "This statement appears to already be in your upload list. We kept the existing copy so it is not counted twice."
            )
            return false
        }
        
        // Create ONE UploadedTransaction for the entire statement
        let tx = UploadedTransaction(
            image: image,
            accountType: transactionData.accountType,
            items: importedItems,
            totalDebits: transactionData.totalDebits,
            totalCredits: transactionData.totalCredits,
            sourceType: sourceType,
            confidence: transactionData.confidence,
            processingMethod: transactionData.processingMethod,
            processingTimeMs: transactionData.processingTimeMs,
            confidenceReason: transactionData.confidenceReason
        )
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            // Store in AppState instead of local state
            if appState.uploadedTransactions == nil {
                appState.uploadedTransactions = []
            }
            appState.uploadedTransactions?.append(tx)
            print("📊 Stored statement in AppState: \(tx.items.count) items, $\(tx.totalDebits)")
        }
        playCartAddAnimation(for: .statement)
        // DO NOT add individual items to manualTransactions
        // The statement is converted into one review transaction with breakdown rows later.

        if batchTotal <= 1 {
            showLowQualityStatementWarningIfNeeded(for: tx)
            saveCompletedScanDraft()
            finishBackgroundScanIfNeeded(documentName: "Statement")
        }

        return true
    }

    private func isDuplicateStatement(_ transactionData: ReceiptTransactionData, debitItems: [ReceiptTransactionItem]) -> Bool {
        guard let existing = appState.uploadedTransactions else { return false }
        return existing.contains { transaction in
            transaction.accountType == transactionData.accountType &&
            abs(transaction.totalDebits - transactionData.totalDebits) < 0.01 &&
            abs(transaction.totalCredits - transactionData.totalCredits) < 0.01 &&
            transaction.items.count == debitItems.count &&
            transaction.items.map(\.description) == debitItems.map(\.description) &&
            transaction.items.map { String(format: "%.2f", $0.amount) } == debitItems.map { String(format: "%.2f", $0.amount) }
        }
    }
    // UPDATED: Better error messages for receipt vs statement
    private func handleOCRResult(_ result: Result<OCRService.ReceiptData, Error>, image: UIImage) -> Bool {
        switch result {
        case .success(let receiptData):
            return handleReceiptData(receiptData, image: image)
        case .failure(let error):
            let nsError = error as NSError
            
            // Special case: statement handled via notification - not an error
            if nsError.code == -213 {
                print("  [handleOCRResult] Statement handled via notification - ignoring")
                return false
            }
            
            // Better error messages based on document type
            if uploadType == .receipt {
                print("Receipt OCR failure ignored for OpenCV testing: \(error.localizedDescription)")
                return handleReceiptData(testReceiptData(from: image, reason: error.localizedDescription), image: image)
            } else if uploadType == .transactionHistory {
                invalidReceiptMessage = "The statement parser could not read this upload confidently. Please try again or upload the PDF statement."
            } else {
                invalidReceiptMessage = "The parser could not read this upload confidently. Please try again."
            }
            
            showInvalidReceiptAlert = true
            return false
        }
    }

    private var mainContent: some View {
        UploadKeyboardToolbarHost(
            showDone: focusedManualField?.isAmountField == true,
            onDone: dismissManualKeyboard
        ) {
            AnyView(tabbedUploadHome)
        }
    }

    private var tabbedUploadHome: some View {
        ZStack(alignment: .bottom) {
            selectedTopLevelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)

            bottomNavigationArea
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .zIndex(20)
        }
        .background(Color(red: 1.0, green: 0.992, blue: 0.969))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: selectedTopLevelTab) { _, tab in
            if tab == .upload {
                selectedHomePage = .camera
                selectedCaptureMode = .receipt
            } else {
                selectedHomePage = .balances
                dismissManualKeyboard()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isTabActionMenuExpanded = false
                }
            }
        }
    }

    @ViewBuilder
    private var selectedTopLevelContent: some View {
        switch selectedTopLevelTab {
        case .upload:
            restoredUploadHome
        case .balances:
            balancesPage
        }
    }

    private var restoredUploadHome: some View {
        ZStack {
            Color(red: 1.0, green: 0.992, blue: 0.969)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerSection

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        restoredAddExpensesSection

                        manualEntrySection

                        if hasUploadedDocumentThumbnails {
                            uploadedDocumentThumbnailsSection
                        } else {
                            restoredReceiptsHeading
                        }

                        if !draftSummaries.isEmpty {
                            savedDraftsSection
                        }

                        if shouldShowUploadBottomCTA {
                            inlineProceedCTA
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 136)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        dismissManualKeyboard()
                    }
                )
            }
        }
    }

    private var restoredAddExpensesSection: some View {
        UploadActionSection(
            hasCurrentUploadWork: true,
            isProcessingImage: isProcessingImage,
            onSaveDraft: saveDraftFromButton,
            onReset: {
                HapticManager.impact(style: .light)
                showResetUploadAlert = true
            },
            onReceiptCamera: startReceiptCameraScanFromTab,
            onReceiptGallery: startReceiptGalleryScanFromTab,
            onStatementPDF: startStatementScanFromTab
        )
    }

    private var restoredReceiptsHeading: some View {
        Text("RECEIPTS")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(1.5)
            .padding(.horizontal, 4)
            .padding(.top, 18)
    }

    private var inlineProceedCTA: some View {
        VStack(spacing: 8) {
            if !canProceedFromUpload || incompleteManualDraftCount > 0 || hasPendingLowQualityScanWarning {
                Text(uploadReadinessText.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.48))
                    .tracking(1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Button(action: {
                HapticManager.impact(style: .medium)
                proceedFromUpload()
            }) {
                HStack(spacing: 8) {
                    Text(uploadCTAButtonTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(1)
                    if canProceedFromUpload {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .foregroundColor(canProceedFromUpload ? .white : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.30))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(canProceedFromUpload ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.08))
                .cornerRadius(3)
            }
            .disabled(!canProceedFromUpload)
            .buttonStyle(ScaleButtonStyle())
            .tutorialSpotlight(isHighlighted: shouldHighlightNextButton, cornerRadius: 3)
        }
    }

    private var snapchatUploadPager: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                balancesPage
                    .frame(width: geometry.size.width, height: geometry.size.height)

                dutchiCameraHome
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .offset(x: pagerXOffset(width: geometry.size.width))
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: selectedHomePage)
            .gesture(pageSwipeGesture(size: geometry.size))
        }
        .ignoresSafeArea()
        .onAppear {
            guard !hasPreparedInitialReceiptCamera else { return }
            hasPreparedInitialReceiptCamera = true
            selectedCaptureMode = .receipt
            syncSelectedContextWithActiveGroup()
            if selectedHomePage == .camera {
                prepareReceiptCameraImmediately()
            }
        }
        .onChange(of: selectedHomePage) { _, page in
            selectedTopLevelTab = page == .camera ? .upload : .balances
            if page == .camera {
                prepareReceiptCameraImmediately()
            } else {
                dismissManualKeyboard()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isTabActionMenuExpanded = false
                }
            }
        }
        .onChange(of: readyUploadItemCount) { oldValue, newValue in
            guard newValue > oldValue else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.48)) {
                cartPulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    cartPulse = false
                }
            }
        }
    }

    private func pagerXOffset(width: CGFloat) -> CGFloat {
        let base = selectedHomePage == .balances ? CGFloat.zero : -width
        return base + pageDragOffset
    }

    private func pageSwipeGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .updating($pageDragOffset) { value, state, _ in
                guard value.startLocation.y < size.height - 250 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                switch selectedHomePage {
                case .balances:
                    state = min(0, value.translation.width)
                case .camera:
                    state = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                guard value.startLocation.y < size.height - 250 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let threshold = min(size.width * 0.18, 120)

                switch selectedHomePage {
                case .balances where value.translation.width < -threshold:
                    HapticManager.impact(style: .light)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        selectedHomePage = .camera
                    }
                case .camera where value.translation.width > threshold:
                    HapticManager.impact(style: .light)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        selectedHomePage = .balances
                    }
                default:
                    break
                }
            }
    }

    private var dutchiCameraHome: some View {
        ZStack {
            cameraPreviewSurface
            if !usesLightUploadSurface {
                cameraReadabilityGradients
            }
            receiptScanOverlay

            if showCameraPermissionDeniedOverlay && selectedCaptureMode == .receipt {
                cameraPermissionOverlay
                    .padding(.horizontal, 24)
                    .zIndex(20)
            }

            VStack(spacing: 0) {
                topCameraOverlay
                if selectedCaptureMode == .manualEntry {
                    cameraManualEntryPanel
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                }
                shutterAndModeCarousel
                    .padding(.bottom, 10)
                bottomWorkflowTabs
                    .padding(.bottom, 26)
            }

            if !usesLightUploadSurface {
                GeometryReader { geometry in
                    rightToolRail
                        .position(
                            x: geometry.size.width - 35,
                            y: max(176, geometry.size.height * 0.32)
                        )
                }
                .allowsHitTesting(true)
            }

            cartFlyerOverlay
        }
        .background(usesLightUploadSurface ? Color(red: 1.0, green: 0.992, blue: 0.969) : Color.black)
        .contentShape(Rectangle())
    }

    private var cameraPreviewSurface: some View {
        ZStack {
            if selectedCaptureMode == .receipt,
               cameraAuthorizationStatus == .authorized,
               UIImagePickerController.isSourceTypeAvailable(.camera) {
                DutchiEmbeddedReceiptCameraView(
                    captureTrigger: $embeddedReceiptCaptureTrigger,
                    isFlashEnabled: $isFlashEnabled,
                    onImageCaptured: { image in
                        if let image {
                            processImage(image)
                        }
                    }
                )
                .ignoresSafeArea()
            } else if usesLightUploadSurface {
                Color(red: 1.0, green: 0.992, blue: 0.969)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    modeGlyph(for: selectedCaptureMode, color: Color(red: 0.15, green: 0.15, blue: 0.14), lineWidth: 2.2)
                        .frame(width: 70, height: 70)
                        .opacity(0.10)
                    Text(selectedCaptureMode.title.uppercased())
                        .font(.system(size: 12, weight: .black))
                        .tracking(1.7)
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.14).opacity(0.28))
                }
                .offset(y: -36)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.055, blue: 0.055),
                        Color(red: 0.11, green: 0.105, blue: 0.095),
                        Color(red: 0.02, green: 0.02, blue: 0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 18) {
                    modeGlyph(for: selectedCaptureMode, color: .white.opacity(0.18), lineWidth: 2.4)
                        .frame(width: 72, height: 72)
                    Text(selectedCaptureMode.title)
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1.6)
                        .foregroundColor(.white.opacity(0.36))
                }
                .offset(y: -18)
            }

            if let group = selectedContextGroup {
                VStack {
                    Spacer()
                    Text("ADDS TO \(group.name.uppercased())")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(.white.opacity(0.86))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.42))
                        .clipShape(Capsule())
                        .padding(.bottom, 245)
                }
            }
        }
    }

    private var usesLightUploadSurface: Bool {
        selectedCaptureMode == .manualEntry
    }

    @ViewBuilder
    private var receiptScanOverlay: some View {
        if selectedCaptureMode == .receipt {
            GeometryReader { geometry in
                let width = min(geometry.size.width * 0.74, 330)
                let height = min(geometry.size.height * 0.44, 430)
                ZStack {
                    receiptScanFrame(width: width, height: height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -24)
            }
            .allowsHitTesting(false)
        }
    }

    private func receiptScanFrame(width: CGFloat, height: CGFloat) -> some View {
        return ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                .frame(width: width, height: height)

            ReceiptScanCorners()
                .stroke(Color.white.opacity(0.88), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: width, height: height)
        }
    }

    private var cameraPermissionOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
            Text("Camera Access Needed")
                .font(.system(size: 18, weight: .black))
                .foregroundColor(.white)
            Text("Allow camera access to scan receipts directly from this screen.")
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.72))
            Button {
                openAppSettings()
            } label: {
                Text("OPEN SETTINGS")
                    .font(.system(size: 12, weight: .black))
                    .tracking(1.1)
                    .foregroundColor(Color(red: 0.12, green: 0.12, blue: 0.11))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.96))
        }
        .padding(22)
        .background(.black.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var cameraReadabilityGradients: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.58), .black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)

            Spacer()

            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 360)
        }
        .allowsHitTesting(false)
    }

    private var topCameraOverlay: some View {
        let ink = usesLightUploadSurface ? Color(red: 0.14, green: 0.14, blue: 0.13) : .white
        return HStack(spacing: 10) {
            Button {
                HapticManager.impact(style: .light)
                router.presentProfile()
            } label: {
                AvatarView(
                    imageData: appState.profile.avatarImage,
                    initials: appState.profile.initials,
                    size: 44
                )
                .overlay(Circle().stroke(ink.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .tutorialSpotlight(isHighlighted: shouldHighlightProfileButton, cornerRadius: 22)

            Spacer()

            if selectedHomePage == .camera {
                uploadCartButton(ink: ink)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 54)
    }

    private func uploadCartButton(ink: Color) -> some View {
        Button {
            HapticManager.impact(style: .medium)
            proceedFromUpload()
        } label: {
            ZStack(alignment: .topTrailing) {
                DutchUploadGlyph(kind: .cart, color: ink, lineWidth: 2.2)
                    .frame(width: 25, height: 25)
                    .frame(width: 46, height: 46)
                    .background(usesLightUploadSurface ? Color(red: 0.93, green: 0.93, blue: 0.90) : .black.opacity(0.34))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(ink.opacity(0.16), lineWidth: 1))

                if readyUploadItemCount > 0 {
                    Text("\(readyUploadItemCount)")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(usesLightUploadSurface ? Color(red: 1.0, green: 0.992, blue: 0.969) : Color(red: 0.12, green: 0.12, blue: 0.11))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, readyUploadItemCount > 9 ? 4 : 0)
                        .background(usesLightUploadSurface ? Color(red: 0.13, green: 0.13, blue: 0.13) : .white)
                        .clipShape(Capsule())
                        .offset(x: 4, y: -4)
                }
            }
            .scaleEffect(cartPulse ? 1.14 : 1.0)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.94))
        .disabled(!canProceedFromUpload)
        .opacity(canProceedFromUpload ? 1 : 0.58)
        .accessibilityLabel("Upload cart")
    }

    @ViewBuilder
    private var cartFlyerOverlay: some View {
        if let mode = cartFlyerMode {
            GeometryReader { geometry in
                let start = CGPoint(x: geometry.size.width / 2, y: geometry.size.height - 170)
                let end = CGPoint(x: geometry.size.width - 39, y: 77)

                ZStack {
                    Circle()
                        .fill(usesLightUploadSurface ? Color(red: 0.13, green: 0.13, blue: 0.13) : Color.white)
                        .frame(width: 42, height: 42)
                        .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 8)
                    modeGlyph(
                        for: mode,
                        color: usesLightUploadSurface ? Color(red: 1.0, green: 0.992, blue: 0.969) : Color(red: 0.12, green: 0.12, blue: 0.11),
                        lineWidth: 2.1
                    )
                    .frame(width: 21, height: 21)
                }
                .position(cartFlyerIsAtCart ? end : start)
                .scaleEffect(cartFlyerIsAtCart ? 0.35 : 1.0)
                .opacity(cartFlyerIsAtCart ? 0.15 : 1.0)
                .animation(.spring(response: 0.46, dampingFraction: 0.78), value: cartFlyerIsAtCart)
                .allowsHitTesting(false)
            }
            .transition(.opacity)
            .zIndex(30)
        }
    }

    private func playCartAddAnimation(for mode: CaptureMode) {
        cartFlyerMode = mode
        cartFlyerIsAtCart = false

        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                cartFlyerIsAtCart = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.48)) {
                cartPulse = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) {
            withAnimation(.easeOut(duration: 0.12)) {
                cartFlyerMode = nil
                cartFlyerIsAtCart = false
                cartPulse = false
            }
        }
    }

    private var rightToolRail: some View {
        VStack(spacing: 12) {
            cameraRailButton(systemName: isFlashEnabled ? "bolt.fill" : "bolt.slash", isActive: isFlashEnabled) {
                isFlashEnabled.toggle()
                HapticManager.impact(style: .light)
            }
        }
    }

    private var cameraManualEntryPanel: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    manualEntrySection
                    if canProceedFromUpload {
                        Button {
                            HapticManager.impact(style: .medium)
                            proceedFromUpload()
                        } label: {
                            Text(shouldProceedToGroupReview ? "PROCEED TO REVIEW" : "PROCEED TO SPLIT")
                                .font(.system(size: 14, weight: .black))
                                .tracking(1.1)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(Color(red: 0.12, green: 0.12, blue: 0.11))
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 1.0, green: 0.992, blue: 0.969))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 8)
            .onChange(of: focusedManualField) { _, field in
                guard let field else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(field.scrollID, anchor: .center)
                    }
                }
            }
        }
    }

    private var cameraReviewStrip: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isProcessingImage ? "SCANNING" : "READY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(.white.opacity(0.62))
                Text(isProcessingImage ? processingMessage : "\(readyUploadItemCount) item\(readyUploadItemCount == 1 ? "" : "s") · \(formatQuickCurrency(readyUploadTotal))")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            Spacer()

            if canProceedFromUpload {
                Button {
                    HapticManager.impact(style: .medium)
                    proceedFromUpload()
                } label: {
                    Text(shouldProceedToGroupReview ? "REVIEW" : "SPLIT")
                        .font(.system(size: 12, weight: .black))
                        .tracking(0.8)
                        .foregroundColor(Color(red: 0.12, green: 0.12, blue: 0.11))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var shutterAndModeCarousel: some View {
        VStack(spacing: 12) {
            ZStack {
                shutterButton

                ForEach([-2, -1, 1, 2], id: \.self) { relativeOffset in
                    if let mode = captureMode(relativeOffset: relativeOffset) {
                        captureModeBubble(mode)
                            .scaleEffect(captureModeScale(relativeOffset: relativeOffset))
                            .opacity(captureModeOpacity(relativeOffset: relativeOffset))
                            .offset(
                                x: captureModeXOffset(relativeOffset: relativeOffset),
                                y: abs(relativeOffset) == 2 ? 8 : 0
                            )
                            .zIndex(Double(4 - abs(relativeOffset)))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 112)

            Text(selectedCaptureMode.shutterTitle)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundColor(carouselInk.opacity(0.88))
        }
        .padding(.horizontal, 20)
        .highPriorityGesture(captureCarouselDragGesture)
    }

    private var carouselInk: Color {
        usesLightUploadSurface ? Color(red: 0.14, green: 0.14, blue: 0.13) : .white
    }

    private var captureCarouselDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($captureDragOffset) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = max(-130, min(130, value.translation.width))
            }
            .onEnded { value in
                let horizontalMovement = abs(value.predictedEndTranslation.width) > abs(value.translation.width)
                    ? value.predictedEndTranslation.width
                    : value.translation.width
                guard abs(horizontalMovement) > abs(value.translation.height),
                      abs(horizontalMovement) > 28 else { return }

                if horizontalMovement < 0 {
                    selectAdjacentCaptureMode(offset: 1)
                } else {
                    selectAdjacentCaptureMode(offset: -1)
                }
            }
    }

    private func captureModeXOffset(relativeOffset: Int) -> CGFloat {
        let base: CGFloat
        switch relativeOffset {
        case -2:
            base = -190
        case -1:
            base = -118
        case 1:
            base = 118
        case 2:
            base = 190
        default:
            base = 0
        }

        return base + captureDragOffset
    }

    private func captureModeScale(relativeOffset: Int) -> CGFloat {
        let projectedDistance = abs(captureModeXOffset(relativeOffset: relativeOffset))
        if projectedDistance < 84 { return 0.98 }
        if projectedDistance > 150 { return 0.82 }
        return 0.90
    }

    private func captureModeOpacity(relativeOffset: Int) -> Double {
        let projectedDistance = abs(captureModeXOffset(relativeOffset: relativeOffset))
        if projectedDistance < 84 { return 0.88 }
        if projectedDistance > 150 { return 0.54 }
        return 1.0
    }

    private func selectAdjacentCaptureMode(offset: Int) {
        guard let index = CaptureMode.allCases.firstIndex(of: selectedCaptureMode) else { return }
        let target = index + offset
        guard CaptureMode.allCases.indices.contains(target) else { return }
        selectCaptureMode(CaptureMode.allCases[target], userInitiated: false)
    }

    private func captureMode(relativeOffset: Int) -> CaptureMode? {
        guard let index = CaptureMode.allCases.firstIndex(of: selectedCaptureMode) else { return nil }
        let target = index + relativeOffset
        guard CaptureMode.allCases.indices.contains(target) else { return nil }
        return CaptureMode.allCases[target]
    }

    private var shutterButton: some View {
        Button {
            handleShutterTap()
        } label: {
            ZStack {
                Circle()
                    .stroke(carouselInk, lineWidth: 6)
                    .frame(width: 86, height: 86)
                Circle()
                    .fill(carouselInk.opacity(usesLightUploadSurface ? 0.10 : 0.24))
                    .frame(width: 70, height: 70)
                modeGlyph(for: selectedCaptureMode, color: carouselInk, lineWidth: 2.3)
                    .frame(width: 30, height: 30)
            }
            .shadow(color: .black.opacity(usesLightUploadSurface ? 0.10 : 0.32), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.95))
    }

    private func captureModeBubble(_ mode: CaptureMode) -> some View {
        let isSelected = selectedCaptureMode == mode
        return Button {
            selectCaptureMode(mode, userInitiated: true)
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(isSelected ? carouselInk : (usesLightUploadSurface ? Color(red: 0.93, green: 0.93, blue: 0.90) : .black.opacity(0.48)))
                        .frame(width: isSelected ? 58 : 48, height: isSelected ? 58 : 48)
                    modeGlyph(
                        for: mode,
                        color: isSelected ? (usesLightUploadSurface ? Color(red: 1.0, green: 0.992, blue: 0.969) : Color(red: 0.12, green: 0.12, blue: 0.11)) : carouselInk.opacity(0.88),
                        lineWidth: isSelected ? 2.2 : 2.0
                    )
                    .frame(width: isSelected ? 25 : 22, height: isSelected ? 25 : 22)
                }
                Text(mode.title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(carouselInk.opacity(isSelected ? 0.95 : 0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 78)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.94))
    }

    private func modeGlyph(for mode: CaptureMode, color: Color, lineWidth: CGFloat) -> some View {
        let kind: DutchUploadGlyph.Kind
        switch mode {
        case .receiptPhoto:
            kind = .gallery
        case .receipt:
            kind = .receipt
        case .statement:
            kind = .statement
        case .manualEntry:
            kind = .manual
        }

        return DutchUploadGlyph(kind: kind, color: color, lineWidth: lineWidth)
    }

    private var bottomWorkflowTabs: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        workflowTabButton(title: "Personal", isSelected: selectedGroupContextID == nil && selectedHomePage == .camera) {
                            selectPersonalContext()
                        }
                        .id("personal-context")

                        ForEach(stableVisibleGroups) { group in
                            workflowTabButton(title: group.name, isSelected: selectedGroupContextID == group.id && selectedHomePage == .camera) {
                                selectGroupContext(group)
                            }
                            .id(groupContextScrollID(group.id))
                        }

                        workflowAddGroupButton
                            .id("create-group-context")
                    }
                    .padding(.horizontal, max(28, geometry.size.width / 2 - 66))
                    .padding(.vertical, 2)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        let targetID = selectedGroupContextID.map { groupContextScrollID($0) } ?? "personal-context"
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                }
                .onChange(of: selectedGroupContextID) { _, groupID in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                        let targetID = groupID.map { groupContextScrollID($0) } ?? "personal-context"
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                }
                .onChange(of: stableVisibleGroups.count) { _, _ in
                    guard selectedGroupContextID == nil else { return }
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            proxy.scrollTo("personal-context", anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(height: 48)
    }

    private func groupContextScrollID(_ id: UUID) -> String {
        "group-context-\(id.uuidString)"
    }

    private func workflowTabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .black))
                .tracking(0.4)
                .foregroundColor(usesLightUploadSurface ? Color(red: 0.14, green: 0.14, blue: 0.13).opacity(isSelected ? 1.0 : 0.52) : .white.opacity(isSelected ? 1.0 : 0.64))
                .padding(.horizontal, isSelected ? 16 : 8)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(isSelected ? (usesLightUploadSurface ? Color(red: 0.93, green: 0.93, blue: 0.90) : Color.black.opacity(0.46)) : Color.clear)
                )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.96))
    }

    private var workflowAddGroupButton: some View {
        Button {
            HapticManager.impact(style: .medium)
            guard authManager.canUseGroupMode else {
                showPhoneVerification = true
                return
            }
            selectedHomePage = .camera
            router.openGroupCreationSheet()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .black))
                .foregroundColor(usesLightUploadSurface ? Color(red: 0.14, green: 0.14, blue: 0.13) : .white)
                .frame(width: 36, height: 36)
                .background(usesLightUploadSurface ? Color(red: 0.93, green: 0.93, blue: 0.90) : Color.black.opacity(0.46))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke((usesLightUploadSurface ? Color(red: 0.14, green: 0.14, blue: 0.13) : .white).opacity(0.18), lineWidth: 1)
                )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.94))
        .accessibilityLabel("Create group")
    }

    private var balancesPage: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 1.0, green: 0.992, blue: 0.969)
                .ignoresSafeArea()

            BalancesView {
                HapticManager.impact(style: .light)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    selectedTopLevelTab = .upload
                }
            }
                .environmentObject(appState)
                .environmentObject(router)
                .padding(.top, 22)
        }
    }

    private func cameraCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.38))
                .clipShape(Circle())
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.94))
    }

    private func cameraRailButton(systemName: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(isActive ? Color(red: 0.12, green: 0.12, blue: 0.11) : .white)
                .frame(width: 42, height: 42)
                .background(isActive ? .white.opacity(0.94) : .black.opacity(0.38))
                .clipShape(Circle())
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.94))
    }

    private func handleShutterTap() {
        HapticManager.impact(style: .medium)
        dismissManualKeyboard()

        switch selectedCaptureMode {
        case .receipt:
            captureReceiptUsingEmbeddedCamera()
        case .receiptPhoto:
            openExistingReceiptPhotoPickerImmediately()
        case .statement:
            openExistingStatementPickerImmediately()
        case .manualEntry:
            openManualEntryFromTab(autoFocus: false)
        }
    }

    private func selectCaptureMode(_ mode: CaptureMode, userInitiated: Bool) {
        guard selectedCaptureMode != mode || mode == .receiptPhoto || (userInitiated && (mode == .statement || mode == .manualEntry)) else { return }
        HapticManager.impact(style: .light)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            selectedCaptureMode = mode
        }

        switch mode {
        case .receipt:
            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                showManualEntry = false
            }
            prepareReceiptCameraImmediately()
        case .receiptPhoto:
            guard userInitiated else { return }
            openExistingReceiptPhotoPickerImmediately()
        case .statement:
            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                showManualEntry = false
            }
            guard userInitiated else { return }
            openExistingStatementPickerImmediately()
        case .manualEntry:
            openManualEntryFromTab(autoFocus: false)
        }
    }

    private func captureReceiptUsingEmbeddedCamera() {
        uploadType = .receipt
        uploadTutorialMode = .receipt
        runScanAction(mode: .receipt) {
            showCameraForReceipt = true
        }
    }

    private func openExistingReceiptPhotoPickerImmediately() {
        guard !isPresentingReceiptPhotoPicker else { return }
        dismissManualKeyboard()
        uploadType = .receipt
        uploadTutorialMode = .receipt
        guard canStartNetworkScan() else { return }
        if trialManager.isOutOfIncludedOCRCredits {
            HapticManager.notification(type: .warning)
            openOutOfCreditsPaywall(preferredOutOfCreditsPaywallTarget)
            return
        }
        isPresentingReceiptPhotoPicker = true
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedTopLevelTab = .upload
            isTabActionMenuExpanded = false
            showManualEntry = false
        }
        showPhotoPicker = true
    }

    private func openExistingStatementPickerImmediately() {
        guard !isPresentingStatementPicker else { return }
        dismissManualKeyboard()
        uploadType = .transactionHistory
        uploadTutorialMode = .transaction
        guard canStartNetworkScan() else { return }
        if trialManager.isOutOfIncludedOCRCredits {
            HapticManager.notification(type: .warning)
            openOutOfCreditsPaywall(preferredOutOfCreditsPaywallTarget)
            return
        }
        isPresentingStatementPicker = true
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedTopLevelTab = .upload
            isTabActionMenuExpanded = false
            showManualEntry = false
        }
        showStatementFileImporter = true
    }

    private func handleReceiptPhotoPickerDismissed() {
        isPresentingReceiptPhotoPicker = false
    }

    private func handleStatementPickerDismissed() {
        isPresentingStatementPicker = false
    }

    private func prepareReceiptCameraImmediately() {
        guard selectedCaptureMode == .receipt else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorizationStatus = status

        switch status {
        case .authorized:
            showCameraPermissionDeniedOverlay = false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    showCameraPermissionDeniedOverlay = !granted
                }
            }
        case .denied, .restricted:
            showCameraPermissionDeniedOverlay = true
        @unknown default:
            showCameraPermissionDeniedOverlay = true
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var selectedContextGroup: DutchieGroup? {
        guard let selectedGroupContextID else { return nil }
        return stableVisibleGroups.first { $0.id == selectedGroupContextID }
            ?? groupManager.activeGroup.flatMap { $0.id == selectedGroupContextID ? $0 : nil }
    }

    private var selectedContextTitle: String {
        selectedContextGroup?.name ?? "Personal"
    }

    private func syncSelectedContextWithActiveGroup() {
        if groupManager.isGroupModeEnabled, let activeGroup = groupManager.activeGroup {
            selectedGroupContextID = activeGroup.id
            appState.forcePersonalSplitForCurrentUpload = false
        } else {
            selectedGroupContextID = nil
            appState.forcePersonalSplitForCurrentUpload = true
        }
    }

    private func preparePersonalContextForUploadHome() {
        selectedGroupContextID = nil
        appState.forcePersonalSplitForCurrentUpload = true
        groupManager.disableGroupMode(clearActiveGroup: true)
    }

    private func selectPersonalContext() {
        HapticManager.impact(style: .light)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
            selectedGroupContextID = nil
            selectedHomePage = .camera
        }
        appState.forcePersonalSplitForCurrentUpload = true
        groupManager.disableGroupMode(clearActiveGroup: true)
    }

    private func selectGroupContext(_ group: DutchieGroup) {
        HapticManager.impact(style: .light)
        guard authManager.canUseGroupMode else {
            showPhoneVerification = true
            return
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
            selectedGroupContextID = group.id
            selectedHomePage = .camera
        }

        appState.forcePersonalSplitForCurrentUpload = false
        groupManager.setActiveGroup(group)
        groupManager.enableGroupMode()
        groupManager.syncMembersToAppState(appState)
    }

    private var bottomNavigationArea: some View {
        VStack(spacing: 0) {
            DutchFloatingUploadTabBar(
                selectedTab: $selectedTopLevelTab,
                isActionMenuExpanded: $isTabActionMenuExpanded,
                onReceiptCamera: startReceiptCameraScanFromTab,
                onReceiptGallery: startReceiptGalleryScanFromTab,
                onScanStatement: startStatementScanFromTab,
                onManualEntry: { openManualEntryFromTab(autoFocus: true) }
            )
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: focusedManualField)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: isTabActionMenuExpanded)
    }

    private func startReceiptCameraScanFromTab() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedTopLevelTab = .upload
            isTabActionMenuExpanded = false
        }
        dismissManualKeyboard()
        startReceiptCameraScan()
    }

    private func startReceiptGalleryScanFromTab() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedTopLevelTab = .upload
            isTabActionMenuExpanded = false
        }
        dismissManualKeyboard()
        startReceiptGalleryScan()
    }

    private func startReceiptCameraScan() {
        uploadType = .receipt
        uploadTutorialMode = .receipt
        runScanAction(mode: .receipt) {
            showCameraForReceipt = true
        }
    }

    private func startReceiptGalleryScan() {
        uploadType = .receipt
        uploadTutorialMode = .receipt
        runScanAction(mode: .receipt) {
            showPhotoPicker = true
        }
    }

    private func startStatementScanFromTab() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedTopLevelTab = .upload
            isTabActionMenuExpanded = false
        }
        uploadType = .transactionHistory
        runScanAction(mode: .transaction) {
            showStatementFileImporter = true
        }
    }

    private func openManualEntryFromTab(autoFocus: Bool = true) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedTopLevelTab = .upload
            isTabActionMenuExpanded = false
            showManualEntry = true
            if manualItems.isEmpty {
                manualItems.append(UploadManualDraftItem())
            }
        }

        if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focusedManualField = manualItems.first.map { .name($0.id) }
            }
        } else {
            focusedManualField = nil
        }
    }

    private func dismissManualKeyboard() {
        focusedManualField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var outOfCreditsPrompt: some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
        let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)

        return VStack(alignment: .leading, spacing: 12) {
            Text("OUT OF CREDITS")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundColor(ink.opacity(0.5))

            Text(outOfCreditsPromptMessage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                if shouldOfferStartProNow {
                    Button {
                        HapticManager.impact(style: .medium)
                        openOutOfCreditsPaywall(.subscription)
                    } label: {
                        Text("START PRO NOW")
                            .font(.system(size: 13, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(ivory)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(ink)
                            .cornerRadius(2)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }

                Button {
                    HapticManager.impact(style: .medium)
                    openOutOfCreditsPaywall(.creditPack)
                } label: {
                    Text("PURCHASE CREDITS")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(shouldOfferStartProNow ? ink : ivory)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(shouldOfferStartProNow ? Color.clear : ink)
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(shouldOfferStartProNow ? ink.opacity(0.35) : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    HapticManager.impact(style: .light)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        didDismissCreditPrompt = true
                    }
                } label: {
                    Text("Later")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ink.opacity(0.45))
                        .padding(.top, 2)
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(16)
        .background(ivory)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(0.20), lineWidth: 1.5)
        )
    }

    private var outOfCreditsPromptMessage: String {
        if isActiveRecurringSubscriptionOutOfIncludedCredits {
            return "You are out of credits until \(trialManager.creditResetDescription). Would you like to purchase more credits?"
        }
        if shouldOfferStartProNow {
            return "You used all included trial scan credits for your recurring plan. Start Pro now to unlock the subscription credits today, or purchase extra credits."
        }
        if isCreditOnlyCreditsExhausted {
            return "You used all available scan credits. Purchase more credits to keep scanning."
        }
        if trialManager.isTrialExpired {
            return "Your 3-day trial has ended. Purchase credits to keep scanning."
        }
        return "You used all 20 trial scan credits. Would you like to purchase more credits?"
    }

    private enum OutOfCreditsPaywallTarget {
        case subscription
        case creditPack
    }

    private var isCreditPackEntitlement: Bool {
        (trialManager.subscriptionPlanName ?? "").localizedCaseInsensitiveContains("credit pack")
    }

    private var hasScheduledRecurringSubscription: Bool {
        trialManager.hasScheduledSubscription && !trialManager.hasActiveSubscription && !isCreditPackEntitlement
    }

    private var shouldOfferStartProNow: Bool {
        trialManager.isTrialActive &&
        hasScheduledRecurringSubscription &&
        trialManager.receiptOCRSessionsRemaining <= 0
    }

    private var isActiveRecurringSubscriptionOutOfIncludedCredits: Bool {
        trialManager.hasActiveSubscription && trialManager.subscriptionOCRSessionsRemaining == 0
    }

    private var isCreditOnlyCreditsExhausted: Bool {
        !trialManager.hasActiveSubscription &&
        !hasScheduledRecurringSubscription &&
        trialManager.purchasedOCRCreditsRemaining <= 0
    }

    private var preferredOutOfCreditsPaywallTarget: OutOfCreditsPaywallTarget {
        shouldOfferStartProNow ? .subscription : .creditPack
    }

    private func openOutOfCreditsPaywall(_ target: OutOfCreditsPaywallTarget) {
        paywallOpenOnCredits = target == .creditPack
        paywallStartsPaidImmediately = target == .subscription
        showPaywallSheet = true
    }

    // MARK: - Group icon: two figures side by side (geometric, line-drawn style)
    @ViewBuilder
    private func groupIconShape(filled: Bool) -> some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
        Canvas { context, size in
            // Person 1 (left)
            let p1HeadX: CGFloat = size.width * 0.33
            let p2HeadX: CGFloat = size.width * 0.67
            let headY: CGFloat   = size.height * 0.20
            let headR: CGFloat   = size.height * 0.13
            let bodyTopY: CGFloat = headY + headR + 1
            let bodyBotY: CGFloat = size.height * 0.72
            let bodyHalfW: CGFloat = size.height * 0.09
            let shoulderW: CGFloat = size.height * 0.15

            // Person 1 head
            let head1 = Path(ellipseIn: CGRect(
                x: p1HeadX - headR, y: headY - headR,
                width: headR * 2, height: headR * 2))
            // Person 1 body (trapezoid: shoulders taper to waist)
            var body1 = Path()
            body1.move(to: CGPoint(x: p1HeadX - shoulderW, y: bodyTopY))
            body1.addLine(to: CGPoint(x: p1HeadX + shoulderW, y: bodyTopY))
            body1.addLine(to: CGPoint(x: p1HeadX + bodyHalfW, y: bodyBotY))
            body1.addLine(to: CGPoint(x: p1HeadX - bodyHalfW, y: bodyBotY))
            body1.closeSubpath()

            // Person 2 head
            let head2 = Path(ellipseIn: CGRect(
                x: p2HeadX - headR, y: headY - headR,
                width: headR * 2, height: headR * 2))
            // Person 2 body
            var body2 = Path()
            body2.move(to: CGPoint(x: p2HeadX - shoulderW, y: bodyTopY))
            body2.addLine(to: CGPoint(x: p2HeadX + shoulderW, y: bodyTopY))
            body2.addLine(to: CGPoint(x: p2HeadX + bodyHalfW, y: bodyBotY))
            body2.addLine(to: CGPoint(x: p2HeadX - bodyHalfW, y: bodyBotY))
            body2.closeSubpath()

            // Connection line at the bottom (shared ground line)
            var ground = Path()
            ground.move(to: CGPoint(x: size.width * 0.12, y: bodyBotY))
            ground.addLine(to: CGPoint(x: size.width * 0.88, y: bodyBotY))

            let lineWidth: CGFloat = 1.5

            if filled {
                context.fill(head1, with: .color(ink))
                context.fill(body1, with: .color(ink))
                context.fill(head2, with: .color(ink))
                context.fill(body2, with: .color(ink))
                context.stroke(ground, with: .color(ink), lineWidth: lineWidth)
            } else {
                context.stroke(head1, with: .color(ink), lineWidth: lineWidth)
                context.stroke(body1, with: .color(ink), lineWidth: lineWidth)
                context.stroke(head2, with: .color(ink), lineWidth: lineWidth)
                context.stroke(body2, with: .color(ink), lineWidth: lineWidth)
                context.stroke(ground, with: .color(ink), lineWidth: lineWidth)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var headerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DUTCH")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .tracking(2)
                    Text("\(Date().formatted(date: .numeric, time: .omitted))")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.7))
                        .tracking(1)
                }
                Spacer()
                
                // Group mode button with people icon
                Button(action: {
                    HapticManager.impact(style: .light)
                    handleGroupIconTap()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.992, blue: 0.969))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        groupIconShape(filled: groupManager.isGroupModeEnabled)
                    }
                }
                .buttonStyle(ScaleButtonStyle())

                Button(action: {
                    HapticManager.impact(style: .light)
                    router.presentProfile()
                }) {
                    AvatarView(imageData: appState.profile.avatarImage,
                               initials: appState.profile.initials, size: 44)
                        .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                        .shadow(color: Color.primary.opacity(0.05), radius: 4, y: 2)
                }
                .buttonStyle(ScaleButtonStyle())
                .tutorialSpotlight(isHighlighted: shouldHighlightProfileButton, cornerRadius: 22)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 16)
            .background(Color(red: 1.0, green: 0.992, blue: 0.969))
            
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
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                    }
                )
                .padding(.horizontal, 20)
        }
    }
    
    private func handleSettleButtonTap() {
        guard authManager.canUseGroupMode else {
            showPhoneVerification = true
            return
        }

        if groupManager.isGroupModeEnabled {
            router.navigateToSettle()
        } else {
            let groups = groupManager.currentUserAvailableGroups
            if groups.isEmpty {
                router.navigateToSettle()
                
            } else if groups.count == 1 {
                let group = groups[0]
                groupManager.setActiveGroup(group)
                groupManager.enableGroupMode()
                groupManager.syncMembersToAppState(appState)
                router.navigateToSettle()
            } else {
                withAnimation(.spring(response: 0.3)) {
                    showGroupSelector = true
                }
            }
        }
    }
    
    private func handleGroupIconTap() {
        if !authManager.canUseGroupMode {
            showPhoneVerification = true
        } else {
            withAnimation(.spring(response: 0.3)) {
                showGroupSelector = true
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("UPLOAD SUMMARY")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.52))
                        .tracking(1.5)

                    Text(formatQuickCurrency(readyUploadTotal))
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(readyUploadItemCount) ITEM\(readyUploadItemCount == 1 ? "" : "S")")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .tracking(0.7)

                    Text(uploadReadinessText.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(canProceedFromUpload ? Color(red: 0.16, green: 0.38, blue: 0.16) : Color(red: 0.53, green: 0.24, blue: 0.08))
                        .tracking(0.6)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                uploadSummaryPill(label: "RECEIPTS", value: "\(appState.uploadedReceipts.count)")
                uploadSummaryPill(label: "STATEMENTS", value: "\(uploadedStatementCount)")
                uploadSummaryPill(label: "MANUAL", value: "\(appState.manualTransactions.count + readyManualDraftItems.count)")
            }

            if !pendingOfflineUploads.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))
                    Text("\(pendingOfflineUploads.count) upload\(pendingOfflineUploads.count == 1 ? "" : "s") waiting for internet")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.53, green: 0.24, blue: 0.08))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color(red: 1.0, green: 0.96, blue: 0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(red: 0.53, green: 0.24, blue: 0.08).opacity(0.22), lineWidth: 1)
                )
            }
        }
        .padding(16)
        .background(Color(red: 1.0, green: 0.992, blue: 0.969))
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.18), lineWidth: 1.5)
        )
    }

    private func uploadSummaryPill(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.52))
                .tracking(0.8)
            Text(value)
                .font(.system(size: 10, weight: .black))
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.12), lineWidth: 1)
        )
    }

    private var savedDraftsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                HapticManager.impact(style: .light)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    showSavedDrafts.toggle()
                }
            }) {
                HStack(spacing: 10) {
                    Text("SAVED DRAFTS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(1)

                    Text("\(draftSummaries.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                        .cornerRadius(2)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showSavedDrafts ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if showSavedDrafts {
                VStack(spacing: 8) {
                    ForEach(Array(draftSummaries.prefix(5))) { draft in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Button(action: {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        if expandedDraftIDs.contains(draft.id) {
                                            expandedDraftIDs.remove(draft.id)
                                        } else {
                                            expandedDraftIDs.insert(draft.id)
                                        }
                                    }
                                }) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                        .rotationEffect(.degrees(expandedDraftIDs.contains(draft.id) ? 90 : 0))
                                        .frame(width: 24, height: 24)
                                        .background(Color.white)
                                        .cornerRadius(2)
                                }
                                .buttonStyle(ScaleButtonStyle(scale: 0.94))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(draft.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                    Text("PREVIEW ITEMS")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.secondary)
                                        .tracking(0.8)
                                }

                                Spacer()

                                Button(action: {
                                    restoreUploadDraft(id: draft.id)
                                }) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                        .frame(width: 32, height: 32)
                                        .background(Color.white)
                                        .cornerRadius(2)
                                }
                                .buttonStyle(ScaleButtonStyle(scale: 0.94))

                                Button(action: {
                                    deleteUploadDraft(id: draft.id)
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.red.opacity(0.85))
                                        .frame(width: 32, height: 32)
                                        .background(Color.red.opacity(0.08))
                                        .cornerRadius(2)
                                }
                                .buttonStyle(ScaleButtonStyle(scale: 0.94))
                            }

                            if expandedDraftIDs.contains(draft.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(draft.itemPreview.enumerated()), id: \.offset) { _, item in
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.35))
                                                .frame(width: 4, height: 4)
                                            Text(item)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(Color(red: 0.22, green: 0.22, blue: 0.2))
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.leading, 36)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(12)
                        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color(red: 0.9, green: 0.9, blue: 0.88), lineWidth: 1)
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func saveDraftFromButton() {
        guard hasCurrentUploadWork else { return }
        saveUploadDraft(forceNewVersion: true)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showSavedDrafts = true
        }
        HapticManager.notification(type: .success)
    }

    // MARK: - Upload section
        // Receipt: camera OR gallery (confirmation dialog)
        // Statement: PDF import only
    @ViewBuilder
    private var uploadSectionCombined: some View {
        if isUploadAndManualMultiSpotlight {
            currentUploadControls
                .tutorialMultiSpotlight(target: .uploadSection, isActive: true)
        } else if hasCurrentUploadWork {
            currentUploadControls
        }
    }

    private var currentUploadControls: some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
        let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
        let paper = Color(red: 0.965, green: 0.958, blue: 0.935)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CURRENT UPLOAD")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(ink.opacity(0.48))
                    .tracking(1.2)
                Text("Review, save, or reset the items below")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ink.opacity(0.62))
            }

            Spacer(minLength: 8)

            Button(action: saveDraftFromButton) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ink)
                    .frame(width: 38, height: 38)
                    .background(paper)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ink.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.94))

            Button {
                HapticManager.impact(style: .light)
                showResetUploadAlert = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ink.opacity(0.64))
                    .frame(width: 38, height: 38)
                    .background(paper)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ink.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.94))
        }
        .padding(14)
        .background(ivory)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ink.opacity(0.14), lineWidth: 1.2)
        )
        .shadow(color: ink.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private func runScanAction(mode: ScanTutorialMode, action: @escaping () -> Void) {
        dismissManualKeyboard()

        guard canStartNetworkScan() else { return }

        // Hard gate — never open camera/picker when out of credits
        if trialManager.isOutOfIncludedOCRCredits {
            HapticManager.notification(type: .warning)
            openOutOfCreditsPaywall(preferredOutOfCreditsPaywallTarget)
            return
        }

        uploadTutorialMode = mode
        let shouldHide = mode == .receipt ? hideReceiptScanTutorial : hideStatementScanTutorial
        if shouldHide {
            action()
        } else {
            pendingAction = action
            showUploadTutorial = true
        }
    }
    
    // MARK: - Geometric icons matching the app style
    @ViewBuilder
    private func uploadButtonIcon(type: OCRService.DocumentType) -> some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

        if type == .receipt {
            // Camera body: a rectangle with a small lens circle
            ZStack {
                // Camera body
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink, lineWidth: 1.5)
                    .frame(width: 30, height: 22)
                // Viewfinder bump on top
                Rectangle()
                    .stroke(ink, lineWidth: 1.5)
                    .frame(width: 10, height: 5)
                    .offset(y: -13.5)
                // Lens circle
                Circle()
                    .stroke(ink, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                // Lens inner dot
                Circle()
                    .fill(ink)
                    .frame(width: 3, height: 3)
            }
            .frame(height: 40)
        } else {
            // Phone/gallery: a phone outline with a small image grid inside
            ZStack {
                // Phone body
                RoundedRectangle(cornerRadius: 3)
                    .stroke(ink, lineWidth: 1.5)
                    .frame(width: 22, height: 34)
                // Screen area lines (representing a screenshot)
                VStack(spacing: 3) {
                    Rectangle()
                        .fill(ink)
                        .frame(width: 13, height: 1.5)
                    Rectangle()
                        .fill(ink)
                        .frame(width: 11, height: 1.5)
                    Rectangle()
                        .fill(ink)
                        .frame(width: 13, height: 1.5)
                    Rectangle()
                        .fill(ink)
                        .frame(width: 9, height: 1.5)
                }
                // Home indicator at bottom
                Rectangle()
                    .fill(ink)
                    .frame(width: 8, height: 1.5)
                    .cornerRadius(1)
                    .offset(y: 14)
            }
            .frame(height: 40)
        }
    }

    private func uploadTypeButton(
        title: String,
        type: OCRService.DocumentType,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { HapticManager.impact(style: .medium); action() }) {
            VStack(spacing: 14) {
                uploadButtonIcon(type: type)
                
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 16)
            .background(Color.clear)
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .disabled(isProcessingImage)
        .opacity(isProcessingImage ? 0.6 : 1.0)
    }

    private var hasUploadedDocumentThumbnails: Bool {
        !appState.uploadedReceipts.isEmpty || !(appState.uploadedTransactions?.isEmpty ?? true)
    }

    private var uploadedDocumentThumbnailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RECEIPTS AND STATEMENTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(1.5)
                .padding(.horizontal, 4)

            if !appState.uploadedReceipts.isEmpty {
                receiptThumbnailGrid(showHeading: false)
            }

            if !(appState.uploadedTransactions?.isEmpty ?? true) {
                transactionThumbnailGrid(showHeading: false)
            }
        }
    }

    private var receiptThumbnailsSection: some View {
        receiptThumbnailGrid(showHeading: true)
    }

    private func receiptThumbnailGrid(showHeading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if showHeading {
                Text("RECEIPTS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(1.5)
                    .padding(.horizontal, 4)
            }

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: receiptThumbnailCellSize, maximum: receiptThumbnailCellSize),
                        spacing: 6,
                        alignment: .leading
                    )
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(appState.uploadedReceipts.enumerated()), id: \.element.id) { index, receipt in
                    receiptThumbnail(receipt: receipt, index: index)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func receiptThumbnail(receipt: UploadedReceipt, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Button(action: {
                HapticManager.impact(style: .light)
                selectedReceiptForViewing = receipt
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showReceiptViewer = true }
            }) {
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: receipt.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: receiptThumbnailImageSize, height: receiptThumbnailImageSize)
                        .background(Color(red: 0.91, green: 0.91, blue: 0.88))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    LinearGradient(
                        colors: [Color.black.opacity(0.02), Color.black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(formatQuickCurrency(receipt.total))
                            .font(.system(size: 17, weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text("\(receipt.lineItems.count) ITEM\(receipt.lineItems.count == 1 ? "" : "S")")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(.white.opacity(0.82))
                        Text(receiptDebugSummary(receipt))
                            .font(.system(size: 7, weight: .black))
                            .tracking(0.25)
                            .foregroundColor(.white.opacity(0.74))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(5)
                }
                .frame(width: receiptThumbnailImageSize, height: receiptThumbnailImageSize)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                )
                .padding(receiptThumbnailPadding)
                .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1)
                )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.96))

            Button(action: {
                HapticManager.notification(type: .warning)
                withAnimation(.spring(response: 0.3)) {
                    _ = appState.uploadedReceipts.remove(at: index)
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 34, height: 34, alignment: .topTrailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.9))
            .padding(.top, 2)
            .padding(.trailing, 2)
        }
    }

    private var transactionThumbnailsSection: some View {
        transactionThumbnailGrid(showHeading: true)
    }

    private func transactionThumbnailGrid(showHeading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showHeading {
                Text("STATEMENTS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(1.5)
                    .padding(.horizontal, 4)
            }

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: receiptThumbnailCellSize, maximum: receiptThumbnailCellSize),
                        spacing: 6,
                        alignment: .leading
                    )
                ],
                alignment: .leading,
                spacing: 8
            ) {
                if let statements = appState.uploadedTransactions {
                    ForEach(Array(statements.enumerated()), id: \.element.id) { index, transaction in
                        transactionThumbnail(transaction: transaction, index: index)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transactionThumbnail(transaction: UploadedTransaction, index: Int) -> some View {
        let total = statementSplitTotal(transaction)
        let hasPreviewImage = transaction.image.size.width > 0 && transaction.image.size.height > 0

        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button(action: {
                    HapticManager.impact(style: .light)
                    selectedTransactionForViewing = transaction
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showTransactionViewer = true }
                }) {
                    ZStack(alignment: .bottomLeading) {
                        if hasPreviewImage {
                            Image(uiImage: transaction.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: receiptThumbnailImageSize, height: receiptThumbnailImageSize)
                        } else {
                            ZStack {
                                Color(red: 0.91, green: 0.91, blue: 0.88)
                                Image(systemName: "doc.text")
                                    .font(.system(size: 34, weight: .semibold))
                                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                            }
                            .frame(width: receiptThumbnailImageSize, height: receiptThumbnailImageSize)
                        }

                        LinearGradient(
                            colors: [Color.black.opacity(0.02), Color.black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(formatQuickCurrency(total))
                                .font(.system(size: 17, weight: .black))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Text("\(transaction.items.count) ITEM\(transaction.items.count == 1 ? "" : "S")")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.5)
                                .foregroundColor(.white.opacity(0.82))
                            Text(transaction.sourceType == "pdf" ? "PDF" : "STATEMENT")
                                .font(.system(size: 7, weight: .black))
                                .tracking(0.45)
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                            Text(statementDebugSummary(transaction))
                                .font(.system(size: 7, weight: .black))
                                .tracking(0.25)
                                .foregroundColor(.white.opacity(0.74))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(5)
                    }
                    .frame(width: receiptThumbnailImageSize, height: receiptThumbnailImageSize)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                    )
                    .padding(receiptThumbnailPadding)
                    .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.96))

                Button(action: {
                    HapticManager.notification(type: .warning)
                    deleteTransaction(at: index)
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 28, height: 28)
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 34, height: 34, alignment: .topTrailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.9))
                .padding(.top, 2)
                .padding(.trailing, 2)
            }
        }
    }

    private func statementItemTotal(_ transaction: UploadedTransaction) -> Double {
        round2(transaction.items.reduce(0.0) { $0 + abs($1.amount) })
    }

    private func statementSplitTotal(_ transaction: UploadedTransaction) -> Double {
        if transaction.totalDebits > 0 {
            return round2(transaction.totalDebits)
        }
        return statementItemTotal(transaction)
    }

    private func receiptDebugSummary(_ receipt: UploadedReceipt) -> String {
        "\(receiptMethodLabel(receipt.processingMethod)) \(confidencePercent(receipt.ocrConfidence)) \(durationLabel(receipt.ocrProcessingTimeMs))"
    }

    private func statementDebugSummary(_ transaction: UploadedTransaction) -> String {
        "\(transaction.processingMethod.uppercased()) \(confidencePercent(transaction.confidence)) \(durationLabel(transaction.processingTimeMs))"
    }

    private func receiptMethodLabel(_ method: OCRService.ProcessingMethod) -> String {
        switch method {
        case .appleLocal: return "LOCAL"
        case .googleVision: return "VISION"
        case .tabscanner: return "TAB"
        case .gptAppleOCR: return "MISTRAL"
        case .paddleVL: return "PADDLE"
        }
    }

    private func confidencePercent(_ value: Float) -> String {
        "\(Int((max(0, min(value, 1)) * 100).rounded()))%"
    }

    private func durationLabel(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "--" }
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        let seconds = Double(milliseconds) / 1000.0
        return String(format: "%.1fs", seconds)
    }

    private var statementDateFilterSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Filter Statement")
                        .font(.system(size: 24, weight: .black))
                        .foregroundColor(Color(red: 0.12, green: 0.12, blue: 0.12))
                    Text("Show transactions from a date range.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    showStatementDateFilter = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(red: 0.12, green: 0.12, blue: 0.12))
                        .frame(width: 38, height: 38)
                        .background(Color(red: 0.93, green: 0.93, blue: 0.90))
                        .clipShape(Circle())
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.92))
            }

            VStack(alignment: .leading, spacing: 12) {
                DatePicker(
                    "From",
                    selection: $statementFilterStartDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.compact)
                .font(.system(size: 15, weight: .bold))

                DatePicker(
                    "To",
                    selection: $statementFilterEndDate,
                    in: statementFilterStartDate...,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.compact)
                .font(.system(size: 15, weight: .bold))
            }
            .padding(14)
            .background(Color(red: 0.96, green: 0.96, blue: 0.94))
            .cornerRadius(3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.16), lineWidth: 1)
            )

            if let index = statementDateFilterIndex,
               let statements = appState.uploadedTransactions,
               statements.indices.contains(index),
               let filterLabel = statements[index].dateFilterLabel {
                Text("Currently showing \(statements[index].items.count) of \(statements[index].allItems.count) rows for \(filterLabel).")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 10) {
                Button {
                    applyStatementDateFilter()
                } label: {
                    Text("APPLY DATE RANGE")
                        .font(.system(size: 14, weight: .black))
                        .tracking(1.1)
                        .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(red: 0.13, green: 0.13, blue: 0.13))
                        .cornerRadius(3)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.97))

                Button {
                    clearStatementDateFilter()
                } label: {
                    Text("CLEAR FILTER")
                        .font(.system(size: 14, weight: .black))
                        .tracking(1.1)
                        .foregroundColor(Color(red: 0.13, green: 0.13, blue: 0.13))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color(red: 0.13, green: 0.13, blue: 0.13).opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.97))
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .background(Color(red: 1.0, green: 0.992, blue: 0.969))
        .onChange(of: statementFilterStartDate) { _, newStartDate in
            if statementFilterEndDate < newStartDate {
                statementFilterEndDate = newStartDate
            }
        }
    }

    private func presentStatementDateFilter(for index: Int) {
        guard let statements = appState.uploadedTransactions,
              statements.indices.contains(index) else { return }
        let statement = statements[index]
        statementDateFilterIndex = index
        if let label = statement.dateFilterLabel,
           let range = parseStatementDateRangeLabel(label) {
            statementFilterStartDate = range.start
            statementFilterEndDate = range.end
        } else if let range = statementAvailableDateRange(for: statement) {
            statementFilterStartDate = range.start
            statementFilterEndDate = range.end
        } else {
            statementFilterStartDate = Date()
            statementFilterEndDate = Date()
        }
        showStatementDateFilter = true
    }

    private func applyStatementDateFilter() {
        guard let index = statementDateFilterIndex,
              var statements = appState.uploadedTransactions,
              statements.indices.contains(index) else { return }

        var statement = statements[index]
        let startDate = min(statementFilterStartDate, statementFilterEndDate)
        let endDate = max(statementFilterStartDate, statementFilterEndDate)
        let sourceItems = statement.allItems.isEmpty ? statement.items : statement.allItems
        let filteredItems = sourceItems.filter {
            statementItem($0, isBetween: startDate, and: endDate)
        }

        guard !filteredItems.isEmpty else {
            showStatementDateFilter = false
            showDuplicateUploadNotice(
                title: "No Transactions Found",
                message: "This statement does not have parsed transactions from \(statementDateDisplayString(startDate)) to \(statementDateDisplayString(endDate))."
            )
            return
        }

        statement.items = filteredItems
        statement.allItems = sourceItems
        statement.totalDebits = round2(filteredItems.filter(\.isDebit).reduce(0.0) { $0 + abs($1.amount) })
        statement.totalCredits = round2(filteredItems.filter { !$0.isDebit }.reduce(0.0) { $0 + abs($1.amount) })
        statement.dateFilterLabel = statementDateRangeDisplayString(startDate: startDate, endDate: endDate)
        statements[index] = statement
        appState.uploadedTransactions = statements
        selectedTransactionForViewing = statement
        showStatementDateFilter = false
    }

    private func clearStatementDateFilter() {
        guard let index = statementDateFilterIndex,
              var statements = appState.uploadedTransactions,
              statements.indices.contains(index) else { return }

        var statement = statements[index]
        let sourceItems = statement.allItems.isEmpty ? statement.items : statement.allItems
        statement.items = sourceItems
        statement.allItems = sourceItems
        statement.totalDebits = round2(sourceItems.filter(\.isDebit).reduce(0.0) { $0 + abs($1.amount) })
        statement.totalCredits = round2(sourceItems.filter { !$0.isDebit }.reduce(0.0) { $0 + abs($1.amount) })
        statement.dateFilterLabel = nil
        statements[index] = statement
        appState.uploadedTransactions = statements
        selectedTransactionForViewing = statement
        showStatementDateFilter = false
    }

    private func statementItem(_ item: ReceiptTransactionItem, isBetween startDate: Date, and endDate: Date) -> Bool {
        guard let rawDate = item.date?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDate.isEmpty else { return false }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)

        if let parsedDate = parseStatementItemDate(rawDate, rangeStart: start, rangeEnd: end) {
            let parsedDay = calendar.startOfDay(for: parsedDate)
            return parsedDay >= start && parsedDay <= end
        }

        return false
    }

    private func statementAvailableDateRange(for statement: UploadedTransaction) -> (start: Date, end: Date)? {
        let sourceItems = statement.allItems.isEmpty ? statement.items : statement.allItems
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())

        let parsedDates = sourceItems.compactMap { item -> Date? in
            guard let rawDate = item.date?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawDate.isEmpty else { return nil }

            if let fullDate = parseStatementDateWithYear(rawDate) {
                return calendar.startOfDay(for: fullDate)
            }

            if let monthDay = parseStatementMonthDay(rawDate),
               let month = monthDay.month,
               let day = monthDay.day,
               let inferredDate = calendar.date(from: DateComponents(year: currentYear, month: month, day: day)) {
                return calendar.startOfDay(for: inferredDate)
            }

            return nil
        }

        guard let start = parsedDates.min(), let end = parsedDates.max() else { return nil }
        return (start, end)
    }

    private func parseStatementItemDate(_ rawDate: String, rangeStart: Date, rangeEnd: Date) -> Date? {
        let calendar = Calendar.current

        if let fullDate = parseStatementDateWithYear(rawDate) {
            return fullDate
        }

        guard let monthDay = parseStatementMonthDay(rawDate),
              let month = monthDay.month,
              let day = monthDay.day else {
            return nil
        }

        let startYear = calendar.component(.year, from: rangeStart)
        let endYear = calendar.component(.year, from: rangeEnd)
        let candidateYears = Array((startYear - 1)...(endYear + 1))
        let candidates = candidateYears.compactMap {
            calendar.date(from: DateComponents(year: $0, month: month, day: day))
        }

        if let inRange = candidates.first(where: {
            let normalized = calendar.startOfDay(for: $0)
            return normalized >= rangeStart && normalized <= rangeEnd
        }) {
            return inRange
        }

        return candidates.min {
            abs($0.timeIntervalSince(rangeStart)) < abs($1.timeIntervalSince(rangeStart))
        }
    }

    private func parseStatementDateWithYear(_ rawDate: String) -> Date? {
        let cleaned = normalizedStatementDateString(rawDate)
        let formats = [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyy.MM.dd",
            "MM/dd/yyyy",
            "M/d/yyyy",
            "MM-dd-yyyy",
            "M-d-yyyy",
            "MM.dd.yyyy",
            "M.d.yyyy",
            "MM/dd/yy",
            "M/d/yy",
            "MM-dd-yy",
            "M-d-yy",
            "MM.dd.yy",
            "M.d.yy",
            "MMM d yyyy",
            "MMMM d yyyy",
            "d MMM yyyy",
            "d MMMM yyyy"
        ]
        return formats.compactMap { statementDateFormatter(format: $0).date(from: cleaned) }.first
    }

    private func normalizedStatementDateString(_ rawDate: String) -> String {
        rawDate.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: #"(?i)\b(\d{1,2})(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseStatementMonthDay(_ rawDate: String) -> DateComponents? {
        let cleaned = normalizedStatementDateString(rawDate)
        let formats = ["MM/dd", "M/d", "MM-dd", "M-d", "MM.dd", "M.d", "MMM d", "MMMM d", "d MMM", "d MMMM"]
        for format in formats {
            if let date = statementDateFormatter(format: format).date(from: cleaned) {
                return Calendar.current.dateComponents([.month, .day], from: date)
            }
        }
        return nil
    }

    private func parseStatementDateRangeLabel(_ label: String) -> (start: Date, end: Date)? {
        let parts = label.components(separatedBy: " - ")
        guard parts.count == 2,
              let start = statementDateDisplayFormatter.date(from: parts[0]),
              let end = statementDateDisplayFormatter.date(from: parts[1]) else {
            if let single = statementDateDisplayFormatter.date(from: label) {
                return (single, single)
            }
            return nil
        }
        return (start, end)
    }

    private func statementDateDisplayString(_ date: Date) -> String {
        statementDateDisplayFormatter.string(from: date)
    }

    private func statementDateRangeDisplayString(startDate: Date, endDate: Date) -> String {
        let start = statementDateDisplayString(startDate)
        let end = statementDateDisplayString(endDate)
        return start == end ? start : "\(start) - \(end)"
    }

    private func statementDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private var statementDateDisplayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private func fullScreenReceiptViewer(receipt: UploadedReceipt) -> some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showReceiptViewer = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedReceiptForViewing = nil }
                }
            VStack(spacing: 20) {
                Spacer()
                Image(uiImage: receipt.image).resizable().aspectRatio(contentMode: .fit)
                    .cornerRadius(16).shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
                    .padding(.horizontal, 20)
                Spacer()
            }
            VStack {
                Spacer()
                ocrDebugPanel(
                    title: "RECEIPT OCR",
                    rows: [
                        ("Method", receiptMethodLabel(receipt.processingMethod)),
                        ("Confidence", confidencePercent(receipt.ocrConfidence)),
                        ("Runtime", durationLabel(receipt.ocrProcessingTimeMs)),
                        ("Route", receipt.ocrRoute ?? receiptMethodLabel(receipt.processingMethod)),
                        ("Detail", receipt.ocrFallbackReason ?? receipt.ocrValidationStatus.rawValue)
                    ]
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        HapticManager.impact(style: .light)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showReceiptViewer = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedReceiptForViewing = nil }
                    }) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.15)).frame(width: 44, height: 44)
                                .background(Circle().fill(.ultraThinMaterial))
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle()).padding(20)
                }
                Spacer()
            }
        }
    }

    private func fullScreenTransactionViewer(transaction: UploadedTransaction) -> some View {
        let total = statementSplitTotal(transaction)
        return ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("STATEMENT BREAKDOWN")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.8)
                        .foregroundColor(Color.white.opacity(0.55))
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(transaction.items.count) items")
                            .font(.system(size: 28, weight: .black))
                            .foregroundColor(.white)
                        Spacer()
                        Text(formatQuickCurrency(total))
                            .font(.system(size: 28, weight: .black))
                            .foregroundColor(.white)
                    }
                    Text("Review the extracted transaction rows before splitting.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.64))
                    if let filterLabel = transaction.dateFilterLabel {
                        Text("Filtered to \(filterLabel)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(red: 0.74, green: 0.93, blue: 0.70))
                    }
                    ocrDebugPanel(
                        title: "STATEMENT OCR",
                        rows: [
                            ("Method", transaction.processingMethod.uppercased()),
                            ("Confidence", confidencePercent(transaction.confidence)),
                            ("Runtime", durationLabel(transaction.processingTimeMs)),
                            ("Source", transaction.sourceType.uppercased()),
                            ("Detail", transaction.confidenceReason ?? "Mistral structured statement parse")
                        ]
                    )
                    if let index = appState.uploadedTransactions?.firstIndex(where: { $0.id == transaction.id }) {
                        Button {
                            HapticManager.impact(style: .light)
                            presentStatementDateFilter(for: index)
                        } label: {
                            Text("FILTER BY DATE")
                                .font(.system(size: 11, weight: .black))
                                .tracking(1.1)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                )
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.94))
                    }
                }
                .padding(.top, 74)
                .padding(.horizontal, 20)

                ScrollView(showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(Array(transaction.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.description.isEmpty ? "Transaction" : item.description)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(3)
                                    if let date = item.date, !date.isEmpty {
                                        Text(date)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(Color.white.opacity(0.45))
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(formatQuickCurrency(abs(item.amount)))
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundColor(.white)
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)

                            Divider()
                                .background(Color.white.opacity(0.16))
                                .padding(.horizontal, 16)
                        }
                    }
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        HapticManager.impact(style: .light)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showTransactionViewer = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { selectedTransactionForViewing = nil }
                    }) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.15)).frame(width: 44, height: 44)
                                .background(Circle().fill(.ultraThinMaterial))
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle()).padding(20)
                }
                Spacer()
            }
        }
    }

    private func ocrDebugPanel(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .tracking(1.2)
                .foregroundColor(Color.white.opacity(0.62))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    Text(row.0)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.50))
                        .frame(width: 72, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.58))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func validateAndAddItems() {
        incompleteManualItemIDs = []
        for item in manualItems {
            guard hasManualItemContent(item), !isManualItemReady(item) else { continue }
            if !incompleteManualItemIDs.contains(item.id) {
                incompleteManualItemIDs.append(item.id)
            }
        }

        if !incompleteManualItemIDs.isEmpty {
            showIncompleteItemAlert = true
            return
        }
        addCompleteItems()
    }

    private func addCompleteItems() {
        commitReadyManualItems()
    }

    private func commitReadyManualItems() {
        let readyItems = manualItems.filter(isManualItemReady)
        guard !readyItems.isEmpty else {
            HapticManager.notification(type: .warning)
            return
        }

        let baseIndex = appState.manualTransactions.count + 1
        for (offset, item) in readyItems.enumerated() {
            guard let amount = manualAmountValue(item.amount), amount > 0 else { continue }
            let trimmedName = item.name.trimmingCharacters(in: .whitespaces)
            let finalName = trimmedName.isEmpty ? "Item \(baseIndex + offset)" : trimmedName

            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                appState.manualTransactions.append((name: finalName, amount: amount))
            }
        }
        playCartAddAnimation(for: .manualEntry)

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            manualItems.removeAll { readyItems.map(\.id).contains($0.id) }
            if showManualEntry && manualItems.isEmpty {
                manualItems.append(UploadManualDraftItem())
            }
            incompleteManualItemIDs.removeAll()
        }

        HapticManager.notification(type: .success)
    }

    private func deleteIncompleteItems() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            manualItems.removeAll { incompleteManualItemIDs.contains($0.id) }
            incompleteManualItemIDs.removeAll()
        }
        
        // Now add the complete items to preview list
        addCompleteItems()
    }

    private func sanitizedManualAmountInput(_ value: String) -> String {
        let allowed = value.filter { $0.isNumber || $0 == "." }
        var result = ""
        var hasDecimal = false
        var decimalCount = 0

        for character in allowed {
            if character == "." {
                guard !hasDecimal else { continue }
                hasDecimal = true
                result.append(character)
                continue
            }
            if hasDecimal {
                guard decimalCount < 2 else { continue }
                decimalCount += 1
            }
            result.append(character)
        }

        return result
    }

    private func manualAmountValue(_ amount: String) -> Double? {
        Double(amount.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func hasManualItemContent(_ item: UploadManualDraftItem) -> Bool {
        !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !item.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isManualItemReady(_ item: UploadManualDraftItem) -> Bool {
        guard hasManualItemContent(item), let amount = manualAmountValue(item.amount) else { return false }
        return amount > 0
    }

    private func manualItemAttentionText(_ item: UploadManualDraftItem) -> String {
        if item.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add an amount or remove this row."
        }
        return "Use a valid amount greater than $0."
    }

    private func removeManualDraftItem(_ itemID: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if manualItems.count == 1 {
                manualItems[0] = UploadManualDraftItem()
            } else {
                manualItems.removeAll { $0.id == itemID }
            }
            incompleteManualItemIDs.removeAll { $0 == itemID }
        }
    }

    private var readyManualDraftItems: [UploadManualDraftItem] {
        manualItems.filter(isManualItemReady)
    }

    private var manualDraftTotal: Double {
        readyManualDraftItems.reduce(0.0) { total, item in
            total + (manualAmountValue(item.amount) ?? 0)
        }
    }

    private var manualAddedTotal: Double {
        appState.manualTransactions.reduce(0.0) { $0 + $1.amount }
    }

    private var manualGrandTotal: Double {
        manualDraftTotal + manualAddedTotal
    }

    private var manualSaveButtonTitle: String {
        let readyCount = readyManualDraftItems.count
        guard readyCount > 0 else { return "ADD AMOUNT TO SAVE" }
        let itemWord = readyCount == 1 ? "ITEM" : "ITEMS"
        return "SAVE \(readyCount) \(itemWord) TO CART · \(formatQuickCurrency(manualDraftTotal))"
    }
  
    
    private var manualEntrySection: some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
        let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)

        return VStack(alignment: .leading, spacing: 16) {
            if selectedCaptureMode == .manualEntry {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MANUAL ENTRY")
                        .font(.system(size: 10, weight: .black))
                        .tracking(1.8)
                        .foregroundColor(.secondary)
                    Text("Add items")
                        .font(.system(size: 24, weight: .black))
                        .foregroundColor(ink)
                    Text("Type items that were not scanned. Save them to the cart when ready.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(ink.opacity(0.56))
                }
            } else {
                manualEntryToggle
            }

            if showManualEntry || selectedCaptureMode == .manualEntry {
                VStack(spacing: 10) {
                    ForEach(manualItems) { item in
                        manualItemRow(itemID: item.id)
                    }

                    HStack(spacing: 10) {
                        Button {
                            HapticManager.impact(style: .light)
                            appendManualDraft(forceNew: true)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .bold))
                                Text("ADD ROW")
                                    .font(.system(size: 13, weight: .semibold))
                                    .tracking(0.5)
                            }
                            .foregroundColor(ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ivory)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink, lineWidth: 1.5))
                        }
                        .frame(width: 120)
                        .buttonStyle(ScaleButtonStyle(scale: 0.97))

                        Button {
                            HapticManager.impact(style: .medium)
                            validateAndAddItems()
                        } label: {
                            Text(manualSaveButtonTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .tracking(0.5)
                                .foregroundColor(ivory)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.68)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 48)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .background(readyManualDraftItems.isEmpty ? ink.opacity(0.35) : ink)
                                .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.97))
                        .disabled(readyManualDraftItems.isEmpty)
                    }

                    if !appState.manualTransactions.isEmpty {
                        addedItemsList
                    }
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95, anchor: .top).combined(with: .opacity),
                    removal: .scale(scale: 0.95, anchor: .top).combined(with: .opacity)
                ))
            }
        }
        .id("manual-entry-scroll-anchor")
        .tutorialMultiSpotlight(target: .manualEntry, isActive: isUploadAndManualMultiSpotlight)
        .alert("Check Manual Entry", isPresented: $showIncompleteItemAlert) {
            Button("Remove unfinished rows", role: .destructive) {
                deleteIncompleteItems()
            }
            Button("Keep Editing") { }
        } message: {
            Text("Every manual item needs a valid amount. Names are optional.")
        }
    }

    private func appendManualDraft(named name: String = "", forceNew: Bool = false, autoFocus: Bool = true) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let emptyIndex = forceNew ? nil : manualItems.firstIndex { !hasManualItemContent($0) }
        var itemID = UUID()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if let emptyIndex {
                manualItems[emptyIndex].name = cleanName
                itemID = manualItems[emptyIndex].id
            } else {
                let item = UploadManualDraftItem(name: cleanName)
                itemID = item.id
                manualItems.append(item)
            }
        }

        if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                focusedManualField = cleanName.isEmpty ? .name(itemID) : .amount(itemID)
            }
        }
    }

    private func ensureTrailingManualDraft(after itemID: UUID) {
        guard let index = manualItems.firstIndex(where: { $0.id == itemID }) else { return }
        guard index == manualItems.indices.last else { return }
        guard let amount = manualAmountValue(manualItems[index].amount), amount > 0 else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            manualItems.append(UploadManualDraftItem())
        }
    }
    
    private var visibleManualDraftItems: [UploadManualDraftItem] {
        manualItems.filter { item in
            !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !item.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var collapsedManualEntrySummary: String? {
        let draftCount = visibleManualDraftItems.count
        let addedCount = appState.manualTransactions.count
        let itemCount = draftCount + addedCount

        guard itemCount > 0 else { return nil }

        let draftTotal = visibleManualDraftItems.reduce(0.0) { total, item in
            total + (Double(item.amount.replacingOccurrences(of: "$", with: "")) ?? 0)
        }
        let addedTotal = appState.manualTransactions.reduce(0.0) { $0 + $1.amount }
        let total = draftTotal + addedTotal
        let itemText = "\(itemCount) item\(itemCount == 1 ? "" : "s")"

        if total > 0 {
            return "\(itemText) • \(String(format: "$%.2f", total))"
        }
        return itemText
    }

    private var manualEntryToggle: some View {
        Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showManualEntry.toggle()
                if showManualEntry && manualItems.isEmpty {
                    manualItems.append(UploadManualDraftItem())
                }
            }
            if showManualEntry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    focusedManualField = manualItems.first.map { .name($0.id) }
                }
            }
        }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MANUAL ENTRY")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .tracking(0.5)
                    Text(showManualEntry ? "Add item names and amounts" : (collapsedManualEntrySummary ?? "Add items without scanning"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.52))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                
                Spacer()

                if manualGrandTotal > 0 {
                    Text(formatQuickCurrency(manualGrandTotal))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.08))
                        .cornerRadius(2)
                }
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .rotationEffect(.degrees(showManualEntry ? 180 : 0))
            }
            .padding(16)
            .background(Color.clear)
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .tutorialMultiSpotlight(target: .manualEntry, isActive: isUploadAndManualMultiSpotlight)
    }

    private var addNewItemCard: some View {
        VStack(spacing: 16) {
            // Fields row
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ITEM NAME")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(1)
                    
                    ZStack(alignment: .leading) {
                        // Semi-transparent suggestion
                        if manualItemName.isEmpty && showingSuggestion {
                            Text(suggestedItemName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.4))
                                .padding(.leading, 14)
                        }
                        
                        TextField("e.g., Dinner, Coffee", text: $manualItemName)
                            .font(.system(size: 15, weight: .medium))
                            .padding(14)
                            .background(Color.white)
                            .cornerRadius(2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color(red: 0.8, green: 0.8, blue: 0.8), lineWidth: 1)
                            )
                            .focused($focusedManualField, equals: .legacyName)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedManualField = .legacyAmount
                            }
                            .onChange(of: manualItemName) { _, newValue in
                                if !newValue.isEmpty {
                                    showingSuggestion = false
                                }
                            }
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("AMOUNT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(1)
                    
                    HStack(spacing: 8) {
                        Text("$")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        ZStack(alignment: .leading) {
                            // Semi-transparent suggestion
                            if manualItemAmount.isEmpty && showingSuggestion {
                                Text(suggestedItemAmount)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                            
                            TextField("0.00", text: $manualItemAmount)
                                .font(.system(size: 15, weight: .medium))
                                .keyboardType(.decimalPad)
                                .focused($focusedManualField, equals: .legacyAmount)
                                .onChange(of: manualItemAmount) { _, newValue in
                                    if !newValue.isEmpty {
                                        showingSuggestion = false
                                    }
                                }
                        }
                    }
                    .padding(14)
                    .background(Color.white)
                    .cornerRadius(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(red: 0.8, green: 0.8, blue: 0.8), lineWidth: 1)
                    )
                }
                .frame(width: 100)
            }
            
            // ADD button
            Button(action: {
                HapticManager.notification(type: .success)
                addManualItemWithSuggestion()
            }) {
                HStack(spacing: 8) {
                    ZStack {
                        Rectangle()
                            .fill(Color(red: 1.0, green: 0.992, blue: 0.969))
                            .frame(width: 12, height: 2)
                        Rectangle()
                            .fill(Color(red: 1.0, green: 0.992, blue: 0.969))
                            .frame(width: 2, height: 12)
                    }
                    Text("ADD ITEM")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1)
                        .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    canAddItemWithSuggestion
                        ? Color(red: 0.15, green: 0.15, blue: 0.15)
                        : Color(red: 0.6, green: 0.6, blue: 0.58)
                )
                .cornerRadius(2)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.97))
            .disabled(!canAddItemWithSuggestion)
            .animation(.easeInOut(duration: 0.15), value: canAddItemWithSuggestion)
        }
        .padding(20)
        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
        )
        .onAppear {
            if manualItemName.isEmpty && manualItemAmount.isEmpty {
                generateSuggestion()
            }
        }
    }
    
    private var canAddItemWithSuggestion: Bool {
        // Can add if user typed something OR if suggestion is showing
        if showingSuggestion {
            return true  // Suggestion is valid
        }
        return !manualItemName.trimmingCharacters(in: .whitespaces).isEmpty &&
               Double(manualItemAmount) ?? 0 > 0
    }

    private func addManualItemWithSuggestion() {
        // If user didn't type anything, use the suggestion
        let finalName: String
        let finalAmount: String
        
        if manualItemName.isEmpty && showingSuggestion {
            finalName = suggestedItemName
        } else {
            finalName = manualItemName
        }
        
        if manualItemAmount.isEmpty && showingSuggestion {
            finalAmount = suggestedItemAmount
        } else {
            finalAmount = manualItemAmount
        }
        
        guard !finalName.trimmingCharacters(in: .whitespaces).isEmpty,
              let amount = Double(finalAmount), amount > 0 else { return }
        
        let trimmedName = finalName.trimmingCharacters(in: .whitespaces)
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.manualTransactions.append((name: trimmedName, amount: amount))
        }
        
        // Clear fields and generate new suggestion
        manualItemName = ""
        manualItemAmount = ""
        showingSuggestion = false
        // Generate new suggestion for next item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            generateSuggestion()
        }
        
        HapticManager.notification(type: .success)
    }
    
    private var addedItemsList: some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
        return VStack(alignment: .leading, spacing: 8) {
            Text("ADDED")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(ink.opacity(0.4))
                .tracking(1.2)
                .padding(.horizontal, 2)
                .padding(.top, 4)

            VStack(spacing: 6) {
                ForEach(Array(appState.manualTransactions.enumerated()), id: \.offset) { index, item in
                    addedItemRow(item: item, index: index)
                }
            }
        }
    }

    private func addedItemRow(item: (name: String, amount: Double), index: Int) -> some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
        return HStack(spacing: 0) {
            Text(item.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(ink.opacity(0.10))
                .frame(width: 1)
                .padding(.vertical, 8)

            Text(String(format: "$%.2f", item.amount))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ink)
                .padding(.horizontal, 14)
                .frame(width: 90, alignment: .trailing)

            Rectangle()
                .fill(ink.opacity(0.10))
                .frame(width: 1)
                .padding(.vertical, 8)

            Button(action: { HapticManager.impact(style: .light); deleteManualTransaction(at: index) }) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(ink.opacity(0.35))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.9))
        }
        .background(Color(red: 0.95, green: 0.94, blue: 0.91))
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var accountTypePrompt: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "creditcard.fill").font(.system(size: 48)).foregroundColor(.primary.opacity(0.7))
                    Text("What type of account is this?")
                        .font(.system(size: 22, weight: .bold)).foregroundColor(.primary).multilineTextAlignment(.center)
                    Text("This helps us correctly identify\nyour spending transactions")
                        .font(.system(size: 15, weight: .medium)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                VStack(spacing: 12) {
                    accountTypeButton(title: "Credit Card", description: "Purchases increase balance",
                                      icon: "creditcard.fill",  accountType: .creditCard)
                    accountTypeButton(title: "Debit Card",   description: "Purchases decrease balance",
                                      icon: "banknote.fill",    accountType: .debitCard)
                }
                Button(action: {
                    HapticManager.impact(style: .light)
                    withAnimation(.spring(response: 0.3)) { showAccountTypePrompt = false; isProcessingImage = false }
                }) {
                    Text("Cancel").font(.system(size: 16, weight: .semibold)).foregroundColor(.secondary).padding(.top, 8)
                }
            }
            .padding(32)
            .background(RoundedRectangle(cornerRadius: 24)
                .fill(Color(.systemBackground))
                .shadow(color: Color.primary.opacity(0.2), radius: 20, y: 10))
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    private func accountTypeButton(
        title: String, description: String, icon: String, accountType: ReceiptAccountType
    ) -> some View {
        Button(action: { HapticManager.impact(style: .medium); handleAccountTypeSelection(accountType) }) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08)).frame(width: 56, height: 56)
                    Image(systemName: icon).font(.system(size: 24)).foregroundColor(.primary.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
                    Text(description).font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.1), lineWidth: 2)))
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.97))
    }

    private var bottomCTA: some View {
        VStack(spacing: 0) {
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
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                    }
                )
                .padding(.horizontal, 20)
            
            VStack(spacing: 8) {
                if !canProceedFromUpload || incompleteManualDraftCount > 0 || hasPendingLowQualityScanWarning {
                    Text(uploadReadinessText.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.48))
                        .tracking(1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }

                Button(action: {
                    HapticManager.impact(style: .medium)
                    proceedFromUpload()
                }) {
                    HStack(spacing: 8) {
                        Text(uploadCTAButtonTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(1)
                        if canProceedFromUpload {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .foregroundColor(canProceedFromUpload ? .white : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.30))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(canProceedFromUpload ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.08))
                    .cornerRadius(3)
                }
                .disabled(!canProceedFromUpload)
                .buttonStyle(ScaleButtonStyle())
                .tutorialSpotlight(isHighlighted: shouldHighlightNextButton, cornerRadius: 3)
                .padding(.horizontal, 20)
                .padding(.top, (!canProceedFromUpload || incompleteManualDraftCount > 0 || hasPendingLowQualityScanWarning) ? 4 : 16)
                .padding(.bottom, 20)
            }
            .background(Color(red: 1.0, green: 0.992, blue: 0.969))
        }
    }

    private func proceedFromUpload() {
        guard canProceedFromUpload else {
            HapticManager.notification(type: .warning)
            return
        }

        incompleteManualItemIDs = manualItems
            .filter { hasManualItemContent($0) && !isManualItemReady($0) }
            .map(\.id)

        if !incompleteManualItemIDs.isEmpty {
            showManualEntry = true
            showIncompleteItemAlert = true
            return
        }

        if hasPendingLowQualityScanWarning,
           !userWillHandleLowQualityScan,
           !confirmedLowQualityReviewProceed {
            showLowQualityProceedAlert = true
            return
        }

        if !readyManualDraftItems.isEmpty {
            commitReadyManualItems()
        }

        if shouldProceedToGroupReview {
            appState.forcePersonalSplitForCurrentUpload = false
            prepareGroupReviewNavigation()
            convertToTransactions()
            router.navigateToReview()
        } else {
            appState.forcePersonalSplitForCurrentUpload = true
            router.navigateToPeople()
        }
    }
    
    private func convertToTransactions() {
        if appState.preserveReviewTransactionsOnNextReview && !appState.transactions.isEmpty {
            appState.preserveReviewTransactionsOnNextReview = false
            print("=== Reusing preserved Review transactions: \(appState.transactions.count) ===")
            return
        }

        appState.transactions.removeAll()
        
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
                       ?? Person(name: appState.profile.name, isCurrentUser: true)
        
        let splitWithPeople: [Person]
        if isGroupModeActiveForUploadReview {
            groupManager.syncMembersToAppState(appState)
            splitWithPeople = appState.people
            
            if !splitWithPeople.contains(where: { $0.isCurrentUser }) {
                print("WARNING: No current user after sync!")
            }
        } else {
            splitWithPeople = appState.people
        }
        
        print("\n=== convertToTransactions DEBUG ===")
        print("Split with people:")
        for person in splitWithPeople {
            print("  \(person.name) - isCurrentUser: \(person.isCurrentUser)")
        }
        
        for receipt in appState.uploadedReceipts {
            let transaction = Transaction(
                amount: receipt.total,
                merchant: receipt.merchant.isEmpty ? "Receipt" : receipt.merchant,
                paidBy: currentUser,
                splitWith: splitWithPeople,
                receiptImage: receipt.bestImageData,
                includeInSplit: true,
                isManual: false,
                backgroundResultToken: receipt.backgroundResultToken,
                lineItems: receipt.lineItems,
                sourceDocumentType: .receipt
            )
            appState.transactions.append(transaction)
        }
        
        for manualEntry in appState.manualTransactions {
            let transaction = Transaction(
                amount: manualEntry.amount,
                merchant: manualEntry.name,
                paidBy: currentUser,
                splitWith: splitWithPeople,
                receiptImage: nil,
                includeInSplit: true,
                isManual: true,
                lineItems: [],
                sourceDocumentType: .manual
            )
            appState.transactions.append(transaction)
        }
        
        if let uploadedTransactions = appState.uploadedTransactions {
            for statement in uploadedTransactions {
                let total = statementSplitTotal(statement)
                guard total > 0 else { continue }

                let transaction = Transaction(
                    amount: total,
                    merchant: "Statement",
                    paidBy: currentUser,
                    splitWith: splitWithPeople,
                    receiptImage: nil,
                    includeInSplit: true,
                    isManual: false,
                    lineItems: statementBreakdownLineItems(from: statement),
                    currency: "USD",
                    sourceDocumentType: .statement
                )
                appState.transactions.append(transaction)
            }
        }
        
        print("=== Converted Transactions for Group Mode ===")
        print("Group: \(groupManager.activeGroup?.name ?? "none")")
        print("Total transactions: \(appState.transactions.count)")
        print("  - From receipts: \(appState.uploadedReceipts.count)")
        print("  - From manual: \(appState.manualTransactions.count)")
        print("  - From statements: \(appState.uploadedTransactions?.count ?? 0)")
        print("===\n")
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
    

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button(action: { HapticManager.impact(style: .light); cancelProcessing() }) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.15)).frame(width: 32, height: 32)
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.9))
                }
                if isLowQualityGPTMode {
                    VStack(spacing: 16) {
                        SpinningCoinView().frame(width: 56, height: 56)
                        Text(processingMessage)
                            .font(.system(size: 17, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center)
                        if let subtitle = processingSubtitle {
                            Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.75))
                                .multilineTextAlignment(.center).lineSpacing(4)
                        }
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        Text(processingMessage)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        if let subtitle = processingSubtitle {
                            Text(subtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                
                if batchTotal > 1 {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(batchDone), total: Double(max(batchTotal, 1)))
                            .progressViewStyle(LinearProgressViewStyle(tint: Color.green))
                        Text("\(batchDone) of \(batchTotal) processed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 32)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black.opacity(0.88))
                    .environment(\.colorScheme, .dark)
            )
            .padding(.horizontal, 40)
        }
    }

    private var canAddItem: Bool {
        !manualItemName.trimmingCharacters(in: .whitespaces).isEmpty &&
        Double(manualItemAmount) ?? 0 > 0
    }

    private var hasUnsavedManualEntry: Bool {
        !manualItemName.trimmingCharacters(in: .whitespaces).isEmpty ||
        !manualItemAmount.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addManualItem() {
        guard canAddItem else { return }
        guard let amount = Double(manualItemAmount), amount > 0 else { return }
        let trimmedName = manualItemName.trimmingCharacters(in: .whitespaces)
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.manualTransactions.append((name: trimmedName, amount: amount))
        }
        
        manualItemName = ""
        manualItemAmount = ""
        HapticManager.notification(type: .success)
    }

    private func deleteManualTransaction(at index: Int) {
        guard index < appState.manualTransactions.count else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.manualTransactions.remove(at: index)
        }
    }
    
    private func deleteTransaction(at index: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.uploadedTransactions?.remove(at: index)
            
            // If array becomes empty, set to nil
            if appState.uploadedTransactions?.isEmpty == true {
                appState.uploadedTransactions = nil
            }
        }
    }
     

    private func cancelProcessing() {
        isProcessingImage = false
        endScanBackgroundTask()
        scanContinuedAfterLeaving = false
        isLowQualityGPTMode = false
        processingMessage = "Validating receipt..."
        processingSubtitle = nil
        processingToken += 1
        batchQueue.removeAll()
        batchTotal = 0
        batchDone = 0
        batchErrors.removeAll()
    }

    private func setupAccountTypeListener() {
        guard accountTypeObserver == nil else { return }
        accountTypeObserver = NotificationCenter.default.addObserver(
            forName: .requestAccountType,
            object: nil,
            queue: .main
        ) { _ in
            withAnimation(.spring(response: 0.3)) {
                showAccountTypePrompt = true
            }
        }
    }
    
    // NEW: Setup listener for locally-parsed statement data
    private func setupStatementDataListener() {
        guard statementDataObserver == nil else { return }
        statementDataObserver = NotificationCenter.default.addObserver(
            forName: .statementDataParsed,
            object: nil,
            queue: .main
        ) { notification in
            guard let transactionData = notification.userInfo?["transactionData"] as? ReceiptTransactionData,
                  let image = notification.userInfo?["image"] as? UIImage else {
                return
            }
            
            // Hide processing overlay
            isProcessingImage = false
            
            // Handle the parsed statement data
            handleTransactionData(transactionData, image: image)
        }
    }

    private func handleAccountTypeSelection(_ accountType: ReceiptAccountType) {
        withAnimation(.spring(response: 0.3)) {
            showAccountTypePrompt = false
        }
        NotificationCenter.default.post(
            name: .accountTypeSelected,
            object: nil,
            userInfo: ["accountType": accountType]
        )
    }

    private func setupSharedImageListener() {
        guard sharedImageObserver == nil else { return }
        sharedImageObserver = NotificationCenter.default.addObserver(
            forName: .sharedImageReceived,
            object: nil,
            queue: .main
        ) { notification in
            if let image = notification.userInfo?["image"] as? UIImage {
                uploadType = .receipt
                processImage(image)
            }
        }
    }

    private func loadPhotos(_ photos: [PhotosPickerItem]) {
        guard !photos.isEmpty else { return }
        
        var images: [UIImage] = []
        let group = DispatchGroup()
        
        for photo in photos {
            group.enter()
            photo.loadTransferable(type: Data.self) { result in
                defer { group.leave() }
                if case .success(let data) = result,
                   let data = data,
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
        }
        
        group.notify(queue: .main) {
            selectedPhotos = []
            if !images.isEmpty {
                processImages(images)
            }
        }
    }

    private func offlineUploadsDirectory() -> URL? {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = appSupport.appendingPathComponent("PendingOfflineUploads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            print("Could not prepare offline upload directory: \(error.localizedDescription)")
            return nil
        }
    }

    private func offlineUploadsIndexURL() -> URL? {
        offlineUploadsDirectory()?.appendingPathComponent("pending_uploads.json")
    }

    private func readPendingOfflineUploads() -> [PendingOfflineUpload] {
        guard let indexURL = offlineUploadsIndexURL(),
              let data = try? Data(contentsOf: indexURL),
              let uploads = try? JSONDecoder().decode([PendingOfflineUpload].self, from: data) else {
            return []
        }
        return uploads
    }

    private func writePendingOfflineUploads(_ uploads: [PendingOfflineUpload]) {
        guard let indexURL = offlineUploadsIndexURL() else { return }
        do {
            let data = try JSONEncoder().encode(uploads)
            try data.write(to: indexURL, options: [.atomic])
            pendingOfflineUploads = uploads
        } catch {
            print("Could not save offline upload queue: \(error.localizedDescription)")
        }
    }

    private func loadPendingOfflineUploads() {
        pendingOfflineUploads = readPendingOfflineUploads()
    }

    private func queueOfflineImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let kind: PendingOfflineUpload.Kind = uploadType == .transactionHistory ? .statementImage : .receiptImage
        var uploads = readPendingOfflineUploads()
        guard let directory = offlineUploadsDirectory() else { return }

        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.86) else { continue }
            let id = UUID()
            let filename = "\(id.uuidString).jpg"
            do {
                try data.write(to: directory.appendingPathComponent(filename), options: [.atomic])
                uploads.append(
                    PendingOfflineUpload(
                        id: id,
                        kind: kind,
                        filename: filename,
                        createdAt: Date()
                    )
                )
            } catch {
                print("Could not queue offline image: \(error.localizedDescription)")
            }
        }

        writePendingOfflineUploads(uploads)
        notificationManager.requestPermissionIfNeeded()
        showDuplicateUploadNotice(
            title: "Saved Until Online",
            message: images.count == 1
                ? "You're offline, so Dutch saved this upload and will process it when Wi-Fi or cellular is back."
                : "You're offline, so Dutch saved these uploads and will process them when Wi-Fi or cellular is back."
        )
    }

    private func queueOfflineStatementPDF(_ url: URL) {
        var uploads = readPendingOfflineUploads()
        guard let directory = offlineUploadsDirectory() else { return }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let id = UUID()
            let filename = "\(id.uuidString).pdf"
            try data.write(to: directory.appendingPathComponent(filename), options: [.atomic])
            uploads.append(
                PendingOfflineUpload(
                    id: id,
                    kind: .statementPDF,
                    filename: filename,
                    createdAt: Date()
                )
            )
            writePendingOfflineUploads(uploads)
            notificationManager.requestPermissionIfNeeded()
            showDuplicateUploadNotice(
                title: "Saved Until Online",
                message: "You're offline, so Dutch saved this statement PDF and will process it when Wi-Fi or cellular is back."
            )
        } catch {
            invalidReceiptMessage = "Could not save this PDF for later. Try again after reconnecting to Wi-Fi or cellular data."
            showInvalidReceiptAlert = true
        }
    }

    private func removePendingOfflineUpload(_ upload: PendingOfflineUpload) {
        var uploads = readPendingOfflineUploads()
        uploads.removeAll { $0.id == upload.id }
        writePendingOfflineUploads(uploads)

        if let directory = offlineUploadsDirectory() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(upload.filename))
        }
    }

    private func processPendingOfflineUploadsIfNeeded() {
        guard networkMonitor.isOnline else { return }
        guard !isProcessingOfflineUploadQueue, !isProcessingImage else { return }

        let uploads = readPendingOfflineUploads()
        guard !uploads.isEmpty else { return }

        isProcessingOfflineUploadQueue = true
        notificationManager.notifyOfflineUploadsProcessing(count: uploads.count)
        processPendingOfflineUpload(uploads, index: 0, completed: 0)
    }

    private func processPendingOfflineUpload(
        _ uploads: [PendingOfflineUpload],
        index: Int,
        completed: Int
    ) {
        guard index < uploads.count else {
            isProcessingOfflineUploadQueue = false
            if completed > 0 {
                notificationManager.notifyOfflineUploadsReady(count: completed)
            }
            return
        }

        guard networkMonitor.isOnline else {
            isProcessingOfflineUploadQueue = false
            return
        }

        guard let directory = offlineUploadsDirectory() else {
            isProcessingOfflineUploadQueue = false
            return
        }

        let upload = uploads[index]
        let fileURL = directory.appendingPathComponent(upload.filename)

        switch upload.kind {
        case .receiptImage, .statementImage:
            guard let data = try? Data(contentsOf: fileURL),
                  let image = UIImage(data: data) else {
                removePendingOfflineUpload(upload)
                processPendingOfflineUpload(uploads, index: index + 1, completed: completed)
                return
            }

            uploadType = upload.kind == .receiptImage ? .receipt : .transactionHistory
            removePendingOfflineUpload(upload)
            processImage(image) { success in
                processPendingOfflineUpload(
                    uploads,
                    index: index + 1,
                    completed: completed + (success ? 1 : 0)
                )
            }

        case .statementPDF:
            uploadType = .transactionHistory
            processStatementPDF(fileURL) { success in
                removePendingOfflineUpload(upload)
                processPendingOfflineUpload(
                    uploads,
                    index: index + 1,
                    completed: completed + (success ? 1 : 0)
                )
            }
        }
    }

    private func processImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        guard networkMonitor.isOnline else {
            queueOfflineImages(images)
            return
        }
        guard canStartNetworkScan() else { return }
        
        if images.count == 1 {
            processImage(images[0])
        } else {
            batchQueue = images
            batchTotal = images.count
            batchDone = 0
            batchErrors = []
            processBatchQueue()
        }
    }

    private func processBatchQueue() {
        guard !batchQueue.isEmpty else {
            finalizeBatch()
            return
        }
        
        let image = batchQueue.removeFirst()
        processingMessage = "Processing image \(batchDone + 1) of \(batchTotal)..."
        
        processImage(image) { success in
            if success {
                batchDone += 1
            } else {
                batchErrors.append("Image \(batchDone + 1) failed")
            }
            
            processBatchQueue()
        }
    }

    private func finalizeBatch() {
        let completedCount = batchDone
        let totalCount = batchTotal
        isProcessingImage = false
        batchQueue.removeAll()
        batchTotal = 0
        batchDone = 0
        
        if !batchErrors.isEmpty {
            invalidReceiptMessage = "Some images couldn't be processed:\n" + batchErrors.joined(separator: "\n")
            showInvalidReceiptAlert = true
        }
        
        batchErrors.removeAll()
        if completedCount > 0 {
            showLowQualityScanWarningForCurrentUploadIfNeeded()
            saveCompletedScanDraft()
        }

        if totalCount > 1 {
            finishBackgroundScanIfNeeded(documentName: "\(completedCount) of \(totalCount) scanned item\(totalCount == 1 ? "" : "s")")
        }
    }

    // UPDATED: Set appropriate processing message based on document type
    private func processImage(_ image: UIImage, completion: ((Bool) -> Void)? = nil) {
        let token = processingToken
        guard networkMonitor.isOnline else {
            queueOfflineImages([image])
            completion?(false)
            return
        }
        guard canStartNetworkScan() else {
            completion?(false)
            return
        }

        guard let creditDebit = consumeScanQuotaIfNeeded() else {
            completion?(false)
            return
        }

        if uploadType == .transactionHistory {
            processStatementImage(image, sourceType: "screenshot", token: token, creditDebit: creditDebit, completion: completion)
            return
        }

        isProcessingImage = true
        scanContinuedAfterLeaving = false
        if batchTotal <= 1 {
            scanCompletionNotificationSent = false
        }
        notificationManager.requestPermissionIfNeeded()
        beginScanBackgroundTaskIfNeeded()
        
        // Set appropriate processing message based on document type
        if uploadType == .transactionHistory {
            processingMessage = "Reading statement..."
        } else {
            processingMessage = "Scanning receipt..."
        }
        
        processingSubtitle = "You can leave Dutch. We will notify you when your item is ready."
        isLowQualityGPTMode = false

        let process: (@escaping (Result<OCRService.ReceiptData, Error>) -> Void) -> Void = { completion in
            if uploadType == .receipt {
                OCRService.processDocument(from: image, hint: .receipt, completion: completion)
            } else {
                OCRService.processDocument(from: image, hint: uploadType, completion: completion)
            }
        }

        process { result in
            DispatchQueue.main.async {
                guard token == processingToken else {
                    completion?(false)
                    return
                }
                
                isProcessingImage = false
                let didStoreReceipt = handleOCRResult(result, image: image)
                trialManager.commitReceiptOCRCredits(creditDebit)
                endScanBackgroundTask()
                if batchTotal <= 1 {
                    finishBackgroundScanIfNeeded(documentName: "Receipt")
                }
                completion?(didStoreReceipt)
            }
        }
    }

    private func processStatementImage(
        _ image: UIImage,
        sourceType: String,
        token: Int,
        creditDebit: TrialManager.ScanCreditDebit,
        completion: ((Bool) -> Void)? = nil
    ) {
        isProcessingImage = true
        scanContinuedAfterLeaving = false
        scanCompletionNotificationSent = false
        notificationManager.requestPermissionIfNeeded()
        beginScanBackgroundTaskIfNeeded()
        processingMessage = sourceType == "camera"
            ? "Reading your statement photo..."
            : "Reading your statement..."
        processingSubtitle = "You can leave Dutch. We will notify you when your item is ready."
        isLowQualityGPTMode = false

        OCRService.parseFinancialDocument(image: image, sourceType: sourceType) { result in
            DispatchQueue.main.async {
                guard token == processingToken else {
                    completion?(false)
                    return
                }

                isProcessingImage = false
                endScanBackgroundTask()

                switch result {
                case .success(let response):
                    let didStoreStatement = handleFinancialDocumentResponse(response, image: image, sourceType: sourceType)
                    trialManager.commitReceiptOCRCredits(creditDebit)
                    finishBackgroundScanIfNeeded(documentName: "Statement")
                    completion?(didStoreStatement)
                case .failure(let error):
                    trialManager.commitReceiptOCRCredits(creditDebit)
                    invalidReceiptMessage = statementScanErrorMessage(from: error)
                    showInvalidReceiptAlert = true
                    finishBackgroundScanIfNeeded(documentName: "Statement")
                    completion?(false)
                }
            }
        }
    }

    private func handleStatementFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            processStatementPDF(url)
        case .failure(let error):
            invalidReceiptMessage = error.localizedDescription
            showInvalidReceiptAlert = true
        }
    }

    private func processStatementPDF(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        guard networkMonitor.isOnline else {
            queueOfflineStatementPDF(url)
            completion?(false)
            return
        }
        guard canStartNetworkScan() else {
            completion?(false)
            return
        }
        let token = processingToken

        DispatchQueue.global(qos: .userInitiated).async {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let requiredCredits = pdfPageCreditCount(for: data)
                DispatchQueue.main.async {
                    guard token == processingToken else {
                        completion?(false)
                        return
                    }

                    guard let creditDebit = consumeScanQuotaIfNeeded(requiredCredits: requiredCredits) else {
                        completion?(false)
                        return
                    }

                    isProcessingImage = true
                    scanContinuedAfterLeaving = false
                    scanCompletionNotificationSent = false
                    notificationManager.requestPermissionIfNeeded()
                    beginScanBackgroundTaskIfNeeded()
                    processingMessage = "Reading your PDF statement..."
                    processingSubtitle = "You can leave Dutch. We will notify you when your item is ready."

                    OCRService.parseFinancialDocument(
                        data: data,
                        mimeType: "application/pdf",
                        sourceType: "pdf"
                    ) { result in
                        DispatchQueue.main.async {
                            guard token == processingToken else {
                                completion?(false)
                                return
                            }
                            isProcessingImage = false
                            endScanBackgroundTask()
                            switch result {
                            case .success(let response):
                                let didStoreStatement = handleFinancialDocumentResponse(response, image: UIImage(), sourceType: "pdf")
                                trialManager.commitReceiptOCRCredits(creditDebit)
                                finishBackgroundScanIfNeeded(documentName: "Statement PDF")
                                completion?(didStoreStatement)
                            case .failure(let error):
                                trialManager.commitReceiptOCRCredits(creditDebit)
                                invalidReceiptMessage = statementScanErrorMessage(from: error)
                                showInvalidReceiptAlert = true
                                finishBackgroundScanIfNeeded(documentName: "Statement PDF")
                                completion?(false)
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessingImage = false
                    endScanBackgroundTask()
                    invalidReceiptMessage = "Could not read this PDF. Upload an unlocked statement PDF."
                    showInvalidReceiptAlert = true
                    finishBackgroundScanIfNeeded(documentName: "Statement PDF")
                    completion?(false)
                }
            }
        }
    }

    private func pdfPageCreditCount(for data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            return 1
        }
        return max(1, document.numberOfPages)
    }

    @discardableResult
    private func handleFinancialDocumentResponse(
        _ response: FinancialDocumentResponse,
        image: UIImage,
        sourceType: String = "screenshot"
    ) -> Bool {
        do {
            let transactionData = try OCRService.transactionData(from: response)

            if response.data?.partialDocument == true {
                receiptUpdatedMessage = "This statement appears to be partial. Only the visible transactions were imported."
                showReceiptUpdatedAlert = true
            }

            return handleTransactionData(transactionData, image: image, sourceType: sourceType)
        } catch {
            let warning = response.warnings.first ?? response.classification.reason
            invalidReceiptMessage = warning.isEmpty
                ? "This does not appear to be a supported statement PDF."
                : warning
            showInvalidReceiptAlert = true
            return false
        }
    }

    private func statementScanErrorMessage(from error: Error) -> String {
        let rawMessage = error.localizedDescription
        let lowercased = rawMessage.lowercased()

        if lowercased.contains("missing_file") || lowercased.contains("unsupported_file_type") {
            return "This file type is not supported. Upload a PDF statement."
        }

        if lowercased.contains("not_a_statement") {
            return "No statement page or transaction history was found in this file."
        }

        if lowercased.contains("no_statement_transactions") {
            return "The file was inspected, but no statement transactions were detected. Upload a clearer PDF statement."
        }

        if lowercased.contains("pdf_page_limit_exceeded") {
            return "This PDF has too many pages. Upload a shorter statement PDF."
        }

        if lowercased.contains("network") || lowercased.contains("offline") {
            return "Turn on Wi-Fi or cellular data, then try scanning the statement again."
        }

        return "We could not read this statement yet. Upload a clearer or unlocked PDF statement."
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard isProcessingImage else { return }
            scanContinuedAfterLeaving = true
            beginScanBackgroundTaskIfNeeded()
        case .active:
            notificationManager.cancelScanReadyFollowUpReminder()
            endScanBackgroundTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                enforceRequiredGroupModeTutorialIfNeeded()
            }
        case .inactive:
            guard isProcessingImage else { return }
            scanContinuedAfterLeaving = true
            beginScanBackgroundTaskIfNeeded()
        @unknown default:
            break
        }
    }

    private func beginScanBackgroundTaskIfNeeded() {
        guard scanBackgroundTask == .invalid else { return }
        scanBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DutchReceiptOCR") {
            endScanBackgroundTask()
        }
    }

    private func endScanBackgroundTask() {
        guard scanBackgroundTask != .invalid else { return }
        let task = scanBackgroundTask
        scanBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func finishBackgroundScanIfNeeded(documentName: String) {
        guard !scanCompletionNotificationSent else { return }
        // Product rule: every scan that starts sends exactly one finished notification,
        // whether OCR succeeds, rejects the image, or fails. Do not make this conditional
        // on background/foreground state.
        notificationManager.notifyReceiptScanCompleted(documentName: documentName)
        scanCompletionNotificationSent = true
        scanContinuedAfterLeaving = false
    }

    private func saveCompletedScanDraft() {
    }

    private func showReceiptAccuracyWarningIfNeeded(for receipt: UploadedReceipt) {
        print("Receipt accuracy review skipped for OpenCV testing")
    }

    private func showLowQualityStatementWarningIfNeeded(for statement: UploadedTransaction) {
        guard statement.confidence < 0.78 else { return }
        showSoftScanQualityNotice(
            title: "Review Statement",
            message: "The statement was added to your cart. Give the rows a quick check before splitting."
        )
    }

    private func presentLowQualityScanWarning(_ message: String, requiresRetake: Bool) {
        print("Low quality receipt review skipped for testing: \(message)")
        hasPendingLowQualityScanWarning = false
        userWillHandleLowQualityScan = true
        confirmedLowQualityReviewProceed = true
        lowQualityUploadRequiresRetake = false
        lowQualityUploadMessage = ""
        showLowQualityUploadAlert = false
        showLowQualityProceedAlert = false
    }

    private func acceptLowQualityScanWarning() {
        hasPendingLowQualityScanWarning = false
        userWillHandleLowQualityScan = true
        confirmedLowQualityReviewProceed = true
        showLowQualityUploadAlert = false
        showLowQualityProceedAlert = false
    }

    private func receiptHasTotalAccuracyProblem(_ receipt: UploadedReceipt) -> Bool {
        guard !receiptLineItemsMatchTotal(receipt) else { return false }

        if receipt.ocrValidationStatus == .mismatch {
            return true
        }

        guard receipt.ocrTotalConfidence == .low else {
            return false
        }

        return receipt.ocrConfidence < 0.65 || receipt.ocrQualityScore < 0.60
    }

    private func receiptNeedsUploadAccuracyWarning(_ receipt: UploadedReceipt) -> Bool {
        guard !receiptLineItemsMatchTotal(receipt) else { return false }

        let poorOCR = receipt.ocrConfidence < 0.62 || receipt.ocrQualityScore < 0.55
        let weakReview = receipt.ocrNeedsReview &&
            (receipt.ocrConfidence < 0.70 || receipt.ocrQualityScore < 0.65)
        let totalValidationIssue = receipt.ocrValidationIssues.contains { issue in
            let lowercased = issue.lowercased()
            return lowercased.contains("total") ||
                lowercased.contains("mismatch") ||
                lowercased.contains("gap")
        }

        return poorOCR || weakReview || totalValidationIssue
    }

    private func receiptLineItemsMatchTotal(_ receipt: UploadedReceipt) -> Bool {
        guard receipt.total > 0, !receipt.lineItems.isEmpty else { return false }
        let selectedItems = receipt.lineItems.filter(\.isSelected)
        let candidateItems = selectedItems.isEmpty ? receipt.lineItems : selectedItems
        let itemSum = candidateItems.reduce(0.0) { $0 + $1.amount }
        return abs(roundToCents(itemSum) - roundToCents(receipt.total)) <= 0.02
    }

    private func roundToCents(_ amount: Double) -> Double {
        (amount * 100).rounded() / 100
    }

    private func showSoftScanQualityNotice(title: String, message: String) {
        print("Soft scan quality notice skipped: \(title) - \(message)")
    }

    private func showLowQualityScanWarningForCurrentUploadIfNeeded() {
        if (appState.uploadedTransactions ?? []).contains(where: { $0.confidence < 0.78 }) {
            showSoftScanQualityNotice(
                title: "Review Statement",
                message: "One or more statements may need a quick check. They are still in your cart."
            )
        }
    }

    private func handleLowQualityRetake() {
        HapticManager.impact(style: .medium)
        showLowQualityUploadAlert = false
        showLowQualityProceedAlert = false
        uploadType = .receipt
        showCameraForReceipt = true
    }

    private func canStartNetworkScan() -> Bool {
        guard uploadType == .receipt || uploadType == .transactionHistory else {
            return true
        }

        return networkMonitor.requireOnline(
            message: "Turn on Wi-Fi or cellular data to scan receipts or statements."
        )
    }

    @discardableResult
    private func consumeScanQuotaIfNeeded(requiredCredits: Int = 1) -> TrialManager.ScanCreditDebit? {
        guard uploadType == .receipt || uploadType == .transactionHistory else {
            return nil
        }

        let credits = max(1, requiredCredits)
        guard let debit = trialManager.consumeReceiptOCRCredits(credits: credits) else {
            invalidReceiptMessage = trialManager.hasActiveSubscription
                ? "You are out of credits until \(trialManager.creditResetDescription). Would you like to purchase more credits?"
                : trialManager.isTrialExpired
                ? "Your 3-day trial has ended. Choose a credit pack or group pass to keep scanning receipts and statements."
                : trialManager.hasStartedTrial
                ? "You need \(credits) scan credit\(credits == 1 ? "" : "s") for this scan, but only \(trialManager.receiptOCRSessionsRemaining) of 20 trial credits remain. Choose a credit pack or group pass to keep scanning."
                : "Start your 3-day trial, buy a credit pack, or choose a group pass to scan receipts and statements."
            showInvalidReceiptAlert = false
            openOutOfCreditsPaywall(preferredOutOfCreditsPaywallTarget)
            return nil
        }

        return debit
    }

    private func handleReceiptFullDataReady(_ notification: Notification) {
        guard let receiptData = notification.userInfo?["receiptData"] as? OCRService.ReceiptData else { return }
        let token = (notification.userInfo?["token"] as? String) ?? receiptData.backgroundResultToken
        guard let token else { return }

        let update = appState.updateReceipt(backgroundResultToken: token, with: receiptData)
        guard update.updated else { return }
        saveCompletedScanDraft()
        finishBackgroundScanIfNeeded(documentName: "Receipt")

        if let newTotal = update.newTotal {
            groupManager.updateReceiptBackedExpense(
                backgroundResultToken: token,
                amount: newTotal,
                description: receiptData.merchant.isEmpty ? nil : receiptData.merchant
            )
        }

        guard let oldTotal = update.oldTotal,
              let newTotal = update.newTotal,
              abs(oldTotal - newTotal) >= 0.01 else {
            return
        }

        receiptUpdatedMessage = "The detailed receipt scan finished and updated the total from \(formatQuickCurrency(oldTotal)) to \(formatQuickCurrency(newTotal))."
        print("Receipt update notice skipped for testing: \(receiptUpdatedMessage)")
    }

    private func formatQuickCurrency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    private func showDuplicateUploadNotice(title: String, message: String) {
        HapticManager.notification(type: .warning)
        uploadNoticeTitle = title
        uploadNoticeMessage = message
        showUploadNoticeAlert = true
    }

    private func handleReceiptData(_ receiptData: OCRService.ReceiptData, image: UIImage) -> Bool {
        let thumbnailImage = receiptData.preprocessedPreviewImage
            ?? ImagePreprocessor.prepare(image)
        let receipt = UploadedReceipt(
            image: thumbnailImage,
            ocrResult: receiptData
        )

        if isDuplicateReceipt(receipt) {
            print("🧾 Ignored duplicate receipt OCR result")
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.uploadedReceipts.append(receipt)
        }
        playCartAddAnimation(for: selectedCaptureMode == .receiptPhoto ? .receiptPhoto : .receipt)

        if batchTotal <= 1 {
            showReceiptAccuracyWarningIfNeeded(for: receipt)
            saveCompletedScanDraft()
            finishBackgroundScanIfNeeded(documentName: "Receipt")
        }

        return true
    }

    private func isUsableReceiptResult(_ receiptData: OCRService.ReceiptData) -> Bool {
        if let total = receiptData.grandTotal, total > 0 {
            return true
        }
        let hasPositiveItem = receiptData.lineItems.contains { item in
            item.amount > 0 && !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasReceiptCharge = (receiptData.taxAmount ?? 0) > 0 || (receiptData.tipAmount ?? 0) > 0 || receiptData.fees > 0
        let hasReceiptIdentity = !receiptData.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            receiptData.receiptDate != nil

        return receiptData.hasReceiptStructure || hasPositiveItem || hasReceiptCharge || hasReceiptIdentity
    }

    private func isDuplicateReceipt(_ receipt: UploadedReceipt) -> Bool {
        false && appState.uploadedReceipts.contains { existing in
            if let existingToken = existing.backgroundResultToken,
               let newToken = receipt.backgroundResultToken,
               !existingToken.isEmpty,
               existingToken == newToken {
                return true
            }

            let sameMerchant = existing.merchant
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(receipt.merchant.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            let sameTotal = abs(existing.total - receipt.total) < 0.01
            let sameLineCount = existing.lineItems.count == receipt.lineItems.count
            return sameMerchant && sameTotal && sameLineCount
        }
    }

    private func testReceiptData(from image: UIImage, reason: String) -> OCRService.ReceiptData {
        let prepared = ImagePreprocessor.prepareWithTimings(image)
        return OCRService.ReceiptData(
            merchant: "Unknown Merchant",
            lineItems: [],
            hasReceiptStructure: true,
            confidence: 0,
            grandTotal: nil,
            processingMethod: .appleLocal,
            receiptDate: nil,
            needsReview: false,
            fallbackReason: "test_mode_upload_placeholder:\(reason)",
            currency: "USD",
            qualityScore: 0,
            totalConfidence: .none,
            validationStatus: .notValidated,
            arithmeticGapCents: 0,
            validationIssues: [],
            ocrRoute: "apple_local_upload_placeholder",
            backgroundResultToken: nil,
            processingTimeMs: Int(prepared.timing.totalMs),
            preprocessedPreviewImage: prepared.previewImage ?? prepared.image
        )
    }

}

private struct ReceiptScanCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = min(rect.width, rect.height) * 0.16
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))

        return path
    }
}

private struct DutchiEmbeddedReceiptCameraView: UIViewRepresentable {
    @Binding var captureTrigger: Int
    @Binding var isFlashEnabled: Bool
    let onImageCaptured: (UIImage?) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.configure(previewView: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.isFlashEnabled = isFlashEnabled
        context.coordinator.captureIfNeeded(trigger: captureTrigger)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }

    nonisolated final class Coordinator: NSObject, AVCapturePhotoCaptureDelegate {
        private let session = AVCaptureSession()
        private let photoOutput = AVCapturePhotoOutput()
        private let sessionQueue = DispatchQueue(label: "com.dutchi.embedded-receipt-camera")
        private let onImageCaptured: (UIImage?) -> Void
        private var captureDevice: AVCaptureDevice?
        private var lastCaptureTrigger = 0
        private var hasObservedInitialCaptureTrigger = false
        private var isConfigured = false
        var isFlashEnabled = false

        init(onImageCaptured: @escaping (UIImage?) -> Void) {
            self.onImageCaptured = onImageCaptured
            super.init()
        }

        func configure(previewView: PreviewView) {
            previewView.previewLayer.videoGravity = .resizeAspectFill
            previewView.previewLayer.session = session

            sessionQueue.async { [weak self] in
                guard let self, !self.isConfigured else { return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo

                guard
                    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                    let input = try? AVCaptureDeviceInput(device: device),
                    self.session.canAddInput(input),
                    self.session.canAddOutput(self.photoOutput)
                else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.onImageCaptured(nil) }
                    return
                }

                self.captureDevice = device
                self.session.addInput(input)
                self.session.addOutput(self.photoOutput)
                self.photoOutput.isHighResolutionCaptureEnabled = true
                self.session.commitConfiguration()
                self.isConfigured = true
                self.session.startRunning()
            }
        }

        func captureIfNeeded(trigger: Int) {
            guard hasObservedInitialCaptureTrigger else {
                lastCaptureTrigger = trigger
                hasObservedInitialCaptureTrigger = true
                return
            }
            guard trigger != lastCaptureTrigger else { return }
            lastCaptureTrigger = trigger
            capturePhoto()
        }

        private func capturePhoto() {
            sessionQueue.async { [weak self] in
                guard let self, self.isConfigured, self.session.isRunning else {
                    DispatchQueue.main.async { self?.onImageCaptured(nil) }
                    return
                }

                let settings = AVCapturePhotoSettings()
                settings.isHighResolutionPhotoEnabled = true
                if self.isFlashEnabled, self.captureDevice?.hasFlash == true {
                    settings.flashMode = .on
                }
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else { return }
                self.session.stopRunning()
            }
        }

        nonisolated func photoOutput(
            _ output: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error: Error?
        ) {
            guard error == nil,
                  let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                DispatchQueue.main.async { self.onImageCaptured(nil) }
                return
            }

            DispatchQueue.main.async {
                self.onImageCaptured(image)
            }
        }
    }
}

// MARK: - Camera picker fallback
struct CameraImagePicker: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .overFullScreen  // ✅ CHANGED from .fullScreen
        picker.cameraViewTransform = .identity  // ✅ ADD THIS
        picker.showsCameraControls = true  // ✅ ADD THIS
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker
        init(_ parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            let image = info[.originalImage] as? UIImage
            parent.onImageCaptured(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onImageCaptured(nil)
        }
    }
}


// MARK: - Multi-image gallery picker
struct MultiImagePicker: UIViewControllerRepresentable {
    let onImagesSelected: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.filter = .images
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MultiImagePicker
        init(_ parent: MultiImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            
            guard !results.isEmpty else {
                parent.onImagesSelected([])
                return
            }

            var images = Array<UIImage?>(repeating: nil, count: results.count)
            let group = DispatchGroup()
            let lock = NSLock()
            
            for (index, result) in results.enumerated() {
                group.enter()
                result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data,
                       let image = Self.downsampledImage(from: data) {
                        lock.lock()
                        images[index] = image
                        lock.unlock()
                        group.leave()
                        return
                    }

                    result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                        defer { group.leave() }
                        if let image = object as? UIImage {
                            lock.lock()
                            images[index] = Self.resizedImageIfNeeded(image)
                            lock.unlock()
                        }
                    }
                }
            }
            
            group.notify(queue: .main) {
                self.parent.onImagesSelected(images.compactMap { $0 })
            }
        }

        private static func downsampledImage(from data: Data, maxDimension: CGFloat = 1800) -> UIImage? {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
                return UIImage(data: data).map { resizedImageIfNeeded($0) }
            }

            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
            ] as CFDictionary

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
                return UIImage(data: data).map { resizedImageIfNeeded($0) }
            }

            return UIImage(cgImage: cgImage)
        }

        private static func resizedImageIfNeeded(_ image: UIImage, maxDimension: CGFloat = 1800) -> UIImage {
            let longest = max(image.size.width, image.size.height)
            guard longest > maxDimension else { return image }

            let scale = maxDimension / longest
            let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }
    }
}

private struct UploadActionSection: View {
    let hasCurrentUploadWork: Bool
    let isProcessingImage: Bool
    let onSaveDraft: () -> Void
    let onReset: () -> Void
    let onReceiptCamera: () -> Void
    let onReceiptGallery: () -> Void
    let onStatementPDF: () -> Void

    @State private var showPhotoOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(spacing: 12) {
                uploadTypeButton(title: "SCAN RECEIPT", type: .receipt) {
                    showPhotoOptions = true
                }

                uploadTypeButton(title: "SCAN STATEMENT", type: .transactionHistory) {
                    onStatementPDF()
                }
            }
        }
        .confirmationDialog("Add Receipt Photo", isPresented: $showPhotoOptions, titleVisibility: .visible) {
            Button("Take Photo") {
                onReceiptCamera()
            }
            Button("Choose from Gallery") {
                onReceiptGallery()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text("ADD EXPENSES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(1)

            Spacer()

            if hasCurrentUploadWork {
                HStack(spacing: 8) {
                    Button(action: onSaveDraft) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color(red: 0.88, green: 0.88, blue: 0.85), lineWidth: 1)
                        )
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.96))
                    .accessibilityLabel("Save draft")

                    Button(action: onReset) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                        .foregroundColor(.red.opacity(0.85))
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(2)
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.96))
                    .accessibilityLabel("Reset upload")
                }
            }
        }
    }

    private func uploadTypeButton(
        title: String,
        type: OCRService.DocumentType,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            HapticManager.impact(style: .medium)
            action()
        }) {
            VStack(spacing: 14) {
                uploadButtonIcon(type: type)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 16)
            .background(Color.clear)
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .disabled(isProcessingImage)
        .opacity(isProcessingImage ? 0.6 : 1.0)
    }

    @ViewBuilder
    private func uploadButtonIcon(type: OCRService.DocumentType) -> some View {
        let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

        if type == .receipt {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink, lineWidth: 1.5)
                    .frame(width: 30, height: 22)
                Rectangle()
                    .stroke(ink, lineWidth: 1.5)
                    .frame(width: 10, height: 5)
                    .offset(y: -13.5)
                Circle()
                    .stroke(ink, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(ink)
                    .frame(width: 3, height: 3)
            }
            .frame(height: 40)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(ink, lineWidth: 1.5)
                    .frame(width: 22, height: 34)
                VStack(spacing: 3) {
                    Rectangle()
                        .fill(ink)
                        .frame(width: 13, height: 1.5)
                    Rectangle()
                        .fill(ink)
                        .frame(width: 11, height: 1.5)
                    Rectangle()
                        .fill(ink)
                        .frame(width: 13, height: 1.5)
                    Rectangle()
                        .fill(ink)
                        .frame(width: 9, height: 1.5)
                }
                Rectangle()
                    .fill(ink)
                    .frame(width: 8, height: 1.5)
                    .cornerRadius(1)
                    .offset(y: 14)
            }
            .frame(height: 40)
        }
    }
}

private struct DutchFloatingUploadTabBar: View {
    @Binding var selectedTab: UploadTopLevelTab
    @Binding var isActionMenuExpanded: Bool
    let onReceiptCamera: () -> Void
    let onReceiptGallery: () -> Void
    let onScanStatement: () -> Void
    let onManualEntry: () -> Void
    @State private var isReceiptSourceExpanded = false

    private let ink = Color(red: 0.13, green: 0.13, blue: 0.13)
    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let border = Color(red: 0.82, green: 0.80, blue: 0.776)

    var body: some View {
        barSurface
            .frame(height: 84)
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
        .onChange(of: isActionMenuExpanded) { _, expanded in
            if !expanded {
                isReceiptSourceExpanded = false
            }
        }
    }

    private var barSurface: some View {
        ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(ivory)
                .frame(height: 84)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(ink.opacity(0.22), lineWidth: 1.5)
                )
                .shadow(color: ink.opacity(0.08), radius: 16, x: 0, y: 8)

            HStack(spacing: 12) {
                tabButton(.upload)
                tabButton(.balances)
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 84)
    }

    private var centerActionButton: some View {
        Button {
            HapticManager.impact(style: .medium)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                isActionMenuExpanded.toggle()
                if !isActionMenuExpanded {
                    isReceiptSourceExpanded = false
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(ink)
                    .frame(width: 68, height: 68)
                    .overlay(Circle().stroke(ivory.opacity(0.9), lineWidth: 2))
                    .shadow(color: ink.opacity(0.18), radius: 14, x: 0, y: 8)

                PlusGlyph()
                    .stroke(ivory, style: StrokeStyle(lineWidth: 4.2, lineCap: .round))
                    .frame(width: 27, height: 27)
                    .rotationEffect(.degrees(isActionMenuExpanded ? 45 : 0))
            }
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.94))
        .accessibilityLabel(isActionMenuExpanded ? "Close scan menu" : "Open scan menu")
    }

    private var actionFan: some View {
        HStack(alignment: .bottom, spacing: 12) {
            actionButton(title: "Scan Receipt", kind: .receipt, action: onReceiptCamera)
            actionButton(title: "Scan Statement", kind: .statement, action: onScanStatement)
        }
    }

    private func actionButton(title: String, kind: DutchUploadGlyph.Kind, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.impact(style: .medium)
            action()
        } label: {
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(ink)
                        .frame(width: 58, height: 58)
                        .overlay(Circle().stroke(ivory.opacity(0.9), lineWidth: 1.5))
                        .shadow(color: ink.opacity(0.12), radius: 10, x: 0, y: 6)
                    DutchUploadGlyph(kind: kind, color: ivory, lineWidth: 2.2)
                        .frame(width: 30, height: 30)
                }

                Text(title)
                    .font(.system(size: 9, weight: .black))
                    .tracking(0.45)
                    .foregroundColor(ink.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(ivory.opacity(0.96))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(border.opacity(0.55), lineWidth: 1))
            }
            .frame(width: 90)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.94))
        .accessibilityLabel(title)
    }

    private func sourceActionButton(title: String, kind: DutchUploadGlyph.Kind, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.impact(style: .medium)
            action()
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(ink)
                        .frame(width: 46, height: 46)
                        .overlay(Circle().stroke(ivory.opacity(0.9), lineWidth: 1.3))
                        .shadow(color: ink.opacity(0.10), radius: 8, x: 0, y: 5)
                    DutchUploadGlyph(kind: kind, color: ivory, lineWidth: 2)
                        .frame(width: 23, height: 23)
                }

                Text(title)
                    .font(.system(size: 8, weight: .black))
                    .tracking(0.35)
                    .foregroundColor(ink.opacity(0.76))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(ivory.opacity(0.96))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(border.opacity(0.5), lineWidth: 1))
            }
            .frame(width: 52)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.94))
        .accessibilityLabel(title)
    }

    private func tabButton(_ tab: UploadTopLevelTab) -> some View {
        let isSelected = selectedTab == tab
        let color = isSelected ? ink : ink.opacity(0.42)

        return Button {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                selectedTab = tab
                isActionMenuExpanded = false
            }
        } label: {
            VStack(spacing: 5) {
                DutchUploadGlyph(kind: tab == .upload ? .upload : .balances, color: color, lineWidth: isSelected ? 2.2 : 2.0)
                    .frame(width: 30, height: 30)

                Text(tab.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 88, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.96))
        .accessibilityLabel(tab.rawValue)
    }
}

private struct UploadKeyboardToolbarHost<Content: View>: View {
    let showDone: Bool
    let onDone: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if showDone {
                        Spacer()
                        Button(action: onDone) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Done")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        }
                    }
                }
            }
    }
}

private struct PlusGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct DutchUploadGlyph: View {
    enum Kind {
        case upload
        case cart
        case balances
        case receipt
        case statement
        case gallery
        case manual
    }

    let kind: Kind
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            let rect = CGRect(origin: .zero, size: size)

            switch kind {
            case .receipt:
                drawCamera(in: rect, context: &context, stroke: stroke)
            case .upload:
                drawUploadTray(in: rect, context: &context, stroke: stroke)
            case .cart:
                drawCart(in: rect, context: &context, stroke: stroke)
            case .balances:
                drawLedger(in: rect, context: &context, stroke: stroke)
            case .statement:
                drawDocument(in: rect, context: &context, stroke: stroke)
            case .gallery:
                drawGallery(in: rect, context: &context, stroke: stroke)
            case .manual:
                drawManual(in: rect, context: &context, stroke: stroke)
            }
        }
    }

    private func drawCamera(in rect: CGRect, context: inout GraphicsContext, stroke: StrokeStyle) {
        let body = CGRect(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.30, width: rect.width * 0.76, height: rect.height * 0.50)
        let lens = CGRect(x: rect.midX - rect.width * 0.15, y: rect.midY - rect.width * 0.15, width: rect.width * 0.30, height: rect.width * 0.30)
        let top = CGRect(x: rect.midX - rect.width * 0.18, y: rect.minY + rect.height * 0.18, width: rect.width * 0.36, height: rect.height * 0.16)

        context.stroke(Path(roundedRect: body, cornerRadius: rect.width * 0.08), with: .color(color), style: stroke)
        context.stroke(Path(roundedRect: top, cornerRadius: rect.width * 0.04), with: .color(color), style: stroke)
        context.stroke(Path(ellipseIn: lens), with: .color(color), style: stroke)
    }

    private func drawUploadTray(in rect: CGRect, context: inout GraphicsContext, stroke: StrokeStyle) {
        let tray = CGRect(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.50, width: rect.width * 0.68, height: rect.height * 0.28)
        context.stroke(Path(roundedRect: tray, cornerRadius: rect.width * 0.07), with: .color(color), style: stroke)

        var lid = Path()
        lid.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.50))
        lid.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.36))
        lid.addLine(to: CGPoint(x: rect.minX + rect.width * 0.66, y: rect.minY + rect.height * 0.36))
        lid.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.50))
        context.stroke(lid, with: .color(color), style: stroke)

        var mark = Path()
        mark.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.22))
        mark.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.42))
        mark.move(to: CGPoint(x: rect.midX - rect.width * 0.08, y: rect.minY + rect.height * 0.32))
        mark.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.22))
        mark.addLine(to: CGPoint(x: rect.midX + rect.width * 0.08, y: rect.minY + rect.height * 0.32))
        context.stroke(mark, with: .color(color), style: stroke)
    }

    private func drawCart(in rect: CGRect, context: inout GraphicsContext, stroke: StrokeStyle) {
        let basket = CGRect(
            x: rect.minX + rect.width * 0.16,
            y: rect.minY + rect.height * 0.36,
            width: rect.width * 0.68,
            height: rect.height * 0.34
        )
        context.stroke(Path(roundedRect: basket, cornerRadius: rect.width * 0.06), with: .color(color), style: stroke)

        var handle = Path()
        handle.move(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.36))
        handle.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.22))
        handle.addLine(to: CGPoint(x: rect.minX + rect.width * 0.60, y: rect.minY + rect.height * 0.22))
        handle.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.minY + rect.height * 0.36))
        context.stroke(handle, with: .color(color), style: stroke)

        for xFactor in [0.34, 0.50, 0.66] {
            var line = Path()
            line.move(to: CGPoint(x: rect.minX + rect.width * xFactor, y: rect.minY + rect.height * 0.43))
            line.addLine(to: CGPoint(x: rect.minX + rect.width * xFactor, y: rect.minY + rect.height * 0.63))
            context.stroke(line, with: .color(color.opacity(0.75)), style: stroke)
        }
    }

    private func drawLedger(in rect: CGRect, context: inout GraphicsContext, stroke: StrokeStyle) {
        let page = CGRect(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.12, width: rect.width * 0.64, height: rect.height * 0.76)
        context.stroke(Path(roundedRect: page, cornerRadius: rect.width * 0.08), with: .color(color), style: stroke)

        for index in 0..<3 {
            let y = rect.minY + rect.height * (0.34 + CGFloat(index) * 0.17)
            var row = Path()
            row.move(to: CGPoint(x: rect.minX + rect.width * 0.34, y: y))
            row.addLine(to: CGPoint(x: rect.minX + rect.width * 0.68, y: y))
            context.stroke(row, with: .color(color), style: stroke)
        }

        for index in 0..<2 {
            context.fill(
                Path(ellipseIn: CGRect(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * (0.29 + CGFloat(index) * 0.17), width: rect.width * 0.07, height: rect.width * 0.07)),
                with: .color(color)
            )
        }
    }

    private func drawDocument(in rect: CGRect, context: inout GraphicsContext, stroke: StrokeStyle) {
        let page = CGRect(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.08, width: rect.width * 0.52, height: rect.height * 0.82)
        context.stroke(Path(roundedRect: page, cornerRadius: rect.width * 0.07), with: .color(color), style: stroke)
        for index in 0..<4 {
            let y = rect.minY + rect.height * (0.32 + CGFloat(index) * 0.13)
            var line = Path()
            line.move(to: CGPoint(x: rect.minX + rect.width * 0.36, y: y))
            line.addLine(to: CGPoint(x: rect.minX + rect.width * (index == 3 ? 0.58 : 0.66), y: y))
            context.stroke(line, with: .color(color), style: stroke)
        }
    }

    private func drawGallery(in rect: CGRect, context: inout GraphicsContext, stroke: StrokeStyle) {
        let frame = CGRect(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.20, width: rect.width * 0.72, height: rect.height * 0.58)
        context.stroke(Path(roundedRect: frame, cornerRadius: rect.width * 0.07), with: .color(color), style: stroke)
        context.stroke(
            Path(ellipseIn: CGRect(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.30, width: rect.width * 0.10, height: rect.width * 0.10)),
            with: .color(color),
            style: stroke
        )

        var mountain = Path()
        mountain.move(to: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.70))
        mountain.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.50))
        mountain.addLine(to: CGPoint(x: rect.minX + rect.width * 0.52, y: rect.minY + rect.height * 0.62))
        mountain.addLine(to: CGPoint(x: rect.minX + rect.width * 0.64, y: rect.minY + rect.height * 0.52))
        mountain.addLine(to: CGPoint(x: rect.minX + rect.width * 0.80, y: rect.minY + rect.height * 0.70))
        context.stroke(mountain, with: .color(color), style: stroke)
    }

    private func drawManual(in rect: CGRect, context: inout GraphicsContext, stroke: StrokeStyle) {
        let box = CGRect(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.22, width: rect.width * 0.58, height: rect.height * 0.58)
        context.stroke(Path(roundedRect: box, cornerRadius: rect.width * 0.07), with: .color(color), style: stroke)

        var pencil = Path()
        pencil.move(to: CGPoint(x: rect.minX + rect.width * 0.50, y: rect.minY + rect.height * 0.68))
        pencil.addLine(to: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.34))
        pencil.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.26))
        pencil.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.60))
        context.stroke(pencil, with: .color(color), style: stroke)
    }
}

// MARK: - Spinning coin loading indicator
struct SpinningCoinView: View {
    @State private var isFlipping = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.yellow.opacity(0.8), Color.orange.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 2))
                .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)

            Text("$")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
                .rotation3DEffect(
                    .degrees(isFlipping ? 360 : 0),
                    axis: (x: 0, y: 1, z: 0)
                )
        }
        .onAppear {
            withAnimation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                isFlipping = true
            }
        }
    }
}

extension Notification.Name {
    static let requestAccountType = Notification.Name("requestAccountType")
    static let accountTypeSelected = Notification.Name("accountTypeSelected")
    static let sharedImageReceived = Notification.Name("sharedImageReceived")
    static let groupDidLeave = Notification.Name("groupDidLeave")
    static let groupDidLeaveWithUndo = Notification.Name("groupDidLeaveWithUndo")
    static let statementDataParsed = Notification.Name("statementDataParsed")  // NEW
}
