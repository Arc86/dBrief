#import "NativeMicCaptureSession.h"
#import <CoreMedia/CoreMedia.h>

static NSError *CaptureError(NSString *operation, NSString *message) {
    return [NSError errorWithDomain:@"dBrief.NativeMicCaptureSession" code:1
        userInfo:@{NSLocalizedDescriptionKey: message, @"operation": operation}];
}

@interface NativeMicCaptureSession () <AVCaptureAudioDataOutputSampleBufferDelegate> {
    AVCaptureSession *_session;
    AVCaptureDeviceInput *_input;
    AVCaptureAudioDataOutput *_output;
    dispatch_queue_t _callbackQueue;
    AVAudioNodeTapBlock _handler;
    NSError *_captureError;
    NSString *_deviceUID;
    id _runtimeObserver;
}
@end

@implementation NativeMicCaptureSession

+ (instancetype)makeForDeviceUID:(NSString *)uid error:(NSError **)error {
    @try {
        AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:uid];
        if (!device || ![device hasMediaType:AVMediaTypeAudio]) {
            if (error) *error = CaptureError(@"resolve", @"Requested audio device is unavailable");
            return nil;
        }
        NativeMicCaptureSession *candidate = [[self alloc] init];
        candidate->_callbackQueue = dispatch_queue_create("com.dbrief.mic-capture-session", DISPATCH_QUEUE_SERIAL);
        candidate->_deviceUID = [device.uniqueID copy];
        candidate->_input = [AVCaptureDeviceInput deviceInputWithDevice:device error:error];
        if (!candidate->_input) return nil;
        candidate->_session = [[AVCaptureSession alloc] init];
        candidate->_output = [[AVCaptureAudioDataOutput alloc] init];
        // Keep the native rate/channel count; request AVAudioFile’s standard
        // deinterleaved Float32 layout so buffers write without conversion.
        candidate->_output.audioSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @YES,
        };
        if (![candidate->_session canAddInput:candidate->_input]) {
            if (error) *error = CaptureError(@"configure", @"Capture session rejected audio input");
            return nil;
        }
        [candidate->_session addInput:candidate->_input];
        if (![candidate->_session canAddOutput:candidate->_output]) {
            if (error) *error = CaptureError(@"configure", @"Capture session rejected audio data output");
            return nil;
        }
        [candidate->_session addOutput:candidate->_output];
        [candidate->_output setSampleBufferDelegate:candidate queue:candidate->_callbackQueue];
        __weak NativeMicCaptureSession *weakCandidate = candidate;
        candidate->_runtimeObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVCaptureSessionRuntimeErrorNotification object:candidate->_session queue:nil
            usingBlock:^(NSNotification *notification) {
                [weakCandidate recordError:notification.userInfo[AVCaptureSessionErrorKey]
                    ?: CaptureError(@"runtime", @"Capture session runtime error")];
            }];
        return candidate;
    } @catch (NSException *exception) {
        if (error) *error = CaptureError(@"make", exception.name);
        return nil;
    }
}

- (NSString *)deviceUID { return _deviceUID; }
- (NSError *)captureError { @synchronized (self) { return _captureError; } }
- (void)recordError:(NSError *)error {
    @synchronized (self) { if (!_captureError) _captureError = error; }
}

- (BOOL)startWithHandler:(AVAudioNodeTapBlock)handler error:(NSError **)error {
    @try {
        if (self.captureError) {
            if (error) *error = self.captureError;
            return NO;
        }
        dispatch_sync(_callbackQueue, ^{ self->_handler = [handler copy]; });
        [_session startRunning];
        if (!_session.isRunning) {
            if (error) *error = self.captureError ?: CaptureError(@"start", @"Capture session did not start");
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        NSError *failure = CaptureError(@"start", exception.name);
        [self recordError:failure];
        if (error) *error = failure;
        return NO;
    }
}

- (BOOL)stopWithError:(NSError **)error {
    BOOL stopped = YES;
    @try { [_session stopRunning]; }
    @catch (NSException *exception) {
        stopped = NO;
        if (error) *error = CaptureError(@"stop", exception.name);
    }
    // Called from the main actor, never from a sample callback.
    if (_callbackQueue) dispatch_sync(_callbackQueue, ^{ self->_handler = nil; });
    return stopped;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
      fromConnection:(AVCaptureConnection *)connection {
    if (!_handler || self.captureError) return;
    @try {
        CMItemCount frames = CMSampleBufferGetNumSamples(sample);
        CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
        const AudioStreamBasicDescription *asbd = description
            ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
        if (!CMSampleBufferDataIsReady(sample) || !asbd || frames <= 0 || frames > INT32_MAX
            || asbd->mFormatID != kAudioFormatLinearPCM) {
            [self recordError:CaptureError(@"sample", @"Invalid PCM capture sample")];
            return;
        }
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
            frameCapacity:(AVAudioFrameCount)frames];
        if (!buffer) {
            [self recordError:CaptureError(@"sample", @"PCM buffer allocation failed")];
            return;
        }
        buffer.frameLength = (AVAudioFrameCount)frames;
        OSStatus status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, 0, (int32_t)frames,
            buffer.mutableAudioBufferList);
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        // The session creates its synchronization clock during startRunning.
        // Read it at delivery, as prescribed by AVCaptureSession's clock API.
        CMClockRef clock = _session.synchronizationClock;
        CMTime hostTime = clock ? CMSyncConvertTime(pts, clock, CMClockGetHostTimeClock()) : kCMTimeInvalid;
        if (status != noErr || !CMTIME_IS_NUMERIC(hostTime) || CMTimeCompare(hostTime, kCMTimeZero) < 0) {
            [self recordError:CaptureError(@"sample", @"PCM copy or host-clock conversion failed")];
            return;
        }
        AVAudioTime *time = [AVAudioTime timeWithHostTime:CMClockConvertHostTimeToSystemUnits(hostTime)];
        _handler(buffer, time);
    } @catch (NSException *exception) {
        [self recordError:CaptureError(@"sample", exception.name)];
    }
}

- (void)dealloc {
    if (_runtimeObserver) [[NSNotificationCenter defaultCenter] removeObserver:_runtimeObserver];
    @try {
        [_output setSampleBufferDelegate:nil queue:NULL];
        [_session stopRunning];
    } @catch (NSException *exception) { /* Contain native teardown exceptions. */ }
}
@end
