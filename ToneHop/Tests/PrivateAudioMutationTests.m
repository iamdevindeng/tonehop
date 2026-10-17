#import <XCTest/XCTest.h>
#import "../Sources/Services/THPrivateAudioRuntime.h"
#import "ToneHopTests-Swift.h"

@interface PrivateAudioMutationTests : XCTestCase
@end

@implementation PrivateAudioMutationTests
- (void)testAcceptedMutationRunsOnceAndRealSwiftGateDrains {
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    __block NSUInteger gateCalls = 0, operationCalls = 0;
    BOOL accepted = THPerformAudioMutation(^BOOL(void (^operation)(void)) {
        gateCalls++;
        return [gate performIfRunning:operation];
    }, ^{ operationCalls++; });
    XCTAssertTrue(accepted);
    XCTAssertEqual(gateCalls, 1u);
    XCTAssertEqual(operationCalls, 1u);
    [gate close];
    XCTestExpectation *drained = [self expectationWithDescription:@"accepted mutation drained"];
    [gate drainWithCompletion:^{ [drained fulfill]; }];
    [self waitForExpectations:@[drained] timeout:1];
}

- (void)testClosedSwiftGateRejectsMutationWithoutExecutingAndDrains {
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    [gate close];
    __block NSUInteger gateCalls = 0, operationCalls = 0;
    BOOL accepted = THPerformAudioMutation(^BOOL(void (^operation)(void)) {
        gateCalls++;
        return [gate performIfRunning:operation];
    }, ^{ operationCalls++; });
    XCTAssertFalse(accepted);
    XCTAssertEqual(gateCalls, 1u);
    XCTAssertEqual(operationCalls, 0u);
    XCTestExpectation *drained = [self expectationWithDescription:@"rejected mutation left gate drained"];
    [gate drainWithCompletion:^{ [drained fulfill]; }];
    [self waitForExpectations:@[drained] timeout:1];
}

- (void)testOriginalExceptionRethrowsAfterSwiftGateReturnsAndPendingDrainCompletes {
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    NSException *original = [NSException exceptionWithName:@"FixtureNativeMutationException"
                                                   reason:@"original identity retained" userInfo:@{@"phase":@"submitted"}];
    XCTestExpectation *entered = [self expectationWithDescription:@"native mutation entered"];
    XCTestExpectation *caught = [self expectationWithDescription:@"original exception caught outside Swift gate"];
    XCTestExpectation *drained = [self expectationWithDescription:@"real Swift submission drained"];
    dispatch_semaphore_t releaseOperation = dispatch_semaphore_create(0);
    dispatch_semaphore_t drainCompleted = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("ToneHopTests.native-mutation", DISPATCH_QUEUE_SERIAL);

    dispatch_async(queue, ^{
        __block BOOL gateReturned = NO;
        @try {
            THPerformAudioMutation(^BOOL(void (^operation)(void)) {
                BOOL accepted = [gate performIfRunning:operation];
                gateReturned = YES;
                return accepted;
            }, ^{
                [entered fulfill];
                long released = dispatch_semaphore_wait(releaseOperation, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
                XCTAssertEqual(released, 0l, @"The test must release the operation before throwing.");
                @throw original;
            });
            XCTFail(@"The native exception must not be swallowed or converted into a successful submission.");
        } @catch (NSException *exception) {
            XCTAssertTrue(exception == original, @"Rethrow must preserve the exception object and its evidence.");
            XCTAssertTrue(gateReturned, @"No Cocoa exception may unwind through the Swift gate.");
        }
        [caught fulfill];
    });

    [self waitForExpectations:@[entered] timeout:1];
    [gate close];
    XCTAssertFalse([gate performIfRunning:^{ XCTFail(@"Closing must reject every later mutation."); }]);
    [gate drainWithCompletion:^{
        dispatch_semaphore_signal(drainCompleted);
        [drained fulfill];
    }];
    XCTAssertNotEqual(dispatch_semaphore_wait(drainCompleted, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)), 0l,
                      @"Drain must remain pending while the admitted native operation has not returned.");
    dispatch_semaphore_signal(releaseOperation);
    [self waitForExpectations:@[caught, drained] timeout:2];
}
@end
