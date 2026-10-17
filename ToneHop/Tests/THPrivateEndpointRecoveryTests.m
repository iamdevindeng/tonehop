#import <XCTest/XCTest.h>
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "../Sources/Services/THRetainedSystemAudioBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

@interface THPrivateEndpointRecoveryTests : XCTestCase
@end

@implementation THPrivateEndpointRecoveryTests

- (THPrivateEndpointBridge *)startedBridge:(THPrivateAudioRuntimeFixture *)runtime {
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    XCTAssertTrue([bridge startWithError:NULL]);
    return bridge;
}

- (void)assertDiscoveryOnly:(THPrivateAudioRuntimeFixture *)runtime {
    XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
    XCTAssertEqual(runtime.contextCopies, 0u);
    XCTAssertEqual(runtime.halWrites, 0u);
    XCTAssertEqual(runtime.adds, 0u);
    XCTAssertEqual(runtime.removes, 0u);
}

- (void)assertStoppedWithoutReacquisition:(THPrivateEndpointBridge *)bridge
                                runtime:(THPrivateAudioRuntimeFixture *)runtime {
    NSUInteger copies = runtime.managerCopies;
    [bridge stop];
    [runtime advanceTime:60];
    NSError *error = nil;
    XCTAssertNil([bridge availableEndpointReferencesWithError:&error]);
    XCTAssertEqual(error.code, 9);
    XCTAssertEqual(runtime.managerCopies, copies);
    XCTAssertEqual(runtime.managerReleases, copies);
    [self assertDiscoveryOnly:runtime];
}

- (void)testThrowingManagerGetterKeepsOldReferenceAndUsesRetryBudget {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    runtime.onCopyManager = ^{
        @throw [NSException exceptionWithName:@"FixtureManagerGetterFailure" reason:nil userInfo:nil];
    };
    NSError *error = nil;
    XCTAssertNil([bridge availableEndpointReferencesWithError:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual(runtime.managerCopies, 2u);
    XCTAssertEqual(runtime.managerReleases, 0u, @"A rejected getter must not release the live owner's old reference.");
    runtime.onCopyManager = nil;
    [runtime advanceTime:2];
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u);
    [runtime advanceTime:1];
    XCTAssertNotNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 3u);
    XCTAssertEqual(runtime.managerReleases, 1u);
    [bridge stop];
    // The throwing getter acquired no candidate, so only two references exist.
    XCTAssertEqual(runtime.managerReleases, 2u);
    [self assertDiscoveryOnly:runtime];
}

- (void)testSecondDirectoryReadFailureRejectsFirstSuccessfulObservation {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    __block NSUInteger reads = 0;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"manager"] && [key hasSuffix:@"_AvailableEndpoints"] && ++reads == 2)
            @throw [NSException exceptionWithName:@"FixtureSecondDirectoryReadFailure" reason:nil userInfo:nil];
    };
    NSError *error = nil;
    XCTAssertNil([bridge snapshotWithError:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual(reads, 2u);
    XCTAssertEqual(runtime.managerCopies, 2u);
    XCTAssertEqual(runtime.managerReleases, 1u, @"The unverified candidate is released; the old manager remains held.");
    runtime.onRead = nil;
    [runtime advanceTime:3];
    XCTAssertEqual([[bridge snapshotWithError:NULL][@"endpoints"] count], 2u);
    XCTAssertEqual(runtime.managerReleases, 2u);
    [self assertStoppedWithoutReacquisition:bridge runtime:runtime];
}

- (void)testEndpointIdentityFailureInEitherObservationRejectsCandidate {
    // Each observation reads two endpoint identities. Fail the first identity
    // in either observation, rather than the manager's array getter itself.
    for (NSNumber *failureRead in @[@1, @3]) {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
        [runtime rotateSystemSession];
        __block NSUInteger reads = 0;
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"leaf"] && [key hasSuffix:@"_ID"] && ++reads == failureRead.unsignedIntegerValue)
                @throw [NSException exceptionWithName:@"FixtureCandidateIdentityFailure" reason:nil userInfo:nil];
        };
        NSError *error = nil;
        XCTAssertNil([bridge availableEndpointReferencesWithError:&error]);
        XCTAssertNotNil(error);
        XCTAssertEqual(reads, failureRead.unsignedIntegerValue);
        XCTAssertEqual(runtime.managerReleases, 1u);
        runtime.onRead = nil;
        [runtime advanceTime:3];
        XCTAssertEqual([bridge availableEndpointReferencesWithError:NULL].count, 2u);
        XCTAssertEqual(runtime.managerReleases, 2u);
        [self assertStoppedWithoutReacquisition:bridge runtime:runtime];
    }
}

- (void)testCandidateWithMissingEndpointIdentityCannotReplaceManager {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    runtime.availableEndpointIdentifiers = @[@"receiver-A", @""];
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u);
    XCTAssertEqual(runtime.managerReleases, 1u);
    runtime.availableEndpointIdentifiers = @[@"receiver-A", @"receiver-B"];
    [runtime advanceTime:3];
    XCTAssertEqual([[bridge snapshotWithError:NULL][@"endpoints"] count], 2u);
    [self assertStoppedWithoutReacquisition:bridge runtime:runtime];
}

- (void)testDuplicateMultiplicityChangeCannotMasqueradeAsStableDirectory {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    runtime.availableEndpointIdentifiers = @[@"receiver-A", @"receiver-A", @"receiver-B"];
    __block NSUInteger reads = 0;
    __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"manager"] && [key hasSuffix:@"_AvailableEndpoints"] && ++reads == 2)
            weakRuntime.availableEndpointIdentifiers = @[@"receiver-A", @"receiver-B"];
    };
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryCandidate"][@"reason"], @"directoryChangedDuringRead");
    runtime.onRead = nil;
    [runtime advanceTime:3];
    XCTAssertEqual([bridge availableEndpointReferencesWithError:NULL].count, 2u);
    [self assertStoppedWithoutReacquisition:bridge runtime:runtime];
}

- (void)testRecoveredEmptyDirectoryIsAdoptedAndRemainsHealthy {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    runtime.availableEndpointIdentifiers = @[];
    __block NSUInteger reads = 0;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"manager"] && [key hasSuffix:@"_AvailableEndpoints"]) reads++;
    };
    NSError *error = nil;
    NSArray *endpoints = [bridge availableEndpointReferencesWithError:&error];
    XCTAssertNotNil(endpoints);
    XCTAssertEqual(endpoints.count, 0u);
    XCTAssertNil(error);
    XCTAssertEqual(reads, 2u, @"An empty replacement still requires both healthy observations.");
    XCTAssertEqual(runtime.managerReleases, 1u);
    runtime.onRead = nil;
    [runtime advanceTime:60];
    NSDictionary *snapshot = [bridge snapshotWithError:&error];
    XCTAssertNotNil(snapshot);
    XCTAssertEqual([snapshot[@"endpoints"] count], 0u);
    XCTAssertNil(error);
    XCTAssertEqual(runtime.managerCopies, 2u);
    [self assertStoppedWithoutReacquisition:bridge runtime:runtime];
}

- (void)testSnapshotAndReferenceReadsShareRecoveryAdmission {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    runtime.managerPropertyStatus = -42;
    XCTAssertNil([bridge snapshotWithError:NULL]);
    for (NSUInteger index = 0; index < 5; index++) {
        XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
        XCTAssertNil([bridge snapshotWithError:NULL]);
    }
    XCTAssertEqual(runtime.managerCopies, 2u);
    XCTAssertEqual(runtime.managerReleases, 1u);
    [runtime advanceTime:2];
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u);
    [runtime advanceTime:1];
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 3u);
    XCTAssertEqual(runtime.managerReleases, 2u);
    [self assertStoppedWithoutReacquisition:bridge runtime:runtime];
}

- (void)testSuccessfulReplacementClearsThirtySecondPenaltyButKeepsThreeSecondMinimum {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    runtime.managerPropertyStatus = -42;
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        if (attempt) [runtime advanceTime:3];
        XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    }
    XCTAssertEqual(runtime.managerCopies, 4u);
    runtime.managerPropertyStatus = 0;
    [runtime advanceTime:30];
    XCTAssertNotNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 5u);
    XCTAssertEqual(runtime.managerReleases, 4u);

    [runtime rotateSystemSession];
    runtime.managerPropertyStatus = -42;
    [runtime advanceTime:2];
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 5u);
    [runtime advanceTime:1];
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 6u);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryFailures"], @1);
    runtime.managerPropertyStatus = 0;
    [runtime advanceTime:3];
    XCTAssertNotNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 7u, @"The next failure starts a fresh short retry budget, not the old 30-second penalty.");
    [self assertStoppedWithoutReacquisition:bridge runtime:runtime];
}

- (void)testHealthyEmptyCurrentDirectoryClearsLongPenaltyWithoutReacquiring {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    runtime.managerPropertyStatus = -42;
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        if (attempt) [runtime advanceTime:3];
        XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    }
    XCTAssertEqual(runtime.managerCopies, 4u);
    [runtime advanceTime:1];
    runtime.managerPropertyStatus = 0;
    runtime.availableEndpointIdentifiers = @[];
    NSArray *empty = [bridge availableEndpointReferencesWithError:NULL];
    XCTAssertNotNil(empty);
    XCTAssertEqual(empty.count, 0u);
    XCTAssertEqual(runtime.managerCopies, 4u);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryFailures"], @0);

    runtime.managerPropertyStatus = -42;
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 4u);
    [runtime advanceTime:2];
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 5u, @"Recovery may retry at t=9 after the healthy read, rather than waiting until t=36.");
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryFailures"], @1);
    [self assertStoppedWithoutReacquisition:bridge runtime:runtime];
}

- (void)testDiscoveryReplacementPreservesOwnedAndPendingRetainedTransactions {
    XCTestExpectation *finished = [self expectationWithDescription:@"discovery recovery with retained transactions"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        for (NSString *phase in @[@"owned", @"pendingAdd", @"pendingRemove"]) {
            THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
            THPrivateEndpointBridge *endpoints = [self startedBridge:runtime];
            THRetainedSystemAudioBridge *retained = [[THRetainedSystemAudioBridge alloc]
                initWithEndpointDiscovery:endpoints runtime:runtime];
            [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"system-stream"]];
            [runtime selectSystemAggregate:@"aggregate-A"];
            XCTAssertEqualObjects([retained snapshotWithError:NULL][@"retained"][@"state"], @"selected");
            [runtime selectSystemAggregate:nil];
            [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
            runtime.deferAdd = [phase isEqual:@"pendingAdd"];
            BOOL selected = [retained selectIdentifier:@"receiver-A" isCancelled:^{ return NO; }
                isShuttingDown:^{ return NO; }
                performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL];
            XCTAssertEqual(selected, !runtime.deferAdd);
            XCTAssertEqual(runtime.adds, 1u);
            if ([phase isEqual:@"pendingRemove"]) {
                runtime.deferRemove = YES;
                [runtime selectSystemAggregate:nil];
                XCTAssertFalse([retained reconcileRuntimeStateIsShuttingDown:^{ return NO; }
                    performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL]);
                XCTAssertTrue(runtime.removeCallbackPending);
            }
            NSDictionary *before = [retained snapshotWithError:NULL];
            XCTAssertEqualObjects(before[@"diagnostics"][@"ownedMember"], @YES);
            NSUInteger contexts = runtime.contextCopies, managers = runtime.managerCopies;
            NSUInteger writes = runtime.halWrites, adds = runtime.adds, removes = runtime.removes;
            BOOL addPending = runtime.addCallbackPending, removePending = runtime.removeCallbackPending;

            [runtime rotateSystemSession];
            XCTAssertEqual([endpoints availableEndpointReferencesWithError:NULL].count, 2u);
            XCTAssertEqual(runtime.managerCopies, managers + 1);
            NSDictionary *after = [retained snapshotWithError:NULL];
            XCTAssertEqualObjects(after[@"diagnostics"][@"ownedMember"], @YES, @"%@", phase);
            XCTAssertEqualObjects(after[@"diagnostics"][@"callbackPending"], before[@"diagnostics"][@"callbackPending"]);
            XCTAssertEqual(runtime.addCallbackPending, addPending);
            XCTAssertEqual(runtime.removeCallbackPending, removePending);
            XCTAssertEqual(runtime.contextCopies, contexts);
            XCTAssertEqual(runtime.managerCopies, managers + 1, @"Discovery recovery cannot reacquire the retained session during a transaction.");
            XCTAssertEqual(runtime.halWrites, writes);
            XCTAssertEqual(runtime.adds, adds);
            XCTAssertEqual(runtime.removes, removes);
            XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));

            [runtime completeAdd];
            [runtime completeRemove];
            XCTAssertTrue([retained shutdownWithError:NULL]);
            [endpoints stop];
            XCTAssertEqual(runtime.halWrites, writes);
            XCTAssertEqual(runtime.adds, adds);
            XCTAssertEqual(runtime.removes, removes);
        }
        [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}

@end
