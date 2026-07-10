import SwiftUI
import UIKit

// MARK: - TransactionCardView

struct TransactionCardView: View {
    @Binding var transaction: Transaction
    let allPeople: [Person]
    let onDelete: () -> Void
    let onEditAmount: () -> Void
    let onEditName: () -> Void
    let onImageTap: () -> Void
    let onBreakdown: (() -> Void)?
    let onAdvancedSplit: (() -> Void)?

    @State private var showSplitOptions = false
    @State private var showPaidByOptions = false

    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme

    // MARK: - Warm receipt palette
    private let ink        = Color(red: 0.11, green: 0.10, blue: 0.08)
    private let ivory      = Color(red: 1.00, green: 0.99, blue: 0.97)
    private let cream      = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let parchment  = Color(red: 0.93, green: 0.91, blue: 0.85)
    private let redInk     = Color(red: 0.48, green: 0.12, blue: 0.12)

    // MARK: - Helpers

    private var hasCustomSplit: Bool {
        !transaction.splitQuantities.isEmpty &&
        transaction.splitQuantities.values.contains(where: { $0 > 1 })
    }

    private func weightedAmount(for person: Person) -> Double {
        let quantities = transaction.splitWith.map { p in
            transaction.splitQuantities[p.id] ?? 1
        }
        let total = quantities.reduce(0, +)
        guard total > 0 else { return transaction.perPersonAmount }
        let myQty = transaction.splitQuantities[person.id] ?? 1
        return transaction.amount * (Double(myQty) / Double(total))
    }

    private var allPeopleSelected: Bool {
        allPeople.allSatisfy { person in
            transaction.splitWith.contains(where: { $0.id == person.id })
        }
    }

    private func selectAll() {
        withAnimation(.spring(response: 0.3)) {
            for person in allPeople {
                if !transaction.splitWith.contains(where: { $0.id == person.id }) {
                    transaction.splitWith.append(person)
                }
            }
            transaction.splitQuantities = [:]
        }
        HapticManager.impact(style: .light)
    }

    private func deselectAll() {
        withAnimation(.spring(response: 0.3)) {
            transaction.splitWith = []
            transaction.splitQuantities = [:]
        }
        HapticManager.impact(style: .light)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            heavyDash
            if transaction.receiptImage != nil {
                receiptButtons
                heavyDash
            }
            paidBySection
            heavyDash
            splitSection
            heavyDash
            deleteRow
        }
        .background(ivory)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink, lineWidth: 1.5)
        )
        .cornerRadius(2)
    }

    // MARK: - Dashed dividers

    private var heavyDash: some View {
        dashedLine(opacity: 0.30)
    }

    private func dashedLine(opacity: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        let dashWidth: CGFloat = 5
                        let dashGap:   CGFloat = 5
                        var x: CGFloat = 0
                        while x < geometry.size.width {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: min(x + dashWidth, geometry.size.width), y: 0))
                            x += dashWidth + dashGap
                        }
                    }
                    .stroke(ink.opacity(opacity), lineWidth: 1)
                }
            )
    }

    // MARK: - Section band with better visibility

    private func sectionBand(
        label: String,
        value: String,
        isExpanded: Bool,
        trailingButton: AnyView? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ink.opacity(0.65))
                    .tracking(1.8)
                    .textCase(.uppercase)

                Circle()
                    .fill(ink.opacity(0.40))
                    .frame(width: 3, height: 3)

                Text(value)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ink)

                Spacer()

                if let btn = trailingButton {
                    btn
                }

                // Chevron in a circle
                ZStack {
                    Circle()
                        .stroke(ink.opacity(0.30), lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                    Text(isExpanded ? "▴" : "▾")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ink.opacity(0.65))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(ivory)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Header row - improved visibility

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onEditName) {
                    HStack(spacing: 6) {
                        Text(transaction.merchant.uppercased())
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(ink)
                            .tracking(0.3)
                            .multilineTextAlignment(.leading)
                        editBadge
                    }
                }
                .buttonStyle(PlainButtonStyle())

                if transaction.isManual {
                    Text("MANUAL ENTRY")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ink.opacity(0.55))
                        .tracking(1.2)
                } else if transaction.receiptImage != nil {
                    Text("RECEIPT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ink.opacity(0.55))
                        .tracking(1.2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Button(action: onEditAmount) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(transaction.formattedAmount)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(ink)
                        editBadge
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var editBadge: some View {
        Text("EDIT")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(ink.opacity(0.55))
            .tracking(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(0.28), lineWidth: 1.5)
            )
    }

    // MARK: - Receipt action buttons - improved visibility

    private var receiptButtons: some View {
        HStack(spacing: 10) {
            Button(action: onImageTap) {
                HStack(spacing: 8) {
                    receiptIcon
                    Text("VIEW RECEIPT")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ink)
                        .tracking(0.5)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(ink, lineWidth: 1.5)
                )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.97))

            if let breakdown = onBreakdown {
                Button(action: breakdown) {
                    HStack(spacing: 8) {
                        linesIcon
                        Text("BREAK DOWN")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(ink)
                            .tracking(0.5)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(ink, lineWidth: 1.5)
                    )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.97))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var receiptIcon: some View {
        VStack(spacing: 2) {
            Rectangle().fill(ink).frame(width: 12, height: 2)
            Rectangle().fill(ink).frame(width: 10, height: 2)
            Rectangle().fill(ink).frame(width: 12, height: 2)
        }
    }

    private var linesIcon: some View {
        VStack(spacing: 2) {
            Rectangle().fill(ink).frame(width: 12, height: 2)
            Rectangle().fill(ink).frame(width: 12, height: 2)
            Rectangle().fill(ink).frame(width: 12, height: 2)
        }
    }

    // MARK: - Paid By section

    private var paidBySection: some View {
        VStack(spacing: 0) {
            sectionBand(
                label: "Paid by",
                value: transaction.paidBy.name,
                isExpanded: showPaidByOptions,
                action: {
                    withAnimation(.spring(response: 0.3)) { showPaidByOptions.toggle() }
                }
            )

            if showPaidByOptions {
                VStack(spacing: 0) {
                    ForEach(allPeople) { person in
                        paidByRow(person: person)
                        if person.id != allPeople.last?.id {
                            Divider()
                                .background(ink.opacity(0.08))
                        }
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func paidByRow(person: Person) -> some View {
        let isSelected = transaction.paidBy.id == person.id
        return Button(action: {
            withAnimation(.spring(response: 0.3)) {
                transaction.paidBy = person
                showPaidByOptions = false
            }
        }) {
            HStack(spacing: 12) {
                checkboxView(checked: isSelected)
                AvatarView(imageData: person.contactImage, initials: person.initials, size: 32)
                    .overlay(Circle().stroke(ink.opacity(0.16), lineWidth: 1))
                    .opacity(isSelected ? 1 : 0.45)
                Text(person.name)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? ink : ink.opacity(0.50))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(isSelected ? ivory : parchment.opacity(0.45))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Split section

    private var splitSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sectionBand(
                    label: "Split with",
                    value: "\(transaction.splitWith.count) \(transaction.splitWith.count == 1 ? "person" : "people")",
                    isExpanded: showSplitOptions,
                    trailingButton: onAdvancedSplit != nil ? AnyView(advancedButton) : nil,
                    action: {
                        withAnimation(.spring(response: 0.3)) { showSplitOptions.toggle() }
                    }
                )
            }

            if showSplitOptions {
                VStack(spacing: 0) {
                    // Select all / Reset row
                    HStack(spacing: 10) {
                        Button(action: {
                            if allPeopleSelected { deselectAll() } else { selectAll() }
                        }) {
                            Text(allPeopleSelected ? "DESELECT ALL" : "SELECT ALL")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(allPeopleSelected ? redInk : ink.opacity(0.65))
                                .tracking(1.2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(
                                            allPeopleSelected ? redInk.opacity(0.5) : ink.opacity(0.25),
                                            lineWidth: 1.5
                                        )
                                )
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.95))

                        Spacer()

                        if hasCustomSplit {
                            Button(action: {
                                withAnimation(.spring(response: 0.3)) {
                                    transaction.splitQuantities = [:]
                                }
                            }) {
                                Text("RESET EQUAL")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(ink.opacity(0.60))
                                    .tracking(0.8)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(ink.opacity(0.20), lineWidth: 1.5)
                                    )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.95))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    VStack(spacing: 0) {
                        ForEach(allPeople) { person in
                            personSplitRow(person: person)
                            if person.id != allPeople.last?.id {
                                Divider()
                                    .background(ink.opacity(0.08))
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var advancedButton: some View {
        Button(action: { onAdvancedSplit?() }) {
            HStack(spacing: 6) {
                VStack(spacing: 2) {
                    Rectangle().fill(hasCustomSplit ? Color.white : ink).frame(width: 12, height: 2)
                    Rectangle().fill(hasCustomSplit ? Color.white : ink).frame(width: 12, height: 2)
                    Rectangle().fill(hasCustomSplit ? Color.white : ink).frame(width: 8,  height: 2)
                }
                Text("ADVANCED")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(hasCustomSplit ? .white : ink)
                    .tracking(0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(hasCustomSplit ? ink : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink, lineWidth: 1.5)
            )
            .cornerRadius(2)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.95))
    }

    private func personSplitRow(person: Person) -> some View {
        let isIncluded = isPersonIncluded(person)
        let amount: Double = hasCustomSplit && isIncluded
            ? weightedAmount(for: person)
            : transaction.perPersonAmount
        let customWeight: Int? = hasCustomSplit ? (transaction.splitQuantities[person.id] ?? 1) : nil

        return Button(action: { togglePersonInSplit(person) }) {
            HStack(spacing: 12) {
                checkboxView(checked: isIncluded)

                AvatarView(imageData: person.contactImage, initials: person.initials, size: 32)
                    .overlay(Circle().stroke(ink.opacity(0.12), lineWidth: 1))
                    .opacity(isIncluded ? 1 : 0.40)

                Text(person.name)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(isIncluded ? ink : ink.opacity(0.48))

                if let weight = customWeight, isIncluded, weight > 1 {
                    Text("\(weight)×")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .tracking(0.3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ink)
                        .cornerRadius(2)
                }

                Spacer()

                if isIncluded {
                    Text(String(format: "$%.2f", amount))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ink.opacity(0.60))
                } else {
                    Text("—")
                        .font(.system(size: 15))
                        .foregroundColor(ink.opacity(0.25))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(isIncluded ? ivory : parchment.opacity(0.42))
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
        .animation(.spring(response: 0.25), value: isIncluded)
    }

    // MARK: - Shared checkbox - larger and more visible

    private func checkboxView(checked: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(checked ? ink : Color.clear)
                .frame(width: 18, height: 18)
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink, lineWidth: 1.5)
                .frame(width: 18, height: 18)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - Delete row - more visible

    private var deleteRow: some View {
        Button(action: onDelete) {
            Text("REMOVE TRANSACTION")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(redInk)
                .tracking(1.2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .buttonStyle(PlainButtonStyle())
        .background(redInk.opacity(0.06))
    }

    // MARK: - Helpers

    private func isPersonIncluded(_ person: Person) -> Bool {
        transaction.splitWith.contains(where: { $0.id == person.id })
    }

    private func togglePersonInSplit(_ person: Person) {
        withAnimation(.spring(response: 0.3)) {
            if let index = transaction.splitWith.firstIndex(where: { $0.id == person.id }) {
                transaction.splitWith.remove(at: index)
                transaction.splitQuantities.removeValue(forKey: person.id)
            } else {
                transaction.splitWith.append(person)
            }
        }
    }
}
