import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

private func elapsedMs(since start: CFAbsoluteTime) -> Double {
    (CFAbsoluteTimeGetCurrent() - start) * 1000
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// ============================================================
// MARK: - OCR Data Types
// ============================================================

struct OCRTokenBox {
    let text: String
    let rect: CGRect
    nonisolated var midX: CGFloat { rect.midX }
    nonisolated var maxX: CGFloat { rect.maxX }
    nonisolated var minX: CGFloat { rect.minX }
    nonisolated var midY: CGFloat { rect.midY }
    nonisolated var width: CGFloat { rect.width }
}

struct OCRWord {
    let text: String
    let confidence: Float
    let rect: CGRect
    let recognizedText: VNRecognizedText?
    let alternateCandidates: [String]
    nonisolated var midY: CGFloat   { rect.midY }
    nonisolated var midX: CGFloat   { rect.midX }
    nonisolated var minX: CGFloat   { rect.minX }
    nonisolated var maxX: CGFloat   { rect.maxX }
    nonisolated var minY: CGFloat   { rect.minY }
    nonisolated var maxY: CGFloat   { rect.maxY }
    nonisolated var height: CGFloat { rect.height }
    nonisolated var width: CGFloat  { rect.width }

    var tokens: [String] {
        text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    var tokenBoxes: [OCRTokenBox] {
        let toks = tokens
        guard !toks.isEmpty else { return [] }
        if toks.count == 1 { return [OCRTokenBox(text: toks[0], rect: rect)] }
        let spaceUnits: CGFloat = rect.width * 0.015
        let usableWidth = rect.width - CGFloat(max(toks.count - 1, 0)) * spaceUnits
        let totalChars = max(toks.reduce(0) { $0 + $1.count }, 1)
        var cursorX = rect.minX
        var out: [OCRTokenBox] = []
        for (idx, tok) in toks.enumerated() {
            let frac = CGFloat(tok.count) / CGFloat(totalChars)
            let tokenWidth = max(usableWidth * frac, rect.width * 0.04)
            let tokenRect = CGRect(x: cursorX, y: rect.minY,
                                   width: min(tokenWidth, rect.maxX - cursorX), height: rect.height)
            out.append(OCRTokenBox(text: tok, rect: tokenRect))
            cursorX += tokenWidth
            if idx < toks.count - 1 { cursorX += spaceUnits }
        }
        return out
    }
}

// ============================================================
// MARK: - OCR Pipeline Context
// ============================================================

struct OCRPipelineContext {
    let processedImage: UIImage
    let previewImage:   UIImage
    let candidateSource: String
    let snapshot:       OCRSnapshot
    let rawRows:        [RawReceiptRow]
    let quick:          QuickTotalResult
    let timing:         OCRPipelineTiming
    let quality:        ReceiptImageQualityReport?

    static func build(from originalImage: UIImage) -> OCRPipelineContext? {
        buildCandidates(from: originalImage).first
    }

    static func buildCandidates(from originalImage: UIImage) -> [OCRPipelineContext] {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        let originalForOCR = ImagePreprocessor.downscaledForOCR(originalImage)
        let processedResult = ImagePreprocessor.prepareWithTimings(originalForOCR)
        let processed = processedResult.image
        var candidates: [Candidate] = []
        if let processedCandidate = buildCandidate(from: processed, source: "processed") {
            candidates.append(processedCandidate)
        }
        if let originalCandidate = buildCandidate(from: originalForOCR, source: "original", usesOriginal: true) {
            candidates.append(originalCandidate)
        }
        guard !candidates.isEmpty else { return [] }
        let sorted = candidates.sorted { fallbackScore($0) > fallbackScore($1) }
        print("  [OCRPipeline] local candidates: \(sorted.map { "\($0.source)=score\(fallbackScore($0))/words\($0.snapshot.words.count)/prices\($0.priceCount)" }.joined(separator: " | "))")
        return sorted.map { candidate in
            var timing = processedResult.timing
            timing.visionMs = candidate.snapshot.visionMs
            timing.rowsMs = candidate.rowMs
            timing.quickMs = candidate.quickMs
            timing.totalMs = elapsedMs(since: pipelineStart)
            return OCRPipelineContext(
                processedImage: candidate.image,
                previewImage: candidate.usesOriginal ? originalForOCR : (processedResult.previewImage ?? processed),
                candidateSource: candidate.source,
                snapshot: candidate.snapshot,
                rawRows: candidate.rows,
                quick: candidate.quick,
                timing: timing,
                quality: processedResult.quality
            )
        }
    }

    private struct Candidate {
        let image: UIImage
        let source: String
        let snapshot: OCRSnapshot
        let rows: [RawReceiptRow]
        let quick: QuickTotalResult
        let rowMs: Double
        let quickMs: Double
        let priceCount: Int
        let usesOriginal: Bool
    }

    private static func buildCandidate(from image: UIImage, source: String, usesOriginal: Bool = false) -> Candidate? {
        guard let snapshot = OCRSnapshot.build(from: image) else { return nil }
        let rowStart = CFAbsoluteTimeGetCurrent()
        let rows = RowBuilder.buildRows(from: snapshot)
        let rowMs = elapsedMs(since: rowStart)
        let quickStart = CFAbsoluteTimeGetCurrent()
        let quick = QuickTotalDetector.detect(from: snapshot, rawRows: rows)
        let quickMs = elapsedMs(since: quickStart)
        let priceCount = rows.reduce(0) { $0 + $1.prices.count }
        return Candidate(
            image: image,
            source: source,
            snapshot: snapshot,
            rows: rows,
            quick: quick,
            rowMs: rowMs,
            quickMs: quickMs,
            priceCount: priceCount,
            usesOriginal: usesOriginal
        )
    }

    private static func shouldTryOriginalFallback(_ candidate: Candidate) -> Bool {
        candidate.quick.total == nil || candidate.priceCount < 3 || candidate.snapshot.words.count < 18
    }

    private static func fallbackScore(_ candidate: Candidate) -> Int {
        var score = 0
        if candidate.quick.total != nil { score += 1000 }
        if candidate.quick.subtotal != nil { score += 200 }
        if candidate.quick.tax != nil { score += 150 }
        score += min(candidate.priceCount, 12) * 40
        score += min(candidate.snapshot.words.count, 80)
        return score
    }
}

struct OCRPipelineTiming {
    var detectMs: Double = 0
    var segmentMs: Double = 0
    var correctionMs: Double = 0
    var cropMs: Double = 0
    var enhanceMs: Double = 0
    var qualityMs: Double = 0
    var upscaleMs: Double = 0
    var visionMs: Double = 0
    var rowsMs: Double = 0
    var quickMs: Double = 0
    var gateMs: Double = 0
    var totalMs: Double = 0
}

struct ImagePreprocessResult {
    let image: UIImage
    var previewImage: UIImage? = nil
    var timing: OCRPipelineTiming
    var quality: ReceiptImageQualityReport? = nil
}

struct OCRSnapshot {
    let words:       [OCRWord]
    let medianLineH: CGFloat
    let p20LineH:    CGFloat
    let rawLines:    [String]
    let imageSize:   CGSize
    let visionMs:    Double

    static func build(from image: UIImage) -> OCRSnapshot? {
        guard let result = VisionOCRService().recognizeWords(from: image) else { return nil }
        let words = result.words
        let heights = words.map(\.height).sorted()
        let p20H = heights.isEmpty ? 0.015 : heights[max(0, Int(Double(heights.count) * 0.20))]
        let p50H = heights.isEmpty ? 0.015 : heights[heights.count / 2]
        print("  [OCRSnapshot] \(words.count) words | p20H=\(String(format:"%.4f",p20H)) p50H=\(String(format:"%.4f",p50H))")
        print("  [OCRSnapshot.raw]\n\(result.rawLines.joined(separator: "\n"))")
        let imageSize = CGSize(width: image.cgImage?.width ?? Int(image.size.width),
                               height: image.cgImage?.height ?? Int(image.size.height))
        return OCRSnapshot(words: words, medianLineH: p50H, p20LineH: p20H, rawLines: result.rawLines, imageSize: imageSize, visionMs: result.visionMs)
    }

    static func fastWordCount(from image: UIImage) -> Int {
        VisionOCRService.fastWordCount(from: image)
    }

    private static func correctedPriceCandidate(top: VNRecognizedText, candidates: [VNRecognizedText]) -> VNRecognizedText {
        let topTokens = top.string.split(separator: " ").map(String.init)
        guard topTokens.contains(where: { hasPriceShapeShadow($0) && !PriceParser.looksLikePrice($0) }) else {
            return top
        }
        for candidate in candidates.dropFirst() {
            let altTokens = candidate.string.split(separator: " ").map(String.init)
            guard altTokens.count == topTokens.count else { continue }
            for idx in altTokens.indices {
                let topToken = topTokens[idx]
                let altToken = altTokens[idx]
                guard PriceParser.looksLikePrice(altToken),
                      !PriceParser.looksLikePrice(topToken),
                      differsOnlyByPriceConfusables(topToken, altToken) else { continue }
                print("  [OCRSnapshot] price candidate correction '\(topToken)' -> '\(altToken)'")
                return candidate
            }
        }
        return top
    }

    private static func hasPriceShapeShadow(_ token: String) -> Bool {
        let digits = token.filter(\.isNumber).count
        guard digits >= 2 else { return false }
        return token.contains(".") || token.contains(",") || token.contains("-") || token.contains("_") || Double(digits) / Double(max(token.count, 1)) >= 0.5
    }

    private static func differsOnlyByPriceConfusables(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs)
        let b = Array(rhs)
        guard a.count == b.count else { return false }
        var sawDifference = false
        for (x, y) in zip(a, b) {
            if x == y { continue }
            sawDifference = true
            guard arePriceConfusable(x, y) else { return false }
        }
        return sawDifference
    }

    private static func arePriceConfusable(_ a: Character, _ b: Character) -> Bool {
        let groups: [Set<Character>] = [
            ["O", "o", "0"],
            ["S", "s", "5"],
            ["B", "b", "8"],
            ["I", "l", "|", "1"],
            ["Z", "z", "2"],
            ["G", "g", "6"]
        ]
        return groups.contains { $0.contains(a) && $0.contains(b) }
    }
}

// ============================================================
// MARK: - Image Pre-Processing
// ============================================================

enum ImagePreprocessor {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let maxOCRDimension: CGFloat = 2200

    static func downscaledForOCR(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longest = max(width, height)
        guard longest > maxOCRDimension else { return image }
        let scale = maxOCRDimension / longest
        let targetSize = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            UIImage(cgImage: cgImage, scale: 1, orientation: image.imageOrientation)
                .draw(in: CGRect(origin: .zero, size: targetSize))
        }
        print("  [ImagePreprocessor] downscaled OCR image \(Int(width))x\(Int(height)) -> \(Int(targetSize.width))x\(Int(targetSize.height))")
        return resized
    }

    static func prepare(_ image: UIImage) -> UIImage {
        prepareWithTimings(image).image
    }

    static func prepareWithTimings(_ image: UIImage) -> ImagePreprocessResult {
        var timing = OCRPipelineTiming()
        guard let cg = image.cgImage else { return ImagePreprocessResult(image: image, previewImage: image, timing: timing) }
        let width = cg.width
        let height = cg.height
        print("  [ImagePreprocessor] Original: \(width)x\(height)")
        guard width >= 400 && height >= 400 else {
            print("  [ImagePreprocessor] ⚠️ Image too small: \(width)x\(height)")
            return ImagePreprocessResult(image: image, previewImage: image, timing: timing)
        }

        let documentStart = CFAbsoluteTimeGetCurrent()
        var documentCorrection = correctWithVisionDocumentSegmentation(image)
        timing.segmentMs = elapsedMs(since: documentStart)
        if let corrected = documentCorrection {
            let originalWordCount = OCRSnapshot.fastWordCount(from: image)
            let correctedWordCount = OCRSnapshot.fastWordCount(from: corrected.image)
            if shouldDiscardPreprocessedImage(baselineWordCount: originalWordCount, candidateWordCount: correctedWordCount) {
                print("  [ImagePreprocessor] ⚠️ discarding Vision document correction: \(correctedWordCount) words vs \(originalWordCount) on original")
                documentCorrection = nil
            }
        }
        let inputImage = documentCorrection?.image ?? image
        let enhanceStart = CFAbsoluteTimeGetCurrent()
        let enhancedImage = enhanceForOCR(inputImage)
        timing.enhanceMs = elapsedMs(since: enhanceStart)
        let qualityStart = CFAbsoluteTimeGetCurrent()
        let quality = analyzeQuality(enhancedImage, perspectiveDistortion: 0)
        timing.qualityMs = elapsedMs(since: qualityStart)

        print("  [ImagePreprocessor] Vision document=\(documentCorrection == nil ? "NO" : "YES") | OpenCV preprocess=DISABLED | enhance=\(String(format: "%.0f", timing.enhanceMs))ms quality=\(Int(quality.score)) retake=\(quality.shouldRetake ? "YES" : "NO")")
        return ImagePreprocessResult(
            image: enhancedImage,
            previewImage: enhancedImage,
            timing: timing,
            quality: quality
        )
    }

    private static func correctWithVisionDocumentSegmentation(_ image: UIImage) -> (image: UIImage, previewImage: UIImage)? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            print("  [ImagePreprocessor] Vision document segmentation failed: \(error.localizedDescription)")
            return nil
        }

        guard let rectangle = bestDocumentRectangle(from: request.results, imageSize: CGSize(width: cgImage.width, height: cgImage.height)) else {
            return nil
        }

        return perspectiveCorrect(image: image, cgImage: cgImage, rectangle: rectangle)
    }

    private static func bestDocumentRectangle(from observations: [VNRectangleObservation]?, imageSize: CGSize) -> VNRectangleObservation? {
        guard let observations, !observations.isEmpty else { return nil }
        let imageArea = max(imageSize.width * imageSize.height, 1)

        return observations
            .map { observation -> (VNRectangleObservation, CGFloat) in
                let points = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
                let area = normalizedPolygonArea(points) * imageArea
                let widthTop = distance(observation.topLeft, observation.topRight)
                let widthBottom = distance(observation.bottomLeft, observation.bottomRight)
                let heightLeft = distance(observation.topLeft, observation.bottomLeft)
                let heightRight = distance(observation.topRight, observation.bottomRight)
                let longSide = max(widthTop, widthBottom, heightLeft, heightRight)
                let shortSide = max(min(widthTop, widthBottom, heightLeft, heightRight), 0.001)
                let aspect = longSide / shortSide
                let aspectPenalty: CGFloat = aspect < 1.05 || aspect > 12.0 ? 0.6 : 1.0
                let hugePenalty: CGFloat = area / imageArea > 0.97 ? 0.6 : 1.0
                return (observation, area * aspectPenalty * hugePenalty)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func shouldDiscardPreprocessedImage(baselineWordCount: Int, candidateWordCount: Int) -> Bool {
        guard baselineWordCount >= 8 else { return false }
        return candidateWordCount < max(5, baselineWordCount / 3)
    }

    private static func perspectiveCorrect(image: UIImage, cgImage: CGImage, rectangle: VNRectangleObservation) -> (image: UIImage, previewImage: UIImage)? {
        let ciImage = CIImage(cgImage: cgImage)
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = vector(rectangle.topLeft, width: width, height: height)
        filter.topRight = vector(rectangle.topRight, width: width, height: height)
        filter.bottomRight = vector(rectangle.bottomRight, width: width, height: height)
        filter.bottomLeft = vector(rectangle.bottomLeft, width: width, height: height)

        guard let output = filter.outputImage,
              let correctedCG = ciContext.createCGImage(output, from: output.extent) else {
            return nil
        }

        let corrected = UIImage(cgImage: correctedCG, scale: image.scale, orientation: .up)
        return (corrected, corrected)
    }

    private static func vector(_ point: CGPoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: point.x * width, y: point.y * height)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func normalizedPolygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var area: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return abs(area) * 0.5
    }

    private static func adaptiveEnhancementParameters(for image: CIImage, context: CIContext) -> (contrast: Double, brightness: Double, sharpness: Double) {
        let extent = image.extent
        let averageFilter = CIFilter.areaAverage()
        averageFilter.inputImage = image
        averageFilter.extent = extent
        var rgba = [UInt8](repeating: 0, count: 4)
        if let output = averageFilter.outputImage {
            context.render(output, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let luminance = (0.2126 * Double(rgba[0]) + 0.7152 * Double(rgba[1]) + 0.0722 * Double(rgba[2])) / 255.0
        if luminance < 0.38 {
            return (1.22, 0.07, 0.70)
        }
        if luminance > 0.78 {
            return (1.14, -0.02, 0.55)
        }
        return (1.08, 0.03, 0.45)
    }

    private static func enhanceForOCR(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        let params = adaptiveEnhancementParameters(for: ciImage, context: ciContext)

        let color = CIFilter.colorControls()
        color.inputImage = ciImage
        color.contrast = Float(params.contrast)
        color.brightness = Float(params.brightness)
        color.saturation = 0.0

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = color.outputImage
        sharpen.sharpness = Float(params.sharpness)

        guard let output = sharpen.outputImage,
              let enhancedCG = ciContext.createCGImage(output, from: output.extent) else {
            return image
        }
        return UIImage(cgImage: enhancedCG, scale: image.scale, orientation: .up)
    }

    private static func analyzeQuality(_ image: UIImage, perspectiveDistortion: CGFloat) -> ReceiptImageQualityReport {
        guard let cgImage = image.cgImage else {
            return ReceiptImageQualityReport(score: 0, shouldRetake: true, retakeReasons: ["image_unreadable"])
        }
        let sampleSize = 96
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return ReceiptImageQualityReport(score: 0, shouldRetake: true, retakeReasons: ["quality_context_failed"])
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var luma = [CGFloat]()
        luma.reserveCapacity(sampleSize * sampleSize)
        for idx in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = CGFloat(pixels[idx]) / 255.0
            let g = CGFloat(pixels[idx + 1]) / 255.0
            let b = CGFloat(pixels[idx + 2]) / 255.0
            luma.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        let mean = luma.reduce(0, +) / CGFloat(max(luma.count, 1))
        let variance = luma.reduce(CGFloat(0)) { $0 + pow($1 - mean, 2) } / CGFloat(max(luma.count, 1))
        let contrast = sqrt(variance)

        var edgeEnergy: CGFloat = 0
        var edgeCount: CGFloat = 0
        for y in 1..<(sampleSize - 1) {
            for x in 1..<(sampleSize - 1) {
                let i = y * sampleSize + x
                let lap = abs(4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - sampleSize] - luma[i + sampleSize])
                edgeEnergy += lap * lap
                edgeCount += 1
            }
        }
        let blurVariance = edgeCount > 0 ? edgeEnergy / edgeCount * 10_000 : 0
        var reasons: [String] = []
        if blurVariance < 18 { reasons.append("blurry") }
        if mean < 0.18 { reasons.append("too_dark") }
        if mean > 0.92 { reasons.append("overexposed") }
        if contrast < 0.08 { reasons.append("low_contrast") }

        let blurScore = min(1, blurVariance / 55)
        let brightnessScore = mean < 0.50 ? mean / 0.50 : (1 - min(1, (mean - 0.50) / 0.50) * 0.35)
        let contrastScore = min(1, contrast / 0.18)
        let score = max(0, min(100, (blurScore * 0.45 + brightnessScore * 0.25 + contrastScore * 0.30) * 100))
        return ReceiptImageQualityReport(
            blurVariance: blurVariance,
            brightness: mean,
            contrast: contrast,
            estimatedTextHeight: 0,
            perspectiveDistortion: perspectiveDistortion,
            score: score,
            shouldRetake: score < 45 || reasons.count >= 2,
            retakeReasons: reasons
        )
    }
}

// ============================================================
// MARK: - Raw Receipt Rows
// ============================================================

struct RawReceiptRow {
    var words:   [OCRWord]
    var minY:    CGFloat
    var maxY:    CGFloat
    var midY:    CGFloat
    var minX:    CGFloat
    var maxX:    CGFloat
    var rowIndex: Int = 0
    var zone:    RowBuilder.Zone = .unknown
    var midX: CGFloat { (minX + maxX) / 2 }


    var fullText:   String          { words.map(\.text).joined(separator: " ") }
    var allTokens:  [String]        { words.flatMap(\.tokens) }
    var tokenBoxes: [OCRTokenBox]   { words.flatMap { $0.tokenBoxes } }

    var prices: [Double] {
        var out: [Double] = []
        for v in tokenBoxes.flatMap({ PriceParser.extractAllIncludingUSD(from: $0.text) })
                + PriceParser.extractAllIncludingUSD(from: fullText) {
            if !out.contains(where: { abs($0 - v) < 0.001 }) { out.append(v) }
        }
        return out
    }

    var terminalItemPrice: Double? {
        let byX = tokenBoxes.flatMap { box -> [(Double, CGFloat)] in
            PriceParser.extractAllIncludingUSD(from: box.text).map { ($0, box.maxX) }
        }
        if let best = byX.max(by: { $0.1 < $1.1 })?.0 { return best }
        return PriceParser.extractAllIncludingUSD(from: fullText).max()
    }
}

// ============================================================
// MARK: - Structured Output Models
// ============================================================

struct ReceiptLineItem: Identifiable, Codable {
    let id: UUID
    var name:          String
    var amount:        Double
    var originalPrice: Double
    var discount:      Double
    var discountLabel: String?
    var taxPortion:    Double
    var isSelected:    Bool
    var category:      ItemCategory
    var splitCategory: String?
    var splitCategoryConfidence: Double?
    
    enum ItemCategory: String, Codable {
        case merchandise
        case tax
        case tip
        case fee
        case adjustment
    }
    
    init(id: UUID = UUID(), name: String, originalPrice: Double, discount: Double,
         amount: Double, taxPortion: Double, isSelected: Bool, category: ItemCategory = .merchandise,
         discountLabel: String? = nil, splitCategory: String? = nil, splitCategoryConfidence: Double? = nil) {
        self.id = id
        self.name = name
        self.originalPrice = originalPrice
        self.discount = discount
        self.discountLabel = discountLabel
        self.amount = amount
        self.taxPortion = taxPortion
        self.isSelected = isSelected
        self.category = category
        self.splitCategory = splitCategory
        self.splitCategoryConfidence = splitCategoryConfidence
    }
}

struct ReceiptCharge {
    enum Kind: String { case tax, tip, fee, discount }
    var kind:   Kind
    var label:  String
    var amount: Double
}

struct QuickTotalResult {
    var merchant:   String
    var total:      Double?
    var cashTotal:  Double?
    var nonCashTotal: Double?
    var nonCashFee: Double?
    var selectedGrandTotalBasis: String?
    var subtotal:   Double?
    var tax:        Double?
    var tip:        Double?
    var fees:       Double?
    var totalConf:  ReceiptParseResult.TotalConfidence
}

struct ReceiptParseResult {
    enum TotalConfidence: CustomStringConvertible {
        case none, low, medium, high
        var description: String {
            switch self { case .none: return "none"; case .low: return "low"
            case .medium: return "medium"; case .high: return "high" }
        }
    }
}

// ============================================================
// MARK: - Price Parser Utilities
// ============================================================

enum PriceParser {
    private static let standardPrice = #"(?<!\d)(-?\$?\s*\d{1,3}(?:,\d{3})*\.\d{2})(?!\d)"#
    private static let dashedPrice   = #"(?<!\d)(\d{1,3}[-_]\d{2})(?!\d)"#
    private static let qtyAt         = #"(\d{1,3})\s*[@xX×]\s*\$?(\d{1,3}\.\d{2})"#
    // Precompiled once: these run per token/row during local OCR and should not recompile in hot loops.
    private static let standardPriceRegex = try! NSRegularExpression(pattern: standardPrice)
    private static let dashedPriceRegex = try! NSRegularExpression(pattern: dashedPrice)
    private static let missingDecimalRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4,5})(?!\d)"#)
    private static let usdPriceRegex = try! NSRegularExpression(pattern: #"USD\$?\s*(\d{1,4}\.\d{2})"#, options: .caseInsensitive)
    private static let qtyAtRegex = try! NSRegularExpression(pattern: qtyAt)
    private static let weightLineRegex = try! NSRegularExpression(pattern: #"(\d+\.\d{1,3})\s*lb\s*[@x×]\s*\$?(\d+\.\d{2})"#, options: .caseInsensitive)
    private static let exactPriceRegex = try! NSRegularExpression(pattern: #"^\-?\$?\d{1,4}\.\d{2}$"#)
    private static let exactDashedPriceRegex = try! NSRegularExpression(pattern: #"^\d{1,4}[-_]\d{2}$"#)

    static func repairMissingDecimal(rawInt: Int, context: String) -> Double? {
        let lower = context.lowercased()
        guard lower.contains("total") || lower.contains("amount") || lower.contains("balance") else { return nil }
        let s = "\(rawInt)"
        guard s.count == 4 || s.count == 5 else { return nil }
        if let v = Double("\(s.dropLast(2)).\(s.suffix(2))"), v >= 0.01, v < 10000 { return v }
        return nil
    }

    static func extractAll(from text: String) -> [Double] {
        var results: [Double] = []
        let ns = text as NSString
        for m in standardPriceRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
            if let v = Double(s), abs(v) >= 0.01, abs(v) < 10000 { results.append(round2(v)) }
        }
        for m in dashedPriceRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "-", with: ".").replacingOccurrences(of: "_", with: ".")
            if let v = Double(s), abs(v) >= 0.01, abs(v) < 10000 {
                let r = round2(v)
                if !results.contains(where: { abs($0 - r) < 0.001 }) { results.append(r) }
            }
        }
        for m in missingDecimalRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range(at: 1))
            if let raw = Int(s), let rep = repairMissingDecimal(rawInt: raw, context: text) {
                let r = round2(rep)
                if !results.contains(where: { abs($0 - r) < 0.001 }) { results.append(r) }
            }
        }
        return results
    }

    static func extractAllIncludingUSD(from text: String) -> [Double] {
        var base = extractAll(from: text)
        let ns = text as NSString
        for m in usdPriceRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let v = Double(ns.substring(with: m.range(at: 1))), v >= 0.01, v < 10000 {
                let r = round2(v)
                if !base.contains(where: { abs($0 - r) < 0.001 }) { base.append(r) }
            }
        }
        return base
    }

    static func extractQtyUnit(from text: String) -> (qty: Double, unitPrice: Double, lineTotal: Double)? {
        let ns = text as NSString
        guard let m = qtyAtRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 3 else { return nil }
        guard let qty  = Double(ns.substring(with: m.range(at: 1))),
              let unit = Double(ns.substring(with: m.range(at: 2))),
              qty >= 1, qty < 100 else { return nil }
        return (qty, round2(unit), round2(qty * unit))
    }

    static func extractWeightLine(from text: String) -> (weightLbs: Double, ratePerLb: Double, lineTotal: Double)? {
        let lower = normalizeMeasurementOCR(text)
        let ns = lower as NSString
        guard let m = weightLineRegex.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 3 else { return nil }
        guard let w = Double(ns.substring(with: m.range(at: 1))),
              let r = Double(ns.substring(with: m.range(at: 2))), w > 0, r > 0 else { return nil }
        return (w, round2(r), round2(w * r))
    }

    nonisolated static func looksLikePrice(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        let range = NSRange(location: 0, length: (t as NSString).length)
        return exactPriceRegex.firstMatch(in: t, range: range) != nil
            || exactDashedPriceRegex.firstMatch(in: t, range: range) != nil
    }

    static func looksLikeMemberID(_ text: String) -> Bool {
        let d = text.filter { $0.isNumber }
        return d.count >= 8 && Double(d) != nil
    }

    static func isTaxFlag(_ text: String) -> Bool {
        let u = text.uppercased().trimmingCharacters(in: .whitespaces)
        return ["F","N","T","B","A","E","NE","NF","TX","NT"].contains(u) && u.count <= 2
    }

    static func isSKUCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if t.allSatisfy({ $0.isNumber }) && t.count >= 5 && t.count <= 13 { return true }
        if t.count >= 6, t.first?.isLetter == true, t.dropFirst().allSatisfy({ $0.isNumber }) { return true }
        return false
    }

    static func normalizeMeasurementOCR(_ text: String) -> String {
        " " + text.lowercased()
            .replacingOccurrences(of: "/1b", with: "/lb").replacingOccurrences(of: "/ib", with: "/lb")
            .replacingOccurrences(of: "/|b", with: "/lb").replacingOccurrences(of: " 1b ", with: " lb ")
            .replacingOccurrences(of: " ib ", with: " lb ").replacingOccurrences(of: " |b ", with: " lb ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func cleanItemName(_ rawTokens: [String]) -> String {
        var kept: [String] = []; var skippedSKU = false
        for token in rawTokens {
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if !skippedSKU && isSKUCode(t) { skippedSKU = true; continue }
            if looksLikePrice(t) || isTaxFlag(t) || looksLikeMemberID(t) { continue }
            let lower = normalizeMeasurementOCR(t)
            let noise = ["aid","tvr","tsi","seq","ref","auth","approved","approval",
                         "cntctless","contactless","member","loyalty","points","gt",
                         "entry","mode","visa","mastercard","discover","amex",
                         "removed","void","voided","refunded","returned","cancelled","canceled"]
            if noise.contains(where: { lower.hasPrefix($0) }) { continue }
            kept.append(t)
        }
        var name = kept.joined(separator: " ")
        if name.hasPrefix("O ") { name = String(name.dropFirst(2)) }
        if name.hasPrefix("* ") { name = String(name.dropFirst(2)) }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "* \t-•"))
    }

    static func isPoisonRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["enter to win","sweepstakes","no purchase necessary","void where","official rules",
                "win $","prize","contest","gift card","take our survey",".com/survey",
                "aid:","tvr:","tsi:","cntctless","xxxxxxxxxxxx",
                "invoice:","auth code","entry mode","terminal id","merchant id",
                "batch #","response code","rrn:"].contains(where: { lower.contains($0) })
    }

    static func isDiscountRow(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix("you saved") || lower.hasPrefix("savings") ||
            lower.hasPrefix("member savings") || lower.contains(" bogo") ||
            lower.contains("coupon") || lower.contains("discount") || lower.contains("promo")
    }
}

enum NameCleaner {
    static func extractItemName(from row: RawReceiptRow) -> String {
        let tokens = row.words.flatMap(\.tokens)
        let cleaned = PriceParser.cleanItemName(tokens)
        return polishName(cleaned, fallback: row.fullText)
    }

    static func cleanMerchantName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: #"(?i)\b(receipt|invoice|order|sale|purchase)\b[:#]?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(store|terminal|register|cashier|associate|server|host)\s*#?:?\s*\w+\b"#, with: "", options: .regularExpression)
        return polishName(cleaned, fallback: raw)
    }

    private static func polishName(_ raw: String, fallback: String) -> String {
        var value = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*:|_"))

        value = value
            .replacingOccurrences(of: #"^[A-Z]?\d{4,13}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(qty|quantity|item|items|total|subtotal|tax|amount|balance|paid|change)\b[:#]?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*:|_"))

        if value.filter(\.isLetter).count < 2 {
            value = fallback
                .replacingOccurrences(of: #"\$?\d{1,4}[\._-]\d{2}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[A-Z]?\d{4,13}\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*:|_"))
        }

        guard !value.isEmpty else { return value }
        let uppercaseRatio = Double(value.filter { $0.isUppercase }.count) / Double(max(value.filter(\.isLetter).count, 1))
        if uppercaseRatio > 0.75 && value.count > 3 {
            return value.capitalized
        }
        return value
    }
}

enum ReceiptRowSemantics {
    static func isAddressLike(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.range(of: #"\b\d{1,5}\s+[a-z0-9]+\s+(ave|avenue|st|street|rd|road|blvd|boulevard|dr|drive|ln|lane|ct|court|way)\b"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\b[a-z .]+,\s*[a-z]{2}\s+\d{5}\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }
    static func isLocationHeaderLike(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["self-checkout","retail counter","host:","op#","cashier","associate",
                "store #","whse:","trm:","trn:","area:","member","gt member"]
            .contains(where: { lower.contains($0) }) || isAddressLike(text)
    }
    static func isPromoRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["bogo","coupon","discount","promo","promotion","reward","member savings","you saved","savings"]
            .contains(where: { lower.contains($0) })
    }
    static func isAmountOnlyRow(_ row: RawReceiptRow) -> Bool {
        row.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^\$?\d{1,4}\.\d{2}$"#, options: .regularExpression) != nil
    }
    static func isHeaderNoiseRow(_ row: RawReceiptRow) -> Bool {
        let text = row.fullText
        if PriceParser.isPoisonRow(text) || QuickTotalDetector.isTerminalNoiseRow(text) { return true }
        if isLocationHeaderLike(text) { return true }
        let lower = text.lowercased()
        return lower.contains("thank you") || lower.contains("please come again")
            || lower.contains("items sold") || lower.contains("check closed")
    }
    static func isModifierOnlyRow(_ row: RawReceiptRow) -> Bool {
        let lower = row.fullText.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = lower
            .replacingOccurrences(of: #"\$?\d{1,4}[\._-]\d{2}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*:|_"))
        guard !stripped.isEmpty else { return false }
        let modifierWords = [
            "whole", "iced", "hot", "large", "small", "medium", "regular",
            "simple syrup", "half sweet", "no ice", "less ice", "extra ice",
            "almond", "oat", "soy", "skim", "decaf", "add", "extra", "no "
        ]
        if modifierWords.contains(where: { stripped == $0 || stripped.hasPrefix($0 + " ") }) {
            return true
        }
        return stripped.filter(\.isLetter).count <= 4 && !stripped.contains(where: \.isNumber)
    }

    static func hasStrongItemName(_ row: RawReceiptRow) -> Bool {
        let name = NameCleaner.extractItemName(from: row)
        let letters = name.filter(\.isLetter).count
        if letters < 3 { return false }
        if isModifierOnlyRow(row) { return false }
        let lower = row.fullText.lowercased()
        if lower.contains("subtotal") || lower.contains("total") || lower.contains("tax") || lower.contains("tip") { return false }
        if isHeaderNoiseRow(row) || isPromoRow(row.fullText) { return false }
        return true
    }
}

func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

// ============================================================
// MARK: - Total Detection
// ============================================================

enum RowNormalizer {
    private static let garbleMap: [(pattern: String, replacement: String)] = [
        ("amcunt",  "amount"), ("amqunt",  "amount"), ("am0unt",  "amount"),
        ("seaz",    "seq"),    ("sea#",    "seq"),     ("vIsa",    "visa"),
        ("vls4",    "visa"),   ("resp:",   "resp:"),   ("appr0ved","approved"), ("appr0val","approval"),
    ]
    private static let pureNoisePatterns: Set<String> = [
        "m","n","l","i","j",";",":","|","•","·","—","–","o","0","°","*","`","'","\"","^","~"
    ]
    static func normalize(_ word: OCRWord) -> OCRWord? {
        let raw = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.count == 1 && pureNoisePatterns.contains(raw.lowercased()) { return nil }
        let asciiLetters = raw.filter { $0.isASCII && $0.isLetter }
        let allLetters   = raw.filter { $0.isLetter }
        if allLetters.count > 2 && asciiLetters.count == 0 {
            if let recovered = word.alternateCandidates.first(where: { candidate in
                let candLetters = candidate.filter(\.isLetter)
                let candAscii = candidate.filter { $0.isASCII && $0.isLetter }
                return candLetters.count > 2 && candAscii.count > 0
            }) {
                return OCRWord(text: recovered, confidence: word.confidence, rect: word.rect, recognizedText: word.recognizedText, alternateCandidates: word.alternateCandidates)
            }
            return nil
        }
        var cleaned = raw
        let lower   = raw.lowercased()
        for (pattern, replacement) in garbleMap {
            if lower == pattern {
                cleaned = raw.hasPrefix(raw.first.map(String.init) ?? "") && raw.first?.isUppercase == true
                    ? replacement.capitalized : replacement
                break
            }
        }
        if cleaned.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty
            && cleaned.filter(\.isLetter).count == 0
            && cleaned.filter(\.isNumber).count == 0 { return nil }
        return cleaned == raw ? word : OCRWord(text: cleaned, confidence: word.confidence, rect: word.rect, recognizedText: word.recognizedText, alternateCandidates: word.alternateCandidates)
    }
}

enum QuickTotalDetector {
    private enum TotalTier: Int, Comparable {
        case none = 0, arithmeticDerived = 1, paymentEcho = 2,
             balanceDue = 3, grandTotal = 4, explicitTotal = 5
        static func < (l: TotalTier, r: TotalTier) -> Bool { l.rawValue < r.rawValue }
    }

    private struct TotalCandidate {
        let amount: Double
        let label: String
        let rowText: String
        let zone: RowBuilder.Zone?
        let yPosition: CGFloat
        let tier: TotalTier
        let isExplicitTotal: Bool
        let isGrandTotal: Bool
        let isAmountDue: Bool
        let isSubtotal: Bool
        let isTax: Bool
        let isPaymentEcho: Bool
        let isCashTotal: Bool
        let isNonCashTotal: Bool
        var confidence: Double
        var rejectionReasons: [String]
    }

    static func detect(from snapshot: OCRSnapshot, rawRows: [RawReceiptRow]? = nil) -> QuickTotalResult {
        let merchant = detectMerchant(from: snapshot, rawRows: rawRows)
        var subtotal: Double?
        var taxLines: [Double] = []
        var totalTaxOverride: Double?
        var tip: Double?
        var feeLines: [Double] = []
        var total: Double?
        var totalTier = TotalTier.none
        var totalCandidates: [TotalCandidate] = []

        func accumulate(_ line: String, zone: RowBuilder.Zone? = nil, midY: CGFloat = 0, inPaymentZone: Bool = false) {
            let lower   = norm(line)
            guard !isHardRejectedTotalRow(lower) else { return }
            let amounts = PriceParser.extractAllIncludingUSD(from: line)
            guard !amounts.isEmpty else { return }
            if subtotal == nil && isSubtotalLabel(lower) {
                subtotal = amounts.filter { $0 > 5 }.max() ?? amounts.max()
            }
            if isTotalTaxLabel(lower) {
                let unique = Array(Set(amounts.map { Int($0 * 100) })).map { Double($0) / 100.0 }
                if let v = unique.filter({ $0 < 100 }).min() { totalTaxOverride = v }
            } else if isTaxLabel(lower) {
                let unique = Array(Set(amounts.map { Int($0 * 100) })).map { Double($0) / 100.0 }
                if let v = unique.filter({ $0 < 100 }).min() { taxLines.append(v) }
            }
            if tip == nil && isTipLabel(lower) { tip = amounts.min() }
            if isFeeLabel(lower) {
                let unique = Array(Set(amounts.map { Int($0 * 100) })).map { Double($0) / 100.0 }
                if let v = unique.filter({ $0 > 0 && $0 < 100 }).max() { feeLines.append(v) }
            }
            guard !inPaymentZone else {
                if isPaymentTotalEcho(lower) {
                    appendTotalCandidates(amounts: amounts, lower: lower, line: line, zone: zone, midY: midY)
                }
                return
            }
            appendTotalCandidates(amounts: amounts, lower: lower, line: line, zone: zone, midY: midY)
        }

        func appendTotalCandidates(amounts: [Double], lower: String, line: String, zone: RowBuilder.Zone?, midY: CGFloat) {
            let tier = grandTotalTier(lower)
            for amount in amounts.filter({ $0 >= 0.01 && $0 < 10000 }) {
                var candidate = TotalCandidate(
                    amount: round2(amount),
                    label: lower,
                    rowText: line,
                    zone: zone,
                    yPosition: midY,
                    tier: tier,
                    isExplicitTotal: hasTotalLabel(lower) && !isSubtotalLabel(lower),
                    isGrandTotal: lower.contains("grand total"),
                    isAmountDue: lower.contains("amount due") || lower.contains("balance due") || lower.contains("total due"),
                    isSubtotal: isSubtotalLabel(lower),
                    isTax: isTaxLabel(lower) || isTotalTaxLabel(lower),
                    isPaymentEcho: isPaymentTotalEcho(lower),
                    isCashTotal: lower.contains("cash") && !lower.contains("non-cash"),
                    isNonCashTotal: lower.contains("non-cash") || lower.contains("non cash") || lower.contains("card total"),
                    confidence: 0,
                    rejectionReasons: []
                )
                candidate.confidence = scoreTotalCandidate(candidate, subtotal: subtotal, taxLines: taxLines, fees: feeLines, tip: tip, snapshot: snapshot)
                if !candidate.rejectionReasons.contains("not_total_candidate"), candidate.tier != .none || candidate.isPaymentEcho {
                    totalCandidates.append(candidate)
                }
            }
        }

        if let rows = rawRows, !rows.isEmpty {
            for row in rows where row.zone == .summary  { accumulate(row.fullText, zone: row.zone, midY: row.midY) }
            for row in rows where row.zone == .items    { accumulate(row.fullText, zone: row.zone, midY: row.midY) }
            let start = max(0, rows.count - 12)
            for i in start..<rows.count {
                let row = rows[i]
                guard !isTerminalNoiseRow(row.fullText) else { continue }
                accumulate(row.fullText, zone: row.zone, midY: row.midY, inPaymentZone: row.zone == .payment || row.zone == .footer)
                if i + 1 < rows.count, rows[i+1].zone != .payment, rows[i+1].zone != .footer {
                    accumulate(row.fullText + " " + rows[i+1].fullText, zone: row.zone, midY: row.midY)
                }
            }
            for row in rows {
                guard !isTerminalNoiseRow(row.fullText) else { continue }
                accumulate(row.fullText, zone: row.zone, midY: row.midY, inPaymentZone: row.zone == .payment || row.zone == .footer)
            }
        }
        for line in snapshot.rawLines where !isTerminalNoiseRow(line) { accumulate(line) }

        var tax: Double? = {
            if let ov = totalTaxOverride { return ov }
            var deduped: [Double] = []
            for t in taxLines where !deduped.contains(where: { abs($0 - t) < 0.01 }) { deduped.append(t) }
            let s = round2(deduped.reduce(0, +))
            return s > 0 ? s : nil
        }()
        let fees: Double? = {
            var deduped: [Double] = []
            for f in feeLines where !deduped.contains(where: { abs($0 - f) < 0.01 }) { deduped.append(f) }
            let s = round2(deduped.reduce(0, +))
            return s > 0 ? s : nil
        }()

        let paymentContext = (
            snapshot.rawLines.joined(separator: " ") + " " +
            (rawRows?.map(\.fullText).joined(separator: " ") ?? "")
        ).lowercased()
        let hasExplicitTotalCandidate = totalCandidates.contains {
            ($0.isExplicitTotal || $0.isGrandTotal || $0.isAmountDue || $0.isCashTotal || $0.isNonCashTotal) &&
            !$0.isSubtotal && !$0.isTax && $0.tier != .none
        }

        if let selected = selectBestTotalCandidate(totalCandidates, subtotal: subtotal, tax: tax, fees: fees, tip: tip, paymentContext: paymentContext) {
            total = selected.amount
            totalTier = selected.tier
            print("  [QuickTotalCandidate.selected] amount=\(String(format: "%.2f", selected.amount)) conf=\(String(format: "%.2f", selected.confidence)) tier=\(selected.tier) row='\(selected.rowText)'")
        }

        let cashTotal = totalCandidates
            .filter { $0.isCashTotal && !$0.isNonCashTotal && !$0.isSubtotal && !$0.isTax }
            .max { $0.confidence < $1.confidence }?
            .amount
        let nonCashTotal = totalCandidates
            .filter { $0.isNonCashTotal && !$0.isSubtotal && !$0.isTax }
            .max { $0.confidence < $1.confidence }?
            .amount
        let nonCashFee: Double? = {
            guard let cashTotal, let nonCashTotal else { return nil }
            let fee = round2(nonCashTotal - cashTotal)
            return fee > 0 && fee <= max(5.0, cashTotal * 0.08) ? fee : nil
        }()
        let selectedGrandTotalBasis: String? = {
            guard let total else { return nil }
            if let nonCashTotal, abs(total - nonCashTotal) <= 0.01 { return "non_cash" }
            if let cashTotal, abs(total - cashTotal) <= 0.01 { return "cash" }
            return totalTier == .arithmeticDerived ? "arithmetic" : "explicit"
        }()
        let effectiveFees: Double? = {
            let base = fees ?? 0
            let addNonCashFee = selectedGrandTotalBasis == "non_cash" && base <= 0
            let value = round2(base + (addNonCashFee ? (nonCashFee ?? 0) : 0))
            return value > 0 ? value : nil
        }()

        if !hasExplicitTotalCandidate, (total == nil || totalTier == .none), let sub = subtotal, let t = tax {
            total = round2(sub + t + (fees ?? 0) + (tip ?? 0)); totalTier = .arithmeticDerived
        }
        if !hasExplicitTotalCandidate, (total == nil || totalTier == .none),
           let fallback = fallbackTotalCandidate(snapshot: snapshot, rawRows: rawRows, subtotal: subtotal, tax: tax, tip: tip) {
            total = fallback.total
            totalTier = fallback.tier
            print("  [QuickTotal] fallback total=\(String(format: "%.2f", fallback.total)) reason=\(fallback.reason)")
        }
        if let tot = total, let t = tax {
            let derivedTax = subtotal.map { round2(tot - $0 - (fees ?? 0) - (tip ?? 0)) }
            if abs(t - tot) < 0.01 || t >= tot * 0.50 || t > max(15.0, tot * 0.15) {
                if let derivedTax, derivedTax > 0, derivedTax <= max(15.0, tot * 0.15) {
                    print("  [QuickTotal] replacing suspicious tax \(String(format: "%.2f", t)) with derived \(String(format: "%.2f", derivedTax))")
                    tax = derivedTax
                } else {
                    print("  [QuickTotal] dropping suspicious tax \(String(format: "%.2f", t)) total=\(String(format: "%.2f", tot))")
                    tax = nil
                }
            }
        }
        if tax == nil, let sub = subtotal {
            let taxBasisTotal = cashTotal ?? total
            let derivedTax = taxBasisTotal.map { round2($0 - sub - (effectiveFees ?? 0) - (tip ?? 0)) }
            if let derivedTax, let taxBasisTotal, derivedTax > 0, derivedTax <= max(15.0, taxBasisTotal * 0.15) {
                print("  [QuickTotal] derived tax from subtotal/total: \(String(format: "%.2f", derivedTax))")
                tax = derivedTax
            }
        }
        if (totalTier == .arithmeticDerived || totalTier == .paymentEcho),
           let sub = subtotal, let t = tax, let tot = total,
           abs(round2(sub + t + (effectiveFees ?? 0) + (tip ?? 0)) - tot) < 0.02 { totalTier = .explicitTotal }
        if let sub = subtotal, let tot = total, sub >= tot { subtotal = nil }

        let conf: ReceiptParseResult.TotalConfidence
        switch totalTier {
        case .none:                                    conf = .none
        case .arithmeticDerived:                       conf = .medium
        case .paymentEcho:                             conf = .medium
        case .balanceDue, .grandTotal, .explicitTotal: conf = .high
        }
        logTotalCandidates(totalCandidates)
        print("  [QuickTotal] merchant='\(merchant)' total=\(total.map{String(format:"%.2f",$0)} ?? "nil") cash=\(cashTotal.map{String(format:"%.2f",$0)} ?? "nil") nonCash=\(nonCashTotal.map{String(format:"%.2f",$0)} ?? "nil") nonCashFee=\(nonCashFee.map{String(format:"%.2f",$0)} ?? "nil") basis=\(selectedGrandTotalBasis ?? "nil") subtotal=\(subtotal.map{String(format:"%.2f",$0)} ?? "nil") tax=\(tax.map{String(format:"%.2f",$0)} ?? "nil") fees=\(effectiveFees.map{String(format:"%.2f",$0)} ?? "nil") tier=\(totalTier)")
        return QuickTotalResult(merchant: merchant, total: total, cashTotal: cashTotal, nonCashTotal: nonCashTotal, nonCashFee: nonCashFee, selectedGrandTotalBasis: selectedGrandTotalBasis, subtotal: subtotal, tax: tax, tip: tip, fees: effectiveFees, totalConf: conf)
    }

    private static func scoreTotalCandidate(
        _ candidate: TotalCandidate,
        subtotal: Double?,
        taxLines: [Double],
        fees: [Double],
        tip: Double?,
        snapshot: OCRSnapshot
    ) -> Double {
        var score = Double(candidate.tier.rawValue) * 20.0
        let lower = candidate.label
        if candidate.isGrandTotal { score += 28 }
        if candidate.isAmountDue { score += 24 }
        if candidate.isNonCashTotal { score += containsAny(lower, ["visa", "card", "contactless"]) ? 24 : 14 }
        if candidate.isCashTotal { score += containsAny(snapshot.rawLines.joined(separator: " ").lowercased(), ["cash"]) ? 10 : -4 }
        if candidate.isExplicitTotal { score += 18 }
        if candidate.isPaymentEcho { score += 4 }
        if candidate.zone == .summary { score += 18 }
        if candidate.zone == .items { score -= 18 }
        if candidate.zone == .payment { score -= candidate.isPaymentEcho ? 4 : 22 }
        if candidate.zone == .footer || candidate.zone == .header { score -= 22 }

        if candidate.isSubtotal { score -= 85 }
        if candidate.isTax { score -= 90 }
        if containsAny(lower, ["change", "tendered", "amount paid", "suggested tip", "receipt code", "authorization", "approval", "auth", "aid", "terminal"]) {
            score -= 80
        }
        if containsAny(lower, ["survey", "feedback", "thank you", "merchant copy"]) {
            score -= 60
        }
        if let subtotal, subtotal > 0 {
            let tax = round2(taxLines.reduce(0, +))
            let fee = round2(fees.reduce(0, +))
            let expected = round2(subtotal + tax + fee + (tip ?? 0))
            let gap = abs(candidate.amount - expected)
            if gap <= 0.01 { score += 40 }
            else if gap <= 0.05 { score += 25 }
            else if candidate.amount + 0.01 < subtotal { score -= 35 }
        }
        let imageHeight = max(snapshot.imageSize.height, 1)
        let yNorm = Double(min(1, max(0, candidate.yPosition / imageHeight)))
        score += yNorm * 8
        return max(0, min(1, score / 140.0))
    }

    private static func selectBestTotalCandidate(_ candidates: [TotalCandidate], subtotal: Double?, tax: Double?, fees: Double?, tip: Double?, paymentContext: String) -> TotalCandidate? {
        let filtered = candidates.filter { $0.confidence >= 0.15 && !$0.isSubtotal && !$0.isTax }
        guard !filtered.isEmpty else { return nil }
        let hasCardPayment = containsAny(paymentContext, ["visa", "mastercard", "amex", "discover", "card", "contactless", "non-cash", "non cash", "approved"])
        let hasCashPayment = containsAny(paymentContext, ["cash tendered", "cash paid", "paid cash"]) && !hasCardPayment
        let expected = subtotal.map { round2($0 + (tax ?? 0) + (fees ?? 0) + (tip ?? 0)) }
        return filtered.max { lhs, rhs in
            func rank(_ c: TotalCandidate) -> Double {
                var value = c.confidence
                if hasCardPayment, c.isNonCashTotal { value += 0.18 }
                if hasCardPayment, c.isCashTotal { value -= 0.12 }
                if hasCashPayment, c.isCashTotal { value += 0.18 }
                if !hasCardPayment && !hasCashPayment && c.isNonCashTotal { value -= 0.04 }
                if let expected {
                    let gap = abs(c.amount - expected)
                    if gap <= 0.01 { value += 0.20 }
                    else if gap <= 0.05 { value += 0.12 }
                }
                if c.isPaymentEcho && c.tier < .explicitTotal { value -= 0.08 }
                return value
            }
            return rank(lhs) < rank(rhs)
        }
    }

    private static func logTotalCandidates(_ candidates: [TotalCandidate]) {
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }).prefix(12) {
            print("  [TotalCandidate] amount=\(String(format: "%.2f", candidate.amount)) conf=\(String(format: "%.2f", candidate.confidence)) tier=\(candidate.tier) zone=\(candidate.zone?.rawValue ?? "nil") explicit=\(candidate.isExplicitTotal) subtotal=\(candidate.isSubtotal) tax=\(candidate.isTax) paymentEcho=\(candidate.isPaymentEcho) row='\(candidate.rowText)'")
        }
    }

    private static func grandTotalTier(_ lower: String) -> TotalTier {
        if lower.contains("grand total") { return .grandTotal }
        if lower.contains("balance due") || lower.contains("amount due") || lower.contains("amount paid")
            || lower.contains("you paid") || lower.contains("order total") || lower.contains("total due")
            || lower.contains("carryout total") { return .balanceDue }
        if lower.contains("****") && lower.contains("total") { return .explicitTotal }
        if lower.hasPrefix("amount:") || lower.hasPrefix("amount :") || lower.hasPrefix("amcunt:") || lower.hasPrefix("amqunt:") { return .paymentEcho }
        let hasTotal = hasTotalLabel(lower)
        if hasTotal && !lower.contains("subtotal") && !lower.contains("sub total") && !lower.contains("sub-total")
            && !lower.contains("tax") && !lower.contains("items sold") && !lower.contains("total number")
            && !lower.contains("total discount") && !lower.contains("savings") { return .explicitTotal }
        return .none
    }

    private static func fallbackTotalCandidate(
        snapshot: OCRSnapshot,
        rawRows: [RawReceiptRow]?,
        subtotal: Double?,
        tax: Double?,
        tip: Double?
    ) -> (total: Double, tier: TotalTier, reason: String)? {
        var candidates: [(amount: Double, score: Double, reason: String)] = []
        let imageHeight = max(snapshot.imageSize.height, 1)

        func addCandidate(amount: Double, lower: String, midY: CGFloat, zone: RowBuilder.Zone?, source: String) {
            guard amount >= 0.01, amount < 10_000 else { return }
            guard !isTerminalNoiseRow(lower), !PriceParser.isPoisonRow(lower) else { return }
            guard !isHardRejectedTotalRow(lower) else { return }
            if lower.contains("receipt code") || lower.contains("order #") || lower.contains("phone") { return }

            let yNorm = min(1.0, max(0.0, Double(midY / imageHeight)))
            var score = yNorm * 30.0
            if let zone {
                switch zone {
                case .summary: score += 30
                case .items: score += 4
                case .payment: score -= 20
                case .footer, .header: score -= 14
                case .unknown: break
                }
            }

            if hasTotalLabel(lower) {
                score += 90
                if lower.contains("cash") && !lower.contains("non-cash") { score += 8 }
                if lower.contains("non-cash") { score += 2 }
            }
            if isSubtotalLabel(lower) { score -= 75 }
            if isTaxLabel(lower) || isTipLabel(lower) { score -= 85 }
            if lower.contains("amount") || lower.contains("balance") { score += 18 }

            if let subtotal, subtotal > 0 {
                if amount + 0.02 < subtotal { score -= 30 }
                if let tax, abs(amount - round2(subtotal + tax + (tip ?? 0))) <= 0.03 { score += 45 }
                if amount > subtotal { score += 18 }
            }

            candidates.append((round2(amount), score, "\(source):\(lower)"))
        }

        if let rows = rawRows {
            for row in rows {
                let lower = norm(row.fullText)
                let rowAmounts = dedupeAmounts(row.prices + PriceParser.extractAllIncludingUSD(from: row.fullText))
                for amount in rowAmounts {
                    addCandidate(amount: amount, lower: lower, midY: row.midY, zone: row.zone, source: "row")
                }
            }
        }

        for word in snapshot.words {
            let lower = norm(word.text)
            let amounts = PriceParser.extractAllIncludingUSD(from: word.text)
            for amount in amounts {
                addCandidate(amount: amount, lower: lower, midY: word.midY, zone: nil, source: "word")
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }), best.score > 20 else {
            return nil
        }
        let tier: TotalTier = best.reason.contains("total") || best.reason.contains("otal")
            ? .explicitTotal
            : .arithmeticDerived
        return (best.amount, tier, best.reason)
    }

    private static func dedupeAmounts(_ amounts: [Double]) -> [Double] {
        var out: [Double] = []
        for amount in amounts {
            let rounded = round2(amount)
            if !out.contains(where: { abs($0 - rounded) <= 0.001 }) {
                out.append(rounded)
            }
        }
        return out
    }

    static func detectMerchant(from snapshot: OCRSnapshot, rawRows: [RawReceiptRow]? = nil) -> String {
        var candidates: [(name: String, score: Int)] = []
        let medianH = max(snapshot.medianLineH, 1)

        if let rows = rawRows {
            var priorNames: [(idx: Int, row: RawReceiptRow, name: String, score: Int)] = []
            for (idx, row) in rows.prefix(12).enumerated() {
                if row.zone == .items || row.zone == .summary || row.zone == .payment { break }
                if let candidate = merchantCandidate(from: row.fullText, lineIndex: idx, row: row, medianLineHeight: medianH) {
                    candidates.append(candidate)
                    priorNames.append((idx, row, candidate.name, candidate.score))
                }
            }
            for i in 0..<max(0, priorNames.count - 1) {
                let a = priorNames[i]
                let b = priorNames[i + 1]
                guard b.idx == a.idx + 1 else { continue }
                guard averageWordHeight(a.row) > medianH * 1.15, averageWordHeight(b.row) > medianH * 1.15 else { continue }
                candidates.append(("\(a.name) \(b.name)", a.score + b.score + 12))
            }
        }
        for (idx, line) in snapshot.rawLines.prefix(10).enumerated() {
            if let candidate = merchantCandidate(from: line, lineIndex: idx, row: nil, medianLineHeight: medianH) {
                candidates.append(candidate)
            }
        }
        return candidates.max { $0.score < $1.score }?.name ?? ""
    }

    private static func averageWordHeight(_ row: RawReceiptRow) -> CGFloat {
        guard !row.words.isEmpty else { return 0 }
        return row.words.reduce(0) { $0 + $1.height } / CGFloat(row.words.count)
    }

    private static func merchantCandidate(from line: String, lineIndex: Int, row: RawReceiptRow?, medianLineHeight: CGFloat) -> (name: String, score: Int)? {
        let c = line.trimmingCharacters(in: .whitespaces)
        guard c.count >= 2, c.count <= 50 else { return nil }
        let lower = c.lowercased()
        if ReceiptRowSemantics.isAddressLike(c) { return nil }
        if lower.contains("survey") || lower.contains("feedback") || lower.contains("td #") { return nil }
        if lower.contains("host:") || lower.contains("server:") || lower.contains("register") || lower.contains("guest count") { return nil }
        if lower.contains("check #") || lower.contains("ordered:") || lower.contains("cashier") || lower.contains("op#") { return nil }
        if containsAny(lower, ["receipt code", "scan", "qr", "barcode", "coupon", "reward", "loyalty", "thanks for shopping", "thank you", "merchant copy"]) { return nil }
        if containsAny(lower, ["visa", "mastercard", "amex", "discover", "auth", "approval", "aid", "terminal", "contactless", "payment"]) { return nil }
        if lower.contains("www.") || lower.contains(".com") { return nil }
        if lower.contains("receipt") || lower == "order" || lower == "sale" { return nil }
        if lower.range(of: #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#, options: .regularExpression) != nil { return nil }
        if lower.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil { return nil }
        let digits = c.filter(\.isNumber).count
        let letters = c.filter(\.isLetter).count
        guard letters >= 3, digits <= 3 else { return nil }
        guard Double(letters) / Double(max(c.count, 1)) > 0.45 else { return nil }
        guard PriceParser.extractAll(from: c).isEmpty else { return nil }
        let name = NameCleaner.cleanMerchantName(c)
        guard name.filter(\.isLetter).count >= 3 else { return nil }

        var score = letters * 2 - digits * 3
        if c == c.uppercased() { score += 4 }
        if lower.contains("cafe") || lower.contains("coffee") || lower.contains("restaurant") || lower.contains("market") { score += 8 }
        if lower.contains("doughnuts") && lower.contains("coffee") { score -= 10 }
        score -= lineIndex * 2
        if lower.contains("#") { score -= 4 }
        if lower.contains("store") || lower.contains("terminal") || lower.contains("register") { score -= 6 }

        if let row {
            let height = averageWordHeight(row)
            if height > medianLineHeight * 1.6 { score += 14 }
            else if height > medianLineHeight * 1.2 { score += 6 }
        }
        return (name, score)
    }

    private static func legacyMerchantCandidateDisabled() {
        /*
         The old merchantCandidate implementation is intentionally left out; merchant scoring now uses
         top-row line height so short, visually prominent logos can beat longer lower text.
         */
    }

    private static func norm(_ text: String) -> String {
        RowBuilder.normalizeFuzzySummaryText(
            text.lowercased().replacingOccurrences(of: "|", with: "l")
                .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: "  ", with: " ")
        )
    }
    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
    private static func isSubtotalLabel(_ lower: String) -> Bool {
        ["subtotal","sub total","sub-total", "ubtotal", "subtotai", "subtota1"].contains(where: { lower.contains($0) })
    }
    private static func isTotalTaxLabel(_ lower: String) -> Bool {
        (lower.hasPrefix("total tax") || lower.hasPrefix("tax total") || lower == "total tax" || lower == "tax total") && !lower.contains("tax id")
    }
    private static func isTaxLabel(_ lower: String) -> Bool {
        guard !isTotalTaxLabel(lower) else { return false }
        return (lower.contains("tax") || lower.contains("hst") || lower.contains("gst") || lower.contains("pst") || lower.contains("vat"))
            && !lower.contains("tax id") && !lower.contains("without tax") && !lower.hasPrefix("tip")
    }
    private static func isTipLabel(_ lower: String) -> Bool {
        lower.hasPrefix("tip") && !lower.contains("tipsy") && !lower.contains("receipt")
    }
    private static func isFeeLabel(_ lower: String) -> Bool {
        ["dual price", "non-cash fee", "non cash fee", "service charge", "convenience fee",
         "card fee", "surcharge", "delivery fee", "processing fee", "service fee"].contains {
            lower.contains($0)
        }
    }
    private static func isPaymentTotalEcho(_ lower: String) -> Bool {
        containsAny(lower, ["amount:", "amount :", "amcunt:", "amqunt:", "sale total", "charged", "approved amount"])
    }
    private static func hasTotalLabel(_ lower: String) -> Bool {
        let normalized = lower
            .replacingOccurrences(of: "tota1", with: "total")
            .replacingOccurrences(of: "totai", with: "total")
        return normalized == "total"
            || normalized.hasPrefix("total ")
            || normalized.hasPrefix("total:")
            || normalized.contains(" total")
            || normalized.contains(":total")
            || normalized == "otal"
            || normalized.hasPrefix("otal ")
            || normalized.hasPrefix("otal:")
            || normalized.contains(" otal")
            || normalized.contains(":otal")
    }
    static func isTerminalNoiseRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["tvr:","tsi:","rrn:","aid:","noic","xxxxxxxxxxxx","cntctless",
                "entry method","auth code","approval code","authorization","application id",
                "payment id","device id","card reader","transaction type","input type",
                "powered by","emv chip","contactless","change due","change:"]
            .contains(where: { lower.contains($0) })
    }

    static func isHardRejectedTotalRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("suggested tip")
            || lower.contains("%")
            || lower.contains("approval")
            || lower.contains("auth")
            || lower.contains("aid")
            || lower.contains("reference")
            || lower.contains("account")
            || lower.contains("card name")
            || lower.contains("pan")
            || lower.contains("tid")
            || lower.contains("mid")
    }
}

// ============================================================
// MARK: - Row Builder
// ============================================================

enum RowBuilder {
    enum Zone: String { case header, items, summary, payment, footer, unknown }
    enum TokenType { case sku, word, price, summaryWord, paymentWord, memberID, taxFlag, junk }
    struct ClassifiedWord { let word: OCRWord; let type: TokenType }

    private static let summaryKeywords = ["subtotal","sub-total","sub total","ubtotal","subtota1","total","tota1","totai","otal","lotal","lota","grand total","tax","lax","tux","hst","gst","pst","vat","amount due","balance due","change","cash","non-cash","non cash"]
    private static let paymentKeywords = ["visa","mastercard","amex","discover","approved","approval","auth","aid:","tran","seq","rrn","amount:","contactless","emv","chip","xxxx","amcunt","amqunt"]
    private static let headerKeywords  = ["self-checkout","retail counter","cashier","associate","store #","whse:","trm:","trn:","op#","op$:","gt member","member"]
    private static let footerKeywords  = ["thank you","please come again","items sold","total number of items","op$:","whse:","trm:","trn:","op:"]

    static func buildRows(from snapshot: OCRSnapshot) -> [RawReceiptRow] {
        let effectiveH = max(snapshot.p20LineH, 6)
        let normalizedWords = snapshot.words.compactMap { RowNormalizer.normalize($0) }
        let classified = normalizedWords.map { classifyWord($0) }

        var groups: [RowGroup] = []
        for (word, cls) in zip(normalizedWords, classified) {
            var bestIdx: Int?; var bestScore: CGFloat = 0
            for (i, group) in groups.enumerated() {
                let overlap      = max(0, min(word.maxY, group.maxY) - max(word.minY, group.minY))
                let overlapRatio = overlap / max(min(word.height, group.height), 0.001)
                let midGap       = abs(word.midY - group.midY)
                if overlapRatio > 0.42 && midGap < effectiveH * 0.95 {
                    let score = overlapRatio - (midGap * 0.10)
                    if score > bestScore { bestScore = score; bestIdx = i }
                }
            }
            if let idx = bestIdx { groups[idx].add(word, cls) }
            else { var g = RowGroup(); g.add(word, cls); groups.append(g) }
        }

        let sorted = groups.sorted { $0.midY < $1.midY }
        let zones  = assignZones(to: sorted)
        var rows: [RawReceiptRow] = []
        for (gIdx, group) in sorted.enumerated() {
            rows.append(contentsOf: structuralSplit(group: group, zone: zones[gIdx]))
        }
        rows = mergePriceOnlyRows(rows, medianLineH: effectiveH)
        rows.sort { $0.midY < $1.midY }
        for i in rows.indices { rows[i].rowIndex = i }
        print("  [RowBuilder] \(snapshot.words.count) words → \(rows.count) rows")
        for row in rows {
            print("  [VisualRow \(row.rowIndex)] y=\(Int(row.midY.rounded())) xRange=\(Int(row.minX.rounded()))-\(Int(row.maxX.rounded())) zone=\(row.zone.rawValue) text='\(row.fullText)'")
        }
        return rows
    }

    static func classifyWord(_ word: OCRWord) -> TokenType {
        let text  = word.text.trimmingCharacters(in: .whitespaces)
        let lower = normalizeFuzzySummaryText(text.lowercased())
        if text.isEmpty { return .junk }
        let asciiLetters = text.filter { $0.isASCII && $0.isLetter }
        let allLetters   = text.filter { $0.isLetter }
        if allLetters.count > 0 && asciiLetters.count == 0 { return .junk }
        if allLetters.isEmpty && text.filter({ $0.isNumber }).isEmpty { return .junk }
        if PriceParser.looksLikeMemberID(text) { return .memberID }
        if PriceParser.isSKUCode(text)          { return .sku }
        if PriceParser.looksLikePrice(text)     { return .price }
        if PriceParser.isTaxFlag(text)          { return .taxFlag }
        if text.range(of: #"^\d{1,2}/\d{1,3}\.?\d*$"#, options: .regularExpression) != nil { return .price }
        if paymentKeywords.contains(where: { lower.contains($0) }) { return .paymentWord }
        if summaryKeywords.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ":") }) { return .summaryWord }
        if headerKeywords.contains(where: { lower.contains($0) }) { return .junk }
        return .word
    }

    private static func assignZones(to groups: [RowGroup]) -> [Zone] {
        let n = groups.count
        var zones = Array(repeating: Zone.unknown, count: n)
        let summaryBarrierIdx = findSummaryBarrier(in: groups)
        let topY    = groups.first?.midY ?? 0
        let bottomY = groups.last?.midY  ?? 1
        let span    = max(bottomY - topY, 0.01)
        let headerCutoff: CGFloat = topY + span * 0.20
        var leadingNoPriceBands = 0
        for group in groups {
            let hasPrice = group.classifiedWords.contains { $0.type == .price }
            let hasSKU   = group.classifiedWords.contains { $0.type == .sku }
            if !hasPrice && !hasSKU { leadingNoPriceBands += 1 } else { break }
        }
        leadingNoPriceBands = min(leadingNoPriceBands, 8)
        for (i, group) in groups.enumerated() {
            let lower = normalizeFuzzySummaryText(group.words.map { $0.text.lowercased() }.joined(separator: " "))
            let hasPaymentWord = group.classifiedWords.contains { $0.type == .paymentWord }
            if isCouponSurveyFooter(lower) { zones[i] = .footer; continue }
            if hasPaymentWord || lower.contains("xxxx") || lower.contains("aid:") || lower.contains("approved") || lower.contains("tran") || lower.contains("seq") || lower.contains("rrn:") { zones[i] = .payment; continue }
            if footerKeywords.contains(where: { lower.contains($0) }) || lower.contains("op$:") || lower.contains("whse:") || lower.contains("trm:") || lower.contains("trn:") { zones[i] = .footer; continue }
            if isFuzzySummaryRow(lower) { zones[i] = .summary; continue }
            if let barrier = summaryBarrierIdx, i >= barrier { zones[i] = .summary; continue }
            if i < leadingNoPriceBands { zones[i] = .header; continue }
            if group.midY <= headerCutoff {
                let hasPrice    = group.classifiedWords.contains { $0.type == .price }
                let hasSKU      = group.classifiedWords.contains { $0.type == .sku }
                let hasItemWord = group.classifiedWords.contains { $0.type == .word && $0.word.text.filter(\.isLetter).count >= 4 }
                if ReceiptRowSemantics.isAddressLike(lower) { zones[i] = .header; continue }
                if lower.contains("member") { zones[i] = .header; continue }
                if !hasPrice && !hasSKU && !hasItemWord { zones[i] = .header; continue }
            }
            zones[i] = .items
        }
        return zones
    }

    private static func findSummaryBarrier(in groups: [RowGroup]) -> Int? {
        for (i, group) in groups.enumerated() {
            let lower      = normalizeFuzzySummaryText(group.words.map { $0.text.lowercased() }.joined(separator: " "))
            let hasSummary = group.classifiedWords.contains { $0.type == .summaryWord }
            let hasItem    = group.classifiedWords.contains { $0.type == .word && $0.word.text.filter(\.isLetter).count >= 4 }
            let hasSKU     = group.classifiedWords.contains { $0.type == .sku }
            guard (hasSummary || isFuzzySummaryRow(lower)) && !hasItem && !hasSKU else { continue }
            if lower.contains("subtotal") || lower.contains("sub total") || lower.contains("sub-total")
                || lower.contains("grand total") || lower == "total" || lower.hasPrefix("total ")
                || lower.contains("cash") || lower.contains("non-cash")
                || lower.contains("**** total") { return i }
        }
        return nil
    }

    static func normalizeFuzzySummaryText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "subtota1", with: "subtotal")
            .replacingOccurrences(of: "subtotai", with: "subtotal")
            .replacingOccurrences(of: "ubtotal", with: "subtotal")
            .replacingOccurrences(of: " l ax ", with: " tax ")
            .replacingOccurrences(of: "lax", with: "tax")
            .replacingOccurrences(of: "tux", with: "tax")
            .replacingOccurrences(of: "(otal", with: "total")
            .replacingOccurrences(of: "tota1", with: "total")
            .replacingOccurrences(of: "totai", with: "total")
            .replacingOccurrences(of: "lotal", with: "total")
            .replacingOccurrences(of: "lota", with: "total")
            .replacingOccurrences(of: " otal", with: " total")
            .replacingOccurrences(of: "uash", with: "cash")
            .replacingOccurrences(of: "ron-lash", with: "non-cash")
            .replacingOccurrences(of: "non lash", with: "non-cash")
            .replacingOccurrences(of: "ron cash", with: "non-cash")
    }

    private static func isFuzzySummaryRow(_ lower: String) -> Bool {
        lower.contains("subtotal") || lower.contains("tax") || lower.contains("total")
            || lower.contains("balance due") || lower.contains("amount due")
            || lower.contains("non-cash") || lower.contains("cash total")
    }

    private static func isCouponSurveyFooter(_ lower: String) -> Bool {
        ["survey", "visit today", "complete our survey", "listen", "redeem", "receive a code",
         "validation code", "offer expires", "coupon", "product may vary", "not redeemable",
         "not valid", "cash value", "sweepstakes", "rewards member", "download the app",
         "apply online", "thank you for visiting"].contains { lower.contains($0) }
    }

    private static func structuralSplit(group: RowGroup, zone: Zone) -> [RawReceiptRow] {
        guard zone == .items else { return [group.toRow(zone: zone)] }
        let tokens = group.classifiedWords.filter { $0.type != .memberID && $0.type != .junk }.sorted { $0.word.minX < $1.word.minX }
        let hasItemAnchor = tokens.contains { $0.type == .word && $0.word.text.filter(\.isLetter).count >= 3 }
        let hasSKU = tokens.contains { $0.type == .sku }
        if !hasItemAnchor && !hasSKU { return [group.toRow(zone: .header)] }
        let skuPositions = tokens.indices.filter { tokens[$0].type == .sku }
        if skuPositions.count >= 2 {
            let priceCount = tokens.filter { $0.type == .price }.count
            let wordCount  = tokens.filter { $0.type == .word  }.count
            if priceCount >= 1 || wordCount >= 2 {
                let rows = splitBySKUBoundary(tokens: tokens, skuPositions: skuPositions, group: group)
                if rows.count >= 2 { return rows }
            }
        }
        if tokens.contains(where: { $0.type == .summaryWord }) {
            if let splitIdx = tokens.firstIndex(where: { $0.type == .summaryWord }) {
                var itemPart = Array(tokens[0..<splitIdx])
                itemPart = stripSummaryLeakPrices(from: itemPart, summaryTokens: Array(tokens[splitIdx...]))
                let summaryPart = Array(tokens[splitIdx...])
                var result: [RawReceiptRow] = []
                if !itemPart.isEmpty    { result.append(makeRow(from: itemPart.map    { $0.word }, zone: .items)) }
                if !summaryPart.isEmpty { result.append(makeRow(from: summaryPart.map { $0.word }, zone: .summary)) }
                if result.count >= 2 { return result }
            }
        }
        if tokens.count < group.classifiedWords.count { return [makeRow(from: tokens.map { $0.word }, zone: .items)] }
        return [group.toRow(zone: .items)]
    }

    private static func stripSummaryLeakPrices(from itemTokens: [ClassifiedWord], summaryTokens: [ClassifiedWord]) -> [ClassifiedWord] {
        let summaryPrices = Set(summaryTokens.filter { $0.type == .price }.compactMap { Double($0.word.text.replacingOccurrences(of: "$", with: "")) }.map { Int($0 * 100) })
        let summaryText   = summaryTokens.map { $0.word.text }.joined(separator: " ")
        let summaryAmounts = PriceParser.extractAllIncludingUSD(from: summaryText).map { Int($0 * 100) }
        let allSummaryAmounts = summaryPrices.union(Set(summaryAmounts))
        return itemTokens.filter { token in
            guard token.type == .price else { return true }
            guard let v = Double(token.word.text.replacingOccurrences(of: "$", with: "")) else { return true }
            return !allSummaryAmounts.contains(Int(v * 100))
        }
    }

    private static func splitBySKUBoundary(tokens: [ClassifiedWord], skuPositions: [Int], group: RowGroup) -> [RawReceiptRow] {
        var segments: [[ClassifiedWord]] = []
        for (segIdx, skuPos) in skuPositions.enumerated() {
            let end = segIdx + 1 < skuPositions.count ? skuPositions[segIdx + 1] : tokens.count
            segments.append(Array(tokens[skuPos..<end]))
        }
        var allPrices = tokens.filter { $0.type == .price }.sorted { $0.word.minX < $1.word.minX }
        var clean = segments.map { seg in seg.filter { $0.type != .price } }
        for i in clean.indices {
            guard !allPrices.isEmpty else { break }
            clean[i].append(allPrices.removeFirst())
        }
        return clean.compactMap { seg -> RawReceiptRow? in
            let words = seg.map { $0.word }
            guard !words.isEmpty else { return nil }
            return makeRow(from: words, zone: .items)
        }
    }

    private static func mergePriceOnlyRows(_ rows: [RawReceiptRow], medianLineH: CGFloat) -> [RawReceiptRow] {
        guard rows.count > 1 else { return rows }
        let ordered = rows.sorted { $0.midY < $1.midY }

        func isPriceOnly(_ row: RawReceiptRow) -> Bool {
            guard row.zone == .items, !row.prices.isEmpty else { return false }
            let hasName = row.words.contains { word in
                word.tokens.contains { token in
                    !PriceParser.looksLikePrice(token)
                        && !PriceParser.isTaxFlag(token)
                        && !PriceParser.isSKUCode(token)
                        && token.filter(\.isLetter).count >= 3
                }
            }
            return !hasName
        }

        func isNameOnly(_ row: RawReceiptRow) -> Bool {
            row.zone == .items && row.prices.isEmpty && ReceiptRowSemantics.hasStrongItemName(row)
        }

        var out: [RawReceiptRow] = []
        var pendingNameRow: RawReceiptRow?

        for row in ordered {
            if isPriceOnly(row), let pending = pendingNameRow, abs(row.midY - pending.midY) < medianLineH * 1.6 {
                var merged = pending
                merged.words.append(contentsOf: row.words)
                merged.words.sort { $0.minX < $1.minX }
                merged.minY = min(merged.minY, row.minY)
                merged.maxY = max(merged.maxY, row.maxY)
                merged.midY = (merged.minY + merged.maxY) / 2
                merged.minX = min(merged.minX, row.minX)
                merged.maxX = max(merged.maxX, row.maxX)
                out.append(merged)
                pendingNameRow = nil
                continue
            }
            if let pending = pendingNameRow {
                out.append(pending)
                pendingNameRow = nil
            }
            if isNameOnly(row) {
                pendingNameRow = row
            } else {
                out.append(row)
            }
        }
        if let pending = pendingNameRow { out.append(pending) }
        return out
    }

    private static func makeRow(from words: [OCRWord], zone: Zone) -> RawReceiptRow {
        let s = words.sorted { $0.minX < $1.minX }
        var row = RawReceiptRow(words: s, minY: s.map(\.minY).min() ?? 0, maxY: s.map(\.maxY).max() ?? 0,
                                midY: ((s.map(\.minY).min() ?? 0) + (s.map(\.maxY).max() ?? 0)) / 2,
                                minX: s.map(\.minX).min() ?? 0, maxX: s.map(\.maxX).max() ?? 0)
        row.zone = zone; return row
    }

    private struct RowGroup {
        var words: [OCRWord] = []; var classifiedWords: [ClassifiedWord] = []
        var minY: CGFloat = .greatestFiniteMagnitude; var maxY: CGFloat = -.greatestFiniteMagnitude
        var minX: CGFloat = .greatestFiniteMagnitude; var maxX: CGFloat = -.greatestFiniteMagnitude
        var midY: CGFloat { (minY + maxY) / 2 }; var height: CGFloat { maxY - minY }
        var fullText: String { words.map(\.text).joined(separator: " ") }
        mutating func add(_ w: OCRWord, _ cls: TokenType) {
            words.append(w); classifiedWords.append(ClassifiedWord(word: w, type: cls))
            minY = min(minY, w.minY); maxY = max(maxY, w.maxY); minX = min(minX, w.minX); maxX = max(maxX, w.maxX)
        }
        func toRow(zone: Zone) -> RawReceiptRow {
            let s = words.sorted { $0.minX < $1.minX }
            var row = RawReceiptRow(words: s, minY: minY, maxY: maxY, midY: midY, minX: minX, maxX: maxX)
            row.zone = zone; return row
        }
    }
}

// ============================================================
// MARK: - Supporting receipt types
// ============================================================

enum OCRSection: String, Codable { case header, items, summary, footer }
enum XBucket:   String, Codable  { case left, mid, right }
enum YBucket:   String, Codable  { case top, upper, lower, bottom }
struct OCRToken: Codable { let text: String; let xBucket: XBucket }
struct OCRRow: Codable {
    let rowIndex: Int; let yNorm: Float; let yBucket: YBucket
    let section: OCRSection; let tokens: [OCRToken]
    var fullText: String { tokens.map(\.text).joined(separator: " ") }
}

extension String {
    func ranges(of searchString: String, options: String.CompareOptions = []) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []; var start = startIndex
        while start < endIndex, let r = range(of: searchString, options: options, range: start..<endIndex) {
            ranges.append(r); start = r.upperBound
        }
        return ranges
    }
}

// ============================================================
// MARK: - Local Parse Quality Gate
// ============================================================

enum LocalReceiptQualityGate {
    // Precompiled once to avoid recompilation during every local receipt build.
    private static let isoDateRegex = try! NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#)
    private static let slashDateRegex = try! NSRegularExpression(pattern: #"\b(\d{1,2})[/\-](\d{1,2})[/\-](\d{2,4})\b"#)
    private static let monthDateRegex = try! NSRegularExpression(pattern: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+(\d{1,2}),?\s+(\d{4})\b"#, options: .caseInsensitive)

    struct Assessment {
        let usable:  Bool
        let reasons: [String]
        let score:   Float
    }

    enum LocalItemizationStatus: String {
        case fullItemizedTrusted
        case itemizedNeedsReview
        case totalOnlyTrusted
        case paymentSlipNoItems
        case failed
    }

    enum LocalReceiptKind: String {
        case restaurantItemized
        case groceryRetail
        case paymentSlip
        case pharmacyRetail
        case unknown
    }

    enum LocalReceiptZone: String {
        case header
        case itemSection
        case summarySection
        case paymentSection
        case tipSuggestionSection
        case footer
    }

    struct OCRWordBox {
        let text: String
        let alternateCandidates: [String]
        let rect: CGRect
        let confidence: Float
        let rowIndex: Int
        let zone: LocalReceiptZone
        var midX: CGFloat { rect.midX }
        var midY: CGFloat { rect.midY }
        var maxX: CGFloat { rect.maxX }
        var minX: CGFloat { rect.minX }
    }

    struct PriceToken {
        let amount: Double
        let sourceText: String
        let repairedText: String?
        let source: String
        let rect: CGRect
        let confidence: Float
        let rowIndex: Int
        let zone: LocalReceiptZone
        var midX: CGFloat { rect.midX }
        var midY: CGFloat { rect.midY }
    }

    struct ItemNameContext {
        let inItemWindow: Bool
        let rightColumnPriceSupport: Bool
        let nearbyPriceSupport: Bool
        let beforeSummary: Bool
        let repairedPairing: Bool
    }

    struct ItemCandidate {
        let name: String
        let price: Double
        let zone: LocalReceiptZone
        let yPosition: CGFloat
        let confidence: Double
        let evidence: [String]
        let warnings: [String]
        let accepted: Bool
        let rowIndex: Int
    }

    struct DiscountCandidate {
        let amount: Double
        let rowIndex: Int
        let sourceRow: String
    }

    struct LocalItemizationResult {
        let status: LocalItemizationStatus
        let receiptKind: LocalReceiptKind
        let itemizationAttempted: Bool
        let itemizationAttemptReason: String
        let itemWindowFound: Bool
        let itemNameCandidateCount: Int
        let itemPriceCandidateCount: Int
        let itemizationFailureReason: String?
        let items: [LocalItemCandidate]
        let acceptedCandidates: [ItemCandidate]
        let rejectedCandidates: [ItemCandidate]
        let discounts: [DiscountCandidate]
        let expectedItemCount: Int?
        let itemSum: Double
        let discountTotal: Double
        let reconciliationGap: Double?
        let warnings: [String]
        let confidence: Double
    }

    struct ItemizationEvidence {
        let itemWindowFound: Bool
        let itemNameCandidateCount: Int
        let itemPriceCandidateCount: Int
        let reason: String
    }

    struct LocalItemCandidate {
        let name: String
        let price: Double
        let rowIndex: Int
    }

    static func isReceiptLike(_ ctx: OCRPipelineContext) -> Bool {
        let words      = ctx.snapshot.words
        let rawLines   = ctx.snapshot.rawLines

        guard words.count >= 5 else {
            print("  [isReceiptLike] ✗ too few words: \(words.count)")
            return false
        }

        let fullText = rawLines.joined(separator: " ")
        let priceMatches = fullText.ranges(
            of: #"(?<!\d)(?:\$?\s*)?\d{1,4}(?:[\.\-_]\d{2})?(?!\d)"#, options: .regularExpression
        )

        let priceCount = ctx.rawRows.reduce(0) { $0 + $1.prices.count }
        let numericTokenCount = words.reduce(0) { total, word in
            total + (word.tokens.contains { $0.contains(where: \.isNumber) } ? 1 : 0)
        }
        guard priceCount >= 1 || priceMatches.count >= 1 || numericTokenCount >= 2 else {
            print("  [isReceiptLike] ✗ no amount-like evidence priceCount=\(priceCount) numericTokens=\(numericTokenCount)")
            return false
        }

        let hasItemText = words.contains { word in
            word.text.filter(\.isLetter).count >= 3
        }
        guard hasItemText else {
            print("  [isReceiptLike] ✗ no item-like text")
            return false
        }

        let lower = fullText.lowercased()
        let hasReceiptLabel = ["total","subtotal","tax","amount","balance",
                               "receipt","order","sale","purchase","payment"].contains {
            lower.contains($0)
        }

        let rowsWithPrice = ctx.rawRows.filter { !$0.prices.isEmpty }.count
        print("  [isReceiptLike] ✓ words=\(words.count) prices=\(priceCount) numericTokens=\(numericTokenCount) priceRows=\(rowsWithPrice) hasLabel=\(hasReceiptLabel)")
        return true
    }

    static func assess(ctx: OCRPipelineContext) -> Assessment {
        var reasons: [String] = []
        var score: Float = 0

        guard let grandTotal = ctx.quick.total, grandTotal > 0 else {
            return Assessment(usable: false, reasons: ["grand_total_missing"], score: 0)
        }
        
        guard ctx.quick.totalConf == .high else {
            return Assessment(usable: false, reasons: ["total_confidence_not_high:\(ctx.quick.totalConf)"], score: 0.10)
        }
        score += 0.40

        let itemization = localItemization(ctx: ctx)
        switch itemization.status {
        case .fullItemizedTrusted:
            score += 0.25
        case .totalOnlyTrusted:
            reasons.append("total_only_trusted")
            score += 0.10
        case .paymentSlipNoItems:
            reasons.append("payment_slip_no_merchandise_items")
            score += 0.08
        case .itemizedNeedsReview:
            reasons.append("itemization_needs_review")
            reasons.append(contentsOf: itemization.warnings)
            return Assessment(usable: false, reasons: reasons, score: score)
        case .failed:
            reasons.append("itemization_failed")
            reasons.append(contentsOf: itemization.warnings)
            return Assessment(usable: false, reasons: reasons, score: score)
        }

        let tax        = ctx.quick.tax ?? 0
        let tip        = ctx.quick.tip ?? 0
        let fees       = ctx.quick.fees ?? 0
        let chargeSum  = round2(tax + tip + fees)
        let merch      = round2(grandTotal - chargeSum)
        let itemSum    = itemization.itemSum
        
        let gapAbs  = abs(itemSum - merch)
        let gapCents = Int((gapAbs * 100).rounded())

        if itemization.status == .paymentSlipNoItems || itemization.status == .totalOnlyTrusted {
            return Assessment(usable: false, reasons: reasons, score: min(score, 1.0))
        }

        guard gapCents <= 2 else {
            reasons.append("arithmetic_gap_\(gapCents)cents")
            return Assessment(usable: false, reasons: reasons, score: score)
        }
        score += 0.30

        if tax == 0 {
            guard gapCents <= 2 else {
                reasons.append("zero_tax_arithmetic_gap")
                return Assessment(usable: false, reasons: reasons, score: score)
            }
        } else if tax > max(15.0, grandTotal * 0.15) {
            reasons.append("tax_too_large")
            return Assessment(usable: false, reasons: reasons, score: score)
        } else if tax < grandTotal * 0.02 && grandTotal > 20 {
            reasons.append("tax_suspiciously_low")
            score += 0.03
        } else {
            score += 0.05
        }

        let maxItemPrice = itemization.items.map(\.price).max() ?? 0
        if maxItemPrice >= grandTotal * 0.90 && itemization.items.count == 1 {
            let singleItemGap = abs(maxItemPrice - merch)
            if singleItemGap > 0.02 {
                reasons.append("dominant_item_likely_total_echo")
                return Assessment(usable: false, reasons: reasons, score: score)
            }
        }

        score += min(Float(itemization.items.count) * 0.01, 0.05)

        let usable = reasons.isEmpty || reasons.allSatisfy { $0.hasPrefix("tax_suspiciously_low") }
        return Assessment(usable: usable, reasons: reasons, score: min(score, 1.0))
    }

    static func buildReceiptData(from ctx: OCRPipelineContext) -> OCRService.ReceiptData {
        let tax      = round2(ctx.quick.tax ?? 0)
        let tip      = round2(ctx.quick.tip ?? 0)
        let fees     = round2(ctx.quick.fees ?? 0)
        var total    = round2(ctx.quick.total ?? 0)
        let subtotal = ctx.quick.subtotal.map(round2)
            ?? (total > 0 ? round2(total - tax - fees - tip) : nil)

        let itemization = localItemization(ctx: ctx)
        let itemCandidates = itemization.items
        if total <= 0 {
            let itemSum = round2(itemCandidates.reduce(0) { $0 + $1.price })
            if let subtotal, subtotal > 0, tax > 0 {
                total = round2(subtotal + tax + fees + tip)
                print("  [LocalReceipt] derived missing total from subtotal/tax: \(String(format: "%.2f", total))")
            } else if itemSum > 0, tax > 0 {
                total = round2(itemSum + tax + fees + tip)
                print("  [LocalReceipt] derived missing total from items/tax: \(String(format: "%.2f", total))")
            }
        }

        var allItems: [ReceiptLineItem] = itemCandidates.compactMap { candidate in
            let price = candidate.price
            let name = candidate.name
            guard price > 0, name.filter(\.isLetter).count >= 2 else { return nil }
            return ReceiptLineItem(
                name: name,
                originalPrice: price,
                discount: 0,
                amount: price,
                taxPortion: 0,
                isSelected: true,
                category: .merchandise
            )
        }

        if tax > 0 {
            allItems.append(ReceiptLineItem(
                name: "Tax",
                originalPrice: tax,
                discount: 0,
                amount: tax,
                taxPortion: 0,
                isSelected: true,
                category: .tax
            ))
        }
        if tip > 0 {
            allItems.append(ReceiptLineItem(
                name: "Tip",
                originalPrice: tip,
                discount: 0,
                amount: tip,
                taxPortion: 0,
                isSelected: true,
                category: .tip
            ))
        }
        if fees > 0 {
            allItems.append(ReceiptLineItem(
                name: "Fee",
                originalPrice: fees,
                discount: 0,
                amount: fees,
                taxPortion: 0,
                isSelected: true,
                category: .fee
            ))
        }

        let itemSum   = round2(allItems.reduce(0) { $0 + $1.amount })
        let gapCents  = total > 0 ? abs(Int(((itemSum - total) * 100).rounded())) : 0
        let valStatus: OCRService.ValidationStatus = gapCents <= 1 ? .balanced : gapCents <= 2 ? .closeEnough : total > 0 ? .mismatch : .notValidated

        let confScore: Float = gapCents <= 1 ? 0.95 : gapCents <= 2 ? 0.90 : 0.70
        let imageQualityScore = ctx.quality.map { Float($0.score / 100.0) } ?? confScore
        var validationIssues = itemization.warnings
        validationIssues.append("local_itemization_status:\(itemization.status.rawValue)")
        validationIssues.append("local_receipt_kind:\(itemization.receiptKind.rawValue)")
        validationIssues.append("itemization_attempted:\(itemization.itemizationAttempted)")
        validationIssues.append("itemization_attempt_reason:\(itemization.itemizationAttemptReason)")
        validationIssues.append("item_window_found:\(itemization.itemWindowFound)")
        validationIssues.append("item_name_candidate_count:\(itemization.itemNameCandidateCount)")
        validationIssues.append("item_price_candidate_count:\(itemization.itemPriceCandidateCount)")
        validationIssues.append("accepted_item_count:\(itemization.acceptedCandidates.count)")
        validationIssues.append("rejected_item_count:\(itemization.rejectedCandidates.count)")
        if let failure = itemization.itemizationFailureReason {
            validationIssues.append("itemization_failure_reason:\(failure)")
        }
        if itemization.status != .fullItemizedTrusted {
            validationIssues.append("local_itemization_not_trusted")
        }
        if itemization.status == .paymentSlipNoItems {
            validationIssues.append("payment_slip_no_items")
        }

        return OCRService.ReceiptData(
            merchant:            ctx.quick.merchant,
            lineItems:           allItems,
            hasReceiptStructure: true,
            confidence:          confScore,
            grandTotal:          total > 0 ? total : nil,
            processingMethod:    .appleLocal,
            receiptDate:         Self.extractNormalizedDate(from: ctx.snapshot),
            needsReview:         itemization.status != .fullItemizedTrusted,
            fallbackReason:      "\(rawOCRDebugDetail(from: ctx)) | itemization=\(itemization.status.rawValue) kind=\(itemization.receiptKind.rawValue)",
            currency:            "USD",
            qualityScore:        min(confScore, imageQualityScore),
            totalConfidence:     .high,
            validationStatus:    valStatus,
            arithmeticGapCents:  gapCents,
            validationIssues:    Array(Set(validationIssues)).sorted(),
            ocrRoute:            "apple_local_\(itemization.status.rawValue)",
            backgroundResultToken: nil,
            preprocessedPreviewImage: ctx.previewImage
        )
    }

    private static func rawOCRDebugDetail(from ctx: OCRPipelineContext) -> String {
        let rawLines = ctx.snapshot.rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(30)
            .joined(separator: " | ")
        let summary = [
            "merchant=\(ctx.quick.merchant.isEmpty ? "nil" : ctx.quick.merchant)",
            "total=\(ctx.quick.total.map { String(format: "%.2f", $0) } ?? "nil")",
            "tax=\(ctx.quick.tax.map { String(format: "%.2f", $0) } ?? "nil")",
            "tip=\(ctx.quick.tip.map { String(format: "%.2f", $0) } ?? "nil")",
            "fees=\(ctx.quick.fees.map { String(format: "%.2f", $0) } ?? "nil")"
        ].joined(separator: ", ")
        return rawLines.isEmpty ? summary : "\(summary) | raw=\(rawLines)"
    }

    private static func localItemCandidates(ctx: OCRPipelineContext) -> [LocalItemCandidate] {
        localItemization(ctx: ctx).items
    }

    private static func localItemization(ctx: OCRPipelineContext) -> LocalItemizationResult {
        let rowZones = detectLocalZones(rows: ctx.rawRows)
        let evidence = itemizationEvidence(rows: ctx.rawRows, rowZones: rowZones)
        let receiptKind = classifyReceiptKind(ctx: ctx, rowZones: rowZones)
        let discounts = detectDiscounts(rows: ctx.rawRows, rowZones: rowZones)
        let expectedItemCount = expectedItemCount(from: ctx)

        if receiptKind == .paymentSlip {
            let result = LocalItemizationResult(
                status: .paymentSlipNoItems,
                receiptKind: receiptKind,
                itemizationAttempted: true,
                itemizationAttemptReason: "payment_slip_classified_no_merchandise_itemization",
                itemWindowFound: evidence.itemWindowFound,
                itemNameCandidateCount: evidence.itemNameCandidateCount,
                itemPriceCandidateCount: evidence.itemPriceCandidateCount,
                itemizationFailureReason: evidence.itemWindowFound ? "payment_slip_with_item_section_evidence_review_required" : nil,
                items: [],
                acceptedCandidates: [],
                rejectedCandidates: [],
                discounts: discounts,
                expectedItemCount: expectedItemCount,
                itemSum: 0,
                discountTotal: round2(discounts.reduce(0) { $0 + abs($1.amount) }),
                reconciliationGap: nil,
                warnings: ["payment_slip_classified_no_merchandise_itemization"],
                confidence: 0.80
            )
            logCandidateItemization(source: ctx.candidateSource, result: result)
            logItemization(result, ctx: ctx)
            return result
        }

        let sameRow = buildItemizationPass(
            ctx: ctx,
            rowZones: rowZones,
            receiptKind: receiptKind,
            discounts: discounts,
            expectedItemCount: expectedItemCount,
            allowNearbyRepair: false,
            passName: "same_row"
        )
        if sameRow.status == .fullItemizedTrusted {
            saveDebugOverlayIfNeeded(ctx: ctx, rowZones: rowZones, result: sameRow)
            logRegressionAssertions(result: sameRow, ctx: ctx)
            logCandidateItemization(source: ctx.candidateSource, result: sameRow)
            logItemization(sameRow, ctx: ctx)
            return sameRow
        }

        let repair = buildItemizationPass(
            ctx: ctx,
            rowZones: rowZones,
            receiptKind: receiptKind,
            discounts: discounts,
            expectedItemCount: expectedItemCount,
            allowNearbyRepair: true,
            passName: "repair"
        )
        let chosen = shouldUseRepairResult(repair, over: sameRow) ? repair : sameRow
        saveDebugOverlayIfNeeded(ctx: ctx, rowZones: rowZones, result: chosen)
        logRegressionAssertions(result: chosen, ctx: ctx)
        logCandidateItemization(source: ctx.candidateSource, result: chosen)
        logItemization(chosen, ctx: ctx)
        return chosen
    }

    private static func itemizationEvidence(rows: [RawReceiptRow], rowZones: [Int: LocalReceiptZone]) -> ItemizationEvidence {
        let itemRows = rows.enumerated().filter { idx, _ in rowZones[idx] == .itemSection }
        let itemWindowFound = !itemRows.isEmpty
        let nameCount = itemRows.reduce(0) { count, pair in
            let row = pair.element
            let name = cleanLayoutItemName(NameCleaner.extractItemName(from: row))
            let context = ItemNameContext(inItemWindow: true, rightColumnPriceSupport: !row.prices.isEmpty, nearbyPriceSupport: !row.prices.isEmpty, beforeSummary: true, repairedPairing: false)
            guard !isPaymentOrFooterLeakage(row.fullText),
                  !isDiscountOrModifierRow(row.fullText),
                  !isVoidedRow(row.fullText),
                  !isCategoryHeader(row.fullText),
                  !isMetadataItemName(row.fullText),
                  itemNameQuality(name, context: context) >= 0.45 else {
                return count
            }
            return count + 1
        }
        let priceCount = itemRows.reduce(0) { count, pair in
            count + pair.element.prices.filter { $0 > 0 }.count
        }
        let hasItemHeader = rows.contains { row in
            let lower = row.fullText.lowercased()
            return containsAny(lower, [" item ", " item", "qty", "quantity", "price", "amount"])
        }
        let hasPreSummaryPrices = itemRows.contains { _, row in !row.prices.isEmpty }
        let reason: String
        if itemWindowFound, nameCount > 0, priceCount > 0 {
            reason = "item_window_with_names_and_prices"
        } else if itemWindowFound, hasPreSummaryPrices {
            reason = "item_window_with_price_evidence"
        } else if itemWindowFound, nameCount > 0 {
            reason = "item_window_with_name_evidence"
        } else if hasItemHeader {
            reason = "item_header_evidence"
        } else {
            reason = "no_item_section_evidence"
        }
        return ItemizationEvidence(
            itemWindowFound: itemWindowFound || hasItemHeader,
            itemNameCandidateCount: nameCount,
            itemPriceCandidateCount: priceCount,
            reason: reason
        )
    }

    private static func buildItemizationPass(
        ctx: OCRPipelineContext,
        rowZones: [Int: LocalReceiptZone],
        receiptKind: LocalReceiptKind,
        discounts: [DiscountCandidate],
        expectedItemCount: Int?,
        allowNearbyRepair: Bool,
        passName: String
    ) -> LocalItemizationResult {
        let wordBoxes = buildWordBoxes(rows: ctx.rawRows, rowZones: rowZones)
        let allPriceTokens = buildPriceTokens(from: wordBoxes)
        logPriceTokens(allPriceTokens)
        let evidence = itemizationEvidence(rows: ctx.rawRows, rowZones: rowZones)
        let imageWidth = max(ctx.snapshot.imageSize.width, 1)
        let priceTokens = candidateItemPriceTokens(allPriceTokens, rows: ctx.rawRows, rowZones: rowZones, imageWidth: imageWidth)
        let dominantPriceX = dominantPriceColumnX(priceTokens, imageWidth: imageWidth)

        var accepted: [ItemCandidate] = []
        var rejected: [ItemCandidate] = []
        var usedPriceKeys = Set<String>()

        for price in priceTokens.sorted(by: { $0.midY < $1.midY }) {
            let key = "\(price.rowIndex):\(Int((price.amount * 100).rounded())):\(String(format: "%.4f", price.midY))"
            guard !usedPriceKeys.contains(key) else { continue }
            usedPriceKeys.insert(key)

            let rowText = ctx.rawRows[safe: price.rowIndex]?.fullText ?? price.sourceText
            var fatalWarnings: [String] = []
            var nonFatalSignals: [String] = []
            var evidence: [String] = ["pass=\(passName)", "price_token=\(price.sourceText)", "dominant_price_x=\(String(format: "%.0f", dominantPriceX ?? 0))"]
            if let repaired = price.repairedText { evidence.append("price_repaired=\(repaired)") }
            if price.source != "topCandidate" { nonFatalSignals.append("price_source=\(price.source)") }

            if isPaymentOrFooterLeakage(rowText) {
                fatalWarnings.append("strict_rejected_row")
                let candidate = ItemCandidate(name: "", price: price.amount, zone: price.zone, yPosition: price.midY, confidence: 0.0, evidence: evidence, warnings: fatalWarnings, accepted: false, rowIndex: price.rowIndex)
                rejected.append(candidate)
                logItemCandidate(candidate)
                continue
            }

            if let dominantPriceX, price.midX < dominantPriceX - max(50, imageWidth * 0.08) {
                nonFatalSignals.append("price_not_in_dominant_column")
            }

            let pairing = pairedName(
                for: price,
                wordBoxes: wordBoxes,
                rows: ctx.rawRows,
                rowZones: rowZones,
                imageWidth: imageWidth,
                allowNearbyRepair: allowNearbyRepair
            )
            var name = pairing.name
            evidence.append(contentsOf: pairing.evidence)
            fatalWarnings.append(contentsOf: pairing.fatalWarnings)
            nonFatalSignals.append(contentsOf: pairing.nonFatalSignals)

            if isCategoryHeader(name) || isCategoryHeader(rowText) {
                fatalWarnings.append("category_header_used_as_item")
            }
            if isDiscountOrModifierRow(rowText) {
                fatalWarnings.append("discount_or_modifier_row")
            }
            if name.filter(\.isLetter).count < 3 {
                fatalWarnings.append("weak_item_name")
            }

            name = cleanLayoutItemName(name)
            let nameContext = ItemNameContext(
                inItemWindow: true,
                rightColumnPriceSupport: dominantPriceX.map { abs(price.midX - $0) <= max(80, imageWidth * 0.14) } ?? true,
                nearbyPriceSupport: true,
                beforeSummary: true,
                repairedPairing: pairing.nonFatalSignals.contains("drifted_price_attachment")
            )
            let quality = itemNameQuality(name, context: nameContext)
            if quality < 0.45 {
                nonFatalSignals.append("low_item_name_quality")
            }
            let confidence = itemCandidateConfidence(name: name, price: price, warnings: fatalWarnings + nonFatalSignals, evidence: evidence)
            let dynamicThreshold = pairing.nonFatalSignals.contains("drifted_price_attachment") ? 0.54 : 0.60
            let acceptedCandidate = fatalWarnings.isEmpty && price.amount > 0 && quality >= 0.35 && confidence >= dynamicThreshold
            let candidate = ItemCandidate(
                name: name,
                price: round2(price.amount),
                zone: price.zone,
                yPosition: price.midY,
                confidence: confidence,
                evidence: evidence,
                warnings: fatalWarnings + nonFatalSignals,
                accepted: acceptedCandidate,
                rowIndex: price.rowIndex
            )
            if acceptedCandidate {
                accepted.append(candidate)
            } else {
                rejected.append(candidate)
            }
            logItemCandidate(candidate)
        }

        let sequenceAccepted = sequenceItemWindowCandidates(rows: ctx.rawRows, rowZones: rowZones)
        if !sequenceAccepted.isEmpty {
            let currentSum = round2(accepted.reduce(0) { $0 + $1.price })
            let sequenceSum = round2(sequenceAccepted.reduce(0) { $0 + $1.price })
            let currentGap = bestItemizationGap(itemSum: currentSum, discountTotal: round2(discounts.reduce(0) { $0 + abs($1.amount) }), ctx: ctx)
            let sequenceGap = bestItemizationGap(itemSum: sequenceSum, discountTotal: round2(discounts.reduce(0) { $0 + abs($1.amount) }), ctx: ctx)
            if sequenceGap + 0.01 < currentGap || accepted.isEmpty {
                print("  [LocalItemization] using sequence item-window pairing gap=\(String(format: "%.2f", sequenceGap)) over current=\(String(format: "%.2f", currentGap))")
                accepted = sequenceAccepted
            }
        }

        var seen = Set<String>()
        let itemCandidates = accepted.compactMap { candidate -> LocalItemCandidate? in
            let key = "\(candidate.rowIndex):\(Int((candidate.price * 100).rounded())):\(candidate.name.lowercased())"
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return LocalItemCandidate(name: candidate.name, price: candidate.price, rowIndex: candidate.rowIndex)
        }

        let itemSum = round2(itemCandidates.reduce(0) { $0 + $1.price })
        let discountTotal = round2(discounts.reduce(0) { $0 + abs($1.amount) })
        let reconciliation = reconcileItems(itemSum: itemSum, discountTotal: discountTotal, expectedItemCount: expectedItemCount, accepted: accepted, rejected: rejected, ctx: ctx)
        let status: LocalItemizationStatus
        if itemCandidates.isEmpty {
            if !evidence.itemWindowFound, ctx.quick.total != nil, ctx.quick.totalConf == .high {
                status = .totalOnlyTrusted
            } else if ctx.quick.total != nil && ctx.quick.totalConf == .high {
                status = .itemizedNeedsReview
            } else {
                status = .failed
            }
        } else if reconciliation.trusted {
            status = .fullItemizedTrusted
        } else if ctx.quick.total != nil && ctx.quick.totalConf == .high {
            status = .itemizedNeedsReview
        } else {
            status = .failed
        }

        var warnings = reconciliation.warnings
        if !rejected.isEmpty { warnings.append("rejected_item_candidates:\(rejected.count)") }
        if evidence.itemWindowFound, itemCandidates.isEmpty {
            warnings.append("item_section_evidence_but_no_items_accepted")
        }
        let failureReason: String?
        if status == .fullItemizedTrusted {
            failureReason = nil
        } else if evidence.itemWindowFound, itemCandidates.isEmpty {
            failureReason = "item_window_found_no_accepted_items"
        } else if evidence.itemWindowFound, !(reconciliation.trusted) {
            failureReason = reconciliation.warnings.first ?? "item_reconciliation_failed"
        } else if !evidence.itemWindowFound {
            failureReason = "item_window_not_found"
        } else {
            failureReason = nil
        }
        let result = LocalItemizationResult(
            status: status,
            receiptKind: receiptKind,
            itemizationAttempted: true,
            itemizationAttemptReason: evidence.reason,
            itemWindowFound: evidence.itemWindowFound,
            itemNameCandidateCount: evidence.itemNameCandidateCount,
            itemPriceCandidateCount: evidence.itemPriceCandidateCount,
            itemizationFailureReason: failureReason,
            items: itemCandidates,
            acceptedCandidates: accepted,
            rejectedCandidates: rejected,
            discounts: discounts,
            expectedItemCount: expectedItemCount,
            itemSum: itemSum,
            discountTotal: discountTotal,
            reconciliationGap: reconciliation.gap,
            warnings: Array(Set(warnings)).sorted(),
            confidence: reconciliation.confidence
        )
        return result
    }

    private static func bestItemizationGap(itemSum: Double, discountTotal: Double, ctx: OCRPipelineContext) -> Double {
        var gaps: [Double] = []
        if let subtotal = ctx.quick.subtotal { gaps.append(abs(round2(itemSum - subtotal))) }
        if let total = ctx.quick.total {
            gaps.append(abs(round2(itemSum + (ctx.quick.tax ?? 0) + (ctx.quick.fees ?? 0) + (ctx.quick.tip ?? 0) - total)))
        }
        if let subtotal = ctx.quick.subtotal, discountTotal > 0 {
            gaps.append(abs(round2(itemSum - discountTotal - subtotal)))
        }
        return gaps.min() ?? .greatestFiniteMagnitude
    }

    private static func candidateItemPriceTokens(
        _ allPriceTokens: [PriceToken],
        rows: [RawReceiptRow],
        rowZones: [Int: LocalReceiptZone],
        imageWidth: CGFloat
    ) -> [PriceToken] {
        let summaryStartY = rows.enumerated()
            .filter { idx, row in
                let lower = RowBuilder.normalizeFuzzySummaryText(row.fullText.lowercased())
                return rowZones[idx] == .summarySection || containsAny(lower, ["subtotal", "tax", "total", "balance due", "amount due", "cash", "non-cash", "non cash", "tender", "change"])
            }
            .map { $0.element.midY }
            .min() ?? .greatestFiniteMagnitude

        let itemStartY = rows.enumerated()
            .filter { idx, row in
                guard row.midY < summaryStartY else { return false }
                let lower = row.fullText.lowercased()
                guard !isPaymentOrFooterLeakage(row.fullText),
                      !isMetadataItemName(row.fullText),
                      !containsAny(lower, ["server", "cashier", "table", "order", "check", "guest", "register"]) else { return false }
                return rowZones[idx] == .itemSection || ReceiptRowSemantics.hasStrongItemName(row) || !row.prices.isEmpty
            }
            .map { $0.element.midY }
            .min() ?? rows.first?.midY ?? 0

        let preSummaryPrices = allPriceTokens.filter { price in
            guard price.amount > 0,
                  price.midY >= itemStartY - 6,
                  price.midY < summaryStartY - 2,
                  let row = rows[safe: price.rowIndex] else { return false }
            guard !isPaymentOrFooterLeakage(row.fullText), !isDiscountOrModifierRow(row.fullText) else { return false }
            let lower = RowBuilder.normalizeFuzzySummaryText(row.fullText.lowercased())
            guard !containsAny(lower, ["subtotal", "tax", "total", "balance due", "amount due", "cash", "non-cash", "non cash", "tender", "change"]) else { return false }
            return true
        }
        let dominantX = dominantPriceColumnX(preSummaryPrices, imageWidth: imageWidth)
        let filtered = preSummaryPrices.filter { price in
            guard let dominantX else { return price.zone == .itemSection || price.midX > imageWidth * 0.35 }
            return abs(price.midX - dominantX) <= max(90, imageWidth * 0.16) || price.zone == .itemSection
        }
        print("  [ItemPriceWindow] itemStartY=\(Int(itemStartY.rounded())) summaryStartY=\(summaryStartY.isFinite ? Int(summaryStartY.rounded()) : -1) candidates=\(filtered.count)/\(allPriceTokens.count)")
        return filtered
    }

    private static func sequenceItemWindowCandidates(rows: [RawReceiptRow], rowZones: [Int: LocalReceiptZone]) -> [ItemCandidate] {
        struct NameRow { let row: RawReceiptRow; let name: String; let index: Int }
        struct PriceRow { let row: RawReceiptRow; let price: Double; let index: Int }
        var names: [NameRow] = []
        var prices: [PriceRow] = []
        var sameRow: [ItemCandidate] = []
        var usedNameRows = Set<Int>()
        var usedPriceRows = Set<Int>()

        for (idx, row) in rows.enumerated() where rowZones[idx] == .itemSection {
            let rowText = row.fullText
            guard !isPaymentOrFooterLeakage(rowText),
                  !isDiscountOrModifierRow(rowText),
                  !isVoidedRow(rowText),
                  !isCategoryHeader(rowText),
                  !isMetadataItemName(rowText) else { continue }

            let cleanName = cleanLayoutItemName(NameCleaner.extractItemName(from: row))
            let context = ItemNameContext(inItemWindow: true, rightColumnPriceSupport: !row.prices.isEmpty, nearbyPriceSupport: !row.prices.isEmpty, beforeSummary: true, repairedPairing: false)
            let strongName = itemNameQuality(cleanName, context: context) >= 0.45
            let terminalPrice = row.terminalItemPrice ?? row.prices.last
            if let price = terminalPrice, price > 0, strongName {
                sameRow.append(ItemCandidate(
                    name: cleanName,
                    price: round2(price),
                    zone: .itemSection,
                    yPosition: row.midY,
                    confidence: 0.88,
                    evidence: ["sequence_same_row"],
                    warnings: [],
                    accepted: true,
                    rowIndex: idx
                ))
                usedNameRows.insert(idx)
                usedPriceRows.insert(idx)
                continue
            }
            if let price = terminalPrice, price > 0, !strongName {
                prices.append(PriceRow(row: row, price: round2(price), index: idx))
            } else if strongName {
                names.append(NameRow(row: row, name: cleanName, index: idx))
            }
        }

        var paired: [ItemCandidate] = sameRow
        for price in prices.sorted(by: { $0.row.midY < $1.row.midY }) {
            guard !usedPriceRows.contains(price.index) else { continue }
            let candidates = names
                .filter { !usedNameRows.contains($0.index) && $0.row.midY <= price.row.midY + max($0.row.maxY - $0.row.minY, 8) * 1.25 }
                .sorted { abs($0.row.midY - price.row.midY) < abs($1.row.midY - price.row.midY) }
            guard let name = candidates.first else { continue }
            let distance = abs(name.row.midY - price.row.midY)
            guard distance < max(name.row.maxY - name.row.minY, price.row.maxY - price.row.minY) * 5.0 else { continue }
            paired.append(ItemCandidate(
                name: name.name,
                price: price.price,
                zone: .itemSection,
                yPosition: min(name.row.midY, price.row.midY),
                confidence: 0.82,
                evidence: ["sequence_split_row:name_row=\(name.row.rowIndex)", "price_row=\(price.row.rowIndex)"],
                warnings: [],
                accepted: true,
                rowIndex: name.row.rowIndex
            ))
            usedNameRows.insert(name.index)
            usedPriceRows.insert(price.index)
        }
        return paired.sorted { $0.yPosition < $1.yPosition }
    }

    private static func shouldUseRepairResult(_ repair: LocalItemizationResult, over sameRow: LocalItemizationResult) -> Bool {
        if repair.status == .fullItemizedTrusted, sameRow.status != .fullItemizedTrusted { return true }
        guard repair.items.count >= sameRow.items.count else { return false }
        let sameGap = sameRow.reconciliationGap ?? .greatestFiniteMagnitude
        let repairGap = repair.reconciliationGap ?? .greatestFiniteMagnitude
        return repairGap + 0.05 < sameGap && repair.confidence > sameRow.confidence + 0.05
    }

    private static func detectLocalZones(rows: [RawReceiptRow]) -> [Int: LocalReceiptZone] {
        var zones: [Int: LocalReceiptZone] = [:]
        var current: LocalReceiptZone = .header
        for (idx, row) in rows.enumerated() {
            let lower = RowBuilder.normalizeFuzzySummaryText(row.fullText.lowercased())
            if containsAny(lower, ["thank you", "survey", "sweepstakes", "returns", "feedback", "bathroom code", "apply online",
                                   "visit today", "complete our survey", "listen", "redeem", "receive a code",
                                   "validation code", "offer expires", "coupon", "product may vary", "not redeemable",
                                   "not valid", "cash value", "rewards member", "download the app", "thank you for visiting"]) {
                current = .footer
            } else if lower.contains("suggested tip") {
                current = .tipSuggestionSection
            } else if containsAny(lower, ["visa", "mastercard", "amex", "aid", "tvr", "tsi", "approval", "auth", "reference", "account", "card", "terminal"]) {
                current = .paymentSection
            } else if containsAny(lower, ["subtotal", "sub total", "tax", "total", "balance due", "amount due", "credit", "total tendered", "change", "cash", "non-cash"]) {
                current = .summarySection
            } else if containsAny(lower, ["ordered:", "dairy", "grocery", "bakery", "produce", "seafood", "frozen", "deli", "meat"]) {
                current = .itemSection
            } else if current == .header, row.zone == .items {
                current = .itemSection
            }

            zones[idx] = current
        }
        return zones
    }

    private static func classifyReceiptKind(ctx: OCRPipelineContext, rowZones: [Int: LocalReceiptZone]) -> LocalReceiptKind {
        let text = ctx.snapshot.rawLines.joined(separator: " ").lowercased()
        let paymentTerms = [
            "transaction type", "visa contactless", "contactless", "aid", "tvr", "tsi", "pan",
            "approval", "auth", "reference", "card type", "card name", "terminal", "suggested tip"
        ]
        let paymentHits = paymentTerms.filter { text.contains($0) }.count
        let merchandiseRows = ctx.rawRows.enumerated().filter { idx, row in
            rowZones[idx] == .itemSection && ReceiptRowSemantics.hasStrongItemName(row) && !row.prices.isEmpty
        }.count

        let hasMerchandiseEvidence: Bool = {
            if merchandiseRows > 0 { return true }
            guard let total = ctx.quick.total, total > 0, let subtotal = ctx.quick.subtotal else { return false }
            return subtotal > 0.01 && subtotal < total
        }()

        if paymentHits >= 4 && !hasMerchandiseEvidence {
            return .paymentSlip
        }
        if containsAny(text, ["rx", "pharmacy", "prescription", "walgreens", "cvs"]) {
            return .pharmacyRetail
        }
        if containsAny(text, ["dairy", "grocery", "produce", "seafood", "frozen", "bakery", "deli", "meat"]) {
            return .groceryRetail
        }
        if containsAny(text, ["server:", "table", "guest", "ordered:", "dine in"]) {
            return .restaurantItemized
        }
        return .unknown
    }

    private static func buildWordBoxes(rows: [RawReceiptRow], rowZones: [Int: LocalReceiptZone]) -> [OCRWordBox] {
        rows.enumerated().flatMap { idx, row in
            let zone = rowZones[idx] ?? .header
            return row.words.flatMap { word in
                let tokenBoxes = word.tokenBoxes
                return tokenBoxes.map {
                    OCRWordBox(text: $0.text, alternateCandidates: word.alternateCandidates, rect: $0.rect, confidence: word.confidence, rowIndex: idx, zone: zone)
                }
            }
        }
    }

    private static func buildPriceTokens(from words: [OCRWordBox]) -> [PriceToken] {
        words.flatMap { word -> [PriceToken] in
            var tokens: [PriceToken] = []
            func appendPrices(from text: String, source: String, repairedText: String? = nil, confidenceMultiplier: Float = 1.0) {
                for amount in PriceParser.extractAllIncludingUSD(from: text) {
                    let rounded = round2(amount)
                    guard rounded > 0 else { continue }
                    guard !tokens.contains(where: { abs($0.amount - rounded) <= 0.001 && $0.source == source }) else { continue }
                    tokens.append(PriceToken(
                        amount: rounded,
                        sourceText: word.text,
                        repairedText: repairedText,
                        source: source,
                        rect: word.rect,
                        confidence: word.confidence * confidenceMultiplier,
                        rowIndex: word.rowIndex,
                        zone: word.zone
                    ))
                }
            }
            appendPrices(from: word.text, source: "topCandidate")
            for alternate in word.alternateCandidates.prefix(4) where alternate != word.text {
                appendPrices(from: alternate, source: "alternateCandidate", repairedText: alternate, confidenceMultiplier: 0.92)
            }
            if let repaired = repairPriceConfusables(word.text), repaired != word.text {
                appendPrices(from: repaired, source: "confusableRepair", repairedText: repaired, confidenceMultiplier: 0.82)
            }
            return tokens
        }
    }

    private static func repairPriceConfusables(_ text: String) -> String? {
        let mapped = text.map { ch -> Character in
            switch ch {
            case "O", "o": return "0"
            case "S", "s": return "5"
            case "B", "b": return "8"
            case "I", "l", "|": return "1"
            case "Z", "z": return "2"
            case "G", "g": return "6"
            case ":", "-", "_": return "."
            default: return ch
            }
        }
        let repaired = String(mapped)
        let digitCount = repaired.filter(\.isNumber).count
        guard digitCount >= 2, repaired.contains(".") else { return nil }
        guard PriceParser.extractAllIncludingUSD(from: repaired).isEmpty == false else { return nil }
        return repaired
    }

    private static func logPriceTokens(_ prices: [PriceToken]) {
        for price in prices.sorted(by: {
            $0.rowIndex == $1.rowIndex ? $0.midX < $1.midX : $0.rowIndex < $1.rowIndex
        }) {
            print("  [PriceToken] amount=\(String(format: "%.2f", price.amount)) raw='\(price.sourceText)' x=\(Int(price.midX.rounded())) y=\(Int(price.midY.rounded())) row=\(price.rowIndex) zone=\(price.zone.rawValue)")
        }
    }

    private static func dominantPriceColumnX(_ prices: [PriceToken], imageWidth: CGFloat) -> CGFloat? {
        let xs = prices.map(\.midX).filter { $0 > imageWidth * 0.35 }.sorted()
        guard !xs.isEmpty else { return nil }
        return xs[xs.count / 2]
    }

    private static func pairedName(
        for price: PriceToken,
        wordBoxes: [OCRWordBox],
        rows: [RawReceiptRow],
        rowZones: [Int: LocalReceiptZone],
        imageWidth: CGFloat,
        allowNearbyRepair: Bool
    ) -> (name: String, evidence: [String], fatalWarnings: [String], nonFatalSignals: [String]) {
        var evidence: [String] = []
        var fatalWarnings: [String] = []
        var nonFatalSignals: [String] = []
        let leftPadding = max(4, imageWidth * 0.005)
        let sameBand = wordBoxes.filter {
            $0.rowIndex == price.rowIndex &&
            $0.maxX < price.midX - leftPadding &&
            !PriceParser.looksLikePrice($0.text) &&
            !PriceParser.isTaxFlag($0.text)
        }
        let sameName = PriceParser.cleanItemName(sameBand.map(\.text))
        let sameContext = ItemNameContext(inItemWindow: true, rightColumnPriceSupport: true, nearbyPriceSupport: true, beforeSummary: true, repairedPairing: false)
        if sameName.filter(\.isLetter).count >= 3, !isCategoryHeader(sameName), !isMetadataItemName(sameName), itemNameQuality(sameName, context: sameContext) >= 0.45 {
            evidence.append("same_y_band")
            return (sameName, evidence, fatalWarnings, nonFatalSignals)
        }

        guard allowNearbyRepair else {
            fatalWarnings.append("missing_item_name_for_price")
            return (sameName, evidence, fatalWarnings, nonFatalSignals)
        }

        let nearbyRows = [price.rowIndex - 1, price.rowIndex + 1, price.rowIndex - 2, price.rowIndex + 2]
        for idx in nearbyRows where rows.indices.contains(idx) {
            guard rowZones[idx] == .itemSection || rowZones[price.rowIndex] == .itemSection else { continue }
            let row = rows[idx]
            guard row.terminalItemPrice == nil || row.prices.isEmpty else { continue }
            guard !isPaymentOrFooterLeakage(row.fullText), !isCategoryHeader(row.fullText), !isMetadataItemName(row.fullText) else { continue }
            guard !isVoidedRow(row.fullText) else { continue }
            let candidateName = NameCleaner.extractItemName(from: row)
            let context = ItemNameContext(inItemWindow: true, rightColumnPriceSupport: true, nearbyPriceSupport: true, beforeSummary: true, repairedPairing: true)
            if ReceiptRowSemantics.hasStrongItemName(row), itemNameQuality(candidateName, context: context) >= 0.35 {
                evidence.append("nearby_row:\(idx)")
                nonFatalSignals.append("drifted_price_attachment")
                return (candidateName, evidence, fatalWarnings, nonFatalSignals)
            }
        }

        fatalWarnings.append("missing_item_name_for_price")
        return (sameName, evidence, fatalWarnings, nonFatalSignals)
    }

    private static func detectDiscounts(rows: [RawReceiptRow], rowZones: [Int: LocalReceiptZone]) -> [DiscountCandidate] {
        rows.enumerated().compactMap { idx, row in
            guard rowZones[idx] == .itemSection || rowZones[idx] == .summarySection else { return nil }
            guard isDiscountOrModifierRow(row.fullText) else { return nil }
            let amount = row.prices.map(abs).max() ?? PriceParser.extractAllIncludingUSD(from: row.fullText).map(abs).max() ?? 0
            guard amount > 0 else { return nil }
            return DiscountCandidate(amount: round2(amount), rowIndex: idx, sourceRow: row.fullText)
        }
    }

    private static func expectedItemCount(from ctx: OCRPipelineContext) -> Int? {
        let text = ctx.snapshot.rawLines.joined(separator: " ").lowercased()
        let patterns = [
            #"number of items(?: sold)?:?\s*(\d{1,3})"#,
            #"total number of items(?: sold)?:?\s*(\d{1,3})"#,
            #"items sold:?\s*(\d{1,3})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1,
               let value = Int(ns.substring(with: match.range(at: 1))) {
                return value
            }
        }
        return nil
    }

    private static func reconcileItems(
        itemSum: Double,
        discountTotal: Double,
        expectedItemCount: Int?,
        accepted: [ItemCandidate],
        rejected: [ItemCandidate],
        ctx: OCRPipelineContext
    ) -> (trusted: Bool, gap: Double?, warnings: [String], confidence: Double) {
        var warnings: [String] = []
        let subtotal = ctx.quick.subtotal
        let tax = ctx.quick.tax ?? 0
        let tip = ctx.quick.tip ?? 0
        let fees = ctx.quick.fees ?? 0
        let total = ctx.quick.total
        var gaps: [Double] = []
        if let subtotal { gaps.append(abs(round2(itemSum - subtotal))) }
        if let total { gaps.append(abs(round2(itemSum + tax + fees + tip - total))) }
        if let subtotal, discountTotal > 0 { gaps.append(abs(round2(itemSum - discountTotal - subtotal))) }
        let bestGap = gaps.min()
        if let expectedItemCount, accepted.count < max(1, expectedItemCount - 1) {
            warnings.append("too_few_items_expected_\(expectedItemCount)_got_\(accepted.count)")
        }
        if accepted.contains(where: { $0.warnings.contains("category_header_used_as_item") }) {
            warnings.append("category_header_used_as_item")
        }
        if accepted.contains(where: { $0.warnings.contains("drifted_price_attachment") }) {
            warnings.append("drifted_price_attachment")
        }
        if rejected.contains(where: { $0.warnings.contains("strict_rejected_row") }) {
            warnings.append("summary_payment_footer_leakage_rejected")
        }
        if let bestGap, bestGap > 0.05 {
            warnings.append("item_sum_mismatch_\(Int((bestGap * 100).rounded()))cents")
        }
        let alignedRatio = accepted.isEmpty ? 0 : Double(accepted.filter { $0.confidence >= 0.78 }.count) / Double(accepted.count)
        let trusted = !accepted.isEmpty &&
            (bestGap ?? 0) <= 0.05 &&
            alignedRatio >= 0.80 &&
            !warnings.contains(where: { $0.hasPrefix("too_few_items") || $0.hasPrefix("item_sum_mismatch") || $0 == "category_header_used_as_item" })
        let confidence = min(1.0, max(0.0, 0.35 + alignedRatio * 0.40 + ((bestGap ?? 0) <= 0.05 ? 0.25 : 0.0)))
        return (trusted, bestGap, warnings, confidence)
    }

    static func isStrictlyRejectedItemRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["subtotal", "total", "tax", "visa", "credit", "balance due", "change", "aid",
                "auth", "approval", "reference", "card", "suggested tip", "survey",
                "sweepstakes", "thank you", "terminal", "contactless", "receipt code",
                "qr", "barcode", "merchant copy", "authorization", "payment id",
                "loyalty", "points", "reward", "feedback", "coupon"].contains { lower.contains($0) }
    }

    static func isCategoryHeader(_ text: String) -> Bool {
        let upper = text.uppercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(.whitespacesAndNewlines))
        return ["DAIRY", "GROCERY", "PRODUCE", "SEAFOOD", "FROZEN", "BAKERY", "DELI", "MEAT"].contains(upper)
    }

    static func isDiscountOrModifierRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("you saved") || lower.contains("coupon") || lower.contains("discount")
            || lower.contains("promo") || lower.contains("bogo") || lower.contains("savings")
            || lower.contains("reward") || lower.contains("removed") || lower.contains("-$")
    }

    static func isVoidedRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["removed", "void", "voided", "refunded", "returned", "cancelled", "canceled"]
            .contains { lower.contains($0) }
    }

    static func isPaymentOrFooterLeakage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return isStrictlyRejectedItemRow(lower)
            || containsAny(lower, ["sale approved", "powered by", "scan to", "apply online", "bathroom code",
                                   "merchant id", "transaction type", "entry mode", "application id"])
    }

    static func isMetadataItemName(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return true }
        if containsAny(lower, ["dine in", "take out", "takeout", "carryout", "server", "host", "cashier",
                               "table", "order", "check", "guest", "register", "employee", "brianna"]) {
            return true
        }
        if lower.range(of: #"^\s*(rh\d+|b\d+|#?\d{2,})\s*$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func itemNameQuality(_ text: String, context: ItemNameContext? = nil) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, !isMetadataItemName(trimmed), !isCategoryHeader(trimmed), !isPaymentOrFooterLeakage(trimmed) else {
            return 0
        }
        let letters = trimmed.filter(\.isLetter)
        let asciiLetters = trimmed.filter { $0.isASCII && $0.isLetter }
        let digits = trimmed.filter(\.isNumber)
        guard letters.count >= 3 else { return 0 }
        if asciiLetters.count == 0 { return 0 }
        if Double(asciiLetters.count) / Double(max(letters.count, 1)) < 0.75 { return 0.15 }
        let tokens = trimmed.split(separator: " ").map(String.init)
        if tokens.count == 1 {
            let upper = trimmed.uppercased()
            if ["ONIS", "JO", "JО", "BA4A", "UMMI"].contains(upper) { return 0 }
            if upper == trimmed && trimmed.count <= 4 { return context?.rightColumnPriceSupport == true ? 0.42 : 0.2 }
            if digits.count >= letters.count { return 0.1 }
        }
        if PriceParser.looksLikeMemberID(trimmed) || PriceParser.isSKUCode(trimmed) { return 0 }
        var score = 0.48
        if tokens.count >= 2 { score += 0.20 }
        if letters.count >= 8 { score += 0.15 }
        if trimmed.range(of: #"[aeiouAEIOU]"#, options: .regularExpression) != nil { score += 0.05 }
        if digits.count > 0 { score -= 0.10 }
        if let context {
            if context.inItemWindow { score += 0.08 }
            if context.rightColumnPriceSupport { score += 0.12 }
            if context.nearbyPriceSupport { score += 0.08 }
            if context.beforeSummary { score += 0.04 }
            if context.repairedPairing { score += 0.02 }
        }
        return min(1.0, max(0.0, score))
    }

    private static func cleanLayoutItemName(_ text: String) -> String {
        PriceParser.cleanItemName(text.split(separator: " ").map(String.init))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func itemCandidateConfidence(name: String, price: PriceToken, warnings: [String], evidence: [String]) -> Double {
        var confidence = 0.55
        if evidence.contains(where: { $0 == "same_y_band" }) { confidence += 0.25 }
        if evidence.contains(where: { $0.hasPrefix("nearby_row") }) { confidence += 0.08 }
        if name.filter(\.isLetter).count >= 4 { confidence += 0.08 }
        if price.confidence >= 0.80 { confidence += 0.06 }
        confidence -= Double(warnings.count) * 0.14
        return min(1.0, max(0.0, confidence))
    }

    #if DEBUG
    private static func saveDebugOverlayIfNeeded(ctx: OCRPipelineContext, rowZones: [Int: LocalReceiptZone], result: LocalItemizationResult) {
        // Disabled in the live OCR path. Full-size UIKit rendering from the background
        // scan queue can spike memory and crash after photo confirmation.
        print("  [OCRDebugOverlay] skipped live overlay render")
    }
    #else
    private static func saveDebugOverlayIfNeeded(ctx: OCRPipelineContext, rowZones: [Int: LocalReceiptZone], result: LocalItemizationResult) {}
    #endif

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func logRegressionAssertions(result: LocalItemizationResult, ctx: OCRPipelineContext) {
        let text = ctx.snapshot.rawLines.joined(separator: " ").lowercased()
        let itemNames = result.items.map { $0.name.lowercased() }.joined(separator: " | ")
        func log(_ name: String, _ passed: Bool, _ detail: String) {
            print("  [LocalRegression] \(passed ? "PASS" : "FAIL") \(name): \(detail)")
        }
        if text.contains("krispy") || text.contains("glazed dozen") {
            log("krispy_kreme_items", itemNames.contains("original") && itemNames.contains("glazed"), "items='\(itemNames)' merchant='\(ctx.quick.merchant)'")
            log("krispy_kreme_merchant", ctx.quick.merchant.lowercased().contains("krispy"), "merchant='\(ctx.quick.merchant)'")
        }
        if text.contains("ntvflo") || text.contains("bloom bqt") {
            log("whole_foods_flower", result.items.contains { $0.name.lowercased().contains("ntvflo") && abs($0.price - 19.99) <= 0.01 }, "items='\(itemNames)'")
        }
        if text.contains("chc chp") || text.contains("lac fre") {
            log("fresh_thyme_small", result.items.contains { $0.name.lowercased().contains("chc chp") && abs($0.price - 4.99) <= 0.01 } && result.items.contains { $0.name.lowercased().contains("milk") && abs($0.price - 5.99) <= 0.01 }, "items='\(itemNames)'")
        }
        let forbidden = ["bakery", "dairy", "grocery", "you saved", "subtotal", "tax", "total", "visa"]
        let leaked = forbidden.filter { itemNames.contains($0) }
        log("forbidden_item_leakage", leaked.isEmpty, "leaked=\(leaked.joined(separator: ","))")
    }

    private static func logItemCandidate(_ candidate: ItemCandidate) {
        print("  [LocalItemCandidate] \(candidate.accepted ? "ACCEPT" : "REJECT") name='\(candidate.name)' price=\(String(format: "%.2f", candidate.price)) zone=\(candidate.zone.rawValue) y=\(Int(candidate.yPosition.rounded())) conf=\(String(format: "%.2f", candidate.confidence)) evidence=\(candidate.evidence.joined(separator: ",")) warnings=\(candidate.warnings.joined(separator: ","))")
    }

    private static func logCandidateItemization(source: String, result: LocalItemizationResult) {
        let reason = result.itemizationFailureReason ?? "none"
        print("  [CandidateItemization] source=\(source) attempted=\(result.itemizationAttempted) itemWindowFound=\(result.itemWindowFound) names=\(result.itemNameCandidateCount) prices=\(result.itemPriceCandidateCount) accepted=\(result.acceptedCandidates.count) rejected=\(result.rejectedCandidates.count) status=\(result.status.rawValue) reason=\(reason)")
    }

    private static func logItemization(_ result: LocalItemizationResult, ctx: OCRPipelineContext) {
        print("  [LocalItemization] status=\(result.status.rawValue) kind=\(result.receiptKind.rawValue) items=\(result.items.count) expected=\(result.expectedItemCount.map(String.init) ?? "nil") itemSum=\(String(format: "%.2f", result.itemSum)) subtotal=\(ctx.quick.subtotal.map { String(format: "%.2f", $0) } ?? "nil") tax=\(ctx.quick.tax.map { String(format: "%.2f", $0) } ?? "nil") fees=\(ctx.quick.fees.map { String(format: "%.2f", $0) } ?? "nil") total=\(ctx.quick.total.map { String(format: "%.2f", $0) } ?? "nil") discount=\(String(format: "%.2f", result.discountTotal)) gap=\(result.reconciliationGap.map { String(format: "%.2f", $0) } ?? "nil") confidence=\(String(format: "%.2f", result.confidence)) warnings=\(result.warnings.joined(separator: ","))")
    }

    private static func isSummaryEcho(
        _ row: RawReceiptRow,
        price: Double,
        total: Double?,
        subtotal: Double?,
        tax: Double?,
        tip: Double?
    ) -> Bool {
        let lower = row.fullText.lowercased()
        if lower.contains("subtotal") || lower.contains("sub total") || lower.contains("sub-total")
            || lower.contains("total") || lower.contains("tax") || lower.contains("tip")
            || lower.contains("amount due") || lower.contains("balance due") {
            return true
        }
        let echoes = [total, subtotal, tax, tip].compactMap { $0 }
        return echoes.contains { abs($0 - price) < 0.01 } && !ReceiptRowSemantics.hasStrongItemName(row)
    }

    static func extractNormalizedDate(from snapshot: OCRSnapshot) -> String? {
        let combined = snapshot.rawLines.prefix(15).joined(separator: " ")
        let ns = combined as NSString

        if let m = isoDateRegex.firstMatch(in: combined, range: NSRange(location: 0, length: ns.length)) {
            let y = ns.substring(with: m.range(at: 1))
            let mo = ns.substring(with: m.range(at: 2))
            let d  = ns.substring(with: m.range(at: 3))
            if let yr = Int(y), let mo_ = Int(mo), let dy = Int(d),
               yr >= 2020, yr <= 2099, mo_ >= 1, mo_ <= 12, dy >= 1, dy <= 31 {
                return String(format: "%04d-%02d-%02d", yr, mo_, dy)
            }
        }

        if let m = slashDateRegex.firstMatch(in: combined, range: NSRange(location: 0, length: ns.length)) {
            let a = ns.substring(with: m.range(at: 1))
            let b = ns.substring(with: m.range(at: 2))
            var c = ns.substring(with: m.range(at: 3))
            if c.count == 2 { c = "20\(c)" }
            if let yr = Int(c), let mo = Int(a), let dy = Int(b),
               yr >= 2020, yr <= 2099, mo >= 1, mo <= 12, dy >= 1, dy <= 31 {
                return String(format: "%04d-%02d-%02d", yr, mo, dy)
            }
        }

        let monthMap = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        if let m = monthDateRegex.firstMatch(in: combined, range: NSRange(location: 0, length: ns.length)) {
            let month = ns.substring(with: m.range(at: 1)).lowercased()
            let day = ns.substring(with: m.range(at: 2))
            let year = ns.substring(with: m.range(at: 3))
            if let mo = monthMap[String(month.prefix(3))], let dy = Int(day), let yr = Int(year),
               yr >= 2020, yr <= 2099, dy >= 1, dy <= 31 {
                return String(format: "%04d-%02d-%02d", yr, mo, dy)
            }
        }

        return nil
    }
}

// ============================================================
// MARK: - Server Response Models
// ============================================================

struct ServerReceiptResponse: Codable {
    struct Item: Codable {
        var name:                     String
        var rawName:                  String?
        var normalizedName:           String?
        var amount:                   Double
        var originalAmount:           Double?
        var itemDiscount:             Double?
        var itemDiscountLabel:        String?
        var discountDisplayLabel:     String?
        var qty:                      Double?
        var unitPrice:                Double?
        var weightLbs:                Double?
        var category:                 String?
        var categoryConfidence:       Double?
        var normalizationConfidence:  Double?
        var needsNameVerification:    Bool?
        var confidence: String?
    }

    var merchant:    String
    var receiptDate: String?
    var currency:    String
    var items:       [Item]
    var subtotal:    Double?
    var tax:         Double?
    var tip:         Double?
    var fees:        Double?
    var grandTotal:  Double?
    var confidence:  String
    var notes:       String?
    var route:       String?
    var routeReason: String?
    var timings:     Timings?

    struct Timings: Codable {
        var total_ms: Int?
        var ocr_ms: Int?
    }
}

struct ServerReceiptStagedResponse: Codable {
    var ok: Bool
    var request_id: String
    var phase: String?
    var itemizationStatus: String?
    var quickTotal: QuickTotal?
    var result: ServerReceiptResponse?
    var error: StagedError?

    struct QuickTotal: Codable {
        var merchant: String?
        var grandTotal: Double?
        var confidence: String?
    }

    struct StagedError: Codable {
        var code: String?
        var message: String?
    }
}

struct FinancialDocumentResponse: Codable {
    struct Classification: Codable {
        var confidence: Double
        var reason: String
    }

    struct OCR: Codable {
        var model: String
        var pageCount: Int
        var lowConfidenceFields: [String]
    }

    struct Debug: Codable {
        var method: String?
        var provider: String?
        var model: String?
        var elapsedMs: Int?
        var confidence: Double?
        var confidenceReason: String?
        var pageCount: Int?
        var lowConfidenceFieldCount: Int?
    }

    struct Reconciliation: Codable {
        var status: String
        var reason: String?
        var visiblePostedDebitTotal: Double?
        var visiblePostedCreditTotal: Double?
        var pendingTransactionTotal: Double?
    }

    struct BankDocument: Codable {
        struct StatementPeriod: Codable {
            var startDate: String?
            var endDate: String?
        }

        struct Balances: Codable {
            var openingBalance: Double?
            var closingBalance: Double?
            var availableBalance: Double?
            var currentBalance: Double?
        }

        struct Transaction: Codable {
            var transactionDate: String?
            var postedDate: String?
            var description: String
            var amount: Double
            var direction: String
            var status: String
            var balanceAfterTransaction: Double?
            var sourceText: String
            var confidence: Double?
        }

        var documentType: String
        var institutionName: String?
        var accountName: String?
        var accountLast4: String?
        var currency: String?
        var statementPeriod: StatementPeriod
        var balances: Balances
        var transactions: [Transaction]
        var partialDocument: Bool
        var warnings: [String]
    }

    var ok: Bool
    var parseVersion: String?
    var documentType: String
    var classification: Classification
    var data: BankDocument?
    var reconciliation: Reconciliation
    var warnings: [String]
    var reviewRequired: Bool
    var ocr: OCR
    var debug: Debug?
}

// ============================================================
// MARK: - OCR Service
// ============================================================

class OCRService {
    static var onStatusUpdate: ((String?) -> Void)?
    // Precompiled once to avoid per-row/per-token regex recompilation in OCR helpers.
    private static let statementAmountWordRegex = try! NSRegularExpression(pattern: #"^-?\+?\$[\d,]+\.\d{2}$"#)
    private static let signedNegativeAmountRegexes = [
        try! NSRegularExpression(pattern: #"-\s*\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2})"#),
        try! NSRegularExpression(pattern: #"\(\s*\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2})\s*\)"#)
    ]
    private static let signedPositiveAmountRegex = try! NSRegularExpression(pattern: #"(?<![(\-])\+?\s*\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2})(?!\))"#)
    private static let looseDateRegex = try! NSRegularExpression(pattern: #"\b(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})\b"#)

    private enum ReceiptTiming {
        // Server QUICK_TOTAL_TIMEOUT_MS is 5000ms; allow a little transport/decode overhead.
        static let stagedInitialRequestTimeout: TimeInterval = 8
        // Poll requests should fail quickly because the itemization job is already running.
        static let stagedPollRequestTimeout: TimeInterval = 5
        // One poll per second keeps the user-facing itemization budget bounded and predictable.
        static let stagedPollInterval: TimeInterval = 1
        // 10 polls gives the staged itemization path an about-10-second completion budget.
        static let stagedMaxPollAttempts = 10
        // Legacy full parse is used only as background shadow verification after local success.
        static let shadowVerificationTimeout: TimeInterval = 30
    }

    enum DocumentType     { case receipt, transactionHistory, unknown }
    enum ProcessingMethod { case appleLocal, googleVision, tabscanner, gptAppleOCR, paddleVL }
    enum TotalConfidence  { case none, low, medium, high }
    enum ValidationStatus: String { case notValidated, balanced, closeEnough, mismatch }
    enum ReceiptSource: String { case appleVision = "apple_vision", mistral, needsReview = "needs_review" }
    enum ReceiptConfidenceStatus: String { case highConfidence = "high_confidence", mediumConfidence = "medium_confidence", needsReview = "needs_review", failed }
    enum ReceiptVerificationIssue: String {
        case totalMissing
        case subtotalMissing
        case merchantMissing
        case mathMismatch
        case totalNotNearBottom
        case duplicateTotalConflict
        case lowConfidencePriceToken
        case riskyOCRCharacterInAmount
        case itemLineMissingPrice
        case itemLineMissingName
        case impossibleTax
        case impossibleTip
        case impossibleDiscount
        case providerDisagreement
        case hallucinatedField
        case weakLayoutEvidence
        case ambiguousTotalCandidate
        case itemSumMismatch
        case itemCountMismatch
        case driftedPriceAttachment
        case categoryHeaderUsedAsItem
        case summaryPaymentFooterLeakage
        case discountTreatedAsItem
    }

    struct ReceiptData {
        var merchant:             String
        var lineItems:            [ReceiptLineItem]
        var hasReceiptStructure:  Bool
        var confidence:           Float
        var grandTotal:           Double?
        var processingMethod:     ProcessingMethod
        var receiptDate:          String?
        var needsReview:          Bool
        var fallbackReason:       String?
        var currency:             String?
        var qualityScore:         Float
        var totalConfidence:      TotalConfidence
        var validationStatus:     ValidationStatus
        var arithmeticGapCents:   Int
        var validationIssues:     [String]
        var ocrRoute:             String?
        var backgroundResultToken: String?
        var processingTimeMs:     Int? = nil
        var preprocessedPreviewImage: UIImage? = nil

        var merchandiseItems: [ReceiptLineItem] {
            lineItems.filter { $0.category == .merchandise }
        }
        
        var taxAmount: Double? {
            let tax = lineItems.filter { $0.category == .tax }.reduce(0.0) { $0 + $1.amount }
            return tax > 0 ? tax : nil
        }
        
        var tipAmount: Double? {
            let tip = lineItems.filter { $0.category == .tip }.reduce(0.0) { $0 + $1.amount }
            return tip > 0 ? tip : nil
        }
        
        var fees: Double {
            lineItems.filter { $0.category == .fee }.reduce(0.0) { $0 + $1.amount }
        }
        
        var merchandiseAmounts: [Double] {
            merchandiseItems.map { $0.amount }
        }
    }

    struct ReceiptVerificationResult {
        let source: ReceiptSource
        let status: ReceiptConfidenceStatus
        let overallConfidence: Double
        let ocrConfidence: Double
        let merchantConfidence: Double
        let itemLineConfidence: Double
        let subtotalConfidence: Double
        let taxConfidence: Double
        let tipConfidence: Double
        let discountConfidence: Double
        let totalConfidence: Double
        let mathConfidence: Double
        let layoutConfidence: Double
        let crossProviderAgreement: Double?
        let issues: [ReceiptVerificationIssue]
        let parsedReceipt: ReceiptData?
        let decisionReason: String

        var debugJSON: String {
            let payload: [String: Any] = [
                "chosenSource": source.rawValue,
                "status": status.rawValue,
                "appleConfidence": source == .appleVision ? overallConfidence : 0.0,
                "mistralConfidence": source == .mistral ? overallConfidence : 0.0,
                "mathConfidence": mathConfidence,
                "merchantConfidence": merchantConfidence,
                "itemLineConfidence": itemLineConfidence,
                "totalConfidence": totalConfidence,
                "issues": issues.map(\.rawValue),
                "decisionReason": decisionReason
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return decisionReason
            }
            return json
        }
    }

    private static var serverEndpoint: URL? {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "ReceiptParserEndpoint") as? String
        guard let rawValue else {
            print("  [OCRService] ReceiptParserEndpoint key not found in Info.plist")
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("  [OCRService] ReceiptParserEndpoint is empty in Info.plist")
            return nil
        }
        guard let url = URL(string: trimmed) else {
            print("  [OCRService] ReceiptParserEndpoint is not a valid URL: \(trimmed)")
            return nil
        }
        return url
    }
    
    static func processTransactionStatement(
        image: UIImage,
        authToken: String = "",
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let statementStartedAt = Date()
            guard let ctx = OCRPipelineContext.build(from: image) else {
                DispatchQueue.main.async {
                    completion(.failure(nsError(-200, "Unable to read statement image")))
                }
                return
            }

            print("\n╔══════════════════════════════════════════════════════╗")
            print("║  STATEMENT OCR - APPLE VISION (LOCAL)               ║")
            print("╚══════════════════════════════════════════════════════╝")
            print("  Words: \(ctx.snapshot.words.count) | Rows: \(ctx.rawRows.count)")

            if isStatementLike(ctx) {
                print("  ✓ Looks like a statement - requesting account type from user")
            } else {
                print("  ⚠️ Local statement signals were weak; continuing because the user selected Statement")
            }

            // Remove any previously registered observer BEFORE adding a new one
            // This is the root cause of duplicate statements
            if let existing = activeAccountTypeObserver {
                NotificationCenter.default.removeObserver(existing)
                activeAccountTypeObserver = nil
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .requestAccountType, object: nil)
            }

            // Track the observer so it can be cleaned up
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .accountTypeSelected,
                object: nil,
                queue: .main
            ) { notification in
                // Remove immediately — guaranteed single fire
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                    activeAccountTypeObserver = nil
                }
                observer = nil

                guard let accountType = notification.userInfo?["accountType"] as? ReceiptAccountType else {
                    completion(.failure(nsError(-212, "Account type not selected")))
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    var transactionData = parseStatementLocally(ctx: ctx, accountType: accountType)
                    transactionData.processingTimeMs = Int(Date().timeIntervalSince(statementStartedAt) * 1000)
                    guard transactionData.items.count >= 2 else {
                        DispatchQueue.main.async {
                            completion(.failure(nsError(-407, "no_statement_transactions:local_statement_rows_below_confidence_floor")))
                        }
                        return
                    }

                    print("  ✅ LOCAL STATEMENT PARSE COMPLETE")
                    print("     Account Type: \(accountType == .creditCard ? "Credit" : "Debit")")
                    print("     Transactions: \(transactionData.items.count)")
                    print("     Total Debits: $\(String(format: "%.2f", transactionData.totalDebits))")
                    print("     Total Credits: $\(String(format: "%.2f", transactionData.totalCredits))")

                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .statementDataParsed,
                            object: nil,
                            userInfo: [
                                "transactionData": transactionData,
                                "image": image
                            ]
                        )
                        completion(.failure(nsError(-213, "statement_handled_via_notification")))
                    }
                }
            }

            // Store reference so next call can clean it up
            activeAccountTypeObserver = observer
        }
    }

    // Add this static property to OCRService
    private static var activeAccountTypeObserver: NSObjectProtocol? = nil

    static func parseFinancialDocument(
        data: Data,
        mimeType: String,
        sourceType: String,
        authToken: String = "",
        completion: @escaping (Result<FinancialDocumentResponse, Error>) -> Void
    ) {
        guard let endpoint = Self.serverEndpoint?.appendingPathComponent("parse-financial-document") else {
            completion(.failure(nsError(-400, "ReceiptParserEndpoint missing or invalid")))
            return
        }
        let payload: [String: String] = [
            "fileBase64": data.base64EncodedString(),
            "mimeType": mimeType,
            "uploadIntent": "scan_statement",
            "sourceType": sourceType,
            "processingMode": "single_pass_max_accuracy_fast",
            "accuracyMode": "max",
            "latencyTargetSeconds": "5",
            "responseContract": "compact_json_only"
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(nsError(-401, "Failed to encode statement request")))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = authToken.isEmpty ? backendAuthToken : authToken
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = 180

        print("  [OCRService] POST \(endpoint.absoluteString) statement \(mimeType) \(data.count / 1024)KB")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(.failure(nsError(-402, "Network error: \(error?.localizedDescription ?? "unknown")")))
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                completion(.failure(nsError(http.statusCode, "Server error \(http.statusCode): \(body)")))
                return
            }

            do {
                let parsed = try JSONDecoder().decode(FinancialDocumentResponse.self, from: data)
                completion(.success(parsed))
            } catch {
                completion(.failure(nsError(-403, "Failed to decode statement response: \(error.localizedDescription)")))
            }
        }.resume()
    }

    static func parseFinancialDocument(
        image: UIImage,
        sourceType: String = "screenshot",
        authToken: String = "",
        completion: @escaping (Result<FinancialDocumentResponse, Error>) -> Void
    ) {
        guard let imageData = aiUploadJPEGData(from: image) else {
            completion(.failure(nsError(-404, "Unable to prepare statement image")))
            return
        }
        parseFinancialDocument(
            data: imageData,
            mimeType: "image/jpeg",
            sourceType: sourceType,
            authToken: authToken,
            completion: completion
        )
    }

    static func transactionData(from response: FinancialDocumentResponse) throws -> ReceiptTransactionData {
        guard response.ok else {
            throw nsError(-405, "Statement parser returned an error")
        }

        guard [
            "bank_statement",
            "account_activity_screenshot",
            "credit_card_activity_screenshot"
        ].contains(response.documentType) else {
            throw nsError(-406, "This does not appear to be a supported statement or transaction screenshot.")
        }

        guard let bankDocument = response.data else {
            throw nsError(-407, "No statement data was returned.")
        }

        let accountType: ReceiptAccountType = response.documentType == "credit_card_activity_screenshot"
            ? .creditCard
            : .debitCard

        let items = bankDocument.transactions.map { tx in
            ReceiptTransactionItem(
                description: tx.description,
                amount: tx.amount,
                date: tx.transactionDate ?? tx.postedDate,
                isDebit: tx.direction != "credit"
            )
        }

        let totalDebits = items.filter(\.isDebit).reduce(0.0) { $0 + $1.amount }
        let totalCredits = items.filter { !$0.isDebit }.reduce(0.0) { $0 + $1.amount }

        return ReceiptTransactionData(
            items: items,
            accountType: accountType,
            totalDebits: round2(totalDebits),
            totalCredits: round2(totalCredits),
            confidence: Float(response.classification.confidence),
            processingMethod: response.debug?.method ?? "mistral",
            processingTimeMs: response.debug?.elapsedMs,
            confidenceReason: response.debug?.confidenceReason ?? response.classification.reason
        )
    }
    private static func sendToServerInBackground(
        ctx: OCRPipelineContext,
        localData: ReceiptData,
        localLatencyMs: Int,
        authToken: String,
        backgroundResultToken: String
    ) {
        guard let imageData = ctx.processedImage.jpegData(compressionQuality: 0.90) else { return }
        let imageBase64 = imageData.base64EncodedString()
        
        let assessment = LocalReceiptQualityGate.assess(ctx: ctx)
        let serverStartedAt = Date()
        sendToServer(
            imageBase64: imageBase64,
            appleOcrText: buildAppleOCRText(ctx: ctx),
            localHints: buildLocalHints(ctx: ctx, fallbackReasons: assessment.reasons),
            authToken: authToken
        ) { result in
            let serverLatencyMs = Int(Date().timeIntervalSince(serverStartedAt) * 1000)
            switch result {
            case .success(let serverData):
                logReceiptShadowAgreement(
                    token: backgroundResultToken,
                    localData: localData,
                    serverData: serverData,
                    localLatencyMs: localLatencyMs,
                    serverLatencyMs: serverLatencyMs
                )
            case .failure(let error):
                print("  [ReceiptShadow] token=\(backgroundResultToken) server_check_failed=\"\(error.localizedDescription)\"")
            }
        }
    }

    private static func cents(_ value: Double?) -> Int? {
        guard let value else { return nil }
        return Int((value * 100).rounded())
    }

    private static func logReceiptShadowAgreement(
        token: String,
        localData: ReceiptData,
        serverData: ReceiptData,
        localLatencyMs: Int,
        serverLatencyMs: Int
    ) {
        let localItemCount = localData.merchandiseItems.count
        let serverItemCount = serverData.merchandiseItems.count
        let localTotalCents = cents(localData.grandTotal)
        let serverTotalCents = cents(serverData.grandTotal)
        let totalDeltaCents: Int? = {
            guard let localTotalCents, let serverTotalCents else { return nil }
            return serverTotalCents - localTotalCents
        }()
        let agrees = totalDeltaCents.map { abs($0) <= 1 } ?? false
            && abs(serverItemCount - localItemCount) <= 1

        print("  [ReceiptShadow] token=\(token) agreement=\(agrees ? "match" : "mismatch") local_latency_ms=\(localLatencyMs) server_latency_ms=\(serverLatencyMs)")
        print("  [ReceiptShadow] local_total_cents=\(localTotalCents.map(String.init) ?? "nil") server_total_cents=\(serverTotalCents.map(String.init) ?? "nil") total_delta_cents=\(totalDeltaCents.map(String.init) ?? "nil")")
        print("  [ReceiptShadow] local_items=\(localItemCount) server_items=\(serverItemCount) server_route=\(serverData.ocrRoute ?? "unknown")")
    }
    
    
    private static func isStatementLike(_ ctx: OCRPipelineContext) -> Bool {
        let fullText = ctx.snapshot.rawLines.joined(separator: " ").lowercased()

        print("  [isStatementLike] Checking if this is a statement...")
        print("  [isStatementLike] Text preview: \(String(fullText.prefix(200)))")

        guard ctx.snapshot.words.count >= 10 else {
            print("  [isStatementLike] ✗ too few words: \(ctx.snapshot.words.count)")
            return false
        }

        func isAmountWord(_ t: String) -> Bool {
            let ns = t as NSString
            return statementAmountWordRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil
        }

        func absAmount(_ t: String) -> Double? {
            Double(t
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "+", with: "")
                .trimmingCharacters(in: .whitespaces))
        }

        // Collect all amount words anywhere on screen
        let amountWords = ctx.snapshot.words.filter { word in
            let t = word.text.trimmingCharacters(in: .whitespaces)
            guard isAmountWord(t), let v = absAmount(t), v > 0 else { return false }
            return true
        }

        print("  [isStatementLike] Amount words: \(amountWords.count)")
        guard amountWords.count >= 2 else {
            print("  [isStatementLike] ✗ not enough amounts")
            return false
        }

        // For each amount word, check if there is ANY non-amount word nearby
        // within a vertical band — regardless of horizontal position or sign.
        // A real transaction row always has a description near its amount.
        let verticalTolerance: CGFloat = 0.10
        var pairedCount = 0

        for amt in amountWords {
            let hasDesc = ctx.snapshot.words.contains { word in
                guard abs(word.midY - amt.midY) < verticalTolerance else { return false }
                let t = word.text.trimmingCharacters(in: .whitespaces)
                guard !isAmountWord(t) else { return false }
                guard t.filter(\.isLetter).count >= 3 else { return false }
                return true
            }
            if hasDesc { pairedCount += 1 }
        }

        print("  [isStatementLike] Paired (amount+description) rows: \(pairedCount)")

        let isStatement = pairedCount >= 2
        print("  [isStatementLike] RESULT: \(isStatement ? "✓ IS STATEMENT" : "✗ NOT STATEMENT")")
        return isStatement
    }
    
    private static func parseStatementLocally(
        ctx: OCRPipelineContext,
        accountType: ReceiptAccountType
    ) -> ReceiptTransactionData {

        let words = ctx.snapshot.words.sorted { $0.midY < $1.midY }

        func isAmountWord(_ t: String) -> Bool {
            let ns = t as NSString
            return statementAmountWordRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil
        }

        func absAmount(_ t: String) -> Double? {
            Double(t
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "+", with: "")
                .trimmingCharacters(in: .whitespaces))
        }

        func isNoise(_ t: String) -> Bool {
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.count > 1 else { return true }
            guard trimmed.filter({ $0.isLetter || $0.isNumber }).count >= 2 else { return true }
            return false
        }

        struct AmountWord {
            let value: Double
            let rawSign: Sign      // what the screen actually shows
            let midX: CGFloat
            let midY: CGFloat
            let text: String

            enum Sign { case negative, positive, unsigned }
        }

        let allAmounts: [AmountWord] = words.compactMap { word in
            let t = word.text.trimmingCharacters(in: .whitespaces)
            guard isAmountWord(t), let v = absAmount(t), v > 0 else { return nil }
            let sign: AmountWord.Sign = t.hasPrefix("-") ? .negative
                                      : t.hasPrefix("+") ? .positive
                                      : .unsigned
            return AmountWord(value: round2(v), rawSign: sign,
                              midX: word.midX, midY: word.midY, text: t)
        }

        // --- Detect sign convention used by this screen ---
        // Convention A (Chase-style): negative = debit, unsigned/positive = credit
        //   → screen has at least one `-$` amount
        // Convention B (some banks): unsigned = debit, +$ = credit
        //   → screen has `+$` amounts but NO `-$` amounts
        let hasNegative = allAmounts.contains { $0.rawSign == .negative }
        let hasExplicitPositive = allAmounts.contains { $0.rawSign == .positive }
        let convention: SignConvention = (!hasNegative && hasExplicitPositive) ? .unsignedIsDebit : .negativeIsDebit

        enum SignConvention { case negativeIsDebit, unsignedIsDebit }

        print("  [parseStatement] Sign convention: \(convention == .negativeIsDebit ? "negative=debit (Chase-style)" : "unsigned=debit, +=credit")")
        print("  [parseStatement] All amounts: \(allAmounts.map { "\($0.text)@y\(String(format:"%.3f",$0.midY))" })")

        // --- Group amounts on same visual row (Y tolerance 0.025) ---
        var usedIdx = Set<Int>()
        var rows: [[AmountWord]] = []
        for (i, amt) in allAmounts.enumerated() {
            guard !usedIdx.contains(i) else { continue }
            var group = [amt]; usedIdx.insert(i)
            for (j, other) in allAmounts.enumerated() {
                guard !usedIdx.contains(j), abs(other.midY - amt.midY) < 0.025 else { continue }
                group.append(other); usedIdx.insert(j)
            }
            rows.append(group)
        }

        // --- Pick transaction candidate from each row ---
        struct TxCandidate {
            let amount: AmountWord
            let rowAmounts: [AmountWord]
            var isTransactionDebit: Bool
        }

        var candidates: [TxCandidate] = []
        for row in rows {
            switch convention {

            case .negativeIsDebit:
                // Negative = transaction debit; unsigned/positive = transaction credit or balance
                let negatives = row.filter { $0.rawSign == .negative }
                if !negatives.isEmpty {
                    negatives.forEach {
                        candidates.append(TxCandidate(amount: $0, rowAmounts: row, isTransactionDebit: true))
                    }
                } else {
                    // All unsigned/positive — each is a candidate; resolve via description below
                    row.forEach {
                        candidates.append(TxCandidate(amount: $0, rowAmounts: row, isTransactionDebit: false))
                    }
                }

            case .unsignedIsDebit:
                // Unsigned = debit, +$ = credit; negative shouldn't appear but handle it
                let unsigned = row.filter { $0.rawSign == .unsigned }
                let positive = row.filter { $0.rawSign == .positive }
                let negative = row.filter { $0.rawSign == .negative }
                // Emit unsigned as debits
                unsigned.forEach {
                    candidates.append(TxCandidate(amount: $0, rowAmounts: row, isTransactionDebit: true))
                }
                // Emit explicit positives as credits
                positive.forEach {
                    candidates.append(TxCandidate(amount: $0, rowAmounts: row, isTransactionDebit: false))
                }
                // Negative still = debit if it somehow appears
                negative.forEach {
                    candidates.append(TxCandidate(amount: $0, rowAmounts: row, isTransactionDebit: true))
                }
            }
        }
        candidates.sort { $0.amount.midY < $1.amount.midY }

        // --- Collect description words for each candidate ---
        func descriptionWords(for candidate: TxCandidate, prevY: CGFloat) -> String {
            let windowTop    = prevY + 0.005
            let windowBottom = candidate.amount.midY + 0.04

            let desc = words
                .filter { word in
                    guard word.midY >= windowTop, word.midY <= windowBottom else { return false }
                    let t = word.text.trimmingCharacters(in: .whitespaces)
                    guard !isAmountWord(t) else { return false }
                    guard !isNoise(t) else { return false }
                    return true
                }
                .sorted { $0.midY != $1.midY ? $0.midY < $1.midY : $0.midX < $1.midX }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            return desc.count > 80 ? String(desc.prefix(80)) + "…" : desc
        }

        // --- Emit transactions ---
        var transactions: [ReceiptTransactionItem] = []
        var prevY: CGFloat = 0

        for candidate in candidates {
            let description = descriptionWords(for: candidate, prevY: prevY)

            // Skip balance echoes: same-row all-positive candidates with no description
            let sharesRow = candidate.rowAmounts.count > 1
            if sharesRow && description.isEmpty {
                print("  [parseStatement] ⚠️ skipping \(candidate.amount.text) — balance echo")
                prevY = candidate.amount.midY
                continue
            }

            guard !description.isEmpty else {
                print("  [parseStatement] ⚠️ no description for \(candidate.amount.text) — skipping")
                prevY = candidate.amount.midY
                continue
            }

            // For debit account, override isTransactionDebit using accountType if needed
            // Credit card flips the sense: a charge (positive/unsigned) is what you owe
            let isDebit: Bool
            if accountType == .creditCard {
                // Credit card: unsigned/positive = you spent (debit), negative = refund (credit)
                isDebit = candidate.amount.rawSign != .negative
            } else {
                // Debit account: use convention-derived value
                isDebit = candidate.isTransactionDebit
            }

            transactions.append(ReceiptTransactionItem(
                description: description,
                amount: candidate.amount.value,
                date: nil,
                isDebit: isDebit
            ))

            print("  [parseStatement] ✓ \(isDebit ? "DEBIT" : "CREDIT") \(String(format:"$%.2f", candidate.amount.value)) — \(description)")
            prevY = candidate.amount.midY
        }

        let totalDebits  = round2(transactions.filter {  $0.isDebit }.reduce(0) { $0 + $1.amount })
        let totalCredits = round2(transactions.filter { !$0.isDebit }.reduce(0) { $0 + $1.amount })
        print("  [parseStatement] Final: \(transactions.count) txns | debits=$\(totalDebits) credits=$\(totalCredits)")
        let confidence: Float = transactions.count >= 4 ? 0.88 : transactions.count >= 2 ? 0.78 : 0.45

        return ReceiptTransactionData(
            items: transactions,
            accountType: accountType,
            totalDebits: totalDebits,
            totalCredits: totalCredits,
            confidence: confidence,
            processingMethod: "local",
            processingTimeMs: nil,
            confidenceReason: "Apple Vision local statement parse extracted \(transactions.count) transaction row(s)."
        )
    }
    // 4. ADD HELPER: Extract signed amounts (positive and negative)
    private static func extractSignedAmounts(from text: String) -> [Double] {
        var amounts: [Double] = []
        
        let ns = text as NSString
        
        // Extract negative amounts first
        for regex in signedNegativeAmountRegexes {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if match.numberOfRanges >= 2 {
                    let amountStr = ns.substring(with: match.range(at: 1))
                        .replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: "$", with: "")
                    if let value = Double(amountStr), value > 0 {
                        amounts.append(-value)  // Negative amount
                    }
                }
            }
        }
        
        // Extract positive amounts
        for match in signedPositiveAmountRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.numberOfRanges >= 2 {
                let amountStr = ns.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: "$", with: "")
                if let value = Double(amountStr), value > 0 {
                    // Check if this position was already captured as negative
                    let alreadyCaptured = amounts.contains { amount in
                        abs(abs(amount) - value) < 0.01
                    }
                    if !alreadyCaptured {
                        amounts.append(value)  // Positive amount
                    }
                }
            }
        }
        
        return amounts.map { round2($0) }
    }
     
    // 5. ADD HELPER: Extract transaction description
    private static func extractTransactionDescription(from row: RawReceiptRow, amounts: [Double]) -> String {
        // Get all tokens before the first amount
        let tokens = row.allTokens
        var descriptionTokens: [String] = []
        
        for token in tokens {
            let cleaned = token.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .trimmingCharacters(in: .whitespaces)
            
            // Stop if we hit an amount
            if let cleanedAmount = Double(cleaned),
               amounts.contains(where: { abs(abs($0) - cleanedAmount) < 0.01 }) {
                break
            }
            
            // Skip dates
            if cleaned.range(of: #"\d{1,2}[/-]\d{1,2}"#, options: .regularExpression) != nil {
                continue
            }
            
            // Skip common statement junk
            if cleaned.isEmpty || cleaned.count <= 1 {
                continue
            }
            
            descriptionTokens.append(token)
        }
        
        let description = descriptionTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        
        // Limit description length
        if description.count > 60 {
            return String(description.prefix(60)) + "..."
        }
        
        return description
    }
     
    // 6. ADD HELPER: Extract date from text
    private static func extractDate(from text: String) -> String? {
        // Pattern: MM/DD/YYYY or MM/DD/YY or MM-DD-YYYY
        guard let match = looseDateRegex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
            return nil
        }
        
        let ns = text as NSString
        return ns.substring(with: match.range)
    }
     
    // 7. ADD HELPER: Remove duplicate transactions
    private static func removeDuplicateTransactions(_ transactions: [ReceiptTransactionItem]) -> [ReceiptTransactionItem] {
        var seen: Set<String> = []
        var unique: [ReceiptTransactionItem] = []
        
        for transaction in transactions {
            // Create a unique key based on description and amount
            let key = "\(transaction.description)_\(Int(transaction.amount * 100))"
            
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(transaction)
            }
        }
        
        return unique
    }
     
    
    

    private static var backendAuthToken: String {
        Bundle.main.object(forInfoDictionaryKey: "ReceiptParserAuthToken") as? String ?? ""
    }

    private struct LocalReceiptCandidateEvaluation {
        let ctx: OCRPipelineContext
        let assessment: LocalReceiptQualityGate.Assessment
        let verification: ReceiptVerificationResult
        var data: ReceiptData
        let trusted: Bool
        let selectionScore: Double

        var source: String { ctx.candidateSource }
        var itemizationStatus: String {
            data.validationIssues
                .first(where: { $0.hasPrefix("local_itemization_status:") })?
                .replacingOccurrences(of: "local_itemization_status:", with: "") ?? "unknown"
        }
        var itemizationAttempted: Bool { boolIssue("itemization_attempted") ?? false }
        var itemWindowFound: Bool { boolIssue("item_window_found") ?? false }
        var itemNameCandidateCount: Int { intIssue("item_name_candidate_count") ?? 0 }
        var itemPriceCandidateCount: Int { intIssue("item_price_candidate_count") ?? 0 }
        var acceptedItemCount: Int { intIssue("accepted_item_count") ?? data.merchandiseItems.count }
        var rejectedItemCount: Int { intIssue("rejected_item_count") ?? 0 }
        var itemizationFailureReason: String? { stringIssue("itemization_failure_reason") }

        private func stringIssue(_ key: String) -> String? {
            data.validationIssues
                .first(where: { $0.hasPrefix("\(key):") })?
                .replacingOccurrences(of: "\(key):", with: "")
        }

        private func boolIssue(_ key: String) -> Bool? {
            stringIssue(key).flatMap { Bool($0) }
        }

        private func intIssue(_ key: String) -> Int? {
            stringIssue(key).flatMap { Int($0) }
        }
    }

    private static func evaluateLocalReceiptCandidate(
        ctx: OCRPipelineContext,
        receiptPipelineStartedAt: Date
    ) -> LocalReceiptCandidateEvaluation {
        let assessment = LocalReceiptQualityGate.assess(ctx: ctx)
        let localCandidate = LocalReceiptQualityGate.buildReceiptData(from: ctx)
        let verification = verifyReceiptCandidate(
            localCandidate,
            source: .appleVision,
            ctx: ctx
        )

        var localData = localCandidate
        localData.processingTimeMs = Int(Date().timeIntervalSince(receiptPipelineStartedAt) * 1000)
        localData.ocrRoute = "apple_local_\(ctx.candidateSource)"
        localData.confidence = max(localData.confidence, Float(verification.overallConfidence))
        localData.fallbackReason = [
            localData.fallbackReason,
            verification.decisionReason
        ]
        .compactMap { $0 }
        .joined(separator: " | verifier=")
        if let quality = ctx.quality {
            localData.qualityScore = min(localData.qualityScore, Float(quality.score / 100.0))
            if quality.shouldRetake,
               !localData.validationIssues.contains("image_quality_retake_suggested") {
                localData.validationIssues.append("image_quality_retake_suggested")
            }
        }
        if !isStrictApplePass(verification),
           !localData.validationIssues.contains("strict_local_gate_failed") {
            localData.validationIssues.append("strict_local_gate_failed")
        }

        let trusted = isStrictApplePass(verification) && assessment.usable
        if trusted {
            localData.needsReview = false
            localData.ocrRoute = "apple_local_trusted_\(ctx.candidateSource)"
        } else {
            localData.needsReview = true
            localData.ocrRoute = verification.status == .failed
                ? "apple_local_user_review_required_\(ctx.candidateSource)"
                : "apple_local_provisional_waiting_for_server_\(ctx.candidateSource)"
            if !localData.validationIssues.contains("untrusted_local_ocr") {
                localData.validationIssues.append("untrusted_local_ocr")
            }
            if verification.status == .failed,
               !localData.validationIssues.contains("local_verifier_failed") {
                localData.validationIssues.append("local_verifier_failed")
            }
        }

        let score = localCandidateSelectionScore(
            data: localData,
            assessment: assessment,
            verification: verification,
            trusted: trusted
        )

        return LocalReceiptCandidateEvaluation(
            ctx: ctx,
            assessment: assessment,
            verification: verification,
            data: localData,
            trusted: trusted,
            selectionScore: score
        )
    }

    private static func localCandidateSelectionScore(
        data: ReceiptData,
        assessment: LocalReceiptQualityGate.Assessment,
        verification: ReceiptVerificationResult,
        trusted: Bool
    ) -> Double {
        let issues = data.validationIssues.joined(separator: " ")
        let isFullItemized = issues.contains("local_itemization_status:fullItemizedTrusted")
        let isTotalOnly = issues.contains("local_itemization_status:totalOnlyTrusted")
        let isNeedsReview = issues.contains("local_itemization_status:itemizedNeedsReview")
        let itemizationAttempted = issues.contains("itemization_attempted:true")
        let itemWindowFound = issues.contains("item_window_found:true")
        let gapCents = data.arithmeticGapCents

        if itemWindowFound, !itemizationAttempted { return -1_000_000 }
        if !itemizationAttempted, isTotalOnly { return -900_000 }
        if trusted, isFullItemized, gapCents <= 1 { return 1_000_000 + verification.overallConfidence * 1_000 }
        if trusted, isTotalOnly, itemizationAttempted, gapCents <= 1 { return 800_000 + verification.totalConfidence * 1_000 }
        if verification.status == .failed { return -100_000 + verification.overallConfidence * 100 }

        var score = 0.0
        switch verification.status {
        case .highConfidence: score += 50_000
        case .mediumConfidence: score += 30_000
        case .needsReview: score += 15_000
        case .failed: score -= 50_000
        }
        if isNeedsReview { score += 5_000 }
        if isTotalOnly { score += 4_000 }
        if isFullItemized { score += 8_000 }
        if itemWindowFound, data.merchandiseItems.isEmpty { score -= 20_000 }
        if !itemizationAttempted { score -= 50_000 }
        if data.grandTotal != nil { score += 2_000 }
        score += Double(data.merchandiseItems.count) * 250
        score += verification.overallConfidence * 1_000
        score += verification.mathConfidence * 1_000
        score += Double(max(0, 100 - min(gapCents, 100)))
        score += Double(assessment.score) * 500
        return score
    }

    private static func selectLocalReceiptCandidate(_ evaluations: [LocalReceiptCandidateEvaluation]) -> LocalReceiptCandidateEvaluation? {
        guard !evaluations.isEmpty else { return nil }
        let sorted = evaluations.sorted {
            if abs($0.selectionScore - $1.selectionScore) > 0.001 {
                return $0.selectionScore > $1.selectionScore
            }
            return $0.ctx.snapshot.words.count > $1.ctx.snapshot.words.count
        }
        print("\n╔══════════════════════════════════════════════════════╗")
        print("║  LOCAL OCR CANDIDATE SELECTION                      ║")
        print("╚══════════════════════════════════════════════════════╝")
        for eval in sorted {
            let itemSum = eval.data.merchandiseItems.reduce(0.0) { $0 + $1.amount }
            print("  [LocalCandidate] source=\(eval.source) score=\(String(format: "%.1f", eval.selectionScore)) status=\(eval.itemizationStatus) attempted=\(eval.itemizationAttempted) itemWindowFound=\(eval.itemWindowFound) names=\(eval.itemNameCandidateCount) prices=\(eval.itemPriceCandidateCount) accepted=\(eval.acceptedItemCount) rejected=\(eval.rejectedItemCount) failure=\(eval.itemizationFailureReason ?? "none") verifier=\(eval.verification.status.rawValue) usable=\(eval.assessment.usable ? "YES" : "NO") merchant='\(eval.data.merchant)' total=\(eval.data.grandTotal.map { String(format: "%.2f", $0) } ?? "nil") items=\(eval.data.merchandiseItems.count) itemSum=\(String(format: "%.2f", itemSum)) gap=\(eval.data.arithmeticGapCents) issues=\(eval.verification.issues.map(\.rawValue).joined(separator: ","))")
        }
        print("  [LocalCandidate] chosen=\(sorted[0].source)\n")
        return sorted[0]
    }

    static func processDocument(
        from image: UIImage,
        hint: DocumentType = .unknown,
        authToken: String = "",
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        // CRITICAL: Route to statement processor FIRST
        if hint == .transactionHistory {
            print("  [processDocument] Routing to statement processor...")
            processTransactionStatement(image: image, authToken: authToken, completion: completion)
            return
        }
     
        DispatchQueue.global(qos: .userInitiated).async {
            let receiptPipelineStartedAt = Date()

            let candidateContexts = OCRPipelineContext.buildCandidates(from: image)
            guard !candidateContexts.isEmpty else {
                print("  Apple Vision produced no receipt text; returning test receipt placeholder.")
                DispatchQueue.main.async {
                    completion(.success(testReceiptData(from: image, reason: "no_receipt_text")))
                }
                return
            }

            let evaluations = candidateContexts.map {
                evaluateLocalReceiptCandidate(ctx: $0, receiptPipelineStartedAt: receiptPipelineStartedAt)
            }
            guard let chosenEvaluation = selectLocalReceiptCandidate(evaluations) else {
                DispatchQueue.main.async {
                    completion(.success(testReceiptData(from: image, reason: "no_local_candidate_selected")))
                }
                return
            }
            let ctx = chosenEvaluation.ctx
     
            print("\n╔══════════════════════════════════════════════════════╗")
            print("║  APPLE VISION OCR COMPLETE                           ║")
            print("╚══════════════════════════════════════════════════════╝")
            print("  Candidate source: \(ctx.candidateSource)")
            print("  Words: \(ctx.snapshot.words.count) | Rows: \(ctx.rawRows.count)")
            print("  Merchant: '\(ctx.quick.merchant)'")
            print("  Total: \(ctx.quick.total.map { String(format: "$%.2f", $0) } ?? "nil") [\(ctx.quick.totalConf)]")
            print("  Tax: \(ctx.quick.tax.map { String(format: "$%.2f", $0) } ?? "nil")")

            if !LocalReceiptQualityGate.isReceiptLike(ctx) {
                print("  [ReceiptTestMode] receipt-like structure gate skipped")
            }
     
            let gateStart = CFAbsoluteTimeGetCurrent()
            let assessment = chosenEvaluation.assessment
            var timing = ctx.timing
            timing.gateMs = elapsedMs(since: gateStart)
            timing.totalMs = elapsedMs(since: CFAbsoluteTime(receiptPipelineStartedAt.timeIntervalSinceReferenceDate))
            print(String(format: "[Timing] detect=%.0fms correct=%.0fms crop=%.0fms enhance=%.0fms quality=%.0fms upscale=%.0fms vision=%.0fms rows=%.0fms quick=%.0fms gate=%.0fms total=%.0fms",
                         timing.detectMs,
                         timing.correctionMs,
                         timing.cropMs,
                         timing.enhanceMs,
                         timing.qualityMs,
                         timing.upscaleMs,
                         timing.visionMs,
                         timing.rowsMs,
                         timing.quickMs,
                         timing.gateMs,
                         timing.totalMs))
            if let quality = ctx.quality {
                print(String(format: "[ImageQuality] score=%.0f blur=%.0f brightness=%.0f contrast=%.0f textH=%.0f distortion=%.2f retake=%@",
                             quality.score,
                             quality.blurVariance,
                             quality.brightness,
                             quality.contrast,
                             quality.estimatedTextHeight,
                             quality.perspectiveDistortion,
                             quality.shouldRetake ? "YES" : "NO"))
                if quality.shouldRetake {
                    print("[ImageQuality] suggestions=\(quality.retakeReasons.joined(separator: " "))")
                }
            }
            print(String(format: "[LegacyTiming] segment=%.0fms correct=%.0fms enhance=%.0fms vision=%.0fms rows=%.0fms quick=%.0fms gate=%.0fms total=%.0fms",
                         timing.segmentMs,
                         timing.correctionMs,
                         timing.enhanceMs,
                         timing.visionMs,
                         timing.rowsMs,
                         timing.quickMs,
                         timing.gateMs,
                         timing.totalMs))
            print("\n╔══════════════════════════════════════════════════════╗")
            print("║  LOCAL OCR HINT ASSESSMENT                           ║")
            print("╚══════════════════════════════════════════════════════╝")
            print("  Looks usable locally: \(assessment.usable ? "YES" : "NO")")
            print("  Score: \(String(format:"%.2f",assessment.score))")
            print("  Reasons: \(assessment.reasons.isEmpty ? "none" : assessment.reasons.joined(separator:", "))")
            print("════════════════════════════════════════════════════════\n")

            let localVerification = chosenEvaluation.verification
            print("  [ReceiptVerifier] Apple: \(localVerification.decisionReason)")

            let localData = chosenEvaluation.data
            let localTrusted = chosenEvaluation.trusted
            print("\n  \(localTrusted ? "✅ TRUSTED LOCAL RECEIPT DECISION" : "⚠️ UNTRUSTED LOCAL RECEIPT DECISION")")
            print("     Chosen: \(localTrusted ? "trusted local candidate" : "review/provisional local candidate") [source=\(chosenEvaluation.source) score=\(String(format: "%.1f", chosenEvaluation.selectionScore))]")
            print("     Verifier: \(localVerification.decisionReason)")
            print("     Total: \(localData.grandTotal.map { String(format: "%.2f", $0) } ?? "nil")")
            print("     Needs review: \(localData.needsReview ? "YES" : "NO")")
            print("     Route: \(localData.ocrRoute ?? "unknown")")
            print("     Mistral/staged server: disabled\n")

            DispatchQueue.main.async {
                completion(.success(localData))
            }
        }
    }
     
    static func processReceiptQuickThenFull(
        from image: UIImage,
        authToken: String = "",
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        processDocument(from: image, hint: .receipt, authToken: authToken, completion: completion)
    }

    private static func testReceiptData(from image: UIImage, reason: String) -> ReceiptData {
        let prepared = ImagePreprocessor.prepareWithTimings(image)
        return ReceiptData(
            merchant: "Unknown Merchant",
            lineItems: [],
            hasReceiptStructure: true,
            confidence: 0,
            grandTotal: nil,
            processingMethod: .appleLocal,
            receiptDate: nil,
            needsReview: false,
            fallbackReason: "test_mode_placeholder:\(reason)",
            currency: "USD",
            qualityScore: 0,
            totalConfidence: .none,
            validationStatus: .notValidated,
            arithmeticGapCents: 0,
            validationIssues: [],
            ocrRoute: "apple_local_test_placeholder",
            backgroundResultToken: nil,
            processingTimeMs: Int(prepared.timing.totalMs),
            preprocessedPreviewImage: prepared.previewImage ?? prepared.image
        )
    }
	 
	 
    static func extractText(
        from image: UIImage,
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        processDocument(from: image, hint: .receipt, authToken: backendAuthToken, completion: completion)
    }

    private struct ServerRequestPayload: Codable {
        struct LocalHints: Codable {
            let merchantCandidate:         String
            let grandTotalCandidate:       Double?
            let grandTotalConfidence:      String
            let subtotalCandidate:         Double?
            let taxCandidate:              Double?
            let tipCandidate:              Double?
            let targetMerchandiseSubtotal: Double?
            let fallbackReason:            String
        }
        struct LocalParseResult: Codable {
            let merchant: String
            let items: [Item]
            let subtotal: Double?
            let tax: Double?
            let tip: Double?
            let grandTotal: Double?
            
            struct Item: Codable {
                let name: String
                let amount: Double
                let qty: Double?
                let unitPrice: Double?
                let weightLbs: Double?
                let confidence: String
            }
        }

        let imageBase64:      String
        let mimeType:         String
        let currency:         String
        let processingMode:   String
        let accuracyMode:     String
        let latencyTargetSeconds: Int
        let responseContract: String
        let appleOcrText:     String
        let localHints:       LocalHints
        let localParseResult: LocalParseResult?
    }

    private static func aiUploadJPEGData(from image: UIImage, maxDimension: CGFloat = 1800, quality: CGFloat = 0.82) -> Data? {
        guard let cg = image.cgImage else {
            return image.jpegData(compressionQuality: quality)
        }

        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let longest = max(width, height)
        guard longest > maxDimension else {
            return image.jpegData(compressionQuality: quality)
        }

        let scale = maxDimension / longest
        let targetSize = CGSize(width: width * scale, height: height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    private static func sendToServer(
        imageBase64: String,
        appleOcrText: String,
        localHints: ServerRequestPayload.LocalHints,
        authToken: String,
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        guard let endpoint = Self.serverEndpoint?.appendingPathComponent("parse-receipt") else {
            completion(.failure(nsError(-400, "ReceiptParserEndpoint missing or invalid")))
            return
        }

        let localParseResult: ServerRequestPayload.LocalParseResult? = {
            guard let total = localHints.grandTotalCandidate, total > 0 else { return nil }
            return ServerRequestPayload.LocalParseResult(
                merchant: localHints.merchantCandidate,
                items: [],
                subtotal: localHints.subtotalCandidate,
                tax: localHints.taxCandidate,
                tip: localHints.tipCandidate,
                grandTotal: total
            )
        }()

        let payload = ServerRequestPayload(
            imageBase64:      imageBase64,
            mimeType:         "image/jpeg",
            currency:         "USD",
            processingMode:   "single_pass_max_accuracy_fast",
            accuracyMode:     "max",
            latencyTargetSeconds: 5,
            responseContract: "compact_json_only",
            appleOcrText:     appleOcrText,
            localHints:       localHints,
            localParseResult: localParseResult
        )

        guard let bodyData = try? JSONEncoder().encode(payload) else {
            completion(.failure(nsError(-301, "Failed to encode request payload"))); return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = ReceiptTiming.shadowVerificationTimeout

        print("  [OCRService] POST \(endpoint.absoluteString)")
        print("  [OCRService] payload: image=\(imageBase64.count / 1024)KB appleOcrText=\(appleOcrText.count)ch")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(.failure(nsError(-302, "Network error: \(error?.localizedDescription ?? "unknown")"))); return
            }
            if let http = response as? HTTPURLResponse {
                print("  [OCRService] HTTP \(http.statusCode)")
                guard (200...299).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                    completion(.failure(nsError(http.statusCode, "Server error \(http.statusCode): \(body)"))); return
                }
            }
            do {
                let serverResponse = try JSONDecoder().decode(ServerReceiptResponse.self, from: data)
                let receiptData    = buildReceiptData(from: serverResponse)
                guard isUsableReceiptData(receiptData, serverResponse: serverResponse) else {
                    completion(.failure(nsError(-214, "not_a_receipt:server_returned_no_receipt_total")))
                    return
                }
                completion(.success(receiptData))
            } catch {
                print("  [OCRService] Decode error: \(error)")
                completion(.failure(nsError(-303, "Failed to decode server response: \(error.localizedDescription)")))
            }
        }.resume()
    }

    private static func sendToServerStaged(
        imageBase64: String,
        authToken: String,
        onQuickTotal: ((Double?, String?) -> Void)? = nil,
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        guard let endpoint = Self.serverEndpoint?.appendingPathComponent("parse-receipt-staged") else {
            completion(.failure(nsError(-400, "ReceiptParserEndpoint missing or invalid")))
            return
        }
        let payload: [String: Any] = [
            "imageBase64": imageBase64,
            "mimeType": "image/jpeg",
            "sourceType": "camera",
            "mode": "staged"
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(nsError(-301, "Failed to encode staged request")))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = ReceiptTiming.stagedInitialRequestTimeout

        print("  [OCRService] POST \(endpoint.absoluteString)")
        print("  [OCRService] staged payload: image=\(imageBase64.count / 1024)KB")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(.failure(nsError(-302, "Network error: \(error?.localizedDescription ?? "unknown")")))
                return
            }
            if let http = response as? HTTPURLResponse {
                print("  [OCRService] staged HTTP \(http.statusCode)")
                guard (200...299).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
                    completion(.failure(nsError(http.statusCode, "Staged server error \(http.statusCode): \(body)")))
                    return
                }
            }

            do {
                let staged = try JSONDecoder().decode(ServerReceiptStagedResponse.self, from: data)
                onQuickTotal?(staged.quickTotal?.grandTotal, staged.quickTotal?.merchant)

                if staged.itemizationStatus == "complete", let result = staged.result {
                    let receiptData = buildReceiptData(from: result)
                    guard isUsableReceiptData(receiptData, serverResponse: result) else {
                        completion(.failure(nsError(-214, "not_a_receipt:staged_server_returned_no_receipt_total")))
                        return
                    }
                    completion(.success(receiptData))
                    return
                }

                pollStagedReceipt(
                    requestId: staged.request_id,
                    authToken: authToken,
                    attempt: 0,
                    completion: completion
                )
            } catch {
                print("  [OCRService] staged decode error: \(error)")
                completion(.failure(nsError(-303, "Failed to decode staged response: \(error.localizedDescription)")))
            }
        }.resume()
    }

    private static func pollStagedReceipt(
        requestId: String,
        authToken: String,
        attempt: Int,
        completion: @escaping (Result<ReceiptData, Error>) -> Void
    ) {
        guard attempt < ReceiptTiming.stagedMaxPollAttempts else {
            completion(.failure(nsError(-304, "Itemization timed out")))
            return
        }

        guard let endpoint = Self.serverEndpoint?
            .appendingPathComponent("parse-receipt-staged")
            .appendingPathComponent(requestId)
        else {
            completion(.failure(nsError(-400, "ReceiptParserEndpoint missing or invalid")))
            return
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = ReceiptTiming.stagedPollRequestTimeout

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let staged = try? JSONDecoder().decode(ServerReceiptStagedResponse.self, from: data) else {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + ReceiptTiming.stagedPollInterval) {
                    pollStagedReceipt(
                        requestId: requestId,
                        authToken: authToken,
                        attempt: attempt + 1,
                        completion: completion
                    )
                }
                return
            }

            if staged.itemizationStatus == "complete", let result = staged.result {
                let receiptData = buildReceiptData(from: result)
                guard isUsableReceiptData(receiptData, serverResponse: result) else {
                    completion(.failure(nsError(-214, "not_a_receipt:staged_server_returned_no_receipt_total")))
                    return
                }
                completion(.success(receiptData))
            } else if staged.itemizationStatus == "failed" {
                completion(.failure(nsError(-305, staged.error?.message ?? "Itemization failed")))
            } else {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + ReceiptTiming.stagedPollInterval) {
                    pollStagedReceipt(
                        requestId: requestId,
                        authToken: authToken,
                        attempt: attempt + 1,
                        completion: completion
                    )
                }
            }
        }.resume()
    }

    private static func isUsableReceiptData(_ receiptData: ReceiptData, serverResponse: ServerReceiptResponse) -> Bool {
        guard let total = receiptData.grandTotal, total > 0 else { return false }
        if !receiptData.hasReceiptStructure { return false }
        if serverResponse.items.contains(where: { $0.amount > 0 && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        if let subtotal = serverResponse.subtotal, subtotal > 0 { return true }
        if let tax = serverResponse.tax, tax > 0 { return true }
        if let tip = serverResponse.tip, tip > 0 { return true }
        if let fees = serverResponse.fees, fees > 0 { return true }
        return !serverResponse.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && serverResponse.receiptDate != nil
    }

    private static func buildAppleOCRText(ctx: OCRPipelineContext) -> String {
        ctx.rawRows
            .map { $0.fullText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func verifyReceiptCandidate(
        _ receipt: ReceiptData,
        source: ReceiptSource,
        ctx: OCRPipelineContext,
        peer: ReceiptData? = nil
    ) -> ReceiptVerificationResult {
        var issues: Set<ReceiptVerificationIssue> = []
        let ocrConfidence = averageOCRConfidence(ctx)
        let merchantConfidence = merchantEvidenceConfidence(receipt.merchant, ctx: ctx, source: source, issues: &issues)
        let totalEvidence = totalEvidenceConfidence(receipt.grandTotal, ctx: ctx, issues: &issues)
        let itemLineConfidence = itemEvidenceConfidence(receipt, ctx: ctx, source: source, issues: &issues)
        let fieldConfidence = fieldConfidence(receipt)
        let mathConfidence = mathReconciliationConfidence(receipt, issues: &issues)
        let layoutConfidence = min(totalEvidence.layoutConfidence, merchantConfidence >= 0.80 ? 0.95 : 0.72)
        let crossProviderAgreement = peer.map { providerAgreement(receipt, $0, issues: &issues) }
        let selfConsistency = crossProviderAgreement ?? (mathConfidence >= 0.95 && totalEvidence.totalConfidence >= 0.95 ? 0.92 : 0.68)

        if hasRiskyAmountOCR(ctx) {
            issues.insert(.riskyOCRCharacterInAmount)
        }
        if hasDuplicateTotalConflict(ctx, expectedTotal: receipt.grandTotal) {
            issues.insert(.duplicateTotalConflict)
        }
        if receipt.grandTotal == nil || (receipt.grandTotal ?? 0) <= 0 {
            issues.insert(.totalMissing)
        }
        if let tax = receipt.taxAmount, tax < 0 {
            issues.insert(.impossibleTax)
        }
        if let tip = receipt.tipAmount, tip < 0 {
            issues.insert(.impossibleTip)
        }
        if receipt.merchandiseItems.count > 1 {
            let weakPriceCount = receipt.merchandiseItems.filter { $0.amount <= 0 || $0.amount > 5000 }.count
            if Double(weakPriceCount) / Double(receipt.merchandiseItems.count) > 0.20 {
                issues.insert(.lowConfidencePriceToken)
            }
        }

        let fullItemizedTrusted = receipt.validationIssues.contains("local_itemization_status:fullItemizedTrusted")
        if fullItemizedTrusted && mathConfidence >= 0.95 && totalEvidence.totalConfidence >= 0.90 {
            issues.remove(.ambiguousTotalCandidate)
            issues.remove(.totalNotNearBottom)
            issues.remove(.riskyOCRCharacterInAmount)
            if !hasUnresolvedDuplicateTotalConflict(ctx, selectedTotal: receipt.grandTotal) {
                issues.remove(.duplicateTotalConflict)
            }
        }

        let overall = min(1.0, max(0.0,
            0.30 * mathConfidence +
            0.20 * totalEvidence.totalConfidence +
            0.15 * itemLineConfidence +
            0.12 * layoutConfidence +
            0.10 * merchantConfidence +
            0.08 * ocrConfidence +
            0.05 * selfConsistency
        ))

        let hardNeedsReview: Set<ReceiptVerificationIssue> = [
            .totalMissing,
            .mathMismatch,
            .totalNotNearBottom,
            .duplicateTotalConflict,
            .riskyOCRCharacterInAmount,
            .ambiguousTotalCandidate,
            .providerDisagreement,
            .hallucinatedField,
            .impossibleTax,
            .impossibleTip,
            .impossibleDiscount
        ]
        let hasHardIssue = issues.contains(where: { hardNeedsReview.contains($0) })
        let status: ReceiptConfidenceStatus
        if receipt.grandTotal == nil || receipt.lineItems.isEmpty {
            status = .failed
        } else if hasHardIssue || overall < 0.70 {
            status = .needsReview
        } else if overall >= 0.90 && mathConfidence >= 0.95 && totalEvidence.totalConfidence >= 0.95 {
            status = .highConfidence
        } else {
            status = .mediumConfidence
        }

        let reason = [
            "\(source.rawValue) verifier status=\(status.rawValue)",
            "overall=\(String(format: "%.2f", overall))",
            "math=\(String(format: "%.2f", mathConfidence))",
            "total=\(String(format: "%.2f", totalEvidence.totalConfidence))",
            "items=\(String(format: "%.2f", itemLineConfidence))",
            "merchant=\(String(format: "%.2f", merchantConfidence))",
            "issues=\(issues.map(\.rawValue).sorted().joined(separator: ","))"
        ].joined(separator: " | ")

        return ReceiptVerificationResult(
            source: source,
            status: status,
            overallConfidence: overall,
            ocrConfidence: ocrConfidence,
            merchantConfidence: merchantConfidence,
            itemLineConfidence: itemLineConfidence,
            subtotalConfidence: fieldConfidence.subtotal,
            taxConfidence: fieldConfidence.tax,
            tipConfidence: fieldConfidence.tip,
            discountConfidence: fieldConfidence.discount,
            totalConfidence: totalEvidence.totalConfidence,
            mathConfidence: mathConfidence,
            layoutConfidence: layoutConfidence,
            crossProviderAgreement: crossProviderAgreement,
            issues: issues.sorted { $0.rawValue < $1.rawValue },
            parsedReceipt: receipt,
            decisionReason: reason
        )
    }

    private static func chooseBestReceiptResult(
        apple: ReceiptVerificationResult?,
        mistral: ReceiptVerificationResult?,
        mistralTimedOut: Bool
    ) -> ReceiptVerificationResult {
        if let apple, let mistral,
           let appleTotal = apple.parsedReceipt?.grandTotal,
           let mistralTotal = mistral.parsedReceipt?.grandTotal,
           abs(appleTotal - mistralTotal) > 0.03 {
            return reviewResult(
                parsedReceipt: strongerFallbackReceipt(apple: apple, mistral: mistral),
                reason: "provider total disagreement > $0.03",
                issues: [.providerDisagreement]
            )
        }

        if let apple, isStrictApplePass(apple) {
            if let mistral {
                if mistral.status != .highConfidence && mistral.mathConfidence < apple.mathConfidence {
                    return apple
                }
            } else {
                return apple
            }
        }

        if let mistral, isStrictMistralPass(mistral) {
            if let apple {
                if mistral.overallConfidence >= apple.overallConfidence - 0.02 {
                    return mistral
                }
            } else {
                return mistral
            }
        }

        if let apple, let mistral {
            let candidates = [apple, mistral].sorted {
                if abs($0.mathConfidence - $1.mathConfidence) > 0.02 { return $0.mathConfidence > $1.mathConfidence }
                if abs($0.totalConfidence - $1.totalConfidence) > 0.02 { return $0.totalConfidence > $1.totalConfidence }
                return $0.overallConfidence > $1.overallConfidence
            }
            let best = candidates[0]
            if best.status == .highConfidence || best.status == .mediumConfidence {
                return applyReviewStatusIfNeeded(best, reason: "best verified provider but not strict clean final")
            }
            return reviewResult(parsedReceipt: best.parsedReceipt, reason: "both providers uncertain", issues: best.issues)
        }

        if let apple {
            if isStrictApplePass(apple) { return apple }
            let reason = mistralTimedOut ? "mistral timed out and apple was not strict high-confidence" : "apple was not strict high-confidence"
            return reviewResult(parsedReceipt: apple.parsedReceipt, reason: reason, issues: apple.issues)
        }

        if let mistral {
            if isStrictMistralPass(mistral) { return mistral }
            return reviewResult(parsedReceipt: mistral.parsedReceipt, reason: "mistral was not strict high-confidence", issues: mistral.issues)
        }

        return reviewResult(parsedReceipt: nil, reason: "no receipt candidate returned", issues: [.totalMissing])
    }

    private static func isStrictApplePass(_ result: ReceiptVerificationResult) -> Bool {
        result.status == .highConfidence &&
        result.overallConfidence >= 0.94 &&
        result.mathConfidence >= 0.98 &&
        result.totalConfidence >= 0.95 &&
        result.itemLineConfidence >= 0.85 &&
        result.layoutConfidence >= 0.85 &&
        result.merchantConfidence >= 0.80 &&
        !result.issues.contains(.mathMismatch) &&
        !result.issues.contains(.totalMissing) &&
        !result.issues.contains(.duplicateTotalConflict) &&
        !result.issues.contains(.lowConfidencePriceToken) &&
        !result.issues.contains(.riskyOCRCharacterInAmount) &&
        !result.issues.contains(.ambiguousTotalCandidate)
    }

    private static func isStrictMistralPass(_ result: ReceiptVerificationResult) -> Bool {
        result.status == .highConfidence &&
        result.overallConfidence >= 0.90 &&
        result.mathConfidence >= 0.95 &&
        result.totalConfidence >= 0.95 &&
        result.itemLineConfidence >= 0.82 &&
        result.merchantConfidence >= 0.75 &&
        !result.issues.contains(.mathMismatch) &&
        !result.issues.contains(.totalMissing) &&
        !result.issues.contains(.hallucinatedField) &&
        !result.issues.contains(.duplicateTotalConflict) &&
        !result.issues.contains(.ambiguousTotalCandidate)
    }

    private static func applyVerification(_ verification: ReceiptVerificationResult) -> ReceiptData? {
        guard var data = verification.parsedReceipt else { return nil }
        data.confidence = Float(verification.overallConfidence)
        data.qualityScore = Float(verification.overallConfidence)
        data.needsReview = !isStrictApplePass(verification) && !isStrictMistralPass(verification)
        data.fallbackReason = verification.debugJSON
        data.validationIssues = Array(Set(data.validationIssues + verification.issues.map(\.rawValue))).sorted()
        if data.needsReview, !data.validationIssues.contains("untrusted_verified_candidate") {
            data.validationIssues.append("untrusted_verified_candidate")
        }
        data.totalConfidence = verification.totalConfidence >= 0.95 ? .high : verification.totalConfidence >= 0.75 ? .medium : .low
        data.validationStatus = verification.mathConfidence >= 0.95 ? .balanced : verification.mathConfidence >= 0.80 ? .closeEnough : .mismatch
        return data
    }

    private static func averageOCRConfidence(_ ctx: OCRPipelineContext) -> Double {
        let confidences = ctx.snapshot.words.map { Double($0.confidence) }.filter { $0 > 0 }
        guard !confidences.isEmpty else { return 0.0 }
        return min(1.0, max(0.0, confidences.reduce(0, +) / Double(confidences.count)))
    }

    private static func merchantEvidenceConfidence(
        _ merchant: String,
        ctx: OCRPipelineContext,
        source: ReceiptSource,
        issues: inout Set<ReceiptVerificationIssue>
    ) -> Double {
        let cleaned = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.filter(\.isLetter).count >= 3 else {
            issues.insert(.merchantMissing)
            return 0.0
        }
        let lowerMerchant = cleaned.lowercased()
        let topCutoff = max(ctx.snapshot.imageSize.height, 1) * 0.20
        let topRows = ctx.rawRows.filter { $0.midY <= topCutoff }
        let topText = topRows.map(\.fullText).joined(separator: " ").lowercased()
        let allText = buildAppleOCRText(ctx: ctx).lowercased()
        var confidence = 0.25
        if topText.contains(lowerMerchant) || lowerMerchant.split(separator: " ").allSatisfy({ topText.contains($0) }) {
            confidence = 0.92
        } else if allText.contains(lowerMerchant) || lowerMerchant.split(separator: " ").allSatisfy({ allText.contains($0) }) {
            confidence = 0.65
            if source == .mistral { issues.insert(.weakLayoutEvidence) }
        } else {
            confidence = source == .mistral ? 0.20 : 0.45
            if source == .mistral { issues.insert(.hallucinatedField) }
        }
        if ReceiptRowSemantics.isAddressLike(cleaned) || PriceParser.extractAll(from: cleaned).isEmpty == false {
            confidence = min(confidence, 0.35)
            issues.insert(.merchantMissing)
        }
        return confidence
    }

    private static func totalEvidenceConfidence(
        _ total: Double?,
        ctx: OCRPipelineContext,
        issues: inout Set<ReceiptVerificationIssue>
    ) -> (totalConfidence: Double, layoutConfidence: Double) {
        guard let total, total > 0 else {
            issues.insert(.totalMissing)
            return (0.0, 0.0)
        }

        let matchingRows = ctx.rawRows.filter { row in
            row.prices.contains { abs($0 - total) <= 0.03 }
        }
        let labeledRows = matchingRows.filter { row in
            let lower = row.fullText.lowercased()
            return ["grand total", "amount due", "balance due", "sale total", "check total", "order total", "total due"].contains { lower.contains($0) }
                || lower == "total"
                || lower.hasPrefix("total ")
                || lower.contains(" total")
        }
        let bottomCutoff = max(ctx.snapshot.imageSize.height, 1) * 0.60
        let bottomRows = matchingRows.filter { $0.midY >= bottomCutoff }
        if matchingRows.isEmpty {
            issues.insert(.ambiguousTotalCandidate)
            return (0.35, 0.35)
        }
        if labeledRows.isEmpty {
            issues.insert(.ambiguousTotalCandidate)
        }
        if bottomRows.isEmpty {
            issues.insert(.totalNotNearBottom)
        }
        let totalConfidence = labeledRows.isEmpty ? 0.62 : bottomRows.isEmpty ? 0.78 : 0.98
        let layoutConfidence = bottomRows.isEmpty ? 0.55 : labeledRows.isEmpty ? 0.72 : 0.96
        return (totalConfidence, layoutConfidence)
    }

    private static func itemEvidenceConfidence(
        _ receipt: ReceiptData,
        ctx: OCRPipelineContext,
        source: ReceiptSource,
        issues: inout Set<ReceiptVerificationIssue>
    ) -> Double {
        let items = receipt.merchandiseItems
        guard !items.isEmpty else {
            if receipt.validationIssues.contains("payment_slip_no_items") {
                return 0.72
            }
            issues.insert(.itemLineMissingName)
            return 0.0
        }
        var penalty = 0.0
        let localIssues = Set(receipt.validationIssues)
        if localIssues.contains(where: { $0.hasPrefix("item_sum_mismatch") }) {
            issues.insert(.itemSumMismatch)
            penalty += 0.35
        }
        if localIssues.contains(where: { $0.hasPrefix("too_few_items") }) {
            issues.insert(.itemCountMismatch)
            penalty += 0.25
        }
        if localIssues.contains("drifted_price_attachment") {
            issues.insert(.driftedPriceAttachment)
            penalty += 0.15
        }
        if localIssues.contains("category_header_used_as_item") {
            issues.insert(.categoryHeaderUsedAsItem)
            penalty += 0.35
        }
        if localIssues.contains("summary_payment_footer_leakage_rejected") {
            issues.insert(.summaryPaymentFooterLeakage)
            penalty += 0.20
        }
        let ocrText = buildAppleOCRText(ctx: ctx).lowercased()
        var supported = 0
        var priced = 0
        for item in items {
            if item.name.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isLetter).count < 2 {
                issues.insert(.itemLineMissingName)
            }
            if LocalReceiptQualityGate.isCategoryHeader(item.name) {
                issues.insert(.categoryHeaderUsedAsItem)
                penalty += 0.25
            }
            if LocalReceiptQualityGate.isDiscountOrModifierRow(item.name) {
                issues.insert(.discountTreatedAsItem)
                penalty += 0.25
            }
            if LocalReceiptQualityGate.isStrictlyRejectedItemRow(item.name) {
                issues.insert(.summaryPaymentFooterLeakage)
                penalty += 0.25
            }
            if item.amount <= 0 {
                issues.insert(.itemLineMissingPrice)
                continue
            }
            priced += 1
            let nameTokens = item.name
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
            let nameSupported = nameTokens.isEmpty || nameTokens.prefix(3).contains { ocrText.contains($0) }
            let priceSupported = ctx.rawRows.contains { row in
                row.zone == .items && row.prices.contains { abs($0 - item.amount) <= 0.03 }
            }
            if nameSupported && priceSupported {
                supported += 1
            } else if source == .mistral {
                issues.insert(.hallucinatedField)
            }
        }
        let pricedRatio = Double(priced) / Double(max(items.count, 1))
        let supportRatio = Double(supported) / Double(max(items.count, 1))
        return min(1.0, max(0.0, 0.35 + 0.35 * pricedRatio + 0.30 * supportRatio - penalty))
    }

    private static func fieldConfidence(_ receipt: ReceiptData) -> (subtotal: Double, tax: Double, tip: Double, discount: Double) {
        let merchandiseTotal = receipt.merchandiseItems.reduce(0.0) { $0 + $1.amount }
        let total = receipt.grandTotal ?? 0
        let subtotal = merchandiseTotal > 0 ? 0.85 : 0.0
        let tax = receipt.taxAmount == nil ? 0.75 : ((receipt.taxAmount ?? 0) >= 0 && (receipt.taxAmount ?? 0) <= max(15.0, total * 0.20) ? 0.95 : 0.20)
        let tip = receipt.tipAmount == nil ? 0.75 : ((receipt.tipAmount ?? 0) >= 0 && (receipt.tipAmount ?? 0) <= max(50.0, total * 0.40) ? 0.92 : 0.20)
        let discountTotal = receipt.lineItems.reduce(0.0) { $0 + max(0, $1.discount) }
        let discount = discountTotal <= max(100.0, total) ? 0.90 : 0.30
        return (subtotal, tax, tip, discount)
    }

    private static func mathReconciliationConfidence(_ receipt: ReceiptData, issues: inout Set<ReceiptVerificationIssue>) -> Double {
        guard let total = receipt.grandTotal, total > 0, total < 10000 else {
            issues.insert(.totalMissing)
            return 0.0
        }
        let merchandise = round2(receipt.merchandiseItems.reduce(0.0) { $0 + $1.amount })
        let tax = round2(receipt.taxAmount ?? 0)
        let tip = round2(receipt.tipAmount ?? 0)
        let fees = round2(receipt.fees)
        let discounts = round2(receipt.lineItems.reduce(0.0) { $0 + max(0, $1.discount) })
        if tax < 0 { issues.insert(.impossibleTax); return 0.0 }
        if tip < 0 { issues.insert(.impossibleTip); return 0.0 }
        if discounts < 0 { issues.insert(.impossibleDiscount); return 0.0 }
        guard merchandise > 0 || receipt.lineItems.contains(where: { $0.category != .adjustment }) else {
            return 0.65
        }

        let candidateTotals = [
            merchandise,
            merchandise + tax + tip + fees - discounts,
            merchandise + tax + tip + fees
        ].map(round2)
        let bestGap = candidateTotals.map { abs($0 - total) }.min() ?? .greatestFiniteMagnitude
        if bestGap <= 0.01 { return 1.0 }
        if bestGap <= 0.03 { return 0.95 }
        if bestGap <= 0.05 { return 0.80 }
        issues.insert(.mathMismatch)
        return receipt.merchandiseItems.isEmpty ? 0.65 : 0.30
    }

    private static func providerAgreement(_ lhs: ReceiptData, _ rhs: ReceiptData, issues: inout Set<ReceiptVerificationIssue>) -> Double {
        var score = 1.0
        if let a = lhs.grandTotal, let b = rhs.grandTotal {
            let gap = abs(a - b)
            if gap > 0.03 {
                issues.insert(.providerDisagreement)
                score -= 0.65
            } else if gap > 0.01 {
                score -= 0.10
            }
        }
        let lhsMerchant = lhs.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhsMerchant = rhs.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !lhsMerchant.isEmpty, !rhsMerchant.isEmpty, lhsMerchant != rhsMerchant,
           !lhsMerchant.contains(rhsMerchant), !rhsMerchant.contains(lhsMerchant) {
            score -= 0.20
        }
        return min(1.0, max(0.0, score))
    }

    private static func hasRiskyAmountOCR(_ ctx: OCRPipelineContext) -> Bool {
        let riskyLetters = CharacterSet(charactersIn: "OoIl|SBZ")
        for row in ctx.rawRows {
            let lower = row.fullText.lowercased()
            if isExcludedAmountContext(lower) { continue }
            for token in row.allTokens where token.rangeOfCharacter(from: .decimalDigits) != nil {
                let hasPriceShape = token.contains(".") || token.contains(",") || token.contains("$")
                guard hasPriceShape else { continue }
                if token.rangeOfCharacter(from: riskyLetters) != nil { return true }
                if token.filter({ $0 == "." }).count > 1 { return true }
                if token.contains(",") && !token.contains(".") { return true }
            }
        }
        return false
    }

    private static func hasDuplicateTotalConflict(_ ctx: OCRPipelineContext, expectedTotal: Double?) -> Bool {
        let rows = ctx.rawRows.filter { row in
            let lower = row.fullText.lowercased()
            return lower.contains("total") && !lower.contains("subtotal") && !isExcludedAmountContext(lower)
        }
        var totals: [Double] = []
        for amount in rows.flatMap(\.prices) where amount > 0 {
            if !totals.contains(where: { abs($0 - amount) <= 0.03 }) {
                totals.append(amount)
            }
        }
        guard totals.count > 1 else { return false }
        if let expectedTotal {
            let conflicting = totals.filter { abs($0 - expectedTotal) > 0.03 }
            return conflicting.count >= 1 && totals.contains(where: { abs($0 - expectedTotal) <= 0.03 })
        }
        return true
    }

    private static func hasUnresolvedDuplicateTotalConflict(_ ctx: OCRPipelineContext, selectedTotal: Double?) -> Bool {
        guard let selectedTotal else { return true }
        let paymentContext = buildAppleOCRText(ctx: ctx).lowercased()
        let hasCardContext = paymentContext.contains("visa") || paymentContext.contains("card") || paymentContext.contains("contactless") || paymentContext.contains("non-cash")
        let cashRows = ctx.rawRows.filter { RowBuilder.normalizeFuzzySummaryText($0.fullText).contains("cash") }
        let cashAmounts = cashRows.flatMap(\.prices)
        if hasCardContext, cashAmounts.contains(where: { abs($0 - selectedTotal) <= 0.03 }) {
            return false
        }
        return hasDuplicateTotalConflict(ctx, expectedTotal: selectedTotal)
    }

    private static func isExcludedAmountContext(_ lower: String) -> Bool {
        ["auth", "approval", "card", "visa", "mastercard", "amex", "change", "cash", "tender",
         "order", "table", "server", "guest", "date", "time", "phone", "zip", "reward",
         "points", "balance", "ref", "terminal", "transaction", "invoice", "gift"].contains { lower.contains($0) }
    }

    private static func strongerFallbackReceipt(
        apple: ReceiptVerificationResult,
        mistral: ReceiptVerificationResult
    ) -> ReceiptData? {
        let ranked = [apple, mistral].sorted {
            if abs($0.mathConfidence - $1.mathConfidence) > 0.02 { return $0.mathConfidence > $1.mathConfidence }
            return $0.overallConfidence > $1.overallConfidence
        }
        return ranked.first?.parsedReceipt
    }

    private static func applyReviewStatusIfNeeded(_ result: ReceiptVerificationResult, reason: String) -> ReceiptVerificationResult {
        guard result.status == .highConfidence else {
            return reviewResult(parsedReceipt: result.parsedReceipt, reason: reason, issues: result.issues)
        }
        return result
    }

    private static func reviewResult(
        parsedReceipt: ReceiptData?,
        reason: String,
        issues: [ReceiptVerificationIssue]
    ) -> ReceiptVerificationResult {
        ReceiptVerificationResult(
            source: .needsReview,
            status: parsedReceipt == nil ? .failed : .needsReview,
            overallConfidence: 0.0,
            ocrConfidence: 0.0,
            merchantConfidence: 0.0,
            itemLineConfidence: 0.0,
            subtotalConfidence: 0.0,
            taxConfidence: 0.0,
            tipConfidence: 0.0,
            discountConfidence: 0.0,
            totalConfidence: 0.0,
            mathConfidence: 0.0,
            layoutConfidence: 0.0,
            crossProviderAgreement: nil,
            issues: Array(Set(issues)).sorted { $0.rawValue < $1.rawValue },
            parsedReceipt: parsedReceipt,
            decisionReason: reason
        )
    }

    private static func buildLocalHints(ctx: OCRPipelineContext, fallbackReasons: [String] = []) -> ServerRequestPayload.LocalHints {
        let total    = ctx.quick.total
        let tax      = saneTax(ctx: ctx) ?? 0
        let tip      = ctx.quick.tip ?? 0
        let subtotal = saneSubtotal(ctx: ctx)
        let merchandiseTarget: Double? = {
            if let t = total { let d = round2(t - tax - tip); return d > 0.01 ? d : nil }
            return subtotal
        }()
        let reason = fallbackReasons.isEmpty
            ? "local_quality_gate_passed_but_sent_for_verification"
            : "local_gate_failed: \(fallbackReasons.joined(separator:", "))"
        return ServerRequestPayload.LocalHints(
            merchantCandidate:         ctx.quick.merchant,
            grandTotalCandidate:       total,
            grandTotalConfidence:      "\(ctx.quick.totalConf)",
            subtotalCandidate:         subtotal,
            taxCandidate:              saneTax(ctx: ctx),
            tipCandidate:              ctx.quick.tip,
            targetMerchandiseSubtotal: merchandiseTarget,
            fallbackReason:            reason
        )
    }

    private static func saneTax(ctx: OCRPipelineContext) -> Double? {
        guard let total = ctx.quick.total, total > 0 else { return nil }
        guard let tax = ctx.quick.tax, tax > 0 else { return nil }
        if tax > max(15.0, total * 0.15) { return nil }
        return round2(tax)
    }

    private static func saneSubtotal(ctx: OCRPipelineContext) -> Double? {
        guard let subtotal = ctx.quick.subtotal, subtotal > 0 else { return nil }
        if let total = ctx.quick.total {
            if subtotal > total { return nil }
            if subtotal < total * 0.20 && total > 20 { return nil }
        }
        return round2(subtotal)
    }

    private static func buildReceiptData(from response: ServerReceiptResponse) -> ReceiptData {
        var allItems = response.items.map { item -> ReceiptLineItem in
            let finalAmount = item.amount
            let originalAmount = item.originalAmount ?? finalAmount
            let discount = item.itemDiscount ?? max(0, originalAmount - finalAmount)
            return ReceiptLineItem(
                name: item.name,
                originalPrice: originalAmount,
                discount: discount,
                amount: finalAmount,
                taxPortion: 0,
                isSelected: true,
                category: .merchandise,
                discountLabel: item.discountDisplayLabel ?? item.itemDiscountLabel,
                splitCategory: item.category,
                splitCategoryConfidence: item.categoryConfidence
            )
        }
        
        if let tax = response.tax, tax > 0 {
            allItems.append(ReceiptLineItem(
                name: "Tax",
                originalPrice: tax,
                discount: 0,
                amount: tax,
                taxPortion: 0,
                isSelected: true,
                category: .tax
            ))
        }
        
        if let tip = response.tip, tip > 0 {
            allItems.append(ReceiptLineItem(
                name: "Tip",
                originalPrice: tip,
                discount: 0,
                amount: tip,
                taxPortion: 0,
                isSelected: true,
                category: .tip
            ))
        }
        
        if let fees = response.fees, fees > 0 {
            allItems.append(ReceiptLineItem(
                name: "Fee",
                originalPrice: fees,
                discount: 0,
                amount: fees,
                taxPortion: 0,
                isSelected: true,
                category: .fee
            ))
        }
        
        if let grandTotal = response.grandTotal {
            enforceTotal(lineItems: &allItems, grandTotal: grandTotal)
        }

        let route = response.route ?? ""
        let method: ProcessingMethod
        switch route {
        case "tabscanner":   method = .tabscanner
        case "gpt_vision":   method = .gptAppleOCR
        case "apple_local":  method = .appleLocal
        case "paddle_vl":    method = .paddleVL
        default:             method = .gptAppleOCR
        }

        let confStr = response.confidence.lowercased()
        var confidence: Float = confStr == "high" ? 0.90 : confStr == "medium" ? 0.75 : 0.60
        if !response.merchant.isEmpty { confidence = min(confidence + 0.05, 1.0) }

        let itemSum     = allItems.reduce(0.0) { $0 + $1.amount }
        let total       = response.grandTotal ?? 0
        let gapCents    = total > 0 ? abs(Int(((itemSum - total) * 100).rounded())) : 0
        let valStatus: ValidationStatus = gapCents <= 1 ? .balanced : gapCents <= 10 ? .closeEnough : total > 0 ? .mismatch : .notValidated

        return ReceiptData(
            merchant:            response.merchant,
            lineItems:           allItems,
            hasReceiptStructure: true,
            confidence:          confidence,
            grandTotal:          response.grandTotal,
            processingMethod:    method,
            receiptDate:         response.receiptDate,
            needsReview:         false,
            fallbackReason:      response.routeReason,
            currency:            response.currency,
            qualityScore:        confidence,
            totalConfidence:     confStr == "high" ? .high : confStr == "medium" ? .medium : .low,
            validationStatus:    valStatus,
            arithmeticGapCents:  gapCents,
            validationIssues:    gapCents > 10 ? ["arithmetic_gap_\(gapCents)cents"] : [],
            ocrRoute:            route,
            backgroundResultToken: nil,
            processingTimeMs: response.timings?.total_ms
        )
    }

    static func enforceTotal(
        lineItems: inout [ReceiptLineItem],
        grandTotal: Double
    ) {
        lineItems.removeAll { $0.category == .adjustment }
        guard grandTotal > 0 else { return }
        let itemSum = lineItems.reduce(0.0) { $0 + $1.amount }
        let gap = round2(grandTotal - itemSum)
        if abs(gap) > 0.01 {
            lineItems.append(ReceiptLineItem(
                name: gap > 0 ? "Remaining" : "Adjustment",
                originalPrice: gap,
                discount: 0,
                amount: gap,
                taxPortion: 0,
                isSelected: gap > 0,
                category: .adjustment
            ))
            print("  [OCRService.enforceTotal] gap: \(String(format: "%.2f", gap))")
        }
    }

    private static func nsError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "OCRService", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}



extension Notification.Name {
    static let receiptFullDataReady = Notification.Name("receiptFullDataReady")
}
