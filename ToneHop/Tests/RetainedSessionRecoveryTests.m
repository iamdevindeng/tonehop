#import <XCTest/XCTest.h>
#import "../Sources/Services/THRetainedSystemAudioBridge.h"
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

@interface RetainedSessionRecoveryTests : XCTestCase
@end
@implementation RetainedSessionRecoveryTests
- (NSDictionary *)retained:(NSDictionary *)snapshot {
    id value = snapshot[@"retained"];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (void)withColdBridge:(void (^)(THRetainedSystemAudioBridge *, THPrivateAudioRuntimeFixture *))test {
    XCTestExpectation *finished = [self expectationWithDescription:@"isolated session recovery"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"state"], @"uncaptured");
        test(bridge, runtime);
        runtime.onCopyContext = nil; runtime.onCopyManager = nil; runtime.onRead = nil; runtime.onPump = nil;
        [runtime completeAdd]; [runtime completeRemove];
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop];
        [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}
- (void)selectSystem:(THPrivateAudioRuntimeFixture *)runtime {
    [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"system-stream"]];
    [runtime selectSystemAggregate:@"aggregate-A"];
}
- (void)captureAndAdd:(THRetainedSystemAudioBridge *)bridge runtime:(THPrivateAudioRuntimeFixture *)runtime {
    [self selectSystem:runtime];
    XCTAssertEqualObjects([self retained:[bridge snapshotWithError:NULL]][@"state"], @"selected");
    [runtime selectSystemAggregate:nil]; [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
    BOOL selected = [bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL];
    if (!runtime.deferAdd) XCTAssertTrue(selected);
}
- (void)assertNoRouteWrites:(THPrivateAudioRuntimeFixture *)runtime {
    XCTAssertEqual(runtime.halWrites, 0u); XCTAssertEqual(runtime.adds, 0u); XCTAssertEqual(runtime.removes, 0u);
    XCTAssertEqual(runtime.modes.count, 1u, @"Recovery must reuse discovery without start/stop/mode writes");
}
- (void)testUncapturedSessionRecoversAfterItsContextAndManagerBecomeStale {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        NSUInteger managers = runtime.managerCopies;
        [runtime rotateSystemSession]; [self selectSystem:runtime];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects([self retained:snapshot][@"state"], @"selected");
        XCTAssertEqualObjects([self retained:snapshot][@"identifier"], @"receiver-A");
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"captureStreamUID"], @"system-stream");
        XCTAssertEqual(runtime.managerCopies, managers + 1);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testHealthyUnselectedContextDoesNotReacquireRetainedSession {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
        for (NSUInteger i = 0; i < 3; i++) {
            NSDictionary *snapshot = [bridge snapshotWithError:NULL];
            XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"uncaptured");
            XCTAssertEqualObjects(snapshot[@"sessionReadSucceeded"], @YES);
            XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)snapshot[@"sessionReadSucceeded"]), CFBooleanGetTypeID());
        }
        // The existing-stream read-only association separately gets a temporary
        // context/manager once per empty observation on its verified OS version.
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        NSUInteger independentReads = version.majorVersion == 27 && version.minorVersion == 0 && version.patchVersion == 1 ? 3 : 0;
        XCTAssertEqual(runtime.contextCopies, contexts + independentReads);
        XCTAssertEqual(runtime.managerCopies, managers + independentReads);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testReadHealthSeparatesHealthyUncapturedFromFailedRecoveryAndBackoff {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"sessionReadSucceeded"], @YES);
        [runtime rotateSystemSession]; runtime.managerStatus = -42;
        NSDictionary *failed = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(failed[@"sessionReadSucceeded"], @NO);
        XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)failed[@"sessionReadSucceeded"]), CFBooleanGetTypeID());
        NSDictionary *backoff = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(backoff[@"sessionReadSucceeded"], @NO);
        XCTAssertEqualObjects(backoff[@"diagnostics"][@"sessionRecoveryState"], @"backoff");
        runtime.managerStatus = 0; [runtime advanceTime:3];
        NSDictionary *recovered = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(recovered[@"retained"], NSNull.null);
        XCTAssertEqualObjects(recovered[@"sessionReadSucceeded"], @YES);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testThreeFailedReplacementsUseThreeSecondThenThirtySecondBackoffAndRecover {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession]; [self selectSystem:runtime]; runtime.managerStatus = -42;
        NSUInteger managers = runtime.managerCopies;
        (void)[bridge snapshotWithError:NULL]; // attempt 1 at t=0
        XCTAssertEqual(runtime.managerCopies, managers + 1);
        for (NSUInteger i = 0; i < 5; i++) (void)[bridge snapshotWithError:NULL];
        [runtime advanceTime:2]; (void)[bridge snapshotWithError:NULL];
        XCTAssertEqual(runtime.managerCopies, managers + 1);
        [runtime advanceTime:1]; (void)[bridge snapshotWithError:NULL]; // attempt 2 at t=3
        XCTAssertEqual(runtime.managerCopies, managers + 2);
        [runtime advanceTime:3]; (void)[bridge snapshotWithError:NULL]; // attempt 3 at t=6
        XCTAssertEqual(runtime.managerCopies, managers + 3);
        runtime.managerStatus = 0;
        for (NSUInteger i = 0; i < 5; i++) (void)[bridge snapshotWithError:NULL];
        [runtime advanceTime:29]; (void)[bridge snapshotWithError:NULL];
        XCTAssertEqual(runtime.managerCopies, managers + 3);
        [runtime advanceTime:1]; // attempt 4 at t=36
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqual(runtime.managerCopies, managers + 4);
        XCTAssertEqualObjects([self retained:snapshot][@"state"], @"selected");
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testOwnedTransactionDoesNotReacquireSessionAfterInvalidation {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self captureAndAdd:bridge runtime:runtime];
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies, writes = runtime.halWrites;
        [runtime rotateSystemSession];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"ownedMember"], @YES);
        XCTAssertEqualObjects(snapshot[@"sessionReadSucceeded"], @NO);
        XCTAssertEqual(runtime.contextCopies, contexts); XCTAssertEqual(runtime.managerCopies, managers);
        XCTAssertEqual(runtime.halWrites, writes); XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testPendingAddDoesNotReacquireSessionAfterInvalidation {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.deferAdd = YES; [self captureAndAdd:bridge runtime:runtime];
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
        [runtime rotateSystemSession]; (void)[bridge snapshotWithError:NULL];
        XCTAssertTrue(runtime.addCallbackPending);
        XCTAssertEqual(runtime.contextCopies, contexts); XCTAssertEqual(runtime.managerCopies, managers);
        XCTAssertEqual(runtime.adds, 1u); XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testPendingRemoveDoesNotReacquireSessionAfterInvalidation {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [self captureAndAdd:bridge runtime:runtime]; runtime.deferRemove = YES; [runtime selectSystemAggregate:nil];
        (void)[bridge reconcileRuntimeStateIsShuttingDown:^{ return NO; }
            performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL];
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
        [runtime rotateSystemSession]; (void)[bridge snapshotWithError:NULL];
        XCTAssertTrue(runtime.removeCallbackPending);
        XCTAssertEqual(runtime.contextCopies, contexts); XCTAssertEqual(runtime.managerCopies, managers);
        XCTAssertEqual(runtime.removes, 1u);
    }];
}
- (void)testShutdownDuringRecoveryDoesNotAcquireManagerOrPublishNewReferences {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession]; [self selectSystem:runtime];
        __block BOOL shutdown = NO;
        runtime.onCopyContext = ^{ shutdown = YES; };
        NSUInteger managers = runtime.managerCopies;
        NSDictionary *snapshot = [bridge snapshotIsShuttingDown:^{ return shutdown; } error:NULL];
        XCTAssertTrue(shutdown);
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"stopped");
        XCTAssertEqualObjects(snapshot[@"retained"], NSNull.null);
        XCTAssertEqual(runtime.managerCopies, managers);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testSnapshotAfterShutdownNeverReopensItsSession {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([bridge shutdownWithError:NULL]);
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"stopped");
        XCTAssertEqualObjects(snapshot[@"sessionReadSucceeded"], @NO);
        XCTAssertEqual(runtime.contextCopies, contexts); XCTAssertEqual(runtime.managerCopies, managers);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testRecoveredHealthyUnselectedSessionCanCaptureLaterSystemSelection {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession];
        NSDictionary *unselected = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(unselected[@"retained"], NSNull.null);
        XCTAssertEqualObjects(unselected[@"diagnostics"][@"sessionRecoveryState"], @"recovered");
        [self selectSystem:runtime];
        NSDictionary *selected = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects([self retained:selected][@"state"], @"selected");
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testWrongManagerTypeRejectsTheWholeCandidateAndCanRetry {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession]; [self selectSystem:runtime]; runtime.managerWrongType = YES;
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
        NSDictionary *failed = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(failed[@"retained"], NSNull.null);
        XCTAssertEqual(runtime.contextCopies, contexts + 1); XCTAssertEqual(runtime.managerCopies, managers + 1);
        runtime.managerWrongType = NO; [runtime advanceTime:3];
        NSDictionary *recovered = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects([self retained:recovered][@"state"], @"selected");
        XCTAssertEqual(runtime.contextCopies, contexts + 2); XCTAssertEqual(runtime.managerCopies, managers + 2);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testUnreadableCandidateManagerReleasesItAndDoesNotInstallPartialContext {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession]; [self selectSystem:runtime]; runtime.managerPropertyStatus = -43;
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies, releases = runtime.managerReleases;
        NSDictionary *failed = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(failed[@"retained"], NSNull.null); XCTAssertEqual(runtime.managerReleases, releases + 1);
        (void)[bridge snapshotWithError:NULL];
        XCTAssertEqual(runtime.contextCopies, contexts + 1); XCTAssertEqual(runtime.managerCopies, managers + 1);
        runtime.managerPropertyStatus = 0; [runtime advanceTime:3];
        NSDictionary *recovered = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects([self retained:recovered][@"state"], @"selected");
        XCTAssertEqual(runtime.contextCopies, contexts + 2); XCTAssertEqual(runtime.managerCopies, managers + 2);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testCandidateContextIdentityChangingBetweenReadsIsRejected {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession];
        __block NSUInteger reads = 0; __weak THPrivateAudioRuntimeFixture *owner = runtime;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"context"] && [key hasSuffix:@"_ContextUUID"])
                owner.contextIdentifier = (++reads % 2) ? @"context-B" : @"context-C";
        };
        NSUInteger releases = runtime.managerReleases;
        NSDictionary *failed = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(failed[@"retained"], NSNull.null);
        XCTAssertEqualObjects(failed[@"diagnostics"][@"sessionRecoveryState"], @"candidateRejected");
        XCTAssertEqual(runtime.managerReleases, releases + 1); [self assertNoRouteWrites:runtime];
    }];
}
- (void)testCandidateManagerEvidenceChangingBetweenReadsIsRejected {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession];
        __block NSUInteger reads = 0; __weak THPrivateAudioRuntimeFixture *owner = runtime;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"manager"] && [key hasSuffix:@"_ShowInfo"])
                [owner setAggregate:@"aggregate-A" receiver:(++reads % 2) ? @"receiver-A" : @"receiver-B" streams:@[]];
        };
        NSUInteger releases = runtime.managerReleases;
        NSDictionary *failed = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(failed[@"retained"], NSNull.null);
        XCTAssertEqualObjects(failed[@"diagnostics"][@"sessionRecoveryState"], @"candidateRejected");
        XCTAssertEqual(runtime.managerReleases, releases + 1); [self assertNoRouteWrites:runtime];
    }];
}
- (void)testShutdownInsideManagerGetterReleasesCandidateAndStopsPublication {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession]; [self selectSystem:runtime];
        __block BOOL shutdown = NO; runtime.onCopyManager = ^{ shutdown = YES; };
        NSUInteger releases = runtime.managerReleases;
        NSDictionary *snapshot = [bridge snapshotIsShuttingDown:^{ return shutdown; } error:NULL];
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"stopped");
        XCTAssertEqualObjects(snapshot[@"retained"], NSNull.null); XCTAssertEqual(runtime.managerReleases, releases + 1);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testShutdownDuringSecondCandidateReadReleasesCandidateAndStopsPublication {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession];
        __block BOOL shutdown = NO; __block NSUInteger reads = 0, readsAfterShutdown = 0;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if (shutdown) readsAfterShutdown++;
            if ([kind isEqual:@"context"] && [key hasSuffix:@"_ContextUUID"] && ++reads == 2) shutdown = YES;
        };
        NSUInteger releases = runtime.managerReleases, bufferedReads = runtime.bufferedReads;
        NSDictionary *snapshot = [bridge snapshotIsShuttingDown:^{ return shutdown; } error:NULL];
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"stopped");
        XCTAssertEqualObjects(snapshot[@"retained"], NSNull.null); XCTAssertEqual(runtime.managerReleases, releases + 1);
        XCTAssertEqual(readsAfterShutdown, 0u);
        XCTAssertEqual(runtime.bufferedReads, bufferedReads + 1, @"Only the first candidate observation may read buffered selection");
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testSuccessfulRecoveryResetsTheFailureBudgetForTheNextInvalidation {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession]; runtime.managerStatus = -42;
        (void)[bridge snapshotWithError:NULL]; [runtime advanceTime:3];
        (void)[bridge snapshotWithError:NULL]; [runtime advanceTime:3];
        (void)[bridge snapshotWithError:NULL]; [runtime advanceTime:30]; runtime.managerStatus = 0;
        NSDictionary *recovered = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(recovered[@"diagnostics"][@"sessionRecoveryFailures"], @0);
        [runtime rotateSystemSession]; runtime.managerStatus = -42;
        NSUInteger managers = runtime.managerCopies;
        (void)[bridge snapshotWithError:NULL];
        XCTAssertEqual(runtime.managerCopies, managers, @"Success preserves the current 3s minimum interval");
        [runtime advanceTime:3]; (void)[bridge snapshotWithError:NULL];
        [runtime advanceTime:3]; (void)[bridge snapshotWithError:NULL];
        XCTAssertEqual(runtime.managerCopies, managers + 2, @"A new failure sequence starts with 3s, not stale 30s backoff");
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testExceptionFromStaleProxyEntersBoundedRecovery {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession]; runtime.throwFromStaleSession = YES; [self selectSystem:runtime];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects([self retained:snapshot][@"state"], @"selected");
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"sessionRecoveryObservation"][@"exception"], @"FixtureStaleProxyException");
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testShutdownInsideHealthPropertyReadStopsFurtherReadsAndRecovery {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        __block BOOL shutdown = NO; __block NSUInteger reads = 0;
        runtime.onRead = ^(NSString *kind, NSString *key) { reads++; shutdown = YES; };
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
        NSDictionary *snapshot = [bridge snapshotIsShuttingDown:^{ return shutdown; } error:NULL];
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"stopped");
        XCTAssertEqual(reads, 1u); XCTAssertEqual(runtime.contextCopies, contexts); XCTAssertEqual(runtime.managerCopies, managers);
        [self assertNoRouteWrites:runtime];
    }];
}
- (void)testShutdownInsideInitialContextGetterNeverAcquiresInitialManager {
    [self withColdBridge:^(THRetainedSystemAudioBridge *existing, THPrivateAudioRuntimeFixture *runtime) {
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        THRetainedSystemAudioBridge *fresh = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        __block BOOL shutdown = NO; runtime.onCopyContext = ^{ shutdown = YES; };
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
        NSDictionary *snapshot = [fresh snapshotIsShuttingDown:^{ return shutdown; } error:NULL];
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"stopped");
        XCTAssertEqual(runtime.contextCopies, contexts + 1); XCTAssertEqual(runtime.managerCopies, managers);
        XCTAssertTrue([fresh shutdownWithError:NULL]); [self assertNoRouteWrites:runtime];
    }];
}
- (void)testSuccessfulRecoveryStillLimitsNextRecoveryToOnePerThreeSeconds {
    [self withColdBridge:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        [runtime rotateSystemSession]; (void)[bridge snapshotWithError:NULL];
        [runtime advanceTime:1]; [runtime rotateSystemSession]; [self selectSystem:runtime];
        NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
        (void)[bridge snapshotWithError:NULL];
        XCTAssertEqual(runtime.contextCopies, contexts); XCTAssertEqual(runtime.managerCopies, managers);
        [runtime advanceTime:2];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects([self retained:snapshot][@"state"], @"selected");
        XCTAssertEqual(runtime.contextCopies, contexts + 1); XCTAssertEqual(runtime.managerCopies, managers + 1);
        [self assertNoRouteWrites:runtime];
    }];
}
@end
