#import <XCTest/XCTest.h>
#import "../Sources/Services/THSystemAudioSnapshotBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

/// Keep the context's associated UID intact while varying only HAL's public
/// runtime read result. The shared fixture deliberately couples both identities.
@interface THBoundaryHALIdentityRuntime : THPrivateAudioRuntimeFixture
@property(nonatomic, copy) NSString *injectedHALUID;
@property(nonatomic) NSUInteger injectFromUIDRead;
@property(nonatomic) NSUInteger halUIDReads;
@end
@implementation THBoundaryHALIdentityRuntime
- (NSString *)halString:(AudioObjectID)object selector:(AudioObjectPropertySelector)selector {
    NSString *value = [super halString:object selector:selector];
    if (selector != kAudioDevicePropertyDeviceUID) return value;
    self.halUIDReads++;
    return self.injectedHALUID && self.halUIDReads >= self.injectFromUIDRead ? self.injectedHALUID : value;
}
@end

@interface SystemAudioSelectionBoundaryTests : XCTestCase
@end
@implementation SystemAudioSelectionBoundaryTests
- (void)selectRoute:(THPrivateAudioRuntimeFixture *)runtime {
    [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-A"]];
    [runtime selectSystemAggregate:@"aggregate-A"];
}
- (NSDictionary *)read:(THSystemAudioSnapshotBridge *)bridge runtime:(THPrivateAudioRuntimeFixture *)runtime {
    NSError *error = nil;
    NSDictionary *snapshot = [bridge snapshotWithError:&error];
    XCTAssertNotNil(snapshot);
    XCTAssertNil(error);
    XCTAssertEqual(runtime.halWrites, 0u);
    XCTAssertEqual(runtime.adds, 0u);
    XCTAssertEqual(runtime.removes, 0u);
    XCTAssertEqual(runtime.modes.count, 0u, @"Reading selected identity must not start or stop discovery.");
    return snapshot;
}
- (NSDictionary *)selectedRoute:(NSDictionary *)snapshot {
    id route = snapshot[@"selection"];
    return [route isKindOfClass:NSDictionary.class] ? route : @{};
}
- (void)assertUnknown:(NSDictionary *)snapshot state:(NSString *)state {
    XCTAssertEqualObjects(snapshot[@"selection"], NSNull.null);
    XCTAssertEqualObjects(snapshot[@"isUnselectedConfirmed"], @NO,
                          @"Failed or changing evidence must not assert that no output is selected.");
    XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], state);
}

- (void)testSelectedAggregateReplacementCannotHideBehindTheSameStreamUID {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    [runtime setAggregate:@"aggregate-B" receiver:@"receiver-B" streams:@[@"stream-A"]];
    __weak THPrivateAudioRuntimeFixture *weakRuntime = runtime;
    runtime.onCopyManager = ^{
        // The first aggregate and stream have already been observed. Keep HAL
        // and AssociatedAudioDevice stable, replacing only system selection.
        [weakRuntime selectSystemAggregate:@"aggregate-B"];
    };
    THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
    [self assertUnknown:[self read:bridge runtime:runtime] state:@"selectionChangedDuringRead"];
    XCTAssertEqualObjects(runtime.defaultUID, @"stream-A");
    XCTAssertEqualObjects(runtime.selectedAggregate, @"aggregate-B");
    XCTAssertEqual(runtime.bufferedReads, 2u, @"The replacement must be rejected at the second selected-aggregate read.");
    XCTAssertEqual(runtime.managerReleases, 1u);
    runtime.onCopyManager = nil;
}

- (void)testHALUIDConflictRejectsAnOtherwiseMatchingAssociatedDevice {
    THBoundaryHALIdentityRuntime *runtime = [[THBoundaryHALIdentityRuntime alloc] initFixture];
    [self selectRoute:runtime];
    runtime.injectedHALUID = @"different-hal-stream";
    runtime.injectFromUIDRead = 1;
    THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
    [self assertUnknown:[self read:bridge runtime:runtime] state:@"selectedHALMismatch"];
    XCTAssertEqualObjects(runtime.defaultUID, @"stream-A", @"The fixture's associated UID remains the expected stream.");
    XCTAssertFalse(runtime.invalidAssociation);
    XCTAssertEqual(runtime.halUIDReads, 1u);
    XCTAssertEqual(runtime.bufferedReads, 1u);
    XCTAssertEqual(runtime.managerReleases, 1u);
}

- (void)testHALUIDChangeAtTheFinalReadRejectsTwoMatchingPrivateObservations {
    THBoundaryHALIdentityRuntime *runtime = [[THBoundaryHALIdentityRuntime alloc] initFixture];
    [self selectRoute:runtime];
    runtime.injectedHALUID = @"replacement-hal-stream";
    runtime.injectFromUIDRead = 2;
    THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
    [self assertUnknown:[self read:bridge runtime:runtime] state:@"selectionChangedDuringRead"];
    XCTAssertEqualObjects(runtime.defaultUID, @"stream-A");
    XCTAssertFalse(runtime.invalidAssociation);
    XCTAssertEqual(runtime.halUIDReads, 2u, @"The final HAL check must execute after both matching associated-UID observations.");
    XCTAssertEqual(runtime.bufferedReads, 2u);
    XCTAssertEqual(runtime.managerReleases, 1u);
}

- (void)testReadFailuresOnTheSameBridgeNeverReuseItsPreviousSelectedRoute {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
    NSArray<NSString *> *failureStates = @[@"contextUnavailable", @"invalidSystemContext",
        @"managerUnavailable", @"invalidManagerShowInfo", @"selectedHALMismatch"];
    for (NSUInteger index = 0; index < failureStates.count; index++) {
        NSDictionary *before = [self read:bridge runtime:runtime];
        XCTAssertEqualObjects([self selectedRoute:before][@"uid"], @"stream-A");
        switch (index) {
            case 0: runtime.contextStatus = -42; break;
            case 1: runtime.propertyStatus = -42; break;
            case 2: runtime.managerStatus = -42; break;
            case 3: runtime.managerPropertyStatus = -42; break;
            case 4: runtime.invalidHAL = YES; break;
        }
        [self assertUnknown:[self read:bridge runtime:runtime] state:failureStates[index]];
        runtime.contextStatus = 0;
        runtime.propertyStatus = 0;
        runtime.managerStatus = 0;
        runtime.managerPropertyStatus = 0;
        runtime.invalidHAL = NO;
        NSDictionary *recovered = [self read:bridge runtime:runtime];
        XCTAssertEqualObjects([self selectedRoute:recovered][@"uid"], @"stream-A");
        XCTAssertEqualObjects([self selectedRoute:recovered][@"readbackStable"], @YES);
    }
}

- (void)testConfirmedUnselectedReadReplacesEarlierSelectionWithoutReusingItsEvidence {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
    NSDictionary *selected = [self read:bridge runtime:runtime];
    XCTAssertEqualObjects([self selectedRoute:selected][@"identifier"], @"receiver-A");
    NSUInteger managers = runtime.managerCopies, halReads = runtime.halReads;
    [runtime selectSystemAggregate:nil];
    NSDictionary *unselected = [self read:bridge runtime:runtime];
    XCTAssertEqualObjects(unselected[@"selection"], NSNull.null);
    XCTAssertEqualObjects(unselected[@"isUnselectedConfirmed"], @YES);
    XCTAssertEqualObjects(unselected[@"diagnostics"][@"state"], @"noSelectedAggregate");
    XCTAssertEqual(runtime.managerCopies, managers);
    XCTAssertEqual(runtime.halReads, halReads);
}

- (void)testSecondMembershipReadExceptionCannotPublishTheFirstCompleteObservation {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    [self selectRoute:runtime];
    __block NSUInteger memberReads = 0;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        if ([kind isEqual:@"manager"] && [key hasSuffix:@"_ShowInfo"] && ++memberReads == 2)
            @throw [NSException exceptionWithName:@"FixtureSecondMembershipReadFailure" reason:nil userInfo:nil];
    };
    THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
    NSDictionary *snapshot = [self read:bridge runtime:runtime];
    // Whether the runtime converts the exception into a missing property or the
    // bridge catches it directly, the first observation cannot become selection.
    XCTAssertEqualObjects(snapshot[@"selection"], NSNull.null);
    XCTAssertEqualObjects(snapshot[@"isUnselectedConfirmed"], @NO);
    XCTAssertEqual([self selectedRoute:snapshot].count, 0u);
    XCTAssertEqual(memberReads, 2u);
    XCTAssertEqual(runtime.bufferedReads, 2u);
    XCTAssertEqual(runtime.managerReleases, 1u);
    runtime.onRead = nil;
}
@end
