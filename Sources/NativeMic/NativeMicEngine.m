#import "NativeMicEngine.h"

NSErrorDomain const NativeMicErrorDomain = @"dBrief.NativeMic";

typedef NS_ENUM(NSInteger, NativeMicErrorCode) {
    NativeMicErrorException = 1,
    NativeMicErrorSynthetic = 2,
    NativeMicErrorMissingAudioUnit = 3,
    NativeMicErrorInvalidated = 5,
    NativeMicErrorTapAlreadyInstalled = 6,
};

static NSError *OperationError(NSInteger code, NSString *operation, NSString *description) {
    return [NSError errorWithDomain:NativeMicErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description,
        @"operation": operation,
    }];
}

static NSError *ExceptionError(NSString *operation, NSException *exception) {
    return [NSError errorWithDomain:NativeMicErrorDomain code:NativeMicErrorException userInfo:@{
        NSLocalizedDescriptionKey: @"Native microphone operation failed",
        @"operation": operation,
        @"exceptionName": exception.name ?: @"UnknownException",
    }];
}

@interface NativeMicEngine () {
    AVAudioEngine *_engine;
    AVAudioInputNode *_inputNode;
    BOOL _tapInstalled;
    BOOL _invalidated;
    id _configurationObserver;
}
@end

@implementation NativeMicEngine

- (instancetype)initWithEngine:(AVAudioEngine *)engine inputNode:(AVAudioInputNode *)inputNode {
    self = [super init];
    if (self) {
        _engine = engine;
        _inputNode = inputNode;
    }
    return self;
}

+ (instancetype)makeWithError:(NSError **)error {
    @try {
        AVAudioEngine *engine = [[AVAudioEngine alloc] init];
        AVAudioInputNode *inputNode = engine.inputNode;
        return [[self alloc] initWithEngine:engine inputNode:inputNode];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(@"make", exception);
        return nil;
    }
}

- (BOOL)requireUsable:(NSString *)operation error:(NSError **)error {
    if (!_invalidated) return YES;
    if (error) *error = OperationError(NativeMicErrorInvalidated, operation,
        @"Native microphone candidate is invalid after an earlier exception");
    return NO;
}

- (void)invalidate:(NSException *)exception operation:(NSString *)operation error:(NSError **)error {
    _invalidated = YES;
    if (error) *error = ExceptionError(operation, exception);
}

- (NSNumber *)currentDeviceIDWithError:(NSError **)error {
    if (![self requireUsable:@"readCurrentDevice" error:error]) return nil;
    @try {
        AudioUnit unit = _inputNode.audioUnit;
        if (!unit) {
            if (error) *error = OperationError(NativeMicErrorMissingAudioUnit,
                @"readCurrentDevice", @"The microphone audio unit was unavailable");
            return nil;
        }
        AudioDeviceID actual = 0;
        UInt32 size = sizeof(actual);
        OSStatus status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &actual, &size);
        if (status != noErr) {
            if (error) *error = OperationError(status, @"readCurrentDevice",
                [NSString stringWithFormat:@"AudioUnitGetProperty(CurrentDevice) failed (%d)", status]);
            return nil;
        }
        return @(actual);
    } @catch (NSException *exception) {
        [self invalidate:exception operation:@"readCurrentDevice" error:error];
        return nil;
    }
}

- (BOOL)setVoiceProcessingEnabled:(BOOL)enabled error:(NSError **)error {
    if (![self requireUsable:@"voiceProcessing" error:error]) return NO;
    @try {
        return [_inputNode setVoiceProcessingEnabled:enabled error:error];
    } @catch (NSException *exception) {
        [self invalidate:exception operation:@"voiceProcessing" error:error];
        return NO;
    }
}

- (NSNumber *)voiceProcessingEnabledWithError:(NSError **)error {
    if (![self requireUsable:@"readVoiceProcessing" error:error]) return nil;
    @try {
        return @(_inputNode.isVoiceProcessingEnabled);
    } @catch (NSException *exception) {
        [self invalidate:exception operation:@"readVoiceProcessing" error:error];
        return nil;
    }
}

- (AVAudioFormat *)inputFormatWithError:(NSError **)error {
    if (![self requireUsable:@"inputFormat" error:error]) return nil;
    @try { return [_inputNode inputFormatForBus:0]; }
    @catch (NSException *exception) {
        [self invalidate:exception operation:@"inputFormat" error:error];
        return nil;
    }
}

- (AVAudioFormat *)outputFormatWithError:(NSError **)error {
    if (![self requireUsable:@"outputFormat" error:error]) return nil;
    @try { return [_inputNode outputFormatForBus:0]; }
    @catch (NSException *exception) {
        [self invalidate:exception operation:@"outputFormat" error:error];
        return nil;
    }
}

- (BOOL)setConfigurationChangeHandler:(NativeMicConfigurationChangeHandler)handler error:(NSError **)error {
    if (![self requireUsable:@"configurationObserver" error:error]) return NO;
    @try {
        if (_configurationObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:_configurationObserver];
            _configurationObserver = nil;
        }
        if (handler) {
            _configurationObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:AVAudioEngineConfigurationChangeNotification
                            object:_engine
                             queue:nil
                        usingBlock:^(__unused NSNotification *note) { handler(); }];
        }
        return YES;
    } @catch (NSException *exception) {
        [self invalidate:exception operation:@"configurationObserver" error:error];
        return NO;
    }
}

- (BOOL)installTapWithBufferSize:(AVAudioFrameCount)bufferSize
                           format:(AVAudioFormat *)format
                          handler:(AVAudioNodeTapBlock)handler
                            error:(NSError **)error {
    if (![self requireUsable:@"installTap" error:error]) return NO;
    if (_tapInstalled) {
        if (error) *error = OperationError(NativeMicErrorTapAlreadyInstalled,
            @"installTap", @"A microphone tap is already installed");
        return NO;
    }
    @try {
        [_inputNode installTapOnBus:0 bufferSize:bufferSize format:format block:handler];
        _tapInstalled = YES;
        return YES;
    } @catch (NSException *exception) {
        [self invalidate:exception operation:@"installTap" error:error];
        return NO;
    }
}

- (BOOL)startWithError:(NSError **)error {
    if (![self requireUsable:@"start" error:error]) return NO;
    @try { return [_engine startAndReturnError:error]; }
    @catch (NSException *exception) {
        [self invalidate:exception operation:@"start" error:error];
        return NO;
    }
}

- (BOOL)pauseWithError:(NSError **)error {
    if (![self requireUsable:@"pause" error:error]) return NO;
    @try { [_engine pause]; return YES; }
    @catch (NSException *exception) {
        [self invalidate:exception operation:@"pause" error:error];
        return NO;
    }
}

- (BOOL)removeTapWithError:(NSError **)error {
    if (!_tapInstalled) return YES;
    @try { [_inputNode removeTapOnBus:0]; _tapInstalled = NO; return YES; }
    @catch (NSException *exception) {
        [self invalidate:exception operation:@"removeTap" error:error];
        return NO;
    }
}

- (BOOL)stopWithError:(NSError **)error {
    @try {
        if (_configurationObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:_configurationObserver];
            _configurationObserver = nil;
        }
        [_engine stop];
        return YES;
    }
    @catch (NSException *exception) {
        [self invalidate:exception operation:@"stop" error:error];
        return NO;
    }
}

- (NSNumber *)runningWithError:(NSError **)error {
    if (![self requireUsable:@"isRunning" error:error]) return nil;
    @try { return @(_engine.isRunning); }
    @catch (NSException *exception) {
        [self invalidate:exception operation:@"isRunning" error:error];
        return nil;
    }
}

+ (BOOL)runSyntheticOperation:(NativeMicSyntheticOperation)operation error:(NSError **)error {
    @try {
        switch (operation) {
            case NativeMicSyntheticOperationSucceeds: return YES;
            case NativeMicSyntheticOperationReturnsError:
                if (error) *error = OperationError(NativeMicErrorSynthetic,
                    @"synthetic", @"Synthetic native operation returned an error");
                return NO;
            case NativeMicSyntheticOperationThrowsException:
                @throw [NSException exceptionWithName:@"SyntheticNativeException" reason:nil userInfo:nil];
        }
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(@"synthetic", exception);
        return NO;
    }
}

@end
