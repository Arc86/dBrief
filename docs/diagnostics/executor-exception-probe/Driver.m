#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "Bridge.h"

extern void scheduleProbe(int32_t mode);
extern void checkProbe(void);

// Private runtime ABI, observed solely inside this disposable diagnostic.
// Never use this or executor tracking manipulation in application code.
typedef struct { void *identity; void *implementation; } ExecutorRef;
extern ExecutorRef __attribute__((swiftcall)) swift_task_getCurrentExecutor(void);

static void dumpExecutor(const char *label) {
    ExecutorRef ref = swift_task_getCurrentExecutor();
    printf("%s executor: %p %p\n", label, ref.identity, ref.implementation);
}

__attribute__((noinline)) static void reuseStack(void) {
    volatile unsigned long storage[2048];
    for (int i = 0; i < 2048; i++) storage[i] = 0x12345678;
    __asm__ volatile("" : : "r"(storage) : "memory");
}

void raiseProbeException(void) {
    [NSException raise:@"SyntheticAudioReconfigureException"
                format:@"Synthetic test only; no audio devices accessed"];
}

void containProbeException(void) {
    @try {
        raiseProbeException();
    } @catch (NSException *exception) {
        printf("contained before unwinding into Swift: %s\n", exception.name.UTF8String);
    }
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    int32_t mode = 0;
    if (argc > 1 && strcmp(argv[1], "inject") == 0) mode = 1;
    if (argc > 1 && strcmp(argv[1], "contained") == 0) mode = 2;
    @autoreleasepool {
        dumpExecutor("before");
        scheduleProbe(mode);
        @try {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        } @catch (NSException *exception) {
            printf("outer Objective-C handler caught: %s\n", exception.name.UTF8String);
        }
        dumpExecutor("after run loop");
        reuseStack();
        dumpExecutor("after stack reuse");
        checkProbe();
    }
    return 0;
}
