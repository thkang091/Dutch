import UIKit
import Vision

private enum VisionOCRUtilities {
    nonisolated static func elapsedMs(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    nonisolated static func orientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

struct VisionOCRResult {
    let words: [OCRWord]
    let rawLines: [String]
    let visionMs: Double
}

final class VisionOCRService {
    nonisolated func recognizeWords(from image: UIImage) -> VisionOCRResult? {
        guard let cgImage = image.cgImage else { return nil }

        var observations: [VNRecognizedTextObservation] = []
        let sema = DispatchSemaphore(value: 0)
        let visionStart = CFAbsoluteTimeGetCurrent()

        let request = VNRecognizeTextRequest { request, _ in
            defer { sema.signal() }
            observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.005

        do {
            try VNImageRequestHandler(
                cgImage: cgImage,
                orientation: VisionOCRUtilities.orientation(for: image.imageOrientation),
                options: [:]
            ).perform([request])
        } catch {
            print("  [VisionOCRService] recognizeWords failed: \(error.localizedDescription)")
            return nil
        }
        sema.wait()

        guard !observations.isEmpty else { return nil }

        var words: [OCRWord] = []
        var rawLines: [String] = []
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        for observation in observations {
            let candidates = observation.topCandidates(5)
            guard let top = candidates.first else { continue }
            let chosen = Self.correctedPriceCandidate(top: top, candidates: candidates)
            let alternateCandidates = candidates.map(\.string)
            let boundingBox = observation.boundingBox
            let imageRect = CGRect(
                x: boundingBox.origin.x * imageWidth,
                y: (1.0 - boundingBox.origin.y - boundingBox.height) * imageHeight,
                width: boundingBox.width * imageWidth,
                height: boundingBox.height * imageHeight
            )
            words.append(OCRWord(text: chosen.string, confidence: chosen.confidence, rect: imageRect, recognizedText: chosen, alternateCandidates: alternateCandidates))
            rawLines.append(chosen.string)
        }

        let rowSortThreshold = max(2, imageHeight * 0.002)
        words.sort {
            if abs($0.midY - $1.midY) > rowSortThreshold { return $0.midY < $1.midY }
            return $0.midX < $1.midX
        }

        return VisionOCRResult(words: words, rawLines: rawLines, visionMs: VisionOCRUtilities.elapsedMs(since: visionStart))
    }

    nonisolated static func fastWordCount(from image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        var observations: [VNRecognizedTextObservation] = []
        let sema = DispatchSemaphore(value: 0)
        let request = VNRecognizeTextRequest { request, _ in
            defer { sema.signal() }
            observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.005
        do {
            try VNImageRequestHandler(
                cgImage: cgImage,
                orientation: VisionOCRUtilities.orientation(for: image.imageOrientation),
                options: [:]
            ).perform([request])
        } catch {
            print("  [VisionOCRService] fastWordCount failed: \(error.localizedDescription)")
            return 0
        }
        sema.wait()
        return observations.reduce(0) { count, observation in
            guard let text = observation.topCandidates(1).first?.string else { return count }
            return count + text.split(separator: " ").count
        }
    }

    private nonisolated static func correctedPriceCandidate(top: VNRecognizedText, candidates: [VNRecognizedText]) -> VNRecognizedText {
        let topTokens = top.string.split(separator: " ").map(String.init)
        guard topTokens.contains(where: { hasPriceShapeShadow($0) && !PriceParser.looksLikePrice($0) }) else {
            return top
        }
        for candidate in candidates.dropFirst() {
            let altTokens = candidate.string.split(separator: " ").map(String.init)
            guard altTokens.count == topTokens.count else { continue }
            for index in altTokens.indices {
                let topToken = topTokens[index]
                let altToken = altTokens[index]
                guard PriceParser.looksLikePrice(altToken),
                      !PriceParser.looksLikePrice(topToken),
                      differsOnlyByPriceConfusables(topToken, altToken) else { continue }
                print("  [VisionOCRService] price candidate correction '\(topToken)' -> '\(altToken)'")
                return candidate
            }
        }
        return top
    }

    private nonisolated static func hasPriceShapeShadow(_ token: String) -> Bool {
        let digits = token.filter(\.isNumber).count
        guard digits >= 2 else { return false }
        return token.contains(".")
            || token.contains(",")
            || token.contains("-")
            || token.contains("_")
            || Double(digits) / Double(max(token.count, 1)) >= 0.5
    }

    private nonisolated static func differsOnlyByPriceConfusables(_ lhs: String, _ rhs: String) -> Bool {
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

    private nonisolated static func arePriceConfusable(_ a: Character, _ b: Character) -> Bool {
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
