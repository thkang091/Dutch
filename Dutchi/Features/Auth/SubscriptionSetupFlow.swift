import SwiftUI
import Contacts
import FirebaseAuth
import MessageUI

// MARK: - Pending group model

private struct PendingGroupEntry: Identifiable {
    let id = UUID()
    var name: String = ""
    var contacts: [CNContact] = []
}

// MARK: - SubscriptionSetupFlow

struct SubscriptionSetupFlow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var authManager: AuthManager
    @StateObject private var trialManager = TrialManager.shared
    @StateObject private var groupManager = GroupManager.shared
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared

    let onComplete: () -> Void

    @AppStorage("dutchie.onboardingInviteDone") private var inviteStepDone = false
    @AppStorage("dutchie.onboardingGroupModeTutorialRequired") private var onboardingGroupModeTutorialRequired = false

    private enum Step { case phoneVerification, nameAndInvite }
    @State private var step: Step

    // Phone verification
    @State private var phoneNumber = ""
    @State private var verificationCode = ""
    @FocusState private var isPhoneFocused: Bool
    @FocusState private var isCodeFocused: Bool

    // Multi-group naming
    @State private var pendingGroups: [PendingGroupEntry] = [PendingGroupEntry()]
    @State private var isCreatingGroups = false
    @State private var contactPickerTargetID: UUID? = nil
    @State private var showContactPicker = false
    @State private var addContactError: String? = nil

    // Invite phase
    @State private var createdGroups: [DutchieGroup] = []
    @State private var copiedGroupID: UUID? = nil
    @State private var smsSendQueue: [(phone: String, msg: String)] = []
    @State private var composePayload: MessageComposePayload?

    private let ink   = Color(red: 0.15, green: 0.15, blue: 0.15)
    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let parch = Color(red: 0.96, green: 0.96, blue: 0.94)

    init(authManager: AuthManager, onComplete: @escaping () -> Void) {
        self.authManager = authManager
        self.onComplete  = onComplete
        self._step = State(initialValue: authManager.isAuthenticated ? .nameAndInvite : .phoneVerification)
    }

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            switch step {
            case .phoneVerification:
                phoneStep
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            case .nameAndInvite:
                nameAndInviteStep
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth && step == .phoneVerification {
                HapticManager.notification(type: .success)
                withAnimation { step = .nameAndInvite }
            }
        }
        .sheet(isPresented: $showContactPicker) {
            SearchableContactPickerView { contacts in
                guard let targetID = contactPickerTargetID,
                      let idx = pendingGroups.firstIndex(where: { $0.id == targetID }) else { return }
                var blocked: [String] = []
                for contact in contacts {
                    let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    let seatKey = contactSeatKey(for: contact)
                    let isAlreadyInTargetGroup = pendingGroups[idx].contacts.contains { contactSeatKey(for: $0) == seatKey }
                    let isAlreadyInAnotherGroup = pendingGroups.enumerated().contains { groupIndex, group in
                        groupIndex != idx && group.contacts.contains { contactSeatKey(for: $0) == seatKey }
                    }
                    if isAlreadyInTargetGroup || isAlreadyInAnotherGroup {
                        blocked.append(name.isEmpty ? "Contact" : name)
                        continue
                    }
                    if selectedInviteSeatKeys.count >= inviteSlots {
                        blocked.append(name.isEmpty ? "Contact" : name)
                        continue
                    }
                    if let phone = contact.phoneNumbers.first?.value.stringValue {
                        LocalContactNameStore.save(
                            name: name,
                            phoneNumber: phone,
                            imageData: contact.dutchSafeImageData
                        )
                    }
                    pendingGroups[idx].contacts.append(contact)
                }
                if !blocked.isEmpty {
                    let names = blocked.joined(separator: ", ")
                    let verb = blocked.count == 1 ? "was" : "were"
                    addContactError = "Your plan includes \(inviteSlots) invited \(inviteSlots == 1 ? "person" : "people") total, and each person can only be in one new group — \(names) \(verb) not added."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { addContactError = nil }
                }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard !smsSendQueue.isEmpty else { return }
            let next = smsSendQueue.removeFirst()
            sendSMS(to: next.phone, message: next.msg)
        }
    }

    // MARK: - Step 1: Phone Verification

    private var phoneStep: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 32) {
                    progressHeader(current: 1, total: 2, title: "Verify Your Number")
                    VStack(spacing: 16) {
                        if !isAwaitingCode {
                            phoneField
                            securityNote
                        } else {
                            codeField
                            changePhoneButton
                        }
                        if let error = authManager.errorMessage { errorBanner(error) }
                    }
                    .padding(.horizontal, 24)
                    Spacer(minLength: 40)
                }
            }
            bottomButton(
                label: isAwaitingCode ? "VERIFY CODE" : "SEND CODE",
                icon:  isAwaitingCode ? "checkmark"   : "arrow.right",
                enabled: phoneCanProceed && !authManager.isBusy
            ) {
                HapticManager.impact(style: .medium)
                if isAwaitingCode { Task { await verifyCode() } }
                else              { Task { await sendCode()  } }
            }
        }
        .overlay(loadingOverlay(show: authManager.isBusy, awaitingCode: isAwaitingCode))
        .onAppear { isPhoneFocused = true }
    }

    // MARK: - Step 2: Name & Invite

    private let addGroupAnchorID = "add_group_anchor"

    private var nameAndInviteStep: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 28) {
                    progressHeader(current: 2, total: 2, title: "Name & Invite")
                    if showInvitePhase { invitePhaseContent }
                    else               { namingPhaseContent(proxy: proxy)  }
                    Spacer(minLength: 40)
                }
            }
            } // ScrollViewReader
            if showInvitePhase {
                bottomButton(label: "GET STARTED", icon: "arrow.right", enabled: true) {
                    HapticManager.notification(type: .success)
                    onboardingGroupModeTutorialRequired = true
                    inviteStepDone = true
                    onComplete()
                }
            } else {
                bottomButton(
                    label: isCreatingGroups ? "CREATING..." : (pendingGroups.count > 1 ? "CREATE GROUPS" : "CREATE GROUP"),
                    icon:  isCreatingGroups ? "hourglass"   : "checkmark",
                    enabled: atLeastOneGroupValid && inviteSelectionIsValid && !isCreatingGroups
                ) { createAllGroups() }
            }
        }
        .overlay(isCreatingGroups ? Color.black.opacity(0.15).ignoresSafeArea() : nil)
    }

    private var showInvitePhase: Bool {
        !createdGroups.isEmpty || trialManager.ownedSubscriptionGroupID != nil
    }

    // MARK: - Naming phase

    private func namingPhaseContent(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Error toast for contact limit
            if let error = addContactError {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.minus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red.opacity(0.85))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07))
                .cornerRadius(2)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.red.opacity(0.2), lineWidth: 1))
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.25), value: addContactError)
            }

            ForEach(Array(pendingGroups.enumerated()), id: \.element.id) { idx, group in
                pendingGroupCard(index: idx)
                    .padding(.horizontal, 24)
            }

            // Add another group — visible at bottom; scroll reveals it
            Button {
                HapticManager.impact(style: .light)
                withAnimation {
                    pendingGroups.append(PendingGroupEntry())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation { proxy.scrollTo(addGroupAnchorID, anchor: .bottom) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ink)
                    Text("ADD ANOTHER GROUP")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(parch)
                .cornerRadius(2)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.25), lineWidth: 1.5))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 24)
            .id(addGroupAnchorID)

            planNote
                .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func pendingGroupCardHeader(entryID: UUID, index: Int, isOnly: Bool, usedSlots: Int, label: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.5)
                .foregroundColor(ink.opacity(0.45))
            Spacer()
            Text("\(selectedInviteSeatKeys.count)/\(inviteSlots) plan seats")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundColor(ink.opacity(0.35))
            if !isOnly {
                Button {
                    withAnimation { pendingGroups.removeAll { $0.id == entryID } }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(ink.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .background(ink.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func pendingGroupAddButton(entry: PendingGroupEntry, atLimit: Bool) -> some View {
        Button {
            HapticManager.impact(style: .light)
            contactPickerTargetID = entry.id
            showContactPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ink)
                Text(atLimit ? "Add Plan Contacts" : "Add from Contacts")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.3)
                    .foregroundColor(ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(ink.opacity(0.35))
            }
            .padding(12)
            .background(parch)
            .cornerRadius(2)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func pendingGroupCard(index: Int) -> some View {
        let entry = pendingGroups[index]
        let isOnly = pendingGroups.count == 1
        let usedSlots = entry.contacts.count
        let label = pendingGroups.count > 1 ? "GROUP \(index + 1)" : "YOUR GROUP"
        let atLimit = selectedInviteSeatKeys.count >= inviteSlots

        return VStack(alignment: .leading, spacing: 12) {
            pendingGroupCardHeader(entryID: entry.id, index: index, isOnly: isOnly, usedSlots: usedSlots, label: label)

            TextField("Group name (e.g. Roommates, Trip)", text: Binding(
                get: { pendingGroups[index].name },
                set: { pendingGroups[index].name = $0 }
            ))
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(ink)
            .padding(14)
            .background(parch)
            .cornerRadius(2)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.2) as Color, lineWidth: 1.5))
            .submitLabel(.done)

            pendingGroupAddButton(entry: entry, atLimit: atLimit)

            if !pendingGroups[index].contacts.isEmpty {
                VStack(spacing: 6) {
                    ForEach(pendingGroups[index].contacts, id: \.identifier) { contact in
                        namingContactRow(contact: contact, groupIndex: index)
                    }
                }
            }
        }
        .padding(14)
        .background(ivory)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ink.opacity(0.12) as Color, lineWidth: 1.5))
    }

    private func namingContactRow(contact: CNContact, groupIndex: Int) -> some View {
        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        let phone = contact.phoneNumbers.first?.value.stringValue

        return HStack(spacing: 10) {
            if let data = contact.dutchSafeImageData, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 32, height: 32).clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(ink.opacity(0.1)).frame(width: 32, height: 32)
                    Text(String(contact.givenName.prefix(1)))
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(ink)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(fullName.isEmpty ? "Unknown" : fullName)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(ink)
                if let phone {
                    Text(phone).font(.system(size: 10, weight: .medium)).foregroundColor(ink.opacity(0.45))
                }
            }
            Spacer()
            Button {
                let seatKey = contactSeatKey(for: contact)
                pendingGroups[groupIndex].contacts.removeAll { contactSeatKey(for: $0) == seatKey }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(ink.opacity(0.45))
                    .frame(width: 24, height: 24).background(ink.opacity(0.07)).clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(10)
        .background(parch)
        .cornerRadius(2)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.08), lineWidth: 1))
    }

    private var planNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(ink.opacity(0.35))
            Text("Create as many groups as you need. Your plan includes the same \(inviteSlots) invited \(inviteSlots == 1 ? "person" : "people") across all groups.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ink.opacity(0.4))
        }
    }

    // MARK: - Invite phase

    private var invitePhaseContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            let groups = liveGroups
            if groups.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().tint(ink)
                    Text("Loading your groups…")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(ink.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                    inviteGroupSection(group: group, groupNumber: idx + 1, totalGroups: groups.count)
                }
            }
        }
    }

    private func inviteGroupSection(group: DutchieGroup, groupNumber: Int, totalGroups: Int) -> some View {
        let idx = groupNumber - 1
        let groupContacts: [CNContact] = idx < pendingGroups.count ? pendingGroups[idx].contacts : []
        let phoneContacts = groupContacts.filter { !($0.phoneNumbers.first?.value.stringValue ?? "").isEmpty }
        let isCopied = copiedGroupID == group.id
        let memberTarget = group.maxMemberCount ?? groupContacts.count + 1
        let joinedCount = min(max(1, group.activeMemberCount), memberTarget)

        return VStack(alignment: .leading, spacing: 12) {
            // Group header
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(ink)
                Text(group.name)
                    .font(.system(size: 17, weight: .bold)).foregroundColor(ink)
                Spacer()
                if totalGroups > 1 {
                    Text("GROUP \(groupNumber)")
                        .font(.system(size: 9, weight: .bold)).tracking(1.0).foregroundColor(ink.opacity(0.4))
                }
                Text("\(joinedCount)/\(memberTarget)")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(ink.opacity(0.5))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1))
            }
            .padding(14)
            .background(parch)
            .cornerRadius(2)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.1), lineWidth: 1))

            // Messaging actions
            if !groupContacts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("INVITE CONTACTS")

                    // Message All / Send One by One
                    if phoneContacts.count > 1 {
                        HStack(spacing: 8) {
                            Button {
                                HapticManager.impact(style: .medium)
                                messageAll(contacts: phoneContacts, group: group)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("MESSAGE ALL")
                                        .font(.system(size: 11, weight: .bold)).tracking(0.6)
                                }
                                .foregroundColor(ivory)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(ink).cornerRadius(2)
                            }
                            .buttonStyle(ScaleButtonStyle())

                            Button {
                                HapticManager.impact(style: .light)
                                startSequentialSend(contacts: phoneContacts, group: group)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("ONE BY ONE")
                                        .font(.system(size: 11, weight: .bold)).tracking(0.6)
                                }
                                .foregroundColor(ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.25), lineWidth: 1.5))
                                .cornerRadius(2)
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }
                    }

                    // Individual contact rows
                    VStack(spacing: 6) {
                        ForEach(groupContacts, id: \.identifier) { contact in
                            inviteContactRow(contact: contact, group: group)
                        }
                    }
                }
            }

            // Invite link
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("INVITE LINK")
                Text(group.inviteLink)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ink.opacity(0.6))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(parch)
                    .cornerRadius(2)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.1), lineWidth: 1))

                HStack(spacing: 8) {
                    ShareLink(item: inviteMessage(for: group)) {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .bold))
                            Text("SHARE LINK").font(.system(size: 11, weight: .bold)).tracking(0.6)
                        }
                        .foregroundColor(ivory)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(ink).cornerRadius(2)
                    }
                    .buttonStyle(ScaleButtonStyle())

                    Button {
                        UIPasteboard.general.string = group.inviteLink
                        copiedGroupID = group.id
                        HapticManager.notification(type: .success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if copiedGroupID == group.id { copiedGroupID = nil }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .bold))
                            Text(isCopied ? "COPIED" : "COPY LINK")
                                .font(.system(size: 11, weight: .bold)).tracking(0.6)
                        }
                        .foregroundColor(ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.22), lineWidth: 1.5))
                        .cornerRadius(2)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
        }
        .padding(16)
        .background(ivory)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ink.opacity(0.12), lineWidth: 1.5))
        .padding(.horizontal, 24)
    }

    private func inviteContactRow(contact: CNContact, group: DutchieGroup) -> some View {
        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        let phone = contact.phoneNumbers.first?.value.stringValue

        return HStack(spacing: 10) {
            if let data = contact.dutchSafeImageData, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 32, height: 32).clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(ink.opacity(0.1)).frame(width: 32, height: 32)
                    Text(String(contact.givenName.prefix(1)))
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(ink)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(fullName.isEmpty ? "Unknown" : fullName)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(ink)
                if let phone {
                    Text(phone).font(.system(size: 10, weight: .medium)).foregroundColor(ink.opacity(0.45))
                }
            }
            Spacer()
            if let phone {
                Button { sendSMS(to: phone, message: inviteMessage(for: group)) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "message.fill").font(.system(size: 10, weight: .bold))
                        Text("MSG").font(.system(size: 10, weight: .bold)).tracking(0.3)
                    }
                    .foregroundColor(ivory)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(ink).cornerRadius(2)
                }
                .buttonStyle(ScaleButtonStyle())
            } else {
                ShareLink(item: inviteMessage(for: group)) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 10, weight: .bold))
                        Text("SHARE").font(.system(size: 10, weight: .bold)).tracking(0.3)
                    }
                    .foregroundColor(ink)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.3), lineWidth: 1))
                    .cornerRadius(2)
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(10)
        .background(parch)
        .cornerRadius(2)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Computed helpers

    private var inviteSlots: Int { max(1, (trialManager.subscriptionMemberLimit ?? 3) - 1) }
    private var selectedInviteSeatKeys: Set<String> {
        Set(pendingGroups.flatMap(\.contacts).map { contactSeatKey(for: $0) })
    }
    private var totalSelectedInviteCount: Int {
        pendingGroups.flatMap(\.contacts).count
    }
    private var hasDuplicateInviteContacts: Bool {
        totalSelectedInviteCount != selectedInviteSeatKeys.count
    }
    private var inviteSelectionIsValid: Bool {
        totalSelectedInviteCount <= inviteSlots && !hasDuplicateInviteContacts
    }
    private var atLeastOneGroupValid: Bool {
        pendingGroups.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var liveGroups: [DutchieGroup] {
        if !createdGroups.isEmpty { return createdGroups }
        if let id = trialManager.ownedSubscriptionGroupID, let g = groupManager.getGroup(by: id) { return [g] }
        return []
    }

    // MARK: - Phone step subviews

    private var phoneField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("PHONE NUMBER")
            TextField("(555) 123-4567", text: $phoneNumber)
                .font(.system(size: 18, weight: .medium))
                .keyboardType(.phonePad)
                .foregroundColor(ink)
                .padding(16)
                .background(parch)
                .cornerRadius(2)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(isPhoneFocused ? ink : ink.opacity(0.2), lineWidth: 1.5))
                .focused($isPhoneFocused)
        }
    }

    private var securityNote: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(ink)
            VStack(alignment: .leading, spacing: 2) {
                Text("Security Check Required")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(ink)
                Text("Complete a quick verification to prove you're human")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(ink.opacity(0.6))
            }
            Spacer()
        }
        .padding(14)
        .background(parch)
        .cornerRadius(2)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.15), lineWidth: 1))
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("VERIFICATION CODE")
            TextField("000000", text: $verificationCode)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(ink)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .padding(20)
                .background(parch)
                .cornerRadius(2)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(isCodeFocused ? ink : ink.opacity(0.2), lineWidth: 1.5))
                .focused($isCodeFocused)
                .onChange(of: verificationCode) { _, v in
                    if v.count == 6 { Task { await verifyCode() } }
                }
        }
    }

    private var changePhoneButton: some View {
        Button {
            authManager.resetVerificationState()
            verificationCode = ""
        } label: {
            Text("Change Phone Number")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ink.opacity(0.6))
                .underline()
        }
    }

    // MARK: - Actions

    private var isAwaitingCode: Bool {
        if case .awaitingCode = authManager.authState { return true }
        return false
    }

    private var phoneCanProceed: Bool {
        isAwaitingCode
            ? verificationCode.count == 6
            : !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendCode() async {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi to verify your phone number.") else { return }
        await authManager.sendVerificationCode(to: phoneNumber)
    }

    private func verifyCode() async {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi to verify your phone number.") else { return }
        await authManager.verifyCode(verificationCode)
    }

    private func createAllGroups() {
        guard atLeastOneGroupValid, !isCreatingGroups else { return }
        guard inviteSelectionIsValid else {
            HapticManager.notification(type: .error)
            if hasDuplicateInviteContacts {
                addContactError = "Each invited person can only be in one new group. Remove duplicate contacts before creating groups."
            } else {
                addContactError = "Your plan includes \(inviteSlots) invited \(inviteSlots == 1 ? "person" : "people") total. Remove extra contacts before creating groups."
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { addContactError = nil }
            return
        }
        HapticManager.impact(style: .medium)
        isCreatingGroups = true
        let currentPerson = appState.people.first(where: { $0.isCurrentUser })
        var first = true

        for entry in pendingGroups {
            let trimmed = entry.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Size this group to the people selected for it. The Firebase
            // subscription pool still enforces the shared recurring-plan seats
            // across every group.
            let maxCount = max(2, entry.contacts.count + 1)
            let invitedMembers = pendingMembers(from: entry.contacts)
            let staging = groupManager.createSubscriptionInviteGroup(
                planName:       trialManager.subscriptionPlanName ?? "Dutch Pro",
                maxMemberCount: maxCount,
                profile:        appState.profile,
                currentPerson:  currentPerson,
                existingMembers: invitedMembers
            )
            if first {
                trialManager.activateOwnedSubscriptionGroup(groupID: staging.id, groupName: trimmed)
                first = false
            }
            trialManager.syncCurrentSubscriptionMember(
                profile: appState.profile, groupID: staging.id, groupName: trimmed, isOwner: true
            )
            trialManager.syncPendingSubscriptionInviteMembers(invitedMembers, groupID: staging.id, sourceGroupID: staging.id)
            if let finalized = groupManager.finalizeSubscriptionInviteGroup(groupID: staging.id, name: trimmed) {
                for member in invitedMembers {
                    groupManager.addPendingMember(member, to: finalized.id)
                }
                createdGroups.append(finalized)
            } else {
                for member in invitedMembers {
                    groupManager.addPendingMember(member, to: staging.id)
                }
                createdGroups.append(staging)
            }
        }

        if !createdGroups.isEmpty {
            onboardingGroupModeTutorialRequired = true
        }

        HapticManager.notification(type: .success)
        isCreatingGroups = false
    }

    private func messageAll(contacts: [CNContact], group: DutchieGroup) {
        let phones = uniqueInvitePhones(from: contacts)
        guard !phones.isEmpty else { return }

        let message = inviteMessage(for: group)
        if MFMessageComposeViewController.canSendText() {
            composePayload = MessageComposePayload(recipients: phones, body: message)
        } else if let firstPhone = phones.first {
            sendSMS(to: firstPhone, message: message)
        }
    }

    private func uniqueInvitePhones(from contacts: [CNContact]) -> [String] {
        var seen = Set<String>()
        var phones: [String] = []

        for contact in contacts {
            guard let rawPhone = contact.phoneNumbers.first?.value.stringValue else { continue }
            let digits = rawPhone.filter(\.isNumber)
            guard !digits.isEmpty, seen.insert(digits).inserted else { continue }
            phones.append(rawPhone)
        }

        return phones
    }

    private func startSequentialSend(contacts: [CNContact], group: DutchieGroup) {
        let msg = inviteMessage(for: group)
        smsSendQueue = contacts.compactMap { contact in
            guard let phone = contact.phoneNumbers.first?.value.stringValue else { return nil }
            return (phone: phone, msg: msg)
        }
        guard !smsSendQueue.isEmpty else { return }
        let first = smsSendQueue.removeFirst()
        sendSMS(to: first.phone, message: first.msg)
    }

    private func sendSMS(to phone: String, message: String) {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        let encoded = smsBodyEncoded(message)
        if let url = URL(string: "sms:\(digits)&body=\(encoded)") ?? URL(string: "sms:\(digits)") {
            UIApplication.shared.open(url)
        }
    }

    private func contactSeatKey(for contact: CNContact) -> String {
        if let phone = contact.phoneNumbers.first?.value.stringValue {
            let digits = phone.filter(\.isNumber)
            if digits.count == 11, digits.first == "1" {
                return String(digits.dropFirst())
            }
            if !digits.isEmpty { return digits }
        }
        return contact.identifier
    }

    private func pendingMembers(from contacts: [CNContact]) -> [GroupMember] {
        contacts.map { contact in
            let name = "\(contact.givenName) \(contact.familyName)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let phone = contact.phoneNumbers.first?.value.stringValue
            let digits = phone?.filter(\.isNumber) ?? ""
            let displayName = name.isEmpty ? (digits.isEmpty ? "Invitee" : digits) : name
            if let phone {
                LocalContactNameStore.save(
                    name: displayName,
                    phoneNumber: phone,
                    imageData: contact.dutchSafeImageData
                )
            }
            let imageData = contact.dutchSafeImageData
            return GroupMember(
                name: displayName,
                phoneNumber: phone,
                imageData: imageData,
                isCurrentUser: false,
                isPending: true,
                localDisplayName: displayName,
                localImageData: imageData,
                joinedAt: nil
            )
        }
    }

    // Encodes a message body for the sms: URL scheme.
    // The invite link has its own query string, so encode the whole body tightly.
    private func smsBodyEncoded(_ message: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return message.addingPercentEncoding(withAllowedCharacters: allowed) ?? message
    }

    private func inviteMessage(for group: DutchieGroup) -> String {
        let ownerName = appState.profile.name.isEmpty ? "Someone" : appState.profile.name
        return """
        \(ownerName) invited you to split expenses on Dutch — "\(group.name)" group.

        Dutch invite link (full link):
        \(group.inviteLink)

        Tap the full link above to join this exact group.
        """
    }

    // MARK: - Shared UI

    private func progressHeader(current: Int, total: Int, title: String) -> some View {
        VStack(spacing: 20) {
            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { i in
                    Capsule()
                        .fill(i <= current ? ink : ink.opacity(0.15))
                        .frame(height: 4)
                        .animation(.easeInOut(duration: 0.3), value: current)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            VStack(spacing: 6) {
                Text("STEP \(current) OF \(total)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ink.opacity(0.4))
                    .tracking(2)
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(ink)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(ink.opacity(0.45))
            .tracking(1.5)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundColor(ink)
            Text(translatedError(error))
                .font(.system(size: 13, weight: .medium)).foregroundColor(ink)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.opacity(0.06))
        .cornerRadius(2)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.2), lineWidth: 1))
    }

    private func bottomButton(label: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
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
            .frame(height: 1)
            .padding(.horizontal, 20)

            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold))
                    Text(label).font(.system(size: 13, weight: .bold)).tracking(1.2)
                }
                .foregroundColor(ivory)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(enabled ? ink : ink.opacity(0.3))
                .cornerRadius(3)
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!enabled)
            .padding(20)
        }
        .background(ivory)
    }

    @ViewBuilder
    private func loadingOverlay(show: Bool, awaitingCode: Bool) -> some View {
        if show {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: ivory))
                    .scaleEffect(1.4)
                Text(awaitingCode ? "Verifying code..." : "Security check opening...")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(ivory)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 4).fill(ink))
            .padding(.horizontal, 40)
        }
    }

    private func translatedError(_ error: String) -> String {
        if error.contains("cancelled by the user") { return "Security check was cancelled. Please try again." }
        if error.contains("invalid verification code") { return "Invalid code. Please check and try again." }
        if error.contains("expired") { return "Code expired. Please request a new one." }
        return error
    }
}
