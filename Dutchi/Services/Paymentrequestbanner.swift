import SwiftUI

struct PaymentRequestBanner: View {
    let expense: GroupExpense
    let groupName: String
    let yourShare: Double
    @Binding var isVisible: Bool
    let onPayNow: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.orange)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Payment Request")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("\(expense.addedByName) paid for \(expense.description)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Text("Your share: \(String(format: "$%.2f", yourShare))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.orange)
                }
                
                Spacer()
                
                Button(action: onPayNow) {
                    Text("Pay")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.orange)
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        isVisible = false
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.orange.opacity(0.1))
            )
        }
        .shadow(color: Color.black.opacity(0.1), radius: 8, y: 4)
    }
}
