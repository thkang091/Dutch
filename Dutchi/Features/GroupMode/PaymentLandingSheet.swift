import SwiftUI
import UIKit
import FirebaseDatabase

// MARK: - Payment Landing Sheet
// Presented when recipient taps the deep link from a Dutch message.
// Shows all payments the "from" person owes in this receipt split.

struct PaymentLandingSheet: View {
    let fromName:  String
    let toName:    String
    let amount:    Double
    let receiptId: UUID
    var payeeVenmoUsername: String?
    var payeeVenmoLink: String?
    var payeeZelleContact: String?
    var payeeZelleLink: String?

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @StateObject private var groupManager = GroupManager.shared
    @Environment(\.dismiss) var dismiss

    // Design tokens
    private let ivory  = Color(red: 1.0,  green: 0.992, blue: 0.969)
    private let ink    = Color(red: 0.10, green: 0.10,  blue: 0.10)
    private let chalk  = Color(red: 0.95, green: 0.945, blue: 0.933)
    private let border = Color(red: 0.82, green: 0.80,  blue: 0.776)

    // All settlements this person owes (may be > 1)
    private var allPaymentsDue: [PaymentLink] {
        let localPayments = appState.calculateSettlements().filter { $0.from.name == fromName }
        if !localPayments.isEmpty { return localPayments }

        return [
            PaymentLink(
                from: Person(name: fromName, isCurrentUser: true),
                to: Person(name: toName),
                amount: amount
            )
        ]
    }

    // The primary payment from the deep link (shown first / highlighted)
    private var primaryPayment: PaymentLink? {
        allPaymentsDue.first(where: { $0.to.name == toName })
            ?? allPaymentsDue.first
    }

    @State private var markedPaid: Set<UUID> = []

    func payeePaymentMethods(
        venmoUsername: String?,
        venmoLink: String?,
        zelleContact: String?,
        zelleLink: String?
    ) -> Self {
        var copy = self
        copy.payeeVenmoUsername = venmoUsername
        copy.payeeVenmoLink = venmoLink
        copy.payeeZelleContact = zelleContact
        copy.payeeZelleLink = zelleLink
        return copy
    }

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()

            VStack(spacing: 0) {
                handle
                headerSection
                dashedDivider.padding(.horizontal, 20)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        if allPaymentsDue.isEmpty {
                            allSettledView
                        } else {
                            ForEach(allPaymentsDue) { payment in
                                paymentCard(payment: payment)
                            }
                        }

                        receiptButton
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    // MARK: - Handle

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(ink.opacity(0.2))
            .frame(width: 36, height: 4)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 4) {
            Text("YOU OWE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ink.opacity(0.45))
                .tracking(2)

            Text(fromName == appState.people.first(where: { $0.isCurrentUser })?.name
                 ? toName : toName)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ink)

            Text(String(format: "$%.2f", amount))
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(Color(red: 0.78, green: 0.25, blue: 0.18))
                .tracking(-1)

            if allPaymentsDue.count > 1 {
                Text("\(allPaymentsDue.count) payments total from this split")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ink.opacity(0.40))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    // MARK: - Payment Card

    private func paymentCard(payment: PaymentLink) -> some View {
        let isPaid = markedPaid.contains(payment.id)
        let isPrimary = payment.to.name == toName && payment.amount == amount

        return VStack(spacing: 12) {
            // Recipient row
            HStack(spacing: 12) {
                AvatarView(
                    imageData: payment.to.contactImage,
                    initials: payment.to.initials,
                    size: 44
                )
                .overlay(Circle().stroke(isPrimary ? Color(red: 0.78, green: 0.25, blue: 0.18).opacity(0.3) : border, lineWidth: 1.5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(payment.to.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(ink)
                    Text(isPaid ? "Marked as paid" : "Owes from split")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isPaid ? Color(red: 0.18, green: 0.50, blue: 0.32) : ink.opacity(0.45))
                }

                Spacer()

                Text(payment.formattedAmount)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(isPaid
                        ? Color(red: 0.18, green: 0.50, blue: 0.32)
                        : Color(red: 0.78, green: 0.25, blue: 0.18))
            }

            if isPaid {
                // Paid state
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("PAID")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                }
                .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(red: 0.87, green: 0.95, blue: 0.90))
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(red: 0.18, green: 0.50, blue: 0.32).opacity(0.3), lineWidth: 1)
                )
            } else {
                // Payment action buttons
                let venmoURL = venmoDeepLink(for: payment)
                let zelleURL = zelleDeepLink(for: payment)

                if venmoURL != nil || zelleURL != nil {
                    HStack(spacing: 8) {
                        if let venmo = venmoURL {
                            Button(action: {
                                HapticManager.impact(style: .medium)
                                UIApplication.shared.open(venmo) { success in
                                    if !success, let store = URL(string: "https://apps.apple.com/app/venmo/id351727428") {
                                        UIApplication.shared.open(store)
                                    }
                                }
                            }) {
                                HStack(spacing: 6) {
                                    VenmoIcon(size: 14)
                                    Text("PAY WITH VENMO")
                                        .font(.system(size: 12, weight: .bold))
                                        .tracking(0.5)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(red: 0.18, green: 0.50, blue: 0.90))
                                .cornerRadius(2)
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.98))
                        }

                        if let zelle = zelleURL {
                            Button(action: {
                                HapticManager.impact(style: .medium)
                                UIApplication.shared.open(zelle)
                            }) {
                                HStack(spacing: 6) {
                                    ZelleIcon(size: 14)
                                    Text("ZELLE")
                                        .font(.system(size: 12, weight: .bold))
                                        .tracking(0.5)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(red: 0.38, green: 0.16, blue: 0.58))
                                .cornerRadius(2)
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.98))
                        }
                    }
                } else {
                    // No payment methods set up for recipient
                    Text("Ask \(payment.to.name) to add their Venmo or Zelle in Dutch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ink.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(chalk)
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(border, lineWidth: 1)
                        )
                }

                // Mark as paid button
                Button(action: {
                    HapticManager.notification(type: .success)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        markedPaid.insert(payment.id)
                    }
                    groupManager.markSettlementPaid(from: payment.from, to: payment.to, amount: payment.amount)
                    markPaymentRequestPaidIfNeeded()
                }) {
                    Text("MARK AS PAID")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(ink.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.clear)
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .foregroundColor(border)
                        )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.98))
            }
        }
        .padding(16)
        .background(isPrimary && !isPaid
            ? Color(red: 0.97, green: 0.89, blue: 0.87)
            : ivory)
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(
                    isPrimary && !isPaid
                        ? Color(red: 0.78, green: 0.25, blue: 0.18).opacity(0.3)
                        : border,
                    lineWidth: isPrimary && !isPaid ? 1.5 : 1
                )
        )
    }

    // MARK: - Receipt Button

    private var receiptButton: some View {
        Button(action: {
            HapticManager.impact(style: .light)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                router.showReceiptId = receiptId
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 11, weight: .medium))
                Text("VIEW RECEIPT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
            }
            .foregroundColor(ink.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.clear)
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundColor(border)
            )
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }

    // MARK: - All Settled View

    private var allSettledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
            Text("ALL SETTLED")
                .font(.system(size: 14, weight: .bold))
                .tracking(1.5)
                .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
            Text("No pending payments for this split.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ink.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Dashed Divider

    private var dashedDivider: some View {
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
                    .stroke(ink.opacity(0.25), lineWidth: 1.5)
                }
            )
    }

    // MARK: - Payment Link Builders
    // Pulls from the recipient's group member data

    private func venmoDeepLink(for payment: PaymentLink) -> URL? {
        let amt  = String(format: "%.2f", payment.amount)
        let note = "Split payment".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Split%20payment"

        if let username = payeeVenmoUsername?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            let clean = username.replacingOccurrences(of: "@", with: "")
            return URL(string: "venmo://paycharge?txn=pay&recipients=\(clean)&amount=\(amt)&note=\(note)")
        }
        if let link = payeeVenmoLink?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
            return URL(string: link)
        }

        guard let member = groupManager.activeGroup?.members.first(where: { $0.name == payment.to.name })
        else { return nil }

        if let username = member.venmoUsername, !username.isEmpty {
            let clean = username.replacingOccurrences(of: "@", with: "")
            return URL(string: "venmo://paycharge?txn=pay&recipients=\(clean)&amount=\(amt)&note=\(note)")
        }
        if let link = member.venmoLink, !link.isEmpty {
            return URL(string: link)
        }
        return nil
    }

    private func zelleDeepLink(for payment: PaymentLink) -> URL? {
        let amt = String(format: "%.2f", payment.amount)

        if let link = payeeZelleLink?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
            return URL(string: link)
        }
        if let contact = payeeZelleContact?.trimmingCharacters(in: .whitespacesAndNewlines), !contact.isEmpty {
            let encoded = contact.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? contact
            return URL(string: "zelle://payment?token=\(encoded)&amount=\(amt)")
        }

        guard let member = groupManager.activeGroup?.members.first(where: { $0.name == payment.to.name })
        else { return nil }

        if let link = member.zelleLink, !link.isEmpty {
            return URL(string: link)
        }
        if let email = member.zelleEmail, !email.isEmpty {
            let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
            return URL(string: "zelle://payment?token=\(encoded)&amount=\(amt)")
        }
        return nil
    }

    private func markPaymentRequestPaidIfNeeded() {
        guard let requestID = router.landingPaymentRequestId else { return }
        Database.database().reference()
            .child("paymentRequests")
            .child(requestID)
            .updateChildValues([
                "status": "paid",
                "paidAt": ISO8601DateFormatter().string(from: Date())
            ])

        if let groupID = groupManager.activeGroup?.id.uuidString {
            ActivityStore.markPaymentRequestPaid(
                groupID: groupID,
                requestID: requestID
            )
        }
    }
}
