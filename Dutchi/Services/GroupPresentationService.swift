import Foundation

struct SubscriptionSeatSnapshot {
    var owner: GroupMember?
    var joined: [GroupMember]
    var pending: [GroupMember]
    var removed: [GroupMember]
    var limit: Int

    var activeSeatsUsed: Int {
        min(limit, joined.count + pending.count)
    }
}

struct GroupPresentationSnapshot {
    var group: DutchieGroup
    var balances: [BalanceSummary]
    var activeMembers: [GroupMember]
    var pendingMembers: [GroupMember]
    var removedMembers: [GroupMember]
    var subscriptionSeats: SubscriptionSeatSnapshot?

    var signature: String {
        let expenseSignature = group.expenses
            .map { "\($0.id.uuidString):\($0.amount):\($0.settled):\($0.isArchived):\($0.splitAmongIDs.count)" }
            .joined(separator: "|")
        let shareSignature = group.expenseShares
            .map { key, shares in
                "\(key.uuidString):" + shares
                    .map { "\($0.memberID.uuidString):\($0.status.rawValue):\($0.owedAmount)" }
                    .sorted()
                    .joined(separator: ",")
            }
            .sorted()
            .joined(separator: "|")
        let memberSignature = group.members
            .map { "\($0.id.uuidString):\($0.isPending):\($0.hasLeft):\($0.phoneNumber ?? ""):\($0.name)" }
            .joined(separator: "|")
        return "\(group.id.uuidString):\(memberSignature):\(expenseSignature):\(shareSignature)"
    }
}

@MainActor
final class GroupPresentationService {
    static let shared = GroupPresentationService()

    private init() {}

    func snapshot(
        for group: DutchieGroup,
        trialManager: TrialManager,
        groupManager: GroupManager,
        profile: Profile? = nil,
        currentPerson: Person? = nil
    ) -> GroupPresentationSnapshot {
        var presentationGroup = group
        presentationGroup.members = presentationGroup.members.map(LocalContactNameStore.applyCached(to:))

        let activeMembers = presentationGroup.members.filter { !$0.hasLeft && !$0.isPending }
        let pendingMembers = presentationGroup.members.filter { !$0.hasLeft && $0.isPending }
        let removedMembers = presentationGroup.members.filter(\.hasLeft)
        let balances = presentationGroup.calculateBalances()

        return GroupPresentationSnapshot(
            group: presentationGroup,
            balances: balances,
            activeMembers: activeMembers,
            pendingMembers: pendingMembers,
            removedMembers: removedMembers,
            subscriptionSeats: subscriptionSeatSnapshot(
                for: presentationGroup,
                trialManager: trialManager,
                groupManager: groupManager,
                profile: profile,
                currentPerson: currentPerson
            )
        )
    }

    func subscriptionSeatSnapshot(
        for group: DutchieGroup,
        trialManager: TrialManager,
        groupManager: GroupManager,
        profile: Profile? = nil,
        currentPerson: Person? = nil
    ) -> SubscriptionSeatSnapshot? {
        guard group.maxMemberCount != nil else { return nil }

        let limit = trialManager.hasSharedSubscriptionAccess
            ? (group.maxMemberCount ?? max(1, group.occupiedMemberCount))
            : (trialManager.subscriptionMemberLimit ?? group.maxMemberCount ?? group.members.count)

        let roster = groupManager.subscriptionPlanRosterMembers(
            profile: profile,
            currentPerson: currentPerson,
            including: group,
            hydrateContacts: false
        )
        let localizedRoster = roster.map(LocalContactNameStore.applyCached(to:))
        let owner = localizedRoster.first { member in
            guard let createdByID = group.createdByID else { return member.isCurrentUser }
            return member.id == createdByID
        }
        let joined = localizedRoster.filter { !$0.hasLeft && !$0.isPending }
        let pending = localizedRoster.filter { !$0.hasLeft && $0.isPending }
        let removed = localizedRoster.filter(\.hasLeft)

        return SubscriptionSeatSnapshot(
            owner: owner,
            joined: joined,
            pending: pending,
            removed: removed,
            limit: limit
        )
    }
}
