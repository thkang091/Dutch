import SwiftUI
import UIKit

struct SubscriptionPeopleManagerConfig: Identifiable {
    let id = UUID()
    let managedSubscriptionGroupID: UUID?
}

struct SubscriptionPeopleManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let managedSubscriptionGroupID: UUID?

    @StateObject private var groupManager = GroupManager.shared
    @StateObject private var trialManager = TrialManager.shared
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared

    @State private var group: DutchieGroup?
    @State private var planMembers: [GroupMember] = []
    @State private var visibleMembers: [GroupMember] = []
    @State private var splitGroups: [DutchieGroup] = []
    @State private var finalGroupName = ""
    @State private var isNamingFinalGroup = false
    @State private var isRenamingExistingGroup = false
    @State private var linkCopied = false
    @State private var statusMessage = ""
    @State private var presentationSignature = ""
    @State private var didOpen = false

    private let ink = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let cream = Color(red: 1.00, green: 0.992, blue: 0.969)

    var body: some View {
        NavigationView {
            ZStack {
                cream.ignoresSafeArea()
                if let group {
                    managerContent(for: group)
                } else if !statusMessage.isEmpty {
                    emptyManagerView
                } else {
                    preparingView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        .onAppear { openManagerIfNeeded() }
        .onReceive(groupManager.$allGroups) { groups in
            guard let currentID = group?.id ?? managedSubscriptionGroupID else { return }
            guard let synced = groups.first(where: { $0.id == currentID }) else { return }
            group = synced
            refreshPresentationCache(for: synced)
        }
    }

    private var preparingView: some View {
        VStack(spacing: 14) {
            ProgressView().tint(ink)
            Text("Opening your plan")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyManagerView: some View {
        VStack(spacing: 16) {
            Text(statusMessage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ink.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                HapticManager.impact(style: .medium)
                createSplitGroup()
            } label: {
                primaryButtonText("ADD SPLIT GROUP")
                    .padding(.horizontal, 24)
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func managerContent(for group: DutchieGroup) -> some View {
        let planLimit = trialManager.subscriptionMemberLimit ?? group.maxMemberCount ?? 3
        let occupiedSeats = min(planMembers.count, planLimit)
        let remainingSlots = max(0, planLimit - occupiedSeats)
        let needsInitialName = group.isSubscriptionInviteStaging
        let isEditingGroupName = isNamingFinalGroup || isRenamingExistingGroup
        let canManagePlanMembers = currentUserOwnsSubscriptionGroup(group)
        let membersToShow = planMembers.isEmpty ? visibleMembers : planMembers
        let maxSplitGroups = max(1, planLimit - 1)

        return ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("YOUR PLAN")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(ink.opacity(0.35))
                                .tracking(2.5)
                            Text("Plan People")
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
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            isRenamingExistingGroup = true
                                        }
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

                    Text(remainingSlots == 0 ? "All seats are filled." : "\(remainingSlots) \(remainingSlots == 1 ? "seat" : "seats") open - share the link to add someone.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ink.opacity(0.5))
                }
                .padding(.top, 20)

                divider

                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("MEMBERS")
                    if membersToShow.isEmpty {
                        Text("No one has joined yet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(ink.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(membersToShow) { member in
                            subscriptionMemberRow(member, group: group)
                        }
                    }
                }
                .padding(14)
                .background(ivory)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.12), lineWidth: 1))
                .cornerRadius(2)

                if remainingSlots > 0 {
                    inviteLinkSection(for: group)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ink.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if canManagePlanMembers {
                    splitGroupsSection(
                        allGroups: splitGroups,
                        currentGroup: group,
                        totalLimit: planLimit,
                        totalUsed: occupiedSeats,
                        maxSplitGroups: maxSplitGroups
                    )
                }

                actionSection(
                    group: group,
                    remainingSlots: remainingSlots,
                    needsInitialName: needsInitialName,
                    isEditingGroupName: isEditingGroupName,
                    canManagePlanMembers: canManagePlanMembers
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .onAppear {
            refreshPresentationCache(for: group)
            refreshManagedGroupIfNeeded(force: membersToShow.isEmpty)
        }
    }

    private func inviteLinkSection(for group: DutchieGroup) -> some View {
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

    private func actionSection(
        group: DutchieGroup,
        remainingSlots: Int,
        needsInitialName: Bool,
        isEditingGroupName: Bool,
        canManagePlanMembers: Bool
    ) -> some View {
        VStack(spacing: 10) {
            if remainingSlots > 0 {
                ShareLink(item: subscriptionInviteMessage(for: group)) {
                    primaryButtonText("SHARE INVITE")
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    UIPasteboard.general.string = group.inviteLink
                    linkCopied = true
                    HapticManager.notification(type: .success)
                } label: {
                    secondaryButtonText(linkCopied ? "LINK COPIED" : "COPY LINK")
                }
                .buttonStyle(ScaleButtonStyle())

                Button { joinSubscriptionGroupFromPlanSheet(group) } label: {
                    primaryButtonText("JOIN THIS GROUP")
                }
                .buttonStyle(ScaleButtonStyle())
            }

            if isEditingGroupName {
                Button { saveInviteGroupName(group) } label: {
                    primaryButtonText(needsInitialName ? "CREATE GROUP" : "SAVE NAME")
                }
                .buttonStyle(ScaleButtonStyle())
            } else {
                Button {
                    HapticManager.impact(style: .medium)
                    if needsInitialName {
                        finalGroupName = defaultFinalGroupName(for: group)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isNamingFinalGroup = true
                        }
                    } else {
                        HapticManager.notification(type: .success)
                        dismiss()
                    }
                } label: {
                    primaryButtonText(canManagePlanMembers ? (needsInitialName ? (group.isInviteFull ? "VERIFY & NAME GROUP" : "VERIFY MEMBERS") : "SAVE CHANGES") : "DONE")
                }
                .buttonStyle(ScaleButtonStyle())
            }

            Button(isEditingGroupName ? "Keep current name" : "Done for now") {
                if isEditingGroupName {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isNamingFinalGroup = false
                        isRenamingExistingGroup = false
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

    private func subscriptionMemberRow(_ member: GroupMember, group: DutchieGroup) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ink).frame(width: 32, height: 32)
                Text(member.initials)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(cream)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(subscriptionMemberDisplayName(member, in: group))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ink)
                    .lineLimit(1)
                Text(member.isPending ? "Invited - not joined" : "Joined")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(member.isPending ? Color.orange : Color(red: 0.22, green: 0.56, blue: 0.35))
            }
            Spacer()
            if currentUserOwnsSubscriptionGroup(group), !member.isCurrentUser, member.isPending, group.maxMemberCount != nil {
                Button {
                    HapticManager.impact(style: .light)
                    groupManager.removeMemberFromSubscriptionInvite(groupID: group.id, memberID: member.id)
                    if let updated = groupManager.getGroup(by: group.id) {
                        self.group = updated
                        refreshPresentationCache(for: updated, force: true)
                    }
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

    private func splitGroupsSection(
        allGroups: [DutchieGroup],
        currentGroup: DutchieGroup,
        totalLimit: Int,
        totalUsed: Int,
        maxSplitGroups: Int
    ) -> some View {
        let activeSplitGroupCount = allGroups.count
        let canAddSplitGroup = activeSplitGroupCount < maxSplitGroups

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SPLIT GROUPS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(ink.opacity(0.4))
                        .tracking(2.5)
                    Text("Up to \(maxSplitGroups) subscription split group\(maxSplitGroups == 1 ? "" : "s") for this \(totalLimit)-person plan")
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

            ForEach(allGroups) { candidate in
                splitGroupRow(candidate, currentGroup: currentGroup)
            }

            Button {
                guard canAddSplitGroup else {
                    HapticManager.notification(type: .warning)
                    statusMessage = "Delete a subscription split group before adding another."
                    return
                }
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
                .foregroundColor(ink.opacity(canAddSplitGroup ? 0.65 : 0.28))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(canAddSplitGroup ? 0.22 : 0.1), lineWidth: 1.5))
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!canAddSplitGroup)

            if !canAddSplitGroup {
                Text("Group limit reached. Delete a subscription split group to add a new one.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ink.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(cream)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1.5))
        .cornerRadius(2)
    }

    private func splitGroupRow(_ candidate: DutchieGroup, currentGroup: DutchieGroup) -> some View {
        let activeCount = candidate.members.filter { !$0.hasLeft }.count
        let isCurrent = candidate.id == currentGroup.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.18), lineWidth: 1))
            } else {
                Button {
                    HapticManager.impact(style: .light)
                    group = candidate
                    refreshPresentationCache(for: candidate, force: true)
                } label: {
                    Text("SWITCH")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(cream)
                        .tracking(1.5)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(ink)
                        .cornerRadius(2)
                }
                .buttonStyle(ScaleButtonStyle())
            }
            if currentUserOwnsSubscriptionGroup(candidate) {
                Button {
                    HapticManager.impact(style: .light)
                    deleteSubscriptionSplitGroup(candidate)
                } label: {
                    Text("DELETE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.red.opacity(0.75))
                        .tracking(1.2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.red.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(isCurrent ? ink.opacity(0.04) : ivory)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(isCurrent ? 0.2 : 0.12), lineWidth: 1))
        .cornerRadius(2)
    }

    private var divider: some View {
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

    private func primaryButtonText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .tracking(1.5)
            .foregroundColor(cream)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(ink)
            .cornerRadius(2)
    }

    private func secondaryButtonText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .tracking(1.5)
            .foregroundColor(ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.2), lineWidth: 1))
    }

    private func openManagerIfNeeded() {
        guard !didOpen else { return }
        didOpen = true

        if trialManager.hasSharedSubscriptionAccess,
           let sharedGroupID = trialManager.sharedSubscriptionGroupID {
            if let localGroup = groupManager.getGroup(by: sharedGroupID) {
                group = localGroup
                refreshPresentationCache(for: localGroup, force: true)
            }
            refreshGroupFromFirebase(sharedGroupID)
            return
        }

        if let localGroup = currentSubscriptionGroupForManagement() {
            group = localGroup
            refreshPresentationCache(for: localGroup, force: true)
            return
        }

        if let managedSubscriptionGroupID {
            refreshGroupFromFirebase(managedSubscriptionGroupID)
            return
        }

        guard trialManager.hasScheduledSubscription || trialManager.hasProAccess else {
            statusMessage = "Your plan is not active yet."
            return
        }

        let newGroup = groupManager.createSubscriptionInviteGroup(
            planName: trialManager.subscriptionPlanName ?? "Dutch Pro",
            maxMemberCount: trialManager.subscriptionMemberLimit ?? 3,
            profile: appState.profile,
            currentPerson: appState.people.first(where: { $0.isCurrentUser }),
            existingMembers: []
        )
        group = newGroup
        refreshPresentationCache(for: newGroup, force: true)
    }

    private func currentSubscriptionGroupForManagement() -> DutchieGroup? {
        if trialManager.hasSharedSubscriptionAccess {
            return trialManager.sharedSubscriptionGroupID.flatMap { groupManager.getGroup(by: $0) }
        }
        let ownedGroupID = trialManager.ownedSubscriptionGroupID
        if let managedSubscriptionGroupID,
           let group = groupManager.getGroup(by: managedSubscriptionGroupID),
           ownedGroupID == nil || group.id == ownedGroupID {
            return group
        }
        let group = groupManager.currentUserSubscriptionInviteGroups.first { $0.maxMemberCount != nil && $0.id == ownedGroupID }
            ?? groupManager.currentUserAvailableGroups.first { $0.maxMemberCount != nil }
            ?? groupManager.activeGroup.flatMap { $0.maxMemberCount != nil ? $0 : nil }
        guard let group, ownedGroupID == nil || group.id == ownedGroupID else { return nil }
        return group
    }

    private func refreshGroupFromFirebase(_ groupID: UUID) {
        guard networkMonitor.isOnline else { return }
        groupManager.refreshGroupFromFirebase(groupID: groupID) { fetched in
            DispatchQueue.main.async {
                guard let fetched else { return }
                group = fetched
                refreshPresentationCache(for: fetched, force: true)
            }
        }
    }

    private func refreshManagedGroupIfNeeded(force: Bool = false) {
        guard let groupID = managedSubscriptionGroupID ?? group?.id else { return }
        guard force || group?.members.isEmpty == true else { return }
        refreshGroupFromFirebase(groupID)
    }

    private func presentationSignature(for group: DutchieGroup) -> String {
        let memberSignature = group.members
            .map { "\($0.id.uuidString):\($0.name):\($0.phoneNumber ?? ""):\($0.isPending):\($0.hasLeft):\($0.isCurrentUser)" }
            .sorted()
            .joined(separator: "|")
        let splitSignature = groupManager.currentUserSubscriptionInviteGroups
            .map { "\($0.id.uuidString):\($0.name):\($0.members.count):\($0.isSubscriptionInviteStaging)" }
            .sorted()
            .joined(separator: "|")
        return "\(group.id.uuidString):\(memberSignature):\(splitSignature):\(trialManager.subscriptionMemberLimit ?? -1)"
    }

    private func refreshPresentationCache(for group: DutchieGroup, force: Bool = false) {
        let signature = presentationSignature(for: group)
        guard force || signature != presentationSignature else { return }
        presentationSignature = signature
        planMembers = groupManager.subscriptionPlanRosterMembers(
            profile: appState.profile,
            currentPerson: appState.people.first(where: { $0.isCurrentUser }),
            including: group,
            hydrateContacts: false
        )
        visibleMembers = group.members
            .filter { !$0.hasLeft }
            .map(LocalContactNameStore.applyCached(to:))
            .sorted { lhs, rhs in
                if lhs.isCurrentUser != rhs.isCurrentUser { return lhs.isCurrentUser }
                if lhs.isPending != rhs.isPending { return !lhs.isPending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        splitGroups = groupManager.currentUserSubscriptionInviteGroups
            .filter { !$0.isSubscriptionInviteStaging }
    }

    private func createSplitGroup() {
        let planLimit = trialManager.subscriptionMemberLimit ?? group?.maxMemberCount ?? 3
        let maxSplitGroups = max(1, planLimit - 1)
        let currentSplitGroupCount = splitGroups.count
        guard currentSplitGroupCount < maxSplitGroups else {
            statusMessage = "Delete a subscription split group before adding another."
            HapticManager.notification(type: .warning)
            return
        }

        let newGroup = groupManager.createSubscriptionInviteGroup(
            planName: trialManager.subscriptionPlanName ?? "Dutch Pro",
            maxMemberCount: trialManager.subscriptionMemberLimit ?? 3,
            profile: appState.profile,
            currentPerson: appState.people.first(where: { $0.isCurrentUser }),
            existingMembers: []
        )
        trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: newGroup.id, groupName: newGroup.name, isOwner: true)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            group = newGroup
            isNamingFinalGroup = true
            finalGroupName = ""
        }
        refreshPresentationCache(for: newGroup, force: true)
    }

    private func deleteSubscriptionSplitGroup(_ groupToDelete: DutchieGroup) {
        let fallback = groupManager.deleteSubscriptionSplitGroup(groupToDelete)
        let nextGroup = fallback
            ?? splitGroups.first(where: { $0.id != groupToDelete.id })
            ?? groupManager.currentUserSubscriptionInviteGroups.first(where: { $0.id != groupToDelete.id })

        if let nextGroup {
            group = nextGroup
            refreshPresentationCache(for: nextGroup, force: true)
            statusMessage = "\(groupToDelete.name) was deleted."
        } else {
            group = nil
            planMembers = []
            visibleMembers = []
            splitGroups = []
            presentationSignature = ""
            statusMessage = "\(groupToDelete.name) was deleted. Add a split group to continue."
        }
        HapticManager.notification(type: .success)
    }

    private func finalizeInviteGroup(_ group: DutchieGroup) {
        guard currentUserOwnsSubscriptionGroup(group) else { return }
        guard let finalized = groupManager.finalizeSubscriptionInviteGroup(groupID: group.id, name: finalGroupName) else { return }
        self.group = finalized
        trialManager.activateOwnedSubscriptionGroup(groupID: finalized.id, groupName: finalized.name)
        trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: finalized.id, groupName: finalized.name, isOwner: true)
        refreshPresentationCache(for: finalized, force: true)
        HapticManager.notification(type: .success)
        dismiss()
    }

    private func saveInviteGroupName(_ group: DutchieGroup) {
        guard currentUserOwnsSubscriptionGroup(group) else {
            HapticManager.notification(type: .success)
            dismiss()
            return
        }
        if group.isSubscriptionInviteStaging {
            finalizeInviteGroup(group)
            return
        }
        guard let renamed = groupManager.renameSubscriptionGroup(groupID: group.id, name: finalGroupName) else { return }
        self.group = renamed
        trialManager.activateOwnedSubscriptionGroup(groupID: renamed.id, groupName: renamed.name)
        isRenamingExistingGroup = false
        refreshPresentationCache(for: renamed, force: true)
        HapticManager.notification(type: .success)
        dismiss()
    }

    private func joinSubscriptionGroupFromPlanSheet(_ group: DutchieGroup) {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to join this group.") else { return }
        statusMessage = "Joining group..."
        if currentUserOwnsSubscriptionGroup(group) {
            trialManager.activateOwnedSubscriptionGroup(groupID: group.id, groupName: group.name)
            trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: group.id, groupName: group.name, isOwner: true)
            groupManager.ensureSubscriptionGroupVisible(groupID: group.id, groupName: group.name, profile: appState.profile, activate: true)
            let updated = groupManager.getGroup(by: group.id) ?? group
            self.group = updated
            refreshPresentationCache(for: updated, force: true)
            statusMessage = "Group is ready in Group Mode."
            HapticManager.notification(type: .success)
            return
        }
        guard AuthManager.shared.isAuthenticated,
              let phone = AuthManager.shared.phoneNumber ?? appState.profile.zelleContactInfo,
              !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Verify your phone number first, then join this group."
            return
        }
        TrialManager.shared.joinSharedSubscriptionPlan(
            groupID: group.id,
            groupName: group.name,
            ownerPhone: group.members.first(where: { $0.id == group.createdByID })?.phoneNumber,
            profile: appState.profile,
            fallbackMemberLimit: group.maxMemberCount
        ) { success, message in
            guard success else {
                statusMessage = message ?? "This invite is no longer available."
                HapticManager.notification(type: .error)
                return
            }
            groupManager.ensureSubscriptionGroupVisible(groupID: group.id, groupName: group.name, profile: appState.profile, activate: true)
            let updated = groupManager.getGroup(by: group.id) ?? group
            self.group = updated
            refreshPresentationCache(for: updated, force: true)
            statusMessage = "Group joined."
            HapticManager.notification(type: .success)
        }
    }

    private func currentUserOwnsSubscriptionGroup(_ group: DutchieGroup) -> Bool {
        !trialManager.hasSharedSubscriptionAccess && group.maxMemberCount != nil
    }

    private func defaultFinalGroupName(for group: DutchieGroup) -> String {
        group.name.contains("Share") ? "" : group.name
    }

    private func subscriptionMemberDisplayName(_ member: GroupMember, in group: DutchieGroup) -> String {
        let trimmed = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Member" : trimmed
        if member.isCurrentUser {
            return baseName.localizedCaseInsensitiveCompare("You") == .orderedSame ? "You (Me)" : "\(baseName) (You)"
        }
        if baseName.localizedCaseInsensitiveCompare("You") == .orderedSame {
            if group.createdByID == member.id { return "Plan owner" }
            if let phone = member.phoneNumber?.filter(\.isNumber), phone.count >= 4 {
                return "Member \(phone.suffix(4))"
            }
            return "Member"
        }
        return baseName
    }

    private func subscriptionInviteMessage(for group: DutchieGroup) -> String {
        let planLimit = trialManager.subscriptionMemberLimit ?? group.maxMemberCount ?? 3
        return """
        Join my Dutch plan "\(group.name)".

        Dutch invite link (full link):
        \(group.inviteLink)

        The link works until all \(planLimit) seats are filled.
        """
    }
}
