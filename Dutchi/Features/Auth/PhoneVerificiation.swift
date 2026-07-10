import SwiftUI

struct PhoneVerificationPromptSheet: View {
    @ObservedObject var authManager: AuthManager
    let prefilledPhone: String
    @Binding var isPresented: Bool
    var allowsDismiss: Bool = true
    let onVerified: () -> Void

    @State private var showVerification = false
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 1.0, green: 0.992, blue: 0.969).ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 32) {
                            // Hero
                            VStack(spacing: 20) {
                                ZStack {
                                    Circle()
                                        .fill(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.08))
                                        .frame(width: 96, height: 96)
                                    VStack(spacing: 4) {
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

                                VStack(spacing: 8) {
                                    Text("Unlock Group Mode")
                                        .font(.system(size: 28, weight: .bold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                        .multilineTextAlignment(.center)

                                    Text("Verify your phone to split expenses with groups")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.6))
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 20)
                                }
                            }
                            .padding(.top, 20)

                            // Benefits
                            VStack(spacing: 10) {
                                benefitRow(
                                    icon: "person.3.fill",
                                    title: "Track Group Expenses",
                                    description: "See who owes what in real-time"
                                )
                                benefitRow(
                                    icon: "dollarsign.circle.fill",
                                    title: "Auto-Calculate Splits",
                                    description: "Everyone's balance updated automatically"
                                )
                                benefitRow(
                                    icon: "message.fill",
                                    title: "Quick Payment Requests",
                                    description: "Send payment links with one tap"
                                )
                                benefitRow(
                                    icon: "checkmark.shield.fill",
                                    title: "Secure & Private",
                                    description: "Your phone is only used for verification"
                                )
                            }
                            .padding(.horizontal, 20)

                            Spacer(minLength: 40)
                        }
                    }

                    // CTA
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 1)
                            .overlay(
                                GeometryReader { geometry in
                                    Path { path in
                                        let dashWidth: CGFloat = 5
                                        let dashGap: CGFloat = 5
                                        var x: CGFloat = 0
                                        while x < geometry.size.width {
                                            path.move(to: CGPoint(x: x, y: 0))
                                            path.addLine(to: CGPoint(x: min(x + dashWidth, geometry.size.width), y: 0))
                                            x += dashWidth + dashGap
                                        }
                                    }
                                    .stroke(Color(red: 0.15, green: 0.15, blue: 0.15), lineWidth: 1.5)
                                }
                            )
                            .padding(.horizontal, 20)

                        VStack(spacing: 10) {
                            Button(action: {
                                HapticManager.impact(style: .medium)
                                guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to verify your phone number.") else {
                                    return
                                }
                                showVerification = true
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "phone.fill")
                                        .font(.system(size: 14, weight: .bold))
                                    Text("VERIFY PHONE NUMBER")
                                        .font(.system(size: 13, weight: .bold))
                                        .tracking(1.2)
                                }
                                .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                                .cornerRadius(3)
                            }
                            .buttonStyle(ScaleButtonStyle())

                            if allowsDismiss {
                                Button(action: {
                                    HapticManager.impact(style: .light)
                                    isPresented = false
                                }) {
                                    Text("Maybe Later")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.5))
                                }
                            }
                        }
                        .padding(20)
                    }
                    .background(Color(red: 1.0, green: 0.992, blue: 0.969))
                }
            }
            .navigationTitle("Group Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if allowsDismiss {
                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showVerification) {
            PhoneVerificationSheet(
                authManager: authManager,
                prefilledPhone: prefilledPhone,
                isPresented: $showVerification,
                onVerified: {
                    isPresented = false
                    onVerified()
                }
            )
        }
    }

    private func benefitRow(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.08))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.12), lineWidth: 1)
                    )

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))

                Text(description)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.6))
            }

            Spacer()
        }
        .padding(14)
        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.15), lineWidth: 1)
        )
    }
}
