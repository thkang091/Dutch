import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase
import RevenueCat

private var sharedImagesAlreadyProcessed = false

@main
struct DutchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
    @StateObject private var appState = AppState()
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var router = Router()
    @StateObject private var tutorialManager = TutorialManager()
    @StateObject private var groupModeTutorial = GroupModeTutorialManager()
    
    private let appGroupID = "group.com.taehoonkang.dutchi"
    
    init() {
        print(" Dutch app init")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if NetworkStatusMonitor.shared.isOnline {
                GroupManager.shared.startObservingActiveGroup()
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentRoot()
                .environmentObject(appState)
                .environmentObject(router)
                .environmentObject(tutorialManager)
                .environmentObject(authManager)
                .environmentObject(groupModeTutorial)
                .onAppear {
                    print("✅ ContentRoot appeared")
                    authManager.configure(appState: appState)
                    tutorialManager.router = router
                    tutorialManager.appState = appState
                    
                    // Configure group mode tutorial
                    groupModeTutorial.router = router
                    groupModeTutorial.appState = appState
                    groupModeTutorial.groupManager = GroupManager.shared
                    router.groupModeTutorial = groupModeTutorial

                    if NetworkStatusMonitor.shared.isOnline {
                        TrialManager.shared.syncSubscriptionStatusWithFirebase()
                    }
                    
                    // ✅ RESTART OBSERVER WHEN APP APPEARS
                    if NetworkStatusMonitor.shared.isOnline {
                        GroupManager.shared.startObservingActiveGroup()
                    }
                    openStoredPendingInviteIfPossible()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        processSharedIfNeeded()
                    }
                }
                .onOpenURL { url in
                    print("🔗 onOpenURL:", url.absoluteString)
                    
                    if Auth.auth().canHandle(url) {
                        print("✅ Firebase handled auth URL:", url)
                        return
                    }
                    
                    if url.scheme == "dutch" || url.scheme == "dutchie" {
                        handleDeepLink(url)
                    } else if url.host == "dutchieapp.com" {
                        handleDeepLink(url)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.willEnterForegroundNotification
                    )
                ) { _ in
                    sharedImagesAlreadyProcessed = false
                    if NetworkStatusMonitor.shared.isOnline {
                        TrialManager.shared.syncSubscriptionStatusWithFirebase()
                    }
                    
                    // ✅ RESTART OBSERVER WHEN APP ENTERS FOREGROUND
                    if NetworkStatusMonitor.shared.isOnline {
                        GroupManager.shared.startObservingActiveGroup()
                    }
                    openStoredPendingInviteIfPossible()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        processSharedIfNeeded()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openUpload)) { notification in
                    router.resetToUpload()
                }
        }
    }
    
    // Helper function to normalize phone numbers
    private func normalizePhoneNumber(_ phone: String) -> String {
        let digitsOnly = phone.filter { $0.isNumber }
        
        if digitsOnly.count == 10 {
            return "+1" + digitsOnly
        }
        
        if digitsOnly.count == 11, digitsOnly.first == "1" {
            return "+" + digitsOnly
        }
        
        if phone.hasPrefix("+") {
            return "+" + digitsOnly
        }
        
        return digitsOnly.isEmpty ? phone : "+" + digitsOnly
    }
    
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "dutch" || url.scheme == "dutchie" || url.host == "dutchieapp.com" else { return }

        if (url.scheme == "dutch" || url.scheme == "dutchie"), url.host == "shared-upload" {
            router.showLogoIntro = false
            sharedImagesAlreadyProcessed = false
            router.resetToUpload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                processSharedIfNeeded()
            }
            return
        }

        let isBalancesDeepLink = (url.scheme == "dutch" || url.scheme == "dutchie") && url.host == "balances"
        let isBalancesWebLink = url.host == "dutchieapp.com" && url.path == "/balances"

        if isBalancesDeepLink || isBalancesWebLink {
            router.showLogoIntro = false
            let itemID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "item" })?
                .value
            router.resetToUpload()
            router.pendingBalanceHighlightItemID = itemID
            NotificationCenter.default.post(
                name: .openBalances,
                object: nil,
                userInfo: itemID.map { ["itemID": $0] } ?? [:]
            )
            return
        }

        if let requestID = paymentRequestID(from: url) {
            router.showLogoIntro = false
            loadPaymentRequest(requestID)
            return
        }
        
        if url.host == "join",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let groupIdString = components.queryItems?.first(where: { $0.name == "groupId" })?.value,
           let groupID = UUID(uuidString: groupIdString) {
            
            print("Group invite link clicked: \(groupID)")
            
            let groupName = components.queryItems?.first(where: { $0.name == "name" })?.value?.removingPercentEncoding ?? "Unknown Group"
            let inviterName = components.queryItems?.first(where: { $0.name == "inviter" })?.value?.removingPercentEncoding ?? "Someone"
            
            guard authManager.isAuthenticated else {
                print("User not authenticated - store invite for later")
                UserDefaults.standard.set(groupIdString, forKey: "pendingGroupInvite")
                UserDefaults.standard.set(groupName, forKey: "pendingGroupName")
                UserDefaults.standard.set(inviterName, forKey: "pendingInviterName")
                GroupManager.shared.pendingInvite = PendingGroupInvite(
                    groupID: groupID,
                    groupName: groupName,
                    inviterName: inviterName,
                    phoneNumber: ""
                )
                return
            }

            let processInvite: (DutchieGroup) -> Void = { existingGroup in
                let userPhone = (authManager.phoneNumber ?? appState.profile.zelleContactInfo).map { normalizePhoneNumber($0) }

                if let userPhone,
                   existingGroup.members.contains(where: {
                       guard let memberPhone = $0.phoneNumber else { return false }
                       return normalizePhoneNumber(memberPhone) == userPhone && !$0.isPending
                    }) {
                    print("Already a subscription member - refresh shared plan")
                    TrialManager.shared.joinSharedSubscriptionPlan(
                        groupID: existingGroup.id,
                        groupName: existingGroup.name,
                        ownerPhone: existingGroup.members.first(where: { $0.id == existingGroup.createdByID })?.phoneNumber,
                        profile: appState.profile,
                        fallbackMemberLimit: existingGroup.maxMemberCount
                    ) { success, message in
                        if !success {
                            print(message ?? "Subscription invite is full")
                            return
                        }
                        GroupManager.shared.ensureSubscriptionGroupVisible(
                            groupID: existingGroup.id,
                            groupName: existingGroup.name,
                            profile: appState.profile
                        )
                        UserDefaults.standard.removeObject(forKey: "pendingGroupInvite")
                        UserDefaults.standard.removeObject(forKey: "pendingGroupName")
                        UserDefaults.standard.removeObject(forKey: "pendingInviterName")
                        router.resetToUpload()
                    }
                    return
                }

                let canonicalInviterName = existingGroup.members.first(where: { $0.id == existingGroup.createdByID })?.name
                    ?? existingGroup.members.first(where: { !$0.isCurrentUser && !$0.isPending })?.name
                    ?? inviterName
                let invite = PendingGroupInvite(
                    groupID: groupID,
                    groupName: existingGroup.name,
                    inviterName: canonicalInviterName,
                    phoneNumber: userPhone ?? ""
                )

                GroupManager.shared.pendingInvite = invite
                UserDefaults.standard.set(groupIdString, forKey: "pendingGroupInvite")
                UserDefaults.standard.set(existingGroup.name, forKey: "pendingGroupName")
                UserDefaults.standard.set(canonicalInviterName, forKey: "pendingInviterName")
                NotificationCenter.default.post(
                    name: .processDeepLink,
                    object: nil,
                    userInfo: ["invite": invite]
                )
            }

            if let cachedGroup = GroupManager.shared.getGroup(by: groupID) {
                processInvite(cachedGroup)
                return
            }

            GroupManager.shared.fetchGroupForInvite(groupID: groupID) { fetchedGroup in
                DispatchQueue.main.async {
                    guard let fetchedGroup else {
                        print("Could not verify invite group from Firebase")
                        return
                    }
                    processInvite(fetchedGroup)
                }
            }
            
            return
        }
        
        if let receiptID = receiptID(from: url) {
            router.showLogoIntro = false
            router.showReceiptId = receiptID
            HapticManager.notification(type: .success)
            print("Receipt deep link: \(receiptID)")
            return
        }
        
        if url.host == "pay",
           let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            if let requestID = queryItems.first(where: { $0.name == "request" })?.value,
               !requestID.isEmpty {
                router.showLogoIntro = false
                loadPaymentRequest(requestID)
                return
            }

            let from    = queryItems.first(where: { $0.name == "from" })?.value ?? ""
            let to      = queryItems.first(where: { $0.name == "to" })?.value ?? ""
            let amount  = Double(queryItems.first(where: { $0.name == "amount" })?.value ?? "0") ?? 0
            let receipt = queryItems.first(where: { $0.name == "receipt" })?.value ?? ""
            
            router.landingFromName = from
            router.landingToName = to
            router.landingAmount = amount
            router.landingPaymentRequestId = nil
            router.landingPayeeVenmoUsername = nil
            router.landingPayeeVenmoLink = nil
            router.landingPayeeZelleContact = nil
            router.landingPayeeZelleLink = nil
            if let receiptUUID = UUID(uuidString: receipt) {
                router.landingReceiptId = receiptUUID
            }
            
            router.showLogoIntro = false
            HapticManager.notification(type: .success)
            router.showPaymentLanding = true
            
            print("Payment deep link: from=\(from), to=\(to), amount=\(amount), receipt=\(receipt)")
        }
    }

    private func openStoredPendingInviteIfPossible() {
        guard GroupManager.shared.pendingInvite == nil,
              let groupIdString = UserDefaults.standard.string(forKey: "pendingGroupInvite"),
              let groupID = UUID(uuidString: groupIdString) else {
            return
        }

        let groupName = UserDefaults.standard.string(forKey: "pendingGroupName") ?? "Dutch Group"
        let inviterName = UserDefaults.standard.string(forKey: "pendingInviterName") ?? "Someone"

        GroupManager.shared.pendingInvite = PendingGroupInvite(
            groupID: groupID,
            groupName: groupName,
            inviterName: inviterName,
            phoneNumber: authManager.phoneNumber ?? ""
        )

        guard NetworkStatusMonitor.shared.isOnline else { return }
        GroupManager.shared.fetchGroupForInvite(groupID: groupID) { fetchedGroup in
            DispatchQueue.main.async {
                guard let fetchedGroup else { return }
                let invite = PendingGroupInvite(
                    groupID: groupID,
                    groupName: fetchedGroup.name,
                    inviterName: fetchedGroup.members.first(where: { $0.id == fetchedGroup.createdByID })?.name ?? inviterName,
                    phoneNumber: authManager.phoneNumber ?? ""
                )
                GroupManager.shared.pendingInvite = invite
                NotificationCenter.default.post(
                    name: .processDeepLink,
                    object: nil,
                    userInfo: ["invite": invite]
                )
            }
        }
    }

    private func paymentRequestID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        if url.host == "pay",
           let requestID = components.queryItems?.first(where: { $0.name == "request" })?.value,
           !requestID.isEmpty {
            return requestID
        }

        if url.host == "dutchieapp.com",
           url.path == "/download",
           let requestID = components.queryItems?.first(where: { $0.name == "payRequest" })?.value,
           !requestID.isEmpty {
            return requestID
        }

        return nil
    }

    private func loadPaymentRequest(_ requestID: String) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to open this payment request.") else {
            return
        }

        Database.database().reference()
            .child("paymentRequests")
            .child(requestID)
            .observeSingleEvent(of: .value) { snapshot in
                guard let dict = snapshot.value as? [String: Any] else {
                    print("❌ Payment request not found: \(requestID)")
                    return
                }

                DispatchQueue.main.async {
                    router.landingPaymentRequestId = requestID
                    router.landingFromName = dict["fromName"] as? String ?? "You"
                    router.landingToName = dict["toName"] as? String ?? "Friend"
                    router.landingAmount = dict["amount"] as? Double ?? 0
                    if let receiptString = dict["receiptId"] as? String,
                       let receiptID = UUID(uuidString: receiptString) {
                        router.landingReceiptId = receiptID
                    } else {
                        router.landingReceiptId = UUID()
                    }
                    router.landingPayeeVenmoUsername = dict["payeeVenmoUsername"] as? String
                    router.landingPayeeVenmoLink = dict["payeeVenmoLink"] as? String
                    router.landingPayeeZelleContact = dict["payeeZelleContact"] as? String
                    router.landingPayeeZelleLink = dict["payeeZelleLink"] as? String
                    HapticManager.notification(type: .success)
                    router.showPaymentLanding = true
                }
            }
    }

    private func receiptID(from url: URL) -> UUID? {
        if url.scheme == "dutch" || url.scheme == "dutchie" {
            if url.host == "receipt",
               let idString = url.pathComponents.dropFirst().first,
               let id = UUID(uuidString: idString) {
                return id
            }

            let components = url.pathComponents
            if components.count >= 3,
               components[1] == "receipt",
               let id = UUID(uuidString: components[2]) {
                return id
            }
        }

        if url.host == "dutchieapp.com",
           url.path == "/download",
           let receipt = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "receipt" })?
                .value,
           let id = UUID(uuidString: receipt) {
            return id
        }

        return nil
    }
    
    private func processSharedIfNeeded() {
        guard !sharedImagesAlreadyProcessed else {
            print("Shared images already processed, skipping")
            return
        }
        guard hasPendingSharedImages() else { return }
        sharedImagesAlreadyProcessed = true
        handleSharedReceipts()
    }
    
    private func hasPendingSharedImages() -> Bool {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return false }
        let indexURL = containerURL.appendingPathComponent("pending_receipts.json")
        guard let data = try? Data(contentsOf: indexURL),
              let filenames = try? JSONSerialization.jsonObject(with: data) as? [String] else { return false }
        return !filenames.isEmpty
    }
    
    private func handleSharedReceipts() {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        
        let indexURL = containerURL.appendingPathComponent("pending_receipts.json")
        
        guard let data = try? Data(contentsOf: indexURL),
              let filenames = try? JSONSerialization.jsonObject(with: data) as? [String],
              !filenames.isEmpty else { return }
        
        print("✅ Processing \(filenames.count) shared image(s)")
        try? FileManager.default.removeItem(at: indexURL)
        
        let folder = containerURL.appendingPathComponent("SharedReceipts")
        let totalCount = filenames.count
        
        router.reset()
        
        for (index, filename) in filenames.enumerated() {
            let fileURL = folder.appendingPathComponent(filename)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(index) * 0.6) {
                if let imageData = try? Data(contentsOf: fileURL),
                   let image = UIImage(data: imageData) {
                    print("✅ Posting image \(index + 1)/\(totalCount)")
                    NotificationCenter.default.post(
                        name: NSNotification.Name("sharedImageReceived"),
                        object: nil,
                        userInfo: ["image": image]
                    )
                }
                if index == totalCount - 1 {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
    }
    
    struct ContentRoot: View {
        @EnvironmentObject var router: Router
        @EnvironmentObject var tutorialManager: TutorialManager
        @EnvironmentObject var appState: AppState
        @EnvironmentObject var groupModeTutorial: GroupModeTutorialManager
        @EnvironmentObject var authManager: AuthManager
        @StateObject private var networkMonitor = NetworkStatusMonitor.shared
        @StateObject private var trialManager = TrialManager.shared
        @StateObject private var groupManager = GroupManager.shared

        @State private var showPaymentBanner = false
        @State private var bannerExpense: GroupExpense?
        @State private var bannerGroupName = ""
        @State private var bannerYourShare: Double = 0
        @State private var showOfflineAlert = false
        @State private var offlineAlertMessage = NetworkStatusMonitor.offlineMessage
        @State private var inviteFlowPendingInvite: PendingGroupInvite?
        @State private var showInvitePhoneVerification = false
        @State private var showInviteJoin = false
        // Persisted flag set when user taps "GET STARTED" in the invite step.
        // Until this is true, subscription users stay in the group-creation/invite gate.
        @AppStorage("dutchie.onboardingInviteDone") private var inviteStepDone = false

        // MARK: - Onboarding gate (purely computed from persisted state)

        private var hasPendingInviteFlow: Bool {
            inviteFlowPendingInvite != nil ||
            groupManager.pendingInvite != nil ||
            UserDefaults.standard.string(forKey: "pendingGroupInvite") != nil
        }

        private var isTutorialFlowAllowed: Bool {
            !tutorialManager.hasCompletedTutorial ||
            (trialManager.hasAppEntitlement && groupModeTutorial.isActive)
        }

        private var hasActiveUploadReviewSession: Bool {
            !appState.uploadedReceipts.isEmpty ||
            !appState.manualTransactions.isEmpty ||
            !(appState.uploadedTransactions?.isEmpty ?? true) ||
            !appState.transactions.isEmpty
        }

        private var shouldLockToPaywall: Bool {
            tutorialManager.hasCompletedTutorial &&
            !trialManager.hasAppEntitlement &&
            !isTutorialFlowAllowed &&
            !hasPendingInviteFlow &&
            !hasActiveUploadReviewSession
        }

        private var rootGateDestination: String {
            if router.showLogoIntro { return "logo_intro" }
            if shouldLockToPaywall { return "paywall_locked" }
            if needsSubscriptionSetup { return "subscription_setup" }
            return "main_app"
        }

        private func logRootGate(reason: String) {
            print("""
            🧊 FREEZE DEBUG [root-gate:\(reason)]
            destination=\(rootGateDestination)
            showLogoIntro=\(router.showLogoIntro)
            tutorialCompleted=\(tutorialManager.hasCompletedTutorial)
            tutorialActive=\(tutorialManager.isActive)
            groupTutorialActive=\(groupModeTutorial.isActive)
            hasAppEntitlement=\(trialManager.hasAppEntitlement)
            hasRecurringSubscriptionAccess=\(trialManager.hasRecurringSubscriptionAccess)
            hasUsableCredits=\(trialManager.hasUsableCredits)
            hasActiveSubscription=\(trialManager.hasActiveSubscription)
            hasFutureScheduledSubscription=\(trialManager.hasFutureScheduledSubscription)
            hasSharedSubscriptionAccess=\(trialManager.hasSharedSubscriptionAccess)
            trialActive=\(trialManager.isTrialActive)
            trialExpired=\(trialManager.isTrialExpired)
            trialCreditsRemaining=\(trialManager.receiptOCRSessionsRemaining)
            purchasedCredits=\(trialManager.purchasedOCRCreditsRemaining)
            subscriptionCreditsRemaining=\(trialManager.subscriptionOCRSessionsRemaining.map(String.init) ?? "nil")
            hasPendingInviteFlow=\(hasPendingInviteFlow)
            inviteFlowPendingInvite=\(inviteFlowPendingInvite?.groupID.uuidString ?? "nil")
            groupManagerPendingInvite=\(groupManager.pendingInvite?.groupID.uuidString ?? "nil")
            storedPendingInvite=\(UserDefaults.standard.string(forKey: "pendingGroupInvite") ?? "nil")
            showInvitePhoneVerification=\(showInvitePhoneVerification)
            showInviteJoin=\(showInviteJoin)
            needsSubscriptionSetup=\(needsSubscriptionSetup)
            shouldLockToPaywall=\(shouldLockToPaywall)
            hasActiveUploadReviewSession=\(hasActiveUploadReviewSession)
            authIsAuthenticated=\(authManager.isAuthenticated)
            inviteStepDone=\(inviteStepDone)
            networkOnline=\(networkMonitor.isOnline)
            """)
        }

        // Subscription owners who haven't yet finished phone verify + group creation + invite.
        // Credit-pack users always return false — they skip this gate entirely.
        private var needsSubscriptionSetup: Bool {
            guard tutorialManager.hasCompletedTutorial else { return false }
            guard trialManager.hasAppEntitlement else { return false }
            guard !hasActiveUploadReviewSession else { return false }
            // Gate applies to recurring subscription owners — both while the trial is running
            // (hasFutureScheduledSubscription: subscription start is in the future, trial active)
            // and once the subscription is fully active (hasActiveSubscription).
            // Credit-pack users never set subscriptionStartedAt so both are false → gate skipped.
            let hasOrWillHaveSubscription = trialManager.hasRecurringSubscriptionAccess
            guard hasOrWillHaveSubscription else { return false }
            guard !trialManager.hasSharedSubscriptionAccess else { return false }
            // Gate stays open until phone is verified AND invite step is acknowledged
            return !authManager.isAuthenticated || !inviteStepDone
        }

        // MARK: - Gated content

        @ViewBuilder
        private var gatedContent: some View {
            if shouldLockToPaywall {
                // Locked paywall — normal app usage requires recurring access or usable credits.
                PaywallView(
                    startsPaidImmediately: trialManager.hasStartedTrial,
                    allowsDismiss: false
                )
                .environmentObject(appState)
            } else if needsSubscriptionSetup {
                // Locked phone verification → group creation → invite
                // Stable .id keeps the same SubscriptionSetupFlow instance alive across the
                // phone→group transition so the internal step animation plays correctly.
                SubscriptionSetupFlow(authManager: authManager) {}
                    .environmentObject(appState)
                    .id("subscription-setup")
            } else {
                // Normal app — tutorial runs inside MainView when !hasCompletedTutorial
                MainView()
            }
        }

        var body: some View {
            ZStack(alignment: .top) {
                if router.showLogoIntro {
                    LogoIntroView()
                } else {
                    gatedContent
                        .transition(.opacity)
                }

                if !networkMonitor.isOnline {
                    offlineBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(998)
                }
                
                if showPaymentBanner, let expense = bannerExpense {
                    VStack(spacing: 0) {
                        PaymentRequestBanner(
                            expense: expense,
                            groupName: bannerGroupName,
                            yourShare: bannerYourShare,
                            isVisible: $showPaymentBanner,
                            onPayNow: {
                                withAnimation(.spring(response: 0.3)) {
                                    showPaymentBanner = false
                                }
                            }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                        
                        Spacer()
                    }
                    .zIndex(999)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: networkMonitor.isOnline)
            .alert("Connection Required", isPresented: $showOfflineAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(offlineAlertMessage)
            }
            .sheet(isPresented: $showInvitePhoneVerification) {
                PhoneVerificationPromptSheet(
                    authManager: authManager,
                    prefilledPhone: appState.profile.zelleContactInfo ?? "",
                    isPresented: $showInvitePhoneVerification,
                    allowsDismiss: false,
                    onVerified: {
                        presentInviteJoinAfterVerification()
                    }
                )
                .interactiveDismissDisabled(true)
            }
            .sheet(isPresented: $showInviteJoin) {
                if let invite = inviteFlowPendingInvite {
                    GroupJoinView(
                        groupManager: groupManager,
                        invite: invite,
                        allowsDismiss: false,
                        onFullInviteBack: {
                            exitFullInviteToPaywall()
                        },
                        onJoinComplete: {
                            inviteFlowPendingInvite = nil
                            groupManager.pendingInvite = nil
                            showInviteJoin = false
                            showInvitePhoneVerification = false
                            UserDefaults.standard.removeObject(forKey: "pendingGroupInvite")
                            UserDefaults.standard.removeObject(forKey: "pendingGroupName")
                            UserDefaults.standard.removeObject(forKey: "pendingInviterName")
                        }
                    )
                    .environmentObject(authManager)
                    .environmentObject(appState)
                    .interactiveDismissDisabled(true)
                }
            }
            .onAppear {
                logRootGate(reason: "appear")
                if NetworkStatusMonitor.shared.isOnline {
                    GroupManager.shared.startObservingActiveGroup()
                }
                presentPendingInviteFlowIfNeeded()
                
                NotificationCenter.default.addObserver(
                    forName: .showPaymentRequestBanner,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let userInfo = notification.userInfo,
                       let expense = userInfo["expense"] as? GroupExpense,
                       let groupName = userInfo["groupName"] as? String,
                       let yourShare = userInfo["yourShare"] as? Double {
                        
                        bannerExpense = expense
                        bannerGroupName = groupName
                        bannerYourShare = yourShare
                        
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showPaymentBanner = true
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                            withAnimation(.spring(response: 0.3)) {
                                showPaymentBanner = false
                            }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showOfflineNetworkAlert)) { notification in
                offlineAlertMessage = notification.userInfo?["message"] as? String ?? NetworkStatusMonitor.offlineMessage
                showOfflineAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .processDeepLink)) { notification in
                if let invite = notification.userInfo?["invite"] as? PendingGroupInvite {
                    inviteFlowPendingInvite = invite
                }
                logRootGate(reason: "processDeepLink")
                presentPendingInviteFlowIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dutchieFullReset)) { _ in
                appState.wipeAllState()
                tutorialManager.reset()
                inviteStepDone = false
                inviteFlowPendingInvite = nil
                showInvitePhoneVerification = false
                showInviteJoin = false
                try? authManager.signOut()
                router.reset()
                router.showLogoIntro = true
            }
            .onChange(of: tutorialManager.hasCompletedTutorial) { _, hasCompleted in
                logRootGate(reason: "tutorialCompletedChanged")
                guard hasCompleted else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    presentPendingInviteFlowIfNeeded()
                }
            }
            .onChange(of: groupManager.pendingInvite?.groupID) { _, _ in
                logRootGate(reason: "pendingInviteChanged")
                presentPendingInviteFlowIfNeeded()
            }
            .onChange(of: authManager.canUseGroupMode) { _, canUseGroupMode in
                logRootGate(reason: "canUseGroupModeChanged")
                guard canUseGroupMode else { return }
                presentInviteJoinAfterVerification()
            }
            .onChange(of: networkMonitor.isOnline) { _, isOnline in
                logRootGate(reason: "networkChanged")
                guard isOnline else { return }
                TrialManager.shared.syncSubscriptionStatusWithFirebase()
                GroupManager.shared.startObservingActiveGroup()
            }
        }

        private var offlineBanner: some View {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 14, weight: .bold))
                Text("Turn on Wi-Fi or cellular data to use online features.")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
            .cornerRadius(3)
                .padding(.horizontal, 16)
                .padding(.top, 12)
        }

        private func presentPendingInviteFlowIfNeeded() {
            guard tutorialManager.hasCompletedTutorial else { return }
            guard !showInvitePhoneVerification, !showInviteJoin else { return }
            guard let invite = inviteFlowPendingInvite ?? groupManager.pendingInvite ?? storedPendingInvite() else { return }

            inviteFlowPendingInvite = invite
            groupManager.pendingInvite = nil

            if authManager.canUseGroupMode {
                showInvitePhoneVerification = false
                showInviteJoin = true
            } else {
                showInviteJoin = false
                showInvitePhoneVerification = true
            }
        }

        private func presentInviteJoinAfterVerification() {
            guard let invite = inviteFlowPendingInvite ?? groupManager.pendingInvite ?? storedPendingInvite() else { return }
            let verifiedInvite = inviteWithVerifiedPhone(invite)
            inviteFlowPendingInvite = verifiedInvite
            groupManager.pendingInvite = nil
            showInvitePhoneVerification = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                showInviteJoin = true
            }
        }

        private func storedPendingInvite() -> PendingGroupInvite? {
            guard let groupIdString = UserDefaults.standard.string(forKey: "pendingGroupInvite"),
                  let groupID = UUID(uuidString: groupIdString) else {
                return nil
            }

            return PendingGroupInvite(
                groupID: groupID,
                groupName: UserDefaults.standard.string(forKey: "pendingGroupName") ?? "Dutch Group",
                inviterName: UserDefaults.standard.string(forKey: "pendingInviterName") ?? "Someone",
                phoneNumber: authManager.phoneNumber ?? ""
            )
        }

        private func inviteWithVerifiedPhone(_ invite: PendingGroupInvite) -> PendingGroupInvite {
            guard let phone = authManager.phoneNumber, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return invite
            }

            return PendingGroupInvite(
                groupID: invite.groupID,
                groupName: invite.groupName,
                inviterName: invite.inviterName,
                phoneNumber: phone
            )
        }

        private func exitFullInviteToPaywall() {
            if let groupID = inviteFlowPendingInvite?.groupID {
                groupManager.forceDiscardInviteGroup(groupID: groupID)
            }
            inviteFlowPendingInvite = nil
            groupManager.pendingInvite = nil
            showInviteJoin = false
            showInvitePhoneVerification = false
            UserDefaults.standard.removeObject(forKey: "pendingGroupInvite")
            UserDefaults.standard.removeObject(forKey: "pendingGroupName")
            UserDefaults.standard.removeObject(forKey: "pendingInviterName")
        }
    }
    
    struct MainView: View {
        @EnvironmentObject var appState: AppState
        @EnvironmentObject var router: Router
        @EnvironmentObject var tutorialManager: TutorialManager
        @EnvironmentObject var groupModeTutorial: GroupModeTutorialManager
        @StateObject private var trialManager = TrialManager.shared
        @StateObject private var groupManager = GroupManager.shared

        private var canUseMainApp: Bool {
            trialManager.hasAppEntitlement ||
            groupManager.pendingInvite != nil ||
            !tutorialManager.hasCompletedTutorial
        }
        
        var body: some View {
            SwiftUI.Group {
                if canUseMainApp {
                    NavigationStack(path: $router.path) {
                        UploadView()
                            .navigationDestination(for: String.self) { destination in
                                destinationView(for: destination)
                                    .environmentObject(appState)
                                    .environmentObject(router)
                                    .environmentObject(tutorialManager)
                                    .environmentObject(groupModeTutorial)
                        }
                    }
                    .sheet(isPresented: $router.showProfile, onDismiss: {
                        router.dismissProfile()
                    }) {
                        ProfileView()
                            .environmentObject(appState)
                            .environmentObject(router)
                            .environmentObject(tutorialManager)
                            .keyboardDoneToolbar()
                    }
                    .sheet(item: $router.showReceiptId) { receiptId in
                        NavigationView {
                            ReceiptView(receiptId: receiptId)
                                .environmentObject(appState)
                                .environmentObject(router)
                                .environmentObject(tutorialManager)
                        }
                        .keyboardDoneToolbar()
                    }
                    .sheet(isPresented: $router.showPaymentLanding) {
                        PaymentLandingSheet(
                            fromName: router.landingFromName,
                            toName: router.landingToName,
                            amount: router.landingAmount,
                            receiptId: router.landingReceiptId
                        )
                        .payeePaymentMethods(
                            venmoUsername: router.landingPayeeVenmoUsername,
                            venmoLink: router.landingPayeeVenmoLink,
                            zelleContact: router.landingPayeeZelleContact,
                            zelleLink: router.landingPayeeZelleLink
                        )
                        .environmentObject(appState)
                        .environmentObject(router)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .keyboardDoneToolbar()
                    }
                } else {
                    PaywallView(startsPaidImmediately: trialManager.hasStartedTrial, allowsDismiss: false)
                        .environmentObject(appState)
                }
            }
        }
        
        @ViewBuilder
        private func destinationView(for destination: String) -> some View {
            switch destination {
            case "upload":
                UploadView()
            case "people":
                PeopleView()
            case "processing":
                ProcessingView()
            case "review":
                ReviewView()
            case "settle":
                SettleShareView()
            default:
                UploadView()
            }
        }
    }
}

extension View {
    func keyboardDoneToolbar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(action: {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }) {
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
