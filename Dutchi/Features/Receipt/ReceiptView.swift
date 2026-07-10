import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import FirebaseDatabase

// MARK: - Receipt View (Firebase-backed) - For Normal Mode Only

struct ReceiptView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    
    @StateObject private var receiptManager = ReceiptManager.shared
    
    let receiptId: UUID
    
    @State private var receiptData: ReceiptData?
    @State private var showShareSheet = false
    @State private var isLoading = true

    // MARK: - Print Animation State
    @State private var receiptOffset: CGFloat = 0
    @State private var animationProgress: CGFloat = 0
    @State private var isPrinting: Bool = false
    @State private var printComplete: Bool = false
    @State private var led1Active: Bool = false
    @State private var led2Active: Bool = false
    @State private var led3Active: Bool = false
    @State private var ledBlinking: Bool = false
    @State private var receiptHeight: CGFloat = 0

    // Vintage color palette
    private let paperColor = Color(red: 0.976, green: 0.965, blue: 0.941)
    private let accentColor = Color(red: 0.545, green: 0.490, blue: 0.420)
    private let darkTextColor = Color(red: 0.173, green: 0.157, blue: 0.125)
    private let mutedTextColor = Color(red: 0.353, green: 0.322, blue: 0.282)
    private let dividerColor = Color(red: 0.816, green: 0.784, blue: 0.722)
    private let bannerColor = Color(red: 0.910, green: 0.894, blue: 0.863)
    private let printerBodyColor = Color(red: 0.839, green: 0.827, blue: 0.808)
    private let printerSlotColor = Color(red: 0.102, green: 0.102, blue: 0.102)

    private let printDuration: Double = 3.5
    
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Loading receipt...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else if let data = receiptData {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        printerHardware
                            .padding(.top, 60)
                        
                        VStack(spacing: 0) {
                            receiptPaper(data: data)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .onAppear {
                                                receiptHeight = geo.size.height
                                            }
                                    }
                                )
                                .frame(maxWidth: 280)
                                .offset(y: receiptOffset)
                            
                            if printComplete {
                                tearEdge
                                    .frame(maxWidth: 280)
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: 280)
                        .clipped()
                        .offset(y: -8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 40)
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("Receipt Not Found")
                        .font(.title2.bold())
                    Text("We could not load this receipt from Firebase. Check your connection and try again.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }

            VStack {
                HStack {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        closeReceipt()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.primary.opacity(0.6))
                            .background(Circle().fill(Color(.systemBackground)).padding(-8))
                    }
                    .padding(.leading, 20)
                    .padding(.top, 20)
                    
                    Spacer()
                    
                    if receiptData != nil {
                        Button(action: {
                            HapticManager.impact(style: .medium)
                            shareReceipt()
                        }) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.accentColor)
                                .background(Circle().fill(Color(.systemBackground)).padding(-8))
                        }
                        .padding(.trailing, 20)
                        .padding(.top, 20)
                    }
                }
                Spacer()
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            loadReceipt()
        }
        .onReceive(receiptManager.$activeReceipt) { updatedReceipt in
            // ✅ FIX: Only update if the ID matches
            if let updated = updatedReceipt, updated.id == receiptId {
                print("📥 ReceiptView received update for receipt \(receiptId)")
                receiptData = updated
                if isLoading {
                    isLoading = false
                    startPrintAnimation()
                }
            }
        }
        .onDisappear {
            receiptManager.stopObservingReceipt(receiptID: receiptId)
        }
    }
    
    // MARK: - Load Receipt
    
    private func loadReceipt() {
        isLoading = true
        
        print("🔍 ReceiptView loading receipt: \(receiptId)")
        
        // Start observing
        receiptManager.observeGroupReceipt(receiptID: receiptId)

        receiptManager.fetchReceiptOnce(receiptID: receiptId) { fetchedReceipt in
            guard let fetchedReceipt else { return }
            DispatchQueue.main.async {
                print("✅ Receipt fetched directly: \(fetchedReceipt.id)")
                receiptData = fetchedReceipt
                if isLoading {
                    isLoading = false
                    startPrintAnimation()
                }
            }
        }
        
        var attempts = 0
        let maxAttempts = 16
        
        func checkReceipt() {
            attempts += 1
            print("🔍 Attempt \(attempts)/\(maxAttempts) - Checking for receipt \(receiptId)")
            
            // ✅ FIX: Check if activeReceipt.id matches our receiptId
            if let activeReceipt = receiptManager.activeReceipt,
               activeReceipt.id == receiptId {
                print("✅ Receipt found: \(activeReceipt.id)")
                receiptData = activeReceipt
                isLoading = false
                startPrintAnimation()
            } else if attempts < maxAttempts {
                print("⏳ Receipt not loaded yet, waiting...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    checkReceipt()
                }
            } else {
                print("❌ Receipt not found after \(maxAttempts) attempts")
                isLoading = false
            }
        }
        
        // Start checking
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            checkReceipt()
        }
    }
    
    // MARK: - Printer Hardware

    private var printerHardware: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ledView(active: led1Active, blinking: ledBlinking)
                ledView(active: led2Active, blinking: false)
                ledView(active: led3Active, blinking: false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(Color(red: 0.910, green: 0.902, blue: 0.878))
            .overlay(
                Rectangle()
                    .fill(Color(red: 0.690, green: 0.678, blue: 0.651))
                    .frame(height: 1),
                alignment: .bottom
            )

            Text("DUTCH")
                .font(.system(size: 10, weight: .medium))
                .tracking(2)
                .foregroundColor(Color(red: 0.533, green: 0.533, blue: 0.533))
                .padding(.top, 10)
                .padding(.bottom, 8)

            RoundedRectangle(cornerRadius: 3)
                .fill(printerSlotColor)
                .frame(height: 6)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: 280)
        .background(printerBodyColor)
        .cornerRadius(12, corners: [.topLeft, .topRight])
        .cornerRadius(6, corners: [.bottomLeft, .bottomRight])
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.690, green: 0.678, blue: 0.651), lineWidth: 1.5)
        )
        .shadow(color: Color(red: 0.690, green: 0.678, blue: 0.651).opacity(0.8), radius: 0, y: 2)
    }

    @ViewBuilder
    private func ledView(active: Bool, blinking: Bool) -> some View {
        Circle()
            .fill(active ? Color.green : Color(red: 0.420, green: 0.420, blue: 0.420))
            .frame(width: 7, height: 7)
            .opacity(blinking ? (active ? 1.0 : 0.3) : 1.0)
            .animation(blinking ? Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: active)
    }

    // MARK: - Receipt Paper

    private func receiptPaper(data: ReceiptData) -> some View {
        VStack(spacing: 0) {
            decorativeTearEdge(isTop: true)
            decorativeBanner()

            VStack(spacing: 0) {
                receiptHeader
                transactionsList(transactions: data.transactions)
                summarySection(totalAmount: data.totalAmount)
                dashedDivider()
                settlementsList(settlements: data.settlements)
                dividerLine(dotted: false)
                footerSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
        }
        .background(paperColor)
        .overlay(
            Rectangle()
                .fill(dividerColor.opacity(0.4))
                .frame(width: 1),
            alignment: .leading
        )
        .overlay(
            Rectangle()
                .fill(dividerColor.opacity(0.4))
                .frame(width: 1),
            alignment: .trailing
        )
    }

    private var tearEdge: some View {
        Canvas { context, size in
            var path = Path()
            let segW: CGFloat = 14
            let count = Int(size.width / segW) + 2
            path.move(to: CGPoint(x: 0, y: 0))
            for i in 0..<count {
                let x = CGFloat(i) * segW
                let peak = (i % 2 == 0) ? CGFloat(0) : CGFloat(12)
                path.addLine(to: CGPoint(x: x + segW / 2, y: peak))
                path.addLine(to: CGPoint(x: x + segW, y: 0))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(paperColor))
        }
        .frame(height: 14)
    }

    // MARK: - Print Animation

    private func startPrintAnimation() {
        receiptOffset = -receiptHeight - 100
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            HapticManager.impact(style: .light)
            ledBlinking = true
            led1Active = true
            isPrinting = true

            withAnimation(.linear(duration: printDuration)) {
                receiptOffset = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + printDuration * 0.4) {
                led2Active = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + printDuration) {
                ledBlinking = false
                led3Active = true
                isPrinting = false
                withAnimation(.easeIn(duration: 0.2)) {
                    printComplete = true
                }
                HapticManager.impact(style: .medium)
            }
        }
    }

    // MARK: - Decorative Elements
    
    private func decorativeTearEdge(isTop: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<50, id: \.self) { index in
                Rectangle()
                    .fill(bannerColor)
                    .frame(width: 8, height: 16)
                if index < 49 {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 8, height: 16)
                }
            }
        }
        .overlay(
            Rectangle()
                .fill(dividerColor)
                .frame(height: 1),
            alignment: isTop ? .bottom : .top
        )
    }
    
    private func decorativeBanner() -> some View {
        HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                Spacer()
                Circle()
                    .strokeBorder(accentColor, lineWidth: 2)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(bannerColor))
                    .overlay(
                        ZStack {
                            Path { path in
                                path.move(to: CGPoint(x: 10, y: 18))
                                path.addQuadCurve(
                                    to: CGPoint(x: 22, y: 18),
                                    control: CGPoint(x: 16, y: 23)
                                )
                            }
                            .stroke(accentColor, lineWidth: 1.5)
                            
                            HStack(spacing: 8) {
                                Circle().fill(accentColor).frame(width: 3, height: 3)
                                Circle().fill(accentColor).frame(width: 3, height: 3)
                            }
                            .offset(y: -4)
                        }
                    )
                Spacer()
            }
        }
        .padding(.vertical, 12)
        .background(bannerColor)
        .overlay(
            Rectangle()
                .fill(dividerColor)
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    // MARK: - Receipt Header
    
    private var receiptHeader: some View {
        VStack(spacing: 8) {
            Text("DUTCH")
                .font(.system(size: 28, weight: .bold, design: .serif))
                .foregroundColor(darkTextColor)
                .tracking(-0.5)
            
            Text("Fair Splits Since 1602")
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundColor(mutedTextColor)
                .tracking(0.5)
        }
        .padding(.bottom, 28)
    }
    
    // MARK: - Transactions List
    
    private func transactionsList(transactions: [TransactionSnapshot]) -> some View {
        VStack(spacing: 0) {
            ForEach(transactions) { transaction in
                HStack(alignment: .top) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(transaction.merchant.uppercased())
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(mutedTextColor)
                            .tracking(0.3)
                            .multilineTextAlignment(.leading)

                        if let label = transaction.assignmentLabel,
                           !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(label.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(darkTextColor)
                                .tracking(0.7)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(dividerColor.opacity(0.55), lineWidth: 1)
                                )
                        }
                    }
                    
                    Spacer()
                    
                    Text(String(format: "$%.2f", transaction.amount))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(darkTextColor)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 20)
    }
    
    // MARK: - Summary Section
    
    private func summarySection(totalAmount: Double) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("TOTAL")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(darkTextColor)
                    .tracking(0.5)
                
                Spacer()
                
                Text(String(format: "$%.2f", totalAmount))
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(darkTextColor)
            }
        }
        .padding(.bottom, 24)
    }
    
    // MARK: - Settlements List
    
    private func settlementsList(settlements: [SettlementSnapshot]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("PAYMENTS")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(darkTextColor)
                Spacer()
            }
            .padding(.vertical, 12)
            
            ForEach(settlements) { settlement in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(settlement.fromName.uppercased())
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(darkTextColor)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(mutedTextColor)
                            Text(settlement.toName.uppercased())
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(darkTextColor)
                        }
                    }
                    
                    Spacer()
                    
                    Text(settlement.formattedAmount)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(darkTextColor)
                }
                .padding(.vertical, 10)
                
                if settlement.id != settlements.last?.id {
                    dividerLine(dotted: true, light: true)
                }
            }
        }
        .padding(.bottom, 24)
    }
    
    // MARK: - Footer Section
    
    private var footerSection: some View {
        VStack(spacing: 16) {
            qrCodeView()
                .frame(width: 140, height: 140)
                .padding(.top, 20)
            
            Text("SCAN TO VIEW ONLINE")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(mutedTextColor)
                .tracking(1)
                .textCase(.uppercase)
        }
    }
    
    // MARK: - Helper Views
    
    @ViewBuilder
    private func dividerLine(dotted: Bool, light: Bool = false) -> some View {
        if dotted {
            HStack(spacing: 4) {
                ForEach(0..<60, id: \.self) { _ in
                    Rectangle()
                        .fill(dividerColor.opacity(light ? 0.4 : 0.6))
                        .frame(width: 3, height: 1)
                }
            }
            .frame(height: 1)
        } else {
            Rectangle()
                .fill(dividerColor.opacity(light ? 0.4 : 0.6))
                .frame(height: 1)
        }
    }
    
    private func dashedDivider() -> some View {
        HStack(spacing: 4) {
            ForEach(0..<60, id: \.self) { _ in
                Rectangle()
                    .fill(dividerColor.opacity(0.6))
                    .frame(width: 3, height: 1)
            }
        }
        .frame(height: 1)
    }
    
    private func qrCodeView() -> some View {
        let deepLink = "dutchie://receipt/\(receiptId.uuidString)"
        
        return ZStack {
            if let qrImage = generateQRCode(from: deepLink) {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            }
        }
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - Navigation
    
    private func closeReceipt() {
        receiptManager.stopObservingReceipt(receiptID: receiptId)
        dismiss()
    }
    
    // MARK: - Share Receipt
    
    private func shareReceipt() {
        guard let data = receiptData else { return }
        
        let deepLink = "dutchie://receipt/\(receiptId.uuidString)"
        
        var shareText = "Your Split Receipt from Dutch\n\n"
        shareText += "Total: \(String(format: "$%.2f", data.totalAmount))\n"
        shareText += "Split between \(data.participantCount) people\n\n"
        shareText += "View Full Receipt:\n"
        shareText += "\(deepLink)\n\n"
        shareText += "Don't have Dutch? Download it free:\n"
        shareText += "https://dutchieapp.com/download?receipt=\(receiptId.uuidString)"
        
        let activityVC = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )
        
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        top.present(activityVC, animated: true)
    }
}

// MARK: - Group Receipt View (For Group Mode Only)

struct GroupReceiptView: View {
    let groupID: UUID
    
    @State private var groupName: String = ""
    @State private var unsettledExpenses: [GroupExpense] = []
    @State private var totalAmount: Double = 0
    @State private var isLoading: Bool = true
    
    @Environment(\.dismiss) var dismiss
    
    private let ref = Database.database().reference()
    
    // Vintage colors (matching ReceiptView)
    private let paperColor = Color(red: 0.976, green: 0.965, blue: 0.941)
    private let ink = Color(red: 0.173, green: 0.157, blue: 0.125)
    private let mutedTextColor = Color(red: 0.353, green: 0.322, blue: 0.282)
    private let border = Color(red: 0.816, green: 0.784, blue: 0.722)
    private let accentColor = Color(red: 0.545, green: 0.490, blue: 0.420)
    private let bannerColor = Color(red: 0.910, green: 0.894, blue: 0.863)
    private let dividerColor = Color(red: 0.816, green: 0.784, blue: 0.722)
    
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Loading receipt...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Receipt header
                        VStack(spacing: 16) {
                            Text("DUTCH")
                                .font(.system(size: 28, weight: .bold, design: .serif))
                                .foregroundColor(ink)
                                .tracking(-0.5)
                            
                            Text(groupName.uppercased())
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(ink.opacity(0.6))
                                .tracking(2)
                            
                            Rectangle()
                                .fill(dividerColor)
                                .frame(height: 1)
                                .padding(.horizontal, 28)
                        }
                        .padding(.top, 32)
                        .padding(.bottom, 24)
                        
                        // Unsettled expenses
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("UNSETTLED ITEMS")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(ink)
                                    .tracking(2)
                                Spacer()
                            }
                            .padding(.horizontal, 28)
                            .padding(.bottom, 8)
                            
                            if unsettledExpenses.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 60))
                                        .foregroundColor(.green)
                                    
                                    Text("All Settled!")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(ink)
                                    
                                    Text("All expenses have been marked as settled")
                                        .font(.system(size: 14))
                                        .foregroundColor(mutedTextColor)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(unsettledExpenses) { expense in
                                        HStack(alignment: .top) {
                                            Text(expense.description.uppercased())
                                                .font(.system(size: 14, weight: .regular))
                                                .foregroundColor(mutedTextColor)
                                                .tracking(0.3)
                                                .multilineTextAlignment(.leading)
                                            
                                            Spacer()
                                            
                                            Text(expense.formattedAmount)
                                                .font(.system(size: 14, weight: .regular))
                                                .foregroundColor(ink)
                                        }
                                        .padding(.horizontal, 28)
                                        .padding(.vertical, 8)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 24)
                        
                        // Divider
                        Rectangle()
                            .fill(dividerColor)
                            .frame(height: 1)
                            .padding(.horizontal, 28)
                        
                        // Total
                        HStack {
                            Text("TOTAL")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(ink)
                                .tracking(0.5)
                            
                            Spacer()
                            
                            Text(String(format: "$%.2f", totalAmount))
                                .font(.system(size: 18, weight: .regular))
                                .foregroundColor(ink)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                    }
                    .background(paperColor)
                    .cornerRadius(12)
                    .padding()
                }
            }
            
            // Close button
            VStack {
                HStack {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.primary.opacity(0.6))
                            .background(Circle().fill(Color(.systemBackground)).padding(-8))
                    }
                    .padding(.leading, 20)
                    .padding(.top, 20)
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            loadGroupReceipt()
        }
    }
    
    private func loadGroupReceipt() {
        let groupRef = ref.child("groups").child(groupID.uuidString)
        
        // Load group name
        groupRef.child("name").observeSingleEvent(of: .value) { snapshot in
            if let name = snapshot.value as? String {
                groupName = name
            }
        }
        
        // Load expenses and filter unsettled
        groupRef.child("expenses").observe(.value) { snapshot in
            var expenses: [GroupExpense] = []
            
            for child in snapshot.children {
                guard let childSnapshot = child as? DataSnapshot,
                      let dict = childSnapshot.value as? [String: Any],
                      let idStr = dict["id"] as? String,
                      let expenseID = UUID(uuidString: idStr),
                      let groupIDStr = dict["groupID"] as? String,
                      let addedByIDStr = dict["addedByID"] as? String,
                      let addedByID = UUID(uuidString: addedByIDStr),
                      let addedByName = dict["addedByName"] as? String,
                      let description = dict["description"] as? String,
                      let amount = dict["amount"] as? Double,
                      let dateStr = dict["date"] as? String,
                      let date = ISO8601DateFormatter().date(from: dateStr),
                      let splitAmongIDsStrs = dict["splitAmongIDs"] as? [String] else {
                    continue
                }
                
                let splitAmongIDs = splitAmongIDsStrs.compactMap { UUID(uuidString: $0) }
                let isArchived = (dict["isArchived"] as? Bool) ?? false
                let settled = (dict["settled"] as? Bool) ?? false
                
                // ✅ ONLY include if NOT settled and NOT archived
                if !settled && !isArchived {
                    let expense = GroupExpense(
                        id: expenseID,
                        groupID: UUID(uuidString: groupIDStr) ?? groupID,
                        addedByID: addedByID,
                        addedByName: addedByName,
                        description: description,
                        amount: amount,
                        date: date,
                        splitAmongIDs: splitAmongIDs,
                        isArchived: isArchived,
                        settled: settled
                    )
                    
                    expenses.append(expense)
                }
            }
            
            unsettledExpenses = expenses.sorted { $0.date > $1.date }
            totalAmount = expenses.reduce(0.0) { $0 + $1.amount }
            isLoading = false
            
            print("✅ Loaded \(expenses.count) unsettled expenses, total: $\(totalAmount)")
        }
    }
}

// MARK: - Corner Radius Helper

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
