import SwiftUI
import MessageUI
import Contacts
import ContactsUI

private func hasUsablePhoneNumber(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.filter(\.isNumber).isEmpty
}

private func nonSyncedMemberName(for phone: String?) -> String {
    let digits = phone?.filter(\.isNumber) ?? ""
    guard !digits.isEmpty else { return "Member" }
    return "Member \(digits.suffix(4))"
}

private func deferGroupJoinAction(after delay: TimeInterval = 0.05, _ work: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        let start = CFAbsoluteTimeGetCurrent()
        work()
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        if elapsedMs > 16 {
            print("🧭 PERF [group-join:tap-action] ms=\(elapsedMs)")
        }
    }
}

// MARK: - Group Join Banner (In-App)

struct GroupInviteSheetView: View {
    @ObservedObject var groupManager: GroupManager
    let preselectedPeople: [Person]
    
    @Environment(\.dismiss) var dismiss
    @State private var showSuccess = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                if showSuccess {
                    successView
                } else {
                    inviteView
                }
            }
            .background(Color(red: 1.0, green: 0.992, blue: 0.969))
            .navigationTitle("Invite to Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var inviteView: some View {
        VStack(spacing: 24) {
            Text("Group invitations coming soon!")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.top, 40)
            
            Spacer()
        }
        .padding(24)
    }
    
    private var successView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            
            Text("Invitations Sent!")
                .font(.system(size: 24, weight: .bold))
            
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .cornerRadius(3)
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 24)
        }
        .padding(.top, 40)
    }
}

// MARK: - Group Creation Sheet (Updated with Required Contacts)

struct GroupCreationSheet: View {
    @ObservedObject var groupManager: GroupManager
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    let onCreated: (String) -> Void
    
    @State private var groupName = ""
    @State private var selectedContacts: [InviteContact] = []
    @State private var showContactPicker = false
    @State private var currentStep = 1
    @State private var composePayload: MessageComposePayload?
    @State private var invitesSent = false
    
    @State private var recentPeople: [RecentPerson] = []
    @State private var recentGroups: [PersistedGroup] = []
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared
    @EnvironmentObject var groupModeTutorial: GroupModeTutorialManager
    
    @FocusState private var isNameFieldFocused: Bool
    
    private let canSendText = MFMessageComposeViewController.canSendText()

    private let storage = PeopleStorageManager.shared
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 1.0, green: 0.992, blue: 0.969).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    progressIndicator
                    
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 24) {
                            if currentStep == 1 {
                                nameStep
                            } else if currentStep == 2 {
                                addPeopleStep
                            } else {
                                confirmStep
                            }
                        }
                        .padding(24)
                        .padding(.bottom, 100)
                    }
                    
                    bottomButton
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(currentStep > 1 ? "Back" : "Cancel") {
                        if currentStep > 1 {
                            withAnimation(.spring(response: 0.3)) {
                                currentStep -= 1
                            }
                        } else {
                            isPresented = false
                        }
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            recentPeople = storage.loadRecentPeople().filter { hasUsablePhoneNumber($0.phoneNumber) }
            recentGroups = storage.loadSavedGroups()

            syncTutorialSheetStateIfNeeded(for: groupModeTutorial.currentStepIndex)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isNameFieldFocused = !groupModeTutorial.isActive
            }
        }
        .onChange(of: groupModeTutorial.currentStepIndex) { oldValue, newValue in
            print("🎯 GroupCreationSheet: Tutorial step changed from \(oldValue) to \(newValue)")

            syncTutorialSheetStateIfNeeded(for: newValue)
            
            if newValue == 3 {
                isPresented = false
            }
        }
        .overlay {
            if groupModeTutorial.isActive {
                GroupModeTutorialOverlay(
                    context: .groupCreation,
                    tutorialManager: groupModeTutorial
                )
                .zIndex(200)
            }
        }
        .sheet(isPresented: $showContactPicker) {
            InviteContactPickerSheet { contacts in
                mergeContacts(contacts)
            }
        }
        .sheet(item: $composePayload) { payload in
            GroupMessageComposeView(
                recipients: payload.recipients,
                messageBody: payload.body,
                isPresented: Binding(get: { composePayload != nil }, set: { if !$0 { composePayload = nil; handleMessageSent() } })
            )
            .ignoresSafeArea()
        }
    }
    
    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(1...3, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step <= currentStep ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.2))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    
    // MARK: - Step 1: Name
    
    private var nameStep: some View {
        VStack(spacing: 24) {
            nameStepHeader
            groupNameInputSection
            recentGroupsQuickStart
            Spacer()
        }
    }

    private var nameStepHeader: some View {
        VStack(spacing: 12) {
            Text("Create New Group")
                .font(.system(size: 24, weight: .bold))
            Text("Give your group a name")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private var groupNameInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GROUP NAME")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(1)

            TextField("e.g., Roommates, Weekend Trip", text: $groupName)
                .font(.system(size: 16, weight: .medium))
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.1), lineWidth: 1)
                )
                .focused($isNameFieldFocused)
                .submitLabel(.next)
                .onSubmit {
                    if !groupName.trimmingCharacters(in: .whitespaces).isEmpty {
                        goToStep2()
                    }
                }
        }
        .overlay(groupNameInputTutorialFrame)
    }

    private var groupNameInputTutorialFrame: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.frame(in: .global)) { _, newFrame in
                    registerGroupNameFrameIfNeeded(newFrame)
                }
                .onAppear {
                    registerGroupNameFrameIfNeeded(geo.frame(in: .global))
                    scheduleGroupNameFrameRetries(geo: geo)
                }
                .onChange(of: groupModeTutorial.currentStepIndex) { _, newIndex in
                    guard newIndex == 1, currentStep == 1 else { return }
                    scheduleGroupNameFrameRetries(geo: geo)
                }
                .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in
                    registerGroupNameFrameIfNeeded(geo.frame(in: .global))
                }
        }
    }

    @ViewBuilder
    private var recentGroupsQuickStart: some View {
        if !recentGroups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("Quick Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(recentGroups.prefix(3))) { group in
                            recentGroupButton(group)
                        }
                    }
                }
            }
        }
    }

    private func recentGroupButton(_ group: PersistedGroup) -> some View {
        Button(action: {
            HapticManager.impact(style: .light)
            groupName = group.name
            selectedContacts = inviteContacts(from: group.members)
            withAnimation(.spring(response: 0.3)) {
                currentStep = 2
            }
        }) {
            recentGroupCard(group)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.96))
    }

    private func recentGroupCard(_ group: PersistedGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: -8) {
                ForEach(Array(group.members.prefix(3).enumerated()), id: \.element.id) { index, member in
                    AvatarView(
                        imageData: member.imageData,
                        initials: String(member.name.prefix(2).uppercased()),
                        size: 28
                    )
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .zIndex(Double(3 - index))
                }
            }

            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)

            Text("\(group.members.count) people")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(width: 140)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.1), lineWidth: 1)
        )
    }
    
    private var addPeopleStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text("Add People")
                    .font(.system(size: 24, weight: .bold))
                Text("Select who to invite to \"\(groupName)\"")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button(action: {
                HapticManager.impact(style: .light)
                showContactPicker = true
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 18))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    
                    Text("Select from Contacts")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.15), lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
            
            if !selectedContacts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("SELECTED (\(selectedContacts.count))")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .tracking(1)
                        Spacer()
                    }
                    
                    VStack(spacing: 8) {
                        ForEach(selectedContacts) { contact in
                            selectedContactRow(contact: contact)
                        }
                    }
                }
            }
            
            if !recentPeople.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(selectedContacts.isEmpty ? "Recent People" : "Add More from Recent")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(spacing: 8) {
                        ForEach(recentPeople.prefix(5)) { person in
                            recentPersonRow(person: person)
                        }
                    }
                }
            }
            
            if selectedContacts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Select at least one person to continue")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 20)
            }
            
            Spacer()
        }
    }
    
    private var confirmStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text("Review & Send")
                    .font(.system(size: 24, weight: .bold))
                Text("Invitations will be sent via iMessage")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 16) {
                HStack {
                    Text("GROUP NAME")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(1)
                    Spacer()
                }
                
                HStack {
                    Text(groupName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(2)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("MEMBERS (\(selectedContacts.count + 1))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(1)
                    Spacer()
                }
                
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        AvatarView(
                            imageData: appState.profile.avatarImage,
                            initials: appState.profile.initials,
                            size: 44
                        )
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.profile.name)
                                .font(.system(size: 15, weight: .semibold))
                            Text("You")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        statusBadge(status: .joined)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(2)
                    
                    ForEach(selectedContacts) { contact in
                        HStack(spacing: 12) {
                            AvatarView(
                                imageData: contact.imageData,
                                initials: contact.initials,
                                size: 44
                            )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .font(.system(size: 15, weight: .semibold))
                                if let phone = contact.phoneNumber {
                                    Text(phone)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            statusBadge(status: invitesSent ? .sent : .pending)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(2)
                    }
                }
            }
            
            if invitesSent {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.green)
                    Text("Invitations sent successfully")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.green)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.1))
                .cornerRadius(2)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Helper Views
    
    private func statusBadge(status: MemberStatus) -> some View {
        HStack(spacing: 4) {
            if status == .joined {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
            } else if status == .sent {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10))
            } else {
                Image(systemName: "clock.fill")
                    .font(.system(size: 10))
            }
            
            Text(status.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.3)
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.12))
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(status.color.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func recentPersonRow(person: RecentPerson) -> some View {
        let isSelected = selectedContacts.contains(where: { $0.name == person.name })
        
        return Button(action: {
            guard hasUsablePhoneNumber(person.phoneNumber) else { return }
            HapticManager.impact(style: .light)
            if isSelected {
                selectedContacts.removeAll { $0.name == person.name }
            } else {
                LocalContactNameStore.save(name: person.name, phoneNumber: person.phoneNumber, imageData: person.imageData)
                selectedContacts.append(InviteContact(
                    id: UUID(),
                    name: person.name,
                    phoneNumber: person.phoneNumber,
                    imageData: person.imageData
                ))
            }
        }) {
            HStack(spacing: 12) {
                AvatarView(
                    imageData: person.imageData,
                    initials: String(person.name.prefix(2).uppercased()),
                    size: 40
                )
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    if let phone = person.phoneNumber {
                        Text(phone)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func selectedContactRow(contact: InviteContact) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                imageData: contact.imageData,
                initials: contact.initials,
                size: 40
            )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.system(size: 15, weight: .semibold))
                if let phone = contact.phoneNumber, !phone.isEmpty {
                    Text(phone)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Text("No phone number")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
            
            Spacer()
            
            Button(action: {
                HapticManager.impact(style: .light)
                selectedContacts.removeAll { $0.id == contact.id }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.9))
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(2)
    }
    
    // MARK: - Bottom Button
    
    private var bottomButton: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            
            Button(action: {
                HapticManager.impact(style: .medium)
                handleNextStep()
            }) {
                HStack(spacing: 8) {
                    Text(buttonText)
                        .font(.system(size: 16, weight: .semibold))
                    if currentStep < 3 || !invitesSent {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(isButtonEnabled ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color.secondary.opacity(0.3))
                .cornerRadius(3)
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!isButtonEnabled)
            .padding(20)
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            if groupModeTutorial.isActive &&
                               groupModeTutorial.currentStepIndex == 2 &&
                               currentStep == 3 &&
                               newFrame.width > 0 {
                                groupModeTutorial.registerFrame(newFrame, for: .inviteButton)
                            }
                        }
                        .onAppear {
                            let frame = geo.frame(in: .global)
                            if groupModeTutorial.isActive &&
                               groupModeTutorial.currentStepIndex == 2 &&
                               currentStep == 3 &&
                               frame.width > 0 {
                                for i in 1...20 {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                                        let updatedFrame = geo.frame(in: .global)
                                        if updatedFrame.width > 0 {
                                            groupModeTutorial.registerFrame(updatedFrame, for: .inviteButton)
                                        }
                                    }
                                }
                            }
                        }
                        .onChange(of: currentStep) { _, newStep in
                            if groupModeTutorial.isActive &&
                               groupModeTutorial.currentStepIndex == 2 &&
                               newStep == 3 {
                                for i in 1...20 {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                                        let frame = geo.frame(in: .global)
                                        if frame.width > 0 {
                                            groupModeTutorial.registerFrame(frame, for: .inviteButton)
                                        }
                                    }
                                }
                            }
                        }
                        .onChange(of: groupModeTutorial.frameUpdateTick) { _, _ in
                            if groupModeTutorial.isActive &&
                               groupModeTutorial.currentStepIndex == 2 &&
                               currentStep == 3 {
                                let frame = geo.frame(in: .global)
                                if frame.width > 0 {
                                    groupModeTutorial.registerFrame(frame, for: .inviteButton)
                                }
                            }
                        }
                }
            )
        }
        .background(Color(red: 1.0, green: 0.992, blue: 0.969))
    }
    
    private var buttonText: String {
        switch currentStep {
        case 1: return "Continue"
        case 2: return selectedContacts.isEmpty ? "Select People" : "Continue"
        case 3: return invitesSent ? "Done" : "Send Invitations"
        default: return "Continue"
        }
    }
    
    private var isButtonEnabled: Bool {
        switch currentStep {
        case 1: return !groupName.trimmingCharacters(in: .whitespaces).isEmpty
        case 2: return !selectedContacts.isEmpty
        case 3: return true
        default: return false
        }
    }
    
    // MARK: - Actions
    
    private func handleNextStep() {
        switch currentStep {
        case 1:
            goToStep2()
        case 2:
            goToStep3()
        case 3:
            if invitesSent {
                finishCreation()
            } else {
                sendInvitations()
            }
        default:
            break
        }
    }
    
    private func goToStep2() {
        withAnimation(.spring(response: 0.3)) {
            currentStep = 2
        }
    }
    
    private func goToStep3() {
        withAnimation(.spring(response: 0.3)) {
            currentStep = 3
        }
    }

    private func registerGroupNameFrameIfNeeded(_ frame: CGRect) {
        guard groupModeTutorial.isActive,
              groupModeTutorial.currentStepIndex == 1,
              currentStep == 1,
              frame.width > 0 else { return }
        groupModeTutorial.registerFrame(frame, for: .groupNameInput)
    }

    private func scheduleGroupNameFrameRetries(geo: GeometryProxy) {
        guard groupModeTutorial.isActive,
              groupModeTutorial.currentStepIndex == 1,
              currentStep == 1 else { return }

        for i in 1...20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                registerGroupNameFrameIfNeeded(geo.frame(in: .global))
            }
        }
    }

    private func syncTutorialSheetStateIfNeeded(for tutorialStep: Int) {
        guard groupModeTutorial.isActive else { return }

        isNameFieldFocused = false

        if tutorialStep >= 1, groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            groupName = "Weekend Trip"
        }

        if tutorialStep >= 1, selectedContacts.isEmpty {
            selectedContacts = [
                InviteContact(
                    id: UUID(),
                    name: "Tony",
                    phoneNumber: "+15550101010",
                    imageData: nil
                )
            ]
        }

        guard tutorialStep == 2 else { return }

        if currentStep != 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard groupModeTutorial.isActive,
                      groupModeTutorial.currentStepIndex == 2 else { return }
                withAnimation(.spring(response: 0.3)) {
                    currentStep = 3
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    groupModeTutorial.frameUpdateTick += 1
                }
            }
        }

        if !invitesSent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard groupModeTutorial.isActive,
                      groupModeTutorial.currentStepIndex == 2 else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    invitesSent = true
                }
            }
        }
    }

    private func inviteContacts(from members: [PersistedGroupMember]) -> [InviteContact] {
        members.map { member in
            InviteContact(
                id: UUID(),
                name: member.name,
                phoneNumber: member.phoneNumber,
                imageData: member.imageData
            )
        }
    }

    private func memberAvatarImageData(_ member: GroupMember) -> Data? {
        member.displayImageData
    }
    
    private func createGroupNow() {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to create a group.") else {
            return
        }

        let trimmedName = groupName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        let currentUserMember = GroupMember(
            id: currentUser?.id ?? UUID(),
            name: currentUser?.name ?? appState.profile.name,
            phoneNumber: appState.profile.zelleContactInfo,
            imageData: appState.profile.avatarImage,
            isCurrentUser: true,
            isPending: false,
            profileName: appState.profile.name,
            venmoUsername: appState.profile.venmoUsername?.replacingOccurrences(of: "@", with: ""),
            venmoLink: appState.profile.venmoPaymentLink,
            zelleEmail: appState.profile.zelleContactInfo,
            zelleLink: appState.profile.zellePaymentLink
        )
        
        var allMembers: [GroupMember] = [currentUserMember]
        for contact in selectedContacts {
            guard hasUsablePhoneNumber(contact.phoneNumber) else { continue }
            let normalizedPhone = normalizeInvitePhone(contact.phoneNumber)
            LocalContactNameStore.save(name: contact.name, phoneNumber: normalizedPhone, imageData: contact.imageData)
            allMembers.append(GroupMember(
                id: UUID(),
                name: nonSyncedMemberName(for: normalizedPhone),
                phoneNumber: normalizedPhone,
                imageData: nil,
                isCurrentUser: false,
                isPending: true,
                localDisplayName: contact.name,
                localImageData: contact.imageData,
                joinedAt: nil
            ))
        }
        
        groupManager.createGroup(name: trimmedName, members: allMembers)
        if let group = groupManager.allGroups.first(where: { $0.name == trimmedName }) {
            groupManager.setActiveGroup(group)
        }
        groupManager.enableGroupMode()
        groupManager.syncMembersToAppState(appState)
        
        let persistedMembers = selectedContacts.filter { hasUsablePhoneNumber($0.phoneNumber) }.map {
            PersistedGroupMember(name: $0.name, phoneNumber: $0.phoneNumber, imageData: $0.imageData)
        }
        let persistedGroup = PersistedGroup(name: trimmedName, members: persistedMembers)
        storage.saveGroup(persistedGroup)
        
        HapticManager.notification(type: .success)
    }
    
    private func sendInvitations() {
        createGroupNow()
        
        let phones = selectedContacts.compactMap { $0.phoneNumber }.filter { hasUsablePhoneNumber($0) }
        
        if canSendText && !phones.isEmpty, let group = groupManager.activeGroup {
            let body = """
            Hi! I want to activate Group Mode on Dutch so we can send money in a single tap.
            
            I added you to "\(groupName)" already, so your split is ready when you open Dutch.
            
            Download the app:
            
            App Store: https://apps.apple.com/app/dutchie
            
            Dutch invite link (full link):
            \(group.inviteLink)
            
            Split expenses together, settle up instantly.
            """
            composePayload = MessageComposePayload(recipients: phones, body: body)
        } else {
            handleMessageSent()
        }
    }

    private func normalizeInvitePhone(_ phone: String?) -> String? {
        guard let phone else { return nil }
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
        return digitsOnly.isEmpty ? nil : "+" + digitsOnly
    }
    
    private func handleMessageSent() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            invitesSent = true
        }
    }
    
    private func finishCreation() {
        let trimmedName = groupName.trimmingCharacters(in: .whitespaces)
        
        HapticManager.notification(type: .success)
        onCreated(trimmedName)
        isPresented = false
    }
    
    private func mergeContacts(_ incoming: [InviteContact]) {
        for c in incoming {
            guard hasUsablePhoneNumber(c.phoneNumber) else { continue }
            if !selectedContacts.contains(where: { $0.id == c.id || $0.name == c.name }) {
                selectedContacts.append(c)
            }
        }
    }
}

enum MemberStatus: String {
    case pending = "Pending"
    case sent = "Sent"
    case joined = "Joined"
    
    var color: Color {
        switch self {
        case .pending: return .orange
        case .sent: return .blue
        case .joined: return .green
        }
    }
}

// MARK: - Group Join Banner

struct GroupJoinBannerView: View {
    let memberName: String
    let groupName: String
    let isLastMember: Bool
    @Binding var isVisible: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.3)) {
                isVisible = false
            }
            onTap()
        }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isLastMember ? Color.green : Color.accentColor)
                        .frame(width: 44, height: 44)
                    
                    if isLastMember {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: "person.badge.plus.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    if isLastMember {
                        Text("Everyone's In!")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                        Text("All members of \(groupName) have joined")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(memberName) Joined!")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                        Text("Tap to view \(groupName)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    HapticManager.impact(style: .light)
                    withAnimation(.spring(response: 0.3)) {
                        isVisible = false
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: Color.black.opacity(0.15), radius: 20, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isLastMember ? Color.green.opacity(0.3) : Color.accentColor.opacity(0.3),
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Group Join (Onboarding)

struct GroupJoinView: View {
    @ObservedObject var groupManager: GroupManager
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    let invite: PendingGroupInvite
    var allowsDismiss: Bool = true
    var onFullInviteBack: (() -> Void)? = nil
    let onJoinComplete: () -> Void
    
    @State private var showSuccess = false
    @State private var isJoining = false
    @State private var isLoadingInviteGroup = false
    @State private var joinErrorMessage = ""
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared
    
    var group: DutchieGroup? {
        groupManager.getGroup(by: invite.groupID)
    }

    private var inviteIsFull: Bool {
        guard let group else { return false }
        if canClaimInvite(in: group, phoneNumber: authManager.phoneNumber ?? appState.profile.zelleContactInfo) {
            return false
        }
        if let maxMemberCount = group.maxMemberCount {
            return group.activeMemberCount >= maxMemberCount
        }
        return group.isInviteFull
    }

    private var shouldShowFullInviteBack: Bool {
        guard onFullInviteBack != nil else { return false }
        if inviteIsFull { return true }
        let lowercasedError = joinErrorMessage.lowercased()
        return lowercasedError.contains("full") ||
            lowercasedError.contains("open a seat") ||
            lowercasedError.contains("filled")
    }

    private func normalizedPhoneKey(_ phone: String?) -> String? {
        guard let digits = phone?.filter(\.isNumber), !digits.isEmpty else { return nil }
        return digits.hasPrefix("1") && digits.count == 11 ? String(digits.dropFirst()) : digits
    }

    private func matchingInviteMember(in group: DutchieGroup, phoneNumber: String?) -> GroupMember? {
        let invitePhoneKey = normalizedPhoneKey(invite.phoneNumber)
        let verifiedPhoneKey = normalizedPhoneKey(phoneNumber)
        let candidateKeys = Set([invitePhoneKey, verifiedPhoneKey].compactMap { $0 })

        guard !candidateKeys.isEmpty else { return nil }
        return group.members.first { member in
            guard !member.hasLeft,
                  let memberPhoneKey = normalizedPhoneKey(member.phoneNumber) else { return false }
            return candidateKeys.contains(memberPhoneKey)
        }
    }

    private func canClaimInvite(in group: DutchieGroup, phoneNumber: String?) -> Bool {
        if matchingInviteMember(in: group, phoneNumber: phoneNumber) != nil {
            return true
        }

        guard group.maxMemberCount != nil else {
            return !group.isInviteFull
        }

        return false
    }

    private func logJoinAttempt(
        stage: String,
        group: DutchieGroup?,
        verifiedPhone: String,
        matchedInviteMember: GroupMember?
    ) {
        let verifiedKey = normalizedPhoneKey(verifiedPhone) ?? "nil"
        let inviteKey = normalizedPhoneKey(invite.phoneNumber) ?? "nil"
        let memberRows = group?.members.map { member -> String in
            let phone = member.phoneNumber ?? "nil"
            let phoneKey = normalizedPhoneKey(member.phoneNumber) ?? "nil"
            return """
              - \(member.name) id=\(member.id.uuidString) pending=\(member.isPending) left=\(member.hasLeft) phone=\(phone) phoneKey=\(phoneKey) source=\(member.subscriptionSourceGroupID?.uuidString ?? "nil")
            """
        }.joined(separator: "\n") ?? "  - no group loaded"

        print("""
        🔎 SUBSCRIPTION JOIN DEBUG [\(stage)]
        groupID=\(invite.groupID.uuidString)
        groupName=\(group?.name ?? invite.groupName)
        verifiedPhone=\(verifiedPhone)
        verifiedPhoneKey=\(verifiedKey)
        invitePhone=\(invite.phoneNumber)
        invitePhoneKey=\(inviteKey)
        matchedMember=\(matchedInviteMember?.name ?? "nil")
        matchedMemberPhone=\(matchedInviteMember?.phoneNumber ?? "nil")
        activeMembers=\(group?.activeMemberCount ?? -1)
        pendingMembers=\(group?.pendingMemberCount ?? -1)
        occupiedMembers=\(group?.occupiedMemberCount ?? -1)
        maxMemberCount=\(group?.maxMemberCount.map(String.init) ?? "nil")
        groupMembers:
        \(memberRows)
        """)
    }
    
    var body: some View {
        ZStack {
            Color(red: 1.0, green: 0.992, blue: 0.969).ignoresSafeArea()
            
            if showSuccess {
                successView
            } else {
                inviteView
            }
        }
        .onAppear {
            fetchInviteGroupIfNeeded()
        }
    }
    
    private var inviteView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.08))
                    .frame(width: 96, height: 96)
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .frame(width: 32, height: 3)
                    Rectangle()
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .frame(width: 28, height: 3)
                    Rectangle()
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .frame(width: 30, height: 3)
                }
            }
            
            VStack(spacing: 12) {
                Text("You're Invited!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("\(invite.inviterName) invited you to join")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text(invite.groupName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            
            if let group = group {
                VStack(spacing: 16) {
                    HStack(spacing: 24) {
                        statPill(value: "\(group.activeMemberCount)", label: "Members")
                        if let maxMemberCount = group.maxMemberCount {
                            let openSeats = max(0, maxMemberCount - group.activeMemberCount)
                            statPill(value: "\(openSeats)", label: openSeats == 1 ? "Join Seat" : "Join Seats")
                        } else {
                            statPill(value: String(format: "$%.0f", group.totalExpenses), label: "Total")
                        }
                    }
                    
                    HStack(spacing: -12) {
                        ForEach(group.members.filter { !$0.isPending }.prefix(4)) { member in
                            AvatarView(
                                imageData: member.displayImageData,
                                initials: member.initials,
                                size: 48
                            )
                            .overlay(
                                Circle().stroke(Color(red: 1.0, green: 0.992, blue: 0.969), lineWidth: 3)
                            )
                        }
                    }
                }
                .padding(.vertical, 24)
            }

            if inviteIsFull {
                Text("This invite link has already been filled by joined members.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if !joinErrorMessage.isEmpty {
                Text(joinErrorMessage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            Spacer()
            
            VStack(spacing: 12) {
                Button(action: {
                    HapticManager.impact(style: .medium)
                    joinGroup()
                }) {
                    HStack(spacing: 8) {
                        if isJoining {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text(inviteIsFull ? "Invite Full" : "Join Group")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .cornerRadius(3)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isJoining || inviteIsFull)
                
                if shouldShowFullInviteBack, let onFullInviteBack {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        onFullInviteBack()
                        dismiss()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text("Back")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(ScaleButtonStyle())
                } else if allowsDismiss {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        dismiss()
                    }) {
                        Text("Maybe Later")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
    
    private var successView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 120, height: 120)
                
                Image(systemName: "checkmark")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(.green)
            }
            
            VStack(spacing: 12) {
                Text("You're In!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("Welcome to \(invite.groupName)")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("Split expenses with a single tap")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            
            Spacer()
            
            Button(action: {
                HapticManager.notification(type: .success)
                onJoinComplete()
                dismiss()
            }) {
                Text("Get Started")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .cornerRadius(3)
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
    
    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .tracking(0.5)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.1), lineWidth: 1)
        )
    }
    
    private func joinGroup() {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to join this group.") else {
            return
        }

        guard authManager.isAuthenticated,
              let phoneNumber = authManager.phoneNumber ?? appState.profile.zelleContactInfo,
              !phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        guard group != nil else {
            isJoining = true
            joinErrorMessage = ""
            fetchInviteGroupIfNeeded {
                if group != nil {
                    completeJoin(phoneNumber: phoneNumber)
                } else {
                    isJoining = false
                    joinErrorMessage = "Could not load this invite. Ask the owner to send the link again."
                }
            }
            return
        }

        completeJoin(phoneNumber: phoneNumber)
    }

    private func completeJoin(phoneNumber: String) {
        isJoining = true
        joinErrorMessage = ""

        if let group {
            groupManager.cacheInviteGroupForActivation(group)
        }

        let fetchedGroup = group ?? groupManager.getGroup(by: invite.groupID)
        let matchedInviteMember = fetchedGroup.flatMap { matchingInviteMember(in: $0, phoneNumber: phoneNumber) }
        logJoinAttempt(
            stage: "before-precheck",
            group: fetchedGroup,
            verifiedPhone: phoneNumber,
            matchedInviteMember: matchedInviteMember
        )
        if let fetchedGroup,
           matchedInviteMember == nil,
           fetchedGroup.maxMemberCount != nil || !canClaimInvite(in: fetchedGroup, phoneNumber: phoneNumber) {
            groupManager.forceDiscardInviteGroup(groupID: invite.groupID)
            isJoining = false
            let verifiedKey = normalizedPhoneKey(phoneNumber) ?? "nil"
            let inviteKey = normalizedPhoneKey(invite.phoneNumber) ?? "nil"
            joinErrorMessage = "No matching invite in this group. Verified \(verifiedKey), link \(inviteKey). Check the pending member phone on the owner device."
            print("❌ SUBSCRIPTION JOIN DEBUG rejected before Firebase: \(joinErrorMessage)")
            return
        }

        TrialManager.shared.joinSharedSubscriptionPlan(
            groupID: invite.groupID,
            groupName: fetchedGroup?.name ?? invite.groupName,
            ownerPhone: fetchedGroup?.members.first(where: { $0.id == fetchedGroup?.createdByID })?.phoneNumber,
            profile: appState.profile,
            fallbackMemberLimit: fetchedGroup?.maxMemberCount,
            expectedInvitePhone: matchedInviteMember?.phoneNumber ?? invite.phoneNumber,
            verifiedPhoneNumber: phoneNumber,
            repairMissingInviteSeat: matchedInviteMember != nil
        ) { success, message in
            guard success else {
                groupManager.forceDiscardInviteGroup(groupID: invite.groupID)
                isJoining = false
                joinErrorMessage = message ?? "This invite is no longer available. Ask the owner to send a new one."
                return
            }

            let didActivateMember = groupManager.activateMember(
                phoneNumber: phoneNumber,
                in: invite.groupID,
                currentUserProfile: appState.profile,
                notifyInviteAcceptance: true
            )

            guard didActivateMember else {
                TrialManager.shared.rollbackFailedSharedSubscriptionJoin(groupID: invite.groupID, phoneNumber: phoneNumber)
                groupManager.forceDiscardInviteGroup(groupID: invite.groupID)
                isJoining = false
                joinErrorMessage = "This invite is no longer available. Ask the owner to send a new one."
                return
            }

            if let group = groupManager.getGroup(by: invite.groupID) {
                groupManager.ensureSubscriptionGroupVisible(
                    groupID: group.id,
                    groupName: group.name,
                    profile: appState.profile,
                    activate: true
                )
                groupManager.grantInviteAccess(to: group)
                groupManager.syncMembersToAppState(appState)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isJoining = false
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showSuccess = true
                }
            }
        }
    }

    private func fetchInviteGroupIfNeeded(completion: (() -> Void)? = nil) {
        guard group == nil, !isLoadingInviteGroup else {
            completion?()
            return
        }
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to open this invite.") else {
            return
        }

        isLoadingInviteGroup = true
        groupManager.fetchGroupForInvite(groupID: invite.groupID) { _ in
            DispatchQueue.main.async {
                isLoadingInviteGroup = false
                if group != nil {
                    completion?()
                }
            }
        }
    }
}

// MARK: - ✅ FIXED: Group Detail Sheet (with instant updates & correct notifications)

struct GroupDetailSheet: View {
    let group: DutchieGroup
    @ObservedObject var groupManager: GroupManager
    let currentUserID: UUID
    let onLeave: () -> Void
    let onDelete: () -> Void
    
    @Environment(\.dismiss) var dismiss
    @State private var showAddMember = false
    @State private var composePayload: MessageComposePayload?
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared
    
    // ✅ FIX: Track current group state for instant updates
    @State private var currentGroup: DutchieGroup
    
    // ✅ Custom initializer to set initial state
    init(group: DutchieGroup, groupManager: GroupManager, currentUserID: UUID, onLeave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.group = group
        self.groupManager = groupManager
        self.currentUserID = currentUserID
        self.onLeave = onLeave
        self.onDelete = onDelete
        self._currentGroup = State(initialValue: group)
    }
    
    private let canSendText = MFMessageComposeViewController.canSendText()

    private var isProtectedSubscriptionGroup: Bool {
        guard !currentGroup.isSubscriptionInviteStaging else { return false }
        return currentGroup.maxMemberCount != nil ||
            TrialManager.shared.ownedSubscriptionGroupID == currentGroup.id ||
            TrialManager.shared.sharedSubscriptionGroupID == currentGroup.id ||
            TrialManager.shared.activeSubscriptionPoolGroupID == currentGroup.id
    }
    
    // ✅ Use currentGroup instead of group
    private var currentUserBalance: Double {
        currentGroup.calculateBalances().first(where: { $0.member.id == currentUserID })?.netBalance ?? 0
    }
    
    private var amountToPay: Double {
        currentUserBalance < 0 ? abs(currentUserBalance) : 0
    }
    
    private var amountToReceive: Double {
        currentUserBalance > 0 ? currentUserBalance : 0
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 1.0, green: 0.992, blue: 0.969).ignoresSafeArea()
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        enhancedBalanceCard
                        membersSection
                        activitySection
                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(currentGroup.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isProtectedSubscriptionGroup {
                        Button(action: { onLeave() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Leave")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.red)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                }
            }
            // ✅ FIX: Listen for changes from GroupManager
            .onReceive(groupManager.$activeGroup) { updatedGroup in
                if let updated = updatedGroup, updated.id == currentGroup.id {
                    currentGroup = updated
                }
            }
        }
        .sheet(isPresented: $showAddMember) {
            AddMemberSheet(groupManager: groupManager, groupID: currentGroup.id)
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
    
    // MARK: - Enhanced Balance Card
    
    private var enhancedBalanceCard: some View {
        VStack(spacing: 20) {
            // Top row: I have to pay / I have to receive
            HStack(spacing: 12) {
                // I have to pay
                VStack(alignment: .leading, spacing: 6) {
                    Text("I have to pay")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    Text(String(format: "$%.2f", amountToPay))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(amountToPay > 0 ? .red : .secondary.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                
                // I have to receive
                VStack(alignment: .leading, spacing: 6) {
                    Text("I have to receive")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    Text(String(format: "$%.2f", amountToReceive))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(amountToReceive > 0 ? .green : .secondary.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
            
            // Stats row
            HStack(spacing: 0) {
                statCell(label: "Total Spent", value: String(format: "$%.2f", currentGroup.totalExpenses))
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 36)
                statCell(label: "Members", value: "\(currentGroup.activeMemberCount)")
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 36)
                statCell(label: "Expenses", value: "\(currentGroup.expenses.count)")
            }
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .padding(20)
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: Color.primary.opacity(0.06), radius: 12, y: 4)
    }
    
    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - ✅ FIXED: Members Section (with Payment Icons)
    
    private var membersSection: some View {
        let inviteAvailability = groupManager.inviteAvailability(for: currentGroup.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
                Text("Members").font(.system(size: 18, weight: .bold))
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
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("ADD")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                    }
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(inviteAvailability.canInvite ? 0.08 : 0.03))
                    .cornerRadius(2)
                    .opacity(inviteAvailability.canInvite ? 1 : 0.45)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.95))
                .disabled(!inviteAvailability.canInvite)
            }
            .padding(.leading, 2)

            if let message = inviteAvailability.message, currentGroup.maxMemberCount != nil {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(inviteAvailability.canInvite ? .secondary : .orange)
            }

            if currentGroup.maxMemberCount != nil || currentGroup.pendingMemberCount > 0 {
                groupInviteLinkCard
            }
            
            VStack(spacing: 8) {
                ForEach(currentGroup.calculateBalances()) { balance in
                    memberBalanceRow(balance: balance)
                }
            }
            
            if currentGroup.pendingMemberCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                        Text("Pending")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.orange)
                    }
                    .padding(.leading, 2)
                    .padding(.top, 8)
                    
                    VStack(spacing: 8) {
                        ForEach(currentGroup.members.filter { $0.isPending }) { member in
                            pendingMemberRow(member: member)
                        }
                    }
                }
            }
        }
    }

    private var groupInviteLinkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite link for \(currentGroup.name)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                    Text("Share this exact group link any time.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text(currentGroup.inviteLink)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                ShareLink(item: inviteMessage(for: currentGroup)) {
                    Text("SHARE LINK")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .cornerRadius(3)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.96))

                Button {
                    UIPasteboard.general.string = currentGroup.inviteLink
                    HapticManager.notification(type: .success)
                } label: {
                    Text("COPY")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground).opacity(0.75))
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.96))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
    
    // ✅ FIXED: Only show payment icon when CURRENT USER owes THIS member money
    private func memberBalanceRow(balance: GroupMemberBalance) -> some View {
        // CRITICAL: Check if CURRENT USER owes money to THIS member
        // balance.netBalance > 0 means THIS member is owed money
        // We only show payment button if current user owes them
        let currentUserOwesThisMember = balance.netBalance > 0 && !balance.member.isCurrentUser
        
        return HStack(spacing: 12) {
            AvatarView(imageData: balance.member.displayImageData, initials: balance.member.initials, size: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(memberDisplayName(balance.member)).font(.system(size: 15, weight: .semibold))
                Text(String(format: "Paid $%.2f · Owes $%.2f", balance.totalPaid, balance.totalOwed))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Text(balance.formattedNet).font(.system(size: 16, weight: .bold))
                    .foregroundColor(balance.isPositive ? .green : .red)
                
                // ✅ FIXED: Only show payment icon if CURRENT USER owes THIS member money
                if currentUserOwesThisMember {
                    if let venmoUsername = balance.member.venmoUsername, !venmoUsername.isEmpty {
                        Button(action: {
                            HapticManager.impact(style: .medium)
                            let amount = balance.netBalance // This is how much current user owes
                            openVenmo(username: venmoUsername, amount: amount)
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.1))
                                    .frame(width: 44, height: 44)
                                VenmoIcon(size: 24)
                            }
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.92))
                    } else if balance.member.zelleEmail != nil || balance.member.zelleLink != nil {
                        Button(action: {
                            HapticManager.impact(style: .medium)
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.purple.opacity(0.1))
                                    .frame(width: 44, height: 44)
                                ZelleIcon(size: 24)
                            }
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.92))
                    }
                }
            }
        }
        .padding(14).background(Color(.secondarySystemBackground)).cornerRadius(14)
        .shadow(color: Color.primary.opacity(0.04), radius: 6, y: 2)
    }
    
    private func openVenmo(username: String, amount: Double) {
        let note = "Split from \(currentGroup.name)"
        let venmoURL = "venmo://paycharge?txn=pay&recipients=\(username)&amount=\(String(format: "%.2f", amount))&note=\(note.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        if let url = URL(string: venmoURL), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: "https://venmo.com/\(username)") {
            UIApplication.shared.open(url)
        }
    }
    
    private func pendingMemberRow(member: GroupMember) -> some View {
        HStack(spacing: 12) {
            AvatarView(imageData: member.displayImageData, initials: member.initials, size: 40)
                .overlay(Circle().stroke(Color.orange.opacity(0.3), lineWidth: 2))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(memberDisplayName(member)).font(.system(size: 15, weight: .semibold))
                if let phone = member.phoneNumber {
                    Text(phone).font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Text("PENDING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(4)
                
                Button(action: {
                    HapticManager.impact(style: .light)
                    resendInvite(to: member)
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(8)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(8)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.92))

                if currentGroup.maxMemberCount != nil {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        deferGroupJoinAction {
                            groupManager.removeMemberFromSubscriptionInvite(groupID: currentGroup.id, memberID: member.id)
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(8)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(8)
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.92))
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.3), lineWidth: 1.5))
        .shadow(color: Color.orange.opacity(0.06), radius: 6, y: 2)
    }

    private func memberDisplayName(_ member: GroupMember) -> String {
        let trimmed = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Member" : trimmed
        if member.isCurrentUser {
            return baseName.localizedCaseInsensitiveCompare("You") == .orderedSame ? "You (Me)" : "\(baseName) (You)"
        }
        if baseName.localizedCaseInsensitiveCompare("You") == .orderedSame {
            if currentGroup.createdByID == member.id { return "Plan owner" }
            if let phone = member.phoneNumber?.filter(\.isNumber), phone.count >= 4 {
                return "Member \(phone.suffix(4))"
            }
            return "Member"
        }
        return baseName
    }
    
    // MARK: - ✅ FIXED: Activity Section (with notification bell)
    
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.fill").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
                Text("Activity").font(.system(size: 18, weight: .bold))
            }
            .padding(.leading, 2)
            
            if currentGroup.expenses.isEmpty {
                Text("No expenses yet. Add one from the Upload screen.")
                    .font(.system(size: 14)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
                    .background(Color(.secondarySystemBackground)).cornerRadius(14)
            } else {
                VStack(spacing: 8) {
                    ForEach(currentGroup.recentActivity) { expense in
                        expenseRow(expense: expense)
                    }
                }
            }
        }
    }
    
    private func expenseRow(expense: GroupExpense) -> some View {
        let shares = currentGroup.expenseShares[expense.id] ?? []
        let nonPayerShares = shares.filter { $0.memberID != expense.addedByID }
        let allPaid = !nonPayerShares.isEmpty && nonPayerShares.allSatisfy { $0.status == .paid }

        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 40, height: 40)
                Text(String(expense.addedByName.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(expense.addedByName.components(separatedBy: " ").first ?? expense.addedByName) added \(expense.description)")
                    .font(.system(size: 14, weight: .medium))
                HStack(spacing: 8) {
                    Text(expense.formattedAmount).font(.system(size: 13, weight: .bold)).foregroundColor(.accentColor)
                    if allPaid {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                            Text("PAID")
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
                Text(shortDate(expense.date)).font(.system(size: 12)).foregroundColor(.secondary)
                HStack(spacing: 10) {
                    if !allPaid {
                        Button(action: {
                            HapticManager.impact(style: .light)
                            sendPaymentReminder(for: expense)
                        }) {
                            ZStack {
                                Circle().fill(Color.orange.opacity(0.1)).frame(width: 40, height: 40)
                                Image(systemName: "bell.fill").font(.system(size: 16)).foregroundColor(.orange)
                            }
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.92))
                    }
                    Button(action: {
                        HapticManager.impact(style: .light)
                        togglePaidStatus(expense: expense)
                    }) {
                        ZStack {
                            Circle()
                                .fill(allPaid ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
                                .frame(width: 40, height: 40)
                            Image(systemName: allPaid ? "checkmark.circle.fill" : "checkmark.circle")
                                .font(.system(size: 18))
                                .foregroundColor(allPaid ? .green : .secondary)
                        }
                    }
                    .buttonStyle(ScaleButtonStyle(scale: 0.92))
                }
            }
        }
        .padding(14).background(Color(.secondarySystemBackground)).cornerRadius(14)
        .shadow(color: Color.primary.opacity(0.04), radius: 6, y: 2)
    }
    
    // ✅ NEW: Send payment reminder to people who OWE money for this expense
    private func sendPaymentReminder(for expense: GroupExpense) {
        // Find people who owe money for this expense (they are in splitAmongIDs but didn't pay)
        let peopleWhoOwe = currentGroup.members.filter { member in
            expense.splitAmongIDs.contains(member.id) && member.id != expense.addedByID
        }
        
        guard !peopleWhoOwe.isEmpty else { return }
        
        let share = expense.amount / Double(expense.splitAmongIDs.count)
        let payer = currentGroup.members.first(where: { $0.id == expense.addedByID })?.name ?? "Someone"
        
        for member in peopleWhoOwe {
            // Send local notification to this member
            NotificationManager.shared.notifyPaymentOwed(
                expenseID: expense.id,
                groupName: currentGroup.name,
                payerName: payer,
                expenseDescription: expense.description,
                totalAmount: expense.amount,
                yourShare: share
            )
            
            // Optionally also send via iMessage
            if let phone = member.phoneNumber, !phone.isEmpty, canSendText {
                let body = """
                Payment Reminder: \(currentGroup.name)
                
                \(payer) paid \(expense.formattedAmount) for \(expense.description).
                Your share: \(String(format: "$%.2f", share))
                
                Tap to pay now.
                """
                
                composePayload = MessageComposePayload(recipients: [phone], body: body)
            }
        }
        
        HapticManager.notification(type: .success)
    }
    
    // ✅ FIX: Update both GroupManager AND local state for instant feedback
    private func togglePaidStatus(expense: GroupExpense) {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to update this payment.") else {
            return
        }

        // Call GroupManager to persist the change
        groupManager.toggleExpensePaidStatus(groupID: currentGroup.id, expenseID: expense.id)
        
        // ✅ INSTANT UPDATE: Also update local state immediately for instant UI feedback
        if let expenseIndex = currentGroup.expenses.firstIndex(where: { $0.id == expense.id }) {
            // Toggle the current user's share for this expense
            if let currentUserID = currentGroup.members.first(where: { $0.isCurrentUser })?.id {
                GroupManager.shared.toggleExpensePaidStatus(
                    groupID: currentGroup.id,
                    expenseID: expense.id,
                    memberID: currentUserID
                )
            }        }
    }
    
    private func resendInvite(to member: GroupMember) {
        guard let phone = member.phoneNumber, !phone.isEmpty else { return }
        let body = """
        Hi! I want to activate Group Mode on Dutch so we can send money in a single tap.
        
        Join "\(currentGroup.name)" by downloading the app:
        
        App Store: https://apps.apple.com/app/dutchie
        
        Dutch invite link (full link):
        \(currentGroup.inviteLink)
        
        Split expenses together, settle up instantly.
        """
        if canSendText {
            composePayload = MessageComposePayload(recipients: [phone], body: body)
        }
    }

    private func inviteMessage(for group: DutchieGroup) -> String {
        """
        Join my Dutch group "\(group.name)".

        Dutch invite link (full link):
        \(group.inviteLink)
        """
    }
    
    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: date)
    }
}

// MARK: - Add Member Sheet

struct AddMemberSheet: View {
    @ObservedObject var groupManager: GroupManager
    let groupID: UUID
    @Environment(\.dismiss) var dismiss
    
    @State private var showContactPicker = false
    @State private var selectedContacts: [InviteContact] = []
    @State private var composePayload: MessageComposePayload?
    @State private var inviteMessage: String?
    @State private var cachedAvailability = GroupInviteAvailability(
        canInvite: false,
        message: "Loading invite options...",
        remainingGroupSlots: nil,
        remainingPlanSeats: nil
    )
    @State private var cachedRemainingSelectableSlots: Int?
    @State private var cachedPendingMembers: [GroupMember] = []
    @State private var didPrepareSheet = false
    
    private let canSendText = MFMessageComposeViewController.canSendText()
    private var currentGroup: DutchieGroup? { groupManager.getGroup(by: groupID) }
    private var canOpenContactPicker: Bool {
        cachedAvailability.canInvite && (cachedRemainingSelectableSlots ?? 1) > selectedContacts.count
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        VStack(spacing: 12) {
                            Text("Add Members")
                                .font(.system(size: 24, weight: .bold))
                            Text("Invite people to join this group")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                        }

                        if let availabilityMessage = cachedAvailability.message {
                            Text(availabilityMessage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(cachedAvailability.canInvite ? .secondary : .orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.orange.opacity(cachedAvailability.canInvite ? 0.06 : 0.12))
                                .cornerRadius(2)
                        }

                        if !cachedPendingMembers.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Pending invites")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .tracking(0.8)
                                ForEach(cachedPendingMembers) { member in
                                    pendingInviteRow(member)
                                }
                            }
                        }

                        if let inviteMessage {
                            Text(inviteMessage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(2)
                        }
                        
                        if selectedContacts.isEmpty {
                            Button(action: {
                                guard canOpenContactPicker else {
                                    inviteMessage = cachedAvailability.message ?? "Remove a pending invite before adding someone new."
                                    HapticManager.notification(type: .error)
                                    return
                                }
                                HapticManager.impact(style: .light)
                                showContactPicker = true
                            }) {
                                VStack(spacing: 16) {
                                    Image(systemName: "person.badge.plus")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                    
                                    Text("Select from Contacts")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                                )
                                .opacity(canOpenContactPicker ? 1 : 0.45)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Selected")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .tracking(0.5)
                                    Spacer()
                                    Button(action: {
                                        guard canOpenContactPicker else {
                                            inviteMessage = cachedAvailability.message ?? "Remove a pending invite before adding someone new."
                                            HapticManager.notification(type: .error)
                                            return
                                        }
                                        HapticManager.impact(style: .light)
                                        showContactPicker = true
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus")
                                                .font(.system(size: 10, weight: .bold))
                                            Text("ADD MORE")
                                                .font(.system(size: 10, weight: .bold))
                                                .tracking(0.5)
                                        }
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                    }
                                }
                                .disabled(!canOpenContactPicker)
                                
                                VStack(spacing: 8) {
                                    ForEach(selectedContacts) { contact in
                                        contactRow(contact: contact)
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .padding(.bottom, 100)
                }
                
                VStack(spacing: 0) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                    
                    Button(action: {
                        HapticManager.impact(style: .medium)
                        sendInvites()
                    }) {
                        Text(selectedContacts.isEmpty ? "Select People" : "Add \(selectedContacts.count) \(selectedContacts.count == 1 ? "Person" : "People")")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(selectedContacts.isEmpty || !cachedAvailability.canInvite ? Color.secondary.opacity(0.3) : Color(red: 0.15, green: 0.15, blue: 0.15))
                            .cornerRadius(3)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(selectedContacts.isEmpty || !cachedAvailability.canInvite)
                    .padding(20)
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            prepareSheetIfNeeded()
        }
        .sheet(isPresented: $showContactPicker) {
            InviteContactPickerSheet { contacts in
                mergeContacts(contacts)
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

    private func pendingInviteRow(_ member: GroupMember) -> some View {
        HStack(spacing: 10) {
            AvatarView(imageData: member.displayImageData, initials: member.initials, size: 34)
                .opacity(0.9)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(.system(size: 13, weight: .semibold))
                if let phone = member.phoneNumber {
                    Text(phone)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                HapticManager.impact(style: .light)
                inviteMessage = "Removed \(member.name). You can invite someone new now."
                deferGroupJoinAction {
                    groupManager.removeMemberFromSubscriptionInvite(groupID: groupID, memberID: member.id)
                    refreshSheetSnapshot()
                }
            } label: {
                Text("REMOVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(2)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(2)
    }

    private func prepareSheetIfNeeded() {
        guard !didPrepareSheet else { return }
        didPrepareSheet = true
        refreshSheetSnapshot()
    }

    private func refreshSheetSnapshot() {
        let start = CFAbsoluteTimeGetCurrent()
        let availability = groupManager.inviteAvailability(for: groupID)
        cachedAvailability = availability
        cachedRemainingSelectableSlots = [availability.remainingGroupSlots, availability.remainingPlanSeats]
            .compactMap { $0 }
            .min()
        cachedPendingMembers = currentGroup?.members.filter { $0.isPending && !$0.hasLeft } ?? []

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        if elapsedMs > 16 {
            print("🧭 PERF [add-member:snapshot] pending=\(cachedPendingMembers.count) ms=\(elapsedMs)")
        }
    }
    
    private func contactRow(contact: InviteContact) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                imageData: contact.imageData,
                initials: contact.initials,
                size: 40
            )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.system(size: 15, weight: .semibold))
                if let phone = contact.phoneNumber, !phone.isEmpty {
                    Text(phone)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Text("No phone number")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
            
            Spacer()
            
            Button(action: {
                HapticManager.impact(style: .light)
                selectedContacts.removeAll { $0.id == contact.id }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.9))
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(2)
    }
    
    private func mergeContacts(_ incoming: [InviteContact]) {
        inviteMessage = nil
        let limit = cachedRemainingSelectableSlots.map { max(0, $0 - selectedContacts.count) } ?? incoming.count
        guard limit > 0 else {
            inviteMessage = cachedAvailability.message ?? "Remove a pending invite before adding someone new."
            return
        }

        var addedCount = 0
        for c in incoming {
            guard addedCount < limit else { break }
            if !selectedContacts.contains(where: { $0.id == c.id || $0.name == c.name }) {
                selectedContacts.append(c)
                addedCount += 1
            }
        }

        if incoming.count > addedCount {
            inviteMessage = "Only \(addedCount) more \(addedCount == 1 ? "person" : "people") can be selected for the open seats."
        }
    }
    
    private func sendInvites() {
        guard let group = groupManager.getGroup(by: groupID) else { return }
        
        var addedPhones: [String] = []
        var lastBlockedMessage: String?
        for contact in selectedContacts {
            guard hasUsablePhoneNumber(contact.phoneNumber) else { continue }
            let normalizedPhone = normalizeInvitePhone(contact.phoneNumber)
            LocalContactNameStore.save(name: contact.name, phoneNumber: normalizedPhone, imageData: contact.imageData)
            let member = GroupMember(
                id: contact.id,
                name: nonSyncedMemberName(for: normalizedPhone),
                phoneNumber: normalizedPhone,
                imageData: nil,
                isCurrentUser: false,
                isPending: false,
                localDisplayName: contact.name,
                localImageData: contact.imageData,
                joinedAt: Date()
            )
            let result = groupManager.addPendingMember(member, to: groupID)
            switch result {
            case .added, .updatedExisting:
                if let phone = contact.phoneNumber {
                    addedPhones.append(phone)
                }
            default:
                lastBlockedMessage = result.message
            }
        }
        
        let phones = addedPhones.filter { hasUsablePhoneNumber($0) }
        
        if canSendText && !phones.isEmpty {
            let body = """
            Hi! I want to activate Group Mode on Dutch so we can send money in a single tap.
            
            I added you to "\(group.name)" already, so your split is ready when you open Dutch.
            
            Download the app:
            
            App Store: https://apps.apple.com/app/dutchie
            
            Dutch invite link (full link):
            \(group.inviteLink)
            
            Split expenses together, settle up instantly.
            """
            composePayload = MessageComposePayload(recipients: phones, body: body)
        }

        if phones.isEmpty, let lastBlockedMessage {
            inviteMessage = lastBlockedMessage
            HapticManager.notification(type: .error)
            return
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismiss()
        }
    }

    private func normalizeInvitePhone(_ phone: String?) -> String? {
        guard let phone else { return nil }
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
        return digitsOnly.isEmpty ? nil : "+" + digitsOnly
    }
}

// MARK: - Supporting Views

private struct LightweightInviteContact: Identifiable {
    let id: String
    let name: String
    let phoneNumber: String?
    let imageData: Data?

    var initials: String {
        let parts = name.components(separatedBy: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var inviteContact: InviteContact {
        InviteContact(
            id: UUID(),
            name: name,
            phoneNumber: phoneNumber,
            imageData: imageData
        )
    }
}

struct InviteContactPickerSheet: View {
    let onSelected: ([InviteContact]) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var allContacts: [LightweightInviteContact] = []
    @State private var selectedIDs: Set<String> = []
    @State private var searchText = ""
    @State private var isLoading  = true
    @State private var didRequestContacts = false
    @State private var loadErrorMessage: String?

    private var filtered: [LightweightInviteContact] {
        guard !searchText.isEmpty else { return allContacts }
        return allContacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(searchText) ||
            (contact.phoneNumber ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                if isLoading {
                    ProgressView("Loading contacts…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadErrorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(loadErrorMessage)
                            .font(.system(size: 15, weight: .semibold))
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            didRequestContacts = false
                            loadContactsIfNeeded()
                        }
                        .font(.system(size: 14, weight: .bold))
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if allContacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.xmark").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("No phone contacts found").font(.system(size: 16, weight: .semibold))
                        Text("Group invites need a phone number.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { contact in
                        let isSelected = selectedIDs.contains(contact.id)
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.primary.opacity(0.08)).frame(width: 40, height: 40)
                                Text(contact.initials)
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name).font(.system(size: 15, weight: .medium))
                                if let phone = contact.phoneNumber {
                                    Text(phone).font(.system(size: 13)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22)).foregroundColor(isSelected ? .accentColor : .secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            HapticManager.impact(style: .light)
                            if selectedIDs.contains(contact.id) { selectedIDs.remove(contact.id) }
                            else { selectedIDs.insert(contact.id) }
                        }
                    }
                    .listStyle(.plain).searchable(text: $searchText, prompt: "Search contacts")
                }
            }
            .navigationTitle("Select Contacts").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() }.foregroundColor(.secondary) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        let chosen = allContacts
                            .filter { selectedIDs.contains($0.id) }
                            .map(\.inviteContact)
                        onSelected(chosen); dismiss()
                    }
                    .fontWeight(.semibold).disabled(selectedIDs.isEmpty)
                }
            }
            .onAppear { loadContactsIfNeeded() }
        }
    }

    private func loadContactsIfNeeded() {
        guard !didRequestContacts else { return }
        didRequestContacts = true
        isLoading = true
        loadErrorMessage = nil
        allContacts = []
        loadContacts()
    }

    private func loadContacts() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            fetchContacts()
        case .notDetermined:
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                if granted {
                    fetchContacts()
                } else {
                    DispatchQueue.main.async {
                        isLoading = false
                        loadErrorMessage = "Allow Contacts access to invite people by phone number."
                    }
                }
            }
        case .denied, .restricted:
            isLoading = false
            loadErrorMessage = "Allow Contacts access in Settings to invite people by phone number."
        @unknown default:
            fetchContacts()
        }
    }

    private func fetchContacts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let start = CFAbsoluteTimeGetCurrent()
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]
            var batch: [LightweightInviteContact] = []
            let req = CNContactFetchRequest(keysToFetch: keys)
            req.sortOrder = .userDefault
            func publish(_ contacts: [LightweightInviteContact]) {
                guard !contacts.isEmpty else { return }
                DispatchQueue.main.async {
                    if isLoading { isLoading = false }
                    allContacts.append(contentsOf: contacts)
                    loadErrorMessage = nil
                }
            }

            do {
                try store.enumerateContacts(with: req) { contact, _ in
                    guard let phone = contact.phoneNumbers.first?.value.stringValue,
                          hasUsablePhoneNumber(phone) else { return }

                    let name = "\(contact.givenName) \(contact.familyName)"
                        .trimmingCharacters(in: .whitespaces)
                    batch.append(
                        LightweightInviteContact(
                            id: contact.identifier,
                            name: name.isEmpty ? phone : name,
                            phoneNumber: phone,
                            imageData: nil
                        )
                    )
                    if batch.count >= 80 {
                        let contactsToPublish = batch
                        batch.removeAll(keepingCapacity: true)
                        publish(contactsToPublish)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    loadErrorMessage = "Could not load contacts. Please try again."
                }
                return
            }

            publish(batch)
            DispatchQueue.main.async {
                loadErrorMessage = nil
                isLoading = false

                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                if elapsedMs > 100 {
                    print("🧭 PERF [contacts:invite-load] count=\(allContacts.count) ms=\(elapsedMs)")
                }
            }
        }
    }
}

struct GroupMessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let messageBody: String
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = messageBody
        vc.messageComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let parent: GroupMessageComposeView
        init(_ parent: GroupMessageComposeView) { self.parent = parent }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            DispatchQueue.main.async { self.parent.isPresented = false }
        }
    }
}

struct InviteContact: Identifiable {
    let id: UUID
    let name: String
    let phoneNumber: String?
    let imageData: Data?

    var initials: String {
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1)) + String(parts[1].prefix(1)) }
        return String(name.prefix(2)).uppercased()
    }
}

 
