#import <XCTest/XCTest.h>
#import "../Sources/Services/THRetainedSystemAudioBridge.h"
#import "../Sources/Services/THSystemAudioSnapshotBridge.h"
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

@interface PrivateAudioCopyLifetimeTests : XCTestCase
@end
@implementation PrivateAudioCopyLifetimeTests
- (void)onAudioThread:(void (^)(void))test {
    XCTestExpectation *finished = [self expectationWithDescription:@"CF ownership through native bridge entries"];
    [[[NSThread alloc] initWithBlock:^{ @autoreleasepool { test(); [finished fulfill]; } }] start];
    [self waitForExpectations:@[finished] timeout:3];
}
- (THPrivateEndpointBridge *)endpoints:(THPrivateAudioRuntimeFixture *)runtime {
    THPrivateEndpointBridge *endpoints = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
        performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    XCTAssertTrue([endpoints startWithError:NULL]);
    return endpoints;
}
- (void)testRetainedSnapshotReleasesCopyOutValuesWhenEachGetterThrowsAfterAssignment {
    [self onAudioThread:^{
        for (NSString *operation in @[@"context", @"manager", @"buffered", @"routes",
                @"property:kFigRoutingContextProperty_ContextType"]) {
            THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
            [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-A"]];
            [runtime selectSystemAggregate:@"aggregate-A"];
            THPrivateEndpointBridge *endpoints = [self endpoints:runtime];
            runtime.throwAfterCopyOperation = operation;
            @autoreleasepool {
                THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc]
                    initWithEndpointDiscovery:endpoints runtime:runtime];
                NSDictionary *snapshot = [bridge snapshotWithError:NULL];
                XCTAssertFalse([snapshot[@"retained"] isKindOfClass:NSDictionary.class], @"%@ must not publish a captured route", operation);
                XCTAssertTrue([bridge shutdownWithError:NULL]);
            }
            XCTAssertGreaterThan(runtime.faultCopies, 0u, @"%@ must actually reach the injected Copy", operation);
            XCTAssertEqual(runtime.faultCopies, runtime.faultCopyReleases, @"%@ must release every assigned out value", operation);
            XCTAssertEqual(runtime.adds + runtime.removes + runtime.halWrites, 0u);
            [endpoints stop];
        }
    }];
}
- (void)testSystemSnapshotReleasesPropertyOutValueAndRejectsSelectionOnException {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    runtime.throwAfterCopyOperation = @"property:kFigRoutingContextProperty_ContextType";
    @autoreleasepool {
        THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(snapshot[@"selection"], NSNull.null);
        XCTAssertEqualObjects(snapshot[@"isUnselectedConfirmed"], @NO);
        XCTAssertEqualObjects(snapshot[@"diagnostics"][@"state"], @"readFailed");
    }
    XCTAssertEqual(runtime.faultCopies, 1u); XCTAssertEqual(runtime.faultCopyReleases, 1u);
}
- (void)testSelectedReadReleasesSuccessfulBufferedCopyWhenFollowingViewThrows {
    [self onAudioThread:^{
        THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
        [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-A"]];
        [runtime selectSystemAggregate:@"aggregate-A"];
        THPrivateEndpointBridge *endpoints = [self endpoints:runtime];
        THRetainedSystemAudioBridge *bridge = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:endpoints runtime:runtime];
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"retained"][@"state"], @"selected");
        runtime.trackBufferedCopyLifetimes = YES;
        __block NSUInteger managerReads = 0;
        // An existing capture first validates the held route, then its selected
        // buffered route. Throw inside that view after Copy already succeeded.
        runtime.onRead = ^(NSString *kind, NSString *key) {
            if ([kind isEqual:@"manager"] && [key hasSuffix:@"_ShowInfo"] && ++managerReads == 4)
                @throw [NSException exceptionWithName:@"FixtureSelectedViewException" reason:nil userInfo:nil];
        };
        @autoreleasepool { XCTAssertNil([bridge snapshotWithError:NULL]); }
        XCTAssertEqual(managerReads, 4u);
        XCTAssertGreaterThan(runtime.trackedBufferedCopies, 0u);
        XCTAssertEqual(runtime.trackedBufferedCopies, runtime.trackedBufferedReleases);
        runtime.onRead = nil;
        XCTAssertTrue([bridge shutdownWithError:NULL]); [endpoints stop];
    }];
}
@end
