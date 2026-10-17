#import <XCTest/XCTest.h>
#import "../Sources/Services/THRetainedSystemAudioBridge.h"
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

@interface OwnedRouteExitPreflightTests : XCTestCase
@end

@implementation OwnedRouteExitPreflightTests
- (void)withCapture:(void (^)(THRetainedSystemAudioBridge *, THPrivateAudioRuntimeFixture *))test {
    XCTestExpectation *finished = [self expectationWithDescription:@"exit removal through public bridge entry points"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"captured-stream"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        XCTAssertTrue([endpoints startWithError:NULL]);
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"][@"state"], @"selected");
        test(bridge, runtime);
        runtime.onPump = nil; runtime.onRead = nil;
        [runtime completeAdd]; [runtime completeRemove];
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop];
        [finished fulfill];
    }}] start];
    [self waitForExpectations:@[finished] timeout:5];
}
- (BOOL)addOwned:(THRetainedSystemAudioBridge *)bridge runtime:(THPrivateAudioRuntimeFixture *)runtime {
    [runtime selectSystemAggregate:nil]; [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
    return [bridge selectIdentifier:@"receiver-A" isCancelled:^{ return NO; } isShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL];
}
- (BOOL)completeNormalLeave:(THRetainedSystemAudioBridge *)bridge {
    return [bridge completedLeaveIsShuttingDown:^{ return NO; }
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; } error:NULL];
}
- (void)testProductionQuitPreflightProvesExactOwnStreamWithoutWrites {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self addOwned:bridge runtime:runtime]);
        NSUInteger writes = runtime.adds + runtime.removes + runtime.halWrites;
        NSDictionary *snapshot = [bridge ownedStreamForExitWithError:NULL];
        XCTAssertEqualObjects(snapshot[@"ownedStream"][@"receiverID"], @"receiver-A");
        XCTAssertEqualObjects(snapshot[@"ownedStream"][@"streamUID"], @"stream-A");
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, writes);
    }];
}
- (void)testProductionQuitDoesNotClaimBorrowedOrAlreadyAbsentStream {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertEqualObjects([bridge ownedStreamForExitWithError:NULL][@"ownedStream"], NSNull.null);
        XCTAssertTrue([self addOwned:bridge runtime:runtime]);
        [runtime selectSystemAggregate:nil];
        [runtime setAggregate:@"aggregate-A" receiver:nil streams:@[]];
        XCTAssertEqualObjects([bridge ownedStreamForExitWithError:NULL][@"ownedStream"], NSNull.null);
        XCTAssertEqual(runtime.removes, 0u);
    }];
}
- (void)testProductionQuitTreatsPendingAddAsUnknownInsteadOfAbsent {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.deferAdd = YES;
        XCTAssertFalse([self addOwned:bridge runtime:runtime]);
        NSError *error = nil;
        XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
        XCTAssertNotNil(error);
        XCTAssertEqual(runtime.removes + runtime.halWrites, 0u);
    }];
}
- (void)testProductionQuitRejectsExternalStreamReplacement {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self addOwned:bridge runtime:runtime]);
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"external-stream"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        NSError *error = nil;
        XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
        XCTAssertNotNil(error);
        XCTAssertEqual(runtime.removes, 0u);
        XCTAssertEqual(runtime.halWrites, 1u);
    }];
}
- (void)testProductionQuitRejectsPendingRemoveEvenWhenItsStreamIsAlreadyEmpty {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self addOwned:bridge runtime:runtime]);
        [runtime selectSystemAggregate:nil]; runtime.deferRemove = YES;
        XCTAssertFalse([self completeNormalLeave:bridge]);
        XCTAssertTrue(runtime.removeCallbackPending); XCTAssertEqual(runtime.removes, 1u);
        NSUInteger writes = runtime.adds + runtime.removes + runtime.halWrites;
        NSError *error = nil;
        XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
        XCTAssertEqualObjects(error.userInfo[@"diagnostics"][@"quitPreflightRejection"], @"removeCallbackPending");
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, writes);
        [runtime completeRemove];
        XCTAssertEqualObjects([bridge ownedStreamForExitWithError:NULL][@"ownedStream"], NSNull.null);
        XCTAssertEqual(runtime.removes, 1u);
    }];
}
- (void)testProductionQuitRejectsTerminalRemoveFailureBeforeOfferingAnotherCleanup {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self addOwned:bridge runtime:runtime]);
        [runtime selectSystemAggregate:nil]; runtime.removeStatus = -91;
        XCTAssertFalse([self completeNormalLeave:bridge]);
        NSUInteger writes = runtime.adds + runtime.removes + runtime.halWrites;
        for (NSUInteger attempt = 0; attempt < 2; attempt++) {
            NSError *error = nil;
            XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
            XCTAssertEqualObjects(error.userInfo[@"diagnostics"][@"quitPreflightRejection"], @"removeSubmissionFailed");
            BOOL chinese = [NSBundle.mainBundle.preferredLocalizations.firstObject hasPrefix:@"zh"];
            XCTAssertTrue([error.localizedDescription containsString:chinese ? @"不能重复提交" : @"cannot be submitted again"]);
            XCTAssertFalse([error.localizedDescription containsString:chinese ? @"重试" : @"Try again"]);
        }
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, writes);
        XCTAssertEqual(runtime.removes, 1u);
    }];
}
- (void)testProductionQuitRejectsThrowingRemoveEvenWhenItsPossibleSideEffectEmptiedTheStream {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self addOwned:bridge runtime:runtime]);
        [runtime selectSystemAggregate:nil]; runtime.throwFromRemove = YES;
        XCTAssertFalse([self completeNormalLeave:bridge]);
        NSUInteger writes = runtime.adds + runtime.removes + runtime.halWrites;
        NSError *error = nil;
        XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
        XCTAssertEqualObjects(error.userInfo[@"diagnostics"][@"quitPreflightRejection"], @"removeSubmissionFailed");
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, writes);
        XCTAssertEqual(runtime.removes, 1u);
    }];
}
- (void)testProductionQuitRejectsMismatchedRemoveCallbackBeforeAcceptingEmptyReadback {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self addOwned:bridge runtime:runtime]);
        [runtime selectSystemAggregate:nil]; runtime.mismatchRemove = YES;
        XCTAssertFalse([self completeNormalLeave:bridge]);
        NSUInteger writes = runtime.adds + runtime.removes + runtime.halWrites;
        NSError *error = nil;
        XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
        XCTAssertEqualObjects(error.userInfo[@"diagnostics"][@"quitPreflightRejection"], @"removeCallbackIdentityMismatch");
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, writes);
        XCTAssertEqual(runtime.removes, 1u);
    }];
}
- (void)testProductionQuitRejectsMismatchedAddCallbackWithoutWrites {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.mismatchAdd = YES;
        XCTAssertFalse([self addOwned:bridge runtime:runtime]);
        NSUInteger writes = runtime.adds + runtime.removes + runtime.halWrites;
        NSError *error = nil;
        XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
        XCTAssertEqualObjects(error.userInfo[@"diagnostics"][@"quitPreflightRejection"], @"addCallbackIdentityMismatch");
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, writes);
    }];
}
- (void)testProductionQuitRejectsUnwitnessedStreamWithoutGuessingOwnership {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        runtime.omitAddStream = YES;
        XCTAssertFalse([self addOwned:bridge runtime:runtime]);
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"unwitnessed-stream"]];
        NSUInteger writes = runtime.adds + runtime.removes + runtime.halWrites;
        NSError *error = nil;
        XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
        XCTAssertEqualObjects(error.userInfo[@"diagnostics"][@"quitPreflightRejection"], @"ownStreamNotWitnessed");
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, writes);
    }];
}
- (void)testProductionQuitRejectsUnconfirmedOutputWithoutWrites {
    [self withCapture:^(THRetainedSystemAudioBridge *bridge, THPrivateAudioRuntimeFixture *runtime) {
        XCTAssertTrue([self addOwned:bridge runtime:runtime]);
        runtime.invalidAssociation = YES;
        NSUInteger writes = runtime.adds + runtime.removes + runtime.halWrites;
        NSError *error = nil;
        XCTAssertNil([bridge ownedStreamForExitWithError:&error]);
        XCTAssertEqualObjects(error.userInfo[@"diagnostics"][@"quitPreflightRejection"], @"outputIdentityUnconfirmed");
        XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, writes);
    }];
}
@end
