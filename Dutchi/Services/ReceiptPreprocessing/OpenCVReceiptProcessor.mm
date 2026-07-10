#import "OpenCVReceiptProcessor.h"

#import <CoreFoundation/CoreFoundation.h>
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/photo.hpp>
#import <opencv2/imgcodecs/ios.h>

@implementation OpenCVReceiptDetectionResult
@end

@implementation OpenCVReceiptQualityResult
@end

@implementation OpenCVReceiptPreprocessResult
@end

namespace {

static double elapsedMs(CFAbsoluteTime start) {
    return (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
}

static UIImage *normalizedImage(UIImage *image) {
    if (image.imageOrientation == UIImageOrientationUp) {
        return image;
    }
    UIGraphicsBeginImageContextWithOptions(image.size, YES, image.scale);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

static cv::Mat matFromImage(UIImage *image) {
    cv::Mat rgba;
    UIImageToMat(normalizedImage(image), rgba);
    if (rgba.empty()) {
        return rgba;
    }
    cv::Mat bgr;
    if (rgba.channels() == 4) {
        cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);
    } else if (rgba.channels() == 1) {
        cv::cvtColor(rgba, bgr, cv::COLOR_GRAY2BGR);
    } else {
        bgr = rgba;
    }
    return bgr;
}

static UIImage *imageFromMat(const cv::Mat &mat) {
    cv::Mat rgba;
    if (mat.channels() == 1) {
        cv::cvtColor(mat, rgba, cv::COLOR_GRAY2RGBA);
    } else if (mat.channels() == 3) {
        cv::cvtColor(mat, rgba, cv::COLOR_BGR2RGBA);
    } else {
        rgba = mat;
    }
    return MatToUIImage(rgba);
}

static std::vector<cv::Point2f> orderCorners(std::vector<cv::Point2f> points) {
    std::vector<cv::Point2f> ordered(4);
    double minSum = DBL_MAX, maxSum = -DBL_MAX, minDiff = DBL_MAX, maxDiff = -DBL_MAX;
    for (const auto &p : points) {
        const double sum = p.x + p.y;
        const double diff = p.x - p.y;
        if (sum < minSum) { minSum = sum; ordered[0] = p; }
        if (sum > maxSum) { maxSum = sum; ordered[2] = p; }
        if (diff > maxDiff) { maxDiff = diff; ordered[1] = p; }
        if (diff < minDiff) { minDiff = diff; ordered[3] = p; }
    }
    return ordered;
}

static double distanceBetween(const cv::Point2f &a, const cv::Point2f &b) {
    return std::hypot(a.x - b.x, a.y - b.y);
}

static CGFloat perspectiveDistortionForCorners(const std::vector<cv::Point2f> &ordered) {
    if (ordered.size() != 4) {
        return 0;
    }
    const double top = distanceBetween(ordered[0], ordered[1]);
    const double right = distanceBetween(ordered[1], ordered[2]);
    const double bottom = distanceBetween(ordered[2], ordered[3]);
    const double left = distanceBetween(ordered[3], ordered[0]);
    const double widthSkew = 1.0 - (std::min(top, bottom) / std::max(std::max(top, bottom), 1.0));
    const double heightSkew = 1.0 - (std::min(left, right) / std::max(std::max(left, right), 1.0));
    return (CGFloat)std::min(1.0, (widthSkew + heightSkew) * 0.5);
}

static double polygonArea(const std::vector<cv::Point2f> &points) {
    if (points.size() < 3) {
        return 0;
    }
    double area = 0;
    for (size_t i = 0; i < points.size(); i++) {
        const cv::Point2f &a = points[i];
        const cv::Point2f &b = points[(i + 1) % points.size()];
        area += (double)a.x * (double)b.y - (double)b.x * (double)a.y;
    }
    return std::abs(area) * 0.5;
}

static bool cornersAreSaneReceipt(const std::vector<cv::Point2f> &ordered, cv::Size imageSize) {
    if (ordered.size() != 4) {
        return false;
    }
    const double area = polygonArea(ordered);
    const double imageArea = (double)imageSize.width * (double)imageSize.height;
    if (area < imageArea * 0.006 || area > imageArea * 0.62) {
        return false;
    }

    const double top = distanceBetween(ordered[0], ordered[1]);
    const double right = distanceBetween(ordered[1], ordered[2]);
    const double bottom = distanceBetween(ordered[2], ordered[3]);
    const double left = distanceBetween(ordered[3], ordered[0]);
    const double longSide = std::max(std::max(top, bottom), std::max(left, right));
    const double shortSide = std::max(1.0, std::min(std::min(top, bottom), std::min(left, right)));
    const double aspect = longSide / shortSide;
    return aspect >= 1.25 && aspect <= 8.0;
}

static double textInkDensity(const cv::Mat &grayROI) {
    if (grayROI.empty()) {
        return 0;
    }

    cv::Mat normalized;
    cv::equalizeHist(grayROI, normalized);

    cv::Mat ink;
    cv::adaptiveThreshold(normalized, ink, 255, cv::ADAPTIVE_THRESH_GAUSSIAN_C, cv::THRESH_BINARY_INV, 31, 11);
    cv::morphologyEx(ink, ink, cv::MORPH_OPEN, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(2, 2)));

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(ink, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    double textArea = 0;
    const double roiArea = (double)grayROI.cols * (double)grayROI.rows;
    for (const auto &contour : contours) {
        cv::Rect rect = cv::boundingRect(contour);
        const double area = cv::contourArea(contour);
        if (area < 2 || area > roiArea * 0.08) {
            continue;
        }
        if (rect.height < 3 || rect.height > grayROI.rows * 0.18 || rect.width > grayROI.cols * 0.85) {
            continue;
        }
        textArea += std::max(area, (double)(rect.width * rect.height));
    }

    return std::clamp(textArea / std::max(roiArea, 1.0), 0.0, 0.20);
}

static OpenCVReceiptDetectionResult *objcDetectionFromCorners(
    const std::vector<cv::Point2f> &corners,
    CGRect boundingBox,
    CGSize imageSize,
    CGFloat confidence,
    BOOL hasQuadrilateral
) {
    OpenCVReceiptDetectionResult *result = [OpenCVReceiptDetectionResult new];
    NSMutableArray<NSValue *> *values = [NSMutableArray arrayWithCapacity:corners.size()];
    for (const auto &p : corners) {
        [values addObject:[NSValue valueWithCGPoint:CGPointMake(p.x, p.y)]];
    }
    result.corners = values;
    result.boundingBox = boundingBox;
    result.imageSize = imageSize;
    result.confidence = confidence;
    result.hasQuadrilateral = hasQuadrilateral;
    result.perspectiveDistortion = hasQuadrilateral ? perspectiveDistortionForCorners(corners) : 0;
    return result;
}

static OpenCVReceiptDetectionResult *detectReceipt(const cv::Mat &source) {
    if (source.empty()) {
        return nil;
    }

    const int maxSide = std::max(source.cols, source.rows);
    const double scale = maxSide > 1100 ? 1100.0 / (double)maxSide : 1.0;

    cv::Mat working;
    if (scale < 1.0) {
        cv::resize(source, working, cv::Size(), scale, scale, cv::INTER_AREA);
    } else {
        working = source;
    }

    cv::Mat grayRaw;
    cv::cvtColor(working, grayRaw, cv::COLOR_BGR2GRAY);
    cv::Mat gray;
    cv::GaussianBlur(grayRaw, gray, cv::Size(5, 5), 0);

    const double imageArea = (double)working.cols * (double)working.rows;
    double bestScore = 0;
    double bestArea = 0;
    cv::Rect bestRect(0, 0, working.cols, working.rows);
    std::vector<cv::Point2f> bestCorners;
    bool foundQuad = false;

    std::vector<cv::Mat> masks;
    cv::Mat edges;
    cv::Canny(gray, edges, 45, 140);
    cv::dilate(edges, edges, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 5)));
    cv::morphologyEx(edges, edges, cv::MORPH_CLOSE, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(7, 7)));
    masks.push_back(edges);

    cv::Mat thresholded;
    cv::threshold(gray, thresholded, 0, 255, cv::THRESH_BINARY | cv::THRESH_OTSU);
    cv::morphologyEx(thresholded, thresholded, cv::MORPH_CLOSE, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(9, 9)));
    masks.push_back(thresholded);

    cv::Mat brightMask;
    cv::threshold(gray, brightMask, 138, 255, cv::THRESH_BINARY);
    cv::morphologyEx(brightMask, brightMask, cv::MORPH_CLOSE, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(11, 11)));
    cv::morphologyEx(brightMask, brightMask, cv::MORPH_OPEN, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(3, 3)));
    masks.push_back(brightMask);

    cv::Mat adaptivePaper;
    cv::adaptiveThreshold(gray, adaptivePaper, 255, cv::ADAPTIVE_THRESH_GAUSSIAN_C, cv::THRESH_BINARY, 71, -5);
    cv::morphologyEx(adaptivePaper, adaptivePaper, cv::MORPH_CLOSE, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(13, 13)));
    masks.push_back(adaptivePaper);

    for (const cv::Mat &mask : masks) {
        std::vector<std::vector<cv::Point>> contours;
        cv::findContours(mask, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

        for (const auto &contour : contours) {
            const double area = cv::contourArea(contour);
            if (area < imageArea * 0.006 || area > imageArea * 0.62) {
                continue;
            }

            const double perimeter = cv::arcLength(contour, true);
            if (perimeter <= 0) {
                continue;
            }

            std::vector<cv::Point> approx;
            bool isQuad = false;
            for (double epsilon : {0.018, 0.024, 0.032, 0.045}) {
                cv::approxPolyDP(contour, approx, epsilon * perimeter, true);
                if (approx.size() == 4 && cv::isContourConvex(approx)) {
                    isQuad = true;
                    break;
                }
            }

            std::vector<cv::Point2f> candidateCorners;
            if (isQuad) {
                candidateCorners.reserve(4);
                for (const auto &p : approx) {
                    candidateCorners.push_back(cv::Point2f((float)p.x, (float)p.y));
                }
                candidateCorners = orderCorners(candidateCorners);
            } else {
                cv::RotatedRect minRect = cv::minAreaRect(contour);
                if (minRect.size.width <= 1 || minRect.size.height <= 1) {
                    continue;
                }
                cv::Point2f box[4];
                minRect.points(box);
                candidateCorners.assign(box, box + 4);
                candidateCorners = orderCorners(candidateCorners);
            }

            if (!cornersAreSaneReceipt(candidateCorners, working.size())) {
                continue;
            }

            cv::Rect rect = cv::boundingRect(candidateCorners);
            rect &= cv::Rect(0, 0, working.cols, working.rows);
            const double rectArea = (double)rect.width * (double)rect.height;
            if (rectArea <= 0) {
                continue;
            }

            const double areaRatio = area / imageArea;
            const bool touchesImageFrame =
                rect.x <= working.cols * 0.025 ||
                rect.y <= working.rows * 0.025 ||
                rect.x + rect.width >= working.cols * 0.975 ||
                rect.y + rect.height >= working.rows * 0.975;
            if (touchesImageFrame && areaRatio > 0.34) {
                continue;
            }

            const double aspect = (double)std::max(rect.width, rect.height) / (double)std::max(std::min(rect.width, rect.height), 1);
            const double fillRatio = area / rectArea;
            if (aspect < 1.18 || aspect > 8.0 || fillRatio < 0.30) {
                continue;
            }

            cv::Mat roi = grayRaw(rect);
            cv::Scalar meanValue, stdValue;
            cv::meanStdDev(roi, meanValue, stdValue);
            const double brightness = meanValue[0];
            const double contrast = stdValue[0];
            const double inkDensity = textInkDensity(roi);
            const double brightnessWeight = std::clamp((brightness - 55.0) / 135.0, 0.22, 1.25);
            const double contrastWeight = std::clamp(contrast / 42.0, 0.55, 1.35);
            const double inkWeight = std::clamp(inkDensity / 0.035, 0.32, 2.20);
            const double areaWeight = areaRatio < 0.025 ? 0.58 : (areaRatio > 0.42 ? 0.48 : 1.0);
            const double quadWeight = isQuad ? 1.18 : 0.96;
            const double score = area * fillRatio * brightnessWeight * contrastWeight * inkWeight * areaWeight * quadWeight;

            if (score > bestScore) {
                bestScore = score;
                bestArea = area;
                bestRect = rect;
                bestCorners = candidateCorners;
                foundQuad = true;
            }
        }
    }

    if (!foundQuad) {
        std::vector<std::vector<cv::Point>> contours;
        cv::findContours(edges, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
        double bestFallbackScore = 0;
        for (const auto &contour : contours) {
            const double area = cv::contourArea(contour);
            if (area < imageArea * 0.06) {
                continue;
            }
            cv::Rect rect = cv::boundingRect(contour);
            const double aspect = (double)std::max(rect.width, rect.height) / (double)std::max(std::min(rect.width, rect.height), 1);
            const double score = area * std::min(aspect / 2.0, 2.0);
            if (aspect >= 1.18 && score > bestFallbackScore) {
                bestFallbackScore = score;
                bestRect = rect;
            }
        }
    }

    if (!foundQuad && bestRect.width == working.cols && bestRect.height == working.rows) {
        bestRect = cv::Rect(0, 0, working.cols, working.rows);
    }

    const double inverseScale = 1.0 / scale;
    CGRect originalRect = CGRectMake(
        bestRect.x * inverseScale,
        bestRect.y * inverseScale,
        bestRect.width * inverseScale,
        bestRect.height * inverseScale
    );

    if (foundQuad) {
        for (auto &p : bestCorners) {
            p.x *= inverseScale;
            p.y *= inverseScale;
        }
    }

    const CGSize imageSize = CGSizeMake(source.cols, source.rows);
    const CGFloat confidence = foundQuad
        ? (CGFloat)std::min(1.0, bestArea / std::max(imageArea * 0.42, 1.0))
        : 0.35;
    return objcDetectionFromCorners(bestCorners, originalRect, imageSize, confidence, foundQuad);
}

static std::vector<cv::Point2f> cornersFromDetection(OpenCVReceiptDetectionResult *detection) {
    std::vector<cv::Point2f> corners;
    for (NSValue *value in detection.corners) {
        CGPoint point = value.CGPointValue;
        corners.push_back(cv::Point2f((float)point.x, (float)point.y));
    }
    if (corners.size() == 4) {
        return orderCorners(corners);
    }
    return corners;
}

static cv::Mat perspectiveCorrectOrCrop(const cv::Mat &source, OpenCVReceiptDetectionResult *detection, BOOL *didApplyPerspective) {
    *didApplyPerspective = NO;
    if (source.empty() || detection == nil) {
        return source.clone();
    }

    if (detection.hasQuadrilateral && detection.corners.count == 4) {
        std::vector<cv::Point2f> src = cornersFromDetection(detection);
        const double widthA = distanceBetween(src[2], src[3]);
        const double widthB = distanceBetween(src[1], src[0]);
        const double heightA = distanceBetween(src[1], src[2]);
        const double heightB = distanceBetween(src[0], src[3]);
        int maxWidth = (int)std::round(std::max(widthA, widthB));
        int maxHeight = (int)std::round(std::max(heightA, heightB));
        maxWidth = std::clamp(maxWidth, 320, 2600);
        maxHeight = std::clamp(maxHeight, 420, 3600);

        std::vector<cv::Point2f> dst = {
            cv::Point2f(0, 0),
            cv::Point2f((float)(maxWidth - 1), 0),
            cv::Point2f((float)(maxWidth - 1), (float)(maxHeight - 1)),
            cv::Point2f(0, (float)(maxHeight - 1))
        };

        cv::Mat transform = cv::getPerspectiveTransform(src, dst);
        cv::Mat warped;
        cv::warpPerspective(source, warped, transform, cv::Size(maxWidth, maxHeight), cv::INTER_LINEAR, cv::BORDER_REPLICATE);
        *didApplyPerspective = YES;
        return warped;
    }

    CGRect box = CGRectInset(detection.boundingBox, -detection.boundingBox.size.width * 0.025, -detection.boundingBox.size.height * 0.025);
    int x = std::max(0, (int)std::floor(box.origin.x));
    int y = std::max(0, (int)std::floor(box.origin.y));
    int width = std::min(source.cols - x, (int)std::ceil(box.size.width));
    int height = std::min(source.rows - y, (int)std::ceil(box.size.height));
    if (width <= 0 || height <= 0) {
        return source.clone();
    }
    return source(cv::Rect(x, y, width, height)).clone();
}

static cv::Mat cropTextRegionPreservingMargin(const cv::Mat &source) {
    if (source.empty()) {
        return source.clone();
    }

    cv::Mat gray;
    cv::cvtColor(source, gray, cv::COLOR_BGR2GRAY);

    cv::Mat blurred;
    cv::GaussianBlur(gray, blurred, cv::Size(5, 5), 0);

    cv::Mat paperMask;
    cv::threshold(blurred, paperMask, 0, 255, cv::THRESH_BINARY | cv::THRESH_OTSU);
    cv::Mat closeKernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(15, 15));
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_CLOSE, closeKernel);
    cv::Mat openKernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 5));
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_OPEN, openKernel);

    std::vector<std::vector<cv::Point>> paperContours;
    cv::findContours(paperMask, paperContours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    const double imageArea = (double)source.cols * (double)source.rows;
    double bestPaperScore = 0;
    cv::Rect bestPaperRect;

    for (const auto &contour : paperContours) {
        const double area = cv::contourArea(contour);
        if (area < imageArea * 0.18) {
            continue;
        }

        cv::Rect rect = cv::boundingRect(contour);
        const double rectArea = (double)rect.width * (double)rect.height;
        if (rectArea <= 0) {
            continue;
        }

        const double aspect = (double)std::max(rect.width, rect.height) / (double)std::max(std::min(rect.width, rect.height), 1);
        const double fillRatio = area / rectArea;
        if (aspect < 1.15 || fillRatio < 0.42) {
            continue;
        }

        cv::Mat roi = gray(rect);
        cv::Scalar meanValue, stdValue;
        cv::meanStdDev(roi, meanValue, stdValue);
        const double brightnessBonus = std::clamp(meanValue[0] / 180.0, 0.55, 1.35);
        const double score = area * fillRatio * brightnessBonus;
        if (score > bestPaperScore) {
            bestPaperScore = score;
            bestPaperRect = rect;
        }
    }

    if (bestPaperScore > 0) {
        const int marginX = std::max(10, (int)std::round(bestPaperRect.width * 0.015));
        const int marginY = std::max(10, (int)std::round(bestPaperRect.height * 0.012));
        int x = std::max(0, bestPaperRect.x - marginX);
        int y = std::max(0, bestPaperRect.y - marginY);
        int right = std::min(source.cols, bestPaperRect.x + bestPaperRect.width + marginX);
        int bottom = std::min(source.rows, bestPaperRect.y + bestPaperRect.height + marginY);
        if (right > x && bottom > y) {
            return source(cv::Rect(x, y, right - x, bottom - y)).clone();
        }
    }

    cv::Mat thresholded;
    cv::adaptiveThreshold(gray, thresholded, 255, cv::ADAPTIVE_THRESH_GAUSSIAN_C, cv::THRESH_BINARY_INV, 51, 13);

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(thresholded, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    cv::Rect unionRect;
    bool hasContent = false;
    for (const auto &contour : contours) {
        cv::Rect rect = cv::boundingRect(contour);
        const int area = rect.width * rect.height;
        if (area < 12 || rect.width > source.cols * 0.96 || rect.height > source.rows * 0.96) {
            continue;
        }
        unionRect = hasContent ? (unionRect | rect) : rect;
        hasContent = true;
    }

    if (!hasContent) {
        return source.clone();
    }

    const int marginX = std::max(24, (int)std::round(source.cols * 0.04));
    const int marginY = std::max(24, (int)std::round(source.rows * 0.025));
    int x = std::max(0, unionRect.x - marginX);
    int y = std::max(0, unionRect.y - marginY);
    int right = std::min(source.cols, unionRect.x + unionRect.width + marginX);
    int bottom = std::min(source.rows, unionRect.y + unionRect.height + marginY);
    if (right <= x || bottom <= y) {
        return source.clone();
    }
    return source(cv::Rect(x, y, right - x, bottom - y)).clone();
}

static void rotateReceiptToPortraitIfNeeded(cv::Mat &image) {
    if (!image.empty() && image.cols > image.rows * 1.12) {
        cv::rotate(image, image, cv::ROTATE_90_CLOCKWISE);
    }
}

static cv::Mat makeReceiptPreviewMat(const cv::Mat &source, bool didApplyPerspective) {
    if (source.empty()) {
        return source.clone();
    }

    cv::Mat preview;
    if (source.channels() == 1) {
        cv::cvtColor(source, preview, cv::COLOR_GRAY2BGR);
    } else {
        preview = source.clone();
    }

    if (didApplyPerspective && preview.cols > 16 && preview.rows > 16) {
        const int thickness = std::max(4, (int)std::round(std::min(preview.cols, preview.rows) * 0.012));
        cv::rectangle(
            preview,
            cv::Rect(thickness, thickness, preview.cols - thickness * 2, preview.rows - thickness * 2),
            cv::Scalar(0, 255, 0),
            thickness
        );
    }

    return preview;
}

static cv::Mat enhanceReceiptMat(const cv::Mat &source) {
    if (source.empty()) {
        return source.clone();
    }

    cv::Mat resized = source;
    const int maxSide = std::max(source.cols, source.rows);
    if (maxSide > 2400) {
        const double scale = 2400.0 / (double)maxSide;
        cv::resize(source, resized, cv::Size(), scale, scale, cv::INTER_AREA);
    }

    cv::Mat gray;
    cv::cvtColor(resized, gray, cv::COLOR_BGR2GRAY);

    cv::Mat denoised;
    cv::bilateralFilter(gray, denoised, 5, 38, 38);
    if (std::max(denoised.cols, denoised.rows) <= 1800) {
        cv::fastNlMeansDenoising(denoised, denoised, 5.5f, 7, 21);
    }

    cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(2.2, cv::Size(8, 8));
    cv::Mat equalized;
    clahe->apply(denoised, equalized);

    cv::Scalar meanValue, stdValue;
    cv::meanStdDev(equalized, meanValue, stdValue);
    const double brightness = meanValue[0];
    const double gamma = brightness < 110 ? 0.74 : (brightness > 190 ? 1.18 : 0.92);
    cv::Mat lut(1, 256, CV_8UC1);
    for (int i = 0; i < 256; i++) {
        lut.at<uchar>(i) = cv::saturate_cast<uchar>(std::pow(i / 255.0, gamma) * 255.0);
    }
    cv::Mat gammaCorrected;
    cv::LUT(equalized, lut, gammaCorrected);

    cv::Mat normalized;
    cv::normalize(gammaCorrected, normalized, 0, 255, cv::NORM_MINMAX);

    cv::Mat blurredForSharp;
    cv::GaussianBlur(normalized, blurredForSharp, cv::Size(0, 0), 1.0);

    cv::Mat sharpened;
    cv::addWeighted(normalized, 1.35, blurredForSharp, -0.35, 0, sharpened);

    cv::Mat finalImage;
    cv::medianBlur(sharpened, finalImage, 3);
    return finalImage;
}

static CGFloat estimatedTextHeight(const cv::Mat &gray) {
    if (gray.empty()) {
        return 0;
    }
    cv::Mat thresholded;
    cv::adaptiveThreshold(gray, thresholded, 255, cv::ADAPTIVE_THRESH_GAUSSIAN_C, cv::THRESH_BINARY_INV, 41, 11);

    cv::Mat labels, stats, centroids;
    const int count = cv::connectedComponentsWithStats(thresholded, labels, stats, centroids, 8, CV_32S);
    std::vector<int> heights;
    heights.reserve(std::max(count - 1, 0));

    for (int i = 1; i < count; i++) {
        const int x = stats.at<int>(i, cv::CC_STAT_LEFT);
        const int y = stats.at<int>(i, cv::CC_STAT_TOP);
        const int w = stats.at<int>(i, cv::CC_STAT_WIDTH);
        const int h = stats.at<int>(i, cv::CC_STAT_HEIGHT);
        const int area = stats.at<int>(i, cv::CC_STAT_AREA);
        (void)x; (void)y;
        if (area < 8 || area > gray.cols * gray.rows * 0.02) {
            continue;
        }
        if (h < 5 || h > gray.rows * 0.08 || w > gray.cols * 0.45) {
            continue;
        }
        heights.push_back(h);
    }

    if (heights.empty()) {
        return 0;
    }
    std::sort(heights.begin(), heights.end());
    return (CGFloat)heights[heights.size() / 2];
}

static OpenCVReceiptQualityResult *analyzeQuality(const cv::Mat &source, CGFloat perspectiveDistortion) {
    cv::Mat gray;
    if (source.channels() == 1) {
        gray = source;
    } else {
        cv::cvtColor(source, gray, cv::COLOR_BGR2GRAY);
    }

    cv::Mat laplacian;
    cv::Laplacian(gray, laplacian, CV_64F);
    cv::Scalar lapMean, lapStd;
    cv::meanStdDev(laplacian, lapMean, lapStd);

    cv::Scalar grayMean, grayStd;
    cv::meanStdDev(gray, grayMean, grayStd);

    const double blurVariance = lapStd[0] * lapStd[0];
    const double brightness = grayMean[0];
    const double contrast = grayStd[0];
    const double textHeight = estimatedTextHeight(gray);

    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    double score = 100.0;

    if (blurVariance < 35) {
        score -= 34;
        [reasons addObject:@"Image is too blurry. Hold the phone steady and retake the photo."];
    } else if (blurVariance < 75) {
        score -= 16;
    }

    if (brightness < 65) {
        score -= 22;
        [reasons addObject:@"Image is too dark. Retake with more light."];
    } else if (brightness > 225) {
        score -= 18;
        [reasons addObject:@"Image is overexposed. Avoid glare and retake the photo."];
    }

    if (contrast < 28) {
        score -= 20;
        [reasons addObject:@"Text contrast is low. Retake with the receipt on a plain background."];
    } else if (contrast < 38) {
        score -= 9;
    }

    if (textHeight > 0 && textHeight < 9) {
        score -= 20;
        [reasons addObject:@"Receipt text is too small. Move closer and retake the photo."];
    } else if (textHeight > 0 && textHeight < 13) {
        score -= 8;
    }

    score -= std::min(18.0, (double)perspectiveDistortion * 24.0);
    if (perspectiveDistortion > 0.45) {
        [reasons addObject:@"Receipt angle is too steep. Retake from directly above."];
    }

    score = std::clamp(score, 0.0, 100.0);

    OpenCVReceiptQualityResult *result = [OpenCVReceiptQualityResult new];
    result.blurVariance = blurVariance;
    result.brightness = brightness;
    result.contrast = contrast;
    result.estimatedTextHeight = textHeight;
    result.perspectiveDistortion = perspectiveDistortion;
    result.qualityScore = score;
    result.shouldRetake = score < 55 || blurVariance < 35 || brightness < 45 || brightness > 238 || (textHeight > 0 && textHeight < 7);
    result.retakeReasons = reasons;
    return result;
}

static void upscaleIfNeeded(cv::Mat &image, OpenCVReceiptQualityResult *quality, BOOL *didUpscale, CGFloat *scaleFactor) {
    *didUpscale = NO;
    *scaleFactor = 1.0;
    if (image.empty()) {
        return;
    }

    CGFloat estimatedHeight = quality.estimatedTextHeight;
    if (estimatedHeight <= 0 || estimatedHeight >= 16) {
        return;
    }

    const int maxSide = std::max(image.cols, image.rows);
    CGFloat factor = estimatedHeight < 10 ? 2.0 : 1.5;
    if ((CGFloat)maxSide * factor > 3000) {
        factor = 3000.0 / (CGFloat)maxSide;
    }
    if (factor <= 1.05) {
        return;
    }

    cv::resize(image, image, cv::Size(), factor, factor, cv::INTER_CUBIC);
    *didUpscale = YES;
    *scaleFactor = factor;
}

} // namespace

@implementation OpenCVReceiptProcessor

+ (nullable OpenCVReceiptDetectionResult *)detectReceiptInImage:(UIImage *)image {
    cv::Mat source = matFromImage(image);
    return detectReceipt(source);
}

+ (UIImage *)correctPerspectiveInImage:(UIImage *)image detection:(OpenCVReceiptDetectionResult *)detection {
    cv::Mat source = matFromImage(image);
    BOOL didApplyPerspective = NO;
    cv::Mat corrected = perspectiveCorrectOrCrop(source, detection, &didApplyPerspective);
    cv::Mat cropped = cropTextRegionPreservingMargin(corrected);
    rotateReceiptToPortraitIfNeeded(cropped);
    return imageFromMat(cropped);
}

+ (UIImage *)enhanceReceiptImage:(UIImage *)image {
    cv::Mat source = matFromImage(image);
    cv::Mat enhanced = enhanceReceiptMat(source);
    return imageFromMat(enhanced);
}

+ (OpenCVReceiptQualityResult *)analyzeQualityInImage:(UIImage *)image perspectiveDistortion:(CGFloat)perspectiveDistortion {
    cv::Mat source = matFromImage(image);
    return analyzeQuality(source, perspectiveDistortion);
}

+ (nullable OpenCVReceiptPreprocessResult *)preprocessReceiptImage:(UIImage *)image {
    cv::Mat source = matFromImage(image);
    if (source.empty()) {
        return nil;
    }

    CFAbsoluteTime totalStart = CFAbsoluteTimeGetCurrent();

    CFAbsoluteTime detectStart = CFAbsoluteTimeGetCurrent();
    OpenCVReceiptDetectionResult *detection = detectReceipt(source);
    double detectMs = elapsedMs(detectStart);
    if (detection == nil) {
        detection = objcDetectionFromCorners({}, CGRectMake(0, 0, source.cols, source.rows), CGSizeMake(source.cols, source.rows), 0, NO);
    }

    CFAbsoluteTime correctStart = CFAbsoluteTimeGetCurrent();
    BOOL didApplyPerspective = NO;
    cv::Mat corrected = perspectiveCorrectOrCrop(source, detection, &didApplyPerspective);
    double correctionMs = elapsedMs(correctStart);

	    CFAbsoluteTime cropStart = CFAbsoluteTimeGetCurrent();
	    cv::Mat cropped = cropTextRegionPreservingMargin(corrected);
	    rotateReceiptToPortraitIfNeeded(cropped);
	    cv::Mat preview = makeReceiptPreviewMat(cropped, didApplyPerspective);
	    double cropMs = elapsedMs(cropStart);

    CFAbsoluteTime enhanceStart = CFAbsoluteTimeGetCurrent();
    cv::Mat enhanced = enhanceReceiptMat(cropped);
    double enhanceMs = elapsedMs(enhanceStart);

    CFAbsoluteTime qualityStart = CFAbsoluteTimeGetCurrent();
    OpenCVReceiptQualityResult *quality = analyzeQuality(enhanced, detection.perspectiveDistortion);
    double qualityMs = elapsedMs(qualityStart);

    CFAbsoluteTime upscaleStart = CFAbsoluteTimeGetCurrent();
    BOOL didUpscale = NO;
    CGFloat scaleFactor = 1.0;
    upscaleIfNeeded(enhanced, quality, &didUpscale, &scaleFactor);
    double upscaleMs = elapsedMs(upscaleStart);
    if (didUpscale) {
        quality = analyzeQuality(enhanced, detection.perspectiveDistortion);
    }

	    OpenCVReceiptPreprocessResult *result = [OpenCVReceiptPreprocessResult new];
	    result.image = imageFromMat(enhanced);
	    result.previewImage = imageFromMat(preview);
	    result.detection = detection;
    result.quality = quality;
    result.didApplyPerspective = didApplyPerspective;
    result.didUpscale = didUpscale;
    result.scaleFactor = scaleFactor;
    result.timingsMs = @{
        @"detect": @(detectMs),
        @"correction": @(correctionMs),
        @"crop": @(cropMs),
        @"enhance": @(enhanceMs),
        @"quality": @(qualityMs),
        @"upscale": @(upscaleMs),
        @"totalPreprocess": @(elapsedMs(totalStart))
    };
    return result;
}

@end
