#import <XCTest/XCTest.h>
#import "../Sources/Services/THRetainedSystemAudioBridge.h"
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "../Sources/Services/THPrivateAudioErrors.h"
#import "THPrivateAudioRuntimeFixture.h"
#import "ToneHopTests-Swift.h"

/// Inject changes in public HAL observations while retaining the real bridge's
/// capture, selection, ownership, rollback and shutdown entry points.
@interface THRChangingHALRuntime : THPrivateAudioRuntimeFixture
@property(nonatomic, copy) NSString *affectedUID;
@property(nonatomic, copy) NSString *replacementUID;
@property(nonatomic) BOOL changesSecondUIDRead, changesTransport, becomesUnavailable;
@property(nonatomic) BOOL deniesDefaultOutput;
@property(nonatomic) AudioObjectID affectedObject;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *uidReadCounts;
@property(nonatomic, strong) NSMutableArray<NSString *> *writtenUIDs;
@property(nonatomic, copy) void (^beforeSettable)(THRChangingHALRuntime *);
@property(nonatomic, copy) void (^afterHALRead)(THRChangingHALRuntime *, AudioObjectID, AudioObjectPropertySelector);
@property(nonatomic) OSStatus statusAfterHALWrite;
@property(nonatomic) BOOL throwAfterHALWrite;
@end

/// A fresh bridge has no references from the previous App instance. The runtime
/// preserves only externally observable system state across that boundary.
@interface ExistingSystemStreamRecoveryTests : XCTestCase
@end

@implementation ExistingSystemStreamRecoveryTests
- (NSDictionary *)dictionary:(id)value {
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (BOOL)select:(THRetainedSystemAudioBridge *)bridge error:(NSError **)error {
    return [bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:error];
}
- (void)withColdStreamOnBluetooth:(BOOL)bluetooth test:(void (^)(THRetainedSystemAudioBridge *, THPrivateAudioRuntimeFixture *))test {
    XCTestExpectation *finished = [self expectationWithDescription:@"new App bridge over a surviving system stream"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        THPrivateAudioRuntimeFixture *runtime = [[THRChangingHALRuntime alloc] initFixture];
        runtime.suppressSystemSelectionOnHALWrite = YES;
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-123-Audio"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        THPrivateEndpointBridge *previousEndpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
            performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([previousEndpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *previous = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:previousEndpoints runtime:runtime];
        XCTAssertEqualObjects([self dictionary:[previous snapshotWithError:NULL][@"retained"]][@"state"], @"selected");
        XCTAssertTrue([previous shutdownWithError:NULL]); [previousEndpoints stop];
        previous = nil; previousEndpoints = nil;
        if (bluetooth) [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
        else [runtime selectSystemAggregate:nil];

        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
            performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        test(bridge, runtime);
        runtime.onHALWrite = nil; runtime.onRead = nil; runtime.onPump = nil;
        ((THRChangingHALRuntime *)runtime).beforeSettable = nil;
        ((THRChangingHALRuntime *)runtime).afterHALRead = nil;
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop];
        XCTAssertEqual(runtime.adds + runtime.removes, 0u, @"Recovery only borrows an existing system stream, including on shutdown.");
        [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}
- (void)assertBorrowedSelection:(THRetainedSystemAudioBridge *)bridge runtime:(THPrivateAudioRuntimeFixture *)runtime {
    NSDictionary *snapshot = [bridge snapshotWithError:NULL];
    XCTAssertEqualObjects([self dictionary:snapshot[@"retained"]][@"isSelected"], @YES);
    XCTAssertEqualObjects(snapshot[@"diagnostics"][@"captureStreamUID"], @"aggregate-A-123-Audio");
    XCTAssertEqualObjects(snapshot[@"diagnostics"][@"ownedMember"], @NO);
    XCTAssertEqualObjects(runtime.defaultUID, @"aggregate-A-123-Audio");
    XCTAssertEqual(runtime.adds + runtime.removes, 0u);
}
- (void)testRestartOnBluetoothOrLocalPublishesIndependentRecoveryCapabilityWithoutWrites {
    for (NSNumber *bluetooth in @[@NO, @YES]) {
        [self withColdStreamOnBluetooth:bluetooth.boolValue test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            NSString *original = [runtime.defaultUID copy];
            for (NSUInteger i = 0; i < 3; i++) {
                NSDictionary *snapshot = [bridge snapshotWithError:NULL];
                NSDictionary *recovery = [self dictionary:snapshot[@"existingStreamRecovery"]];
                XCTAssertEqualObjects(recovery[@"identifier"], @"receiver-A");
                XCTAssertEqualObjects(recovery[@"uid"], @"aggregate-A-123-Audio");
                XCTAssertEqualObjects(recovery[@"aggregateIdentifier"], @"aggregate-A");
                XCTAssertEqualObjects(recovery[@"contextIdentifier"], @"context-A");
                XCTAssertEqualObjects(recovery[@"readbackStable"], @YES);
                XCTAssertEqualObjects(recovery[@"canSelect"], @YES);
                XCTAssertEqualObjects(snapshot[@"retained"], NSNull.null);
                XCTAssertEqualObjects(snapshot[@"diagnostics"][@"ownedMember"], @NO);
            }
            XCTAssertEqualObjects(runtime.defaultUID, original);
            XCTAssertEqual(runtime.halWrites, 0u);
        }];
    }
}
- (void)testRestartRecoveryWaitsForIndependentSystemReadbackThenReusesBorrowedStreamAfterBluetooth {
    for (NSNumber *bluetooth in @[@NO, @YES]) {
        [self withColdStreamOnBluetooth:bluetooth.boolValue test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            __weak THPrivateAudioRuntimeFixture *owner = runtime;
            __block NSUInteger pumps = 0, submissions = 0;
            runtime.onHALWrite = ^(NSString *uid) {
                XCTAssertEqualObjects(uid, @"aggregate-A-123-Audio");
                XCTAssertNil(owner.selectedAggregate, @"A HAL setter cannot manufacture SystemAudio readback.");
                pumps = 0; submissions++;
            };
            runtime.onPump = ^{
                if (submissions && ++pumps == 3) [owner selectSystemAggregate:@"aggregate-A"];
            };
            XCTAssertTrue([self select:bridge error:NULL]);
            XCTAssertGreaterThanOrEqual(pumps, 3u);
            XCTAssertEqual(runtime.halWrites, 1u);
            [self assertBorrowedSelection:bridge runtime:runtime];

            [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
            XCTAssertTrue([bridge reconcileRuntimeStateIsShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL]);
            XCTAssertEqual(runtime.removes, 0u);
            XCTAssertTrue([self select:bridge error:NULL]);
            XCTAssertEqual(runtime.halWrites, 2u);
            [self assertBorrowedSelection:bridge runtime:runtime];
        }];
    }
}
- (void)testSuccessfulHALWithoutSystemSelectionRemainsUnconfirmedAndNeverAddsOrRetries {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        NSError *error = nil;
        XCTAssertFalse([self select:bridge error:&error]);
        XCTAssertNotNil(error);
        XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects(runtime.defaultUID, @"aggregate-A-123-Audio");
        XCTAssertNil(runtime.selectedAggregate);
        for (NSUInteger i = 0; i < 3; i++) {
            NSDictionary *snapshot = [bridge snapshotWithError:NULL];
            XCTAssertEqualObjects(snapshot[@"retained"], NSNull.null);
            XCTAssertEqualObjects(snapshot[@"diagnostics"][@"ownedMember"], @NO);
            (void)[bridge reconcileRuntimeStateIsShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL];
        }
        XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)testBufferedSelectionWithoutMatchingAssociatedUIDCannotBecomeCaptured {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        runtime.onHALWrite = ^(NSString *uid) {
            [owner selectSystemAggregate:@"aggregate-A"];
            owner.contextAssociatedAudioDeviceOverride = @"different-complete-stream-UID";
        };
        XCTAssertFalse([self select:bridge error:NULL]);
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(snapshot[@"retained"], NSNull.null);
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"ownedMember"], @NO);
        XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)testCancelledClosedOrRejectedRecoveryNeverSubmitsHAL {
    for (NSNumber *scenario in @[@0, @1, @2]) {
        [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^BOOL{ return scenario.intValue == 0; }
                isShuttingDown:^BOOL{ return scenario.intValue == 1; }
                performIfRunning:^BOOL(void (^operation)(void)) {
                    XCTAssertEqual(scenario.intValue, 2); return NO;
                } error:NULL]);
            XCTAssertEqual(runtime.halWrites, 0u);
            XCTAssertEqualObjects(runtime.defaultUID, @"Bluetooth-Full-UID:output");
        }];
    }
}
- (void)testCancellationAfterHALDoesNotInventCaptureOrSubmitAnotherWrite {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^BOOL{ return runtime.halWrites > 0; }
            isShuttingDown:^{ return NO; } performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL]);
        XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"], NSNull.null);
    }];
}
- (void)testRecoveryRechecksStreamReceiverContextAndCurrentOutputInsideMutationGate {
    for (NSNumber *scenario in @[@0, @1, @2, @3]) {
        [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            XCTAssertEqualObjects([self dictionary:[bridge snapshotWithError:NULL][@"existingStreamRecovery"]][@"canSelect"], @YES);
            XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) {
                    switch (scenario.intValue) {
                        case 0: [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-456-Audio"]]; break;
                        case 1: [runtime setAggregate:@"aggregate-A" receiver:@"receiver-B" streams:@[@"aggregate-A-123-Audio"]]; break;
                        case 2: runtime.contextIdentifier = @"context-B"; break;
                        default: [runtime selectSystemBluetoothUID:@"Other-Bluetooth-Full-UID:output"]; break;
                    }
                    operation(); return YES;
                } error:NULL]);
            XCTAssertEqual(runtime.halWrites, 0u);
        }];
    }
}
- (void)testRecoveryRejectsDifferentRequestedReceiverAndAmbiguousSystemIdentity {
    for (NSNumber *scenario in @[@0, @1, @2, @3]) {
        [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            switch (scenario.intValue) {
                case 1: [runtime setAggregate:@"aggregate-B" receiver:@"receiver-B" streams:@[@"aggregate-B-789-Audio"]]; break;
                case 2: [runtime setAggregate:@"aggregate-A" receivers:@[@"receiver-A", @"receiver-B"] streams:@[@"aggregate-A-123-Audio"]]; break;
                case 3: [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-123-Audio", @"aggregate-A-456-Audio"]]; break;
                default: break;
            }
            if (scenario.intValue) XCTAssertNotEqualObjects([self dictionary:[bridge snapshotWithError:NULL][@"existingStreamRecovery"]][@"canSelect"], @YES);
            XCTAssertFalse([bridge selectIdentifier:scenario.intValue ? @"receiver-A" : @"receiver-B"
                isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL]);
            XCTAssertEqual(runtime.halWrites, 0u);
        }];
    }
}
- (void)testRecoveryRechecksHALUIDAndTransportDuringFinalSettableRead {
    for (NSNumber *transport in @[@NO, @YES]) {
        [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *fixture) {
            THRChangingHALRuntime *runtime = (THRChangingHALRuntime *)fixture;
            runtime.affectedUID = @"aggregate-A-123-Audio";
            XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) {
                    runtime.beforeSettable = ^(THRChangingHALRuntime *value) {
                        if (transport.boolValue) value.changesTransport = YES;
                        else value.replacementUID = @"Unrelated-Full-HAL-UID";
                    };
                    operation(); return YES;
                } error:NULL]);
            XCTAssertEqual(runtime.halWrites, 0u);
        }];
    }
}
- (void)testExternalOutputChangeDuringRecoveryIsNotOverwritten {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        runtime.onPump = ^{
            if (owner.halWrites) [owner selectSystemBluetoothUID:@"User-Selected-Bluetooth-Full-UID:output"];
        };
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertEqualObjects(runtime.defaultUID, @"User-Selected-Bluetooth-Full-UID:output");
        XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @NO);
    }];
}
- (void)testRecoveryFinalUIDChecksRejectChangesDuringHALAndAuthorizationCapabilityReads {
    // First settable read precedes THRSelectHALIf's final HAL snapshot. Third
    // precedes the second complete authorization sample inside willWrite.
    for (NSNumber *armAtSettable in @[@1, @3]) {
        [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *fixture) {
            THRChangingHALRuntime *runtime = (THRChangingHALRuntime *)fixture;
            runtime.affectedUID = @"aggregate-A-123-Audio";
            __block NSUInteger settableReads = 0;
            __block BOOL changed = NO;
            XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) {
                    runtime.beforeSettable = ^(THRChangingHALRuntime *value) {
                        if (++settableReads != armAtSettable.unsignedIntegerValue) return;
                        value.afterHALRead = ^(THRChangingHALRuntime *source, AudioObjectID object, AudioObjectPropertySelector selector) {
                            if (changed || object != source.affectedObject || selector != kAudioDevicePropertyStreamConfiguration) return;
                            // The just-returned capability still describes the
                            // old object; only a later UID observation sees this.
                            source.replacementUID = @"Reused-Object-Complete-UID";
                            changed = YES;
                        };
                    };
                    operation(); return YES;
                } error:NULL]);
            XCTAssertTrue(changed, @"The intended final capability read must be exercised.");
            XCTAssertEqual(runtime.halWrites, 0u);
            XCTAssertEqualObjects(runtime.defaultUID, @"Bluetooth-Full-UID:output");
        }];
    }
}
- (void)testSnapshotLateStreamChangeRevokesOrRefreshesBothAssociationAndRecovery {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __block NSUInteger reads = 0;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"context"] && [key hasSuffix:@"_ContextUUID"]) reads++;
        };
        NSDictionary *baseline = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects([self dictionary:baseline[@"existingStreamRecovery"]][@"canSelect"], @YES);
        NSUInteger lateRead = reads > 1 ? reads - 1 : 1;
        reads = 0;
        __block BOOL changed = NO;
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"context"] && [key hasSuffix:@"_ContextUUID"] && ++reads == lateRead) {
                [owner setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-456-Audio"]];
                changed = YES;
            }
        };
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertTrue(changed);
        NSDictionary *association = [self dictionary:snapshot[@"existingStreamAssociation"]];
        NSDictionary *recovery = [self dictionary:snapshot[@"existingStreamRecovery"]];
        if (association.count) XCTAssertEqualObjects(association[@"uid"], @"aggregate-A-456-Audio");
        if (recovery.count) {
            XCTAssertEqualObjects(recovery[@"uid"], @"aggregate-A-456-Audio");
            XCTAssertEqualObjects(recovery[@"uid"], association[@"uid"]);
        }
        XCTAssertEqual(runtime.halWrites, 0u);
    }];
}
- (void)testHALFailureOrExceptionAfterActualWriteDoesNotRetryRollbackOrClaimOwnership {
    for (NSNumber *throws in @[@NO, @YES]) {
        [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *fixture) {
            THRChangingHALRuntime *runtime = (THRChangingHALRuntime *)fixture;
            runtime.statusAfterHALWrite = -88;
            runtime.throwAfterHALWrite = throws.boolValue;
            NSError *error = nil;
            XCTAssertFalse([self select:bridge error:&error]);
            XCTAssertEqualObjects(error.domain, THRetainedAudioErrorDomain);
            XCTAssertEqual(error.code, THRetainedAudioErrorCapturedSelectionUnconfirmed);
            XCTAssertEqualObjects(runtime.defaultUID, @"aggregate-A-123-Audio");
            XCTAssertEqual(runtime.halWrites, 1u);
            XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @NO);
            XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"], NSNull.null);
        }];
    }
}
- (void)testHALReturnedErrorCanStillSucceedOnlyAfterCompleteIndependentReadback {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *fixture) {
        THRChangingHALRuntime *runtime = (THRChangingHALRuntime *)fixture;
        runtime.statusAfterHALWrite = -88;
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        runtime.onPump = ^{ if (owner.halWrites) [owner selectSystemAggregate:@"aggregate-A"]; };
        XCTAssertTrue([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.halWrites, 1u);
        [self assertBorrowedSelection:bridge runtime:runtime];
    }];
}
- (void)testClosingAfterHALStopsReadbackWithoutAnotherSystemWrite {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        NSError *error = nil;
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; }
            isShuttingDown:^BOOL{ return runtime.halWrites > 0; }
            performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:&error]);
        XCTAssertEqual(error.code, THRetainedAudioErrorCapturedSelectionUnconfirmed);
        XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects(runtime.defaultUID, @"aggregate-A-123-Audio");
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"], NSNull.null);
    }];
}
- (void)testLastAuthorizationSettableReadCannotRevokeDefaultOutputEligibilityUnnoticed {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *fixture) {
        THRChangingHALRuntime *runtime = (THRChangingHALRuntime *)fixture;
        runtime.affectedUID = @"aggregate-A-123-Audio";
        __block NSUInteger settableReads = 0;
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) {
                runtime.beforeSettable = ^(THRChangingHALRuntime *value) {
                    if (++settableReads == 3) value.deniesDefaultOutput = YES;
                };
                operation(); return YES;
            } error:NULL]);
        XCTAssertTrue(runtime.deniesDefaultOutput);
        XCTAssertEqual(runtime.halWrites, 0u);
    }];
}
- (void)testSelectedReplacementGenerationBeforeThirdConfirmationCannotCompleteOriginalRecovery {
    [self withColdStreamOnBluetooth:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        __block NSUInteger pumps = 0;
        __block BOOL replaced = NO;
        runtime.onHALWrite = ^(NSString *uid) { [owner selectSystemAggregate:@"aggregate-A"]; };
        runtime.onPump = ^{
            if (owner.halWrites && ++pumps == 3) {
                [owner setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-456-Audio"]];
                [owner selectSystemAggregate:@"aggregate-A"];
                replaced = YES;
            }
        };
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertTrue(replaced);
        XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects(runtime.defaultUID, @"aggregate-A-456-Audio");
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @NO);
    }];
}
@end

@implementation THRChangingHALRuntime
- (instancetype)initFixture {
    if ((self = [super initFixture])) {
        _uidReadCounts = [NSMutableDictionary dictionary]; _writtenUIDs = [NSMutableArray array];
    }
    return self;
}
- (OSStatus)halRead:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(const void *)qualifier size:(UInt32 *)size output:(void *)output {
    OSStatus status = [super halRead:object address:address qualifierSize:qualifierSize qualifier:qualifier size:size output:output];
    if (status) return status;
    if (address->mSelector == kAudioHardwarePropertyDevices) [self.uidReadCounts removeAllObjects];
    if (address->mSelector == kAudioDevicePropertyDeviceUID) {
        NSString *uid = (__bridge NSString *)*(CFStringRef *)output;
        if ([uid isEqual:self.affectedUID]) {
            self.affectedObject = object;
            NSUInteger reads = [self.uidReadCounts[@(object)] unsignedIntegerValue] + 1;
            self.uidReadCounts[@(object)] = @(reads);
            if (self.replacementUID && (!self.changesSecondUIDRead || reads == 2)) {
                CFRelease(*(CFStringRef *)output);
                *(CFStringRef *)output = CFRetain((__bridge CFStringRef)self.replacementUID);
            }
        }
    } else if (object == self.affectedObject) {
        if (self.changesTransport && address->mSelector == kAudioDevicePropertyTransportType)
            *(UInt32 *)output = kAudioDeviceTransportTypeUSB;
        if (self.becomesUnavailable && address->mSelector == kAudioDevicePropertyDeviceIsAlive)
            *(UInt32 *)output = 0;
        if (self.deniesDefaultOutput && address->mSelector == kAudioDevicePropertyDeviceCanBeDefaultDevice)
            *(UInt32 *)output = 0;
    }
    if (self.afterHALRead) self.afterHALRead(self, object, address->mSelector);
    return noErr;
}
- (OSStatus)halSettable:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address value:(Boolean *)value {
    if (self.beforeSettable) self.beforeSettable(self);
    return [super halSettable:object address:address value:value];
}
- (OSStatus)halWrite:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(const void *)qualifier size:(UInt32)size value:(const void *)value {
    AudioObjectID target = *(AudioObjectID *)value;
    NSString *uid = [self halString:target selector:kAudioDevicePropertyDeviceUID];
    [self.writtenUIDs addObject:uid ?: @"unreadable"];
    OSStatus status = [super halWrite:object address:address qualifierSize:qualifierSize qualifier:qualifier size:size value:value];
    if (self.throwAfterHALWrite) @throw [NSException exceptionWithName:@"FixtureHALExceptionAfterWrite" reason:nil userInfo:nil];
    return status ?: self.statusAfterHALWrite;
}
@end

@interface RetainedTransactionFailureTests : XCTestCase
@end

@implementation RetainedTransactionFailureTests
- (void)withBluetoothCapture:(BOOL)captured test:(void (^)(THRetainedSystemAudioBridge *, THPrivateAudioRuntimeFixture *))test {
    XCTestExpectation *finished = [self expectationWithDescription:@"Bluetooth context through public bridge entry points"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-123-Audio"]];
        if (captured) [runtime selectSystemAggregate:@"aggregate-A"];
        else [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        if (captured) XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"][@"state"], @"selected");
        [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
        test(bridge, runtime);
        runtime.onRead = nil; runtime.onPump = nil;
        [runtime completeAdd]; [runtime completeRemove];
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop]; [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}
- (void)testBluetoothCapturedOriginalStreamRemainsAssociatedAndReusableWithoutAddOrRemove {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertEqualObjects(retained[@"associatedUID"], @"aggregate-A-123-Audio");
        XCTAssertEqualObjects(retained[@"associationReadbackStable"], @YES);
        XCTAssertEqualObjects(retained[@"canSelect"], @YES);
        XCTAssertEqualObjects(retained[@"isSelected"], @NO);
        XCTAssertTrue([self select:bridge error:NULL]);
        XCTAssertEqualObjects(runtime.defaultUID, @"aggregate-A-123-Audio");
        XCTAssertEqual(runtime.halWrites, 1u); XCTAssertEqual(runtime.adds + runtime.removes, 0u);
        [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
        XCTAssertTrue([self reconcile:bridge error:NULL]);
        XCTAssertEqual(runtime.removes, 0u, @"A system-created borrowed stream never receives Remove permission.");
    }];
}
- (void)testRetainedAssociationReadbackStableUsesCFBooleanForPresentAndMissingStream {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        for (NSNumber *present in @[@YES, @NO]) {
            if (!present.boolValue) [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
            NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
            id stable = retained[@"associationReadbackStable"];
            XCTAssertEqualObjects(stable, present);
            XCTAssertNotNil(stable);
            if (stable) XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)stable), CFBooleanGetTypeID(),
                @"The strict Swift decoder requires CFBoolean; equal numeric 0/1 is insufficient.");
        }
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
    }];
}
- (void)testBluetoothUncapturedStreamHasIdentityAndIndependentRecoveryCapability {
    [self withBluetoothCapture:NO test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        NSDictionary *association = [snapshot[@"existingStreamAssociation"] isKindOfClass:NSDictionary.class] ? snapshot[@"existingStreamAssociation"] : nil;
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        if (version.majorVersion == 27 && version.minorVersion == 0 && version.patchVersion == 1) {
            XCTAssertEqualObjects(association[@"uid"], @"aggregate-A-123-Audio");
            XCTAssertEqualObjects(association[@"readbackStable"], @YES);
            NSDictionary *recovery = [snapshot[@"existingStreamRecovery"] isKindOfClass:NSDictionary.class] ? snapshot[@"existingStreamRecovery"] : nil;
            XCTAssertEqualObjects(recovery[@"canSelect"], @YES);
        } else XCTAssertEqualObjects(snapshot[@"existingStreamAssociation"], NSNull.null);
        XCTAssertEqualObjects(snapshot[@"retained"], NSNull.null);
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
    }];
}
- (void)testBluetoothOwnedStreamCanBeInspectedForExitAndCleanedAfterLeaving {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]);
        [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
        NSDictionary *exit = [bridge ownedStreamForExitWithError:NULL];
        XCTAssertEqualObjects(exit[@"ownedStream"][@"streamUID"], @"stream-A");
        XCTAssertEqual(runtime.removes, 0u, @"Exit preflight is read-only.");
        XCTAssertTrue([self completeNormalLeave:bridge error:NULL]);
        XCTAssertEqual(runtime.removes, 1u); XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects(runtime.defaultUID, @"Bluetooth-Full-UID:output");
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @NO);
    }];
}
- (void)invalidateBluetoothContext:(THPrivateAudioRuntimeFixture *)runtime scenario:(NSUInteger)scenario {
    switch (scenario) {
        case 0: runtime.contextAssociatedAudioDeviceOverride = @"Bluetooth-Full-UID"; break;
        case 1: runtime.contextAssociatedAudioDeviceOverride = NSNull.null; break;
        case 2: runtime.contextAssociatedAudioDeviceOverride = @7; break;
        case 3: runtime.associatedStatus = -81; break;
        case 4: runtime.contextRouteIdentifiers = @[]; break;
        case 5: runtime.contextRouteIdentifiers = @[@"bluetooth-route-A", @"bluetooth-route-B"]; break;
        case 6: runtime.routesWrongType = YES; break;
        case 7: runtime.routesStatus = -82; break;
        case 8: runtime.bluetoothRouteProperties = @{@"Type":@"kFigEndpointType_Unknown"}; break;
        case 9: runtime.bluetoothRouteProperties = @{@"IsActivated":@NO}; break;
        case 10: runtime.bluetoothRouteProperties = @{@"IsActivated":NSNull.null}; break;
        case 11: runtime.bluetoothRouteStatuses = @{@"Type":@(-83)}; break;
        case 12: runtime.bluetoothRouteStatuses = @{@"IsActivated":@(-84)}; break;
        case 13: runtime.contextBufferedAggregateOverride = @"aggregate-A"; break;
        case 14: runtime.contextBufferedAggregateOverride = @23; break;
        case 15: runtime.bufferedStatus = -85; break;
        case 16: runtime.bluetoothRouteProperties = @{@"Type":NSNull.null}; break;
        case 17: runtime.bluetoothRouteProperties = @{@"ID":NSNull.null}; break;
        default: XCTFail(@"Unknown Bluetooth fixture scenario");
    }
}
- (void)testBluetoothUnknownConflictingOrFailedContextKeepsHeldIdentityButRejectsSelection {
    for (NSUInteger scenario = 0; scenario < 18; scenario++) {
        [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            [self invalidateBluetoothContext:runtime scenario:scenario];
            NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
            XCTAssertEqualObjects(retained[@"associatedUID"], @"aggregate-A-123-Audio", @"scenario %lu", scenario);
            XCTAssertEqualObjects(retained[@"associationReadbackStable"], @YES, @"scenario %lu", scenario);
            XCTAssertEqualObjects(retained[@"canSelect"], @NO, @"scenario %lu", scenario);
            XCTAssertEqualObjects(retained[@"isSelected"], @NO, @"scenario %lu", scenario);
            XCTAssertFalse([self select:bridge error:NULL], @"scenario %lu", scenario);
            XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u, @"scenario %lu", scenario);
        }];
    }
}
- (void)testBluetoothUncapturedIdentityRejectsUnknownConflictingOrFailedContext {
    for (NSUInteger scenario = 0; scenario < 18; scenario++) {
        [self withBluetoothCapture:NO test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            [self invalidateBluetoothContext:runtime scenario:scenario];
            id association = [bridge snapshotWithError:NULL][@"existingStreamAssociation"];
            XCTAssertTrue(!association || association == NSNull.null, @"scenario %lu", scenario);
            XCTAssertFalse([self select:bridge error:NULL]);
            XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u, @"scenario %lu", scenario);
        }];
    }
}
- (void)testBluetoothReplacementStreamHasIdentityButCannotInheritCaptureOrRemovePermission {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-456-Audio"]];
        NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertEqualObjects(retained[@"associatedUID"], @"aggregate-A-456-Audio");
        XCTAssertEqualObjects(retained[@"associationReadbackStable"], @YES);
        XCTAssertEqualObjects(retained[@"canSelect"], @NO); XCTAssertEqualObjects(retained[@"isSelected"], @NO);
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertTrue([self reconcile:bridge error:NULL]);
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
    }];
}
- (void)testBluetoothDisappearedCapturedStreamRetainsNormalAddAndOwnedCleanupPath {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertEqualObjects(retained[@"associatedUID"], NSNull.null);
        XCTAssertEqualObjects(retained[@"associationReadbackStable"], @NO);
        XCTAssertEqualObjects(retained[@"canSelect"], @YES);
        XCTAssertTrue([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
        [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
        XCTAssertTrue([self completeNormalLeave:bridge error:NULL]); XCTAssertEqual(runtime.removes, 1u);
    }];
}
- (void)testBluetoothContextRouteIdentityChangingBetweenReadsRejectsReuse {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        __block NSUInteger routes = 0;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"context"] && [key isEqual:@"CopyRoutes"])
                owner.contextRouteIdentifiers = @[++routes % 2 ? @"bluetooth-route-A" : @"bluetooth-route-B"];
        };
        NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertEqualObjects(retained[@"associatedUID"], @"aggregate-A-123-Audio");
        XCTAssertEqualObjects(retained[@"canSelect"], @NO);
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
    }];
}
- (void)testBluetoothAssociatedUIDChangingBetweenReadsRejectsReuse {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        __block NSUInteger reads = 0;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"context"] && [key hasSuffix:@"_AssociatedAudioDevice"])
                owner.contextAssociatedAudioDeviceOverride = ++reads % 2 ? @"Bluetooth-Full-UID:output" : @"different-full-UID";
        };
        NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertEqualObjects(retained[@"associatedUID"], @"aggregate-A-123-Audio");
        XCTAssertEqualObjects(retained[@"canSelect"], @NO);
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
    }];
}
- (void)testBluetoothStreamIdentityChangingBetweenReadsDoesNotPublishAssociationOrCapability {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        __block NSUInteger reads = 0;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"aggregate"] && [key hasSuffix:@"_Streams"])
                [owner setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[++reads % 2 ? @"aggregate-A-123-Audio" : @"aggregate-A-456-Audio"]];
        };
        NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertEqualObjects(retained[@"associatedUID"], NSNull.null);
        XCTAssertEqualObjects(retained[@"associationReadbackStable"], @NO);
        XCTAssertEqualObjects(retained[@"canSelect"], @NO);
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
    }];
}
- (void)testBluetoothLateStreamReplacementRevokesEarlierSnapshotAssociation {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __weak THPrivateAudioRuntimeFixture *owner = runtime;
        __block NSUInteger reads = 0;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            // The first three public aggregate reads cover capture refresh,
            // initial snapshot and its identity readback. Change a later read.
            if ([kind isEqual:@"aggregate"] && [key hasSuffix:@"_Streams"] && ++reads == 4)
                [owner setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-456-Audio"]];
        };
        NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertGreaterThanOrEqual(reads, 4u);
        XCTAssertEqualObjects(retained[@"associatedUID"], NSNull.null);
        XCTAssertEqualObjects(retained[@"associationReadbackStable"], @NO);
        XCTAssertEqualObjects(retained[@"canSelect"], @NO);
        XCTAssertEqualObjects(retained[@"catalogRoute"], NSNull.null);
        runtime.onRead = nil;
        retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertEqualObjects(retained[@"associatedUID"], @"aggregate-A-456-Audio");
        XCTAssertEqualObjects(retained[@"associationReadbackStable"], @YES);
        XCTAssertEqualObjects(retained[@"canSelect"], @NO);
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
    }];
}
- (void)testBluetoothDefaultHALIdentityOrTransportChangesRejectReuse {
    for (NSNumber *transportChange in @[@NO, @YES]) {
        [self withIdentityRuntimeBorrowed:YES test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
            [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
            runtime.affectedUID = @"Bluetooth-Full-UID:output";
            if (transportChange.boolValue) runtime.changesTransport = YES;
            else { runtime.replacementUID = @"Bluetooth-Other-Full-UID:output"; runtime.changesSecondUIDRead = YES; }
            NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
            XCTAssertEqualObjects(retained[@"associatedUID"], @"captured-stream");
            XCTAssertEqualObjects(retained[@"canSelect"], @NO);
            XCTAssertFalse([self select:bridge error:NULL]);
            XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
        }];
    }
}
- (void)testBluetoothDuplicateHALUIDCannotAuthorizeSelection {
    [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime setAggregate:@"other-aggregate" receiver:@"receiver-B" streams:@[@"Bluetooth-Full-UID:output"]];
        NSDictionary *retained = [bridge snapshotWithError:NULL][@"retained"];
        XCTAssertEqualObjects(retained[@"associatedUID"], @"aggregate-A-123-Audio");
        XCTAssertEqualObjects(retained[@"canSelect"], @NO);
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
    }];
}
- (void)testBluetoothCleanupRechecksContextInsideMutationGate {
    for (NSNumber *switchBack in @[@NO, @YES]) {
        [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            XCTAssertTrue([self select:bridge error:NULL]);
            [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
            XCTAssertFalse([bridge completedLeaveIsShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) {
                    if (switchBack.boolValue) [runtime selectSystemAggregate:@"aggregate-A"];
                    else runtime.contextAssociatedAudioDeviceOverride = @"unrelated-output";
                    operation(); return YES;
                } error:NULL]);
            XCTAssertEqual(runtime.removes, 0u); XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
            XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @YES);
        }];
    }
}
- (void)testBluetoothCancellationAndRejectedGateDoNotSubmitBorrowedSelection {
    for (NSNumber *cancelled in @[@YES, @NO]) {
        [self withBluetoothCapture:YES test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
            XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return cancelled.boolValue; } isShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) { return NO; } error:NULL]);
            XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
            XCTAssertTrue([self select:bridge error:NULL]); XCTAssertEqual(runtime.halWrites, 1u);
            XCTAssertEqual(runtime.adds + runtime.removes, 0u);
        }];
    }
}
- (void)testBluetoothClosedGatePreventsOwnedCleanupAndShutdownNeverRemoves {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]);
        [runtime selectSystemBluetoothUID:@"Bluetooth-Full-UID:output"];
        (void)[bridge reconcileRuntimeStateIsShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) { return NO; } error:NULL];
        XCTAssertEqual(runtime.removes, 0u);
        (void)[bridge reconcileRuntimeStateIsShuttingDown:^{ return YES; }
            performIfRunning:^BOOL(void (^operation)(void)) { XCTFail(@"Shutdown cannot reach a mutation gate"); operation(); return YES; } error:NULL];
        XCTAssertTrue([bridge shutdownWithError:NULL]);
        XCTAssertEqual(runtime.removes, 0u); XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)withReusableCapture:(void (^)(THRetainedSystemAudioBridge *, THPrivateAudioRuntimeFixture *))test {
    XCTestExpectation *finished = [self expectationWithDescription:@"transaction failure through public entry points"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"captured-stream"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"][@"state"], @"selected");
        [runtime selectSystemAggregate:nil];
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        test(bridge, runtime);
        runtime.onRead = nil; runtime.onPump = nil;
        [runtime completeAdd]; [runtime completeRemove];
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop];
        [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}
- (BOOL)select:(THRetainedSystemAudioBridge *)bridge error:(NSError **)error {
    return [bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:error];
}
- (BOOL)reconcile:(THRetainedSystemAudioBridge *)bridge error:(NSError **)error {
    return [bridge reconcileRuntimeStateIsShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:error];
}
- (void)testSynchronousAddFailureWithConfirmedEmptyRouteNeverWritesHALAndAllowsLaterSelection {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.addStatus = -77;
        NSError *error = nil;
        XCTAssertFalse([self select:bridge error:&error]);
        XCTAssertEqualObjects(error.domain, THRetainedAudioErrorDomain); XCTAssertEqual(error.code, -77);
        XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.removes, 0u); XCTAssertEqual(runtime.halWrites, 0u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @NO);
        runtime.addStatus = 0;
        XCTAssertTrue([self select:bridge error:NULL]); XCTAssertEqual(runtime.adds, 2u);
        XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)testSynchronousRemoveFailureKeepsOwnershipAndNeverResubmits {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]);
        [runtime selectSystemAggregate:nil]; runtime.removeStatus = -88;
        NSError *error = nil;
        for (NSUInteger i = 0; i < 3; i++) {
            XCTAssertFalse([self reconcile:bridge error:&error]);
            XCTAssertEqualObjects(error.domain, THRetainedAudioErrorDomain);
            XCTAssertEqual(error.code, THRetainedAudioErrorCleanupBlocked);
        }
        XCTAssertEqual(runtime.removes, 1u); XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"ownedMember"], @YES);
        XCTAssertEqualObjects(snapshot[@"retained"][@"canSelect"], @NO);
    }];
}
- (void)testRejectedAddGateDoesNotSubmitOrAcquireOwnership {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        NSError *error = nil;
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) { return NO; } error:&error]);
        XCTAssertEqual(error.code, NSUserCancelledError);
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @NO);
        XCTAssertTrue([self select:bridge error:NULL]); XCTAssertEqual(runtime.adds, 1u);
    }];
}
- (void)testAddExceptionAfterSubmissionRetainsPendingOperationWithoutSecondAdd {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
        runtime.throwFromAdd = YES;
        NSError *error = nil;
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) { return [gate performIfRunning:operation]; } error:&error]);
        XCTAssertEqual(error.code, THRetainedAudioErrorSelectionFailed);
        XCTAssertTrue(runtime.addCallbackPending);
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertFalse([self reconcile:bridge error:NULL]);
        XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.removes, 0u); XCTAssertEqual(runtime.halWrites, 0u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @YES);
        XCTAssertTrue([bridge shutdownWithError:NULL]); [runtime completeAdd];
        XCTAssertFalse(runtime.addCallbackPending); XCTAssertEqual(runtime.removes + runtime.halWrites, 0u);
        [gate close];
        XCTestExpectation *drained = [self expectationWithDescription:@"throwing native submission drained through Swift"];
        [gate drainWithCompletion:^{ [drained fulfill]; }];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[drained] timeout:2], XCTWaiterResultCompleted);
    }];
}
- (void)testRemoveExceptionAfterSubmissionNeverResubmitsBeforeLateCallback {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]); [runtime selectSystemAggregate:nil];
        THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
        runtime.throwFromRemove = YES;
        for (NSUInteger i = 0; i < 3; i++) {
            NSError *error = nil;
            XCTAssertFalse([bridge reconcileRuntimeStateIsShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) { return [gate performIfRunning:operation]; } error:&error]);
            XCTAssertEqual(error.code, THRetainedAudioErrorCleanupBlocked);
        }
        XCTAssertTrue(runtime.removeCallbackPending);
        XCTAssertEqual(runtime.removes, 1u); XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @YES);
        XCTAssertTrue([bridge shutdownWithError:NULL]); [runtime completeRemove];
        XCTAssertFalse(runtime.removeCallbackPending); XCTAssertEqual(runtime.removes, 1u);
        [gate close];
        XCTestExpectation *drained = [self expectationWithDescription:@"throwing native submission drained through Swift"];
        [gate drainWithCompletion:^{ [drained fulfill]; }];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[drained] timeout:2], XCTWaiterResultCompleted);
    }];
}
- (void)testRejectedRemoveGateDoesNotMarkSubmittedOrPreventLaterSafeCleanup {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]); [runtime selectSystemAggregate:nil];
        XCTAssertTrue([bridge reconcileRuntimeStateIsShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) { return NO; } error:NULL]);
        XCTAssertEqual(runtime.removes, 0u); XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @YES);
        (void)[self reconcile:bridge error:NULL]; XCTAssertTrue([self reconcile:bridge error:NULL]);
        XCTAssertEqual(runtime.removes, 1u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @NO);
    }];
}
- (BOOL)completeNormalLeave:(THRetainedSystemAudioBridge *)bridge error:(NSError **)error {
    return [bridge completedLeaveIsShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:error];
}
- (void)testCompletedLeaveJoinsExistingPendingRemoveWithoutResubmission {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]);
        [runtime selectSystemAggregate:nil]; runtime.deferRemove = YES;
        XCTAssertFalse([self reconcile:bridge error:NULL]);
        XCTAssertTrue(runtime.removeCallbackPending); XCTAssertEqual(runtime.removes, 1u);
        __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
        runtime.onPump = ^{ [weakRuntime completeRemove]; };
        XCTAssertTrue([self completeNormalLeave:bridge error:NULL]);
        XCTAssertFalse(runtime.removeCallbackPending);
        XCTAssertEqual(runtime.removes, 1u); XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @NO);
    }];
}
- (void)testNormalLeaveRechecksExactStreamInsideAcceptedGateBeforeRemove {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]);
        [runtime selectSystemAggregate:nil];
        XCTAssertFalse([bridge completedLeaveIsShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) {
                [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"replacement-before-submit"]];
                operation(); return YES;
            } error:NULL]);
        XCTAssertEqual(runtime.removes, 0u); XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)testCompletedLeavePendingRemoveUsesNormalBudgetAndSurvivesShutdown {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]);
        [runtime selectSystemAggregate:nil]; runtime.deferRemove = YES;
        NSTimeInterval started = runtime.time;
        NSError *error = nil;
        XCTAssertFalse([self completeNormalLeave:bridge error:&error]);
        XCTAssertEqual(error.code, THRetainedAudioErrorPending);
        XCTAssertGreaterThanOrEqual(runtime.time - started, 15.0);
        XCTAssertLessThan(runtime.time - started, 15.1);
        XCTAssertTrue(runtime.removeCallbackPending);
        XCTAssertTrue([bridge shutdownWithError:NULL]);
        [runtime completeRemove];
        XCTAssertFalse(runtime.removeCallbackPending);
        XCTAssertEqual(runtime.removes, 1u); XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)testCompletedLeaveRequiresEmptyReadbackAfterSuccessfulCallback {
    [self withReusableCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self select:bridge error:NULL]);
        [runtime selectSystemAggregate:nil];
        __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if (weakRuntime.removes && [kind isEqual:@"manager"] && [key hasSuffix:@"_ShowInfo"])
                [weakRuntime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-A"]];
        };
        NSTimeInterval started = runtime.time;
        NSError *error = nil;
        XCTAssertFalse([self completeNormalLeave:bridge error:&error]);
        XCTAssertEqual(error.code, THRetainedAudioErrorCleanupBlocked);
        XCTAssertEqualObjects(error.userInfo[@"diagnostics"][@"reason"], @"removeNotConfirmed");
        XCTAssertGreaterThanOrEqual(runtime.time - started, 3.0);
        XCTAssertLessThan(runtime.time - started, 3.1);
        XCTAssertEqual(runtime.removes, 1u); XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 1u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @YES);
    }];
}

- (void)withIdentityRuntimeBorrowed:(BOOL)borrowed test:(void (^)(THRetainedSystemAudioBridge *, THRChangingHALRuntime *))test {
    XCTestExpectation *finished = [self expectationWithDescription:@"HAL identity through normal retained bridge entry points"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        THRChangingHALRuntime *runtime = [[THRChangingHALRuntime alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"captured-stream"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"][@"state"], @"selected");
        [runtime selectSystemAggregate:nil];
        if (!borrowed) [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        test(bridge, runtime);
        runtime.beforeSettable = nil;
        [runtime completeAdd]; [runtime completeRemove];
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop];
        [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}
- (void)testHALIdentityBorrowedSnapshotRejectsChangedSecondUIDRead {
    [self withIdentityRuntimeBorrowed:YES test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
        runtime.affectedUID = @"captured-stream"; runtime.replacementUID = @"replacement-stream";
        runtime.changesSecondUIDRead = YES;
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(snapshot[@"retained"][@"canSelect"], @NO);
        XCTAssertEqualObjects(snapshot[@"retained"][@"associatedUID"], NSNull.null);
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
    }];
}
- (void)testHALIdentityBorrowedSelectionRechecksInsideSubmissionGate {
    [self withIdentityRuntimeBorrowed:YES test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
        runtime.affectedUID = @"captured-stream";
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) {
                runtime.replacementUID = @"replacement-stream"; operation(); return YES;
            } error:NULL]);
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
        XCTAssertEqualObjects(runtime.defaultUID, @"local");
    }];
}
- (void)testHALIdentityNewAddSelectionRechecksInsideSubmissionGate {
    [self withIdentityRuntimeBorrowed:NO test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
        runtime.affectedUID = @"stream-A";
        __block NSUInteger submissions = 0;
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) {
                if (++submissions == 2) runtime.replacementUID = @"replacement-stream";
                operation(); return YES;
            } error:NULL]);
        XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.halWrites, 0u);
        XCTAssertLessThanOrEqual(runtime.removes, 1u);
        XCTAssertEqualObjects(runtime.defaultUID, @"local");
    }];
}
- (void)testHALIdentityBorrowedRollbackRechecksLocalTargetInsideSubmissionGate {
    [self withIdentityRuntimeBorrowed:YES test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
        runtime.affectedUID = @"local";
        __block NSUInteger submissions = 0;
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^BOOL{ return runtime.halWrites > 0; } isShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) {
                if (++submissions == 2) runtime.replacementUID = @"different-local-device";
                operation(); return YES;
            } error:NULL]);
        XCTAssertEqualObjects(runtime.writtenUIDs, (@[@"captured-stream"]));
        XCTAssertEqual(runtime.adds + runtime.removes, 0u);
    }];
}
- (void)testHALIdentityOwnedRollbackRechecksLocalTargetInsideSubmissionGate {
    [self withIdentityRuntimeBorrowed:NO test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
        runtime.affectedUID = @"local";
        __block NSUInteger submissions = 0;
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^BOOL{ return runtime.halWrites > 0; } isShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) {
                if (++submissions == 3) runtime.replacementUID = @"different-local-device";
                operation(); return YES;
            } error:NULL]);
        XCTAssertEqualObjects(runtime.writtenUIDs, (@[@"stream-A"]));
        XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.removes, 0u);
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @YES);
    }];
}
- (void)testHALIdentitySelectionRejectsUIDChangeDuringSettableRead {
    [self withIdentityRuntimeBorrowed:YES test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
        runtime.affectedUID = @"captured-stream";
        runtime.beforeSettable = ^(THRChangingHALRuntime *value) { value.replacementUID = @"replacement-stream"; };
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.halWrites, 0u);
    }];
}
- (void)testHALIdentitySelectionRejectsTransportChangeDuringSettableRead {
    [self withIdentityRuntimeBorrowed:YES test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
        runtime.affectedUID = @"captured-stream";
        runtime.beforeSettable = ^(THRChangingHALRuntime *value) { value.changesTransport = YES; };
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.halWrites, 0u);
    }];
}
- (void)testHALIdentitySelectionRejectsUnavailableDeviceDuringSettableRead {
    [self withIdentityRuntimeBorrowed:YES test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
        runtime.affectedUID = @"captured-stream";
        runtime.beforeSettable = ^(THRChangingHALRuntime *value) { value.becomesUnavailable = YES; };
        XCTAssertFalse([self select:bridge error:NULL]);
        XCTAssertEqual(runtime.halWrites, 0u);
    }];
}
- (void)testHALIdentityUnchangedBorrowedAndNewAddSelectionsStillSucceed {
    for (NSNumber *borrowed in @[@YES, @NO]) {
        [self withIdentityRuntimeBorrowed:borrowed.boolValue test:^(THRetainedSystemAudioBridge *bridge, THRChangingHALRuntime *runtime) {
            XCTAssertTrue([self select:bridge error:NULL]);
            XCTAssertEqualObjects(runtime.writtenUIDs, (@[borrowed.boolValue ? @"captured-stream" : @"stream-A"]));
            XCTAssertEqual(runtime.adds, borrowed.boolValue ? 0u : 1u);
        }];
    }
}
- (void)testHALIdentityExistingAssociationRejectsChangedSecondUIDRead {
    XCTestExpectation *finished = [self expectationWithDescription:@"existing stream identity stays inside its matching UID"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        THRChangingHALRuntime *runtime = [[THRChangingHALRuntime alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"aggregate-A-1-Audio"]];
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        NSDictionary *baseline = [bridge snapshotWithError:NULL];
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        if (version.majorVersion == 27 && version.minorVersion == 0 && version.patchVersion == 1) {
            XCTAssertEqualObjects(baseline[@"existingStreamAssociation"][@"uid"], @"aggregate-A-1-Audio");
            runtime.affectedUID = @"aggregate-A-1-Audio"; runtime.replacementUID = @"unrelated-stream";
            runtime.changesSecondUIDRead = YES;
            XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"existingStreamAssociation"], NSNull.null);
        } else {
            XCTAssertEqualObjects(baseline[@"existingStreamAssociation"], NSNull.null);
        }
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop]; [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}
- (void)testServiceLeaseSurvivesCustomExecutorAndNativeGateWithoutLosingOwnedAdd {
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    XCTestExpectation *finished = [self expectationWithDescription:@"task-local epoch reaches the real native mutation gate"];
    [gate runWithServiceLease:^{ @autoreleasepool {
        XCTAssertFalse(NSThread.isMainThread);
        XCTAssertTrue(gate.hasServiceLease);
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"captured-stream"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
            performIfRunning:^BOOL(void (^operation)(void)) { return [gate performIfRunning:operation]; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"][@"state"], @"selected");
        [runtime selectSystemAggregate:nil];
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        __block NSUInteger submissions = 0;
        XCTAssertFalse([bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) {
                XCTAssertTrue(gate.hasServiceLease, @"The synchronous ObjC callback must retain its calling task's lease.");
                if (++submissions == 2) XCTAssertTrue([gate revokeServiceLease]);
                return [gate performIfRunning:operation];
            } error:NULL]);
        XCTAssertEqual(runtime.adds, 1u, @"The Add registered before reset remains a real owned operation.");
        XCTAssertEqual(runtime.halWrites, 0u, @"The same native call must not submit HAL after epoch revocation.");
        XCTAssertEqual(runtime.removes, 0u, @"Cleanup cannot escape the revoked epoch either.");
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"ownedMember"], @YES);
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop]; [gate close];
    }} completion:^{ [finished fulfill]; }];
    [self waitForExpectations:@[finished] timeout:5];
}
@end
