#import <XCTest/XCTest.h>
#import "../Sources/Services/THPrivateDeviceEvidence.h"
#import "../Sources/Services/THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntimeFixture.h"

@interface THIconFixtureDevice : NSObject
@end
@implementation THIconFixtureDevice
- (id)deviceID { return @"receiver-A"; }
- (id)modelID { return @"fixture-model"; }
- (id)routeSymbolName { return @"homepodmini.fill"; }
@end

@interface THIconModelOnlyDevice : THIconFixtureDevice
@end
@implementation THIconModelOnlyDevice
- (id)routeSymbolName { return nil; }
@end

@interface THIconChangingIdentityDevice : THIconFixtureDevice
@property(nonatomic) NSUInteger reads;
@end
@implementation THIconChangingIdentityDevice
- (id)deviceID { return ++self.reads == 1 ? @"receiver-A" : @"receiver-B"; }
@end

@interface THIconChangingModelDevice : THIconModelOnlyDevice
@property(nonatomic) NSUInteger reads;
@end
@implementation THIconChangingModelDevice
- (id)modelID { return ++self.reads == 1 ? @"fixture-model" : @"another-model"; }
@end

@interface THIconChangingSymbolDevice : THIconFixtureDevice
@property(nonatomic) NSUInteger reads;
@end
@implementation THIconChangingSymbolDevice
- (id)modelID { return nil; }
- (id)routeSymbolName { return ++self.reads == 1 ? @"homepodmini.fill" : @"appletv.fill"; }
@end

@interface THIconThrowingDevice : THIconFixtureDevice
@end
@implementation THIconThrowingDevice
- (id)modelID { @throw [NSException exceptionWithName:@"FixtureModelFailure" reason:nil userInfo:nil]; }
- (id)routeSymbolName { @throw [NSException exceptionWithName:@"FixtureIconFailure" reason:nil userInfo:nil]; }
@end

@interface THIconMalformedDevice : THIconFixtureDevice
@end
@implementation THIconMalformedDevice
- (id)modelID { return @42; }
- (id)routeSymbolName { return @42; }
@end

@interface THIconMutableSymbolDevice : THIconFixtureDevice
@property(nonatomic, strong) NSMutableString *symbol;
@property(nonatomic) NSUInteger reads;
@end
@implementation THIconMutableSymbolDevice
- (id)modelID { return nil; }
- (id)routeSymbolName {
    if (!self.symbol) self.symbol = [@"homepodmini.fill" mutableCopy];
    if (++self.reads > 1) [self.symbol appendString:@".changed"];
    return self.symbol;
}
@end

@interface THIconWrongABI : NSObject
@end
@implementation THIconWrongABI
- (id)deviceID { return @"receiver-A"; }
- (NSUInteger)modelID { return 42; }
- (NSUInteger)routeSymbolName { return 42; }
@end

@interface THIconSystemMapper : NSObject
@end
@implementation THIconSystemMapper
+ (id)_symbolNameForModelID:(id)identifier { return [identifier isEqual:@"fixture-model"] ? @"homepodmini.fill" : nil; }
@end

@interface THIconWrongMapperABI : NSObject
@end
@implementation THIconWrongMapperABI
+ (NSUInteger)_symbolNameForModelID:(id)identifier { return 42; }
@end

@interface THIconEvidenceRuntime : THPrivateAudioRuntimeFixture
@property(nonatomic) Class mapperClass;
@end
@implementation THIconEvidenceRuntime
- (Class)classNamed:(NSString *)name {
    return [name isEqual:@"MPAVRoutingController"] ? self.mapperClass : [super classNamed:name];
}
@end

@interface THIconRawFallbackRuntime : THIconEvidenceRuntime
@property(nonatomic) BOOL changeIdentityAfterModelReadback;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *modelReads;
@property(nonatomic, strong) NSMutableSet<NSString *> *changedIdentifiers;
@property(nonatomic) THPrivateAudioFunctions originalFunctions;
@end

static SInt32 THIconRawCopyString(CFTypeRef object, CFStringRef key, CFAllocatorRef allocator, CFTypeRef *output) {
    NSDictionary *raw = (__bridge NSDictionary *)object;
    THIconRawFallbackRuntime *runtime = (__bridge THIconRawFallbackRuntime *)[raw[@"environment"] pointerValue];
    NSString *name = (__bridge NSString *)key;
    NSString *identifier = raw[@"identifier"];
    if ([name hasSuffix:@"_Model"]) {
        NSUInteger count = [runtime.modelReads[identifier] unsignedIntegerValue] + 1;
        runtime.modelReads[identifier] = @(count);
        *output = CFRetain(CFSTR("fixture-model"));
        if (count >= 2 && runtime.changeIdentityAfterModelReadback) [runtime.changedIdentifiers addObject:identifier];
        return 0;
    }
    if ([name hasSuffix:@"_ID"] && [runtime.changedIdentifiers containsObject:identifier]) {
        *output = CFRetain((__bridge CFStringRef)[identifier stringByAppendingString:@"-changed"]);
        return 0;
    }
    return runtime.originalFunctions.copyString(object, key, allocator, output);
}

@implementation THIconRawFallbackRuntime
- (instancetype)initFixture {
    self = [super initFixture];
    if (self) {
        self.originalFunctions = [super functions];
        self.modelReads = NSMutableDictionary.dictionary;
        self.changedIdentifiers = NSMutableSet.set;
    }
    return self;
}
- (THPrivateAudioFunctions)functions {
    THPrivateAudioFunctions functions = [super functions];
    functions.copyString = THIconRawCopyString;
    return functions;
}
@end

@interface THDeviceIconEvidenceTests : XCTestCase
@end
@implementation THDeviceIconEvidenceTests
- (THIconEvidenceRuntime *)runtime {
    THIconEvidenceRuntime *runtime = [[THIconEvidenceRuntime alloc] initFixture];
    runtime.mapperClass = THIconSystemMapper.class;
    return runtime;
}

- (void)testStableExistingWrapperReturnsSystemGraphicWithoutSystemMutation {
    THIconEvidenceRuntime *runtime = [self runtime];
    NSDictionary *evidence = THPrivateDeviceIconEvidence([THIconFixtureDevice new], runtime);
    XCTAssertEqualObjects(evidence[@"identifier"], @"receiver-A");
    XCTAssertEqualObjects(evidence[@"readbackIdentifier"], @"receiver-A");
    XCTAssertEqualObjects(evidence[@"readbackStable"], @YES);
    XCTAssertEqualObjects(evidence[@"modelIdentifier"], @"fixture-model");
    XCTAssertEqualObjects(evidence[@"symbolName"], @"homepodmini.fill");
    XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes + runtime.managerCopies, 0u);
    XCTAssertEqual(runtime.modes.count, 0u);
}

- (void)testStableModelUsesSystemMapperWhenDirectSymbolIsAbsent {
    THIconEvidenceRuntime *runtime = [self runtime];
    NSDictionary *evidence = THPrivateDeviceIconEvidence([THIconModelOnlyDevice new], runtime);
    XCTAssertEqualObjects(evidence[@"symbolName"], @"homepodmini.fill");
    XCTAssertNil(THAudioDeviceSymbolForModelIdentifier(@"unrecognised-model", runtime));
    XCTAssertNil(THAudioDeviceSymbolForModelIdentifier(@"", runtime));
    runtime.mapperClass = THIconWrongMapperABI.class;
    XCTAssertNil(THAudioDeviceSymbolForModelIdentifier(@"fixture-model", runtime));
    runtime.mapperClass = Nil;
    XCTAssertEqualObjects(THPrivateDeviceIconEvidence([THIconModelOnlyDevice new], runtime)[@"symbolName"], NSNull.null);
}

- (void)testChangingIdentityModelOrSymbolCannotReuseFirstGraphic {
    THIconEvidenceRuntime *runtime = [self runtime];
    for (Class device in @[THIconChangingIdentityDevice.class, THIconChangingModelDevice.class,
                           THIconChangingSymbolDevice.class, THIconMutableSymbolDevice.class]) {
        NSDictionary *evidence = THPrivateDeviceIconEvidence([device new], runtime);
        XCTAssertEqualObjects(evidence[@"symbolName"], NSNull.null, @"%@", NSStringFromClass(device));
    }
    XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
}

- (void)testUnsupportedMalformedOrThrowingGettersRemainOptionalUnknownEvidence {
    THIconEvidenceRuntime *runtime = [self runtime];
    for (id device in @[[THIconThrowingDevice new], [THIconMalformedDevice new], [THIconWrongABI new], [NSObject new]]) {
        NSDictionary *evidence = THPrivateDeviceIconEvidence(device, runtime);
        XCTAssertEqualObjects(evidence[@"symbolName"], NSNull.null);
    }
    XCTAssertEqualObjects(THPrivateDeviceIconEvidence(nil, runtime)[@"readbackStable"], @NO);
    XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes + runtime.managerCopies, 0u);
}

- (void)testRawModelFallbackRechecksEndpointIdentityAfterItsSecondModelRead {
    for (NSNumber *changes in @[@NO, @YES]) {
        THIconRawFallbackRuntime *runtime = [[THIconRawFallbackRuntime alloc] initFixture];
        runtime.mapperClass = THIconSystemMapper.class;
        runtime.changeIdentityAfterModelReadback = changes.boolValue;
        THPrivateEndpointBridge *bridge = [[THPrivateEndpointBridge alloc] initWithRuntime:runtime
            performIfRunning:^BOOL(void (^operation)(void)) { operation(); return YES; }];
        NSDictionary *snapshot = [bridge snapshotWithError:NULL];
        XCTAssertNotNil(snapshot);
        XCTAssertEqualObjects(snapshot[@"incompleteDeviceCount"], @0);
        for (NSDictionary *row in snapshot[@"endpoints"]) {
            XCTAssertEqualObjects(row[@"discoveryIdentity"][@"readbackStable"], @YES,
                                  @"Optional icon failure does not revoke preceding discovery evidence.");
            XCTAssertEqualObjects(row[@"deviceEligibility"][@"supportsAudio"], @YES);
            XCTAssertEqualObjects(row[@"iconEvidence"][@"symbolName"], changes.boolValue ? NSNull.null : @"homepodmini.fill");
            if (!changes.boolValue) XCTAssertEqualObjects(row[@"iconEvidence"][@"readbackIdentifier"], row[@"identifier"]);
        }
        XCTAssertEqual(runtime.halWrites + runtime.adds + runtime.removes, 0u);
        [bridge stop];
    }
}
@end
