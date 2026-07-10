import SwiftUI
import RevenueCat
import Combine
import UIKit
import StoreKit

// MARK: - Palette

private let ink   = Color(red: 0.11, green: 0.10, blue: 0.08)
private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
private let cream = Color(red: 1.00, green: 0.992, blue: 0.969)
private let parch = Color(red: 0.93, green: 0.91, blue: 0.87)

// MARK: - PaywallView

struct PaywallView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    let startsPaidImmediately: Bool
    let allowsDismiss: Bool
    let opensSubscriptionInvite: Bool
    let managedSubscriptionGroupID: UUID?

    @StateObject private var viewModel      = PaywallViewModel()
    @StateObject private var groupManager   = GroupManager.shared
    @StateObject private var trialManager   = TrialManager.shared
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared

    @State private var selectedGroupSize: GroupSize = .lite
    @State private var selectedPlan: PlanType = .monthly
    @State private var subscriptionInviteGroup: DutchieGroup?
    @State private var linkCopied = false
    @State private var isNamingFinalGroup = false
    @State private var isRenamingExistingGroup = false
    @State private var finalGroupName = ""
    @State private var didOpenInitialInvite = false
    @State private var inviteAccessCode = ""
    @State private var inviteAccessMessage = ""
    @State private var showTerms = false
    @State private var showPrivacy = false
    @State private var purchaseType: PurchaseType
    @State private var selectedCreditPack: CreditPackOption = .credits50
    @State private var didLoadStoreProducts = false
    @State private var invitePresentationSignature = ""
    @State private var invitePlanMembers: [GroupMember] = []
    @State private var inviteVisibleMembers: [GroupMember] = []
    @State private var inviteSplitGroups: [DutchieGroup] = []

    init(
        startsPaidImmediately: Bool = false,
        allowsDismiss: Bool = true,
        opensSubscriptionInvite: Bool = false,
        managedSubscriptionGroupID: UUID? = nil,
        initialPurchaseType: PurchaseType = .subscription
    ) {
        self.startsPaidImmediately = startsPaidImmediately
        self.allowsDismiss = allowsDismiss
        self._purchaseType = State(initialValue: initialPurchaseType)
        self.opensSubscriptionInvite = opensSubscriptionInvite
        self.managedSubscriptionGroupID = managedSubscriptionGroupID
    }

    var body: some View {
        NavigationView {
            ZStack {
                cream.ignoresSafeArea()

                if let subscriptionInviteGroup {
                    // Show invite page whenever a group has been prepared — regardless of how the paywall was opened
                    subscriptionInvitePage(for: groupManager.getGroup(by: subscriptionInviteGroup.id) ?? subscriptionInviteGroup)
                } else if opensSubscriptionInvite {
                    preparingInvitePage
                } else {
                    mainScroll
                }

                if viewModel.isLoading {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().tint(cream).scaleEffect(1.2)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if allowsDismiss {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            HapticManager.impact(style: .light)
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(ink)
                        }
                    }
                }
            }
        }
        .alert(viewModel.successTitle.isEmpty ? (chargesToday ? "Dutchi Pro Started" : "Trial Started") : viewModel.successTitle, isPresented: $viewModel.showSuccessAlert) {
            Button("Continue") { if viewModel.shouldDismissOnSuccess { dismiss() } }
        } message: {
            Text(viewModel.successMessage.isEmpty ? "Your credits are ready in Dutchi." : viewModel.successMessage)
        }
        .alert("Purchase Failed", isPresented: $viewModel.showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .onAppear {
            loadStoreProductsIfNeeded()
            selectCurrentPlanIfPossible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { openSubscriptionInviteIfRequested() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) { openSubscriptionInviteIfRequested() }
        }
        .onChange(of: trialManager.subscriptionPlanName) { _, _ in
            selectCurrentPlanIfPossible()
            if opensSubscriptionInvite { openSubscriptionInviteIfRequested() }
        }
        .onChange(of: groupManager.pendingInvite?.id) { _, id in
            if id != nil { dismiss() }
        }
        .onChange(of: groupManager.currentUserHasActiveGroupAccess) { _, hasAccess in
            // Don't dismiss if the invite page is being prepared after a fresh purchase
            if hasAccess && !opensSubscriptionInvite && subscriptionInviteGroup == nil { dismiss() }
        }
        .onReceive(groupManager.$allGroups) { groups in
            // Only sync when the invite page is intended or already visible
            guard opensSubscriptionInvite || subscriptionInviteGroup != nil else { return }
            if let mid = managedSubscriptionGroupID ?? subscriptionInviteGroup?.id,
               let synced = groups.first(where: { $0.id == mid }) {
                subscriptionInviteGroup = synced
                refreshInvitePresentationCache(for: synced)
            }
        }
    }

    // MARK: - Main scroll

    private var mainScroll: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {

                // ── Headline ──────────────────────────────────────────
                headlineSection
                paywallDash

                // ── Active plan banner (returning subscribers) ────────
                if trialManager.hasScheduledSubscription {
                    currentPlanBanner
                        .padding(.bottom, 20)
                    paywallDash
                }

                // ── Purchase type ─────────────────────────────────────
                purchaseTypeSection
                paywallDash

                // ── Billing cycle (subscription only) ─────────────────
                if purchaseType == .subscription {
                    billingCycleSection
                    paywallDash

                    // ── Group size ────────────────────────────────────
                    groupSizeSection
                    paywallDash
                }

                // ── Credit pack (credit pack only) ────────────────────
                if purchaseType == .creditPack {
                    creditPackSection
                    paywallDash
                }

                // ── Benefits ──────────────────────────────────────────
                benefitsSection

                // ── Closing ───────────────────────────────────────────
                closingSection
                paywallDash

                // ── CTA ───────────────────────────────────────────────
                ctaSection

                // ── Footer ────────────────────────────────────────────
                footerSection
                    .padding(.top, 32)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 56)
        }
    }

    // MARK: - Headline

    private var headlineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DUTCHIE PRO")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(ink.opacity(0.4))
                .tracking(3)

            Text("Tired of manually\ncalculating receipts?")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(ink)
                .lineSpacing(3)

            Text("Turn messy receipts, long PDFs, and bank statements into clean itemized splits in seconds.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(ink.opacity(0.7))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(headlineSubNote)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
    }

    // MARK: - Current plan banner

    private var currentPlanBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CURRENT PLAN")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ink.opacity(0.4))
                    .tracking(2)
                Text(trialManager.subscriptionPlanName ?? "Dutchie Pro")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ink)
            }
            Spacer()
            if isCurrentPlanSelected {
                Text("ACTIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ink.opacity(0.45))
                    .tracking(1.5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.2), lineWidth: 1))
            }
            }

            if canManageRecurringSubscription {
                Button {
                    HapticManager.impact(style: .light)
                    openSubscriptionManagement()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10, weight: .bold))
                        Text("MANAGE OR CANCEL SUBSCRIPTION")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(parch)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.97))
            }
        }
        .padding(14)
        .background(ivory)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.28), lineWidth: 1))
        .cornerRadius(2)
    }

    // MARK: - Purchase type

    private var purchaseTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("BILLING CYCLE")
            HStack(spacing: 0) {
                purchaseTypeTab(type: .subscription, label: "RECURRING")
                purchaseTypeTab(type: .creditPack, label: "CREDIT PACK")
            }
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.28), lineWidth: 1))
            .cornerRadius(2)
        }
        .padding(.vertical, 20)
    }

    private func purchaseTypeTab(type: PurchaseType, label: String) -> some View {
        let selected = purchaseType == type
        return Button {
            HapticManager.impact(style: .light)
            withAnimation(.easeInOut(duration: 0.15)) { purchaseType = type }
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundColor(selected ? cream : ink.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(selected ? ink : Color.clear)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: - Credit pack

    private var creditPackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("SELECT PACK")
            HStack(spacing: 10) {
                creditPackCard(.credits20)
                creditPackCard(.credits50)
            }
            creditPackCard(.credits75)
        }
        .padding(.vertical, 20)
    }

    private func creditPackCard(_ pack: CreditPackOption) -> some View {
        let rcPackage = viewModel.offerings?.current?.availablePackages
            .first(where: { pack.productIDs.contains($0.storeProduct.productIdentifier) })
        let livePrice = rcPackage?.storeProduct.localizedPriceString ?? pack.price
        let available = rcPackage != nil || viewModel.offerings == nil
        let selected = selectedCreditPack == pack
        return Button {
            guard available else { return }
            HapticManager.impact(style: .light)
            withAnimation(.easeInOut(duration: 0.15)) { selectedCreditPack = pack }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(pack.sizeName.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.5)
                        .foregroundColor(selected ? cream.opacity(0.75) : ink.opacity(available ? 0.6 : 0.3))
                    Spacer()
                    if let badge = pack.badge {
                        Text(badge)
                            .font(.system(size: 7, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(selected ? cream.opacity(0.85) : ink.opacity(0.55))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(selected ? cream.opacity(0.12) : ink.opacity(0.06))
                            .cornerRadius(2)
                    }
                    if !available {
                        Text("UNAVAILABLE")
                            .font(.system(size: 7, weight: .bold))
                            .tracking(0.5)
                            .foregroundColor(ink.opacity(0.3))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(ink.opacity(0.06))
                            .cornerRadius(2)
                    }
                }
                Text(livePrice)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(selected ? cream : ink.opacity(available ? 1.0 : 0.3))
                Text("one-time · \(pack.credits) credits")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selected ? cream.opacity(0.65) : ink.opacity(available ? 0.55 : 0.25))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(selected ? ink : ivory)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(selected ? 0.0 : (available ? 0.28 : 0.12)), lineWidth: 1.5))
            .cornerRadius(2)
            .opacity(available ? 1.0 : 0.6)
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!available)
    }

    // MARK: - Billing cycle

    private var billingCycleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("BILLING PERIOD")
            HStack(spacing: 0) {
                cycleTab(plan: .weekly,  label: "WEEKLY",  badge: nil)
                cycleTab(plan: .monthly, label: "MONTHLY", badge: nil)
                cycleTab(plan: .yearly,  label: "YEARLY",  badge: savingsPercentage)
            }
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.28), lineWidth: 1))
            .cornerRadius(2)
        }
        .padding(.vertical, 20)
    }

    private func cycleTab(plan: PlanType, label: String, badge: String?) -> some View {
        let selected = selectedPlan == plan
        return Button {
            HapticManager.impact(style: .light)
            withAnimation(.easeInOut(duration: 0.15)) { selectedPlan = plan }
        } label: {
            VStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundColor(selected ? cream : ink.opacity(0.75))
                if let badge {
                    Text(badge)
                        .font(.system(size: 7, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(selected ? cream.opacity(0.85) : ink.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(selected ? ink : Color.clear)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: - Group size

    private var groupSizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("GROUP SIZE")
            HStack(spacing: 10) {
                groupSizeCard(.lite)
                groupSizeCard(.group)
            }
        }
        .padding(.vertical, 20)
    }

    private func groupSizeCard(_ size: GroupSize) -> some View {
        let selected   = selectedGroupSize == size
        let groupPrice   = size.price(for: selectedPlan)
        let isYearly     = selectedPlan == .yearly
        let monthlyEquiv = groupPrice / 12.0
        let monthlyPrice = size.price(for: .monthly)
        let savingsPct   = Int(((monthlyPrice - monthlyEquiv) / monthlyPrice) * 100)
        let displayedTotalPrice = isYearly ? monthlyEquiv : groupPrice
        let displayedPeriodName = isYearly ? "month" : selectedPeriodName
        let perPersonPrice = displayedTotalPrice / Double(size.peopleCount)
        return Button {
            HapticManager.impact(style: .light)
            withAnimation(.easeInOut(duration: 0.15)) { selectedGroupSize = size }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(size.peopleCount) PEOPLE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.5)
                    .foregroundColor(selected ? cream.opacity(0.75) : ink.opacity(0.6))

                Text(formatPrice(displayedTotalPrice))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(selected ? cream : ink)

                Text("per \(displayedPeriodName) total")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(selected ? cream.opacity(0.68) : ink.opacity(0.58))

                Text("\(formatPrice(perPersonPrice)) per person per \(displayedPeriodName)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(selected ? cream.opacity(0.86) : ink.opacity(0.72))
                    .padding(.top, 2)

                if isYearly {
                    Text("billed yearly")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(selected ? cream.opacity(0.65) : ink.opacity(0.55))
                    Text("\(savingsPct)% cheaper than monthly")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(selected ? cream.opacity(0.8) : ink.opacity(0.65))
                        .tracking(0.3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(selected ? ink : ivory)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(selected ? 0.0 : 0.28), lineWidth: 1.5)
            )
            .cornerRadius(2)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    // MARK: - Benefits

    private var planCreditLabel: String {
        if purchaseType == .creditPack {
            return "\(selectedCreditPack.credits) credits · one-time"
        }
        switch (selectedGroupSize, selectedPlan) {
        case (.lite, .weekly):                    return "40 credits / week"
        case (.lite, .monthly), (.lite, .yearly): return "100 credits / month"
        case (_, .weekly):                        return "60 credits / week"
        default:                                  return "250 credits / month"
        }
    }

    private var benefitLines: [(String, String)] {
        [
            ("doc.text.viewfinder", "Turn **messy receipts**, **long PDF pages**, and **bank statements** into **clean, organized itemized splits**."),
            ("wand.and.stars", "Rewrite **confusing receipt items** into **plain language** so everyone understands what they are paying for."),
            ("sparkles", "\(planCreditLabel). **1 credit = 1 receipt image or 1 statement/PDF page**."),
            ("bolt", "Use **Quick Mode** to organize **large transactions** fast without manually sorting every item."),
            ("checklist", "Follow a **simple workflow**: **scan**, **review**, **assign**, and **done**."),
            ("link", "Set up **prefilled Venmo and Zelle requests** in **less than 15 seconds**."),
            ("person.2", "**Autofill people from your contacts** so you never have to type names manually."),
            ("message", "Send bills to friends by **text**, even if they do not have **Dutchi**."),
            ("list.bullet.rectangle", "Generate a **Dutch Receipt** that clearly shows **who paid**, **who owes**, and **why**."),
            ("tray.and.arrow.down", "**Save drafts** and **hold receipts** so you can come back and finish later.")
        ]
    }

    private func benefitText(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string)) ?? AttributedString(string)
    }

    private var benefitsSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(benefitLines.enumerated()), id: \.offset) { i, pair in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: pair.0)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ink.opacity(0.55))
                        .frame(width: 18, alignment: .center)
                        .padding(.top, 1)
                    Text(benefitText(pair.1))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Rectangle().fill(ink.opacity(0.10)).frame(height: 1).padding(.horizontal, 16)
            }
        }
        .background(ivory)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.28), lineWidth: 1.5))
        .cornerRadius(2)
        .padding(.vertical, 20)
    }

    // MARK: - Closing

    private var closingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stop spending time opening a calculator and splitting long bills across different friend groups.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Text("Scan once. Split cleanly. Get paid faster.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
    }

    // MARK: - CTA

    private var ctaSection: some View {
        VStack(spacing: 14) {
            // Trial note
            HStack(spacing: 6) {
                Rectangle().fill(ink.opacity(0.15)).frame(height: 1)
                Text(trialNoteText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ink.opacity(0.6))
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle().fill(ink.opacity(0.15)).frame(height: 1)
            }
            .padding(.bottom, 4)

            // Primary button
            Button {
                HapticManager.impact(style: .medium)
                handlePrimaryAction()
            } label: {
                HStack {
                    Text(primaryButtonTitle)
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1.5)
                        .foregroundColor(isCurrentPlanSelected ? ink.opacity(0.4) : cream)
                    if !isCurrentPlanSelected {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(cream.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(isCurrentPlanSelected ? parch : ink)
                .cornerRadius(2)
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(viewModel.isLoading || isCurrentPlanSelected)

            if canManageRecurringSubscription {
                Button {
                    HapticManager.impact(style: .light)
                    openSubscriptionManagement()
                } label: {
                    Text("Manage or cancel in Apple Subscriptions")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ink.opacity(0.65))
                        .underline()
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.97))
                .padding(.top, 2)
            }

        }
        .padding(.top, 20)
    }

    private var selectedCreditPackLivePrice: String {
        viewModel.offerings?.current?.availablePackages
            .first(where: { selectedCreditPack.productIDs.contains($0.storeProduct.productIdentifier) })?
            .storeProduct.localizedPriceString ?? selectedCreditPack.price
    }

    private var headlineSubNote: String {
        if purchaseType == .creditPack {
            return chargesToday ? "One-time · no subscription required." : "3 days free, then your credits are purchased automatically unless you cancel."
        }
        return chargesToday ? "Cancel anytime from Apple subscriptions." : "3 days free, no charge until trial ends."
    }

    private var trialNoteText: String {
        if purchaseType == .creditPack {
            if chargesToday { return "\(selectedCreditPackLivePrice) · \(selectedCreditPack.credits) credits · one-time" }
            return "free for 3 days, then \(selectedCreditPackLivePrice) for \(selectedCreditPack.credits) credits"
        }
        if chargesToday { return "\(currentPrice)/\(selectedPeriodName) · cancel anytime" }
        return "free for 3 days, then \(currentPrice)/\(selectedPeriodName)"
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 12) {
            Button {
                if networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to restore purchases.") {
                    viewModel.restorePurchases()
                }
            } label: {
                Text("Restore purchases")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ink.opacity(0.4))
                    .underline()
            }
            .disabled(viewModel.isLoading)

            HStack(spacing: 14) {
                Button { showTerms = true } label: {
                    Text("Terms of Use")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(ink.opacity(0.45))
                        .underline()
                }
                Text("·").foregroundColor(ink.opacity(0.2)).font(.system(size: 10))
                Button { showPrivacy = true } label: {
                    Text("Privacy Policy")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(ink.opacity(0.45))
                        .underline()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showTerms) { TermsOfUseView() }
        .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
    }

    // MARK: - Preparing page

    private var preparingInvitePage: some View {
        VStack(spacing: 14) {
            ProgressView().tint(ink)
            Text("Opening your plan")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Dashed divider

    private var paywallDash: some View {
        Rectangle()
            .fill(ink.opacity(0.18))
            .frame(height: 1.5)
    }


    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(ink.opacity(0.65))
            .tracking(2.5)
    }

    // MARK: - Computed helpers

    private var selectedPeriodName: String {
        switch selectedPlan {
        case .weekly:  return "week"
        case .monthly: return "month"
        case .yearly:  return "year"
        }
    }

    private var currentPriceValue: Double {
        switch selectedPlan {
        case .weekly:  return selectedGroupSize.price(for: .weekly)
        case .monthly: return selectedGroupSize.price(for: .monthly)
        case .yearly:  return selectedGroupSize.price(for: .yearly)
        }
    }

    private var currentPrice: String { formatPrice(currentPriceValue) }

    private var referenceMultipliedPrice: Double { currentPriceValue * Double(selectedGroupSize.peopleCount) }

    private var chargesToday: Bool { startsPaidImmediately || trialManager.hasStartedTrial }

    private var selectedPlanName: String { "\(selectedGroupSize.planName) \(selectedPlan.displayName)" }

    private var isCurrentPlanSelected: Bool {
        guard purchaseType == .subscription else { return false }
        guard trialManager.hasActiveSubscription else { return false }
        return selectedSubscriptionMatchesCurrentPlan
    }

    private var selectedSubscriptionMatchesCurrentPlan: Bool {
        let currentPlanName = (trialManager.subscriptionPlanName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentPlanName.isEmpty else { return false }

        if currentPlanName.caseInsensitiveCompare(selectedPlanName) == .orderedSame {
            return true
        }

        let current = currentPlanName.lowercased()
        let selectedPeriod = selectedPlan.displayName.lowercased()
        guard current.contains(selectedPeriod) else { return false }

        if let memberLimit = trialManager.subscriptionMemberLimit {
            return memberLimit == selectedGroupSize.peopleCount
        }

        switch selectedGroupSize {
        case .lite:
            return current.contains("3 people") || current.contains("3-person") || current.contains("lite")
        case .group, .house:
            return current.contains("6 people") ||
                current.contains("6-person") ||
                current.contains("group") ||
                current.contains("shared dutch")
        }
    }

    private var canManageRecurringSubscription: Bool {
        purchaseType == .subscription &&
        trialManager.hasScheduledSubscription &&
        !trialManager.hasSharedSubscriptionAccess
    }

    private var entitledGroupSize: GroupSize? {
        switch trialManager.subscriptionMemberLimit {
        case 3: return .lite
        case 6: return .group
        default: return nil
        }
    }

    private var entitledGroupPlanName: String {
        entitledGroupSize?.planName ?? selectedGroupSize.planName
    }

    private var savingsPercentage: String {
        let yearly   = selectedGroupSize.price(for: .yearly)
        let monthly  = selectedGroupSize.price(for: .monthly)
        let savings  = ((monthly * 12 - yearly) / (monthly * 12)) * 100
        return "SAVE \(Int(savings))%"
    }

    private var primaryButtonTitle: String {
        if purchaseType == .creditPack {
            if chargesToday {
                return "BUY \(selectedCreditPack.credits) CREDITS — \(selectedCreditPackLivePrice)"
            }
            return "START FREE TRIAL"
        }
        if isCurrentPlanSelected              { return "CURRENT PLAN" }
        if trialManager.hasActiveSubscription { return "CHANGE ON RENEWAL" }
        return chargesToday ? "START PRO TODAY" : "START FREE TRIAL"
    }

    private var currentScanAllowance: String {
        switch (selectedGroupSize, selectedPlan) {
        case (.lite, .weekly):                                              return "40 credits/week"
        case (.lite, .monthly), (.lite, .yearly):                          return "100 credits/month"
        case (.group, .weekly), (.house, .weekly):                         return "60 credits/week"
        case (.group, .monthly), (.group, .yearly),
             (.house, .monthly), (.house, .yearly):                        return "250 credits/month"
        }
    }

    private var renewalDateText: String {
        guard let renewsAt = trialManager.subscriptionRenewsAt else { return "your renewal date" }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: renewsAt)
    }

    private func authorizedInviteLimit(for requestedLimit: Int) -> Int {
        let sharedLimit = 6
        guard trialManager.hasScheduledSubscription || trialManager.hasActiveSubscription,
              let entitlementLimit = trialManager.subscriptionMemberLimit else {
            return min(requestedLimit, sharedLimit)
        }
        return min(requestedLimit, entitlementLimit, sharedLimit)
    }

    private func formatPrice(_ value: Double) -> String { String(format: "$%.2f", value) }

    private func openExternalURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }

    private func openSubscriptionManagement() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            openExternalURL("https://apps.apple.com/account/subscriptions")
            return
        }

        if #available(iOS 15.0, *) {
            Task {
                do {
                    try await AppStore.showManageSubscriptions(in: scene)
                } catch {
                    openExternalURL("https://apps.apple.com/account/subscriptions")
                }
            }
        } else {
            openExternalURL("https://apps.apple.com/account/subscriptions")
        }
    }

    private func loadStoreProductsIfNeeded(force: Bool = false) {
        guard force || !opensSubscriptionInvite else { return }
        guard force || !didLoadStoreProducts else { return }
        didLoadStoreProducts = true
        if networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to load subscription options.") {
            viewModel.loadOfferings()
        }
    }

    private func inviteSignature(for group: DutchieGroup) -> String {
        let memberSignature = group.members
            .map { "\($0.id.uuidString):\($0.name):\($0.phoneNumber ?? ""):\($0.isPending):\($0.hasLeft):\($0.isCurrentUser)" }
            .sorted()
            .joined(separator: "|")
        let splitGroupSignature = groupManager.currentUserSubscriptionInviteGroups
            .map { "\($0.id.uuidString):\($0.name):\($0.members.count):\($0.isSubscriptionInviteStaging)" }
            .sorted()
            .joined(separator: "|")
        return "\(group.id.uuidString):\(memberSignature):\(splitGroupSignature):\(trialManager.subscriptionMemberLimit ?? -1)"
    }

    private func refreshInvitePresentationCache(for group: DutchieGroup, force: Bool = false) {
        let signature = inviteSignature(for: group)
        guard force || signature != invitePresentationSignature else { return }
        invitePresentationSignature = signature
        invitePlanMembers = groupManager.subscriptionPlanRosterMembers(
            profile: appState.profile,
            currentPerson: appState.people.first(where: { $0.isCurrentUser }),
            including: group,
            hydrateContacts: false
        )
        inviteVisibleMembers = group.members
            .filter { !$0.hasLeft }
            .map(LocalContactNameStore.applyCached(to:))
            .sorted { lhs, rhs in
                if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
                if lhs.isPending     != rhs.isPending     { return !lhs.isPending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        inviteSplitGroups = groupManager.currentUserSubscriptionInviteGroups
            .filter { !$0.isSubscriptionInviteStaging }
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to start or manage Dutchie Pro.") else { return }

        // Credit pack: buy immediately or start trial
        if purchaseType == .creditPack {
            if chargesToday {
                viewModel.purchaseCreditPack(selectedCreditPack)
            } else {
                viewModel.purchaseTrialCreditPack(selectedCreditPack)
            }
            return
        }

        guard !trialManager.hasSharedSubscriptionAccess else { openSharedSubscriptionInvite(); return }

        let purchasedGroupSize = selectedGroupSize
        let purchasedPlan      = selectedPlan
        viewModel.purchaseSelected(
            groupSize:             purchasedGroupSize,
            plan:                  purchasedPlan,
            planName:              "\(purchasedGroupSize.planName) \(purchasedPlan.displayName)",
            scanAllowance:         currentScanAllowance,
            startsPaidImmediately: chargesToday
        ) {
            dismiss()
        }
    }

    private func handleInviteAccessCode() {
        guard let groupID = parseInviteGroupID(from: inviteAccessCode) else {
            inviteAccessMessage = "Paste the full invite link or the group code."
            return
        }
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to open this invite.") else { return }

        viewModel.isLoading = true
        groupManager.fetchGroupForInvite(groupID: groupID) { fetchedGroup in
            DispatchQueue.main.async {
                viewModel.isLoading = false
                guard let fetchedGroup else {
                    inviteAccessMessage = "We could not find that invite. Check the link and try again."
                    return
                }
                if userIsActiveMember(of: fetchedGroup) {
                    TrialManager.shared.joinSharedSubscriptionPlan(
                        groupID: fetchedGroup.id, groupName: fetchedGroup.name,
                        ownerPhone: fetchedGroup.members.first(where: { $0.id == fetchedGroup.createdByID })?.phoneNumber,
                        profile: appState.profile, fallbackMemberLimit: fetchedGroup.maxMemberCount
                    ) { success, message in
                        inviteAccessMessage = message ?? (success ? "Invite accepted." : "This invite is no longer available.")
                        if success {
                            groupManager.ensureSubscriptionGroupVisible(groupID: fetchedGroup.id, groupName: fetchedGroup.name, profile: appState.profile)
                            dismiss()
                        }
                    }
                    return
                }
                guard let phone = AuthManager.shared.phoneNumber ?? appState.profile.zelleContactInfo,
                      !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    inviteAccessMessage = "Verify your phone number first, then paste the invite again."
                    return
                }
                TrialManager.shared.joinSharedSubscriptionPlan(
                    groupID: fetchedGroup.id, groupName: fetchedGroup.name,
                    ownerPhone: fetchedGroup.members.first(where: { $0.id == fetchedGroup.createdByID })?.phoneNumber,
                    profile: appState.profile, fallbackMemberLimit: fetchedGroup.maxMemberCount
                ) { success, message in
                    guard success else { inviteAccessMessage = message ?? "This invite is no longer available."; return }
                    groupManager.ensureSubscriptionGroupVisible(groupID: fetchedGroup.id, groupName: fetchedGroup.name, profile: appState.profile)
                    groupManager.pendingInvite = nil
                    inviteAccessMessage = "Invite accepted."
                    dismiss()
                }
            }
        }
    }

    private func parseInviteGroupID(from value: String) -> UUID? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) { return uuid }
        if let url  = URL(string: trimmed),
           let comp = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let gid  = comp.queryItems?.first(where: { $0.name == "groupId" })?.value,
           let uuid = UUID(uuidString: gid) { return uuid }
        return nil
    }

    private func userIsActiveMember(of group: DutchieGroup) -> Bool {
        if group.members.contains(where: { $0.isCurrentUser && !$0.isPending && !$0.hasLeft }) { return true }
        guard let phone = AuthManager.shared.phoneNumber, !phone.isEmpty else { return false }
        let norm = normalizedPhoneForInvite(phone)
        return group.members.contains { m in
            guard !m.isPending, !m.hasLeft, let mp = m.phoneNumber else { return false }
            return normalizedPhoneForInvite(mp) == norm
        }
    }

    private func normalizedPhoneForInvite(_ phone: String) -> String {
        let d = phone.filter { $0.isNumber }
        if d.count == 10 { return "+1" + d }
        if d.count == 11, d.first == "1" { return "+" + d }
        if phone.hasPrefix("+") { return "+" + d }
        return d.isEmpty ? phone : "+" + d
    }

    private func prepareSubscriptionInvite(planName: String, maxMemberCount: Int, existingMembers: [GroupMember]) {
        guard !trialManager.hasSharedSubscriptionAccess else { openSharedSubscriptionInvite(); return }
        let currentPerson          = appState.people.first(where: { $0.isCurrentUser })
        let authorizedMaxMemberCount = authorizedInviteLimit(for: maxMemberCount)
        if let existingGroup = currentSubscriptionGroupForManagement() {
            subscriptionInviteGroup = groupManager.updateSubscriptionGroupPlan(
                groupID: existingGroup.id, maxMemberCount: authorizedMaxMemberCount,
                profile: appState.profile, currentPerson: currentPerson,
                existingMembers: existingMembers.isEmpty ? existingGroup.members : existingMembers
            ) ?? existingGroup
        } else {
            subscriptionInviteGroup = groupManager.createSubscriptionInviteGroup(
                planName: planName, maxMemberCount: authorizedMaxMemberCount,
                profile: appState.profile, currentPerson: currentPerson, existingMembers: existingMembers
            )
        }
        if let group = subscriptionInviteGroup {
            refreshInvitePresentationCache(for: group, force: true)
        }
        if let group = subscriptionInviteGroup {
            trialManager.activateOwnedSubscriptionGroup(groupID: group.id, groupName: group.name)
            trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: group.id, groupName: group.name, isOwner: true)
        }
        finalGroupName     = subscriptionInviteGroup?.isSubscriptionInviteStaging == true ? "" : subscriptionInviteGroup?.name ?? ""
        isNamingFinalGroup = subscriptionInviteGroup?.isSubscriptionInviteStaging == true
        isRenamingExistingGroup = false
    }

    private func currentSubscriptionMembersForChange() -> [GroupMember] {
        if let id = managedSubscriptionGroupID, let g = groupManager.getGroup(by: id) { return g.members }
        if let s = groupManager.currentUserSubscriptionInviteGroups.first { return s.members }
        if let c = groupManager.currentUserAvailableGroups.first(where: { $0.maxMemberCount != nil }) { return c.members }
        if let a = groupManager.activeGroup, a.maxMemberCount != nil { return a.members }
        return []
    }

    private func currentSubscriptionGroupForManagement() -> DutchieGroup? {
        if trialManager.hasSharedSubscriptionAccess {
            return trialManager.sharedSubscriptionGroupID.flatMap { groupManager.getGroup(by: $0) }
        }
        let ownedGroupID = trialManager.ownedSubscriptionGroupID
        if let mid = managedSubscriptionGroupID, mid == ownedGroupID,
           let g = groupManager.getGroup(by: mid), !g.members.isEmpty { return g }
        let group = groupManager.currentUserSubscriptionInviteGroups.first { $0.maxMemberCount != nil && $0.id == ownedGroupID }
            ?? groupManager.currentUserAvailableGroups.first { $0.maxMemberCount != nil }
            ?? groupManager.activeGroup.flatMap { $0.maxMemberCount != nil ? $0 : nil }
        guard let group, ownedGroupID == nil || group.id == ownedGroupID else { return nil }
        return group
    }

    private func openSubscriptionInviteIfRequested() {
        guard opensSubscriptionInvite, !didOpenInitialInvite else { return }
        didOpenInitialInvite = true
        if trialManager.hasSharedSubscriptionAccess {
            openSharedSubscriptionInvite()
            return
        }
        if let group = currentSubscriptionGroupForManagement() {
            subscriptionInviteGroup = group
            refreshInvitePresentationCache(for: group, force: true)
            return
        }
        if let mid = managedSubscriptionGroupID {
            groupManager.refreshGroupFromFirebase(groupID: mid) { fetched in
                DispatchQueue.main.async {
                    guard let fetched else { return }
                    subscriptionInviteGroup = fetched
                    refreshInvitePresentationCache(for: fetched, force: true)
                }
            }
            return
        }
        guard trialManager.hasScheduledSubscription || trialManager.hasProAccess else { return }
        prepareSubscriptionInvite(
            planName: entitledGroupPlanName,
            maxMemberCount: trialManager.subscriptionMemberLimit ?? selectedGroupSize.peopleCount,
            existingMembers: currentSubscriptionMembersForChange()
        )
    }

    private func openSharedSubscriptionInvite() {
        guard let sharedGroupID = trialManager.sharedSubscriptionGroupID else { return }
        if let group = groupManager.getGroup(by: sharedGroupID) {
            subscriptionInviteGroup = group
            refreshInvitePresentationCache(for: group, force: true)
            return
        }
        guard networkMonitor.isOnline else { return }
        viewModel.isLoading = true
        groupManager.refreshGroupFromFirebase(groupID: sharedGroupID) { fetched in
            DispatchQueue.main.async {
                viewModel.isLoading = false
                guard let fetched else { return }
                subscriptionInviteGroup = fetched
                refreshInvitePresentationCache(for: fetched, force: true)
            }
        }
    }

    private func refreshManagedSubscriptionGroupIfNeeded(force: Bool = false) {
        guard let mid = managedSubscriptionGroupID else { return }
        guard force || subscriptionInviteGroup?.members.isEmpty == true else { return }
        guard networkMonitor.isOnline else { return }
        groupManager.refreshGroupFromFirebase(groupID: mid) { fetched in
            DispatchQueue.main.async {
                guard let fetched else { return }
                subscriptionInviteGroup = fetched
                refreshInvitePresentationCache(for: fetched, force: true)
            }
        }
    }

    private func selectCurrentPlanIfPossible() {
        guard let planName = trialManager.subscriptionPlanName?.lowercased() else { return }
        if      planName.contains("3 people") || planName.contains("lite")  { selectedGroupSize = .lite }
        else if planName.contains("6 people") || planName.contains("group") { selectedGroupSize = .group }
        if      planName.contains("weekly")  { selectedPlan = .weekly }
        else if planName.contains("yearly")  { selectedPlan = .yearly }
        else if planName.contains("monthly") { selectedPlan = .monthly }
    }

    // MARK: - Subscription invite page

    private func subscriptionInvitePage(for group: DutchieGroup) -> some View {
        let planLimit        = trialManager.subscriptionMemberLimit ?? group.maxMemberCount ?? selectedGroupSize.peopleCount
        let planMembers      = invitePlanMembers
        let allSubGroups     = inviteSplitGroups
        let occupiedSeats    = min(planMembers.count, planLimit)
        let remainingSlots   = max(0, planLimit - occupiedSeats)
        let shareText        = subscriptionInviteMessage(for: group)
        let needsInitialName    = group.isSubscriptionInviteStaging
        let isEditingGroupName  = isNamingFinalGroup || isRenamingExistingGroup
        let canManagePlanMembers = currentUserOwnsSubscriptionGroup(group)
        let visibleMembers = inviteVisibleMembers.isEmpty
            ? group.members.filter { !$0.hasLeft }
            : inviteVisibleMembers

        return ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {

                // Header
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("YOUR PLAN")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(ink.opacity(0.35))
                                .tracking(2.5)
                            Text("Invite Your Group")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(ink)
                        }
                        Spacer()
                        Text("\(occupiedSeats)/\(planLimit)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(ink.opacity(0.55))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1))
                    }

                    // Group name
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("GROUP NAME")
                        if isEditingGroupName {
                            TextField("e.g. Roommates, Chicago Trip", text: $finalGroupName)
                                .font(.system(size: 18, weight: .bold))
                                .padding(14)
                                .background(ivory)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.2), lineWidth: 1))
                                .cornerRadius(2)
                                .submitLabel(.done)
                        } else {
                            HStack(spacing: 10) {
                                Text(group.name)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(ink)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if canManagePlanMembers {
                                    Button("Rename") {
                                        HapticManager.impact(style: .light)
                                        finalGroupName = group.name
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isRenamingExistingGroup = true }
                                    }
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(ink.opacity(0.55))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.2), lineWidth: 1))
                                }
                            }
                        }
                    }

                    Text(remainingSlots == 0
                         ? "All seats are filled."
                         : "\(remainingSlots) \(remainingSlots == 1 ? "seat" : "seats") open — share the link to add someone.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ink.opacity(0.5))
                }
                .padding(.top, 20)

                paywallDash

                // Members
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("MEMBERS")
                    if planMembers.isEmpty && visibleMembers.isEmpty {
                        Text("No one has joined yet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(ink.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(planMembers.isEmpty ? visibleMembers : planMembers) { member in
                            subscriptionMemberRow(member, group: group)
                        }
                    }
                }
                .padding(14)
                .background(ivory)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.12), lineWidth: 1))
                .cornerRadius(2)

                // Invite link
                if remainingSlots > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("INVITE LINK")
                        Text(group.inviteLink)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(ink.opacity(0.65))
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ivory)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.1), lineWidth: 1))
                            .cornerRadius(2)
                    }
                }

                if !inviteAccessMessage.isEmpty {
                    Text(inviteAccessMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ink.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // ── Split Groups ──────────────────────────────────────
                if canManagePlanMembers {
                    splitGroupsSection(
                        allGroups: allSubGroups,
                        currentGroup: group,
                        totalLimit: planLimit,
                        totalUsed: occupiedSeats
                    )
                }

                // Action buttons
                VStack(spacing: 10) {
                    if remainingSlots > 0 {
                        ShareLink(item: shareText) {
                            Text("SHARE INVITE")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(1.5)
                                .foregroundColor(cream)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(ink)
                                .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle())

                        Button {
                            UIPasteboard.general.string = group.inviteLink
                            linkCopied = true
                            HapticManager.notification(type: .success)
                        } label: {
                            Text(linkCopied ? "LINK COPIED" : "COPY LINK")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(1.5)
                                .foregroundColor(ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(ScaleButtonStyle())

                        Button { joinSubscriptionGroupFromPlanSheet(group) } label: {
                            Text("JOIN THIS GROUP")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(1.5)
                                .foregroundColor(cream)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(ink)
                                .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }

                    if isEditingGroupName {
                        Button { saveInviteGroupName(group) } label: {
                            Text(needsInitialName ? "CREATE GROUP" : "SAVE NAME")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(1.5)
                                .foregroundColor(cream)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(ink)
                                .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    } else {
                        Button {
                            HapticManager.impact(style: .medium)
                            if needsInitialName {
                                finalGroupName = defaultFinalGroupName(for: group)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isNamingFinalGroup = true }
                            } else {
                                HapticManager.notification(type: .success)
                                dismiss()
                            }
                        } label: {
                            Text(canManagePlanMembers
                                 ? (needsInitialName
                                    ? (group.isInviteFull ? "VERIFY & NAME GROUP" : "VERIFY MEMBERS")
                                    : "SAVE CHANGES")
                                 : "DONE")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(1.5)
                                .foregroundColor(cream)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(ink)
                                .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }

                    Button(isEditingGroupName ? "Keep current name" : "Done for now") {
                        if isEditingGroupName {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isNamingFinalGroup = false; isRenamingExistingGroup = false
                            }
                            finalGroupName = group.name
                        } else {
                            dismiss()
                        }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(ink.opacity(0.4))
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .onAppear {
            refreshInvitePresentationCache(for: group)
            refreshManagedSubscriptionGroupIfNeeded(force: visibleMembers.isEmpty && planMembers.isEmpty)
        }
    }

    private func subscriptionMemberRow(_ member: GroupMember, group: DutchieGroup) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ink).frame(width: 32, height: 32)
                Text(member.initials)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(cream)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(member.isCurrentUser ? "\(member.name) (You)" : member.name)
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(ink)
                Text(member.isPending ? "Invited · not joined" : "Joined")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(member.isPending ? Color.orange : Color(red: 0.22, green: 0.56, blue: 0.35))
            }
            Spacer()
            if currentUserOwnsSubscriptionGroup(group), !member.isCurrentUser, member.isPending, group.maxMemberCount != nil {
                Button {
                    HapticManager.impact(style: .light)
                    groupManager.removeMemberFromSubscriptionInvite(groupID: group.id, memberID: member.id)
                    subscriptionInviteGroup = groupManager.getGroup(by: group.id) ?? group
                } label: {
                    Text("Remove")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ink.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Split groups panel

    @ViewBuilder
    private func splitGroupsSection(
        allGroups: [DutchieGroup],
        currentGroup: DutchieGroup,
        totalLimit: Int,
        totalUsed: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SPLIT GROUPS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(ink.opacity(0.4))
                        .tracking(2.5)
                    Text("Use the same \(totalLimit) plan seats across any group")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ink.opacity(0.55))
                }
                Spacer()
                Text("\(totalUsed)/\(totalLimit)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ink.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1))
            }

            ForEach(allGroups) { g in
                let activeCount = g.members.filter { !$0.hasLeft }.count
                let isCurrent   = g.id == currentGroup.id
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ink)
                        Text("\(activeCount) member\(activeCount == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ink.opacity(0.5))
                    }
                    Spacer()
                    if isCurrent {
                        Text("VIEWING")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(ink.opacity(0.4))
                            .tracking(1.5)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1))
                    } else {
                        Button {
                            HapticManager.impact(style: .light)
                            subscriptionInviteGroup = g
                        } label: {
                            Text("SWITCH")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(cream)
                                .tracking(1.5)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(ink)
                                .cornerRadius(2)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(12)
                .background(isCurrent ? ink.opacity(0.04) : ivory)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(isCurrent ? 0.2 : 0.12), lineWidth: 1))
                .cornerRadius(2)
            }

            Button {
                HapticManager.impact(style: .medium)
                createSplitGroup()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("ADD SPLIT GROUP")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                }
                .foregroundColor(ink.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.22), lineWidth: 1.5))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(14)
        .background(cream)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1.5))
        .cornerRadius(2)
    }

    private func createSplitGroup() {
        let currentPerson = appState.people.first(where: { $0.isCurrentUser })
        let newGroup = groupManager.createSubscriptionInviteGroup(
            planName: trialManager.subscriptionPlanName ?? "Dutchi Pro",
            maxMemberCount: trialManager.subscriptionMemberLimit ?? selectedGroupSize.peopleCount,
            profile: appState.profile,
            currentPerson: currentPerson,
            existingMembers: []
        )
        trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: newGroup.id, groupName: newGroup.name, isOwner: true)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            subscriptionInviteGroup = newGroup
            isNamingFinalGroup = true
            finalGroupName = ""
        }
    }

    private func currentUserOwnsSubscriptionGroup(_ group: DutchieGroup) -> Bool {
        !trialManager.hasSharedSubscriptionAccess && group.maxMemberCount != nil
    }

    private func defaultFinalGroupName(for group: DutchieGroup) -> String {
        group.name.contains("Share") ? "" : group.name
    }

    private func finalizeInviteGroup(_ group: DutchieGroup) {
        guard currentUserOwnsSubscriptionGroup(group) else { return }
        guard let finalized = groupManager.finalizeSubscriptionInviteGroup(groupID: group.id, name: finalGroupName) else { return }
        subscriptionInviteGroup = finalized
        trialManager.activateOwnedSubscriptionGroup(groupID: finalized.id, groupName: finalized.name)
        trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: finalized.id, groupName: finalized.name, isOwner: true)
        HapticManager.notification(type: .success)
        dismiss()
    }

    private func saveInviteGroupName(_ group: DutchieGroup) {
        guard currentUserOwnsSubscriptionGroup(group) else { HapticManager.notification(type: .success); dismiss(); return }
        if group.isSubscriptionInviteStaging { finalizeInviteGroup(group); return }
        guard let renamed = groupManager.renameSubscriptionGroup(groupID: group.id, name: finalGroupName) else { return }
        subscriptionInviteGroup = renamed
        trialManager.activateOwnedSubscriptionGroup(groupID: renamed.id, groupName: renamed.name)
        isRenamingExistingGroup = false
        HapticManager.notification(type: .success)
        dismiss()
    }

    private func joinSubscriptionGroupFromPlanSheet(_ group: DutchieGroup) {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to join this group.") else { return }
        inviteAccessMessage = "Joining group..."
        if currentUserOwnsSubscriptionGroup(group) {
            trialManager.activateOwnedSubscriptionGroup(groupID: group.id, groupName: group.name)
            trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: group.id, groupName: group.name, isOwner: true)
            groupManager.ensureSubscriptionGroupVisible(groupID: group.id, groupName: group.name, profile: appState.profile, activate: true)
            subscriptionInviteGroup = groupManager.getGroup(by: group.id) ?? group
            inviteAccessMessage = "Group is ready in Group Mode."
            HapticManager.notification(type: .success)
            return
        }
        guard AuthManager.shared.isAuthenticated,
              let phone = AuthManager.shared.phoneNumber ?? appState.profile.zelleContactInfo,
              !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            inviteAccessMessage = "Verify your phone number first, then join this group."
            return
        }
        TrialManager.shared.joinSharedSubscriptionPlan(
            groupID: group.id, groupName: group.name,
            ownerPhone: group.members.first(where: { $0.id == group.createdByID })?.phoneNumber,
            profile: appState.profile, fallbackMemberLimit: group.maxMemberCount
        ) { success, message in
            guard success else { inviteAccessMessage = message ?? "This invite is no longer available."; HapticManager.notification(type: .error); return }
            groupManager.ensureSubscriptionGroupVisible(groupID: group.id, groupName: group.name, profile: appState.profile, activate: true)
            subscriptionInviteGroup = groupManager.getGroup(by: group.id) ?? group
            inviteAccessMessage = "Group joined."
            HapticManager.notification(type: .success)
        }
    }

    private func subscriptionInviteMessage(for group: DutchieGroup) -> String {
        let planLimit = trialManager.subscriptionMemberLimit ?? group.maxMemberCount ?? selectedGroupSize.peopleCount
        return """
        Join my Dutch plan "\(group.name)".

        Dutch invite link (full link):
        \(group.inviteLink)

        The link works until all \(planLimit) seats are filled.
        """
    }
}

// MARK: - Supporting Views (unchanged)

struct PlanButton: View {
    let title: String
    let isSelected: Bool
    var badge: String = ""
    var showBadge: Bool = false
    let action: () -> Void

    private let ink   = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let cream = Color(red: 1.00, green: 0.992, blue: 0.969)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title).font(.system(size: 10, weight: .bold)).tracking(1)
                if showBadge {
                    Text(badge).font(.system(size: 7, weight: .bold)).tracking(0.8)
                        .foregroundColor(isSelected ? cream : ink)
                }
            }
            .foregroundColor(isSelected ? cream : ink.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, showBadge ? 8 : 12)
            .background(isSelected ? ink : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.3), lineWidth: 1))
            .cornerRadius(2)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

struct TimelineItem: View {
    let icon: String
    let title: String
    let description: String
    var isFirst: Bool = false
    var isLast: Bool = false

    private let ink   = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let cream = Color(red: 1.00, green: 0.992, blue: 0.969)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                if !isFirst { Rectangle().fill(ink.opacity(0.2)).frame(width: 2, height: 16) }
                ZStack {
                    Circle().fill(ink).frame(width: 36, height: 36)
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(cream)
                }
                if !isLast { Rectangle().fill(ink.opacity(0.2)).frame(width: 2, height: 32) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(ink)
                Text(description).font(.system(size: 13, weight: .medium)).foregroundColor(ink.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, isFirst ? 8 : 0).padding(.bottom, 8)
            Spacer()
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(ink).frame(width: 20)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

// MARK: - Models

enum CreditPackOption: CaseIterable, Identifiable {
    case credits20, credits50, credits75
    var id: String { productIDs.first ?? sizeName }
    var credits: Int { switch self { case .credits20: return 20; case .credits50: return 50; case .credits75: return 75 } }
    var sizeName: String { switch self { case .credits20: return "Small"; case .credits50: return "Medium"; case .credits75: return "Large" } }
    var price: String { switch self { case .credits20: return "$0.99"; case .credits50: return "$1.99"; case .credits75: return "$2.99" } }
    var priceValue: Double { switch self { case .credits20: return 0.99; case .credits50: return 1.99; case .credits75: return 2.99 } }
    var badge: String? {
        switch self {
        case .credits50:  return "BEST VALUE"
        case .credits75:  return "BEST FOR TRIPS"
        default: return nil
        }
    }
    var productIDs: [String] {
        switch self {
        case .credits20:  return ["trial_credits_20", "credits_20_trial", "credit_pack_20_trial", "credits_20", "credit_pack_20", "20_credits"]
        case .credits50:  return ["trial_credits_50", "credits_50_trial", "credit_pack_50_trial", "credits_50", "credit_pack_50", "50_credits"]
        case .credits75:  return ["trial_credits_75", "credits_75_trial", "credit_pack_75_trial", "credits_75", "credit_pack_75", "75_credits"]
        }
    }

    var trialProductIDs: [String] {
        productIDs.filter { $0.localizedCaseInsensitiveContains("trial") }
    }
}

enum PurchaseType { case subscription, creditPack }

enum GroupPassOption: CaseIterable, Identifiable {
    case weekly, monthly, yearly
    var id: String { planName }
    var title: String { switch self { case .weekly: return "Weekly Group Pass"; case .monthly: return "Monthly Group"; case .yearly: return "Yearly Group" } }
    var price: String { switch self { case .weekly: return "$1.99 / 7 days"; case .monthly: return "$7.99/mo"; case .yearly: return "$59.99/year" } }
    var badge: String? { switch self { case .weekly: return nil; case .monthly: return "BEST VALUE"; case .yearly: return nil } }
    var creditsText: String { switch self { case .weekly: return "60 credits"; case .monthly, .yearly: return "250 credits/mo" } }
    var memberLimit: Int { 6 }
    var details: [String] { [creditsText, "Up to 6 people", "1 active group"] }
    var planName: String { title }
    var scanAllowance: String { switch self { case .weekly: return "60 credits/week"; case .monthly, .yearly: return "250 credits/month" } }
    var productIDs: [String] {
        switch self {
        case .weekly:  return ["weekly_group_pass", "weekly_6people", "weekly_subscription", "weekly_3people"]
        case .monthly: return ["monthly_group", "monthly_6people", "monthly_3people"]
        case .yearly:  return ["yearly_group", "yearly_6people", "yearly_3people"]
        }
    }
}

enum GroupSize {
    case lite, group, house
    var peopleCount: Int { switch self { case .lite: return 3; case .group, .house: return 6 } }
    var planName: String { switch self { case .lite: return "3 People"; case .group, .house: return "6 People" } }
    func price(for plan: PlanType) -> Double {
        switch (self, plan) {
        case (.lite,  .weekly):                    return 1.99
        case (.lite,  .monthly):                   return 3.99
        case (.lite,  .yearly):                    return 29.99
        case (.group, .weekly), (.house, .weekly): return 3.99
        case (.group, .monthly),(.house, .monthly):return 7.99
        case (.group, .yearly), (.house, .yearly): return 59.99
        }
    }
}

enum PlanType {
    case weekly, monthly, yearly
    var displayName: String { switch self { case .weekly: return "Weekly"; case .monthly: return "Monthly"; case .yearly: return "Yearly" } }
}

// MARK: - ViewModel

@MainActor
class PaywallViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var showSuccessAlert = false
    @Published var showErrorAlert = false
    @Published var successTitle = ""
    @Published var successMessage = ""
    @Published var shouldDismissOnSuccess = true
    @Published var errorMessage = ""
    @Published var isProMember = false
    @Published var offerings: Offerings?

    func loadOfferings() {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to load subscription options.") else { return }
        guard Purchases.isConfigured else { print("⚠️ RevenueCat not configured"); return }
        isLoading = true
        Purchases.shared.getOfferings { [weak self] offerings, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let error = error { print("Error loading offerings: \(error.localizedDescription)"); return }
                self?.offerings = offerings
                self?.checkSubscriptionStatus()
            }
        }
    }

    func checkSubscriptionStatus() {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to check your subscription status.") else { return }
        Purchases.shared.getCustomerInfo { [weak self] customerInfo, error in
            DispatchQueue.main.async {
                if let error = error { print("Error fetching customer info: \(error.localizedDescription)"); return }
                TrialManager.shared.refreshSubscriptionStatusFromStore()
                self?.isProMember = customerInfo?.entitlements.all["pro"]?.isActive == true
            }
        }
    }

    func purchaseCreditPack(_ pack: CreditPackOption) {
        purchaseConsumableProductIDs(pack.productIDs, credits: pack.credits)
    }

    func purchaseTrialCreditPack(_ pack: CreditPackOption) {
        purchaseTrialBackedCreditProductIDs(
            pack.trialProductIDs,
            credits: pack.credits
        )
    }

    func purchaseProductIDs(_ productIds: [String], planName: String, scanAllowance: String, startsPaidImmediately: Bool, onSuccess: (() -> Void)? = nil) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to start this plan.") else { return }
        guard let offerings = offerings, let offering = offerings.current else {
            errorMessage = "No offers available. Please try again later."; showErrorAlert = true; return
        }
        guard let package = offering.availablePackages.first(where: { productIds.contains($0.storeProduct.productIdentifier) }) else {
            errorMessage = "Selected option is not available yet."; showErrorAlert = true; return
        }
        purchase(package: package, planName: planName, scanAllowance: scanAllowance, startsPaidImmediately: startsPaidImmediately, onSuccess: onSuccess)
    }

    private func purchaseConsumableProductIDs(_ productIds: [String], credits: Int) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to buy credits.") else { return }
        guard let offerings = offerings, let offering = offerings.current else {
            errorMessage = "No credit packs available. Please try again later."; showErrorAlert = true; return
        }
        guard let package = offering.availablePackages.first(where: { productIds.contains($0.storeProduct.productIdentifier) }) else {
            errorMessage = "Selected credit pack is not available yet."; showErrorAlert = true; return
        }
        isLoading = true
        Purchases.shared.purchase(package: package) { [weak self] transaction, _, error, userCancelled in
            DispatchQueue.main.async {
                self?.isLoading = false
                if userCancelled { return }
                if let error { self?.errorMessage = error.localizedDescription; self?.showErrorAlert = true; return }
                guard transaction != nil else { self?.errorMessage = "Purchase could not be verified."; self?.showErrorAlert = true; return }
                TrialManager.shared.addPurchasedOCRCredits(credits)
                self?.successTitle   = "Credits Added"
                self?.successMessage = "\(credits) OCR credits were added to your account."
                self?.shouldDismissOnSuccess = true
                self?.showSuccessAlert = true
                HapticManager.notification(type: .success)
            }
        }
    }

    private func purchaseTrialBackedCreditProductIDs(_ productIds: [String], credits: Int) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to start this credit trial.") else { return }
        guard let offerings = offerings, let offering = offerings.current else {
            errorMessage = "No trial credit packs are available. Please try again later."; showErrorAlert = true; return
        }
        guard let package = offering.availablePackages.first(where: { productIds.contains($0.storeProduct.productIdentifier) }) else {
            errorMessage = "This credit pack needs a 3-day trial product in RevenueCat before it can be offered. Add a trial-backed product such as \(productIds.first ?? "credits_trial") to the current offering."
            showErrorAlert = true
            return
        }

        purchase(
            package: package,
            planName: "\(credits) Credit Pack",
            scanAllowance: "\(credits) credits",
            startsPaidImmediately: false
        ) { [weak self] in
            self?.successTitle = "Trial Started"
            self?.successMessage = "Your \(credits) credits will be purchased automatically after the 3-day trial unless you cancel."
            self?.shouldDismissOnSuccess = true
            self?.showSuccessAlert = true
        }
    }

    func purchaseSelected(groupSize: GroupSize, plan: PlanType, planName: String, scanAllowance: String, startsPaidImmediately: Bool, onSuccess: (() -> Void)? = nil) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to start or manage Dutchie Pro.") else { return }
        guard let offerings = offerings, let offering = offerings.current else {
            errorMessage = "No offers available. Please try again later."; showErrorAlert = true; return
        }
        let productIds: [String]
        switch (groupSize, plan) {
        case (.lite,  .weekly):                    productIds = ["weekly_3people", "weekly_subscription"]
        case (.lite,  .monthly):                   productIds = ["monthly_3people"]
        case (.lite,  .yearly):                    productIds = ["yearly_3people"]
        case (.group, .weekly), (.house, .weekly): productIds = ["weekly_group_pass", "weekly_6people", "weekly_subscription"]
        case (.group, .monthly),(.house, .monthly):productIds = ["monthly_group", "monthly_6people"]
        case (.group, .yearly), (.house, .yearly): productIds = ["yearly_group", "yearly_6people"]
        }
        guard let package = offering.availablePackages.first(where: { productIds.contains($0.storeProduct.productIdentifier) }) else {
            errorMessage = "Selected plan is not available."; showErrorAlert = true; return
        }
        purchase(package: package, planName: planName, scanAllowance: scanAllowance, startsPaidImmediately: startsPaidImmediately, onSuccess: onSuccess)
    }

    func purchase(package: Package, planName: String, scanAllowance: String, startsPaidImmediately: Bool, onSuccess: (() -> Void)? = nil) {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to start or manage Dutchie Pro.") else { return }
        isLoading = true
        Purchases.shared.purchase(package: package) { [weak self] transaction, customerInfo, error, userCancelled in
            DispatchQueue.main.async {
                self?.isLoading = false
                if userCancelled { return }
                if let error = error { self?.errorMessage = error.localizedDescription; self?.showErrorAlert = true; return }
                let hasActiveEntitlement  = customerInfo?.entitlements.active.isEmpty == false
                let hasActiveSubscription = customerInfo?.activeSubscriptions.isEmpty == false
                let hasCompletedTx        = transaction != nil
                if hasActiveEntitlement || hasActiveSubscription || hasCompletedTx {
                    self?.isProMember = true
                    let trialEndsAt = TrialManager.shared.trialEndsAt ?? Calendar.current.date(byAdding: .day, value: TrialManager.shared.trialDurationDays, to: Date())
                    let startsAt    = startsPaidImmediately ? Date() : (trialEndsAt ?? Date())
                    TrialManager.shared.activateSubscription(planName: planName, scanAllowance: scanAllowance, startsAt: startsAt, renewsAt: customerInfo?.latestExpirationDate)
                    HapticManager.notification(type: .success)
                    if let onSuccess { onSuccess() } else {
                        self?.successTitle   = startsPaidImmediately ? "Dutchie Pro Started" : "Trial Started"
                        self?.successMessage = startsPaidImmediately
                            ? "Your subscription is active."
                            : "Your plan starts automatically after the 3-day trial unless you cancel."
                        self?.shouldDismissOnSuccess = true
                        self?.showSuccessAlert = true
                    }
                } else {
                    self?.errorMessage = "Purchase could not be verified. Please try Restore Purchases."; self?.showErrorAlert = true
                }
            }
        }
    }

    func restorePurchases() {
        guard NetworkStatusMonitor.shared.requireOnline(message: "Turn on Wi-Fi or cellular data to restore purchases.") else { return }
        isLoading = true
        Purchases.shared.restorePurchases { [weak self] customerInfo, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let error = error { self?.errorMessage = error.localizedDescription; self?.showErrorAlert = true; return }
                if let entitlements = customerInfo?.entitlements.all["pro"], entitlements.isActive {
                    self?.isProMember = true
                    TrialManager.shared.activateSubscription(planName: "Dutchie Pro", scanAllowance: "Pro limit", renewsAt: customerInfo?.latestExpirationDate)
                    self?.successTitle   = "Purchases Restored"
                    self?.successMessage = "Your active Dutchie Pro subscription has been restored."
                    self?.shouldDismissOnSuccess = false
                    self?.showSuccessAlert = true
                    HapticManager.notification(type: .success)
                } else {
                    self?.errorMessage = "No active subscriptions found."; self?.showErrorAlert = true
                }
            }
        }
    }
}

// MARK: - Preview

struct PaywallView_Previews: PreviewProvider {
    static var previews: some View { PaywallView() }
}
