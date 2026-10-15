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

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const WeChatQRCodeEngineErrorDomain;

typedef NS_ENUM(NSInteger, WeChatQRCodeEngineErrorCode) {
    WeChatQRCodeEngineErrorModelsMissing = 1,
    WeChatQRCodeEngineErrorDetectorCreationFailed = 2,
    WeChatQRCodeEngineErrorNotInitialized = 3,
    WeChatQRCodeEngineErrorImageUnreadable = 4,
};

/**
 * Objective-C++ wrapper around OpenCV's `cv::wechat_qrcode::WeChatQRCode`.
 *
 * This is the iOS counterpart of the Android `WeChatQRCodeDetector` object; it
 * exists because the OpenCV API is C++ and Swift cannot call it directly.
 *
 * The detector is created once and reused for every frame. Only `core`,
 * `imgproc`, `objdetect` and `dnn` from OpenCV are used — the modules
 * `opencv_contrib/modules/wechat_qrcode/CMakeLists.txt` declares as its
 * dependencies. Image files are decoded with UIKit rather than `imgcodecs`, so
 * that module is not needed either.
 */
@interface WeChatQRCodeEngine : NSObject

/// Loads the four model files and builds the detector. Idempotent.
+ (BOOL)initializeWithModelDirectory:(NSString *)directory
                               error:(NSError **)error;

+ (BOOL)isInitialized;

/// Drops the detector. The engine must be initialised again before further use.
+ (void)releaseEngine;

/// Decodes every QR code in a BGRA pixel buffer.
///
/// `rotationDegrees` is the clockwise rotation that must be applied to make the
/// frame upright (as reported by AVCaptureConnection.videoRotationAngle).
/// Returns an empty array when no QR code is found; never returns nil for a
/// valid buffer.
+ (NSArray<NSString *> *)detectAndDecodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                                    rotationDegrees:(int)rotationDegrees;

/// Decodes every QR code in an image file on disk.
///
/// The image is normalised for its EXIF orientation and downsampled if very
/// large. Returns an empty array when no QR code is found.
+ (NSArray<NSString *> *)detectAndDecodeImageAtPath:(NSString *)path
                                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
