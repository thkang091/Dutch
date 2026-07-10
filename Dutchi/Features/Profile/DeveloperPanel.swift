import SwiftUI

// MARK: - Dev gate

func isDeveloperPhone(_ phone: String?) -> Bool {
    guard let phone, !phone.isEmpty else { return false }
    let digits = phone.filter(\.isNumber)
    // Match regardless of country-code prefix format (+1, 1, or none)
    return [
        "2179746228",
        "2179746218",
        "7633216538"
    ].contains { digits.hasSuffix($0) }
}

// MARK: - DeveloperPanel

struct DeveloperPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var trial = TrialManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showResetAllConfirm = false
    @State private var ocrCreditInput: Int = 0
    @State private var confirmAction: ConfirmAction?
    @State private var remoteResetInput = ""
    @State private var remoteResetMessage = ""
    @State private var remoteUsers: [DevRemoteUser] = []
    @State private var selectedRemoteUserID: String?
    @State private var remoteUsersLoading = false
    @State private var remoteUserSearchText = ""

    private enum ConfirmAction: Identifiable {
        case resetAll, clearSub, resetTrial, clearGroups, resetRemoteUser
        var id: Int { hashValue }
        var title: String {
            switch self {
            case .resetAll:    return "Reset Everything?"
            case .clearSub:    return "Clear Subscription?"
            case .resetTrial:  return "Reset Trial?"
            case .clearGroups: return "Clear Group State?"
            case .resetRemoteUser: return "Reset Remote User?"
            }
        }
        var message: String {
            switch self {
            case .resetAll:    return "All trial, subscription, and group data will be erased. App will behave as a brand new install."
            case .clearSub:    return "Subscription data only is cleared. Trial state is kept."
            case .resetTrial:  return "Trial will be erased. You can start a fresh trial again."
            case .clearGroups: return "Owned and shared subscription group IDs will be cleared locally."
            case .resetRemoteUser: return "Verified user, member, subscription, and group membership records for the selected remote user will be removed."
            }
        }
    }

    private static let ink   = Color(red: 0.11, green: 0.10, blue: 0.08)
    private static let cream = Color(red: 1.00, green: 0.992, blue: 0.969)
    private static let parch = Color(red: 0.93, green: 0.91, blue: 0.87)

    private let ink   = DeveloperPanel.ink
    private let cream = DeveloperPanel.cream
    private let parch = DeveloperPanel.parch

    @State private var pickerDate: Date = Date()

    private var selectedRemoteUser: DevRemoteUser? {
        remoteUsers.first { $0.id == selectedRemoteUserID }
    }

    private var filteredRemoteUsers: [DevRemoteUser] {
        let query = remoteUserSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return remoteUsers }
        return remoteUsers.filter { user in
            [
                user.name,
                user.phoneNumber ?? "",
                user.phoneKey ?? "",
                user.uid ?? "",
                user.sourceSummary,
                user.groupSummary ?? ""
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
    }

    private var canResetRemoteUser: Bool {
        selectedRemoteUser != nil || !remoteResetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            ZStack {
                ink.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        overrideCard
                        simulatedDateCard
                        stateCard
                        trialCard
                        subscriptionCard
                        ocrCard
                        groupCard
                        dangerCard
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("DEVELOPER MODE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(cream.opacity(0.5))
                            .tracking(2)
                        Text("+1 (217) 974-6228 / 6218")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(cream.opacity(0.35))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(cream.opacity(0.6))
                    }
                }
            }
        }
        .onAppear {
            ocrCreditInput = trial.purchasedOCRCreditsRemaining
            loadRemoteUsers()
        }
        .confirmationDialog(
            confirmAction?.title ?? "",
            isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = confirmAction {
                Button(action.title.replacingOccurrences(of: "?", with: ""), role: .destructive) {
                    execute(action)
                }
                Button("Cancel", role: .cancel) { confirmAction = nil }
            }
        } message: {
            Text(confirmAction?.message ?? "")
        }
    }

    // MARK: - Override Status Card

    private var overrideCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FIREBASE SYNC")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(cream.opacity(0.35))
                .tracking(2)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(trial.devOverrideActive ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text(trial.devOverrideActive
                         ? "OVERRIDE ON — Firebase/RevenueCat writes blocked"
                         : "Normal sync — Firebase active")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(trial.devOverrideActive ? Color.orange.opacity(0.9) : Color.green.opacity(0.8))
                }
                if trial.devOverrideActive {
                    Button {
                        HapticManager.impact(style: .medium)
                        trial.devDisableOverride()
                    } label: {
                        Text("Disable Override")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color.orange.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                            .cornerRadius(2)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Button {
                        HapticManager.impact(style: .light)
                        trial.devSyncFromFirebase()
                    } label: {
                        Text("Pull from Firebase now")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color.green.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.green.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.green.opacity(0.2), lineWidth: 1))
                            .cornerRadius(2)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(14)
            .background(trial.devOverrideActive ? Color.orange.opacity(0.06) : cream.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(
                trial.devOverrideActive ? Color.orange.opacity(0.25) : cream.opacity(0.1), lineWidth: 1))
            .cornerRadius(2)
        }
    }

    // MARK: - Simulated Date Card

    private var simulatedDateCard: some View {
        let isOverriding = trial.devDateOverride != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SIMULATED DATE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(cream.opacity(0.35))
                    .tracking(2)
                Spacer()
                if isOverriding {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.yellow)
                        .tracking(1.5)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
                }
            }
            VStack(spacing: 10) {
                DatePicker("", selection: $pickerDate, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .colorScheme(.dark)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    devButton("SET DATE") {
                        trial.devDateOverride = pickerDate
                    }
                    devButton("CLEAR") {
                        trial.devDateOverride = nil
                        pickerDate = Date()
                    }
                }

                if let override = trial.devDateOverride {
                    HStack(spacing: 6) {
                        Circle().fill(Color.yellow).frame(width: 6, height: 6)
                        Text("Simulating: \(shortDate(override))")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.yellow.opacity(0.85))
                    }
                }
            }
            .padding(14)
            .background(isOverriding ? Color.yellow.opacity(0.05) : cream.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(
                isOverriding ? Color.yellow.opacity(0.3) : cream.opacity(0.1), lineWidth: 1))
            .cornerRadius(2)
        }
    }

    // MARK: - State Card

    private var stateCard: some View {
        devSection("CURRENT STATE") {
            devRow("Trial started",    value: trial.trialStartedAt.map(shortDate) ?? "none")
            devRow("Trial active",     value: trial.isTrialActive ? "YES (\(trial.daysRemaining)d left)" : "no")
            devRow("Sub started",      value: trial.subscriptionStartedAt.map(shortDate) ?? "none")
            devRow("Sub renews",       value: trial.subscriptionRenewsAt.map(shortDate) ?? "none")
            devRow("Sub active",       value: trial.hasActiveSubscription ? "YES" : "no")
            devRow("Plan",             value: trial.subscriptionPlanName ?? "–")
            devRow("Sub OCR remaining", value: trial.subscriptionOCRSessionsRemaining.map { "\($0)/\(trial.subscriptionOCRSessionLimit ?? 250)" } ?? "–")
            devRow("Trial OCR remain",  value: "\(trial.receiptOCRSessionsRemaining)/\(trial.maxReceiptOCRSessions)")
            devRow("Purchased credits", value: "\(trial.purchasedOCRCreditsRemaining)")
            devRow("Owned group",      value: trial.ownedSubscriptionGroupID?.uuidString.prefix(8).description ?? "none")
            devRow("Shared group",     value: trial.sharedSubscriptionGroupID?.uuidString.prefix(8).description ?? "none")
        }
    }

    // MARK: - Trial Card

    private var trialCard: some View {
        devSection("TRIAL") {
            devButton("Force Start Trial (now)") { trial.devForceTrialStart() }
            devButton("Reset Trial (erase)") { confirmAction = .resetTrial }
        }
    }

    // MARK: - Subscription Card

    private var subscriptionCard: some View {
        devSection("SUBSCRIPTION") {
            devButton("Force Active — 30 days") { trial.devForceSubscriptionActive(days: 30) }
            devButton("Force Active — 7 days")  { trial.devForceSubscriptionActive(days: 7) }
            devButton("Force Expired")           { trial.devForceSubscriptionExpired() }
            devButton("Clear Subscription")      { confirmAction = .clearSub }
        }
    }

    // MARK: - OCR Card

    private var ocrCard: some View {
        let subLimit   = trial.subscriptionOCRSessionLimit ?? 250
        let subRemain  = trial.subscriptionOCRSessionsRemaining ?? subLimit
        let trialRemain = trial.receiptOCRSessionsRemaining
        let trialLimit  = trial.maxReceiptOCRSessions

        return devSection("OCR — REMAINING CREDITS") {
            // Subscription OCR row
            ocrRowLabel("SUB OCR", current: subRemain, limit: subLimit)
            HStack(spacing: 6) {
                devButton("0 left",    compact: true) { trial.devSetSubscriptionOCRRemaining(0) }
                devButton("Half",      compact: true) { trial.devSetSubscriptionOCRRemaining(subLimit / 2) }
                devButton("Full",      compact: true) { trial.devSetSubscriptionOCRRemaining(subLimit) }
            }

            Rectangle().fill(cream.opacity(0.08)).frame(height: 1).padding(.vertical, 4)

            // Trial OCR row
            ocrRowLabel("TRIAL OCR", current: trialRemain, limit: trialLimit)
            HStack(spacing: 6) {
                devButton("0 left",  compact: true) { trial.devSetTrialOCRRemaining(0) }
                devButton("Half",    compact: true) { trial.devSetTrialOCRRemaining(trialLimit / 2) }
                devButton("Full",    compact: true) { trial.devSetTrialOCRRemaining(trialLimit) }
            }

            Rectangle().fill(cream.opacity(0.08)).frame(height: 1).padding(.vertical, 4)

            // Purchased credits
            HStack(spacing: 0) {
                Text("PURCHASED CREDITS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(cream.opacity(0.4))
                    .tracking(1.5)
                Spacer()
                devSmallButton("−") { ocrCreditInput = max(0, ocrCreditInput - 1) }
                Text("\(ocrCreditInput)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(cream)
                    .frame(width: 44, alignment: .center)
                devSmallButton("+") { ocrCreditInput += 1 }
                devButton("SET", compact: true) { trial.devSetOCRCredits(ocrCreditInput) }
            }
        }
    }

    private func ocrRowLabel(_ label: String, current: Int, limit: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(cream.opacity(0.4))
                .tracking(1.5)
            Spacer()
            Text("\(current)")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(current == 0 ? Color.red.opacity(0.8) : cream)
            Text("/\(limit)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(cream.opacity(0.4))
        }
    }

    // MARK: - Group Card

    private var groupCard: some View {
        devSection("GROUP STATE") {
            devButton("Clear Group IDs (local)") { confirmAction = .clearGroups }
        }
    }

    // MARK: - Danger Card

    private var dangerCard: some View {
        devSection("DANGER ZONE") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("REMOTE USER RESET")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(cream.opacity(0.35))
                        .tracking(1.5)
                    Spacer()
                    Button {
                        loadRemoteUsers()
                    } label: {
                        HStack(spacing: 5) {
                            if remoteUsersLoading {
                                ProgressView()
                                    .scaleEffect(0.65)
                                    .tint(cream.opacity(0.6))
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text("REFRESH")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(cream.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .disabled(remoteUsersLoading)
                }

                TextField("Search remote users", text: $remoteUserSearchText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .foregroundColor(cream)
                    .background(cream.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(cream.opacity(0.14), lineWidth: 1))
                    .cornerRadius(2)

                remoteUserList

                VStack(alignment: .leading, spacing: 6) {
                    Text("Manual fallback")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(cream.opacity(0.3))
                        .tracking(1.2)
                    TextField("UID or phone number", text: $remoteResetInput)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .foregroundColor(cream)
                        .background(cream.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(cream.opacity(0.1), lineWidth: 1))
                        .cornerRadius(2)
                }

                Button {
                    HapticManager.notification(type: .warning)
                    confirmAction = .resetRemoteUser
                } label: {
                    let label = selectedRemoteUser.map { "RESET \($0.name.uppercased())" } ?? "RESET MANUAL USER"
                    Text(label)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.red.opacity(canResetRemoteUser ? 0.95 : 0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.red.opacity(canResetRemoteUser ? 0.12 : 0.05))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.red.opacity(canResetRemoteUser ? 0.35 : 0.12), lineWidth: 1))
                        .cornerRadius(2)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(!canResetRemoteUser)

                if let selectedRemoteUser {
                    Text("Selected: \(selectedRemoteUser.subtitle)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(cream.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !remoteResetMessage.isEmpty {
                    Text(remoteResetMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(cream.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Rectangle().fill(cream.opacity(0.08)).frame(height: 1).padding(.vertical, 4)
            Button {
                HapticManager.notification(type: .warning)
                confirmAction = .resetAll
            } label: {
                Text("RESET EVERYTHING — NEW USER")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.red.opacity(0.4), lineWidth: 1.5))
                    .cornerRadius(2)
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }

    private var remoteUserList: some View {
        VStack(spacing: 6) {
            if remoteUsersLoading && remoteUsers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.75)
                        .tint(cream.opacity(0.65))
                    Text("Loading Firebase users…")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(cream.opacity(0.45))
                    Spacer()
                }
                .padding(10)
                .background(cream.opacity(0.05))
                .cornerRadius(2)
            } else if filteredRemoteUsers.isEmpty {
                Text(remoteUsers.isEmpty ? "No remote users loaded yet." : "No users match this search.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(cream.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(cream.opacity(0.05))
                    .cornerRadius(2)
            } else {
                ForEach(Array(filteredRemoteUsers.prefix(20))) { user in
                    remoteUserRow(user)
                }
                if filteredRemoteUsers.count > 20 {
                    Text("Showing first 20 of \(filteredRemoteUsers.count). Search to narrow.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(cream.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func remoteUserRow(_ user: DevRemoteUser) -> some View {
        let isSelected = selectedRemoteUserID == user.id
        return Button {
            selectedRemoteUserID = user.id
            remoteResetInput = user.resetIdentifier
            remoteResetMessage = ""
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? cream.opacity(0.9) : cream.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Text(String(user.name.prefix(2)).uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? ink : cream.opacity(0.72))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(user.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(cream.opacity(0.82))
                            .lineLimit(1)
                        if user.isOwner {
                            devTag("OWNER", color: .green)
                        }
                        if user.isPending {
                            devTag("PENDING", color: .orange)
                        }
                    }

                    Text(user.subtitle)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(cream.opacity(0.42))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(user.sourceSummary)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(cream.opacity(0.36))
                        .lineLimit(1)

                    if let groupSummary = user.groupSummary {
                        Text(groupSummary)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color.green.opacity(0.55))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isSelected ? Color.green.opacity(0.8) : cream.opacity(0.28))
            }
            .padding(10)
            .background(isSelected ? cream.opacity(0.11) : cream.opacity(0.055))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(isSelected ? Color.green.opacity(0.32) : cream.opacity(0.08), lineWidth: 1))
            .cornerRadius(2)
        }
        .buttonStyle(.plain)
    }

    private func devTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(color.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(2)
    }

    // MARK: - Helpers

    private func execute(_ action: ConfirmAction) {
        HapticManager.notification(type: .success)
        switch action {
        case .resetAll:    trial.devResetAll()
        case .clearSub:    trial.devClearSubscription()
        case .resetTrial:  trial.devResetTrial()
        case .clearGroups: trial.devClearGroupState()
        case .resetRemoteUser:
            resetSelectedRemoteUser()
        }
        confirmAction = nil
        ocrCreditInput = trial.purchasedOCRCreditsRemaining
    }

    private func loadRemoteUsers() {
        guard !remoteUsersLoading else { return }
        remoteUsersLoading = true
        remoteResetMessage = remoteUsers.isEmpty ? "" : remoteResetMessage
        trial.devFetchRemoteUsers { users, message in
            remoteUsers = users
            remoteUsersLoading = false
            if let message {
                remoteResetMessage = message
            } else if users.isEmpty {
                remoteResetMessage = "No remote users found."
            } else {
                remoteResetMessage = "Loaded \(users.count) remote \(users.count == 1 ? "user" : "users")."
            }
            if let selectedRemoteUserID,
               !users.contains(where: { $0.id == selectedRemoteUserID }) {
                self.selectedRemoteUserID = nil
            }
        }
    }

    private func resetSelectedRemoteUser() {
        let identifier = selectedRemoteUser?.resetIdentifier ?? remoteResetInput
        trial.devResetRemoteUser(identifier: identifier) { message in
            remoteResetMessage = message
            selectedRemoteUserID = nil
            remoteResetInput = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                loadRemoteUsers()
            }
        }
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: d)
    }

    private func devSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(cream.opacity(0.35))
                .tracking(2)
            VStack(spacing: 8) {
                content()
            }
            .padding(14)
            .background(cream.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(cream.opacity(0.1), lineWidth: 1))
            .cornerRadius(2)
        }
    }

    private func devRow(_ label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(cream.opacity(0.45))
                .frame(maxWidth: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(cream.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func devButton(_ label: String, compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { HapticManager.impact(style: .light); action() }) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(cream.opacity(0.8))
                .frame(maxWidth: compact ? nil : .infinity)
                .padding(.horizontal, compact ? 12 : 0)
                .padding(.vertical, 10)
                .background(cream.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(cream.opacity(0.15), lineWidth: 1))
                .cornerRadius(2)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func devSmallButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: { HapticManager.impact(style: .light); action() }) {
            Text(label)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(cream.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(cream.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(cream.opacity(0.12), lineWidth: 1))
                .cornerRadius(2)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
