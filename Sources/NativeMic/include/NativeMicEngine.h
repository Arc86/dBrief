#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const NativeMicErrorDomain;

typedef NS_ENUM(NSInteger, NativeMicSyntheticOperation) {
    NativeMicSyntheticOperationSucceeds,
    NativeMicSyntheticOperationReturnsError,
    NativeMicSyntheticOperationThrowsException,
};

typedef void (^NativeMicConfigurationChangeHandler)(void);

/// Owns one AVAudioEngine. Every potentially exception-throwing AVFAudio
/// operation is performed inside the Objective-C implementation so an
/// NSException never unwinds through a Swift frame. There is deliberately no
/// device-binding operation: writing kAudioOutputUnitProperty_CurrentDevice
/// on this engine's HAL input yields zero callbacks on current macOS
/// (docs/diagnostics/2026-09-20-audio-switching-review.md). The engine only
/// captures the system default input; other devices use NativeMicCaptureSession.
@interface NativeMicEngine : NSObject

+ (nullable instancetype)makeWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(make());

- (nullable NSNumber *)currentDeviceIDWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(currentDeviceID());
- (BOOL)setVoiceProcessingEnabled:(BOOL)enabled
                             error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(setVoiceProcessing(enabled:));
- (nullable NSNumber *)voiceProcessingEnabledWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(voiceProcessingEnabled());
- (nullable AVAudioFormat *)inputFormatWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(inputFormat());
- (nullable AVAudioFormat *)outputFormatWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(outputFormat());
- (BOOL)setConfigurationChangeHandler:(nullable NativeMicConfigurationChangeHandler)handler
                                 error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(setConfigurationChangeHandler(_:));

- (BOOL)installTapWithBufferSize:(AVAudioFrameCount)bufferSize
                           format:(nullable AVAudioFormat *)format
                          handler:(AVAudioNodeTapBlock)handler
                            error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(installTap(bufferSize:format:handler:));
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start());
- (BOOL)pauseWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(pause());
- (BOOL)removeTapWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(removeTap());
- (BOOL)stopWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(stop());
- (nullable NSNumber *)runningWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(isRunning());

+ (BOOL)runSyntheticOperation:(NativeMicSyntheticOperation)operation
                         error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
