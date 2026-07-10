import UIKit

final class ReceiptPreprocessingPipeline {
    nonisolated static let shared = ReceiptPreprocessingPipeline()

    nonisolated let detector = ReceiptDetector()
    nonisolated let perspectiveCorrector = PerspectiveCorrector()
    nonisolated let enhancer = ReceiptEnhancer()
    nonisolated let qualityAnalyzer = ImageQualityAnalyzer()
    nonisolated let ocrService = VisionOCRService()

    nonisolated func preprocess(_ image: UIImage) -> ReceiptPreprocessingResult? {
        nil
    }

    nonisolated func recognizeReceiptText(from image: UIImage) -> (preprocessing: ReceiptPreprocessingResult, ocr: VisionOCRResult)? {
        guard let preprocessing = preprocess(image),
              let ocr = ocrService.recognizeWords(from: preprocessing.image) else {
            return nil
        }
        return (preprocessing, ocr)
    }
}
