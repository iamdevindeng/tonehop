#import "THPrivateAudioRuntimeFixture.h"

// A fixture CF object carries its environment identity; no global/current-test
// lookup is involved. The test owns the environment until all callbacks finish.
static THPrivateAudioRuntimeFixture *THFixtureEnvironment(CFTypeRef object) {
    return (__bridge THPrivateAudioRuntimeFixture *)[[(__bridge NSDictionary *)object objectForKey:@"environment"] pointerValue];
}

typedef void (*THFixtureCallback)(CFTypeRef, CFTypeRef, uint64_t, uint64_t, SInt32, void *);
@interface THFixtureReleaseToken : NSObject
@property(nonatomic, copy) void (^released)(void);
@end
@implementation THFixtureReleaseToken
- (void)dealloc { if (_released) _released(); }
@end

@interface THPrivateAudioRuntimeFixture ()
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *handles;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *aggregates;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *halIDs;
@property(nonatomic, strong) NSMutableArray<NSString *> *bluetoothDeviceUIDs;
@property(nonatomic, copy) void (^addCompletion)(void);
@property(nonatomic, copy) void (^removeCompletion)(void);
@property(nonatomic) NSTimeInterval time;
@property(nonatomic) NSUInteger sessionGeneration;
- (id)readObject:(CFTypeRef)object key:(NSString *)key;
- (NSDictionary *)handle:(NSString *)kind identifier:(NSString *)identifier;
- (SInt32)aggregate:(CFTypeRef)aggregate leaf:(CFTypeRef)leaf add:(BOOL)add callback:(THFixtureCallback)callback refcon:(void *)refcon;
- (void)throwAfterCopy:(NSString *)operation output:(CFTypeRef *)output;
@end

static SInt32 THFixtureCopyProperty(CFTypeRef object, CFStringRef key, CFAllocatorRef allocator, CFTypeRef *output) {
    THPrivateAudioRuntimeFixture *environment = THFixtureEnvironment(object);
    if ([[(__bridge NSDictionary *)object objectForKey:@"generation"] unsignedIntegerValue] != environment.sessionGeneration) {
        *output = NULL;
        if (environment.throwFromStaleSession) @throw [NSException exceptionWithName:@"FixtureStaleProxyException" reason:nil userInfo:nil];
        return environment.staleSessionStatus;
    }
    if ([[(__bridge NSDictionary *)object objectForKey:@"kind"] isEqual:@"manager"] && environment.managerPropertyStatus) {
        *output = NULL; return environment.managerPropertyStatus;
    }
    if (environment.propertyStatus) { *output = NULL; return environment.propertyStatus; }
    if ([[(__bridge NSDictionary *)object objectForKey:@"kind"] isEqual:@"bluetooth"]) {
        SInt32 status = [environment.bluetoothRouteStatuses[[[(__bridge NSString *)key componentsSeparatedByString:@"_"] lastObject]] intValue];
        if (status) { *output = NULL; return status; }
    }
    if ([(__bridge NSString *)key hasSuffix:@"_AssociatedAudioDevice"] && environment.associatedStatus) {
        *output = NULL; return environment.associatedStatus;
    }
    id value = [environment readObject:object key:(__bridge NSString *)key];
    *output = value ? CFRetain((__bridge CFTypeRef)value) : NULL;
    [environment throwAfterCopy:[@"property:" stringByAppendingString:(__bridge NSString *)key] output:output];
    return 0;
}
static SInt32 THFixtureBoolean(CFTypeRef object, CFStringRef key, Boolean *wasNull, Boolean *value) {
    THPrivateAudioRuntimeFixture *environment = THFixtureEnvironment(object);
    if ([[(__bridge NSDictionary *)object objectForKey:@"kind"] isEqual:@"bluetooth"]) {
        SInt32 status = [environment.bluetoothRouteStatuses[[[(__bridge NSString *)key componentsSeparatedByString:@"_"] lastObject]] intValue];
        if (status) { *wasNull = true; *value = false; return status; }
    }
    id raw = [environment readObject:object key:(__bridge NSString *)key];
    *wasNull = raw == nil; *value = [raw boolValue]; return environment.propertyStatus;
}
static SInt32 THFixtureCopyRoutes(CFTypeRef context, CFTypeRef *output) {
    THPrivateAudioRuntimeFixture *environment = THFixtureEnvironment(context);
    if (environment.onRead) environment.onRead(@"context", @"CopyRoutes");
    if ([[(__bridge NSDictionary *)context objectForKey:@"generation"] unsignedIntegerValue] != environment.sessionGeneration) {
        *output = NULL;
        if (environment.throwFromStaleSession) @throw [NSException exceptionWithName:@"FixtureStaleProxyException" reason:nil userInfo:nil];
        return environment.staleSessionStatus;
    }
    if (environment.routesStatus) { *output = NULL; return environment.routesStatus; }
    if (environment.routesWrongType) { *output = CFRetain(CFSTR("not a routes array")); return 0; }
    BOOL bluetooth = [environment.bluetoothDeviceUIDs containsObject:environment.defaultUID ?: @""];
    NSArray *members = environment.contextRouteIdentifiers ?: (bluetooth ? @[@"bluetooth-route-A"] :
        environment.aggregates[environment.selectedAggregate ?: @""][@"members"] ?: @[]);
    NSMutableArray *routes = [NSMutableArray array];
    for (NSString *identifier in members) [routes addObject:[environment handle:(bluetooth || environment.contextRouteIdentifiers) ? @"bluetooth" : @"leaf" identifier:identifier]];
    *output = CFRetain((__bridge CFTypeRef)routes);
    [environment throwAfterCopy:@"routes" output:output];
    return environment.invalidContext ? -1 : 0;
}
static SInt32 THFixtureCopyBuffered(CFTypeRef context, CFStringRef options, CFTypeRef *output) {
    THPrivateAudioRuntimeFixture *environment = THFixtureEnvironment(context);
    environment.bufferedReads++;
    if (environment.onRead) environment.onRead(@"context", @"CopySelectedBufferedEndpoint");
    if ([[(__bridge NSDictionary *)context objectForKey:@"generation"] unsignedIntegerValue] != environment.sessionGeneration) {
        *output = NULL;
        if (environment.throwFromStaleSession) @throw [NSException exceptionWithName:@"FixtureStaleProxyException" reason:nil userInfo:nil];
        return environment.staleSessionStatus;
    }
    if (environment.bufferedStatus) { *output = NULL; return environment.bufferedStatus; }
    id selected = environment.contextBufferedAggregateOverride ?: environment.selectedAggregate;
    if (selected == NSNull.null) selected = nil;
    *output = [selected isKindOfClass:NSString.class] ? CFRetain((__bridge CFTypeRef)[environment handle:@"aggregate" identifier:selected]) :
        selected ? CFRetain((__bridge CFTypeRef)selected) : NULL;
    if (*output && environment.trackBufferedCopyLifetimes) {
        __weak THPrivateAudioRuntimeFixture *owner = environment;
        THFixtureReleaseToken *token = [THFixtureReleaseToken new]; token.released = ^{ owner.trackedBufferedReleases++; };
        CFMutableDictionaryRef tracked = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, *output);
        CFDictionarySetValue(tracked, CFSTR("copiedLifetime"), (__bridge CFTypeRef)token);
        CFRelease(*output); *output = tracked; environment.trackedBufferedCopies++;
    }
    [environment throwAfterCopy:@"buffered" output:output];
    return environment.invalidContext ? -1 : 0;
}
static SInt32 THFixtureAdd(CFTypeRef aggregate, CFTypeRef leaf, CFDictionaryRef options, THFixtureCallback callback, void *refcon) {
    return [THFixtureEnvironment(aggregate) aggregate:aggregate leaf:leaf add:YES callback:callback refcon:refcon];
}
static SInt32 THFixtureRemove(CFTypeRef aggregate, CFTypeRef leaf, CFDictionaryRef options, THFixtureCallback callback, void *refcon) {
    return [THFixtureEnvironment(aggregate) aggregate:aggregate leaf:leaf add:NO callback:callback refcon:refcon];
}
static SInt32 THFixtureMode(CFTypeRef manager, CFStringRef mode, CFDictionaryRef options) {
    THPrivateAudioRuntimeFixture *environment = THFixtureEnvironment(manager);
    environment.modes = [environment.modes arrayByAddingObject:(__bridge NSString *)mode];
    if (environment.onSetMode) environment.onSetMode();
    if (environment.throwFromMode) @throw [NSException exceptionWithName:@"FixtureDiscoveryException" reason:nil userInfo:nil];
    return environment.modeStatus;
}
static const void * const *THFixtureVTable(CFTypeRef object) {
    static const void * const base[] = {NULL, NULL, NULL, NULL, NULL, NULL, THFixtureCopyProperty};
    static const void * const routing[] = {(void *)1, NULL, NULL, NULL, NULL, NULL, NULL, THFixtureCopyRoutes,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, THFixtureCopyBuffered};
    static const void * const operations[] = {(void *)1, THFixtureAdd, THFixtureRemove};
    static const void * const manager[] = {(void *)1, THFixtureMode};
    static const void * const contextTable[] = {NULL, base, routing, NULL, operations};
    static const void * const managerTable[] = {NULL, base, manager, NULL, operations};
    return [[(__bridge NSDictionary *)object objectForKey:@"kind"] isEqual:@"manager"] ? managerTable : contextTable;
}
static CFTypeID THFixtureType(void) { return CFDictionaryGetTypeID(); }
static SInt32 THFixtureContextPlaceholder(CFAllocatorRef allocator, CFDictionaryRef options, CFTypeRef *output) { *output = NULL; return -1; }
static SInt32 THFixtureManagerPlaceholder(CFTypeRef *output) { *output = NULL; return -1; }

// Match the actual wrapper ABI. Its input CF object supplies the environment.
typedef struct OpaqueFigEndpoint *THFixtureFigEndpoint;
@interface THFixtureOutputDevice : NSObject
@property(nonatomic, strong) NSDictionary *endpoint;
+ (instancetype)outputDeviceWithFigEndpoint:(THFixtureFigEndpoint)endpoint;
@end
@implementation THFixtureOutputDevice
+ (instancetype)outputDeviceWithFigEndpoint:(THFixtureFigEndpoint)endpoint {
    THFixtureOutputDevice *device = [self new]; device.endpoint = (__bridge NSDictionary *)(CFTypeRef)endpoint; return device;
}
- (NSString *)deviceID { return self.endpoint[@"identifier"]; }
- (NSUInteger)deviceFeatures { return 1; }
- (BOOL)isCached { return NO; }
- (BOOL)isDeviceDisabled { return NO; }
- (BOOL)requiresAuthorization { return NO; }
@end

@implementation THPrivateAudioRuntimeFixture
- (instancetype)initFixture {
    THPrivateAudioFunctions functions = {0};
    functions.copyContext = THFixtureContextPlaceholder; functions.copyManager = THFixtureManagerPlaceholder;
    functions.getVTable = THFixtureVTable;
    functions.contextType = THFixtureType; functions.managerType = THFixtureType;
    functions.endpointType = THFixtureType; functions.streamType = THFixtureType;
    functions.copyArray = THFixtureCopyProperty; functions.copyString = THFixtureCopyProperty;
    functions.copyNumber = THFixtureCopyProperty; functions.getBoolean = THFixtureBoolean;
    NSMutableDictionary *keys = [NSMutableDictionary dictionary];
    CFStringRef (^keyResolver)(const char *) = ^CFStringRef(const char *symbol) {
        NSString *name = @(symbol); if (!keys[name]) keys[name] = name;
        return (__bridge CFStringRef)keys[name];
    };
    // Clock blocks are rebound through a weak owner after construction.
    __block __weak THPrivateAudioRuntimeFixture *owner;
    self = [super initWithFunctions:functions keyResolver:keyResolver coreMediaKeyResolver:keyResolver
        symbolName:^NSString *(const void *function) {
            if (function == THFixtureCopyProperty) return @"THFixtureCopyProperty";
            if (function == THFixtureCopyRoutes) return @"routingContextRemoteXPC_CopyRoutes";
            if (function == THFixtureCopyBuffered) return @"routingContextRemoteXPC_CopySelectedBufferedEndpoint";
            if (function == THFixtureAdd) return @"FigEndpointRemoteXPC_EndpointAggregateAddEndpointWithCompletionCallback";
            if (function == THFixtureRemove) return @"FigEndpointRemoteXPC_EndpointAggregateRemoveEndpointWithCompletionCallback";
            return @"";
        } classResolver:^Class(NSString *name) { return [name isEqual:@"AVOutputDevice"] ? THFixtureOutputDevice.class : Nil; }
        avRoutingAvailable:YES uptime:^{ return owner.time; }
        pump:^(NSTimeInterval seconds, useconds_t microseconds) {
            owner.time += seconds + microseconds / 1000000.0;
            if (owner.onPump) owner.onPump();
        }];
    if (self) {
        owner = self; _handles = [NSMutableDictionary dictionary]; _aggregates = [NSMutableDictionary dictionary];
        _halIDs = [NSMutableDictionary dictionaryWithObject:@1 forKey:@"local"];
        _contextIdentifier = @"context-A"; _modes = @[]; _defaultUID = @"local"; _staleSessionStatus = -16155;
        _availableEndpointIdentifiers = @[@"receiver-A", @"receiver-B"];
        _bluetoothDeviceUIDs = [NSMutableArray array]; _bluetoothRouteProperties = @{}; _bluetoothRouteStatuses = @{};
    }
    return self;
}
- (NSDictionary *)handle:(NSString *)kind identifier:(NSString *)identifier {
    NSString *key = [NSString stringWithFormat:@"%lu:%@:%@", (unsigned long)self.sessionGeneration, kind, identifier];
    if (!_handles[key]) _handles[key] = @{@"kind":kind, @"identifier":identifier, @"generation":@(self.sessionGeneration),
        @"environment":[NSValue valueWithPointer:(__bridge const void *)self]};
    return _handles[key];
}
- (SInt32)copyContext:(CFAllocatorRef)allocator options:(CFDictionaryRef)options output:(CFTypeRef *)output {
    self.contextCopies++; if (self.onCopyContext) self.onCopyContext();
    *output = self.contextStatus ? NULL : CFRetain((__bridge CFTypeRef)[self handle:@"context" identifier:self.contextIdentifier]);
    [self throwAfterCopy:@"context" output:output];
    return self.contextStatus;
}
- (SInt32)copyManager:(CFTypeRef *)output {
    self.managerCopies++; if (self.onCopyManager) self.onCopyManager();
    if (self.managerWrongType) { *output = CFRetain(CFSTR("wrong manager type")); return 0; }
    if (self.managerStatus) { *output = NULL; return self.managerStatus; }
    __weak THPrivateAudioRuntimeFixture *owner = self;
    THFixtureReleaseToken *token = [THFixtureReleaseToken new]; token.released = ^{ owner.managerReleases++; };
    CFMutableDictionaryRef manager = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(manager, CFSTR("kind"), CFSTR("manager"));
    CFDictionarySetValue(manager, CFSTR("identifier"), CFSTR("manager"));
    CFDictionarySetValue(manager, CFSTR("environment"), (__bridge CFTypeRef)[NSValue valueWithPointer:(__bridge const void *)self]);
    CFDictionarySetValue(manager, CFSTR("lifetime"), (__bridge CFTypeRef)token);
    CFDictionarySetValue(manager, CFSTR("generation"), (__bridge CFTypeRef)@(self.sessionGeneration));
    *output = manager;
    [self throwAfterCopy:@"manager" output:output];
    return 0;
}
- (void)throwAfterCopy:(NSString *)operation output:(CFTypeRef *)output {
    if (![self.throwAfterCopyOperation isEqual:operation]) return;
    if (*output) CFRelease(*output);
    __weak THPrivateAudioRuntimeFixture *owner = self;
    THFixtureReleaseToken *token = [THFixtureReleaseToken new]; token.released = ^{ owner.faultCopyReleases++; };
    CFMutableDictionaryRef fault = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(fault, CFSTR("copyLifetime"), (__bridge CFTypeRef)token);
    *output = fault; self.faultCopies++;
    @throw [NSException exceptionWithName:@"FixtureExceptionAfterCopy" reason:nil userInfo:nil];
}
- (void)setAggregate:(NSString *)aggregate receiver:(NSString *)receiver streams:(NSArray<NSString *> *)streams {
    [self setAggregate:aggregate receivers:receiver ? @[receiver] : @[] streams:streams];
}
- (void)setAggregate:(NSString *)aggregate receivers:(NSArray<NSString *> *)receivers streams:(NSArray<NSString *> *)streams {
    _aggregates[aggregate] = @{@"members":[receivers copy], @"streams":[streams copy]};
    for (NSString *uid in streams) if (!_halIDs[uid]) _halIDs[uid] = @(_halIDs.count + 1);
}
- (void)selectSystemAggregate:(NSString *)aggregate {
    self.selectedAggregate = aggregate;
    self.defaultUID = aggregate ? [_aggregates[aggregate][@"streams"] firstObject] : @"local";
}
- (void)selectSystemBluetoothUID:(NSString *)uid {
    if (![_bluetoothDeviceUIDs containsObject:uid]) [_bluetoothDeviceUIDs addObject:uid];
    if (!_halIDs[uid]) _halIDs[uid] = @(_halIDs.count + 1);
    self.selectedAggregate = nil; self.defaultUID = uid;
}
- (id)readObject:(CFTypeRef)object key:(NSString *)key {
    NSDictionary *handle = (__bridge NSDictionary *)object;
    NSString *kind = handle[@"kind"], *identifier = handle[@"identifier"];
    if (self.onRead) self.onRead(kind, key);
    if ([kind isEqual:@"context"]) {
        if ([key hasSuffix:@"_ContextType"]) return self.invalidContext ? nil : @1;
        if ([key hasSuffix:@"_ContextUUID"]) return self.invalidContext ? nil : self.contextIdentifier;
        if ([key hasSuffix:@"_AssociatedAudioDevice"]) {
            if (self.contextAssociatedAudioDeviceOverride) return self.contextAssociatedAudioDeviceOverride == NSNull.null ? nil : self.contextAssociatedAudioDeviceOverride;
            return self.selectedAggregate || [_bluetoothDeviceUIDs containsObject:self.defaultUID ?: @""] ?
                (self.invalidAssociation ? @"wrong-stream" : self.defaultUID) : nil;
        }
    }
    if ([kind isEqual:@"manager"]) {
        if ([key hasSuffix:@"_AvailableEndpoints"]) {
            NSMutableArray *endpoints = [NSMutableArray array];
            for (NSString *receiver in self.availableEndpointIdentifiers) [endpoints addObject:[self handle:@"leaf" identifier:receiver]];
            return endpoints;
        }
        if ([key hasSuffix:@"_ShowInfo"]) {
            NSMutableArray *groups = [NSMutableArray array];
            for (NSString *aggregate in _aggregates) {
                NSMutableArray *members = [NSMutableArray array];
                for (NSString *receiver in _aggregates[aggregate][@"members"]) [members addObject:@{
                    @"kAPEndpointShowInfoKey_DeviceID":receiver, @"kAPEndpointShowInfoKey_Name":receiver,
                    @"kAPEndpointShowInfoKey_Activated":@YES, @"kAPEndpointShowInfoKey_IsRemoteControlEndpoint":@NO}];
                [groups addObject:@{@"kAPEndpointShowInfoKey_EndpointID":aggregate,
                    @"kAPEndpointShowInfoKey_RoutingContextID":self.contextIdentifier,
                    @"kAPEndpointShowInfoKey_Activated":@YES, @"kAPEndpointShowInfoKey_IsRemoteControlEndpoint":@NO,
                    @"kAPEndpointShowInfoKey_SubEndpointShowInfoDicts":members}];
            }
            return @{@"kAPEndpointManagerShowInfoKey_AggregateShowInfos":groups};
        }
    }
    if ([kind isEqual:@"bluetooth"]) {
        NSString *suffix = [[key componentsSeparatedByString:@"_"] lastObject];
        id override = self.bluetoothRouteProperties[suffix];
        if (override) return override == NSNull.null ? nil : override;
        if ([key hasSuffix:@"_ID"] || [key hasSuffix:@"_Name"]) return identifier;
        if ([key hasSuffix:@"_Type"]) return @"kFigEndpointType_Bluetooth";
        if ([key hasSuffix:@"_RoutingContextUUID"]) return self.contextIdentifier;
        if ([key hasSuffix:@"_IsActivated"]) return @YES;
        if ([key hasSuffix:@"_IsRemoteControlOnly"]) return @NO;
    }
    if ([kind isEqual:@"aggregate"] || [kind isEqual:@"leaf"]) {
        if ([key hasSuffix:@"_ID"]) return identifier;
        if ([key hasSuffix:@"_Name"]) return identifier;
        if ([key hasSuffix:@"_Type"]) return [kind isEqual:@"aggregate"] ? @"kFigEndpointType_AirPlayAggregate" : @"kFigEndpointType_AirPlay";
        if ([key hasSuffix:@"_RoutingContextUUID"]) return self.contextIdentifier;
        if ([key hasSuffix:@"_IsActivated"] || [key hasSuffix:@"_IsConnected"] || [key hasSuffix:@"_IsEligibleForAudioDeviceCreation"]) return @YES;
        if ([key hasSuffix:@"_IsRemoteControlOnly"] || [key hasSuffix:@"_IsCached"] || [key hasSuffix:@"_IsLocalDevice"]) return @NO;
        if ([key hasSuffix:@"_SupportedFeatures"] || [key hasSuffix:@"_ActivatedFeatures"]) return @2;
        if ([key hasSuffix:@"_Streams"]) {
            NSMutableArray *streams = [NSMutableArray array];
            for (NSString *uid in _aggregates[identifier][@"streams"] ?: @[]) [streams addObject:[self handle:@"stream" identifier:uid]];
            return streams;
        }
    }
    if ([kind isEqual:@"stream"]) {
        if ([key hasSuffix:@"_ID"]) return identifier;
        if ([key hasSuffix:@"_Type"]) return @"kFigEndpointStreamType_Audio";
    }
    return nil;
}
- (NSArray<NSString *> *)liveUIDs {
    NSMutableArray *uids = [NSMutableArray arrayWithObject:@"local"];
    [uids addObjectsFromArray:self.bluetoothDeviceUIDs];
    for (NSDictionary *aggregate in _aggregates.allValues) [uids addObjectsFromArray:aggregate[@"streams"]];
    return uids;
}
- (NSString *)uidForDevice:(AudioObjectID)device {
    for (NSString *uid in [self liveUIDs]) if ([_halIDs[uid] unsignedIntValue] == device) return uid;
    return nil;
}
- (OSStatus)halRead:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(const void *)qualifier size:(UInt32 *)size output:(void *)output {
    self.halReads++;
    if (self.invalidHAL) return kAudioHardwareBadDeviceError;
    if (address->mSelector == kAudioHardwarePropertyDevices) {
        NSArray *uids = [self liveUIDs]; UInt32 needed = (UInt32)uids.count * sizeof(AudioObjectID);
        if (*size < needed) return kAudioHardwareBadPropertySizeError;
        for (NSUInteger i = 0; i < uids.count; i++) ((AudioObjectID *)output)[i] = [_halIDs[uids[i]] unsignedIntValue];
        *size = needed; return 0;
    }
    if (address->mSelector == kAudioHardwarePropertyDefaultOutputDevice) {
        *(UInt32 *)output = [_halIDs[self.defaultUID ?: @""] unsignedIntValue]; *size = sizeof(UInt32); return 0;
    }
    NSString *uid = [self uidForDevice:object]; if (!uid) return kAudioHardwareBadDeviceError;
    if (address->mSelector == kAudioDevicePropertyDeviceUID) { *(CFStringRef *)output = CFRetain((__bridge CFStringRef)uid); *size = sizeof(CFStringRef); }
    else if (address->mSelector == kAudioDevicePropertyStreamConfiguration) {
        AudioBufferList *buffers = output; buffers->mNumberBuffers = 1; buffers->mBuffers[0].mNumberChannels = 2; *size = sizeof(AudioBufferList);
    } else { *(UInt32 *)output = address->mSelector == kAudioDevicePropertyTransportType ?
        ([uid isEqual:@"local"] ? kAudioDeviceTransportTypeBuiltIn : [self.bluetoothDeviceUIDs containsObject:uid] ?
            kAudioDeviceTransportTypeBluetooth : kAudioDeviceTransportTypeAirPlay) : 1; *size = sizeof(UInt32); }
    return 0;
}
- (OSStatus)halSize:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(const void *)qualifier size:(UInt32 *)size {
    self.halReads++; if (self.invalidHAL) return kAudioHardwareBadDeviceError;
    *size = address->mSelector == kAudioHardwarePropertyDevices ? (UInt32)[self liveUIDs].count * sizeof(AudioObjectID) : sizeof(AudioBufferList); return 0;
}
- (OSStatus)halSettable:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address value:(Boolean *)value { *value = true; return 0; }
- (OSStatus)halWrite:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(const void *)qualifier size:(UInt32)size value:(const void *)value {
    self.halWrites++; NSString *uid = [self uidForDevice:*(AudioObjectID *)value];
    if (!uid) return kAudioHardwareBadDeviceError;
    self.defaultUID = uid;
    if (!self.suppressSystemSelectionOnHALWrite) {
        self.selectedAggregate = nil;
        for (NSString *aggregate in _aggregates) if ([_aggregates[aggregate][@"streams"] containsObject:uid]) self.selectedAggregate = aggregate;
    }
    if (self.onHALWrite) self.onHALWrite(uid);
    return 0;
}
- (SInt32)aggregate:(CFTypeRef)aggregate leaf:(CFTypeRef)leaf add:(BOOL)add callback:(THFixtureCallback)callback refcon:(void *)refcon {
    NSString *aggregateID = [(__bridge NSDictionary *)aggregate objectForKey:@"identifier"];
    NSString *receiver = [(__bridge NSDictionary *)leaf objectForKey:@"identifier"];
    SInt32 status = add ? self.addStatus : self.removeStatus;
    if (add) { self.adds++; if (!status) [self setAggregate:aggregateID receiver:receiver streams:self.omitAddStream ? @[] : @[@"stream-A"]]; }
    else { self.removes++; if (!status) [self setAggregate:aggregateID receiver:nil streams:@[]]; }
    BOOL mismatch = add ? self.mismatchAdd : self.mismatchRemove;
    id aggregateObject = (__bridge id)aggregate, leafObject = (__bridge id)leaf;
    void (^completion)(void) = ^{
        callback(mismatch ? (__bridge CFTypeRef)leafObject : (__bridge CFTypeRef)aggregateObject,
                 (__bridge CFTypeRef)leafObject, 0, 0, status, refcon);
    };
    if ((add && self.throwFromAdd) || (!add && self.throwFromRemove)) {
        if (add) self.addCompletion = completion; else self.removeCompletion = completion;
        @throw [NSException exceptionWithName:@"FixtureSubmissionException" reason:nil userInfo:nil];
    }
    if (add && self.deferAdd) self.addCompletion = completion;
    else if (!add && self.deferRemove) self.removeCompletion = completion;
    else completion();
    return status;
}
- (BOOL)addCallbackPending { return self.addCompletion != nil; }
- (BOOL)removeCallbackPending { return self.removeCompletion != nil; }
- (void)rotateSystemSession { self.sessionGeneration++; }
- (void)advanceTime:(NSTimeInterval)seconds { self.time += seconds; }
- (void)completeAdd { void (^callback)(void) = self.addCompletion; self.addCompletion = nil; if (callback) callback(); }
- (void)completeRemove { void (^callback)(void) = self.removeCompletion; self.removeCompletion = nil; if (callback) callback(); }
@end
