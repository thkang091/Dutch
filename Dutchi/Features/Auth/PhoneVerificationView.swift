import SwiftUI

struct PhoneVerificationSheet: View {
    @ObservedObject var authManager: AuthManager
    let prefilledPhone: String
    @Binding var isPresented: Bool
    var onVerified: (() -> Void)? = nil

    @State private var phoneNumber: String
    @State private var verificationCode = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared
    @FocusState private var isPhoneFocused: Bool
    @FocusState private var isCodeFocused: Bool

    init(authManager: AuthManager, prefilledPhone: String, isPresented: Binding<Bool>, onVerified: (() -> Void)? = nil) {
        self.authManager = authManager
        self.prefilledPhone = prefilledPhone
        self._isPresented = isPresented
        self.onVerified = onVerified
        self._phoneNumber = State(initialValue: prefilledPhone)
    }

    private var isAwaitingCode: Bool {
        if case .awaitingCode = authManager.authState { return true }
        return false
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 1.0, green: 0.992, blue: 0.969).ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 32) {
                        // Header
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.08))
                                    .frame(width: 80, height: 80)

                                Image(systemName: isAwaitingCode ? "envelope.badge.fill" : "phone.fill")
                                    .font(.system(size: 32, weight: .semibold))
                                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                            }

                            VStack(spacing: 8) {
                                Text(isAwaitingCode ? "Enter Verification Code" : "Verify Phone Number")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))

                                Text(isAwaitingCode
                                    ? "Enter the 6-digit code sent to \(phoneNumber)"
                                    : "We'll send you a verification code via SMS")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.6))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                            }
                        }
                        .padding(.top, 20)

                        // Input section
                        VStack(spacing: 16) {
                            if !isAwaitingCode {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("PHONE NUMBER")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.5))
                                        .tracking(1.2)

                                    TextField("(555) 123-4567", text: $phoneNumber)
                                        .font(.system(size: 18, weight: .medium))
                                        .keyboardType(.phonePad)
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                        .padding(16)
                                        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                                        .cornerRadius(2)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(
                                                    isPhoneFocused
                                                        ? Color(red: 0.15, green: 0.15, blue: 0.15)
                                                        : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.2),
                                                    lineWidth: 1.5
                                                )
                                        )
                                        .focused($isPhoneFocused)
                                }

                                // Security note
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.shield.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Security Check Required")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                        Text("Complete a quick verification to prove you're human")
                                            .font(.system(size: 11, weight: .medium))
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

                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("VERIFICATION CODE")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.5))
                                        .tracking(1.2)

                                    TextField("000000", text: $verificationCode)
                                        .font(.system(size: 28, weight: .bold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.center)
                                        .padding(20)
                                        .background(Color(red: 0.96, green: 0.96, blue: 0.94))
                                        .cornerRadius(2)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(
                                                    isCodeFocused
                                                        ? Color(red: 0.15, green: 0.15, blue: 0.15)
                                                        : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.2),
                                                    lineWidth: 1.5
                                                )
                                        )
                                        .focused($isCodeFocused)
                                        .onChange(of: verificationCode) { _, newValue in
                                            if newValue.count == 6 {
                                                Task { await verifyCode() }
                                            }
                                        }
                                }

                                Button(action: {
                                    authManager.resetVerificationState()
                                    verificationCode = ""
                                }) {
                                    Text("Change Phone Number")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.6))
                                        .underline()
                                }
                            }

                            // Error
                            if let error = authManager.errorMessage {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                    Text(translateError(error))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.06))
                                .cornerRadius(2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.2), lineWidth: 1)
                                )
                            }
                        }
                        .padding(.horizontal, 20)

                        Spacer(minLength: 40)
                    }
                }

                // Loading overlay
                if authManager.isBusy {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()

                    VStack(spacing: 20) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 1.0, green: 0.992, blue: 0.969)))
                            .scaleEffect(1.4)

                        VStack(spacing: 6) {
                            Text(isAwaitingCode ? "Verifying code..." : "Security check opening...")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969))

                            if !isAwaitingCode {
                                Text("Complete the reCAPTCHA to continue")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969).opacity(0.8))
                                    .multilineTextAlignment(.center)
                            }
                        }

                        if !isAwaitingCode {
                            VStack(spacing: 10) {
                                instructionRow("A popup will appear")
                                instructionRow("Check the box to verify you're human")
                                instructionRow("Then we'll send your SMS code")
                            }
                            .padding(14)
                            .background(Color(red: 1.0, green: 0.992, blue: 0.969).opacity(0.1))
                            .cornerRadius(2)
                        }
                    }
                    .padding(28)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                    )
                    .padding(.horizontal, 40)
                }
            }
            .navigationTitle("Verify Phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.6))
                }
            }
            .safeAreaInset(edge: .bottom) {
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

                    Button(action: {
                        HapticManager.impact(style: .medium)
                        if isAwaitingCode {
                            Task { await verifyCode() }
                        } else {
                            Task { await sendCode() }
                        }
                    }) {
                        HStack(spacing: 8) {
                            if !authManager.isBusy {
                                Image(systemName: isAwaitingCode ? "checkmark" : "arrow.right")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            Text(isAwaitingCode ? "VERIFY CODE" : "SEND CODE")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(1.2)
                        }
                        .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(canProceed ? Color(red: 0.15, green: 0.15, blue: 0.15) : Color(red: 0.15, green: 0.15, blue: 0.15).opacity(0.3))
                        .cornerRadius(3)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(!canProceed || authManager.isBusy)
                    .padding(20)
                }
                .background(Color(red: 1.0, green: 0.992, blue: 0.969))
            }
        }
        .onAppear {
            if !isAwaitingCode {
                isPhoneFocused = true
            } else {
                isCodeFocused = true
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            if isAuth {
                HapticManager.notification(type: .success)
                isPresented = false
                onVerified?()
            }
        }
        .keyboardDoneToolbar()
    }

    private func instructionRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color(red: 1.0, green: 0.992, blue: 0.969).opacity(0.4))
                .frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.992, blue: 0.969).opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canProceed: Bool {
        if isAwaitingCode {
            return verificationCode.count == 6
        } else {
            return !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func sendCode() async {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to verify your phone number.") else {
            return
        }
        await authManager.sendVerificationCode(to: phoneNumber)
    }

    private func verifyCode() async {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to verify your phone number.") else {
            return
        }
        await authManager.verifyCode(verificationCode)
    }

    private func translateError(_ error: String) -> String {
        if error.contains("cancelled by the user") {
            return "Security check was cancelled. Please try again and complete the verification."
        } else if error.contains("invalid verification code") {
            return "Invalid code. Please check and try again."
        } else if error.contains("expired") {
            return "Code expired. Please request a new one."
        }
        return error
    }
}
