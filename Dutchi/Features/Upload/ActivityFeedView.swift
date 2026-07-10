import SwiftUI
import FirebaseDatabase

// MARK: - Palette

private let ink    = Color(red: 0.11, green: 0.10, blue: 0.08)
private let ivory  = Color(red: 1.00, green: 0.99, blue: 0.97)
private let cream  = Color(red: 1.00, green: 0.992, blue: 0.969)
private let parch  = Color(red: 0.93, green: 0.91, blue: 0.87)

// MARK: - ActivityFeedView

struct ActivityFeedView: View {
    @ObservedObject var store: ActivityStore
    let currentUserPhone: String?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: Router

    @State private var showClearConfirm = false
    @State private var selectedTab: ActivityFeedTab = .all

    private var allEntries: [ActivityFeedEntry] {
        ActivityFeedEntry.organize(store.activities)
    }

    private var visibleEntries: [ActivityFeedEntry] {
        allEntries.filter { selectedTab.includes($0, viewerPhone: currentUserPhone) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabBar
                fullDash
                content
            }
        }
        .onAppear {
            store.setAttentionPhone(currentUserPhone)
            store.markAllRead()
        }
        .confirmationDialog("Clear all activity?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { store.clearAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes your local copy. It cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ACTIVITY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ink.opacity(0.45))
                    .tracking(3)
                Text("Latest updates from your groups")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(ink.opacity(0.52))
            }
            Spacer()
            Menu {
                if !store.activities.isEmpty {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                }
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(ink)
                    .frame(width: 36, height: 32)
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(cream)
    }

    // MARK: - Content

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ActivityFeedTab.allCases) { tab in
                    Button {
                        HapticManager.impact(style: .light)
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Text(tab.title)
                            let count = tabCount(for: tab)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(selectedTab == tab ? cream : ink.opacity(0.48))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(selectedTab == tab ? cream.opacity(0.20) : ink.opacity(0.06))
                                    )
                            }
                        }
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(selectedTab == tab ? cream : ink.opacity(0.58))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(selectedTab == tab ? ink : ivory)
                        )
                        .overlay(
                            Capsule()
                                .stroke(ink.opacity(selectedTab == tab ? 0 : 0.10), lineWidth: 1)
                        )
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .background(cream)
    }

    @ViewBuilder
    private var content: some View {
        if visibleEntries.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedSections, id: \.label) { section in
                        Section {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(section.groups, id: \.groupName) { group in
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(group.groupName)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(ink)
                                            .padding(.bottom, 6)
                                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                            ActivityCard(
                                                entry: entry,
                                                currentUserPhone: currentUserPhone
                                            ) {
                                                entry.activities.forEach { store.delete(id: $0.id) }
                                            } onDismiss: {
                                                dismiss()
                                            }
                                            if index < group.entries.count - 1 {
                                                Rectangle()
                                                    .fill(ink.opacity(0.08))
                                                    .frame(height: 1)
                                                    .padding(.vertical, 10)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                        } header: {
                            sectionHeader(section.label)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(ink.opacity(0.35))
                .tracking(2.5)
            Rectangle()
                .fill(ink.opacity(0.10))
                .frame(height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(cream)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 56)
            // Receipt-style empty state icon
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(0.12), lineWidth: 1.5)
                    .frame(width: 56, height: 64)
                VStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(ink.opacity(0.12))
                            .frame(width: CGFloat([28, 22, 18][i]), height: 2)
                    }
                }
            }
            Text("Nothing yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ink.opacity(0.4))
            Text(selectedTab.emptyMessage)
                .font(.system(size: 12))
                .foregroundColor(ink.opacity(0.28))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Helpers

    private var fullDash: some View {
        DashedLine(color: ink.opacity(0.18))
            .padding(.horizontal, 20)
    }

    private func tabCount(for tab: ActivityFeedTab) -> Int {
        allEntries.filter { tab.includes($0, viewerPhone: currentUserPhone) }.count
    }

    private var groupedSections: [ActivityDateSection] {
        let calendar     = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfWeek  = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var today:    [ActivityFeedEntry] = []
        var thisWeek: [ActivityFeedEntry] = []
        var earlier:  [ActivityFeedEntry] = []

        for entry in visibleEntries {
            if entry.timestamp >= startOfToday        { today.append(entry) }
            else if entry.timestamp >= startOfWeek    { thisWeek.append(entry) }
            else                                      { earlier.append(entry) }
        }

        var sections: [ActivityDateSection] = []
        if !today.isEmpty    { sections.append(ActivityDateSection(label: "Today", entries: today)) }
        if !thisWeek.isEmpty { sections.append(ActivityDateSection(label: "This Week", entries: thisWeek)) }
        if !earlier.isEmpty  { sections.append(ActivityDateSection(label: "Earlier", entries: earlier)) }
        return sections
    }
}

private enum ActivityFeedTab: String, CaseIterable, Identifiable {
    case all
    case action
    case receipts
    case groups

    var id: Self { self }

    var title: String {
        switch self {
        case .all:      return "ALL"
        case .action:   return "URGENT"
        case .receipts: return "RECEIPTS"
        case .groups:   return "GROUPS"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all:
            return "Group expenses, joins, and settlements\nwill appear here as they happen."
        case .action:
            return "Payment requests and incomplete actions\nthat need your attention will appear here."
        case .receipts:
            return "Receipt uploads and expense batches\nwill appear here."
        case .groups:
            return "Group joins, departures, and settlements\nwill appear here."
        }
    }

    func includes(_ entry: ActivityFeedEntry, viewerPhone: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .action:
            return entry.primary.needsAttention(for: viewerPhone)
        case .receipts:
            return entry.primary.type == .expenseAdded
        case .groups:
            switch entry.primary.type {
            case .memberJoined, .memberLeft, .groupSettled, .paymentConfirmed:
                return true
            case .expenseAdded, .paymentRequested:
                return false
            }
        }
    }
}

private struct ActivityDateSection {
    let label: String
    let entries: [ActivityFeedEntry]

    var groups: [ActivityGroupSection] {
        var result: [ActivityGroupSection] = []
        for entry in entries {
            if let index = result.firstIndex(where: { $0.groupName == entry.groupName }) {
                result[index].entries.append(entry)
            } else {
                result.append(ActivityGroupSection(groupName: entry.groupName, entries: [entry]))
            }
        }
        return result
    }
}

private struct ActivityGroupSection {
    let groupName: String
    var entries: [ActivityFeedEntry]
}

// MARK: - ActivityFeedEntry

private struct ActivityFeedEntry: Identifiable {
    let activities: [GroupActivity]

    var id: String {
        if let batchID = primary.receiptBatchID, isReceiptBatch {
            return "receipt-\(primary.groupID)-\(batchID)"
        }
        if isExpenseSummary {
            return "expense-summary-\(primary.groupID)-\(primary.actorName)-\(Int(primary.timestamp.timeIntervalSince1970 / 90))-\(activities.map(\.id).joined(separator: "-"))"
        }
        return primary.id
    }

    var primary: GroupActivity { activities[0] }
    var timestamp: Date { activities.map(\.timestamp).max() ?? primary.timestamp }
    var isRead: Bool { activities.allSatisfy(\.isRead) }
    var isReceiptBatch: Bool {
        primary.type == .expenseAdded && activities.count > 1 && primary.receiptBatchID != nil
    }
    var isExpenseSummary: Bool {
        primary.type == .expenseAdded && activities.count > 1 && primary.receiptBatchID == nil
    }
    var actorName: String { primary.actorName }
    var groupName: String { primary.groupName }
    var totalAmount: Double? {
        if isReceiptBatch || isExpenseSummary {
            return activities.compactMap(\.amount).reduce(0, +)
        }
        return primary.amount
    }
    var itemCount: Int { activities.count }
    var detail: String {
        if isReceiptBatch {
            return "\(actorName) added a receipt"
        }
        if isExpenseSummary {
            return "\(activities.count) expenses added"
        }

        switch primary.type {
        case .expenseAdded:
            return "\(actorName) added \(primary.detail)"
        case .memberJoined:
            return "\(actorName) joined the group"
        case .memberLeft:
            return "\(actorName) left the group"
        case .groupSettled:
            return primary.detail.isEmpty ? "Group settled" : primary.detail
        case .paymentRequested:
            return "\(actorName) requested payment"
        case .paymentConfirmed:
            return primary.detail.isEmpty ? "Payment confirmed" : primary.detail
        }
    }

    var metadata: String {
        if isReceiptBatch {
            return "\(activities.count) items · \(Self.relativeTime(timestamp))"
        }
        return Self.relativeTime(timestamp)
    }

    static func organize(_ activities: [GroupActivity]) -> [ActivityFeedEntry] {
        let sorted = activities.sorted { $0.timestamp > $1.timestamp }
        var consumed = Set<String>()
        var entries: [ActivityFeedEntry] = []

        for activity in sorted {
            guard !consumed.contains(activity.id) else { continue }

            let batch = receiptBatch(for: activity, in: sorted, consumed: consumed)
            if batch.count > 1 {
                batch.forEach { consumed.insert($0.id) }
                entries.append(ActivityFeedEntry(activities: batch.sorted { $0.timestamp > $1.timestamp }))
            } else {
                consumed.insert(activity.id)
                entries.append(ActivityFeedEntry(activities: [activity]))
            }
        }

        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    private static func receiptBatch(
        for activity: GroupActivity,
        in activities: [GroupActivity],
        consumed: Set<String>
    ) -> [GroupActivity] {
        guard activity.type == .expenseAdded else { return [activity] }

        if let batchID = activity.receiptBatchID, !batchID.isEmpty {
            return activities.filter {
                !consumed.contains($0.id) &&
                $0.type == .expenseAdded &&
                $0.groupID == activity.groupID &&
                $0.receiptBatchID == batchID
            }
        }

        return activities.filter {
            !consumed.contains($0.id) &&
            $0.type == .expenseAdded &&
            $0.receiptBatchID == nil &&
            $0.groupID == activity.groupID &&
            $0.actorName == activity.actorName &&
            abs($0.timestamp.timeIntervalSince(activity.timestamp)) <= 90
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60     { return "just now" }
        if s < 3600   { return "\(s / 60)m ago" }
        if s < 86400  { return "\(s / 3600)h ago" }
        let d = s / 86400
        return d == 1 ? "Yesterday" : "\(d)d ago"
    }
}

// MARK: - ActivityCard

private struct ActivityCard: View {
    let entry: ActivityFeedEntry
    let currentUserPhone: String?
    let onDelete: () -> Void
    let onDismiss: () -> Void
    @EnvironmentObject private var router: Router

    var body: some View {
        Button(action: {
            if needsAction {
                handleAction()
            }
        }) {
            topRow
        }
        .buttonStyle(.plain)
        .padding(.horizontal, needsAction ? 12 : 0)
        .padding(.vertical, needsAction ? 11 : 0)
        .background(needsAction ? Color(red: 1.00, green: 0.985, blue: 0.94) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(needsAction ? Color(red: 0.52, green: 0.20, blue: 0.16).opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                HapticManager.notification(type: .warning)
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var activity: GroupActivity { entry.primary }
    private var actionLabel: String? { activity.actionLabel(for: currentUserPhone) }
    private var needsAction: Bool { actionLabel != nil }
    private var metadata: String {
        needsAction ? "Tap to review · \(entry.metadata)" : entry.metadata
    }

    // MARK: - Top row

    private var topRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if needsAction {
                        Text("URGENT")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1.4)
                            .foregroundColor(Color(red: 0.52, green: 0.20, blue: 0.16))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.52, green: 0.20, blue: 0.16).opacity(0.08))
                            )
                    }
                    Text(entry.detail)
                        .font(.system(size: 13, weight: needsAction ? .semibold : .regular))
                        .foregroundColor(ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.isRead && needsAction {
                        Circle()
                            .fill(ink)
                            .frame(width: 5, height: 5)
                    }
                }
                Text(metadata)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ink.opacity(needsAction ? 0.50 : 0.38))
            }
            Spacer(minLength: 8)
            if let amount = entry.totalAmount {
                Text(String(format: "$%.2f", amount))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ink)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Action handler

    private func handleAction() {
        HapticManager.impact(style: .medium)

        switch activity.type {
        case .paymentRequested:
            if let urlStr = activity.actionURL, let url = URL(string: urlStr) {
                if openDutchiePaymentRequest(url) {
                    onDismiss()
                } else {
                    onDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        UIApplication.shared.open(url)
                    }
                }
            } else {
                onDismiss()
            }

        case .expenseAdded, .memberJoined:
            onDismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NotificationCenter.default.post(name: .openGroupDetail, object: nil)
            }

        default:
            onDismiss()
        }
    }

    private func openDutchiePaymentRequest(_ url: URL) -> Bool {
        guard let requestID = paymentRequestID(from: url) else { return false }

        Database.database().reference()
            .child("paymentRequests")
            .child(requestID)
            .observeSingleEvent(of: .value, with: { snapshot in
                guard let dict = snapshot.value as? [String: Any] else {
                    print("❌ Activity payment request not found: \(requestID)")
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
                    router.showLogoIntro = false
                    router.showPaymentLanding = true
                    print("✅ Opened activity payment request: \(requestID)")
                }
            })

        return true
    }

    private func paymentRequestID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        if (url.scheme == "dutch" || url.scheme == "dutchie"),
           url.host == "pay",
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

}

// MARK: - DashedLine

private struct DashedLine: View {
    let color: Color

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        let dw: CGFloat = 5
                        let dg: CGFloat = 5
                        var x: CGFloat = 0
                        while x < geometry.size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: min(x + dw, geometry.size.width), y: 0))
                            x += dw + dg
                        }
                    }
                    .stroke(color, lineWidth: 1.5)
                }
            )
    }
}

// MARK: - Bell button

struct ActivityBellButton: View {
    @ObservedObject var store: ActivityStore
    let currentUserPhone: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(cream)
                        .frame(width: 44, height: 44)
                        .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    Image(systemName: store.unreadCount > 0 ? "bell.badge" : "bell")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(ink.opacity(0.75))
                }
                if store.unreadCount > 0 {
                    ZStack {
                        Circle()
                            .fill(ink)
                            .frame(width: 18, height: 18)
                        Text(store.unreadCount > 9 ? "9+" : "\(store.unreadCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(cream)
                    }
                    .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .onAppear {
            store.setAttentionPhone(currentUserPhone)
        }
        .onChange(of: currentUserPhone) { _, newPhone in
            store.setAttentionPhone(newPhone)
        }
    }
}
