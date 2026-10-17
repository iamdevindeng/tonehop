#import <XCTest/XCTest.h>
#import "../Sources/Services/THRetainedSystemAudioBridge.h"
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "../Sources/Services/THPrivateAudioErrors.h"
#import "THPrivateAudioRuntimeFixture.h"

@interface RetainedOwnershipRecoveryTests : XCTestCase
@end
@implementation RetainedOwnershipRecoveryTests
- (BOOL)select:(THRetainedSystemAudioBridge *)bridge {
    return [bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL];
}
- (BOOL)reconcile:(THRetainedSystemAudioBridge *)bridge {
    return [bridge reconcileRuntimeStateIsShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL];
}
- (NSDictionary *)snapshot:(THRetainedSystemAudioBridge *)bridge { return [bridge snapshotWithError:NULL]; }
- (void)assertOwned:(THRetainedSystemAudioBridge *)bridge {
    XCTAssertEqualObjects([self snapshot:bridge][@"diagnostics"][@"ownedMember"], @YES);
}
- (void)assertNotOwned:(THRetainedSystemAudioBridge *)bridge {
    XCTAssertEqualObjects([self snapshot:bridge][@"diagnostics"][@"ownedMember"], @NO);
}
- (void)withSetup:(void (^)(THPrivateAudioRuntimeFixture *))setup test:(void (^)(THRetainedSystemAudioBridge *, THPrivateAudioRuntimeFixture *))test {
    XCTestExpectation *finished = [self expectationWithDescription:@"isolated public bridge lifecycle"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"captured-stream"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        XCTAssertEqualObjects([self snapshot:bridge][@"retained"][@"state"], @"selected");
        [runtime selectSystemAggregate:nil];
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        if (setup) setup(runtime);
        BOOL selected = [self select:bridge];
        if (!runtime.deferAdd && !runtime.mismatchAdd && !runtime.addStatus && !runtime.omitAddStream) XCTAssertTrue(selected);
        XCTAssertEqual(runtime.adds, 1u);
        test(bridge, runtime);
        runtime.onRead = nil; runtime.onPump = nil;
        [runtime completeAdd]; [runtime completeRemove];
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop];
        [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}
- (void)withOwned:(void (^)(THRetainedSystemAudioBridge *, THPrivateAudioRuntimeFixture *))test { [self withSetup:nil test:test]; }
- (void)replaceLocally:(THPrivateAudioRuntimeFixture *)runtime receiver:(NSString *)receiver stream:(NSString *)stream {
    [runtime selectSystemAggregate:nil]; [runtime setAggregate:@"aggregate-A" receiver:receiver streams:stream ? @[stream] : @[]];
}
- (void)testExternalSameReceiverGenerationCanRetireAndReopenCapture {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:@"receiver-A" stream:@"stream-B"];
        XCTAssertTrue([self reconcile:bridge]); [self assertNotOwned:bridge];
        XCTAssertEqualObjects([self snapshot:bridge][@"diagnostics"][@"state"], @"uncaptured");
        XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testDifferentReceiverReplacementCanRetire {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:@"receiver-B" stream:@"stream-B"];
        XCTAssertTrue([self reconcile:bridge]); [self assertNotOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testReplacementRetirementNeverRemovesItsSurvivingStream {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:@"receiver-A" stream:@"stream-B"];
        for (NSUInteger i = 0; i < 3; i++) XCTAssertTrue([self reconcile:bridge]);
        XCTAssertEqual(runtime.removes, 0u); XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)testPendingAddKeepsOwnershipUntilItsCallbackCompletes {
    [self withSetup:^(THPrivateAudioRuntimeFixture *runtime) { runtime.deferAdd = YES; }
        test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:@"receiver-A" stream:@"stream-B"];
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge];
        XCTAssertTrue(runtime.addCallbackPending); XCTAssertEqual(runtime.removes, 0u);
        [runtime completeAdd];
        // No stream was witnessed before the timeout: a nonempty replacement
        // still cannot prove which generation belonged to the failed Add.
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge];
        // Publicly reachable recovery: after the delayed callback, the system
        // clears the member and two stable local observations release ownership.
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        XCTAssertTrue([self reconcile:bridge]); [self assertNotOwned:bridge];
        XCTAssertEqualObjects([self snapshot:bridge][@"retained"][@"state"], @"retained");
        runtime.deferAdd = NO; XCTAssertTrue([self select:bridge]);
        XCTAssertEqual(runtime.adds, 2u);
    }];
}
- (void)testPendingRemoveKeepsOwnershipUntilItsCallbackCompletes {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.deferRemove = YES; [runtime selectSystemAggregate:nil];
        XCTAssertFalse([self reconcile:bridge]); XCTAssertTrue(runtime.removeCallbackPending);
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-B" streams:@[@"stream-B"]];
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge];
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        [runtime completeRemove]; XCTAssertTrue([self reconcile:bridge]); [self assertNotOwned:bridge];
        XCTAssertEqualObjects([self snapshot:bridge][@"diagnostics"][@"state"], @"uncaptured");
        XCTAssertEqual(runtime.removes, 1u);
    }];
}
- (void)testMismatchedAddCallbackCannotAuthorizeRetirement {
    [self withSetup:^(THPrivateAudioRuntimeFixture *runtime) { runtime.mismatchAdd = YES; }
        test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:@"receiver-A" stream:@"stream-B"];
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testMismatchedRemoveCallbackCannotAuthorizeRetirement {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.mismatchRemove = YES; [runtime selectSystemAggregate:nil];
        XCTAssertFalse([self reconcile:bridge]);
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-B"]];
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 1u);
    }];
}
- (void)testTransientMissingViewDoesNotDiscardReferences {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.propertyStatus = -7; XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge];
        runtime.propertyStatus = 0; XCTAssertTrue([self reconcile:bridge]); [self assertOwned:bridge];
        XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testChangedReadbackDoesNotRetireAfterOneSample {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:@"receiver-A" stream:@"stream-B"];
        __block NSUInteger reads = 0; __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"manager"] && [key hasSuffix:@"_ShowInfo"])
                [weakRuntime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[(++reads % 2) ? @"stream-B" : @"stream-C"]];
        };
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testExactOwnedStreamSelectedRemainsOwned {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
        XCTAssertEqualObjects([self snapshot:bridge][@"diagnostics"][@"state"], @"selected");
        XCTAssertEqualObjects([self snapshot:bridge][@"diagnostics"][@"ownStreamUID"], @"stream-A");
    }];
}
- (void)testInvalidationAloneCannotRetireTheStillPresentOwnedStream {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-B" streams:@[@"stream-A"]];
        (void)[self snapshot:bridge]; XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge];
        XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testReadOnlySnapshotDoesNotSubmitCleanupForExactOwnedStream {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime selectSystemAggregate:nil];
        for (NSUInteger i = 0; i < 3; i++) (void)[self snapshot:bridge];
        [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u); XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)testSelectedExternalGenerationCanRetireAndCaptureTheVerifiedSystemRoute {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-B"]]; [runtime selectSystemAggregate:@"aggregate-A"];
        XCTAssertTrue([self reconcile:bridge]); [self assertNotOwned:bridge];
        NSDictionary *snapshot = [self snapshot:bridge];
        XCTAssertEqualObjects(snapshot[@"retained"][@"state"], @"selected");
        XCTAssertEqualObjects(snapshot[@"retained"][@"canSelect"], @YES);
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"captureStreamUID"], @"stream-B");
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"captureState"], @"captured");
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"captureSource"], @"copyRoutes");
        XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testEmptyOldAggregateCanRetireWhenTheSystemSelectedANewAggregate {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        [runtime setAggregate:@"aggregate-B" receiver:@"receiver-A" streams:@[@"stream-B"]]; [runtime selectSystemAggregate:@"aggregate-B"];
        XCTAssertTrue([self reconcile:bridge]); [self assertNotOwned:bridge];
        XCTAssertEqualObjects([self snapshot:bridge][@"retained"][@"state"], @"selected"); XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testMissingHALReadbackDoesNotAuthorizeSelectedReplacementRetirement {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-B"]]; [runtime selectSystemAggregate:@"aggregate-A"];
        runtime.invalidHAL = YES; XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testAssociatedUIDMismatchDoesNotAuthorizeSelectedReplacementRetirement {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-B"]]; [runtime selectSystemAggregate:@"aggregate-A"];
        runtime.invalidAssociation = YES; XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testNormalCompletedEmptyAggregateKeepsTheCapturedReferencesForReuse {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:nil stream:nil]; XCTAssertTrue([self reconcile:bridge]); [self assertNotOwned:bridge];
        XCTAssertEqualObjects([self snapshot:bridge][@"retained"][@"state"], @"retained");
        XCTAssertTrue([self select:bridge]); XCTAssertEqual(runtime.adds, 2u); XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testMemberTemporarilyMissingAudioDoesNotRetire {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:@"receiver-A" stream:nil];
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testUnwitnessedOwnStreamCannotTreatANonemptyRouteAsReplacement {
    [self withSetup:^(THPrivateAudioRuntimeFixture *runtime) { runtime.omitAddStream = YES; }
        test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self replaceLocally:runtime receiver:@"receiver-A" stream:@"stream-B"];
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testOriginalStreamAmongMultipleMembersPreventsRetirement {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime selectSystemAggregate:nil];
        [runtime setAggregate:@"aggregate-A" receivers:@[@"receiver-A", @"receiver-B"] streams:@[@"stream-A", @"stream-B"]];
        XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testShutdownReleasesReferencesWithoutInspectingOrMutatingTheSystemRoute {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        NSUInteger reads = runtime.halReads, writes = runtime.halWrites, adds = runtime.adds, removes = runtime.removes;
        XCTAssertTrue([bridge shutdownWithError:NULL]);
        XCTAssertEqual(runtime.halReads, reads); XCTAssertEqual(runtime.halWrites, writes);
        XCTAssertEqual(runtime.adds, adds); XCTAssertEqual(runtime.removes, removes);
    }];
}
- (void)testInvalidContextKeepsTheOwnedTransaction {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.invalidContext = YES; XCTAssertFalse([self reconcile:bridge]); [self assertOwned:bridge]; XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testNormalOwnedStreamLeavingForLocalRemovesOnlyItsExactMemberOnce {
    [self withOwned:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime selectSystemAggregate:nil]; [self reconcile:bridge];
        XCTAssertTrue([self reconcile:bridge]); XCTAssertTrue([self reconcile:bridge]);
        [self assertNotOwned:bridge]; XCTAssertEqual(runtime.removes, 1u);
        XCTAssertEqualObjects([self snapshot:bridge][@"retained"][@"identifier"], @"receiver-A");
        XCTAssertEqualObjects([self snapshot:bridge][@"retained"][@"state"], @"retained");
    }];
}
- (void)testShutdownDuringPendingCallbackKeepsCallbackCapsuleAlive {
    [self withSetup:^(THPrivateAudioRuntimeFixture *runtime) { runtime.deferAdd = YES; }
        test:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue(runtime.addCallbackPending); NSUInteger writes = runtime.halWrites;
        XCTAssertTrue([bridge shutdownWithError:NULL]); [runtime completeAdd];
        XCTAssertFalse(runtime.addCallbackPending); XCTAssertEqual(runtime.halWrites, writes); XCTAssertEqual(runtime.removes, 0u);
    }];
}
@end
