import UIKit

struct ReceiptDetection {
    let corners: [CGPoint]
    let boundingBox: CGRect
    let imageSize: CGSize
    let confidence: CGFloat
    let perspectiveDistortion: CGFloat
    let hasQuadrilateral: Bool

    nonisolated init(
        corners: [CGPoint] = [],
        boundingBox: CGRect = .zero,
        imageSize: CGSize = .zero,
        confidence: CGFloat = 0,
        perspectiveDistortion: CGFloat = 0,
        hasQuadrilateral: Bool = false
    ) {
        self.corners = corners
        self.boundingBox = boundingBox
        self.imageSize = imageSize
        self.confidence = confidence
        self.perspectiveDistortion = perspectiveDistortion
        self.hasQuadrilateral = hasQuadrilateral
    }
}

struct ReceiptImageQualityReport {
    let blurVariance: CGFloat
    let brightness: CGFloat
    let contrast: CGFloat
    let estimatedTextHeight: CGFloat
    let perspectiveDistortion: CGFloat
    let score: CGFloat
    let shouldRetake: Bool
    let retakeReasons: [String]

    nonisolated init(
        blurVariance: CGFloat = 0,
        brightness: CGFloat = 0,
        contrast: CGFloat = 0,
        estimatedTextHeight: CGFloat = 0,
        perspectiveDistortion: CGFloat = 0,
        score: CGFloat = 0,
        shouldRetake: Bool = false,
        retakeReasons: [String] = []
    ) {
        self.blurVariance = blurVariance
        self.brightness = brightness
        self.contrast = contrast
        self.estimatedTextHeight = estimatedTextHeight
        self.perspectiveDistortion = perspectiveDistortion
        self.score = score
        self.shouldRetake = shouldRetake
        self.retakeReasons = retakeReasons
    }
}

struct ReceiptPreprocessingTiming {
    var detectMs: Double = 0
    var correctionMs: Double = 0
    var cropMs: Double = 0
    var enhanceMs: Double = 0
    var qualityMs: Double = 0
    var upscaleMs: Double = 0
    var totalPreprocessMs: Double = 0

    nonisolated init() {}

    nonisolated init(_ timings: [String: NSNumber]) {
        detectMs = timings["detect"]?.doubleValue ?? 0
        correctionMs = timings["correction"]?.doubleValue ?? 0
        cropMs = timings["crop"]?.doubleValue ?? 0
        enhanceMs = timings["enhance"]?.doubleValue ?? 0
        qualityMs = timings["quality"]?.doubleValue ?? 0
        upscaleMs = timings["upscale"]?.doubleValue ?? 0
        totalPreprocessMs = timings["totalPreprocess"]?.doubleValue ?? 0
    }
}

struct ReceiptPreprocessingResult {
    let image: UIImage
    let previewImage: UIImage
    let detection: ReceiptDetection
    let quality: ReceiptImageQualityReport
    let timing: ReceiptPreprocessingTiming
    let didApplyPerspective: Bool
    let didUpscale: Bool
    let scaleFactor: CGFloat

    nonisolated init(
        image: UIImage,
        previewImage: UIImage? = nil,
        detection: ReceiptDetection = ReceiptDetection(),
        quality: ReceiptImageQualityReport = ReceiptImageQualityReport(),
        timing: ReceiptPreprocessingTiming = ReceiptPreprocessingTiming(),
        didApplyPerspective: Bool = false,
        didUpscale: Bool = false,
        scaleFactor: CGFloat = 1
    ) {
        self.image = image
        self.previewImage = previewImage ?? image
        self.detection = detection
        self.quality = quality
        self.timing = timing
        self.didApplyPerspective = didApplyPerspective
        self.didUpscale = didUpscale
        self.scaleFactor = scaleFactor
    }
}
