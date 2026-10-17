#import <XCTest/XCTest.h>
#import "../Sources/Services/THSystemAudioSnapshotBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

@interface THSnapshotMissingKeyRuntime : THPrivateAudioRuntimeFixture
@end
@implementation THSnapshotMissingKeyRuntime
- (CFStringRef)key:(const char *)name {
    if (strcmp(name, "kFigEndpointProperty_Streams") == 0) return NULL;
    return [super key:name];
}
@end

@interface THSystemAudioSnapshotBridgeTests : XCTestCase
@end
@implementation THSystemAudioSnapshotBridgeTests
- (void)selectRoute:(THPrivateAudioRuntimeFixture *)runtime {
    [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-A"]];
    [runtime selectSystemAggregate:@"aggregate-A"];
}
- (NSDictionary *)read:(THPrivateAudioRuntimeFixture *)runtime {
    THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
    NSError *error = nil;
    NSDictionary *snapshot = [bridge snapshotWithError:&error];
    XCTAssertNotNil(snapshot); XCTAssertNil(error);
    XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
    XCTAssertEqual(runtime.modes.count, 0u);
    return snapshot;
}
- (void)assertRejected:(NSDictionary *)snapshot state:(NSString *)state {
    XCTAssertEqualObjects(snapshot[@"selection"], NSNull.null);
    XCTAssertEqualObjects(snapshot[@"isUnselectedConfirmed"], @NO);
    XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], state);
}

- (void)testStableSelectedRouteRequiresCompleteMemberStreamContextAndHALReadback {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    NSDictionary *snapshot = [self read:runtime];
    XCTAssertEqualObjects(snapshot[@"selection"], (@{
        @"identifier":@"receiver-A", @"name":@"receiver-A", @"uid":@"stream-A",
        @"aggregateIdentifier":@"aggregate-A", @"contextIdentifier":@"context-A",
        @"aggregateContextIdentifier":@"context-A", @"associatedUID":@"stream-A",
        @"halUID":@"stream-A", @"audioStreamUIDs":@[@"stream-A"],
        @"memberIdentifiers":@[@"receiver-A"], @"readbackStable":@YES}));
    XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"verifiedSelectedAggregate");
    XCTAssertEqual(runtime.bufferedReads, 2u);
    XCTAssertEqual(runtime.managerCopies, 1u); XCTAssertEqual(runtime.managerReleases, 1u);
}

- (void)testMissingOrMultipleMembersDoNotPublishSelectedRoute {
    for (NSArray *receivers in @[@[], @[@"receiver-A", @"receiver-B"], @[@"receiver-A", @"receiver-A"]]) {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receivers:receivers streams:@[@"stream-A"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        [self assertRejected:[self read:runtime] state:@"ambiguousOrMissingMembers"];
        XCTAssertEqual(runtime.managerReleases, 1u);
    }
}

- (void)testMissingOrMultipleAudioStreamsDoNotPublishSelectedRoute {
    for (NSArray *streams in @[@[], @[@"stream-A", @"stream-B"]]) {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:streams];
        [runtime selectSystemAggregate:@"aggregate-A"];
        [self assertRejected:[self read:runtime] state:@"ambiguousAudioStreams"];
        XCTAssertEqual(runtime.managerCopies, 0u);
    }
}

- (void)testAssociatedDeviceConflictAndHALConflictRejectOtherwiseMatchingRoute {
    THPrivateAudioRuntimeFixture *association = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:association]; association.invalidAssociation = YES;
    [self assertRejected:[self read:association] state:@"selectedHALMismatch"];
    XCTAssertEqual(association.managerReleases, 1u);
    THPrivateAudioRuntimeFixture *hal = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:hal]; hal.defaultUID = @"local";
    [self assertRejected:[self read:hal] state:@"selectedHALMismatch"];
    XCTAssertEqual(hal.managerReleases, 1u);
}

- (void)testMemberChangeDuringSecondReadCannotReuseTheFirstReceiverIdentity {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    __block NSUInteger memberReads = 0;
    __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"manager"] && [key hasSuffix:@"_ShowInfo"] && ++memberReads == 2)
            [weakRuntime setAggregate:@"aggregate-A" receiver:@"receiver-B" streams:@[@"stream-A"]];
    };
    [self assertRejected:[self read:runtime] state:@"selectionChangedDuringRead"];
    XCTAssertEqual(memberReads, 2u); XCTAssertEqual(runtime.managerReleases, 1u);
}

- (void)testStreamGenerationChangeDuringSecondReadRejectsStableAggregateIdentity {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    __block NSUInteger streamReads = 0;
    __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"aggregate"] && [key hasSuffix:@"_Streams"] && ++streamReads == 2) {
            [weakRuntime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-B"]];
            [weakRuntime selectSystemAggregate:@"aggregate-A"];
        }
    };
    [self assertRejected:[self read:runtime] state:@"selectionChangedDuringRead"];
    XCTAssertEqual(streamReads, 2u); XCTAssertEqual(runtime.managerReleases, 1u);
}

- (void)testHALChangeAtFinalReadbackRejectsPreviouslyMatchingSelection {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    __block NSUInteger associatedReads = 0;
    __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"context"] && [key hasSuffix:@"_AssociatedAudioDevice"] && ++associatedReads == 2)
            weakRuntime.defaultUID = @"local";
    };
    [self assertRejected:[self read:runtime] state:@"selectionChangedDuringRead"];
    XCTAssertEqual(associatedReads, 2u); XCTAssertEqual(runtime.managerReleases, 1u);
}

- (void)testWrongTypeManagerAndMissingStreamKeyRemainUnknown {
    THPrivateAudioRuntimeFixture *wrongType = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:wrongType]; wrongType.managerWrongType = YES;
    [self assertRejected:[self read:wrongType] state:@"managerUnavailable"];
    THSnapshotMissingKeyRuntime *missingKey = [[THSnapshotMissingKeyRuntime alloc] initFixture];
    [self selectRoute:missingKey];
    [self assertRejected:[self read:missingKey] state:@"invalidStreams"];
}

- (void)testReadExceptionReleasesCopiedManagerAndDoesNotAssertUnselected {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"manager"] && [key hasSuffix:@"_ShowInfo"])
            @throw [NSException exceptionWithName:@"FixtureSnapshotReadFailure" reason:nil userInfo:nil];
    };
    [self assertRejected:[self read:runtime] state:@"readFailed"];
    XCTAssertEqual(runtime.managerCopies, 1u); XCTAssertEqual(runtime.managerReleases, 1u);
}
@end
