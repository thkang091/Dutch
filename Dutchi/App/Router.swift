import SwiftUI
import Combine

@MainActor
class Router: ObservableObject {
    @Published var path = NavigationPath()
    @Published var showProfile = false
    @Published var showLogoIntro = true
    @Published var showGroupDetail: Bool = false
    @Published var showPaymentLanding = false
    @Published var showReceiptId: UUID? = nil
    @Published var landingFromName = ""
    @Published var landingToName = ""
    @Published var landingAmount = 0.0
    @Published var landingReceiptId = UUID()
    @Published var landingPaymentRequestId: String?
    @Published var landingPayeeVenmoUsername: String?
    @Published var landingPayeeVenmoLink: String?
    @Published var landingPayeeZelleContact: String?
    @Published var landingPayeeZelleLink: String?
    @Published var pendingBalanceHighlightItemID: String?
    
    // Group Mode Tutorial
    @Published var showGroupCreationSheet = false
    
    // Shared reference to group mode tutorial
    weak var groupModeTutorial: GroupModeTutorialManager?

    func presentProfile() {
        if showProfile {
            showProfile = false
            DispatchQueue.main.async { [weak self] in
                self?.showProfile = true
            }
        } else {
            showProfile = true
        }
    }

    func dismissProfile() {
        showProfile = false
    }
    
    func navigateToUpload() {
        path.append("upload")
    }
    
    func navigateToPeople() {
        path.append("people")
    }
    
    func navigateToProcessing() {
        path.append("processing")
    }
    
    func navigateToReview() {
        path.append("review")
    }
    
    func navigateToSettle() {
        print("🔄 Router.navigateToSettle() called")
        path.append("settle")
    }
    
    func navigateBack() {
        if !path.isEmpty {
            path.removeLast()
        }
    }
    
    func dismissLogoIntro() {
        showLogoIntro = false
    }
    
    func reset() {
        path = NavigationPath()
        showProfile = false
        showLogoIntro = false
        showGroupCreationSheet = false
        showReceiptId = nil
        landingPaymentRequestId = nil
        pendingBalanceHighlightItemID = nil
        ReceiptManager.shared.resetSession()
    }
    
    func resetToUpload() {
        path = NavigationPath()
        showProfile = false
        showGroupCreationSheet = false
        showReceiptId = nil
        landingPaymentRequestId = nil
    }
    
    func handleTutorialNavigation(for stepIndex: Int) {
        switch stepIndex {
        case 2:
            navigateToPeople()
        case 3, 4:
            navigateToReview()
        case 5, 6:
            break
        case 7:
            print("🔄 Router navigating to settle for step 7")
            navigateToSettle()
        default:
            break
        }
    }
    
    // Group Mode Tutorial methods
    func openGroupCreationSheet() {
        print("🔄 Router.openGroupCreationSheet() called")
        showGroupCreationSheet = true
    }
    
    func closeGroupCreationSheet() {
        print("🔄 Router.closeGroupCreationSheet() called")
        showGroupCreationSheet = false
    }
}

// Make UUID conform to Identifiable for sheet binding
extension UUID: Identifiable {
    public var id: UUID { self }
}
