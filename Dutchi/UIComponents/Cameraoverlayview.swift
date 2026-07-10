import SwiftUI

enum ScanTutorialMode {
    case receipt
    case transaction
}

struct ScanTutorialView: View {
    @Binding var isVisible: Bool
    @Environment(\.colorScheme) var colorScheme

    let mode: ScanTutorialMode
    let onNeverShowAgain: () -> Void
    let onContinue: () -> Void

    var body: some View {
        if mode == .transaction {
            TransactionTutorialView(isVisible: $isVisible, onNeverShowAgain: onNeverShowAgain, onContinue: onContinue)
        } else {
            ReceiptTutorialView(isVisible: $isVisible, onNeverShowAgain: onNeverShowAgain, onContinue: onContinue)
        }
    }
}

// MARK: - ReceiptTutorialView (2 pages)

struct ReceiptTutorialView: View {
    @Binding var isVisible: Bool
    @Environment(\.colorScheme) var colorScheme

    let onNeverShowAgain: () -> Void
    let onContinue: () -> Void

    /// 0 = tips page (original), 1 = good-vs-bad framing page (new)
    @State private var page: Int = 0

    var body: some View {
        ZStack {
            if page == 0 {
                ReceiptTipsPage(onNext: {
                    withAnimation(.easeInOut(duration: 0.3)) { page = 1 }
                }, onNeverShowAgain: dismissForever)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
            } else {
                ReceiptFramingPage(onDone: {
                    withAnimation(.easeOut(duration: 0.28)) { isVisible = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { onContinue() }
                }, onBack: {
                    withAnimation(.easeInOut(duration: 0.3)) { page = 0 }
                }, onNeverShowAgain: dismissForever)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: page)
    }

    private func dismissForever() {
        onNeverShowAgain()
        withAnimation(.easeOut(duration: 0.28)) { isVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { onContinue() }
    }
}

// MARK: - Page 1: Tips (original ReceiptTutorialView content, unchanged)

private struct ReceiptTipsPage: View {
    @Environment(\.colorScheme) var colorScheme
    let onNext: () -> Void
    let onNeverShowAgain: () -> Void

    @State private var opacity: Double = 0
    @State private var wrongCardOffset: CGFloat = 44
    @State private var rightCardOffset: CGFloat = 44
    @State private var wrongCardOpacity: Double = 0
    @State private var rightCardOpacity: Double = 0
    @State private var badgeScale: CGFloat = 0

    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.10)
    }
    private var textSecondary: Color { Color.white.opacity(0.58) }
    private var cardSurface: Color { Color.white.opacity(colorScheme == .dark ? 0.08 : 0.11) }

    private let tips: [(icon: String, text: String)] = [
        ("light.max",                       "Good light"),
        ("hand.raised.fill",                "Hold steady"),
        ("doc.text.viewfinder",             "Full receipt"),
        ("camera.metering.center.weighted", "Tap to focus"),
    ]

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Page indicator — dot 1 of 2
                pageIndicator(current: 0)
                    .padding(.top, 52)
                    .padding(.bottom, 8)

                VStack(spacing: 8) {
                    Text("Scan Your Receipt")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Position your receipt like the example on the right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding(.bottom, 28)

                HStack(alignment: .top, spacing: 14) {
                    receiptPhoneCard(isCorrect: false)
                        .offset(y: wrongCardOffset)
                        .opacity(wrongCardOpacity)
                    receiptPhoneCard(isCorrect: true)
                        .offset(y: rightCardOffset)
                        .opacity(rightCardOpacity)
                }
                .padding(.horizontal, 20)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(tips, id: \.icon) { tip in
                        VStack(spacing: 6) {
                            Image(systemName: tip.icon)
                                .font(.system(size: 17))
                                .foregroundColor(Color.white.opacity(0.70))
                            Text(tip.text)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                // "Next" replaces the original dismiss button
                Button(action: onNext) {
                    HStack(spacing: 10) {
                        Text("Next")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Capsule().fill(Color.white))
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 12)

                Button(action: onNeverShowAgain) {
                    Text("Don't show this again")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.white.opacity(0.48))
                }
                .padding(.bottom, 48)
            }
        }
        .opacity(opacity)
        .onAppear { animateIn() }
    }

    private func receiptPhoneCard(isCorrect: Bool) -> some View {
        let badgeColor: Color = isCorrect
            ? Color(red: 0.18, green: 0.75, blue: 0.35)
            : Color(red: 0.88, green: 0.22, blue: 0.18)

        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 22)
                .fill(cardSurface)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(badgeColor.opacity(0.60), lineWidth: 1.5))
                .frame(width: 152, height: 232)

            receiptIllustration(isCorrect: isCorrect)
                .rotationEffect(.degrees(isCorrect ? 0 : -16))
                .offset(x: isCorrect ? 0 : -10, y: isCorrect ? 8 : 32)
                .frame(width: 152, height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 22))

            Circle()
                .fill(Color.black.opacity(0.70))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "camera.fill").font(.system(size: 12)).foregroundColor(.white))
                .offset(y: 194)

            ZStack {
                Circle().fill(badgeColor).frame(width: 34, height: 34)
                    .shadow(color: badgeColor.opacity(0.45), radius: 6, x: 0, y: 3)
                Image(systemName: isCorrect ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            }
            .scaleEffect(badgeScale)
            .offset(x: 57, y: -14)
        }
        .frame(width: 152, height: 240)
        .overlay(
            VStack(spacing: 4) {
                Text(isCorrect ? "Do this" : "Don't do this")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(isCorrect
                        ? Color(red: 0.18, green: 0.75, blue: 0.35)
                        : Color(red: 0.88, green: 0.22, blue: 0.18))
                Text(isCorrect ? "Fill the frame,\nkeep all edges in" : "Tilted, cropped,\nor blurry")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSecondary)
                    .multilineTextAlignment(.center)
            }
            .offset(y: 152),
            alignment: .top
        )
    }

    private func receiptIllustration(isCorrect: Bool) -> some View {
        let lineOpacity: Double = isCorrect ? 0.38 : 0.18
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.88 : 0.93))
            .frame(width: isCorrect ? 118 : 106, height: isCorrect ? 202 : 154)
            .overlay(
                VStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(lineOpacity + 0.1)).frame(width: 56, height: 9)
                    Divider().opacity(0.25)
                    VStack(spacing: 5) {
                        ForEach(0..<5, id: \.self) { _ in
                            HStack {
                                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(lineOpacity)).frame(width: 44, height: 6)
                                Spacer()
                                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(lineOpacity)).frame(width: 20, height: 6)
                            }
                        }
                    }
                    HStack(spacing: 2) {
                        ForEach(0..<13, id: \.self) { _ in
                            Circle().fill(Color.gray.opacity(0.28)).frame(width: 3, height: 3)
                        }
                    }
                    Divider().opacity(0.25)
                    HStack {
                        Text("TOTAL").font(.system(size: 7, weight: .bold)).foregroundColor(.gray.opacity(0.5))
                        Spacer()
                        Text("$$$").font(.system(size: 12, weight: .bold)).foregroundColor(.gray.opacity(0.55))
                    }
                }
                .padding(10)
            )
    }

    private func animateIn() {
        withAnimation(.easeIn(duration: 0.3)) { opacity = 1 }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.12)) {
            wrongCardOffset = 0; wrongCardOpacity = 1
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.26)) {
            rightCardOffset = 0; rightCardOpacity = 1
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.5).delay(0.52)) {
            badgeScale = 1.0
        }
    }
}

// MARK: - Page 2: Good-vs-bad framing (new)

private struct ReceiptFramingPage: View {
    @Environment(\.colorScheme) var colorScheme
    let onDone: () -> Void
    let onBack: () -> Void
    let onNeverShowAgain: () -> Void

    @State private var opacity: Double = 0

    // Good card
    @State private var goodCardOffset: CGFloat = 44
    @State private var goodCardOpacity: Double = 0
    @State private var goodBadgeScale: CGFloat = 0
    @State private var goodFloatOffset: CGFloat = 0

    // Bad card
    @State private var badCardOffset: CGFloat = 44
    @State private var badCardOpacity: Double = 0
    @State private var badBadgeScale: CGFloat = 0
    @State private var badCropOverlayOpacity: Double = 0
    @State private var shakeOffset: CGFloat = 0

    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.10)
    }
    private var textSecondary: Color { Color.white.opacity(0.58) }
    private var cardSurface: Color { Color.white.opacity(colorScheme == .dark ? 0.08 : 0.11) }

    private let green = Color(red: 0.18, green: 0.75, blue: 0.35)
    private let red   = Color(red: 0.88, green: 0.22, blue: 0.18)

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Page indicator — dot 2 of 2
                pageIndicator(current: 1)
                    .padding(.top, 52)
                    .padding(.bottom, 8)

                VStack(spacing: 8) {
                    Text("One More Tip")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Zoom in as much as possible without cutting off any edge")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding(.bottom, 28)

                // Side-by-side cards
                HStack(alignment: .top, spacing: 14) {
                    // ── Good card ──
                    framingCard(
                        isCorrect: true,
                        label: "Do this",
                        sublabel: "Close, sharp,\nall edges inside"
                    ) {
                        goodReceiptIllustration
                    }
                    .offset(y: goodCardOffset)
                    .opacity(goodCardOpacity)

                    // ── Bad card ──
                    framingCard(
                        isCorrect: false,
                        label: "Don't do this",
                        sublabel: "Too far away,\ntext is tiny"
                    ) {
                        badReceiptIllustration
                    }
                    .offset(y: badCardOffset)
                    .opacity(badCardOpacity)
                }
                .padding(.horizontal, 20)

                Spacer()

                // Tips row
                HStack(spacing: 0) {
                    ForEach([
                        ("plus.magnifyingglass",               "Zoom close"),
                        ("crop",                               "Don't cut off"),
                        ("doc.viewfinder",                     "Fill square"),
                        ("viewfinder",                         "All edges in"),
                    ], id: \.0) { icon, text in
                        VStack(spacing: 6) {
                            Image(systemName: icon)
                                .font(.system(size: 17))
                                .foregroundColor(Color.white.opacity(0.70))
                            Text(text)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                // CTA
                Button(action: onDone) {
                    HStack(spacing: 10) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Got it — Start Scanning")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Capsule().fill(Color.white))
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 12)

                // Back link
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(Color.white.opacity(0.40))
                }
                .padding(.bottom, 12)

                Button(action: onNeverShowAgain) {
                    Text("Don't show this again")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.white.opacity(0.40))
                }
                .padding(.bottom, 48)
            }
        }
        .opacity(opacity)
        .onAppear { animateIn() }
    }

    // MARK: Card container

    private func framingCard<Content: View>(
        isCorrect: Bool,
        label: String,
        sublabel: String,
        @ViewBuilder illustration: () -> Content
    ) -> some View {
        let badgeColor: Color = isCorrect ? green : red
        return ZStack(alignment: .top) {
            // Card background
            RoundedRectangle(cornerRadius: 22)
                .fill(cardSurface)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(badgeColor.opacity(0.60), lineWidth: 1.5))
                .frame(width: 152, height: 232)

            // Receipt illustration inside card
            illustration()
                .offset(y: isCorrect ? 24 : 16)
                .frame(width: 152, height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 22))

            // Camera button at bottom
            Circle()
                .fill(Color.black.opacity(0.70))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "camera.fill").font(.system(size: 12)).foregroundColor(.white))
                .offset(y: 194)

            // Check / X badge
            ZStack {
                Circle().fill(badgeColor).frame(width: 34, height: 34)
                    .shadow(color: badgeColor.opacity(0.45), radius: 6, x: 0, y: 3)
                Image(systemName: isCorrect ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            }
            .scaleEffect(isCorrect ? goodBadgeScale : badBadgeScale)
            .offset(x: 57, y: -14)
        }
        .frame(width: 152, height: 240)
        .overlay(
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(isCorrect ? green : red)
                Text(sublabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSecondary)
                    .multilineTextAlignment(.center)
            }
            .offset(y: 152),
            alignment: .top
        )
    }

    // MARK: Good receipt — full receipt visible with background, gentle float

    private var goodReceiptIllustration: some View {
        ZStack {
            // Simulated table / background
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: colorScheme == .dark ? 0.22 : 0.55).opacity(0.6))
                .frame(width: 130, height: 190)

            fullReceiptPaper
                .rotationEffect(.degrees(-2))
                .offset(y: goodFloatOffset)
                .animation(
                    .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                    value: goodFloatOffset
                )
        }
    }

    private var fullReceiptPaper: some View {
            RoundedRectangle(cornerRadius: 5)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.90 : 0.96))
            .frame(width: 112, height: 190)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            .overlay(
                VStack(spacing: 0) {
                    // Logo circle
                    Circle()
                        .fill(Color.gray.opacity(0.30))
                        .frame(width: 16, height: 16)
                        .padding(.top, 8)
                    // Merchant name line
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.35))
                        .frame(width: 44, height: 5)
                        .padding(.top, 4)
                    // Subtitle lines
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.22))
                        .frame(width: 34, height: 4)
                        .padding(.top, 3)

                    Rectangle()
                        .fill(Color.gray.opacity(0.18))
                        .frame(height: 0.5)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)

                    // Line items
                    VStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { _ in
                            HStack {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.gray.opacity(0.32))
                                    .frame(width: CGFloat.random(in: 28...38), height: 4)
                                Spacer()
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.gray.opacity(0.28))
                                    .frame(width: 16, height: 4)
                            }
                        }
                    }
                    .padding(.horizontal, 8)

                    Rectangle()
                        .fill(Color.gray.opacity(0.18))
                        .frame(height: 0.5)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)

                    // Total row
                    HStack {
                        Text("TOTAL")
                            .font(.system(size: 5, weight: .bold))
                            .foregroundColor(.gray.opacity(0.55))
                        Spacer()
                        Text("$$$")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.gray.opacity(0.60))
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // Footer barcode dots
                    HStack(spacing: 2) {
                        ForEach(0..<10, id: \.self) { _ in
                            Circle().fill(Color.gray.opacity(0.22)).frame(width: 2.5, height: 2.5)
                        }
                    }
                    .padding(.bottom, 8)
                }
            )
    }

    // MARK: Bad receipt — full receipt visible but too far away to read

    private var badReceiptIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: colorScheme == .dark ? 0.22 : 0.55).opacity(0.6))
                .frame(width: 130, height: 190)

            fullReceiptPaper
                .scaleEffect(0.72)
                .rotationEffect(.degrees(-2))
                .offset(x: shakeOffset, y: 0)

            Text("Too far")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(red.opacity(0.90))
                .cornerRadius(5)
                .offset(y: -82)
                .opacity(badCropOverlayOpacity)
        }
        .animation(.spring(response: 0.08, dampingFraction: 0.3), value: shakeOffset)
    }

    private var zoomedReceiptContent: some View {
        // Shows only the lower portion of a receipt (items + total) — no header visible
        VStack(spacing: 0) {
            // Items — larger to sell the "zoomed in" feel
            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { i in
                    HStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.32))
                            .frame(width: CGFloat([52, 44, 60, 48, 38][i % 5]), height: 7)
                        Spacer()
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.28))
                            .frame(width: 28, height: 7)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            Rectangle()
                .fill(Color.gray.opacity(0.18))
                .frame(height: 0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)

            // Subtotal / Tax / Tip / Total — bigger to match zoom
            VStack(spacing: 7) {
                ForEach(["Subtotal", "Tax", "Tip", "Total"], id: \.self) { label in
                    HStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(label == "Total"
                                  ? Color.gray.opacity(0.55)
                                  : Color.gray.opacity(0.28))
                            .frame(width: label == "Total" ? 40 : 34, height: label == "Total" ? 7 : 6)
                        Spacer()
                        RoundedRectangle(cornerRadius: 2)
                            .fill(label == "Total"
                                  ? Color.gray.opacity(0.60)
                                  : Color.gray.opacity(0.30))
                            .frame(width: label == "Total" ? 36 : 26, height: label == "Total" ? 7 : 6)
                    }
                }
            }
            .padding(.horizontal, 14)

            Spacer()
        }
    }

    // MARK: Animation sequencing

    private func animateIn() {
        withAnimation(.easeIn(duration: 0.3)) { opacity = 1 }

        // Good card slides in first
        withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.12)) {
            goodCardOffset = 0; goodCardOpacity = 1
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.5).delay(0.52)) {
            goodBadgeScale = 1.0
        }
        // Start the gentle float
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            goodFloatOffset = -5
        }

        // Bad card slides in just after
        withAnimation(.spring(response: 0.55, dampingFraction: 0.7).delay(0.26)) {
            badCardOffset = 0; badCardOpacity = 1
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.5).delay(0.66)) {
            badBadgeScale = 1.0
        }
        // Red crop overlay fades in
        withAnimation(.easeIn(duration: 0.4).delay(0.85)) {
            badCropOverlayOpacity = 1
        }
        // Shake the bad receipt to emphasise
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            triggerShake()
        }
    }

    private func triggerShake() {
        let offsets: [CGFloat] = [7, -6, 5, -4, 2, 0]
        for (i, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) {
                shakeOffset = offset
            }
        }
    }
}

// MARK: - Shared page indicator

private func pageIndicator(current: Int) -> some View {
    HStack(spacing: 6) {
        ForEach(0..<2) { i in
            Capsule()
                .fill(current == i ? Color.white : Color.white.opacity(0.28))
                .frame(width: current == i ? 20 : 7, height: 7)
        }
    }
}

// MARK: - TransactionTutorialView

struct TransactionTutorialView: View {
    @Binding var isVisible: Bool
    @Environment(\.colorScheme) var colorScheme

    let onNeverShowAgain: () -> Void
    let onContinue: () -> Void

    @State private var opacity: Double = 0
    @State private var step: Int = 0
    @State private var phoneOpacity: Double = 0
    @State private var phoneOffset: CGFloat = 30
    @State private var pdfScale: CGFloat = 1.0
    @State private var thumbOpacity: Double = 0
    @State private var thumbOffset: CGFloat = 12
    @State private var uploadOpacity: Double = 0
    @State private var uploadOffset: CGFloat = 8
    @State private var highlightRow: Int = -1

    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.10)
    }
    private var textSecondary: Color { Color.white.opacity(0.58) }

    private let stepLabels = [
        "Choose your PDF statement",
        "Dutch reads the PDF pages",
        "Dutch finds the transactions, rows, and values",
    ]

    private let rows: [(icon: String, color: Color, name: String, amount: String)] = [
        ("fork.knife",      Color(red: 0.25, green: 0.55, blue: 0.95), "Restaurant",    "$42.50"),
        ("film",            Color(red: 0.90, green: 0.20, blue: 0.20), "Movie Theatre", "$34.14"),
        ("cart.fill",       Color(red: 0.95, green: 0.35, blue: 0.10), "Grocery Store", "$67.89"),
        ("tram.fill",       Color(red: 0.30, green: 0.70, blue: 0.45), "Gas Station",   "$58.00"),
        ("bag.fill",        Color(red: 0.65, green: 0.25, blue: 0.85), "Department Store","$21.68"),
    ]

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("Add Your Statement")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Upload a PDF bank or credit-card statement.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                }
                .padding(.top, 52)
                .padding(.bottom, 20)

                ZStack(alignment: .bottomTrailing) {
                    phoneCard
                    pdfThumbnail
                    uploadBadge
                }
                .frame(width: 260, height: 300)
                .padding(.bottom, 20)

                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { i in
                            Capsule()
                                .fill(step == i ? Color.white : Color.white.opacity(0.28))
                                .frame(width: step == i ? 20 : 7, height: 7)
                                .animation(.spring(response: 0.38), value: step)
                        }
                    }
                    Text(stepLabels[min(step, 2)])
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
                        .frame(height: 36)
                        .padding(.horizontal, 22)
                        .id(step)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.22), value: step)
                }
                .padding(.bottom, 24)

                Spacer()

                tipsRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)

                Button(action: dismissView) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Got it - Choose PDF")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Capsule().fill(Color.white))
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 12)

                Button(action: dismissForever) {
                    Text("Don't show this again")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.white.opacity(0.48))
                }
                .padding(.bottom, 48)
            }
        }
        .opacity(opacity)
        .onAppear { animateIn() }
    }

    private var phoneCard: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color(red: 0.96, green: 0.97, blue: 0.99))
            .frame(width: 210, height: 290)
            .overlay(
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.20, green: 0.40, blue: 0.80))
                        Spacer()
                        Text("Transactions")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                        Spacer()
                        Circle()
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(.gray)
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                        .frame(height: 28)
                        .overlay(
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(red: 0.85, green: 0.88, blue: 0.95))
                                    .frame(width: 32, height: 18)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(red: 0.20, green: 0.40, blue: 0.80).opacity(0.7))
                                    .frame(width: 70, height: 7)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(row.color.opacity(0.15))
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Image(systemName: row.icon)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(row.color)
                                    )
                                Text(row.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color(red: 0.10, green: 0.12, blue: 0.18))
                                    .lineLimit(1)
                                Spacer()
                                Text(row.amount)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color(red: 0.20, green: 0.40, blue: 0.80))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                highlightRow == index
                                    ? Color(red: 0.20, green: 0.40, blue: 0.80).opacity(0.08)
                                    : Color.clear
                            )
                            .animation(.easeInOut(duration: 0.25), value: highlightRow)

                            if index < rows.count - 1 {
                                Divider()
                                    .padding(.leading, 54)
                                    .opacity(0.5)
                            }
                        }
                    }

                    Spacer()
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
            .scaleEffect(pdfScale)
            .offset(y: phoneOffset)
            .opacity(phoneOpacity)
    }

    private var pdfThumbnail: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.white)
            .frame(width: 52, height: 66)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white, lineWidth: 2))
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(red: 0.20, green: 0.40, blue: 0.80))
                    Text("PDF")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundColor(Color(red: 0.20, green: 0.40, blue: 0.80))
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.gray.opacity(0.38))
                            .frame(width: CGFloat(24 + i * 4), height: 3)
                    }
                }
            )
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
            .offset(x: 14, y: 14)
            .offset(y: thumbOffset)
            .opacity(thumbOpacity)
    }

    private var uploadBadge: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.18, green: 0.75, blue: 0.35))
                .frame(width: 30, height: 30)
                .shadow(color: Color(red: 0.18, green: 0.75, blue: 0.35).opacity(0.4), radius: 6, x: 0, y: 3)
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
        .offset(x: 14, y: -14)
        .offset(y: uploadOffset)
        .opacity(uploadOpacity)
    }

    private var tipsRow: some View {
        let tips: [(icon: String, text: String)] = [
            ("doc.fill",               "PDF only"),
            ("lock.open",              "Unlocked"),
            ("building.columns",       "Bank statement"),
            ("list.bullet.rectangle",  "Rows + values"),
        ]
        return HStack(spacing: 0) {
            ForEach(tips, id: \.icon) { tip in
                VStack(spacing: 6) {
                    Image(systemName: tip.icon)
                        .font(.system(size: 17))
                        .foregroundColor(Color.white.opacity(0.70))
                    Text(tip.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func animateIn() {
        withAnimation(.easeIn(duration: 0.3)) { opacity = 1 }

        withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.15)) {
            phoneOpacity = 1
            phoneOffset = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            cycleRowHighlights(index: 0)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.15)) { step = 1 }
            withAnimation(.easeOut(duration: 0.10).delay(0.05)) { pdfScale = 0.94 }
            withAnimation(.spring(response: 0.25).delay(0.16)) { pdfScale = 1.0 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.75)) {
                thumbOpacity = 1
                thumbOffset = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            withAnimation(.easeIn(duration: 0.15)) { step = 2 }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72).delay(0.08)) {
                uploadOpacity = 1
                uploadOffset = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            withAnimation(.easeOut(duration: 0.3)) {
                thumbOpacity = 0
                uploadOpacity = 0
            }
            withAnimation(.easeOut(duration: 0.35).delay(0.25)) {
                phoneOpacity = 0
                phoneOffset = 30
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                step = 0
                highlightRow = -1
                thumbOffset = 12
                uploadOffset = 8
                animateIn()
            }
        }
    }

    private func cycleRowHighlights(index: Int) {
        guard index < rows.count else {
            highlightRow = -1
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { highlightRow = index }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeInOut(duration: 0.15)) { highlightRow = -1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                cycleRowHighlights(index: index + 1)
            }
        }
    }

    private func dismissView() {
        withAnimation(.easeOut(duration: 0.28)) { opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            isVisible = false
            onContinue()
        }
    }

    private func dismissForever() {
        onNeverShowAgain()
        dismissView()
    }
}

// MARK: - CameraOverlayView / CameraInstructionOverlay (unchanged)

struct CameraOverlayView: View {
    @Binding var isVisible: Bool
    let mode: ScanTutorialMode
    var onNeverShowAgain: () -> Void = {}
    let onDismiss: () -> Void

    var body: some View {
        ScanTutorialView(
            isVisible: $isVisible,
            mode: mode,
            onNeverShowAgain: onNeverShowAgain,
            onContinue: onDismiss
        )
    }
}

struct CameraInstructionOverlay: View {
    @State private var showOverlay = true
    let mode: ScanTutorialMode
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            if showOverlay {
                CameraOverlayView(isVisible: $showOverlay, mode: mode, onDismiss: onDismiss)
            }
        }
    }
}
