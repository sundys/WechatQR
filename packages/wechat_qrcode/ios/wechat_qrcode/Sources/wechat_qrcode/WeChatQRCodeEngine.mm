/*
 * Copyright (C) 2025 WeChatQR project contributors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "WeChatQRCodeEngine.h"

#import <UIKit/UIKit.h>

#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/wechat_qrcode.hpp>

#include <memory>
#include <vector>

NSString *const WeChatQRCodeEngineErrorDomain = @"com.sundys.wechat_qrcode.engine";

#pragma mark - WeChatQRCodeMatch

@implementation WeChatQRCodeMatch

- (instancetype)initWithText:(NSString *)text
                    centreInImage:(nullable NSValue *)centreInImage {
    self = [super init];
    if (self) {
        _text = [text copy];
        _centreInImage = centreInImage;
    }
    return self;
}

@end

/// Longest edge an image is resized to before detection, matching the Android
/// implementation so both platforms behave the same on large photos.
static const CGFloat kMaxImageDimension = 2400.0;

@implementation WeChatQRCodeEngine

/// Shared detector. Created once and reused for every frame.
static std::unique_ptr<cv::wechat_qrcode::WeChatQRCode> gDetector;

+ (BOOL)isInitialized {
    @synchronized(self) {
        return gDetector != nil;
    }
}

+ (BOOL)initializeWithModelDirectory:(NSString *)directory
                               error:(NSError **)error {
    @synchronized(self) {
        if (gDetector) {
            return YES;
        }

        NSString *detectPrototxt = [directory stringByAppendingPathComponent:@"detect.prototxt"];
        NSString *detectModel = [directory stringByAppendingPathComponent:@"detect.caffemodel"];
        NSString *srPrototxt = [directory stringByAppendingPathComponent:@"sr.prototxt"];
        NSString *srModel = [directory stringByAppendingPathComponent:@"sr.caffemodel"];

        // Checked up front so a missing asset produces a clear, retryable error
        // instead of an exception from inside OpenCV.
        for (NSString *path in @[detectPrototxt, detectModel, srPrototxt, srModel]) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                if (error) {
                    *error = [NSError
                        errorWithDomain:WeChatQRCodeEngineErrorDomain
                                   code:WeChatQRCodeEngineErrorModelsMissing
                               userInfo:@{
                                   NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:@"Model file missing: %@", path]
                               }];
                }
                return NO;
            }
        }

        try {
            gDetector = std::make_unique<cv::wechat_qrcode::WeChatQRCode>(
                detectPrototxt.UTF8String,
                detectModel.UTF8String,
                srPrototxt.UTF8String,
                srModel.UTF8String);
        } catch (const std::exception &e) {
            if (error) {
                *error = [NSError
                    errorWithDomain:WeChatQRCodeEngineErrorDomain
                               code:WeChatQRCodeEngineErrorDetectorCreationFailed
                           userInfo:@{
                               NSLocalizedDescriptionKey: [NSString
                                   stringWithFormat:@"OpenCV rejected the QR models: %s", e.what()]
                           }];
            }
            return NO;
        } catch (...) {
            if (error) {
                *error = [NSError
                    errorWithDomain:WeChatQRCodeEngineErrorDomain
                               code:WeChatQRCodeEngineErrorDetectorCreationFailed
                           userInfo:@{NSLocalizedDescriptionKey: @"OpenCV rejected the QR models."}];
            }
            return NO;
        }

        return YES;
    }
}

+ (void)releaseEngine {
    @synchronized(self) {
        gDetector.reset();
    }
}

+ (NSArray<WeChatQRCodeMatch *> *)detectAndDecodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                                            rotationDegrees:(int)rotationDegrees {
    if (!pixelBuffer) {
        return @[];
    }

    cv::Mat bgr;
    @synchronized(self) {
        if (!gDetector) {
            return @[];
        }
        if (![self copyPixelBufferToBgr:pixelBuffer into:&bgr]) {
            return @[];
        }
    }

    return [self detectAndDecodeBgr:&bgr rotationDegrees:rotationDegrees];
}

+ (NSArray<NSString *> *)detectAndDecodeImageAtPath:(NSString *)path
                                              error:(NSError **)error {
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image == nil || image.size.width <= 0 || image.size.height <= 0) {
        if (error) {
            *error = [NSError
                errorWithDomain:WeChatQRCodeEngineErrorDomain
                           code:WeChatQRCodeEngineErrorImageUnreadable
                       userInfo:@{
                           NSLocalizedDescriptionKey:
                               @"The image could not be read or is not a supported format."
                       }];
        }
        return @[];
    }

    // Redrawing through UIGraphicsImageRenderer applies the EXIF orientation and
    // lets us cap the size in one step, so a 50-megapixel photo cannot exhaust
    // memory.
    CGFloat longest = MAX(image.size.width, image.size.height);
    CGFloat scale = longest > kMaxImageDimension ? kMaxImageDimension / longest : 1.0;
    CGSize target = CGSizeMake(
        MAX(1.0, floor(image.size.width * scale)),
        MAX(1.0, floor(image.size.height * scale)));

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    UIImage *normalised = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];

    CGImageRef cgImage = normalised.CGImage;
    if (cgImage == NULL) {
        if (error) {
            *error = [NSError
                errorWithDomain:WeChatQRCodeEngineErrorDomain
                           code:WeChatQRCodeEngineErrorImageUnreadable
                       userInfo:@{NSLocalizedDescriptionKey: @"The image could not be decoded."}];
        }
        return @[];
    }

    cv::Mat bgr;
    if (![self copyCGImageToBgr:cgImage into:&bgr]) {
        if (error) {
            *error = [NSError
                errorWithDomain:WeChatQRCodeEngineErrorDomain
                           code:WeChatQRCodeEngineErrorImageUnreadable
                       userInfo:@{NSLocalizedDescriptionKey: @"The image could not be decoded."}];
        }
        return @[];
    }

    // Already upright: UIGraphicsImageRenderer normalised the orientation.
    //
    // A picture from the gallery carries no preview to place a marker on, so
    // only the payloads are returned here; the analysis path is the one that
    // needs positions.
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (WeChatQRCodeMatch *match in [self detectAndDecodeBgr:&bgr rotationDegrees:0]) {
        [texts addObject:match.text];
    }
    return texts;
}

#pragma mark - Private

+ (NSArray<WeChatQRCodeMatch *> *)detectAndDecodeBgr:(cv::Mat *)bgr
                                        rotationDegrees:(int)rotationDegrees {
    // Rotate in place so the detector sees an upright symbol. QR decoding is
    // rotation-tolerant, but normalising costs almost nothing and keeps the
    // super-resolution path consistent.
    switch (rotationDegrees) {
        case 90:
            cv::rotate(*bgr, *bgr, cv::ROTATE_90_CLOCKWISE);
            break;
        case 180:
            cv::rotate(*bgr, *bgr, cv::ROTATE_180);
            break;
        case 270:
            cv::rotate(*bgr, *bgr, cv::ROTATE_90_COUNTERCLOCKWISE);
            break;
        default:
            break;
    }

    std::vector<cv::Mat> points;
    std::vector<cv::String> decoded;

    @synchronized(self) {
        if (!gDetector) {
            return @[];
        }
        try {
            decoded = gDetector->detectAndDecode(*bgr, points);
        } catch (const std::exception &) {
            // A malformed frame must never take the analysis queue down.
            return @[];
        } catch (...) {
            return @[];
        }
    }

    NSMutableArray<WeChatQRCodeMatch *> *matches =
        [NSMutableArray arrayWithCapacity:decoded.size()];

    for (size_t index = 0; index < decoded.size(); index++) {
        NSString *text = [NSString stringWithUTF8String:decoded[index].c_str()];
        if (text.length == 0) {
            continue;
        }

        // The quadrangle is in the rotated image's coordinates, which is what
        // the preview shows, so normalising by that image's size puts the centre
        // into the same 0..1 space the caller maps onto the view.
        NSValue *centre = nil;
        if (index < points.size()) {
            centre = [self centreOfQuad:points[index] inImageOfSize:bgr->size()];
        }

        [matches addObject:[[WeChatQRCodeMatch alloc] initWithText:text
                                                    centreInImage:centre]];
    }
    return matches;
}

/// The centre of a detected quadrangle, normalised to the image, or nil.
///
/// The engine's output shape is not guaranteed — the points arrive either as a
/// 4x2 matrix or as four 1x2 rows — so both are reshaped to a common form before
/// anything is read. `convertTo` is used rather than a typed accessor so the
/// element type does not matter either.
+ (nullable NSValue *)centreOfQuad:(const cv::Mat &)quad
                     inImageOfSize:(cv::Size)imageSize {
    if (quad.empty() || imageSize.width <= 0 || imageSize.height <= 0) {
        return nil;
    }

    cv::Mat points;
    quad.convertTo(points, CV_64F);
    if (points.channels() == 2) {
        points = points.reshape(1);
    }
    if (points.rows < 4 || points.cols < 2) {
        return nil;
    }

    double sumX = 0.0;
    double sumY = 0.0;
    for (int row = 0; row < 4; row++) {
        sumX += points.at<double>(row, 0);
        sumY += points.at<double>(row, 1);
    }

    double x = sumX / 4.0 / imageSize.width;
    double y = sumY / 4.0 / imageSize.height;
    return [NSValue valueWithCGPoint:CGPointMake(x, y)];
}

/// Converts a BGRA `CVPixelBuffer` into a tightly packed BGR `cv::Mat`.
+ (BOOL)copyPixelBufferToBgr:(CVPixelBufferRef)pixelBuffer into:(cv::Mat *)out {
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return NO;
    }

    const size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);

    if (base == NULL || width == 0 || height == 0) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    // The buffer may be row-padded, so copy row by row rather than assuming a
    // tightly packed layout.
    cv::Mat bgra(static_cast<int>(height),
                 static_cast<int>(width),
                 CV_8UC4,
                 base,
                 bytesPerRow);
    cv::cvtColor(bgra, *out, cv::COLOR_BGRA2BGR);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return true;
}

/// Converts a `CGImage` into a tightly packed BGR `cv::Mat`.
+ (BOOL)copyCGImageToBgr:(CGImageRef)image into:(cv::Mat *)out {
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) {
        return NO;
    }

    cv::Mat bgra(static_cast<int>(height), static_cast<int>(width), CV_8UC4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        return NO;
    }

    CGContextRef context = CGBitmapContextCreate(bgra.data,
                                                width,
                                                height,
                                                8,
                                                bgra.step,
                                                colorSpace,
                                                kCGBitmapByteOrder32Little |
                                                    kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return NO;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);

    cv::cvtColor(bgra, *out, cv::COLOR_BGRA2BGR);
    return true;
}

@end
