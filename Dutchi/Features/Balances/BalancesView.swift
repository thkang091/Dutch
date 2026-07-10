import SwiftUI
import UIKit

private enum BalanceSearchField: Hashable {
    case text
    case min
    case max
}

struct BalancesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @StateObject private var groupManager = GroupManager.shared

    let onScanHintTap: (() -> Void)?

    @State private var settledUndoItems: [BalanceItem] = []
    @State private var balanceSnapshot = BalanceSnapshot.empty
    @State private var isBalanceSearchOpen = false
    @State private var balanceSearchText = ""
    @State private var balanceMinAmount = ""
    @State private var balanceMaxAmount = ""
    @FocusState private var focusedBalanceSearchField: BalanceSearchField?
    @AppStorage("settledGroupBalanceItemIds") private var settledGroupBalanceItemIdsStorage = ""

    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let chalk = Color(red: 0.95, green: 0.945, blue: 0.933)
    private let positive = Color(red: 0.10, green: 0.10, blue: 0.10)

    init(onScanHintTap: (() -> Void)? = nil) {
        self.onScanHintTap = onScanHintTap
    }

    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yyyy"
        return formatter
    }()

    private static let expenseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let expenseISOFormatter = ISO8601DateFormatter()

    private var settledGroupBalanceItemIDs: Set<String> {
        Set(
            settledGroupBalanceItemIdsStorage
                .split(separator: "|")
                .map(String.init)
        )
    }

    private var quickSplitPersonalSpend: Double {
        let visibleQuickSplitItems = appState.balanceItems
            .filter { $0.groupId == nil && $0.status != .archived }
        let groupedItems = Dictionary(grouping: visibleQuickSplitItems, by: quickSplitSessionKey)

        return groupedItems.values.reduce(0) { total, items in
            let oweTotal = items
                .filter { $0.type == .owe }
                .reduce(0) { $0 + $1.amount }

            guard oweTotal <= 0.01 else {
                return total + oweTotal
            }

            let receiveShares = items
                .filter { $0.type == .receive }
                .map(\.amount)

            if !receiveShares.isEmpty {
                let payerShareEstimate = receiveShares.reduce(0, +) / Double(receiveShares.count)
                return total + receiveShares.reduce(0, +) + payerShareEstimate
            }

            let oweShares = items
                .filter { $0.type == .owe }
                .reduce(0) { $0 + $1.amount }
            return total + oweShares
        }
    }

    private var groupPersonalSpend: Double {
        groupManager.currentUserAvailableGroups.reduce(0) { total, group in
            guard let currentUser = group.members.first(where: { $0.isCurrentUser && !$0.hasLeft }) else {
                return total
            }

            let groupShare = group.expenses
                .filter { !$0.isArchived }
                .reduce(0) { subtotal, expense in
                    let activeMembers = group.members.filter { !$0.hasLeft }
                    let activeMemberIDs = Set(activeMembers.map(\.id))
                    let splitIDs = expense.splitAmongIDs.filter { activeMemberIDs.contains($0) }
                    guard splitIDs.contains(currentUser.id), !splitIDs.isEmpty else {
                        return subtotal
                    }
                    return subtotal + expense.amount / Double(splitIDs.count)
                }

            return total + groupShare
        }
    }

    private var generatedGroupBalanceItems: [BalanceItem] {
        groupManager.currentUserAvailableGroups.flatMap { group -> [BalanceItem] in
            guard let currentUser = group.members.first(where: { $0.isCurrentUser && !$0.hasLeft }) else { return [] }
            let receiptId = UserDefaults.standard.string(forKey: "groupReceipt_\(group.id.uuidString)")
            return group.expenses
                .filter { !$0.isArchived && !$0.settled }
                .flatMap { expense -> [BalanceItem] in
                    groupBalanceItems(
                        for: expense,
                        in: group,
                        currentUser: currentUser,
                        receiptId: receiptId
                    )
                }
        }
    }

    var body: some View {
        let snapshot = balanceSnapshot
        let visibleItems = filteredBalanceItems(from: snapshot.activeItems)

        return ZStack {
            ivory.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                dashedDivider
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionLabel("SUMMARY")

                        BalanceSummaryView(
                            oweTotal: snapshot.oweTotal,
                            receiveTotal: snapshot.receiveTotal,
                            totalSpent: snapshot.totalSpent
                        )

                        if snapshot.activeItems.isEmpty {
                            emptyState
                                .padding(.top, 10)
                        } else {
                            openBalancesHeader(visibleItems: visibleItems)
                                .padding(.top, 12)

                            if visibleItems.isEmpty {
                                noSearchResults
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(visibleItems) { item in
                                        let isHighlighted = router.pendingBalanceHighlightItemID == item.id
                                        BalanceSwipeRow(
                                            item: item,
                                            settleColor: positive,
                                            onSettle: { settle(item) }
                                        ) {
                                            BalanceRowView(
                                                item: item,
                                                onPrimaryAction: { handlePrimaryAction(item) },
                                                onReceipt: { openReceipt(for: item) },
                                                isHighlighted: isHighlighted
                                            )
                                        }
                                    }
                                }
                                .transaction { transaction in
                                    transaction.animation = nil
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 136)
                }
            }

            if !settledUndoItems.isEmpty {
                undoBar(items: settledUndoItems)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            refreshBalanceSnapshot()
            DispatchQueue.main.async {
                appState.startObservingBalanceItemsFromFirebaseIfPossible()
                appState.syncBalanceItemsFromFirebaseIfPossible()
            }
            clearHighlightAfterDelayIfNeeded()
        }
        .onChange(of: router.pendingBalanceHighlightItemID) { _, _ in
            clearHighlightAfterDelayIfNeeded()
        }
        .onChange(of: appState.balanceItems) { _, _ in
            refreshBalanceSnapshot()
            clearHighlightAfterDelayIfNeeded()
        }
        .onChange(of: settledGroupBalanceItemIdsStorage) { _, _ in
            refreshBalanceSnapshot()
        }
        .onReceive(groupManager.$allGroups) { _ in
            refreshBalanceSnapshot()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("BALANCES")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(.secondary)
                Text(Self.headerDateFormatter.string(from: Date()))
                    .font(.system(size: 11, weight: .regular))
                    .tracking(1)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(ivory)
    }

    private var dashedDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        let dashWidth: CGFloat = 5
                        let dashGap: CGFloat = 7
                        var x: CGFloat = 0
                        while x < geometry.size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: min(x + dashWidth, geometry.size.width), y: 0))
                            x += dashWidth + dashGap
                        }
                    }
                    .stroke(ink, lineWidth: 1.5)
                }
            )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.5)
            .foregroundColor(.secondary)
    }

    private func openBalancesHeader(visibleItems: [BalanceItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                        isBalanceSearchOpen.toggle()
                    }
                    if isBalanceSearchOpen {
                        focusedBalanceSearchField = .text
                    } else {
                        focusedBalanceSearchField = nil
                    }
                    HapticManager.impact(style: .light)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundColor(ink)
                        .frame(width: 40, height: 40)
                        .background(isBalanceSearchOpen ? chalk : Color.clear)
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink, lineWidth: 1.5)
                        )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.96))
                .accessibilityLabel("Filter balances")

                Spacer()

                if balanceSnapshot.canSettleCurrentSession {
                    ledgerActionButton("SETTLE SESSION") {
                        settle(filteredBalanceItems(from: balanceSnapshot.currentSessionItems))
                    }
                }

                ledgerActionButton("SETTLE ALL") {
                    settle(visibleItems)
                }
            }

            if isBalanceSearchOpen {
                balanceSearchPanel
            }
        }
    }

    private var balanceSearchPanel: some View {
        HStack(spacing: 8) {
            balanceSearchField(
                placeholder: "Name",
                text: $balanceSearchText,
                field: .text,
                keyboardType: .default
            )

            balanceSearchField(
                placeholder: "Min",
                text: $balanceMinAmount,
                field: .min,
                keyboardType: .decimalPad
            )
            .frame(width: 74)

            balanceSearchField(
                placeholder: "Max",
                text: $balanceMaxAmount,
                field: .max,
                keyboardType: .decimalPad
            )
            .frame(width: 74)
        }
        .padding(8)
        .background(ivory)
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(ink.opacity(0.22), lineWidth: 1.5)
        )
    }

    private func balanceSearchField(
        placeholder: String,
        text: Binding<String>,
        field: BalanceSearchField,
        keyboardType: UIKeyboardType
    ) -> some View {
        TextField(placeholder, text: text)
            .focused($focusedBalanceSearchField, equals: field)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(ink)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(chalk.opacity(0.45))
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(focusedBalanceSearchField == field ? 0.85 : 0.18), lineWidth: 1.2)
            )
    }

    private func ledgerActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.clear)
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(ink, lineWidth: 1.5)
                )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.96))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ALL SETTLED")
                .font(.system(size: 13, weight: .semibold))
                .tracking(1)
                .foregroundColor(ink)

            Text("New splits will appear here when someone owes you or when you need to pay.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ink.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(ivory)
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(ink.opacity(0.18), lineWidth: 1.5)
        )
    }

    private var noSearchResults: some View {
        Text("NO MATCHING BALANCES")
            .font(.system(size: 12, weight: .semibold))
            .tracking(1)
            .foregroundColor(ink.opacity(0.48))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func undoBar(items: [BalanceItem]) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(items.count == 1 ? "Marked settled" : "\(items.count) marked settled")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button("UNDO") {
                    undoSettle(items)
                }
                .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(ivory)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(ink)
            .cornerRadius(3)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }

    private func handlePrimaryAction(_ item: BalanceItem) {
        switch item.type {
        case .owe:
            openPayment(for: item)
        case .receive:
            sendReminder(for: item)
        }
    }

    private func openPayment(for item: BalanceItem) {
        appState.markBalanceItemRequested(id: item.id)
        router.landingFromName = appState.profile.name.isEmpty ? "You" : appState.profile.name
        router.landingToName = item.personName
        router.landingAmount = item.amount
        router.landingReceiptId = item.receiptUUID ?? UUID()
        router.landingPaymentRequestId = nil
        router.landingPayeeVenmoUsername = item.personVenmo
        router.landingPayeeVenmoLink = item.personVenmoLink
        router.landingPayeeZelleContact = item.personZelleContact
        router.landingPayeeZelleLink = item.personZelleLink
        router.showPaymentLanding = true
        HapticManager.impact(style: .light)
    }

    private func sendReminder(for item: BalanceItem) {
        appState.markBalanceItemRequested(id: item.id)
        let amount = item.formattedAmount
        let title = item.receiptTitle ?? item.groupName ?? "our split"
        let body = "Reminder from Dutch: \(item.personName), you owe \(amount) for \(title)."
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        let phone = item.personPhone?.filter { !$0.isWhitespace } ?? ""
        let urlString = phone.isEmpty ? "sms:&body=\(encodedBody)" : "sms:\(phone)&body=\(encodedBody)"
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
        HapticManager.impact(style: .light)
    }

    private func openReceipt(for item: BalanceItem) {
        guard let receiptUUID = item.receiptUUID else { return }
        router.showReceiptId = receiptUUID
        HapticManager.impact(style: .light)
    }

    private func clearHighlightAfterDelayIfNeeded() {
        guard let itemID = router.pendingBalanceHighlightItemID,
              !itemID.isEmpty else { return }
        guard balanceSnapshot.activeItems.contains(where: { $0.id == itemID }) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if router.pendingBalanceHighlightItemID == itemID {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    router.pendingBalanceHighlightItemID = nil
                }
            }
        }
    }

    private func settle(_ item: BalanceItem) {
        settle([item])
    }

    private func settle(_ items: [BalanceItem]) {
        let uniqueItems = Array(Dictionary(grouping: items, by: \.id).compactMap { $0.value.first })
        guard !uniqueItems.isEmpty else { return }

        for item in uniqueItems {
            if item.groupId != nil {
                settleGroupItem(item)
            } else {
                appState.markBalanceItemSettled(id: item.id)
            }
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            settledUndoItems = uniqueItems
        }
        HapticManager.notification(type: .success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let currentIDs = Set(uniqueItems.map(\.id))
            if Set(settledUndoItems.map(\.id)) == currentIDs {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    settledUndoItems = []
                }
            }
        }
    }

    private func undoSettle(_ items: [BalanceItem]) {
        for item in items {
            if item.groupId != nil {
                restoreGroupBalanceItem(item)
            } else {
                appState.restoreBalanceItem(id: item.id)
            }
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            settledUndoItems = []
        }
    }

    private func quickSplitSessionKey(_ item: BalanceItem) -> String {
        if let receiptId = item.receiptId, !receiptId.isEmpty {
            return "receipt-\(receiptId)"
        }
        return [
            item.receiptTitle ?? "Quick Split",
            item.sourceDate ?? item.createdAt
        ].joined(separator: "|")
    }

    private func balanceSessionKey(_ item: BalanceItem) -> String {
        if let receiptId = item.receiptId, !receiptId.isEmpty {
            return "receipt-\(receiptId)"
        }
        if let expenseID = item.relatedExpenseIds.first {
            return "expense-\(expenseID)"
        }
        return [
            item.groupId ?? "quick",
            item.receiptTitle ?? "Split",
            item.sourceDate ?? item.createdAt
        ].joined(separator: "|")
    }

    private func settleGroupItem(_ item: BalanceItem) {
        archiveGroupBalanceItem(item)
    }

    private func archiveGroupBalanceItem(_ item: BalanceItem) {
        var ids = settledGroupBalanceItemIDs
        ids.insert(item.id)
        settledGroupBalanceItemIdsStorage = ids.sorted().joined(separator: "|")
        refreshBalanceSnapshot()
    }

    private func restoreGroupBalanceItem(_ item: BalanceItem) {
        var ids = settledGroupBalanceItemIDs
        ids.remove(item.id)
        settledGroupBalanceItemIdsStorage = ids.sorted().joined(separator: "|")
        refreshBalanceSnapshot()
    }

    private func refreshBalanceSnapshot() {
        let snapshot = makeBalanceSnapshot()
        if snapshot != balanceSnapshot {
            balanceSnapshot = snapshot
        }
    }

    private func filteredBalanceItems(from items: [BalanceItem]) -> [BalanceItem] {
        let query = balanceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minAmount = currencyFilterAmount(balanceMinAmount)
        let maxAmount = currencyFilterAmount(balanceMaxAmount)

        guard !query.isEmpty || minAmount != nil || maxAmount != nil else {
            return items
        }

        return items.filter { item in
            let searchableText = [
                item.primaryText,
                item.secondaryText,
                item.personName,
                item.receiptTitle ?? "",
                item.groupName ?? "",
                item.sourceDate ?? ""
            ]
            .joined(separator: " ")
            .lowercased()

            if !query.isEmpty, !searchableText.contains(query) {
                return false
            }
            if let minAmount, item.amount < minAmount {
                return false
            }
            if let maxAmount, item.amount > maxAmount {
                return false
            }
            return true
        }
    }

    private func currencyFilterAmount(_ rawValue: String) -> Double? {
        let cleaned = rawValue
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    private func makeBalanceSnapshot() -> BalanceSnapshot {
        let storedQuickSplitItems = appState.activeBalanceItems.filter { $0.groupId == nil }
        let activeItems = (storedQuickSplitItems + generatedGroupBalanceItems)
            .filter(\.isActive)
            .filter { !settledGroupBalanceItemIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        let oweTotal = activeItems.filter { $0.type == .owe }.reduce(0) { $0 + $1.amount }
        let receiveTotal = activeItems.filter { $0.type == .receive }.reduce(0) { $0 + $1.amount }
        let currentSessionItems: [BalanceItem] = {
            guard let newestItem = activeItems.first else { return [] }
            let key = balanceSessionKey(newestItem)
            return activeItems.filter { balanceSessionKey($0) == key }
        }()

        return BalanceSnapshot(
            activeItems: activeItems,
            currentSessionItems: currentSessionItems,
            oweTotal: oweTotal,
            receiveTotal: receiveTotal,
            totalSpent: quickSplitPersonalSpend + groupPersonalSpend
        )
    }

    private func groupBalanceItems(
        for expense: GroupExpense,
        in group: DutchieGroup,
        currentUser: GroupMember,
        receiptId: String?
    ) -> [BalanceItem] {
        let activeMembers = group.members.filter { !$0.hasLeft }
        let membersByID = Dictionary(uniqueKeysWithValues: activeMembers.map { ($0.id, $0) })
        let splitIDs = expense.splitAmongIDs.filter { membersByID[$0] != nil }
        let splitCount = max(splitIDs.count, 1)
        let perPersonAmount = expense.amount / Double(splitCount)
        let createdAt = Self.expenseISOFormatter.string(from: expense.date)
        let sourceDate = shortDate(expense.date)

        if expense.addedByID == currentUser.id {
            return splitIDs.compactMap { memberID in
                guard memberID != currentUser.id,
                      let counterparty = membersByID[memberID] else { return nil }

                return groupBalanceItem(
                    id: "group-\(group.id.uuidString)-\(expense.id.uuidString)-receive-\(counterparty.id.uuidString)",
                    type: .receive,
                    amount: perPersonAmount,
                    counterparty: counterparty,
                    receiptId: receiptId,
                    receiptTitle: expense.description,
                    group: group,
                    createdAt: createdAt,
                    sourceDate: sourceDate,
                    expenseID: expense.id
                )
            }
        }

        guard splitIDs.contains(currentUser.id),
              let counterparty = membersByID[expense.addedByID] else { return [] }

        return [
            groupBalanceItem(
                id: "group-\(group.id.uuidString)-\(expense.id.uuidString)-owe-\(counterparty.id.uuidString)",
                type: .owe,
                amount: perPersonAmount,
                counterparty: counterparty,
                receiptId: receiptId,
                receiptTitle: expense.description,
                group: group,
                createdAt: createdAt,
                sourceDate: sourceDate,
                expenseID: expense.id
            )
        ]
    }

    private func groupBalanceItem(
        id: String,
        type: BalanceItem.ItemType,
        amount: Double,
        counterparty: GroupMember,
        receiptId: String?,
        receiptTitle: String,
        group: DutchieGroup,
        createdAt: String,
        sourceDate: String,
        expenseID: UUID
    ) -> BalanceItem {
        BalanceItem(
            id: id,
            type: type,
            amount: amount,
            personName: counterparty.name,
            personPhone: counterparty.phoneNumber,
            personVenmo: counterparty.venmoUsername,
            personVenmoLink: counterparty.venmoLink,
            personZelleContact: counterparty.zelleEmail,
            personZelleLink: counterparty.zelleLink,
            receiptId: receiptId,
            receiptTitle: receiptTitle,
            groupId: group.id.uuidString,
            groupName: group.name,
            status: type == .owe ? .unpaid : .requested,
            createdAt: createdAt,
            updatedAt: nil,
            lastReminderAt: nil,
            sourceDate: sourceDate,
            relatedExpenseIds: [expenseID.uuidString]
        )
    }

    private func shortDate(_ date: Date) -> String {
        Self.expenseDateFormatter.string(from: date)
    }
}

private struct BalanceSnapshot: Equatable {
    var activeItems: [BalanceItem]
    var currentSessionItems: [BalanceItem]
    var oweTotal: Double
    var receiveTotal: Double
    var totalSpent: Double

    var canSettleCurrentSession: Bool {
        currentSessionItems.count > 1
    }

    static let empty = BalanceSnapshot(
        activeItems: [],
        currentSessionItems: [],
        oweTotal: 0,
        receiveTotal: 0,
        totalSpent: 0
    )
}

struct BalanceSummaryView: View {
    let oweTotal: Double
    let receiveTotal: Double
    let totalSpent: Double

    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let chalk = Color(red: 0.95, green: 0.945, blue: 0.933)

    private var netTotal: Double {
        receiveTotal - oweTotal
    }

    private var spentProgress: Double {
        guard totalSpent > 0 else { return 0 }
        return min(max((oweTotal + receiveTotal) / totalSpent, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                summaryMetric(title: "YOU OWE", value: oweTotal)

                Divider()
                    .frame(height: 54)
                    .overlay(ink.opacity(0.14))

                summaryMetric(title: "YOU ARE OWED", value: receiveTotal)

                Divider()
                    .frame(height: 54)
                    .overlay(ink.opacity(0.14))

                summaryMetric(title: "TOTAL I SPENT", value: totalSpent)
            }

            VStack(alignment: .leading, spacing: 9) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(ink.opacity(0.10))

                        Capsule()
                            .fill(ink)
                            .frame(width: max(8, geometry.size.width * spentProgress))
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("NET \(formatSignedCurrency(netTotal))")
                    Spacer()
                    Text(activeBalanceCaption)
                }
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundColor(ink.opacity(0.50))
            }
        }
        .padding(18)
        .background(ivory)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(ink.opacity(0.18), lineWidth: 1.5)
        )
    }

    private func summaryMetric(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.66)

            Text(String(format: "$%.2f", value))
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeBalanceCaption: String {
        totalSpent > 0 ? "ACTIVE BALANCES" : "NO OPEN BALANCES"
    }

    private func formatSignedCurrency(_ value: Double) -> String {
        let prefix = value >= 0 ? "+" : "-"
        return "\(prefix)$\(String(format: "%.2f", abs(value)))"
    }
}

struct BalanceSwipeRow<Content: View>: View {
    let item: BalanceItem
    let settleColor: Color
    let onSettle: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offsetX: CGFloat = 0
    @State private var hasTriggeredSettle = false

    private let settleThreshold: CGFloat = 88

    var body: some View {
        ZStack(alignment: .leading) {
            HStack {
                Text("SETTLED")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.leading, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(settleColor)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .opacity(offsetX > 8 ? 1 : 0)

            content()
                .offset(x: offsetX)
                .gesture(
                    DragGesture(minimumDistance: 24, coordinateSpace: .local)
                        .onChanged { value in
                            guard value.translation.width > 0,
                                  abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                            offsetX = min(value.translation.width, 132)
                        }
                        .onEnded { value in
                            guard value.translation.width > 0,
                                  abs(value.translation.width) > abs(value.translation.height) * 1.6 else {
                                resetOffset()
                                return
                            }

                            if value.translation.width >= settleThreshold || value.predictedEndTranslation.width >= 150 {
                                guard !hasTriggeredSettle else { return }
                                hasTriggeredSettle = true
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                    offsetX = 180
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    onSettle()
                                }
                            } else {
                                resetOffset()
                            }
                        }
                )
        }
    }

    private func resetOffset() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            offsetX = 0
        }
    }
}

struct BalanceRowView: View {
    let item: BalanceItem
    let onPrimaryAction: () -> Void
    let onReceipt: () -> Void
    var isHighlighted: Bool = false

    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    private let chalk = Color(red: 0.95, green: 0.945, blue: 0.933)
    private let mutedInk = Color(red: 0.32, green: 0.31, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                directionBadge

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.primaryText)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(0.2)
                        .foregroundColor(ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(item.secondaryText.isEmpty ? "Quick Split" : item.secondaryText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ink.opacity(0.46))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)
            }

            HStack(spacing: 9) {
                iconButton(
                    systemName: item.type == .owe ? "dollarsign" : "bell",
                    accessibilityLabel: item.type == .owe ? "Pay" : "Remind",
                    action: onPrimaryAction
                )
                iconButton(
                    systemName: "doc.text",
                    accessibilityLabel: "Receipt",
                    isDisabled: item.receiptUUID == nil,
                    action: onReceipt
                )
                Spacer(minLength: 0)
            }
        }
        .padding(15)
        .background(isHighlighted ? chalk : ivory)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(isHighlighted ? ink.opacity(0.70) : ink.opacity(0.18), lineWidth: isHighlighted ? 2 : 1.5)
        )
    }

    private var directionBadge: some View {
        let title = item.type == .owe ? "OWE" : "OWED"
        return Text(title)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.7)
            .foregroundColor(mutedInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(chalk.opacity(0.72))
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(0.18), lineWidth: 1)
            )
    }

    private func iconButton(systemName: String, accessibilityLabel: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundColor(isDisabled ? ink.opacity(0.20) : ink)
                .frame(width: 40, height: 40)
            .background(Color.clear)
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(isDisabled ? 0.16 : 1.0), lineWidth: 1.5)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.96))
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }
}
