#import <XCTest/XCTest.h>
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

@interface THPrivateEndpointBridgeLifecycleTests : XCTestCase
@end
@implementation THPrivateEndpointBridgeLifecycleTests
- (THPrivateEndpointBridge *)startedBridge:(THPrivateAudioRuntimeFixture *)runtime {
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    XCTAssertTrue([bridge startWithError:NULL]); return bridge;
}
- (void)assertReleased:(THPrivateEndpointBridge *)bridge {
    XCTAssertEqualObjects(bridge.diagnostics[@"active"], @NO);
    XCTAssertEqualObjects(bridge.diagnostics[@"mode"], @"released");
    XCTAssertEqualObjects(bridge.diagnostics[@"stopAction"], @"releasedReference");
    XCTAssertEqualObjects(bridge.diagnostics[@"stopStatus"], NSNull.null);
}
- (void)testStartupStillRequestsDetailedOnceAndCanReadAvailableEndpoints {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
    XCTAssertEqualObjects(bridge.diagnostics[@"active"], @YES);
    XCTAssertEqualObjects(bridge.diagnostics[@"mode"], @"DetailedDiscovery");
    XCTAssertTrue([bridge startWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 1u);
    XCTAssertEqual(runtime.modes.count, 1u);
    XCTAssertEqual([bridge availableEndpointReferencesWithError:NULL].count, 2u);
    XCTAssertNotNil([bridge snapshotWithError:NULL]);
    [bridge stop];
    XCTAssertEqual(runtime.modes.count, 1u);
    XCTAssertEqual(runtime.managerReleases, 1u);
}
- (void)assertSkippedModeKeepsBridgeUsable:(THPrivateAudioRuntimeFixture *)runtime
                                   state:(NSString *)state symbol:(NSString *)symbol {
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
        performIfRunning:^BOOL(void (^operation)(void)) { XCTFail(@"An unverified slot must not register a mutation"); return NO; }];
    NSError *error = nil;
    XCTAssertTrue([bridge startWithError:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(runtime.modes, @[]);
    XCTAssertEqual(runtime.managerCopies, 1u);
    XCTAssertEqual(runtime.managerReleases, 0u);
    XCTAssertEqualObjects(bridge.diagnostics[@"active"], @YES);
    XCTAssertEqualObjects(bridge.diagnostics[@"mode"], @"skippedUnverified");
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryState"], @"healthy");
    XCTAssertEqualObjects(bridge.diagnostics[@"startStatus"], NSNull.null);
    NSDictionary *verification = bridge.diagnostics[@"setDiscoveryModeVerification"];
    XCTAssertEqualObjects(verification[@"state"], state);
    XCTAssertEqualObjects(verification[@"symbol"], symbol);
    XCTAssertEqualObjects(verification[@"action"], @"skipped");
    XCTAssertEqualObjects(verification[@"osVersion"], NSProcessInfo.processInfo.operatingSystemVersionString);
    XCTAssertEqual([bridge availableEndpointReferencesWithError:&error].count, 2u);
    XCTAssertNil(error);
    XCTAssertNotNil([bridge snapshotWithError:&error]);
    XCTAssertNil(error);
    XCTAssertTrue([bridge startWithError:&error]);
    XCTAssertNil(error);
    XCTAssertEqual(runtime.managerCopies, 1u);
    XCTAssertEqual(runtime.managerReleases, 0u);
    XCTAssertEqualObjects(runtime.modes, @[]);
    [bridge stop];
    [self assertReleased:bridge];
    XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqualObjects(runtime.modes, @[]);
}
- (void)testUnverifiedSetModeSymbolSkipsCallButBridgeStaysUsable {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.setModeSymbolOverride = @"Unrelated_SetDiscoveryMode";
    [self assertSkippedModeKeepsBridgeUsable:runtime state:@"symbolMismatch" symbol:runtime.setModeSymbolOverride];
}
- (void)testUnresolvedSetModeSymbolSkipsCallButBridgeStaysUsable {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.setModeSymbolOverride = @"";
    [self assertSkippedModeKeepsBridgeUsable:runtime state:@"symbolUnresolved" symbol:@""];
}
- (void)testVersionMismatchSkipsCallButBridgeStaysUsable {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.managerClassVersionMismatch = YES;
    [self assertSkippedModeKeepsBridgeUsable:runtime state:@"versionMismatch" symbol:@""];
}
- (void)testNullSetModeSlotSkipsCallButBridgeStaysUsable {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.setModeSlotMissing = YES;
    [self assertSkippedModeKeepsBridgeUsable:runtime state:@"nullSlot" symbol:@""];
}
- (void)testMissingManagerClassSkipsCallButBridgeStaysUsable {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.managerClassMissing = YES;
    [self assertSkippedModeKeepsBridgeUsable:runtime state:@"missingTable" symbol:@""];
}
- (void)testStopReleasesManagerAndClearsLocalLifecycleWithoutModeWrite {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [bridge stop]; [self assertReleased:bridge];
    XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
    XCTAssertEqual(runtime.managerReleases, 1u);
    NSError *error = nil;
    XCTAssertNil([bridge availableEndpointReferencesWithError:&error]);
    XCTAssertEqual(error.code, 9);
    XCTAssertEqual(runtime.managerCopies, 1u, @"A stopped read must not restart discovery");
}
- (void)testRepeatedStopAndFollowingDeallocReleaseOnlyOnce {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    @autoreleasepool {
        THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
        [bridge stop]; NSDictionary *firstStop = bridge.diagnostics;
        [bridge stop]; [bridge stop]; [self assertReleased:bridge];
        XCTAssertEqualObjects(bridge.diagnostics, firstStop);
    }
    XCTAssertEqual(runtime.managerReleases, 1u); XCTAssertEqual(runtime.modes.count, 1u);
}
- (void)testDeallocAloneReleasesManagerWithoutSendingNone {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    __weak THPrivateEndpointBridge *weakBridge;
    @autoreleasepool {
        THPrivateEndpointBridge *bridge = [self startedBridge:runtime]; weakBridge = bridge;
    }
    XCTAssertNil(weakBridge); XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
}
- (void)testRestartAfterReleaseCreatesFreshManagerAndRequestsDetailedAgain {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [bridge stop]; XCTAssertTrue([bridge startWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u); XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqualObjects(bridge.diagnostics[@"active"], @YES);
    XCTAssertEqualObjects(bridge.diagnostics[@"stopAction"], NSNull.null);
    XCTAssertEqual(runtime.modes.count, 2u); [bridge stop];
    [self assertReleased:bridge]; XCTAssertEqual(runtime.managerReleases, 2u);
}
- (void)testFailedDetailedRequestReleasesWithoutCompensatingNone {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture]; runtime.modeStatus = -16155;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSError *error = nil; XCTAssertFalse([bridge startWithError:&error]); XCTAssertEqual(error.code, 4);
    [self assertReleased:bridge]; XCTAssertEqualObjects(bridge.diagnostics[@"startStatus"], @(-16155));
    XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
}
- (void)testDetailedRequestExceptionAlsoReleasesWithoutCompensatingNone {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture]; runtime.throwFromMode = YES;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSError *error = nil; XCTAssertFalse([bridge startWithError:&error]); XCTAssertEqual(error.code, 5);
    [self assertReleased:bridge]; XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
}
- (void)testStopBeforeStartIsHarmlessAndDoesNotCreateAConnection {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    [bridge stop]; [bridge stop]; XCTAssertEqualObjects(bridge.diagnostics[@"active"], @NO);
    XCTAssertEqual(runtime.managerCopies, 0u); XCTAssertEqual(runtime.managerReleases, 0u); XCTAssertEqual(runtime.modes.count, 0u);
}
- (void)testTwoLiveRuntimesKeepDiscoveryStateAndFailureIndependent {
    THPrivateAudioRuntimeFixture *first = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateAudioRuntimeFixture *second = [[THPrivateAudioRuntimeFixture alloc] initFixture]; second.modeStatus = -99;
    THPrivateEndpointBridge *firstBridge = [self startedBridge:first];
    THPrivateEndpointBridge *secondBridge = [[THPrivateEndpointBridge alloc] initWithRuntime:second performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    XCTAssertFalse([secondBridge startWithError:NULL]);
    XCTAssertEqualObjects(firstBridge.diagnostics[@"active"], @YES);
    XCTAssertEqual(first.managerCopies, 1u); XCTAssertEqual(first.managerReleases, 0u);
    XCTAssertEqual(second.managerCopies, 1u); XCTAssertEqual(second.managerReleases, 1u);
    XCTAssertEqual(first.halWrites + second.halWrites + first.adds + second.adds + first.removes + second.removes, 0u);
    [firstBridge stop]; XCTAssertEqual(first.managerReleases, 1u);
}

- (void)testStaleManagerRecoversThroughFreshReadOnlyReference {
    for (NSNumber *throws in @[@NO, @YES]) {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
        runtime.throwFromStaleSession = throws.boolValue;
        [runtime rotateSystemSession];
        NSError *error = nil;
        XCTAssertEqual([bridge availableEndpointReferencesWithError:&error].count, 2u);
        XCTAssertNil(error);
        XCTAssertEqualObjects(bridge.diagnostics[@"recoveryState"], @"recovered");
        XCTAssertEqual(runtime.managerCopies, 2u); XCTAssertEqual(runtime.managerReleases, 1u);
        XCTAssertNotNil([bridge snapshotWithError:NULL]);
        XCTAssertEqual(runtime.managerCopies, 2u);
        XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
        [bridge stop]; XCTAssertEqual(runtime.managerReleases, 2u);
    }
}

- (void)testHealthyEmptyDirectoryNeverReacquiresOrRestartsDiscovery {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.availableEndpointIdentifiers = @[];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    for (NSUInteger index = 0; index < 5; index++) {
        NSArray *endpoints = [bridge availableEndpointReferencesWithError:NULL];
        XCTAssertNotNil(endpoints); XCTAssertEqual(endpoints.count, 0u);
        [runtime advanceTime:30];
    }
    XCTAssertEqual(runtime.managerCopies, 1u); XCTAssertEqual(runtime.modes.count, 1u);
    [bridge stop];
}

- (void)testFailedRecoveryHasSharedRetryBudgetAndThirtySecondBackoff {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession]; runtime.managerStatus = -42;
    for (NSUInteger index = 0; index < 10; index++) XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u);
    [runtime advanceTime:3]; XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 3u);
    [runtime advanceTime:3]; XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 4u);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryFailures"], @3);
    runtime.managerStatus = 0;
    [runtime advanceTime:29]; XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 4u);
    [runtime advanceTime:1]; XCTAssertEqual([bridge availableEndpointReferencesWithError:NULL].count, 2u);
    XCTAssertEqual(runtime.managerCopies, 5u);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryFailures"], @0);
    XCTAssertEqual(runtime.modes.count, 1u);
    XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
    [bridge stop];
}

- (void)testHealthyCurrentManagerClearsPenaltyButKeepsMinimumRetryInterval {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    runtime.managerPropertyStatus = -42;
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u); XCTAssertEqual(runtime.managerReleases, 1u);
    [runtime advanceTime:1]; runtime.managerPropertyStatus = 0;
    XCTAssertNotNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryFailures"], @0);
    runtime.managerPropertyStatus = -42;
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u);
    [runtime advanceTime:2]; XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 3u);
    [bridge stop]; XCTAssertEqual(runtime.managerReleases, 3u);
}

- (void)testUnstableCandidateIsReleasedAndLaterStableDirectoryRecovers {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    __block NSUInteger directoryReads = 0;
    __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"manager"] && [key hasSuffix:@"_AvailableEndpoints"] && ++directoryReads == 2)
            weakRuntime.availableEndpointIdentifiers = @[@"receiver-B"];
    };
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u); XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryCandidate"][@"reason"], @"directoryChangedDuringRead");
    runtime.onRead = nil; [runtime advanceTime:3];
    XCTAssertEqual([bridge availableEndpointReferencesWithError:NULL].count, 1u);
    XCTAssertEqual(runtime.managerReleases, 2u);
    XCTAssertEqual(runtime.modes.count, 1u);
    [bridge stop]; XCTAssertEqual(runtime.managerReleases, 3u);
}

- (void)testThrowingCandidateIsReleasedAndStopPreventsRecovery {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession];
    runtime.onRead = ^(NSString *kind, NSString *key) {
        @throw [NSException exceptionWithName:@"FixtureCandidateReadFailure" reason:nil userInfo:nil];
    };
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u); XCTAssertEqual(runtime.managerReleases, 1u);
    [bridge stop]; [runtime advanceTime:30]; runtime.onRead = nil;
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u); XCTAssertEqual(runtime.managerReleases, 2u);
    XCTAssertEqual(runtime.modes.count, 1u);
}

- (void)testWrongTypeCandidateDoesNotReplaceFailedManager {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    [runtime rotateSystemSession]; runtime.managerWrongType = YES;
    XCTAssertNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerReleases, 0u, @"The old reference remains until a healthy replacement exists.");
    runtime.managerWrongType = NO; [runtime advanceTime:3];
    XCTAssertNotNil([bridge availableEndpointReferencesWithError:NULL]);
    XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqual(runtime.modes.count, 1u);
    [bridge stop];
}

- (void)testSnapshotIdentityDiagnosticsGroupRepeatedReferencesAndContainOnlyValues {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.availableEndpointIdentifiers = @[@"receiver-A", @"receiver-A", @"receiver-B", @"receiver-A", @"receiver-B"];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    NSArray *startupModes = [runtime.modes copy];
    NSError *error = nil;
    NSDictionary *snapshot = [bridge snapshotWithError:&error];
    XCTAssertNotNil(snapshot); XCTAssertNil(error);
    NSArray<NSDictionary *> *rows = snapshot[@"endpoints"];
    NSArray<NSDictionary *> *observations = snapshot[@"diagnostics"][@"identityObservations"];
    NSMutableArray *groups = [NSMutableArray array];
    NSMutableArray *expectedObservations = [NSMutableArray array];
    NSArray *keys = @[@"referenceGroup", @"identifier", @"type", @"routingContextUUID", @"streamUIDs",
        @"isLocalDevice", @"isRemoteControlOnly", @"wrapperIsCached", @"avIdentity"];
    for (NSDictionary *row in rows) {
        [groups addObject:row[@"referenceGroup"] ?: NSNull.null];
        NSMutableDictionary *projection = [NSMutableDictionary dictionary];
        for (NSString *key in keys) projection[key] = row[key] ?: NSNull.null;
        [expectedObservations addObject:projection];
    }
    XCTAssertEqualObjects(groups, (@[@0, @0, @1, @0, @1]),
        @"Repeated fixture references share a group; another endpoint object receives a different group.");
    XCTAssertEqualObjects(observations, expectedObservations);
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:observations],
        @"Diagnostics must contain serializable values, never the fixture's native handle or pointer-bearing NSValue.");
    XCTAssertEqualObjects(runtime.modes, startupModes);
    XCTAssertEqual(runtime.managerCopies, 1u);
    XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
    [bridge stop];
    XCTAssertEqualObjects(runtime.modes, startupModes);
}

- (void)testReferenceGroupsRestartWithinEachSnapshotWithoutMutatingEarlierDiagnostics {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.availableEndpointIdentifiers = @[@"receiver-A", @"receiver-B"];
    THPrivateEndpointBridge *bridge = [self startedBridge:runtime];
    NSArray *startupModes = [runtime.modes copy];
    NSDictionary *first = [bridge snapshotWithError:NULL];
    XCTAssertNotNil(first);
    NSArray *firstObservations = first[@"diagnostics"][@"identityObservations"];
    NSData *firstValues = [NSJSONSerialization dataWithJSONObject:firstObservations options:NSJSONWritingSortedKeys error:NULL];
    XCTAssertNotNil(firstValues);
    NSMutableArray *firstGroups = [NSMutableArray array];
    for (NSDictionary *row in first[@"endpoints"]) [firstGroups addObject:row[@"referenceGroup"] ?: NSNull.null];
    XCTAssertEqualObjects(firstGroups, (@[@0, @1]));

    // The fixture reuses both exact endpoint objects. Changing their encounter
    // order must still restart the ordinal namespace for this new snapshot.
    runtime.availableEndpointIdentifiers = @[@"receiver-B", @"receiver-B", @"receiver-A"];
    NSDictionary *second = [bridge snapshotWithError:NULL];
    XCTAssertNotNil(second);
    NSMutableArray *secondGroups = [NSMutableArray array];
    NSMutableArray *secondIdentifiers = [NSMutableArray array];
    for (NSDictionary *row in second[@"diagnostics"][@"identityObservations"]) {
        [secondGroups addObject:row[@"referenceGroup"] ?: NSNull.null];
        [secondIdentifiers addObject:row[@"identifier"] ?: NSNull.null];
    }
    XCTAssertEqualObjects(secondGroups, (@[@0, @0, @1]));
    XCTAssertEqualObjects(secondIdentifiers, (@[@"receiver-B", @"receiver-B", @"receiver-A"]));
    XCTAssertEqualObjects(first[@"diagnostics"][@"identityObservations"], firstObservations);
    XCTAssertEqualObjects([NSJSONSerialization dataWithJSONObject:first[@"diagnostics"][@"identityObservations"]
        options:NSJSONWritingSortedKeys error:NULL], firstValues);
    XCTAssertEqualObjects(bridge.diagnostics[@"identityObservations"], second[@"diagnostics"][@"identityObservations"]);
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:second[@"diagnostics"][@"identityObservations"]]);
    XCTAssertEqualObjects(runtime.modes, startupModes);
    XCTAssertEqual(runtime.managerCopies, 1u);
    XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
    [bridge stop];
    XCTAssertEqualObjects(runtime.modes, startupModes);
}
@end
