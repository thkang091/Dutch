import SwiftUI

// MARK: - Shared palette

private let legalInk   = Color(red: 0.11, green: 0.10, blue: 0.08)
private let legalCream = Color(red: 1.00, green: 0.992, blue: 0.969)

// MARK: - Terms of Use

struct TermsOfUseView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                legalCream.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        LegalHeader(title: "Terms of Use", updated: "Last updated: June 2025")
                        LegalDivider()

                        LegalSection(title: "1. Acceptance",
                            body: "By downloading or using Dutchi, you agree to these Terms of Use. If you do not agree, do not use the app.")

                        LegalSection(title: "2. What Dutchi Does",
                            body: "Dutchi helps you scan receipts, PDF documents, and bank statements to split expenses among groups of people. Dutchi does not process payments — it generates prefilled links for Venmo, Zelle, or other payment services that you choose to use.")

                        LegalSection(title: "3. Subscriptions and Billing", body: """
Dutchi Pro is an auto-renewable subscription available through the Apple App Store.

• Subscriptions are billed to your Apple ID account at the price shown at the time of purchase.
• Your subscription renews automatically unless cancelled at least 24 hours before the end of the current period.
• You can manage or cancel your subscription at any time through your Apple ID account settings.
• A free trial, when offered, will automatically convert to a paid subscription unless cancelled before the trial ends.
• No refunds are provided for partial subscription periods except as required by applicable law.
""")

                        LegalSection(title: "4. User Content",
                            body: "You may scan receipts, PDF files, and financial documents within Dutchi. You are responsible for having the right to use any documents you upload. Dutchi processes these locally or through encrypted third-party services solely to provide the expense-splitting feature. We do not sell your financial data.")

                        LegalSection(title: "5. Contacts",
                            body: "Dutchi may request access to your contacts to help you add people to expense splits. Contact data is used only within the app to prefill names and is not shared with third parties.")

                        LegalSection(title: "6. Acceptable Use", body: """
You agree not to:
• Use Dutchi for any unlawful purpose
• Attempt to reverse-engineer or tamper with the app
• Use the app to harass, defraud, or deceive others
""")

                        LegalSection(title: "7. Disclaimer",
                            body: "Dutchi is provided \"as is\" without any warranty of any kind. We do not guarantee that the app will always be available, error-free, or that AI-assisted itemization will be perfectly accurate. Always verify splits before sending payment requests.")

                        LegalSection(title: "8. Limitation of Liability",
                            body: "To the maximum extent permitted by law, Dutchi and its creators shall not be liable for any indirect, incidental, or consequential damages arising from your use of the app, including any financial disputes between users.")

                        LegalSection(title: "9. Changes to These Terms",
                            body: "We may update these Terms from time to time. Continued use of Dutchi after any changes constitutes your acceptance of the new Terms. We will notify you of significant changes through the app.")

                        LegalSection(title: "10. Governing Law",
                            body: "These Terms are governed by the laws of the United States. Any disputes will be resolved in the jurisdiction where you reside.")

                        LegalSection(title: "11. Contact",
                            body: "Questions about these Terms? Email us at support@dutchieapp.com.")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 60)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(legalInk)
                    }
                }
            }
        }
    }
}

// MARK: - Privacy Policy

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                legalCream.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        LegalHeader(title: "Privacy Policy", updated: "Last updated: June 2025")
                        LegalDivider()

                        LegalSection(title: "Overview",
                            body: "Dutchi is built around the principle that your financial data is yours. We collect only what is necessary to run the app, and we never sell your data.")

                        LegalSection(title: "1. Information We Collect", body: """
Phone number — used to create your account and link you to expense groups via Firebase Authentication.

Receipt and document images — photos, PDFs, and screenshots you scan are processed to extract line items. Images may be sent to our OCR service and are not retained beyond the session.

Expense data — split amounts, group names, and people you split with are stored locally and synced to Firebase when you use Group Mode or shared features.

Contacts — if you grant permission, Dutchi reads contact names and phone numbers to prefill group members. This data stays on your device and is not uploaded to our servers.

Payment usernames — if you add a Venmo or Zelle handle, it is stored in your profile to prefill payment links and is not shared beyond what you explicitly send.

Usage data — we collect anonymized crash reports and basic analytics to improve the app. This data does not identify you personally.
""")

                        LegalSection(title: "2. How We Use Your Information", body: """
• To authenticate your account and sync data across devices
• To generate expense splits and payment request links
• To operate Group Mode and recurring splits
• To improve app performance and fix bugs
• To send payment reminders you explicitly trigger within the app
""")

                        LegalSection(title: "3. Third-Party Services", body: """
Firebase (Google) — provides authentication, real-time database, and cloud storage. Data is encrypted in transit and at rest.

RevenueCat — manages subscription state and purchase verification. RevenueCat receives your Apple ID purchase receipts.

Apple App Store — in-app purchases and subscriptions are processed by Apple.

Venmo / Zelle — when you tap a payment link, you leave Dutchi and those services' own privacy policies apply.
""")

                        LegalSection(title: "4. Data Storage and Retention", body: """
Most of your data is stored locally on your device. When you use Group Mode, group and activity data is synced to Firebase and retained as long as the group is active or until you delete it.

When you delete your account, we delete your phone number record and group memberships from Firebase. Locally stored data is cleared from your device.
""")

                        LegalSection(title: "5. Data Sharing", body: """
We do not sell, rent, or share your personal information with advertisers.

We share data only:
• With group members you explicitly invite, so they can see shared expense splits
• With third-party services listed above, as required to run the app
• When required by law
""")

                        LegalSection(title: "6. Your Rights", body: """
You can:
• Delete your account at any time from the Profile page
• Revoke contact or camera access at any time in iOS Settings
• Request a copy of your data by emailing us

California residents may have additional rights under the CCPA. Contact us to exercise those rights.
""")

                        LegalSection(title: "7. Children",
                            body: "Dutchi is not intended for users under 13 years of age. We do not knowingly collect personal information from children under 13.")

                        LegalSection(title: "8. Changes to This Policy",
                            body: "We may update this Privacy Policy from time to time. We will notify you of material changes through the app. Continued use of Dutchi after changes constitutes acceptance of the updated policy.")

                        LegalSection(title: "9. Contact Us",
                            body: "If you have questions about this Privacy Policy or how your data is handled, contact us at:\n\nsupport@dutchieapp.com")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 60)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(legalInk)
                    }
                }
            }
        }
    }
}

// MARK: - Shared sub-views

private struct LegalHeader: View {
    let title: String
    let updated: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DUTCHI")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(legalInk.opacity(0.35))
                .tracking(3)
                .padding(.top, 28)

            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(legalInk)

            Text(updated)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(legalInk.opacity(0.45))
        }
        .padding(.bottom, 20)
    }
}

private struct LegalDivider: View {
    var body: some View {
        Rectangle()
            .fill(legalInk.opacity(0.18))
            .frame(height: 1.5)
            .padding(.bottom, 24)
    }
}

private struct LegalSection: View {
    let title: String
    let text: String

    init(title: String, body: String) {
        self.title = title
        self.text = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(legalInk)
                .tracking(0.3)

            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(legalInk.opacity(0.75))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }
}
