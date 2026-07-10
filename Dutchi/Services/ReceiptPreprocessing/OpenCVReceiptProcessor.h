#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenCVReceiptDetectionResult : NSObject
@property (nonatomic, copy) NSArray<NSValue *> *corners;
@property (nonatomic) CGRect boundingBox;
@property (nonatomic) CGSize imageSize;
@property (nonatomic) CGFloat confidence;
@property (nonatomic) CGFloat perspectiveDistortion;
@property (nonatomic) BOOL hasQuadrilateral;
@end

@interface OpenCVReceiptQualityResult : NSObject
@property (nonatomic) CGFloat blurVariance;
@property (nonatomic) CGFloat brightness;
@property (nonatomic) CGFloat contrast;
@property (nonatomic) CGFloat estimatedTextHeight;
@property (nonatomic) CGFloat perspectiveDistortion;
@property (nonatomic) CGFloat qualityScore;
@property (nonatomic) BOOL shouldRetake;
@property (nonatomic, copy) NSArray<NSString *> *retakeReasons;
@end

@interface OpenCVReceiptPreprocessResult : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) UIImage *previewImage;
@property (nonatomic, strong) OpenCVReceiptDetectionResult *detection;
@property (nonatomic, strong) OpenCVReceiptQualityResult *quality;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *timingsMs;
@property (nonatomic) BOOL didApplyPerspective;
@property (nonatomic) BOOL didUpscale;
@property (nonatomic) CGFloat scaleFactor;
@end

@interface OpenCVReceiptProcessor : NSObject
+ (nullable OpenCVReceiptDetectionResult *)detectReceiptInImage:(UIImage *)image;
+ (UIImage *)correctPerspectiveInImage:(UIImage *)image detection:(OpenCVReceiptDetectionResult *)detection;
+ (UIImage *)enhanceReceiptImage:(UIImage *)image;
+ (OpenCVReceiptQualityResult *)analyzeQualityInImage:(UIImage *)image perspectiveDistortion:(CGFloat)perspectiveDistortion;
+ (nullable OpenCVReceiptPreprocessResult *)preprocessReceiptImage:(UIImage *)image;
@end

NS_ASSUME_NONNULL_END
