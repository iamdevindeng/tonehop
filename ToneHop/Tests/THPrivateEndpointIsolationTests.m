#import <XCTest/XCTest.h>
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

// The normal bridge consumes the same fixture objects and function table as the
// other native tests. Only the designated object's raw getter is replaced.
@interface THEIsolationRuntime : THPrivateAudioRuntimeFixture
@property(nonatomic, copy) NSString *faultIdentifier;
@property(nonatomic, copy) NSString *faultSymbol;
@property(nonatomic) NSUInteger faultOnRead, faultReads, copiedFaultValues, releasedFaultValues;
@property(nonatomic) SInt32 faultStatus;
@property(nonatomic) BOOL returnsFaultStatus;
@property(nonatomic) BOOL rawBooleanValue;
@property(nonatomic, copy) NSString *missingCoreMediaKey;
- (THPrivateAudioFunctions)fixtureFunctions;
- (BOOL)faultsObject:(CFTypeRef)object key:(CFStringRef)key;
@end

static THEIsolationRuntime *THEIsolationEnvironment(CFTypeRef object) {
    return (__bridge THEIsolationRuntime *)[[(__bridge NSDictionary *)object objectForKey:@"environment"] pointerValue];
}

static void THEIsolationReleaseOutput(__unused CFAllocatorRef allocator, const void *value) {
    ((__bridge THEIsolationRuntime *)value).releasedFaultValues++;
}

static SInt32 THEIsolationCopy(CFTypeRef object, CFStringRef key, CFAllocatorRef allocator, CFTypeRef *output,
                             SInt32 (*original)(CFTypeRef, CFStringRef, CFAllocatorRef, CFTypeRef *)) {
    THEIsolationRuntime *runtime = THEIsolationEnvironment(object);
    if (![runtime faultsObject:object key:key]) return original(object, key, allocator, output);
    // A Copy getter may fill its out parameter before failing. Its release
    // callback witnesses that the bridge balances the copied reference on both
    // an exception and an OSStatus failure, without using retain-count guesses.
    const void *owner = (__bridge const void *)runtime;
    CFArrayCallBacks callbacks = {0, NULL, THEIsolationReleaseOutput, NULL, NULL};
    *output = CFArrayCreate(kCFAllocatorDefault, &owner, 1, &callbacks);
    runtime.copiedFaultValues++;
    if (runtime.returnsFaultStatus) return runtime.faultStatus;
    @throw [NSException exceptionWithName:@"FixtureRawPropertyException" reason:nil userInfo:nil];
}

static SInt32 THEIsolationString(CFTypeRef object, CFStringRef key, CFAllocatorRef allocator, CFTypeRef *output) {
    return THEIsolationCopy(object, key, allocator, output, THEIsolationEnvironment(object).fixtureFunctions.copyString);
}
static SInt32 THEIsolationNumber(CFTypeRef object, CFStringRef key, CFAllocatorRef allocator, CFTypeRef *output) {
    return THEIsolationCopy(object, key, allocator, output, THEIsolationEnvironment(object).fixtureFunctions.copyNumber);
}
static SInt32 THEIsolationArray(CFTypeRef object, CFStringRef key, CFAllocatorRef allocator, CFTypeRef *output) {
    return THEIsolationCopy(object, key, allocator, output, THEIsolationEnvironment(object).fixtureFunctions.copyArray);
}
static SInt32 THEIsolationBoolean(CFTypeRef object, CFStringRef key, Boolean *wasNull, Boolean *value) {
    THEIsolationRuntime *runtime = THEIsolationEnvironment(object);
    if (![runtime faultsObject:object key:key]) return runtime.fixtureFunctions.getBoolean(object, key, wasNull, value);
    *wasNull = false; *value = runtime.rawBooleanValue; // A partial output must never become evidence.
    if (runtime.returnsFaultStatus) return runtime.faultStatus;
    @throw [NSException exceptionWithName:@"FixtureRawPropertyException" reason:nil userInfo:nil];
}

@implementation THEIsolationRuntime
- (CFStringRef)coreMediaKey:(const char *)name {
    return [self.missingCoreMediaKey isEqual:@(name)] ? NULL : [super coreMediaKey:name];
}
- (THPrivateAudioFunctions)fixtureFunctions { return [super functions]; }
- (THPrivateAudioFunctions)functions {
    THPrivateAudioFunctions functions = [super functions];
    functions.copyString = THEIsolationString;
    functions.copyNumber = THEIsolationNumber;
    functions.copyArray = THEIsolationArray;
    functions.getBoolean = THEIsolationBoolean;
    return functions;
}
- (BOOL)faultsObject:(CFTypeRef)object key:(CFStringRef)key {
    NSDictionary *handle = (__bridge NSDictionary *)object;
    if (![handle[@"identifier"] isEqual:self.faultIdentifier] || ![(__bridge NSString *)key isEqual:self.faultSymbol]) return NO;
    self.faultReads++;
    return self.faultOnRead == 0 || self.faultReads == self.faultOnRead;
}
@end

@interface THPrivateEndpointIsolationTests : XCTestCase
@end

@implementation THPrivateEndpointIsolationTests
- (THEIsolationRuntime *)runtimeWithFault:(NSString *)symbol identifier:(NSString *)identifier {
    THEIsolationRuntime *runtime = [[THEIsolationRuntime alloc] initFixture];
    runtime.faultSymbol = symbol; runtime.faultIdentifier = identifier;
    [runtime setAggregate:@"receiver-A" receiver:nil streams:@[@"stream-A", @"stream-A2"]];
    [runtime setAggregate:@"receiver-B" receiver:nil streams:@[@"stream-B"]];
    return runtime;
}

- (void)assertDiscoveryOnly:(THEIsolationRuntime *)runtime {
    XCTAssertEqual(runtime.contextCopies, 0u);
    XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
    XCTAssertEqualObjects(runtime.modes, (@[@"kFigEndpointManagerDiscoveryMode_DetailedDiscovery"]));
    XCTAssertEqual(runtime.copiedFaultValues, runtime.releasedFaultValues);
}

- (void)assertHealthyReceiver:(NSDictionary *)row {
    XCTAssertEqualObjects(row[@"identifier"], @"receiver-B");
    XCTAssertEqualObjects(row[@"name"], @"receiver-B");
    XCTAssertEqualObjects(row[@"isCached"], @NO);
    XCTAssertEqualObjects(row[@"deviceEligibility"][@"supportsAudio"], @YES);
    XCTAssertEqualObjects(row[@"avIdentity"][@"readbackStable"], @YES);
    XCTAssertEqualObjects(row[@"streamUIDs"], (@[@"stream-B"]));
}

- (void)testRawStringNumberAndBooleanExceptionsKeepUnknownFieldsAndHealthyRows {
    for (NSDictionary *sample in @[
        @{@"symbol":@"ID", @"field":@"identifier", @"incomplete":@1},
        @{@"symbol":@"Name", @"field":@"name", @"incomplete":@1},
        @{@"symbol":@"SupportedFeatures", @"field":@"supportedFeatures", @"incomplete":@0},
        @{@"symbol":@"IsCached", @"field":@"isCached", @"incomplete":@0},
        @{@"symbol":@"IsRemoteControlOnly", @"field":@"isRemoteControlOnly", @"incomplete":@1}
    ]) {
        NSString *symbol = [@"kFigEndpointProperty_" stringByAppendingString:sample[@"symbol"]];
        THEIsolationRuntime *runtime = [self runtimeWithFault:symbol identifier:@"receiver-A"];
        THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        NSError *error = nil;
        NSDictionary *snapshot = [bridge snapshotWithError:&error];
        XCTAssertNotNil(snapshot, @"%@", symbol); XCTAssertNil(error, @"%@", symbol);
        NSArray *rows = snapshot[@"endpoints"];
        XCTAssertEqual(rows.count, 2u, @"%@", symbol);
        XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], sample[@"incomplete"], @"%@", symbol);
        if (rows.count == 2) {
            NSDictionary *bad = rows[0];
            XCTAssertEqualObjects(bad[sample[@"field"]], NSNull.null, @"%@", symbol);
            XCTAssertEqualObjects(bad[@"propertyStatus"][sample[@"field"]][@"state"], @"readFailed");
            XCTAssertEqualObjects(bad[@"propertyStatus"][sample[@"field"]][@"exception"], @"FixtureRawPropertyException");
            XCTAssertEqualObjects(bad[@"streamUIDs"], (@[@"stream-A", @"stream-A2"]));
            if ([sample[@"field"] isEqual:@"identifier"])
                XCTAssertEqualObjects(bad[@"avIdentity"][@"readbackStable"], @NO);
            [self assertHealthyReceiver:rows[1]];
        }
        XCTAssertEqual(runtime.managerCopies, 1u, @"A raw device field failure is not a manager failure.");
        [self assertDiscoveryOnly:runtime];
        runtime.faultSymbol = nil;
        XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"incompleteDeviceCount"], @0);
        XCTAssertEqual(runtime.managerCopies, 1u);
        [bridge stop];
        XCTAssertEqual(runtime.managerReleases, 1u);
    }
}

- (void)testRawCacheReadFailureRemainsDiagnosticAndDoesNotInvalidateWrapperEvidence {
    THEIsolationRuntime *runtime = [self runtimeWithFault:@"kFigEndpointProperty_IsCached" identifier:@"receiver-A"];
    runtime.returnsFaultStatus = YES;
    runtime.faultStatus = -12784;
    runtime.rawBooleanValue = YES;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSDictionary *snapshot = [bridge snapshotWithError:NULL];
    XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @0);
    NSDictionary *row = [snapshot[@"endpoints"] firstObject];
    XCTAssertEqualObjects(row[@"isCached"], NSNull.null, @"A failed getter's output cannot become restriction evidence.");
    XCTAssertEqualObjects(row[@"wrapperIsCached"], @NO);
    XCTAssertEqualObjects(row[@"deviceEligibility"][@"isCached"], @NO);
    XCTAssertEqualObjects(row[@"propertyStatus"][@"isCached"], (@{@"state":@"readFailed", @"status":@(-12784)}));
    NSArray *issues = snapshot[@"diagnostics"][@"fieldIssues"];
    XCTAssertTrue(([issues containsObject:@{@"field":@"isCached", @"state":@"readFailed", @"status":@(-12784), @"count":@1}]));
    XCTAssertFalse([issues.description containsString:@"receiver-A"]);
    XCTAssertFalse([issues.description containsString:@"receiver-B"]);
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"diagnostics"][@"fieldIssues"], issues,
                          @"Identical observations keep the same anonymous issue summary.");
    runtime.faultSymbol = nil;
    NSDictionary *recovered = [bridge snapshotWithError:NULL];
    XCTAssertEqualObjects(recovered[@"incompleteDeviceCount"], @0);
    for (NSDictionary *issue in recovered[@"diagnostics"][@"fieldIssues"])
        XCTAssertNotEqualObjects(issue[@"field"], @"isCached");
    XCTAssertEqual(runtime.managerCopies, 1u);
    [self assertDiscoveryOnly:runtime];
    [bridge stop];
}

- (void)testExplicitRemoteOnlyRowNeedsIdentityButNotDisplayName {
    THEIsolationRuntime *runtime = [self runtimeWithFault:@"kFigEndpointProperty_IsRemoteControlOnly" identifier:@"receiver-A"];
    runtime.availableEndpointIdentifiers = @[@"receiver-A"];
    runtime.missingCoreMediaKey = @"kFigEndpointProperty_Name";
    runtime.returnsFaultStatus = YES;
    runtime.rawBooleanValue = YES;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSDictionary *excluded = [bridge snapshotWithError:NULL];
    XCTAssertEqual([excluded[@"endpoints"] count], 1u);
    XCTAssertEqualObjects(excluded[@"incompleteDeviceCount"], @0);
    XCTAssertEqualObjects([excluded[@"endpoints"] firstObject][@"identifier"], @"receiver-A");
    XCTAssertEqualObjects([excluded[@"endpoints"] firstObject][@"name"], NSNull.null);
    XCTAssertEqualObjects([excluded[@"endpoints"] firstObject][@"isRemoteControlOnly"], @YES);
    runtime.rawBooleanValue = NO;
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"incompleteDeviceCount"], @1);
    runtime.faultStatus = -42;
    NSDictionary *unknown = [bridge snapshotWithError:NULL];
    XCTAssertEqualObjects(unknown[@"incompleteDeviceCount"], @1);
    XCTAssertEqualObjects([unknown[@"endpoints"] firstObject][@"isRemoteControlOnly"], NSNull.null);
    runtime.faultStatus = 0;
    runtime.rawBooleanValue = YES;
    runtime.missingCoreMediaKey = @"kFigEndpointProperty_ID";
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"incompleteDeviceCount"], @1,
                          @"Remote-only rows still need IDs to rule out hidden identity collisions.");
    [self assertDiscoveryOnly:runtime];
    [bridge stop];
}

- (void)testEndpointIdentityReadbackExceptionNeverConfirmsWrapperMapping {
    THEIsolationRuntime *runtime = [self runtimeWithFault:@"kFigEndpointProperty_ID" identifier:@"receiver-A"];
    runtime.faultOnRead = 2;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSDictionary *snapshot = [bridge snapshotWithError:NULL];
    NSArray *rows = snapshot[@"endpoints"];
    XCTAssertEqual(rows.count, 2u);
    if (rows.count == 2) {
        XCTAssertEqualObjects(rows[0][@"identifier"], @"receiver-A");
        XCTAssertEqualObjects(rows[0][@"avIdentity"][@"readbackStable"], @NO);
        XCTAssertEqualObjects(rows[0][@"propertyStatus"][@"avIdentityEndpointReadback"][@"state"], @"readFailed");
        [self assertHealthyReceiver:rows[1]];
    }
    XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @0, @"Optional mapping cannot grant endpoint capability.");
    [self assertDiscoveryOnly:runtime];
    [bridge stop];
}

- (void)testStreamsExceptionPreservesUnknownObservationAndOtherReceiver {
    THEIsolationRuntime *runtime = [self runtimeWithFault:@"kFigEndpointProperty_Streams" identifier:@"receiver-A"];
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSError *error = nil;
    NSDictionary *snapshot = [bridge snapshotWithError:&error];
    XCTAssertNotNil(snapshot); XCTAssertNil(error);
    NSArray *rows = snapshot[@"endpoints"];
    XCTAssertEqual(rows.count, 2u);
    if (rows.count == 2) {
        XCTAssertEqualObjects(rows[0][@"streamUIDs"], @[]);
        XCTAssertEqualObjects(rows[0][@"propertyStatus"][@"streams"][@"state"], @"readFailed",
                              @"No usable UIDs after an exception is not a confirmed empty stream list.");
        XCTAssertEqualObjects(rows[0][@"propertyStatus"][@"streams"][@"exception"], @"FixtureRawPropertyException");
        [self assertHealthyReceiver:rows[1]];
    }
    XCTAssertEqual(runtime.managerCopies, 1u);
    [self assertDiscoveryOnly:runtime];
    [bridge stop];
}

- (void)testStreamIdentifierExceptionDoesNotDiscardIndependentStreamOrReceiver {
    THEIsolationRuntime *runtime = [self runtimeWithFault:@"kFigEndpointStreamProperty_ID" identifier:@"stream-A"];
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSError *error = nil;
    NSDictionary *snapshot = [bridge snapshotWithError:&error];
    XCTAssertNotNil(snapshot); XCTAssertNil(error);
    NSArray *rows = snapshot[@"endpoints"];
    XCTAssertEqual(rows.count, 2u);
    if (rows.count == 2) {
        XCTAssertEqualObjects(rows[0][@"streamUIDs"], (@[@"stream-A2"]));
        NSArray *status = rows[0][@"propertyStatus"][@"streamIdentifiers"];
        XCTAssertEqual(status.count, 2u);
        if (status.count == 2) {
            XCTAssertEqualObjects(status[0][@"identifier"][@"state"], @"readFailed");
            XCTAssertEqualObjects(status[0][@"identifier"][@"exception"], @"FixtureRawPropertyException");
            XCTAssertEqualObjects(status[1][@"identifier"][@"state"], @"value");
        }
        [self assertHealthyReceiver:rows[1]];
    }
    XCTAssertEqual(runtime.managerCopies, 1u);
    [self assertDiscoveryOnly:runtime];
    [bridge stop];
}

- (void)testOSStatusAndUnexpectedTypeRetainTheirExistingFieldSemanticsAndCopyOwnership {
    for (NSNumber *status in @[@(-42), @0]) {
        THEIsolationRuntime *runtime = [self runtimeWithFault:@"kFigEndpointProperty_Name" identifier:@"receiver-A"];
        runtime.returnsFaultStatus = YES; runtime.faultStatus = status.intValue;
        THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        NSArray *rows = snapshot[@"endpoints"];
        XCTAssertEqual(rows.count, 2u);
        if (rows.count == 2) {
            XCTAssertEqualObjects(rows[0][@"name"], NSNull.null);
            XCTAssertEqualObjects(rows[0][@"propertyStatus"][@"name"][@"state"], status.intValue ? @"readFailed" : @"unexpectedType");
            XCTAssertEqualObjects(rows[0][@"propertyStatus"][@"name"][@"status"], status);
            [self assertHealthyReceiver:rows[1]];
        }
        XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @1);
        [self assertDiscoveryOnly:runtime];
        [bridge stop];
    }
}

- (void)testManagerArrayExceptionRemainsSourceFailureAndKeepsRecoveryBudget {
    THEIsolationRuntime *runtime = [self runtimeWithFault:@"kFigEndpointManagerProperty_AvailableEndpoints" identifier:@"manager"];
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSError *error = nil;
    XCTAssertNil([bridge snapshotWithError:&error]); XCTAssertNotNil(error);
    XCTAssertEqual(runtime.managerCopies, 2u);
    XCTAssertEqual(runtime.managerReleases, 1u);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryFailures"], @1);
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 2u);
    [runtime advanceTime:3];
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 3u);
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 3u);
    [runtime advanceTime:3];
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 4u);
    XCTAssertEqualObjects(bridge.diagnostics[@"recoveryFailures"], @3);
    [runtime advanceTime:29];
    XCTAssertNil([bridge snapshotWithError:NULL]);
    XCTAssertEqual(runtime.managerCopies, 4u);
    [runtime advanceTime:1];
    runtime.faultSymbol = nil;
    XCTAssertEqual([[bridge snapshotWithError:NULL][@"endpoints"] count], 2u);
    XCTAssertEqual(runtime.managerCopies, 4u, @"A healthy current manager needs no replacement.");
    [self assertDiscoveryOnly:runtime];
    [bridge stop];
    XCTAssertEqual(runtime.managerReleases, 4u);
}
@end
