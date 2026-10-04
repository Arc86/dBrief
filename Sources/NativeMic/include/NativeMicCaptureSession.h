#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Captures one microphone by exact device UID. Only an audio input and data
/// output: no playback output, voice processing, or system-default mutation.
/// Proven to switch between Bluetooth and built-in microphones where
/// AVAudioEngine delivers nothing (2026-09-21 capture-session probe).
@interface NativeMicCaptureSession : NSObject
+ (nullable instancetype)makeForDeviceUID:(NSString *)uid
                                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(make(deviceUID:));
- (BOOL)startWithHandler:(AVAudioNodeTapBlock)handler
                  error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start(handler:));
/// Stops delivery and drains the callback queue before returning.
- (BOOL)stopWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(stop());
@property(nonatomic, readonly, copy) NSString *deviceUID;
@property(nonatomic, readonly, nullable) NSError *captureError;
@end

NS_ASSUME_NONNULL_END
