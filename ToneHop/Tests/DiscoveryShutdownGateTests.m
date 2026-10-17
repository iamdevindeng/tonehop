#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "../Sources/Services/PrivateAudioBridge.h"
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntimeFixture.h"
#import "ToneHopTests-Swift.h"

@interface THDiscoveryGateTrace : NSObject
@property(nonatomic, copy) NSArray<NSNumber *> *modes;
@property(nonatomic, copy) void (^onInitialize)(void);
@property(nonatomic, copy) void (^onMode)(NSInteger);
@property(nonatomic) NSUInteger releasedSessions;
@end
@implementation THDiscoveryGateTrace
- (instancetype)init { if ((self = [super init])) _modes = @[]; return self; }
@end

// Each runtime receives its own fixture subclass and trace. There is no shared
// current-test state or replacement of a system class/function.
static const char THDiscoveryTraceKey = 0;
@interface THDiscoveryGateSession : NSObject
@property(nonatomic, strong) THDiscoveryGateTrace *trace;
- (instancetype)initWithDeviceFeatures:(NSUInteger)features;
- (void)setDiscoveryMode:(NSInteger)mode;
- (id)availableOutputDevicesObject;
- (NSArray *)otherDevices;
- (NSArray *)recentlyUsedDevices;
@end
@implementation THDiscoveryGateSession
- (instancetype)initWithDeviceFeatures:(NSUInteger)features {
    if ((self = [super init])) {
        _trace = objc_getAssociatedObject(self.class, &THDiscoveryTraceKey);
        if (_trace.onInitialize) _trace.onInitialize();
    }
    return self;
}
- (void)setDiscoveryMode:(NSInteger)mode {
    self.trace.modes = [self.trace.modes arrayByAddingObject:@(mode)];
    if (self.trace.onMode) self.trace.onMode(mode);
}
- (id)availableOutputDevicesObject { return self; }
- (NSArray *)otherDevices { return @[]; }
- (NSArray *)recentlyUsedDevices { return @[]; }
- (void)dealloc { self.trace.releasedSessions++; }
@end

@interface THDiscoveryGateRuntime : THPrivateAudioRuntimeFixture
@property(nonatomic) Class discoveryClass;
@property(nonatomic, strong) THDiscoveryGateTrace *trace;
@end
@implementation THDiscoveryGateRuntime
- (instancetype)initFixture {
    if ((self = [super initFixture])) {
        _trace = [THDiscoveryGateTrace new];
        NSString *name = [@"THDiscoveryGateSession_" stringByAppendingString:
            [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
        _discoveryClass = objc_allocateClassPair(THDiscoveryGateSession.class, name.UTF8String, 0);
        objc_registerClassPair(_discoveryClass);
        objc_setAssociatedObject(_discoveryClass, &THDiscoveryTraceKey, _trace, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
- (Class)classNamed:(NSString *)name {
    return [name isEqual:@"AVOutputDeviceDiscoverySession"] ? self.discoveryClass : Nil;
}
- (void)dealloc {
    // Class registration is process-lifetime, as with real Objective-C classes;
    // remove the per-test trace so it and its callbacks do not stay retained.
    objc_setAssociatedObject(_discoveryClass, &THDiscoveryTraceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

@interface DiscoveryShutdownGateTests : XCTestCase
@end
@implementation DiscoveryShutdownGateTests
- (void)assertDrained:(THAudioMutationGateHarness *)gate {
    XCTestExpectation *drained = [self expectationWithDescription:@"discovery submission drained"];
    [gate drainWithCompletion:^{ [drained fulfill]; }];
    [self waitForExpectations:@[drained] timeout:1];
}
- (void)testEndpointStartAfterCloseDuringManagerAcquisitionNeverSubmitsDetailed {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    runtime.onCopyManager = ^{ [gate close]; };
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
        performIfRunning:^BOOL(void (^operation)(void)) { return [gate performIfRunning:operation]; }];
    NSError *error = nil;
    XCTAssertNil([bridge snapshotWithError:&error]);
    XCTAssertEqual(error.code, NSUserCancelledError);
    XCTAssertEqual(runtime.modes.count, 0u);
    XCTAssertEqual(runtime.managerCopies, runtime.managerReleases);
    XCTAssertEqualObjects(bridge.diagnostics[@"active"], @NO);
    XCTAssertFalse([bridge startWithError:NULL], @"A closed gate cannot be bypassed by explicit start.");
    XCTAssertEqual(runtime.modes.count, 0u); XCTAssertEqual(runtime.managerCopies, runtime.managerReleases);
    [self assertDrained:gate];
}
- (void)testAVStartAfterCloseDuringInitializationDoesNotStartOrCompensate {
    THDiscoveryGateRuntime *runtime = [[THDiscoveryGateRuntime alloc] initFixture];
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    runtime.trace.onInitialize = ^{ [gate close]; };
    THPrivateAudioBridge *bridge = [[THPrivateAudioBridge alloc] initWithRuntime:runtime
        performIfRunning:^BOOL(void (^operation)(void)) { return [gate performIfRunning:operation]; }];
    @autoreleasepool {
        NSError *error = nil;
        XCTAssertNil([bridge snapshotWithError:&error]); XCTAssertEqual(error.code, NSUserCancelledError);
    }
    XCTAssertEqual(runtime.trace.modes.count, 0u, @"An unstarted session must not receive a compensating mode 0.");
    XCTAssertEqual(runtime.trace.releasedSessions, 1u);
    @autoreleasepool { XCTAssertFalse([bridge startWithError:NULL]); }
    XCTAssertEqual(runtime.trace.releasedSessions, 2u); XCTAssertEqual(runtime.trace.modes.count, 0u);
    [bridge stop]; XCTAssertEqual(runtime.trace.modes.count, 0u);
    [self assertDrained:gate];
}
- (void)testAcceptedAVDiscoveryMayFinishAfterCloseAndScopedTeardownStillRuns {
    THDiscoveryGateRuntime *runtime = [[THDiscoveryGateRuntime alloc] initFixture];
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    __block NSUInteger submissions = 0;
    runtime.trace.onMode = ^(NSInteger mode) { if (mode == 2) [gate close]; };
    THPrivateAudioBridge *bridge = [[THPrivateAudioBridge alloc] initWithRuntime:runtime
        performIfRunning:^BOOL(void (^operation)(void)) { submissions++; return [gate performIfRunning:operation]; }];
    XCTAssertTrue([bridge startWithError:NULL]);
    XCTAssertEqualObjects(runtime.trace.modes, (@[@2])); XCTAssertEqual(submissions, 1u);
    [self assertDrained:gate];
    [bridge stop];
    XCTAssertEqualObjects(runtime.trace.modes, (@[@2, @0]));
    XCTAssertFalse([bridge startWithError:NULL]);
    XCTAssertEqualObjects(runtime.trace.modes, (@[@2, @0]));
}
- (void)testAcceptedEndpointDiscoveryMayFinishAfterCloseWithoutRawNone {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    runtime.onSetMode = ^{ [gate close]; };
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
        performIfRunning:^BOOL(void (^operation)(void)) { return [gate performIfRunning:operation]; }];
    XCTAssertTrue([bridge startWithError:NULL]); [self assertDrained:gate]; [bridge stop];
    XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
    XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertFalse([bridge startWithError:NULL]);
    XCTAssertEqual(runtime.modes.count, 1u); XCTAssertEqual(runtime.managerCopies, runtime.managerReleases);
}
- (void)testDiscoveryExceptionReturnsThroughSwiftGateAndReleasesItsSession {
    for (NSNumber *useAV in @[@NO, @YES]) {
        THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
        __block BOOL returnedThroughGate = NO;
        THAudioMutationGate mutation = ^BOOL(void (^operation)(void)) {
            BOOL accepted = [gate performIfRunning:operation]; returnedThroughGate = YES; return accepted;
        };
        if (useAV.boolValue) {
            THDiscoveryGateRuntime *runtime = [[THDiscoveryGateRuntime alloc] initFixture];
            runtime.trace.onMode = ^(NSInteger mode) {
                if (mode == 2) @throw [NSException exceptionWithName:@"FixtureDiscoveryException" reason:nil userInfo:nil];
            };
            THPrivateAudioBridge *bridge = [[THPrivateAudioBridge alloc] initWithRuntime:runtime performIfRunning:mutation];
            @autoreleasepool { XCTAssertFalse([bridge startWithError:NULL]); }
            XCTAssertEqualObjects(runtime.trace.modes, (@[@2, @0])); XCTAssertEqual(runtime.trace.releasedSessions, 1u);
        } else {
            THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture]; runtime.throwFromMode = YES;
            THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:mutation];
            XCTAssertFalse([bridge startWithError:NULL]);
            XCTAssertEqual(runtime.modes.count, 1u); XCTAssertEqual(runtime.managerReleases, 1u);
        }
        XCTAssertTrue(returnedThroughGate, @"Cocoa exceptions must not unwind the Swift submission bookkeeping.");
        [gate close]; [self assertDrained:gate];
    }
}
- (void)testShutdownDrainWaitsForActualEndpointDiscoverySetterReturn {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THAudioMutationGateHarness *gate = [THAudioMutationGateHarness new];
    XCTestExpectation *entered = [self expectationWithDescription:@"discovery setter entered"];
    XCTestExpectation *finished = [self expectationWithDescription:@"discovery start returned"];
    XCTestExpectation *drained = [self expectationWithDescription:@"discovery gate drained"];
    dispatch_semaphore_t releaseSetter = dispatch_semaphore_create(0);
    dispatch_semaphore_t drainReturned = dispatch_semaphore_create(0);
    runtime.onSetMode = ^{
        [entered fulfill];
        XCTAssertEqual(dispatch_semaphore_wait(releaseSetter, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0l);
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
            performIfRunning:^BOOL(void (^operation)(void)) { return [gate performIfRunning:operation]; }];
        XCTAssertTrue([bridge startWithError:NULL]);
        [bridge stop]; [finished fulfill];
    }});
    [self waitForExpectations:@[entered] timeout:1];
    [gate close];
    [gate drainWithCompletion:^{ dispatch_semaphore_signal(drainReturned); [drained fulfill]; }];
    XCTAssertNotEqual(dispatch_semaphore_wait(drainReturned, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)), 0l);
    dispatch_semaphore_signal(releaseSetter);
    [self waitForExpectations:@[finished, drained] timeout:2];
    XCTAssertEqual(runtime.modes.count, 1u); XCTAssertEqual(runtime.managerReleases, 1u);
}
@end
