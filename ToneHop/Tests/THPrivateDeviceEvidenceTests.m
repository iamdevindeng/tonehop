#import <XCTest/XCTest.h>
#import "../Sources/Services/THPrivateDeviceEvidence.h"
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "../Sources/Services/THSystemAudioSnapshotBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

typedef struct OpaqueFigEndpoint *THM4FigEndpoint;
@interface THM4DeviceTraits : NSObject
@property(nonatomic, strong) NSDictionary *endpoint;
+ (instancetype)outputDeviceWithFigEndpoint:(THM4FigEndpoint)endpoint;
@end
@implementation THM4DeviceTraits
+ (instancetype)outputDeviceWithFigEndpoint:(THM4FigEndpoint)endpoint {
    THM4DeviceTraits *device = [self new];
    device.endpoint = (__bridge NSDictionary *)(CFTypeRef)endpoint;
    return device;
}
- (NSUInteger)deviceFeatures { return 1; }
- (BOOL)isCached { return NO; }
- (BOOL)isDeviceDisabled { return NO; }
- (BOOL)requiresAuthorization { return NO; }
@end

@interface THM4StableDevice : THM4DeviceTraits
@end
@implementation THM4StableDevice
- (id)deviceID { return self.endpoint[@"identifier"]; }
@end

@interface THM4ChangingDevice : THM4StableDevice
@property(nonatomic) NSUInteger reads;
@end
@implementation THM4ChangingDevice
- (id)deviceID { return ++self.reads == 1 ? [super deviceID] : @"changed-wrapper-id"; }
@end

@interface THM4MutableIdentityDevice : THM4StableDevice
@property(nonatomic, strong) NSMutableString *identity;
@property(nonatomic) NSUInteger reads;
@end
@implementation THM4MutableIdentityDevice
- (id)deviceID {
    if (!self.identity) self.identity = [[super deviceID] mutableCopy];
    if (++self.reads == 2) [self.identity appendString:@"-changed"];
    return self.identity;
}
@end

@interface THM4EmptyDevice : THM4StableDevice
@end
@implementation THM4EmptyDevice
- (id)deviceID { return @""; }
@end

@interface THM4MalformedDevice : THM4StableDevice
@end
@implementation THM4MalformedDevice
- (id)deviceID { return @42; }
@end

@interface THM4ThrowingIdentityDevice : THM4StableDevice
@end
@implementation THM4ThrowingIdentityDevice
- (id)deviceID { @throw [NSException exceptionWithName:@"FixtureIdentityFailure" reason:nil userInfo:nil]; }
@end

@interface THM4ThrowingEligibilityDevice : THM4DeviceTraits
@end
@implementation THM4ThrowingEligibilityDevice
- (BOOL)isDeviceDisabled { @throw [NSException exceptionWithName:@"FixtureEligibilityFailure" reason:nil userInfo:nil]; }
@end

@interface THM4OneThrowingEligibilityDevice : THM4StableDevice
@end
@implementation THM4OneThrowingEligibilityDevice
- (BOOL)isDeviceDisabled {
    if ([self.endpoint[@"identifier"] isEqual:@"receiver-A"])
        @throw [NSException exceptionWithName:@"FixtureEligibilityFailure" reason:nil userInfo:nil];
    return NO;
}
@end

@interface THM4ThrowingFeaturesDevice : THM4StableDevice
@end
@implementation THM4ThrowingFeaturesDevice
- (NSUInteger)deviceFeatures { @throw [NSException exceptionWithName:@"FixtureFeatureFailure" reason:nil userInfo:nil]; }
@end

@interface THM4ThrowingCacheDevice : THM4StableDevice
@end
@implementation THM4ThrowingCacheDevice
- (BOOL)isCached { @throw [NSException exceptionWithName:@"FixtureCacheFailure" reason:nil userInfo:nil]; }
@end

@interface THM4NonAudioDevice : THM4ThrowingEligibilityDevice
@end
@implementation THM4NonAudioDevice
- (NSUInteger)deviceFeatures { return 0; }
@end

@interface THM4CachedDevice : THM4ThrowingFeaturesDevice
@end
@implementation THM4CachedDevice
- (BOOL)isCached { return YES; }
@end

@interface THM4SecondAudioUnknownDevice : THM4StableDevice
@property(nonatomic) NSUInteger featureReads;
@end
@implementation THM4SecondAudioUnknownDevice
- (NSUInteger)deviceFeatures {
    if (++self.featureReads > 1) @throw [NSException exceptionWithName:@"FixtureFeatureFailure" reason:nil userInfo:nil];
    return 1;
}
@end

@interface THM4ChangingAuthorizationDevice : THM4StableDevice
@property(nonatomic) NSUInteger authorizationReads;
@end
@implementation THM4ChangingAuthorizationDevice
- (BOOL)requiresAuthorization { return ++self.authorizationReads > 1; }
@end

@interface THM4WrongBooleanABI : NSObject
@end
@implementation THM4WrongBooleanABI
- (NSUInteger)deviceFeatures { return 1; }
- (id)isCached { return @NO; }
- (BOOL)isDeviceDisabled { return NO; }
- (BOOL)requiresAuthorization { return NO; }
@end

@interface THM4EndpointRuntime : THPrivateAudioRuntimeFixture
@property(nonatomic) Class wrapperClass;
@property(nonatomic, copy) NSString *missingCoreMediaKey;
@end
@implementation THM4EndpointRuntime
- (Class)classNamed:(NSString *)name {
    return [name isEqualToString:@"AVOutputDevice"] ? self.wrapperClass : [super classNamed:name];
}
- (CFStringRef)coreMediaKey:(const char *)name {
    return [self.missingCoreMediaKey isEqual:@(name)] ? NULL : [super coreMediaKey:name];
}
@end

@interface THPrivateDeviceEvidenceTests : XCTestCase
@end
@implementation THPrivateDeviceEvidenceTests
- (void)testOnlyHealthyExplicitlyEmptySystemSelectionConfirmsUnselectedState {
    THPrivateAudioRuntimeFixture *runtime = [[THPrivateAudioRuntimeFixture alloc] initFixture];
    THSystemAudioSnapshotBridge *bridge = [[THSystemAudioSnapshotBridge alloc] initWithRuntime:runtime];
    NSDictionary *empty = [bridge snapshotWithError:NULL];
    XCTAssertEqualObjects(empty[@"selection"], NSNull.null);
    XCTAssertEqualObjects(empty[@"isUnselectedConfirmed"], @YES);
    XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)empty[@"isUnselectedConfirmed"]), CFBooleanGetTypeID());

    runtime.contextStatus = -1;
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"isUnselectedConfirmed"], @NO);
    runtime.contextStatus = 0;
    runtime.invalidContext = YES;
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"isUnselectedConfirmed"], @NO);
    runtime.invalidContext = NO;
    runtime.onRead = ^(NSString *kind, NSString *key) {
        @throw [NSException exceptionWithName:@"FixtureReadFailure" reason:nil userInfo:nil];
    };
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"isUnselectedConfirmed"], @NO);
    runtime.onRead = nil;
    [runtime setAggregate:@"aggregate-A" receiver:@"receiver-A" streams:@[@"stream-A"]];
    [runtime selectSystemAggregate:@"aggregate-A"];
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"isUnselectedConfirmed"], @NO);
    XCTAssertEqual(runtime.halWrites, 0u); XCTAssertEqual(runtime.adds, 0u); XCTAssertEqual(runtime.removes, 0u);
}

- (void)testEligibilityReadsAreStrictAndEachOptionalGetterFailsIndependently {
    NSDictionary *valid = THPrivateDeviceEligibility([THM4DeviceTraits new]);
    XCTAssertEqualObjects(valid, (@{@"supportsAudio":@YES, @"isCached":@NO, @"isDeviceDisabled":@NO, @"requiresAuthorization":@NO}));
    NSDictionary *throwing = THPrivateDeviceEligibility([THM4ThrowingEligibilityDevice new]);
    XCTAssertEqualObjects(throwing[@"isDeviceDisabled"], NSNull.null);
    XCTAssertEqualObjects(throwing[@"isCached"], @NO);
    XCTAssertEqualObjects(throwing[@"requiresAuthorization"], @NO);
    XCTAssertEqualObjects(THPrivateDeviceEligibility([THM4WrongBooleanABI new])[@"isCached"], NSNull.null);
    for (id value in THPrivateDeviceEligibility(nil).allValues) XCTAssertEqualObjects(value, NSNull.null);
}

- (void)testEndpointWrapperMappingUsesTheSameLiveObjectAndStableIdentifierReadback {
    THM4EndpointRuntime *runtime = [[THM4EndpointRuntime alloc] initFixture];
    runtime.wrapperClass = THM4StableDevice.class;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSDictionary *snapshot = [bridge snapshotWithError:NULL];
    XCTAssertNotNil(snapshot);
    XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @0);
    XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)snapshot[@"incompleteDeviceCount"]), CFNumberGetTypeID());
    XCTAssertGreaterThan([snapshot[@"endpoints"] count], 0u);
    for (NSDictionary *row in snapshot[@"endpoints"]) {
        NSDictionary *identity = row[@"avIdentity"];
        XCTAssertEqualObjects(identity[@"endpointIdentifier"], row[@"identifier"]);
        XCTAssertEqualObjects(identity[@"avDeviceIdentifier"], row[@"identifier"]);
        XCTAssertEqualObjects(identity[@"readbackStable"], @YES);
        XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)identity[@"readbackStable"]), CFBooleanGetTypeID());
    }
    [bridge stop];
    XCTAssertEqual(runtime.halWrites, 0u); XCTAssertEqual(runtime.adds, 0u); XCTAssertEqual(runtime.removes, 0u);
    XCTAssertEqual(runtime.modes.count, 1u, @"Identity reads must not start an additional discovery session.");
}

- (void)testOneThrowingEligibilityGetterPreservesBothRowsAndIndependentEvidence {
    THM4EndpointRuntime *runtime = [[THM4EndpointRuntime alloc] initFixture];
    runtime.wrapperClass = THM4OneThrowingEligibilityDevice.class;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSError *error = nil;
    NSDictionary *snapshot = [bridge snapshotWithError:&error];
    XCTAssertNotNil(snapshot); XCTAssertNil(error);
    XCTAssertEqual([snapshot[@"endpoints"] count], 2u);
    XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @1);
    for (NSDictionary *row in snapshot[@"endpoints"]) {
        BOOL fails = [row[@"identifier"] isEqual:@"receiver-A"];
        XCTAssertEqualObjects(row[@"isDeviceDisabled"], fails ? NSNull.null : @NO);
        XCTAssertEqualObjects(row[@"deviceEligibility"][@"isDeviceDisabled"], fails ? NSNull.null : @NO);
        XCTAssertEqualObjects(row[@"deviceEligibility"][@"requiresAuthorization"], @NO);
        XCTAssertEqualObjects(row[@"deviceEligibility"][@"supportsAudio"], @YES);
        XCTAssertEqualObjects(row[@"avIdentity"][@"readbackStable"], @YES);
    }
    XCTAssertEqual(runtime.managerCopies, 1u, @"One wrapper failure is not a manager failure.");
    XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
    [bridge stop];
}

- (void)testThrowingFeatureGetterKeepsUnknownCapabilityWithoutFailingCatalog {
    THM4EndpointRuntime *runtime = [[THM4EndpointRuntime alloc] initFixture];
    runtime.wrapperClass = THM4ThrowingFeaturesDevice.class;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSDictionary *snapshot = [bridge snapshotWithError:NULL];
    XCTAssertEqual([snapshot[@"endpoints"] count], 2u);
    XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @2);
    for (NSDictionary *row in snapshot[@"endpoints"]) {
        XCTAssertEqualObjects(row[@"deviceFeatures"], NSNull.null);
        XCTAssertEqualObjects(row[@"deviceEligibility"][@"supportsAudio"], NSNull.null);
        XCTAssertEqualObjects(row[@"deviceEligibility"][@"isDeviceDisabled"], @NO);
    }
    [bridge stop];
}

- (void)testEligibilityKeepsItsIndependentSecondPermissionObservation {
    THM4EndpointRuntime *runtime = [[THM4EndpointRuntime alloc] initFixture];
    runtime.wrapperClass = THM4ChangingAuthorizationDevice.class;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    NSDictionary *snapshot = [bridge snapshotWithError:NULL];
    XCTAssertEqual([snapshot[@"endpoints"] count], 2u);
    XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @0, @"An explicit restriction is complete evidence.");
    for (NSDictionary *row in snapshot[@"endpoints"]) {
        XCTAssertEqualObjects(row[@"requiresAuthorization"], @NO);
        XCTAssertEqualObjects(row[@"deviceEligibility"][@"requiresAuthorization"], @YES);
    }
    [bridge stop];
}

- (void)testCriticalEvidenceCountRecoversAndIgnoresOptionalDiagnosticFields {
    THM4EndpointRuntime *runtime = [[THM4EndpointRuntime alloc] initFixture];
    runtime.wrapperClass = THM4OneThrowingEligibilityDevice.class;
    THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"incompleteDeviceCount"], @1);
    runtime.wrapperClass = THM4StableDevice.class;
    runtime.missingCoreMediaKey = @"kFigEndpointProperty_Model";
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"incompleteDeviceCount"], @0);
    runtime.missingCoreMediaKey = @"kFigEndpointProperty_IsRemoteControlOnly";
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"incompleteDeviceCount"], @2);
    runtime.missingCoreMediaKey = @"kFigEndpointProperty_IsCached";
    NSDictionary *optionalCache = [bridge snapshotWithError:NULL];
    XCTAssertEqualObjects(optionalCache[@"incompleteDeviceCount"], @0);
    XCTAssertEqualObjects(optionalCache[@"endpoints"][0][@"isCached"], NSNull.null);
    XCTAssertEqualObjects(optionalCache[@"endpoints"][0][@"propertyStatus"][@"isCached"][@"state"], @"missingSymbol");
    runtime.missingCoreMediaKey = nil;
    XCTAssertEqualObjects([bridge snapshotWithError:NULL][@"incompleteDeviceCount"], @0);
    XCTAssertEqual(runtime.managerCopies, 1u);
    [bridge stop];
}

- (void)testUnknownWrapperCacheAndSecondAudioObservationRemainIncomplete {
    for (Class wrapper in @[THM4ThrowingCacheDevice.class, THM4SecondAudioUnknownDevice.class]) {
        THM4EndpointRuntime *runtime = [[THM4EndpointRuntime alloc] initFixture];
        runtime.wrapperClass = wrapper;
        THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqual([snapshot[@"endpoints"] count], 2u);
        XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @2);
        NSString *field = wrapper == THM4ThrowingCacheDevice.class ? @"isCached" : @"supportsAudio";
        NSString *statusField = [@"deviceEligibility." stringByAppendingString:field];
        for (NSDictionary *row in snapshot[@"endpoints"]) {
            XCTAssertEqualObjects(row[@"deviceEligibility"][field], NSNull.null);
            XCTAssertEqualObjects(row[@"propertyStatus"][statusField][@"state"],
                                  @"unavailableWrapperEvidence");
        }
        XCTAssertEqual(runtime.managerCopies, 1u);
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
        [bridge stop];
    }
}

- (void)testExplicitlyExcludedRowsNeedIdentityButNotDisplayNameOrUnrelatedEligibility {
    for (Class wrapper in @[THM4NonAudioDevice.class, THM4CachedDevice.class]) {
        THM4EndpointRuntime *runtime = [[THM4EndpointRuntime alloc] initFixture];
        runtime.wrapperClass = wrapper;
        runtime.missingCoreMediaKey = @"kFigEndpointProperty_Name";
        THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertEqual([snapshot[@"endpoints"] count], 2u, @"Excluded rows remain available as raw evidence.");
        XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @0);
        for (NSDictionary *row in snapshot[@"endpoints"]) {
            XCTAssertNotEqualObjects(row[@"identifier"], NSNull.null);
            XCTAssertEqualObjects(row[@"name"], NSNull.null);
            XCTAssertEqualObjects(row[@"propertyStatus"][@"name"][@"state"], @"missingSymbol");
        }
        XCTAssertGreaterThan([snapshot[@"diagnostics"][@"fieldIssues"] count], 0u);
        runtime.missingCoreMediaKey = @"kFigEndpointProperty_ID";
        NSDictionary *unknownIdentity = [bridge snapshotWithError:NULL];
        XCTAssertEqualObjects(unknownIdentity[@"incompleteDeviceCount"], @2,
                              @"Excluded rows still need IDs to rule out hidden identity collisions.");
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
        [bridge stop];
    }
}

- (void)testChangedMissingEmptyMalformedOrThrowingWrapperIdentityNeverConfirmsMapping {
    for (Class cls in @[THM4ChangingDevice.class, THM4MutableIdentityDevice.class, THM4DeviceTraits.class, THM4EmptyDevice.class,
                        THM4MalformedDevice.class, THM4ThrowingIdentityDevice.class]) {
        THM4EndpointRuntime *runtime = [[THM4EndpointRuntime alloc] initFixture];
        runtime.wrapperClass = cls;
        THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        NSError *error = nil;
        NSDictionary *snapshot = [bridge snapshotWithError:&error];
        XCTAssertNotNil(snapshot, @"Optional mapping evidence must not fail the whole catalog: %@", NSStringFromClass(cls));
        XCTAssertNil(error);
        for (NSDictionary *row in snapshot[@"endpoints"]) {
            XCTAssertEqualObjects(row[@"avIdentity"][@"readbackStable"], @NO, @"%@", NSStringFromClass(cls));
        }
        [bridge stop];
        XCTAssertEqual(runtime.halWrites, 0u); XCTAssertEqual(runtime.adds, 0u); XCTAssertEqual(runtime.removes, 0u);
    }
}
@end
