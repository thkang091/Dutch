import UIKit

final class ImageQualityAnalyzer {
    nonisolated func analyze(_ image: UIImage, perspectiveDistortion: CGFloat = 0) -> ReceiptImageQualityReport {
        ReceiptImageQualityReport(perspectiveDistortion: perspectiveDistortion)
    }
}
