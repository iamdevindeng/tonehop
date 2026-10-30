#import "THRetainedSystemAudioBridge.h"
#import "THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntime.h"
#import "THPrivateAudioErrors.h"
#import "THRetainedRouteState.h"
#import <CoreAudio/CoreAudio.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdatomic.h>
#import <unistd.h>

typedef NS_ENUM(NSUInteger, THRRemovalSubmission) {
    THRRemovalSubmissionSubmitted,
    THRRemovalSubmissionAlreadyAttempted,
    THRRemovalSubmissionMethodUnavailable,
    THRRemovalSubmissionStateUnavailable,
    THRRemovalSubmissionGateRejected,
    THRRemovalSubmissionEvidenceChanged,
};
static const NSTimeInterval THRSessionRetryInterval = 3;
static const NSTimeInterval THRSessionBackoffInterval = 30;
static const NSUInteger THRSessionFailuresBeforeBackoff = 3;

static os_log_t THRLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.dengziyi.ToneHop", "RetainedRoute");
    });
    return log;
}

typedef SInt32 (*THRCopyBufferedFunction)(CFTypeRef, CFStringRef, CFTypeRef *);
typedef CFTypeID (*THRTypeID)(void);

static BOOL THRTyped(CFTypeRef object, THRTypeID type) {
    return object && type && CFGetTypeID(object) == type();
}
static BOOL THRHasType(id value, CFTypeID type) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == type;
}
static BOOL THRString(id value) { return THRHasType(value, CFStringGetTypeID()) && [value length] > 0; }
BOOL THRExistingStreamRecoverySupportedOS(NSOperatingSystemVersion version) {
    return version.majorVersion == 27;
}
BOOL THExistingStreamUIDMatchesAggregate(NSString *uid, NSString *aggregateIdentifier) {
    if (!THRString(uid) || !THRString(aggregateIdentifier)) return NO;
    NSString *prefix = [aggregateIdentifier stringByAppendingString:@"-"];
    NSString *suffix = @"-Audio";
    if (![uid hasPrefix:prefix] || ![uid hasSuffix:suffix] || uid.length <= prefix.length + suffix.length) return NO;
    NSRange generation = NSMakeRange(prefix.length, uid.length - prefix.length - suffix.length);
    if (generation.length > 20 || (generation.length > 1 && [uid characterAtIndex:generation.location] == '0')) return NO;
    uint64_t number = 0;
    for (NSUInteger i = generation.location; i < NSMaxRange(generation); i++) {
        unichar character = [uid characterAtIndex:i];
        if (character < '0' || character > '9') return NO;
        uint64_t digit = character - '0';
        if (number > (UINT64_MAX - digit) / 10) return NO;
        number = number * 10 + digit;
    }
    return YES;
}
BOOL THOwnedAirPlayStreamMatches(NSString *ownedUID, NSString *liveUID) {
    return THRString(ownedUID) && THRString(liveUID) && [ownedUID isEqualToString:liveUID];
}
static BOOL THRFlag(id value, BOOL expected) {
    // ShowInfo uses CFNumber on some builds and CFBoolean on others.
    return (THRHasType(value, CFBooleanGetTypeID()) || THRHasType(value, CFNumberGetTypeID())) &&
        [value isEqual:@(expected)];
}
static CFStringRef THRKey(THPrivateAudioRuntime *runtime, const char *name) { return [runtime key:name]; }
static NSString *THRSymbol(THPrivateAudioRuntime *runtime, const void *function) { return [runtime symbolName:function]; }
static id THRRead(THPrivateAudioRuntime *runtime, CFTypeRef object, const char *name, NSMutableDictionary *diagnostics) {
    return [runtime readProperty:object name:name diagnostics:diagnostics recordSuccess:YES];
}
static id THRField(THPrivateAudioRuntime *runtime, NSDictionary *dictionary, const char *name) {
    CFStringRef key = THRKey(runtime, name);
    return key ? dictionary[(__bridge NSString *)key] : nil;
}
static id THRHALString(THPrivateAudioRuntime *runtime, AudioObjectID object, AudioObjectPropertySelector selector) {
    return [runtime halString:object selector:selector];
}
static BOOL THRHALScalar(THPrivateAudioRuntime *runtime, AudioObjectID object, AudioObjectPropertySelector selector, UInt32 *value) {
    return [runtime halScalar:object selector:selector value:value];
}
static NSString *THRDefaultAirPlayUID(THPrivateAudioRuntime *runtime) {
    UInt32 device = 0, transport = 0, alive = 0;
    if (!THRHALScalar(runtime, kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, &device) ||
        !THRHALScalar(runtime, device, kAudioDevicePropertyTransportType, &transport) || transport != kAudioDeviceTransportTypeAirPlay ||
        !THRHALScalar(runtime, device, kAudioDevicePropertyDeviceIsAlive, &alive) || !alive) return nil;
    id uid = THRHALString(runtime, device, kAudioDevicePropertyDeviceUID);
    return THRString(uid) ? uid : nil;
}

static void THRPump(THPrivateAudioRuntime *runtime) { [runtime pumpFor:0.04 sleepMicroseconds:10000]; }
static BOOL THRWait(THPrivateAudioRuntime *runtime, THROperation *operation, NSTimeInterval seconds, BOOL (^isShuttingDown)(void)) {
    NSTimeInterval end = [runtime uptime] + seconds;
    while (!atomic_load(&operation->done) && !isShuttingDown() && [runtime uptime] < end) THRPump(runtime);
    return atomic_load(&operation->done);
}
static NSError *THRError(NSInteger code, NSString *message, NSDictionary *diagnostics) {
    return [NSError errorWithDomain:THRetainedAudioErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message, @"diagnostics":[diagnostics copy]}];
}
static const void * const *THRRouting(THPrivateAudioRuntime *runtime, CFTypeRef context) {
    if (!THRTyped(context, runtime.functions.contextType)) return NULL;
    const void * const *table = runtime.functions.getVTable(context), * const *routing = table ? table[2] : NULL;
    return routing && (uintptr_t)routing[0] == 1 &&
        [THRSymbol(runtime, routing[7]) isEqual:@"routingContextRemoteXPC_CopyRoutes"] &&
        [THRSymbol(runtime, routing[18]) isEqual:@"routingContextRemoteXPC_CopySelectedBufferedEndpoint"] ? routing : NULL;
}
static THRAggregateOperation THRAggregateMethod(THPrivateAudioRuntime *runtime, CFTypeRef aggregate, NSUInteger slot, NSMutableDictionary *diagnostics) {
    if (!THRTyped(aggregate, runtime.functions.endpointType) || (slot != 1 && slot != 2)) return NULL;
    CFStringRef type = THRKey(runtime, "kFigEndpointType_AirPlayAggregate");
    if (!type || ![THRRead(runtime, aggregate, "kFigEndpointProperty_Type", diagnostics) isEqual:(__bridge id)type]) return NULL;
    const void * const *table = runtime.functions.getVTable(aggregate), * const *methods = table ? table[4] : NULL;
    NSString *expected = slot == 1 ? @"FigEndpointRemoteXPC_EndpointAggregateAddEndpointWithCompletionCallback" :
        @"FigEndpointRemoteXPC_EndpointAggregateRemoveEndpointWithCompletionCallback";
    // A remote proxy is not a member of the service's local aggregate class.
    // This exact ordinary remote method retains its own server authorization checks.
    return methods && (uintptr_t)methods[0] == 1 && [THRSymbol(runtime, methods[slot]) isEqual:expected] ?
        (THRAggregateOperation)methods[slot] : NULL;
}
static NSArray *THRRoutes(THPrivateAudioRuntime *runtime, CFTypeRef context, NSMutableDictionary *diagnostics) {
    const void * const *routing = THRRouting(runtime, context); if (!routing) return nil;
    SInt32 (*copy)(CFTypeRef, CFTypeRef *) = (void *)routing[7]; CFTypeRef value = NULL;
    @try {
        SInt32 status = copy(context, &value); diagnostics[@"copyRoutesStatus"] = @(status);
        if (status || !value || CFGetTypeID(value) != CFArrayGetTypeID()) return nil;
        NSArray *routes = CFBridgingRelease(value); value = NULL;
        for (id item in routes) if (!THRTyped((__bridge CFTypeRef)item, runtime.functions.endpointType)) return nil;
        diagnostics[@"copyRoutesCount"] = @(routes.count); return routes;
    } @finally { if (value) CFRelease(value); }
}
static CFTypeRef THRCopyBuffered(THPrivateAudioRuntime *runtime, CFTypeRef context, NSMutableDictionary *diagnostics) {
    diagnostics[@"bufferedStatus"] = @"unavailable";
    diagnostics[@"bufferedPresent"] = NSNull.null;
    diagnostics[@"bufferedTypedEndpoint"] = @NO;
    const void * const *routing = THRRouting(runtime, context); if (!routing) return NULL;
    CFTypeRef value = NULL;
    @try {
        SInt32 status = ((THRCopyBufferedFunction)routing[18])(context, NULL, &value);
        diagnostics[@"bufferedStatus"] = @(status);
        diagnostics[@"bufferedPresent"] = @(value != NULL);
        diagnostics[@"bufferedTypedEndpoint"] = @(THRTyped(value, runtime.functions.endpointType));
        if (value && !THRTyped(value, runtime.functions.endpointType)) diagnostics[@"bufferedStatus"] = @"invalidEndpointType";
        if (status || !THRTyped(value, runtime.functions.endpointType)) return NULL;
        CFTypeRef result = value; value = NULL;
        return result;
    } @finally { if (value) CFRelease(value); }
}
static NSDictionary *THRHALDevice(THPrivateAudioRuntime *runtime, AudioObjectID device) {
    UInt32 alive = 0, transport = 0;
    id uid = THRHALString(runtime, device, kAudioDevicePropertyDeviceUID);
    if (!THRString(uid) || !THRHALScalar(runtime, device, kAudioDevicePropertyDeviceIsAlive, &alive) || !alive ||
        !THRHALScalar(runtime, device, kAudioDevicePropertyTransportType, &transport)) return nil;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if ([runtime halSize:device address:&address qualifierSize:0 qualifier:NULL size:&size] || size < sizeof(UInt32)) return nil;
    const UInt32 allocatedSize = size;
    AudioBufferList *buffers = calloc(1, size); if (!buffers) return nil;
    OSStatus status = [runtime halRead:device address:&address qualifierSize:0 qualifier:NULL size:&size output:buffers]; UInt32 channels = 0;
    if (!status && size <= allocatedSize && size >= offsetof(AudioBufferList, mBuffers) &&
        buffers->mNumberBuffers <= (size - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer))
        for (UInt32 i = 0; i < buffers->mNumberBuffers; i++) channels += buffers->mBuffers[i].mNumberChannels;
    free(buffers); if (!channels) return nil;
    return @{@"deviceID":@(device), @"uid":uid, @"transport":@(transport),
        @"airplay":@(transport == kAudioDeviceTransportTypeAirPlay)};
}
static NSDictionary *THRHALDefault(THPrivateAudioRuntime *runtime) {
    UInt32 device = 0;
    return THRHALScalar(runtime, kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, &device) ? THRHALDevice(runtime, device) : nil;
}
static NSDictionary *THRHALExact(THPrivateAudioRuntime *runtime, NSString *uid, BOOL airplay) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (!THRString(uid) || [runtime halSize:kAudioObjectSystemObject address:&address qualifierSize:0 qualifier:NULL size:&size] || size % sizeof(AudioObjectID)) return nil;
    const UInt32 allocatedSize = size;
    AudioObjectID *devices = malloc(size); if (!devices) return nil;
    OSStatus status = [runtime halRead:kAudioObjectSystemObject address:&address qualifierSize:0 qualifier:NULL size:&size output:devices];
    NSDictionary *result = nil; NSUInteger matches = 0;
    if (!status && size <= allocatedSize && size % sizeof(AudioObjectID) == 0) for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        if (![THRHALString(runtime, devices[i], kAudioDevicePropertyDeviceUID) isEqual:uid]) continue;
        matches++; NSDictionary *device = THRHALDevice(runtime, devices[i]);
        // The object can be replaced between the UID lookup and its capability
        // reads. Its new UID must never inherit the old lookup's identity.
        if ([device[@"uid"] isEqual:uid] && THRFlag(device[@"airplay"], airplay)) result = device;
    }
    free(devices); return matches == 1 ? result : nil;
}
// A system audio context can keep a Bluetooth route while no AirPlay aggregate
// is selected. Observe the whole relationship; non-AirPlay transport alone is
// not authorization, and the endpoint ID is never transformed into a HAL UID.
static NSDictionary *THRNonAirPlayOutputSample(THPrivateAudioRuntime *runtime, CFTypeRef context, NSMutableDictionary *diagnostics) {
    if (!THRRouting(runtime, context) ||
        ![THRRead(runtime, context, "kFigRoutingContextProperty_ContextType", diagnostics) isEqual:@1]) return nil;
    NSString *contextID = THRRead(runtime, context, "kFigRoutingContextProperty_ContextUUID", diagnostics);
    NSDictionary *local = THRHALDefault(runtime);
    if (!THRString(contextID) || !local || !THRFlag(local[@"airplay"], NO)) return nil;
    NSArray *routes = THRRoutes(runtime, context, diagnostics);
    CFTypeRef buffered = THRCopyBuffered(runtime, context, diagnostics);
    BOOL noBuffered = NO;
    @try {
        noBuffered = !buffered && [diagnostics[@"bufferedStatus"] isEqual:@0] &&
            [diagnostics[@"bufferedPresent"] isEqual:@NO];
    } @finally { if (buffered) CFRelease(buffered); }
    id associated = THRRead(runtime, context, "kFigRoutingContextProperty_AssociatedAudioDevice", diagnostics);
    if (!routes || !noBuffered || ![diagnostics[@"kFigRoutingContextProperty_AssociatedAudioDevice"] isEqual:@0]) return nil;
    NSDictionary *routeIdentity = nil;
    if (routes.count == 0) {
        if (associated) return nil;
    } else {
        CFStringRef bluetoothType = THRKey(runtime, "kFigEndpointType_Bluetooth");
        if (routes.count != 1 || !bluetoothType ||
            ![local[@"transport"] isEqual:@(kAudioDeviceTransportTypeBluetooth)] ||
            !THRString(associated) || ![associated isEqual:local[@"uid"]]) return nil;
        CFTypeRef route = (__bridge CFTypeRef)routes[0];
        NSString *identifier = THRRead(runtime, route, "kFigEndpointProperty_ID", diagnostics);
        id type = THRRead(runtime, route, "kFigEndpointProperty_Type", diagnostics);
        if (!THRString(identifier) || ![type isEqual:(__bridge id)bluetoothType] ||
            !THRFlag(THRRead(runtime, route, "kFigEndpointProperty_IsActivated", diagnostics), YES)) return nil;
        // Bluetooth endpoints do not expose AirPlay's context/remote-only fields.
        // The system context's complete AssociatedAudioDevice supplies the link.
        routeIdentity = @{@"identifier":identifier, @"type":type};
    }
    if (![THRHALExact(runtime, local[@"uid"], NO) isEqual:local] ||
        ![THRHALDefault(runtime) isEqual:local] ||
        ![THRRead(runtime, context, "kFigRoutingContextProperty_ContextType", diagnostics) isEqual:@1] ||
        ![THRRead(runtime, context, "kFigRoutingContextProperty_ContextUUID", diagnostics) isEqual:contextID]) return nil;
    return @{@"contextID":contextID, @"hal":local, @"route":routeIdentity ?: (id)NSNull.null,
        @"associatedUID":associated ?: (id)NSNull.null};
}
static BOOL THRContextIsUnselected(THPrivateAudioRuntime *runtime, CFTypeRef context, NSMutableDictionary *diagnostics) {
    NSDictionary *first = THRNonAirPlayOutputSample(runtime, context, diagnostics);
    return first && [first isEqual:THRNonAirPlayOutputSample(runtime, context, diagnostics)];
}
static NSDictionary *THRHALForExistingAggregate(THPrivateAudioRuntime *runtime, NSString *aggregateID) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if ([runtime halSize:kAudioObjectSystemObject address:&address qualifierSize:0 qualifier:NULL size:&size] || !size || size % sizeof(AudioObjectID)) return nil;
    UInt32 allocated = size;
    AudioObjectID *devices = malloc(size); if (!devices) return nil;
    OSStatus status = [runtime halRead:kAudioObjectSystemObject address:&address qualifierSize:0 qualifier:NULL size:&size output:devices];
    NSDictionary *only = nil; NSUInteger matches = 0;
    if (!status && size <= allocated && size % sizeof(AudioObjectID) == 0) {
        for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
            NSString *uid = THRHALString(runtime, devices[i], kAudioDevicePropertyDeviceUID);
            if (!THRString(uid)) { status = kAudioHardwareBadDeviceError; break; }
            if (!THExistingStreamUIDMatchesAggregate(uid, aggregateID)) continue;
            // Even an unusable duplicate generation makes the association ambiguous.
            matches++;
            NSDictionary *device = THRHALDevice(runtime, devices[i]);
            if ([device[@"uid"] isEqual:uid] && THRFlag(device[@"airplay"], YES)) only = device;
        }
    }
    free(devices); return !status && matches == 1 ? only : nil;
}
static BOOL THRCanBeDefaultOutput(THPrivateAudioRuntime *runtime, NSDictionary *device) {
    if (!device) return NO;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 eligible = 0, size = sizeof(eligible);
    return [runtime halRead:[device[@"deviceID"] unsignedIntValue] address:&address qualifierSize:0 qualifier:NULL
        size:&size output:&eligible] == noErr && size == sizeof(eligible) && eligible == 1;
}
static OSStatus THRSelectHALIf(THPrivateAudioRuntime *runtime, NSDictionary *device, BOOL (^willWrite)(void)) {
    if (!device) return kAudioHardwareBadDeviceError;
    AudioObjectID identifier = [device[@"deviceID"] unsignedIntValue];
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Boolean settable = false; OSStatus status = [runtime halSettable:kAudioObjectSystemObject address:&address value:&settable];
    if (status || !settable) return status ?: kAudioHardwareIllegalOperationError;
    // This runs inside the existing submission gate. Resolve again after the
    // last potentially blocking preflight, retaining the exact object, UID and
    // transport as well as its current alive/output capability. A final UID read
    // rejects identity changes during those capability reads. System changes
    // after this boundary still require the ordinary post-write verification.
    NSString *uid = device[@"uid"];
    NSDictionary *current = THRHALExact(runtime, uid, [device[@"airplay"] boolValue]);
    if (![current isEqual:device] || ![THRHALString(runtime, identifier, kAudioDevicePropertyDeviceUID) isEqual:uid])
        return kAudioHardwareBadDeviceError;
    if (willWrite && !willWrite()) return NSUserCancelledError;
    return [runtime halWrite:kAudioObjectSystemObject address:&address qualifierSize:0 qualifier:NULL size:sizeof(identifier) value:&identifier];
}
static OSStatus THRSelectHAL(THPrivateAudioRuntime *runtime, NSDictionary *device) {
    return THRSelectHALIf(runtime, device, nil);
}
// Serialize a single submission with the App's shutdown latch. Never hold this
// gate while pumping the run loop or waiting for an asynchronous callback.
static OSStatus THRSubmitHAL(THPrivateAudioRuntime *runtime, NSDictionary *device, THAudioMutationGate performIfRunning) {
    __block OSStatus status = NSUserCancelledError;
    THPerformAudioMutation(performIfRunning, ^{ status = THRSelectHAL(runtime, device); });
    return status;
}
static BOOL THRLeafIdentity(THPrivateAudioRuntime *runtime, CFTypeRef leaf, NSString *identifier, NSMutableDictionary *diagnostics) {
    CFStringRef type = THRKey(runtime, "kFigEndpointType_AirPlay");
    return THRTyped(leaf, runtime.functions.endpointType) && type &&
        [THRRead(runtime, leaf, "kFigEndpointProperty_ID", diagnostics) isEqual:identifier] &&
        [THRRead(runtime, leaf, "kFigEndpointProperty_Type", diagnostics) isEqual:(__bridge id)type] &&
        THRFlag(THRRead(runtime, leaf, "kFigEndpointProperty_IsRemoteControlOnly", diagnostics), NO);
}
static BOOL THRLeafEligible(THPrivateAudioRuntime *runtime, CFTypeRef leaf, NSString *identifier, NSMutableDictionary *diagnostics) {
    if (!THRLeafIdentity(runtime, leaf, identifier, diagnostics)) return NO;
    id features = THRRead(runtime, leaf, "kFigEndpointProperty_SupportedFeatures", diagnostics);
    if (!THRHasType(features, CFNumberGetTypeID()) || !([features unsignedLongLongValue] & 2)) return NO;
    Class cls = [runtime classNamed:@"AVOutputDevice"]; SEL selector = NSSelectorFromString(@"outputDeviceWithFigEndpoint:");
    Method factory = class_getClassMethod(cls, selector);
    if (!factory || strcmp(method_getTypeEncoding(factory), "@24@0:8^{OpaqueFigEndpoint=}16")) return NO;
    @try {
        id device = ((id (*)(id, SEL, CFTypeRef))objc_msgSend)(cls, selector, leaf);
        id deviceFeatures = [device valueForKey:@"deviceFeatures"];
        return [[device valueForKey:@"deviceID"] isEqual:identifier] && THRHasType(deviceFeatures, CFNumberGetTypeID()) &&
            ([deviceFeatures unsignedLongLongValue] & 1) && THRFlag([device valueForKey:@"isCached"], NO) &&
            THRFlag([device valueForKey:@"isDeviceDisabled"], NO) && THRFlag([device valueForKey:@"requiresAuthorization"], NO);
    } @catch (NSException *exception) { diagnostics[@"leafException"] = exception.name; return NO; }
}

// Do not collapse duplicate IDs: an audio endpoint and a remote-control-only
// endpoint may share one receiver ID. Count eligible objects after filtering.
static CFTypeRef THRCopyUniqueLeaf(THPrivateAudioRuntime *runtime, NSArray *routes, NSString *identifier, NSMutableDictionary *diagnostics,
                                  NSString *source) {
    NSUInteger matching = 0, eligible = 0;
    CFTypeRef only = NULL;
    for (id object in routes) {
        CFTypeRef endpoint = (__bridge CFTypeRef)object;
        if (!THRTyped(endpoint, runtime.functions.endpointType) ||
            ![THRRead(runtime, endpoint, "kFigEndpointProperty_ID", diagnostics) isEqual:identifier]) continue;
        matching++;
        if (THRLeafEligible(runtime, endpoint, identifier, diagnostics)) { eligible++; only = endpoint; }
    }
    diagnostics[source] = @{@"available":@(routes != nil), @"total":@(routes.count),
        @"matchingIdentifier":@(matching), @"eligible":@(eligible), @"rejected":@(routes.count - eligible)};
    return eligible == 1 ? CFRetain(only) : NULL;
}

@interface THRetainedSystemAudioBridge () {
    THPrivateAudioRuntime *_runtime;
    NSThread *_thread;
    THPrivateEndpointBridge *_endpointDiscovery;
    THRetainedRouteSession *_session;
    THOwnedRouteTransaction *_transaction;
    BOOL _busy, _closed;
    NSUInteger _sessionRecoveryFailures;
    NSTimeInterval _nextSessionRecoveryAt, _lastSessionRecoveryAt;
    NSMutableDictionary *_diagnostics;
}
@end

@implementation THRetainedSystemAudioBridge
- (instancetype)initWithEndpointDiscovery:(THPrivateEndpointBridge *)endpointDiscovery {
    return [self initWithEndpointDiscovery:endpointDiscovery runtime:THPrivateAudioRuntime.systemRuntime];
}
- (instancetype)initWithEndpointDiscovery:(THPrivateEndpointBridge *)endpointDiscovery runtime:(THPrivateAudioRuntime *)runtime {
    if ((self = [super init])) {
        _runtime = runtime;
        _session = [THRetainedRouteSession new];
        _transaction = [THOwnedRouteTransaction new];
        _lastSessionRecoveryAt = -THRSessionRetryInterval;
        _endpointDiscovery = endpointDiscovery;
        _diagnostics = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)updateDiagnostics {
    _diagnostics[@"heldPointer"] = [NSString stringWithFormat:@"%p", _session.aggregate];
    _diagnostics[@"leafPointer"] = [NSString stringWithFormat:@"%p", _session.leaf];
    _diagnostics[@"aggregateID"] = _session.aggregateID ?: @""; _diagnostics[@"contextID"] = _session.contextID ?: @"";
    _diagnostics[@"captureStreamUID"] = _session.captureStreamUID ?: @"";
    _diagnostics[@"ownStreamUID"] = _transaction.ownStreamUID ?: @"";
    for (NSString *key in @[@"add", @"remove"]) {
        THROperation *operation = [key isEqual:@"add"] ? _transaction.add : _transaction.remove;
        _diagnostics[key] = operation ? @{@"done":@(atomic_load(&operation->done)),
            @"objectsMatch":@(atomic_load(&operation->objectsMatch)), @"status":@(atomic_load(&operation->status))} : (id)NSNull.null;
    }
}
- (void)event:(NSString *)event status:(NSInteger)status {
    [self updateDiagnostics];
    NSDictionary *entry = @{@"event":event, @"status":@(status), @"identifier":_session.identifier ?: @"", @"owned":@(_transaction.owned),
        @"heldPointer":_diagnostics[@"heldPointer"], @"leafPointer":_diagnostics[@"leafPointer"],
        @"aggregateID":_diagnostics[@"aggregateID"], @"contextID":_diagnostics[@"contextID"],
        @"ownStreamUID":_diagnostics[@"ownStreamUID"], @"add":_diagnostics[@"add"], @"remove":_diagnostics[@"remove"],
        @"captureStreamUID":_diagnostics[@"captureStreamUID"],
        @"selectionMode":_diagnostics[@"selectionMode"] ?: @"none",
        @"captureSource":_diagnostics[@"captureSource"] ?: @"none",
        @"captureCopyRoutesCandidates":_diagnostics[@"captureCopyRoutesCandidates"] ?: (id)NSNull.null,
        @"captureDiscoveryCandidates":_diagnostics[@"captureDiscoveryCandidates"] ?: (id)NSNull.null};
    _diagnostics[@"lastOperation"] = entry;
    // Full identities and pointers stay in the explicitly requested diagnostic snapshot.
    // Event names are fixed internal labels, never receiver-provided text.
    os_log_with_type(THRLog(), status == 0 ? OS_LOG_TYPE_INFO : OS_LOG_TYPE_ERROR,
        "event=%{public}@ status=%{public}ld owned=%{public}d", event, (long)status, _transaction.owned);
}
- (BOOL)enter:(NSError **)error {
    if (!_thread) _thread = NSThread.currentThread;
    if (_thread != NSThread.currentThread || NSThread.isMainThread || _busy) {
        if (error) *error = THRError(THRetainedAudioErrorExecutor, NSLocalizedStringWithDefaultValue(@"native.retained.executor_required", nil, NSBundle.mainBundle, @"AirPlay routing operations must run in order on their dedicated thread.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
    }
    _busy = YES; return YES;
}
- (BOOL)ensure:(NSError **)error {
    return [self ensure:error isShuttingDown:^{ return NO; }];
}
- (BOOL)ensure:(NSError **)error isShuttingDown:(BOOL (^)(void))isShuttingDown {
    if ([self isStopping:isShuttingDown]) {
        if (error) *error = THRError(NSUserCancelledError, NSLocalizedStringWithDefaultValue(@"native.retained.session_ended", nil, NSBundle.mainBundle, @"The app's audio session has ended.", @"AirPlay status or error shown to the user."), _diagnostics);
        return NO;
    }
    if (!_runtime.functions.copyContext || !_runtime.functions.copyManager || !_runtime.functions.getVTable || !_runtime.functions.contextType || !_runtime.functions.endpointType || !_runtime.functions.streamType || !_runtime.functions.managerType) {
        if (error) *error = THRError(THRetainedAudioErrorRuntimeUnavailable, NSLocalizedStringWithDefaultValue(@"native.retained.interface_unavailable", nil, NSBundle.mainBundle, @"AirPlay routing is unavailable on this system.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
    }
    if (!_session.context) {
        CFTypeRef context = NULL;
        @try {
            SInt32 status = [_runtime copyContext:kCFAllocatorDefault options:NULL output:&context];
            if ([self isStopping:isShuttingDown]) return NO;
            if (status || !THRRouting(_runtime, context)) {
                if (error) *error = THRError(status ?: 3, NSLocalizedStringWithDefaultValue(@"native.retained.route_read_failed", nil, NSBundle.mainBundle, @"Unable to read the system audio route.", @"AirPlay status or error shown to the user."), _diagnostics); return NO; }
            [_session adoptContext:context]; context = NULL;
        } @finally { if (context) CFRelease(context); }
    }
    if ([self isStopping:isShuttingDown]) return NO;
    if (!_session.manager) {
        CFTypeRef manager = NULL;
        @try {
            SInt32 status = [_runtime copyManager:&manager];
            if ([self isStopping:isShuttingDown]) return NO;
            if (status || !THRTyped(manager, _runtime.functions.managerType)) {
                if (error) *error = THRError(status ?: 4, NSLocalizedStringWithDefaultValue(@"native.retained.aggregate_read_failed", nil, NSBundle.mainBundle, @"Unable to read the system AirPlay aggregate.", @"AirPlay status or error shown to the user."), _diagnostics); return NO; }
            [_session adoptManager:manager]; manager = NULL;
        } @finally { if (manager) CFRelease(manager); }
    }
    return YES;
}
// Session recovery is independent of connection ownership. An empty selected
// endpoint is healthy; only failed/invalid typed reads can request new references.
- (NSDictionary *)uncapturedEvidenceForSession:(THRetainedRouteSession *)session diagnostics:(NSMutableDictionary *)diagnostics isShuttingDown:(BOOL (^)(void))isShuttingDown {
    if ([self isStopping:isShuttingDown]) return nil;
    if (!THRRouting(_runtime, session.context) || !THRTyped(session.manager, _runtime.functions.managerType)) {
        diagnostics[@"reason"] = @"unsupportedSessionABI"; return nil;
    }
    id type = THRRead(_runtime, session.context, "kFigRoutingContextProperty_ContextType", diagnostics);
    if ([self isStopping:isShuttingDown]) return nil;
    id contextID = THRRead(_runtime, session.context, "kFigRoutingContextProperty_ContextUUID", diagnostics);
    if ([self isStopping:isShuttingDown]) return nil;
    if (!THRHasType(type, CFNumberGetTypeID()) || ![type isEqual:@1] || !THRString(contextID)) {
        diagnostics[@"reason"] = @"contextUnreadable"; return nil;
    }
    id show = THRRead(_runtime, session.manager, "kAPEndpointManagerProperty_ShowInfo", diagnostics);
    if ([self isStopping:isShuttingDown]) return nil;
    if (!THRHasType(show, CFDictionaryGetTypeID())) {
        diagnostics[@"reason"] = @"managerUnreadable"; return nil;
    }
    CFTypeRef buffered = THRCopyBuffered(_runtime, session.context, diagnostics);
    @try {
        if ([self isStopping:isShuttingDown]) return nil;
        if (![diagnostics[@"bufferedStatus"] isEqual:@0]) {
            diagnostics[@"reason"] = @"selectedEndpointUnreadable"; return nil;
        }
        id selectedID = NSNull.null;
        if (buffered) {
            selectedID = THRRead(_runtime, buffered, "kFigEndpointProperty_ID", diagnostics);
            if ([self isStopping:isShuttingDown]) return nil;
            id selectedContext = THRRead(_runtime, buffered, "kFigEndpointProperty_RoutingContextUUID", diagnostics);
            if ([self isStopping:isShuttingDown]) return nil;
            if (!THRString(selectedID) || ![selectedContext isEqual:contextID]) {
                diagnostics[@"reason"] = @"selectedEndpointIdentityInvalid"; return nil;
            }
        }
        return @{@"contextID":contextID, @"managerShowInfo":show, @"selectedAggregateID":selectedID};
    } @finally { if (buffered) CFRelease(buffered); }
}
- (BOOL)isStopping:(BOOL (^)(void))isShuttingDown { return _closed || isShuttingDown(); }
- (NSDictionary *)stoppedSnapshot {
    _diagnostics[@"state"] = @"stopped";
    return @{@"retained":NSNull.null, @"existingStreamAssociation":NSNull.null, @"existingStreamRecovery":NSNull.null,
        @"sessionReadSucceeded":@NO, @"diagnostics":[_diagnostics copy]};
}
- (BOOL)recoverUncapturedSessionIsShuttingDown:(BOOL (^)(void))isShuttingDown {
    // Any retained capture or transaction continues under its existing rules.
    // Never reset a capsule to make an unavailable route appear recoverable.
    if (_session.aggregate || _transaction.owned || _transaction.add || _transaction.remove || _transaction.mustClean) return YES;
    if ([self isStopping:isShuttingDown]) return NO;
    NSMutableDictionary *observation = [NSMutableDictionary dictionary];
    NSDictionary *current = nil;
    @try { current = [self uncapturedEvidenceForSession:_session diagnostics:observation isShuttingDown:isShuttingDown]; }
    @catch (NSException *exception) { observation[@"exception"] = exception.name; }
    if ([self isStopping:isShuttingDown]) return NO;
    if (current) {
        _sessionRecoveryFailures = 0;
        _nextSessionRecoveryAt = _lastSessionRecoveryAt + THRSessionRetryInterval;
        _diagnostics[@"sessionRecoveryState"] = @"healthy";
        _diagnostics[@"sessionRecoveryFailures"] = @0;
        return YES;
    }
    _diagnostics[@"sessionRecoveryObservation"] = observation;
    if ([self isStopping:isShuttingDown]) return NO;
    NSTimeInterval now = [_runtime uptime];
    if (now < _nextSessionRecoveryAt) {
        _diagnostics[@"sessionRecoveryState"] = @"backoff";
        return NO;
    }
    // The same budget applies to timer refreshes and external event bursts.
    _lastSessionRecoveryAt = now;
    _nextSessionRecoveryAt = now + THRSessionRetryInterval;
    _diagnostics[@"sessionRecoveryState"] = @"readingCandidate";
    THRetainedRouteSession *candidate = [THRetainedRouteSession new];
    CFTypeRef context = NULL, manager = NULL;
    NSMutableDictionary *candidateRead = [NSMutableDictionary dictionary];
    BOOL replaced = NO;
    @try {
        SInt32 status = [_runtime copyContext:kCFAllocatorDefault options:NULL output:&context];
        candidateRead[@"contextStatus"] = @(status);
        if ([self isStopping:isShuttingDown]) return NO;
        if (status || !THRRouting(_runtime, context)) return NO;
        [candidate adoptContext:context]; context = NULL;
        status = [_runtime copyManager:&manager]; candidateRead[@"managerStatus"] = @(status);
        if ([self isStopping:isShuttingDown]) return NO;
        if (status || !THRTyped(manager, _runtime.functions.managerType)) return NO;
        [candidate adoptManager:manager]; manager = NULL;
        NSDictionary *first = [self uncapturedEvidenceForSession:candidate diagnostics:candidateRead isShuttingDown:isShuttingDown];
        if ([self isStopping:isShuttingDown] || !first) return NO;
        NSDictionary *second = [self uncapturedEvidenceForSession:candidate diagnostics:candidateRead isShuttingDown:isShuttingDown];
        if ([self isStopping:isShuttingDown] || ![first isEqual:second]) {
            candidateRead[@"reason"] = @"candidateChangedDuringRead"; return NO;
        }
        // Commit the complete pair only. No discovery operation or routing write
        // occurs here; strict capture below remains the only capability source.
        [_session copyReferencesFrom:candidate]; _session.invalidated = NO;
        _sessionRecoveryFailures = 0;
        _nextSessionRecoveryAt = _lastSessionRecoveryAt + THRSessionRetryInterval; replaced = YES;
        _diagnostics[@"sessionRecoveryState"] = @"recovered";
        return YES;
    } @catch (NSException *exception) {
        candidateRead[@"exception"] = exception.name;
        return NO;
    } @finally {
        if (context) CFRelease(context); if (manager) CFRelease(manager);
        // Release failed candidate refs immediately; on success the installed
        // session holds its own copies. The endpoint discovery is never replaced.
        [candidate releaseAll];
        _diagnostics[@"sessionRecoveryCandidate"] = candidateRead;
        if (!replaced && ![self isStopping:isShuttingDown]) {
            _sessionRecoveryFailures++;
            _nextSessionRecoveryAt = [_runtime uptime] +
                (_sessionRecoveryFailures >= THRSessionFailuresBeforeBackoff ? THRSessionBackoffInterval : THRSessionRetryInterval);
            _diagnostics[@"sessionRecoveryState"] = @"candidateRejected";
        }
        _diagnostics[@"sessionRecoveryFailures"] = @(_sessionRecoveryFailures);
    }
}
- (BOOL)contextValid {
    return THRRouting(_runtime, _session.context) && [THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextType", _diagnostics) isEqual:@1] &&
        [_session.contextID isEqual:THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextUUID", _diagnostics)];
}
- (NSDictionary *)view:(CFTypeRef)aggregate identifier:(NSString *)aggregateID context:(NSString *)contextID {
    const char *keys[] = {"kAPEndpointManagerShowInfoKey_AggregateShowInfos", "kAPEndpointShowInfoKey_EndpointID",
        "kAPEndpointShowInfoKey_RoutingContextID", "kAPEndpointShowInfoKey_Activated", "kAPEndpointShowInfoKey_IsRemoteControlEndpoint",
        "kAPEndpointShowInfoKey_SubEndpointShowInfoDicts", "kAPEndpointShowInfoKey_DeviceID"};
    for (NSUInteger i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) if (!THRKey(_runtime, keys[i])) return nil;
    CFStringRef type = THRKey(_runtime, "kFigEndpointType_AirPlayAggregate");
    if (!type || !THRTyped(aggregate, _runtime.functions.endpointType) || !THRString(aggregateID) || !THRString(contextID) ||
        ![THRRead(_runtime, aggregate, "kFigEndpointProperty_ID", _diagnostics) isEqual:aggregateID] ||
        ![THRRead(_runtime, aggregate, "kFigEndpointProperty_Type", _diagnostics) isEqual:(__bridge id)type] ||
        ![THRRead(_runtime, aggregate, "kFigEndpointProperty_RoutingContextUUID", _diagnostics) isEqual:contextID] ||
        !THRFlag(THRRead(_runtime, aggregate, "kFigEndpointProperty_IsActivated", _diagnostics), YES) ||
        !THRFlag(THRRead(_runtime, aggregate, "kFigEndpointProperty_IsRemoteControlOnly", _diagnostics), NO)) return nil;
    id show = THRRead(_runtime, _session.manager, "kAPEndpointManagerProperty_ShowInfo", _diagnostics);
    if (!THRHasType(show, CFDictionaryGetTypeID())) return nil;
    id groups = THRField(_runtime, show, "kAPEndpointManagerShowInfoKey_AggregateShowInfos");
    if (!THRHasType(groups, CFArrayGetTypeID())) return nil;
    NSDictionary *match = nil; NSUInteger count = 0;
    for (id group in groups) {
        if (!THRHasType(group, CFDictionaryGetTypeID())) return nil;
        if ([THRField(_runtime, group, "kAPEndpointShowInfoKey_EndpointID") isEqual:aggregateID]) { count++; match = group; }
    }
    if (count != 1 || ![THRField(_runtime, match, "kAPEndpointShowInfoKey_RoutingContextID") isEqual:contextID] ||
        !THRFlag(THRField(_runtime, match, "kAPEndpointShowInfoKey_Activated"), YES) ||
        !THRFlag(THRField(_runtime, match, "kAPEndpointShowInfoKey_IsRemoteControlEndpoint"), NO)) return nil;
    id members = THRField(_runtime, match, "kAPEndpointShowInfoKey_SubEndpointShowInfoDicts");
    if (members && !THRHasType(members, CFArrayGetTypeID())) return nil;
    NSMutableArray *identifiers = [NSMutableArray array]; BOOL allMembersActivated = YES;
    for (id member in members) {
        if (!THRHasType(member, CFDictionaryGetTypeID()) || !THRFlag(THRField(_runtime, member, "kAPEndpointShowInfoKey_IsRemoteControlEndpoint"), NO)) return nil;
        id identifier = THRField(_runtime, member, "kAPEndpointShowInfoKey_DeviceID"); if (!THRString(identifier)) return nil;
        [identifiers addObject:identifier];
        allMembersActivated = allMembersActivated && THRFlag(THRField(_runtime, member, "kAPEndpointShowInfoKey_Activated"), YES);
    }
    id streams = THRRead(_runtime, aggregate, "kFigEndpointProperty_Streams", _diagnostics);
    if (!THRHasType(streams, CFArrayGetTypeID())) return nil;
    NSMutableArray *audio = [NSMutableArray array]; CFStringRef audioType = THRKey(_runtime, "kFigEndpointStreamType_Audio"); if (!audioType) return nil;
    for (id object in streams) {
        CFTypeRef stream = (__bridge CFTypeRef)object; if (!THRTyped(stream, _runtime.functions.streamType)) return nil;
        id streamType = THRRead(_runtime, stream, "kFigEndpointStreamProperty_Type", _diagnostics); if (!THRString(streamType)) return nil;
        if ([streamType isEqual:(__bridge id)audioType]) {
            id uid = THRRead(_runtime, stream, "kFigEndpointStreamProperty_ID", _diagnostics); if (!THRString(uid)) return nil; [audio addObject:uid];
        }
    }
    return @{@"members":identifiers, @"audioUIDs":audio, @"streamCount":@([streams count]), @"memberKeyAbsent":@(members == nil), @"allMembersActivated":@(allMembersActivated)};
}
- (NSDictionary *)heldView {
    if (!_session.aggregate || ![self contextValid]) return nil;
    NSDictionary *view = [self view:_session.aggregate identifier:_session.aggregateID context:_session.contextID];
    NSArray *members = view[@"members"];
    if (view && members.count && !(members.count == 1 && [members[0] isEqual:_session.identifier])) {
        _session.invalidated = YES; _diagnostics[@"reason"] = @"aggregateMemberChanged"; return nil;
    }
    return view;
}
- (BOOL)empty:(NSDictionary *)view {
    return view && [view[@"members"] count] == 0 && [view[@"streamCount"] isEqual:@0];
}
- (BOOL)soleMember:(NSDictionary *)view {
    return view && _session.identifier && [view[@"members"] isEqual:@[_session.identifier]];
}
- (NSString *)stream:(NSDictionary *)view {
    NSArray *audio = view[@"audioUIDs"]; return [self soleMember:view] && audio.count == 1 && [view[@"streamCount"] isEqual:@1] ? audio[0] : nil;
}
- (BOOL)localUnselected {
    return [self contextValid] && THRContextIsUnselected(_runtime, _session.context, _diagnostics) && [self contextValid];
}
- (BOOL)selected:(NSDictionary *)view {
    NSString *uid = [self stream:view];
    if (!uid || !THRFlag(view[@"allMembersActivated"], YES) || ![self contextValid]) return NO;
    CFTypeRef buffered = THRCopyBuffered(_runtime, _session.context, _diagnostics); if (!buffered) return NO;
    NSDictionary *selectedView = nil;
    @try { selectedView = [self view:buffered identifier:_session.aggregateID context:_session.contextID]; }
    @finally { CFRelease(buffered); }
    return THRFlag(selectedView[@"allMembersActivated"], YES) && [[self stream:selectedView] isEqual:uid] &&
        [THRRead(_runtime, _session.context, "kFigRoutingContextProperty_AssociatedAudioDevice", _diagnostics) isEqual:uid] &&
        [THRDefaultAirPlayUID(_runtime) isEqual:uid] && THRHALExact(_runtime, uid, YES);
}
- (BOOL)captureSelectionMatchesView:(NSDictionary *)expected aggregateID:(NSString *)aggregateID contextID:(NSString *)contextID {
    NSArray *members = expected[@"members"], *audio = expected[@"audioUIDs"];
    if (members.count != 1 || audio.count != 1 || ![expected[@"streamCount"] isEqual:@1] ||
        !THRFlag(expected[@"allMembersActivated"], YES) ||
        ![THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextType", _diagnostics) isEqual:@1] ||
        ![THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextUUID", _diagnostics) isEqual:contextID]) return NO;
    CFTypeRef selected = THRCopyBuffered(_runtime, _session.context, _diagnostics);
    if (!selected) return NO;
    NSDictionary *current = nil;
    @try { current = [self view:selected identifier:aggregateID context:contextID]; }
    @finally { CFRelease(selected); }
    return [current[@"members"] isEqual:members] && [current[@"audioUIDs"] isEqual:audio] &&
        [current[@"streamCount"] isEqual:@1] && THRFlag(current[@"allMembersActivated"], YES) &&
        [THRRead(_runtime, _session.context, "kFigRoutingContextProperty_AssociatedAudioDevice", _diagnostics) isEqual:audio[0]] &&
        [THRDefaultAirPlayUID(_runtime) isEqual:audio[0]] && THRHALExact(_runtime, audio[0], YES);
}
// Current stream identity is independent of the original capture's reuse and
// ownership permissions. A replacement generation may identify a catalog row,
// but cannot inherit permission to select or remove the captured stream.
- (NSDictionary *)heldStreamDevice:(NSDictionary *)view {
    NSString *uid = [self stream:view];
    if (_session.invalidated || !uid || !THRFlag(view[@"allMembersActivated"], YES) || ![self contextValid]) return nil;
    return THRHALExact(_runtime, uid, YES);
}
- (NSDictionary *)verifiedHeldStreamDevice:(NSDictionary *)view {
    NSDictionary *first = [self heldStreamDevice:view];
    if (!first) return nil;
    NSDictionary *latestView = [self heldView];
    NSDictionary *latest = [self heldStreamDevice:latestView];
    return !_session.invalidated && [view isEqual:latestView] && [first isEqual:latest] ? latest : nil;
}
// A borrowed member may survive a local switch. Only resume the exact stream
// jointly verified at capture; a new stream with the same receiver ID is not enough.
- (NSDictionary *)capturedStreamDevice:(NSDictionary *)view {
    if (_transaction.owned || _transaction.add || _transaction.remove || _transaction.mustClean || _session.invalidated || !THRString(_session.captureStreamUID) ||
        ![self contextValid] || !THRFlag(view[@"allMembersActivated"], YES) ||
        ![[self stream:view] isEqual:_session.captureStreamUID] || !THRLeafEligible(_runtime, _session.leaf, _session.identifier, _diagnostics)) return nil;
    return THRHALExact(_runtime, _session.captureStreamUID, YES);
}
- (BOOL)confirmSelectedStream:(NSString *)uid isCancelled:(BOOL (^)(void))isCancelled {
    NSUInteger consecutive = 0;
    NSTimeInterval end = [_runtime uptime] + 8;
    do {
        if (isCancelled()) break;
        NSDictionary *view = [self heldView];
        BOOL matches = !_session.invalidated && [[self stream:view] isEqual:uid] && [self selected:view];
        consecutive = matches ? consecutive + 1 : 0;
        if (consecutive >= 3) return YES;
        THRPump(_runtime); [_runtime pumpFor:0 sleepMicroseconds:150000];
    } while ([_runtime uptime] < end);
    return NO;
}
- (void)capture {
    if (_transaction.owned || _transaction.add || _transaction.remove) return;
    if (_session.aggregate) {
        NSDictionary *current = [self heldView];
        if (current && !_session.invalidated) {
            CFTypeRef buffered = THRCopyBuffered(_runtime, _session.context, _diagnostics);
            if (!buffered) return; // Local or a transient read never discards a valid held route.
            BOOL same = NO;
            NSString *liveStreamUID = nil;
            @try {
                same = [THRRead(_runtime, buffered, "kFigEndpointProperty_ID", _diagnostics) isEqual:_session.aggregateID];
                if (same) liveStreamUID = [self stream:[self view:buffered identifier:_session.aggregateID context:_session.contextID]];
            } @finally { CFRelease(buffered); }
            // The system can reconnect the same aggregate with a new stream
            // generation. Its aggregate ID alone cannot keep the old capture
            // current. A changed UID merely triggers candidate validation below;
            // only its complete selected-route readbacks may replace our refs.
            if (same && (!THRString(liveStreamUID) || [liveStreamUID isEqual:_session.captureStreamUID])) return;
        }
        // Only a newly, fully verified system selection may replace old references.
        // Fresh ordinary getters also recover after the helper/service has restarted.
        THRetainedSystemAudioBridge *candidate = [[THRetainedSystemAudioBridge alloc] initWithEndpointDiscovery:_endpointDiscovery runtime:_runtime];
        if (![candidate ensure:NULL]) return;
        [candidate capture]; if (!candidate->_session.aggregate) return;
        [self releaseHeld];
        [_session copyReferencesFrom:candidate->_session];
        for (NSString *key in @[@"captureSource", @"captureCopyRoutesCandidates", @"captureDiscoveryCandidates", @"captureState"])
            if (candidate->_diagnostics[key]) _diagnostics[key] = candidate->_diagnostics[key];
        _session.invalidated = NO; [self event:@"recapturedSystemRoute" status:0]; return;
    }
    _diagnostics[@"captureState"] = @"waitingForSelectedSystemRoute";
    _diagnostics[@"captureSource"] = @"none";
    _diagnostics[@"captureCopyRoutesCandidates"] = NSNull.null;
    _diagnostics[@"captureDiscoveryCandidates"] = NSNull.null;
    _diagnostics[@"captureDiscoveryError"] = NSNull.null;
    if (![THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextType", _diagnostics) isEqual:@1]) return;
    NSString *contextID = THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextUUID", _diagnostics); if (!THRString(contextID)) return;
    CFTypeRef aggregate = THRCopyBuffered(_runtime, _session.context, _diagnostics); if (!aggregate) return;
    CFTypeRef leaf = NULL;
    @try {
        NSString *aggregateID = THRRead(_runtime, aggregate, "kFigEndpointProperty_ID", _diagnostics);
        NSDictionary *view = [self view:aggregate identifier:aggregateID context:contextID];
        if (![self captureSelectionMatchesView:view aggregateID:aggregateID contextID:contextID] ||
            !THRAggregateMethod(_runtime, aggregate, 1, _diagnostics) || !THRAggregateMethod(_runtime, aggregate, 2, _diagnostics)) return;
        NSString *identifier = view[@"members"][0];
        _diagnostics[@"captureState"] = @"waitingForUniqueEligibleReceiver";
        NSString *source = @"copyRoutes";
        leaf = THRCopyUniqueLeaf(_runtime, THRRoutes(_runtime, _session.context, _diagnostics), identifier, _diagnostics, @"captureCopyRoutesCandidates");
        if (!leaf) {
            source = @"availableEndpoints";
            NSError *discoveryError = nil;
            NSArray *available = [_endpointDiscovery availableEndpointReferencesWithError:&discoveryError];
            _diagnostics[@"captureDiscoveryError"] = discoveryError.localizedDescription ?: (id)NSNull.null;
            leaf = THRCopyUniqueLeaf(_runtime, available, identifier, _diagnostics, @"captureDiscoveryCandidates");
        }
        // A not-yet-populated discovery list is retried by the next worker read.
        // No discovery mode or route selection is changed by a capture attempt.
        if (!leaf) return;
        NSString *name = THRRead(_runtime, leaf, "kFigEndpointProperty_Name", _diagnostics); if (!THRString(name)) return;
        _diagnostics[@"captureState"] = @"verifyingSelectionUnchanged";
        if (!THRLeafEligible(_runtime, leaf, identifier, _diagnostics) ||
            ![[self view:aggregate identifier:aggregateID context:contextID] isEqual:view] ||
            ![self captureSelectionMatchesView:view aggregateID:aggregateID contextID:contextID]) return;
        [_session adoptAggregate:aggregate leaf:leaf]; aggregate = NULL; leaf = NULL;
        _session.aggregateID = [aggregateID copy]; _session.contextID = [contextID copy]; _session.identifier = [identifier copy]; _session.name = [name copy];
        if (![self selected:[self heldView]]) { [self releaseHeld]; return; }
        _session.captureStreamUID = [view[@"audioUIDs"][0] copy];
        _diagnostics[@"captureSource"] = source; _diagnostics[@"captureState"] = @"captured";
        _session.invalidated = NO; [self event:@"capturedSystemRoute" status:0];
    } @finally { if (leaf) CFRelease(leaf); if (aggregate) CFRelease(aggregate); }
}
- (void)releaseHeld {
    [_session releaseCapture];
    // Preserve the old combined action explicitly: releasing capture also drops
    // transaction UID hints, but never releases an in-flight callback capsule.
    [_transaction forgetRouteIdentity];
}
- (void)clearOwnership {
    [_transaction clear];
    _diagnostics[@"runtimeCleanupState"] = @"idle";
}
// Retirement releases only obsolete local bookkeeping. Unlike Remove, it
// never acts on a receiver or assumes that a replacement stream belongs to us.
- (NSDictionary *)supersededOwnershipSample {
    if (![self contextValid]) return nil;
    // heldView deliberately rejects changed members. Read the same strictly
    // validated aggregate directly to prove that our generation has gone.
    NSDictionary *view = [self view:_session.aggregate identifier:_session.aggregateID context:_session.contextID];
    if (!view) return nil;
    NSArray *members = view[@"members"], *audio = view[@"audioUIDs"];
    if (THRString(_transaction.ownStreamUID) && [audio containsObject:_transaction.ownStreamUID]) return nil;
    BOOL replacement = THRString(_transaction.ownStreamUID) && members.count == 1 && audio.count == 1 &&
        [view[@"streamCount"] isEqual:@1] && THRString(audio[0]) &&
        THRFlag(view[@"allMembersActivated"], YES);
    // A member temporarily lacking audio is not a replacement. Ordinary empty
    // aggregates with local output keep the captured-route reuse path below.
    BOOL empty = [self empty:view];
    if (!replacement && !empty) return nil;
    if ([self localUnselected]) {
        if (empty && !_session.invalidated) return nil;
        return @{@"view":view, @"output":@"local"};
    }

    // The system may already have selected the replacement, possibly on a new
    // aggregate. Require the same complete readback used for fresh capture;
    // a failed selected getter is not evidence that our output was left.
    CFTypeRef buffered = THRCopyBuffered(_runtime, _session.context, _diagnostics);
    if (!buffered) return nil;
    @try {
        NSString *selectedID = THRRead(_runtime, buffered, "kFigEndpointProperty_ID", _diagnostics);
        NSDictionary *selectedView = [self view:buffered identifier:selectedID context:_session.contextID];
        if (![self captureSelectionMatchesView:selectedView aggregateID:selectedID contextID:_session.contextID]) return nil;
        NSString *selectedUID = selectedView[@"audioUIDs"][0];
        if (THOwnedAirPlayStreamMatches(_transaction.ownStreamUID, selectedUID)) return nil;
        return @{@"view":view, @"output":@"systemRoute", @"selectedID":selectedID, @"selectedView":selectedView};
    } @finally { CFRelease(buffered); }
}
- (BOOL)retireSupersededOwnership {
    // A late or mismatched callback must not recreate an old transaction after
    // we release it. Its capsule retains its own references until it completes.
    if (!_transaction.owned || !_transaction.add || !atomic_load(&_transaction.add->done) || !atomic_load(&_transaction.add->objectsMatch) ||
        (_transaction.remove && (!atomic_load(&_transaction.remove->done) || !atomic_load(&_transaction.remove->objectsMatch)))) return NO;
    NSDictionary *first = [self supersededOwnershipSample];
    if (!first || ![[self supersededOwnershipSample] isEqual:first]) return NO;
    [self event:@"retiredSupersededOwnership" status:0];
    [self clearOwnership];
    [self releaseHeld];
    _session.invalidated = NO;
    return YES;
}
- (void)settleCompletedOperation {
    if ([self retireSupersededOwnership]) return;
    if (!_transaction.owned || !_transaction.add || !atomic_load(&_transaction.add->done) || !atomic_load(&_transaction.add->objectsMatch) ||
        (_transaction.remove && (!atomic_load(&_transaction.remove->done) || !atomic_load(&_transaction.remove->objectsMatch)))) return;
    NSDictionary *first = [self heldView];
    if (_session.invalidated || ![self empty:first] || ![self localUnselected]) return;
    NSDictionary *second = [self heldView];
    if (_session.invalidated || ![first isEqual:second] || ![self empty:second] || ![self localUnselected]) return;
    [self clearOwnership];
    [self event:@"observedSystemMemberRemoval" status:0];
}
- (BOOL)deferCleanup:(NSError **)error reason:(NSString *)reason pending:(BOOL)pending {
    _diagnostics[@"reason"] = reason;
    _diagnostics[@"runtimeCleanupState"] = pending ? @"pending" : @"blocked";
    if (error) *error = THRError(pending ? THRetainedAudioErrorPending : THRetainedAudioErrorCleanupBlocked, pending ?
        NSLocalizedStringWithDefaultValue(@"native.retained.cleanup_readback_pending", nil, NSBundle.mainBundle, @"Waiting for the system to finish connection cleanup or confirm the output state.", @"AirPlay status or error shown to the user.") : NSLocalizedStringWithDefaultValue(@"native.retained.cleanup_reference_held", nil, NSBundle.mainBundle, @"Safe cleanup of this connection could not be confirmed. The original reference has been kept.", @"AirPlay status or error shown to the user."), _diagnostics);
    return NO;
}
- (BOOL)waitForSubmittedRemoval:(NSError **)error isShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(THAudioMutationGate)performIfRunning {
    // An app HAL notification may have submitted this Remove before its own
    // completedLeave arrives. Join that exact operation; never submit again.
    BOOL done = THRWait(_runtime, _transaction.remove, 15, isShuttingDown);
    if (isShuttingDown()) return YES;
    if (!done) return [self deferCleanup:error reason:@"callbackPending" pending:YES];
    [self settleCompletedOperation];
    if (!_transaction.owned) return YES;
    if (!atomic_load(&_transaction.remove->objectsMatch) || atomic_load(&_transaction.remove->status) != 0)
        return [self deferCleanup:error reason:@"removeFailed" pending:NO];
    NSTimeInterval end = [_runtime uptime] + 3;
    do {
        if (isShuttingDown()) return YES;
        if ([self localUnselected] && [self empty:[self heldView]]) {
            return [self reconcile:error isShuttingDown:isShuttingDown performIfRunning:performIfRunning waitForCompletion:NO];
        }
        THRPump(_runtime);
    } while ([_runtime uptime] < end);
    return [self deferCleanup:error reason:@"removeNotConfirmed" pending:NO];
}
// Ordinary leave and confirmed quit share the same submission path, capsule
// lifetime, final gate, exception semantics, and no-resubmission rule.
- (THRRemovalSubmission)submitOwnedRemovalPerformIfPermitted:(THAudioMutationGate)gate confirmEvidence:(BOOL (^)(void))confirmEvidence event:(NSString *)event status:(SInt32 *)resultStatus {
    *resultStatus = NSUserCancelledError;
    if (_transaction.removeAttempted || _transaction.remove) return THRRemovalSubmissionAlreadyAttempted;
    THRAggregateOperation remove = THRAggregateMethod(_runtime, _session.aggregate, 2, _diagnostics);
    if (!remove) return THRRemovalSubmissionMethodUnavailable;
    _transaction.remove = THRNewOperation(_session.aggregate, _session.leaf, _session.context, _session.manager);
    if (!_transaction.remove) return THRRemovalSubmissionStateUnavailable;
    __block SInt32 status = NSUserCancelledError;
    __block BOOL submitted = NO;
    BOOL permitted = NO;
    @try { permitted = THPerformAudioMutation(gate, ^{
        if (!confirmEvidence()) return;
        // Once entered, an exception cannot prove the remote operation did not
        // happen. Keep its callback capsule and forbid a second submission.
        self->_transaction.removePhase = THRetainedRemovePhaseSubmitted;
        self->_transaction.removeSubmittedAt = [self->_runtime uptime];
        submitted = YES;
        status = remove(self->_session.aggregate, self->_session.leaf, NULL, THRComplete, self->_transaction.remove);
    }); } @catch (NSException *exception) {
        if (!submitted) {
            THRReleaseOperation(_transaction.remove); THRReleaseOperation(_transaction.remove); _transaction.remove = NULL;
        } else {
            _transaction.removePhase = THRetainedRemovePhaseSubmissionFailed;
        }
        @throw exception;
    }
    if (!submitted) {
        THRReleaseOperation(_transaction.remove); THRReleaseOperation(_transaction.remove); _transaction.remove = NULL;
        return permitted ? THRRemovalSubmissionEvidenceChanged : THRRemovalSubmissionGateRejected;
    }
    _transaction.removePhase = status != 0 ? THRetainedRemovePhaseSubmissionFailed : THRetainedRemovePhaseSubmitted;
    *resultStatus = status;
    [self event:event status:status];
    return THRRemovalSubmissionSubmitted;
}
// Caller already proved the first view empty. A second complete observation
// must agree; only ordinary leave additionally requires local output.
- (BOOL)confirmEmptyView:(NSDictionary *)view requireLocal:(BOOL)requireLocal {
    NSDictionary *latest = [self heldView];
    return !_session.invalidated && [latest isEqual:view] && (!requireLocal || [self localUnselected]);
}
- (BOOL)reconcile:(NSError **)error isShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(THAudioMutationGate)performIfRunning waitForCompletion:(BOOL)waitForCompletion {
    if (isShuttingDown() || !_transaction.owned) return YES;
    if ([self retireSupersededOwnership]) return YES;
    if (_transaction.removeSubmissionFailed) return [self deferCleanup:error reason:@"removeSubmissionFailed" pending:NO];
    if (waitForCompletion && _transaction.removeAttempted && _transaction.remove)
        return [self waitForSubmittedRemoval:error isShuttingDown:isShuttingDown performIfRunning:performIfRunning];
    if (!_transaction.add || !atomic_load(&_transaction.add->done) || (_transaction.remove && !atomic_load(&_transaction.remove->done))) {
        return [self deferCleanup:error reason:@"callbackPending" pending:YES];
    }
    if (!atomic_load(&_transaction.add->objectsMatch) || (_transaction.remove && !atomic_load(&_transaction.remove->objectsMatch))) {
        _session.invalidated = YES;
        return [self deferCleanup:error reason:@"callbackIdentityMismatch" pending:NO];
    }
    if (_transaction.remove && atomic_load(&_transaction.remove->status) != 0)
        return [self deferCleanup:error reason:@"removeFailed" pending:NO];
    NSDictionary *view = [self heldView];
    if (!view || _session.invalidated) return [self deferCleanup:error reason:@"retainedRouteInvalid" pending:NO];
    // A rapid external switch back cancels an unsubmitted cleanup. The same
    // HAL stream remaining selected is never a reason to Remove its member.
    if ([self selected:view]) {
        _diagnostics[@"runtimeCleanupState"] = @"selected";
        return YES;
    }
    if (![self localUnselected]) return [self deferCleanup:error reason:@"waitingForUnselectedOutput" pending:YES];
    if ([self empty:view]) {
        // Clear only local ownership after two agreeing live samples. This is
        // also the path for removal already completed by the system itself.
        if (![self confirmEmptyView:view requireLocal:YES])
            return [self deferCleanup:error reason:@"emptyReadbackUnstable" pending:YES];
        [self clearOwnership]; _diagnostics[@"runtimeCleanupState"] = @"idle";
        [self event:@"ownMemberCleared" status:0]; return YES;
    }
    if (atomic_load(&_transaction.add->status) != 0 || ![self soleMember:view] ||
        !THRLeafIdentity(_runtime, _session.leaf, _session.identifier, _diagnostics)) {
        return [self deferCleanup:error reason:@"appMemberOwnershipUnconfirmed" pending:NO];
    }
    NSString *stream = [self stream:view];
    if (!THOwnedAirPlayStreamMatches(_transaction.ownStreamUID, stream)) {
        // Never infer a replacement stream from a receiver name/ID or a late
        // Add callback. Only select's first witnessed generation is ours.
        if (THRString(_transaction.ownStreamUID) && THRString(stream)) _session.invalidated = YES;
        return [self deferCleanup:error reason:THRString(_transaction.ownStreamUID) ?
            @"ownStreamReplacedExternally" : @"ownStreamNotWitnessed" pending:NO];
    }
    if (_transaction.removeAttempted) {
        BOOL awaitingReadback = _transaction.remove && atomic_load(&_transaction.remove->status) == 0 &&
            [_runtime uptime] - _transaction.removeSubmittedAt < 18;
        return [self deferCleanup:error reason:@"removeNotConfirmed" pending:awaitingReadback];
    }
    SInt32 status = NSUserCancelledError;
    THRRemovalSubmission submission = [self submitOwnedRemovalPerformIfPermitted:performIfRunning confirmEvidence:^BOOL {
        // Registration commits this operation against shutdown. The Swift gate
        // holds no lock across these reads or the submission. Recheck the full
        // association so an external switch cannot authorize a stale Remove.
        NSDictionary *latest = [self heldView];
        return !self->_session.invalidated && [latest isEqual:view] && [self localUnselected] &&
            THOwnedAirPlayStreamMatches(self->_transaction.ownStreamUID, [self stream:latest]) &&
            THRLeafIdentity(self->_runtime, self->_session.leaf, self->_session.identifier, self->_diagnostics);
    } event:@"removeOwnMemberSubmitted" status:&status];
    if (submission == THRRemovalSubmissionMethodUnavailable) return [self deferCleanup:error reason:@"removeMethodUnavailable" pending:NO];
    if (submission == THRRemovalSubmissionStateUnavailable) return [self deferCleanup:error reason:@"removeStateUnavailable" pending:NO];
    if (submission == THRRemovalSubmissionGateRejected) return YES;
    if (submission != THRRemovalSubmissionSubmitted) {
        return [self deferCleanup:error reason:@"outputChangedBeforeRemove" pending:YES];
    }
    if (status) return [self deferCleanup:error reason:@"removeSubmissionFailed" pending:NO];
    if (!waitForCompletion) {
        return [self deferCleanup:error reason:@"callbackPending" pending:YES];
    }
    return [self waitForSubmittedRemoval:error isShuttingDown:isShuttingDown performIfRunning:performIfRunning];
}
- (BOOL)reconcile:(NSError **)error isShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(THAudioMutationGate)performIfRunning {
    return [self reconcile:error isShuttingDown:isShuttingDown performIfRunning:performIfRunning waitForCompletion:YES];
}
- (void)rollbackOwnOutputPerformIfRunning:(THAudioMutationGate)performIfRunning {
    NSDictionary *view = [self heldView];
    if (_session.invalidated || !_transaction.ownStreamUID || !THRHALExact(_runtime, _transaction.ownStreamUID, YES) || ![self soleMember:view] || ![[self stream:view] isEqual:_transaction.ownStreamUID] ||
        ![THRHALDefault(_runtime)[@"uid"] isEqual:_transaction.ownStreamUID]) return;
    NSDictionary *local = THRHALExact(_runtime, _transaction.returnLocalUID, NO); if (!local) return;
    [self event:@"restoreOwnOutputSubmitted" status:THRSubmitHAL(_runtime, local, performIfRunning)];
    NSTimeInterval end = [_runtime uptime] + 3;
    while (![self localUnselected] && [_runtime uptime] < end) THRPump(_runtime);
}
- (void)rollbackCapturedOutput:(NSString *)uid toLocalUID:(NSString *)localUID performIfRunning:(THAudioMutationGate)performIfRunning {
    _diagnostics[@"capturedRollback"] = @"skippedAssociationChanged";
    NSDictionary *view = [self heldView];
    // Only undo this call's HAL choice. Require the complete selected association
    // still to agree, and never remove or assume ownership of a borrowed member.
    if (![uid isEqual:_session.captureStreamUID] || ![self capturedStreamDevice:view] ||
        ![THRHALDefault(_runtime)[@"uid"] isEqual:uid] || ![self selected:view]) return;
    NSDictionary *local = THRHALExact(_runtime, localUID, NO); if (!local) return;
    OSStatus status = THRSubmitHAL(_runtime, local, performIfRunning);
    _diagnostics[@"capturedRollback"] = status ? @"writeFailed" : @"submitted";
    [self event:@"restoreCapturedOutputSubmitted" status:status];
    if (status) return;
    NSTimeInterval end = [_runtime uptime] + 3;
    while ([_runtime uptime] < end) {
        if ([THRHALDefault(_runtime)[@"uid"] isEqual:localUID] && [self localUnselected]) {
            _diagnostics[@"capturedRollback"] = @"confirmed"; return;
        }
        THRPump(_runtime);
    }
    _diagnostics[@"capturedRollback"] = @"unconfirmed";
}
// Read-only identity association for list deduplication. Recovery authorization
// is separate and additionally validates the current/target HAL write capability.
- (NSDictionary *)existingStreamAssociationSample {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (!THRExistingStreamRecoverySupportedOS(version) ||
        _session.aggregate || _transaction.owned || _transaction.add || _transaction.remove || _transaction.mustClean || _session.invalidated) return nil;
    CFTypeRef context = NULL, manager = NULL, leaf = NULL;
    @try {
        if ([_runtime copyContext:kCFAllocatorDefault options:NULL output:&context] || !THRRouting(_runtime, context) ||
            ![THRRead(_runtime, context, "kFigRoutingContextProperty_ContextType", _diagnostics) isEqual:@1]) return nil;
        NSString *contextID = THRRead(_runtime, context, "kFigRoutingContextProperty_ContextUUID", _diagnostics);
        if (!THRString(contextID)) return nil;
        if (!THRContextIsUnselected(_runtime, context, _diagnostics)) return nil;
        NSDictionary *current = THRHALDefault(_runtime);
        if (!current || !THRFlag(current[@"airplay"], NO) || !THRHALExact(_runtime, current[@"uid"], NO)) return nil;
        if ([_runtime copyManager:&manager] || !THRTyped(manager, _runtime.functions.managerType)) return nil;
        id show = THRRead(_runtime, manager, "kAPEndpointManagerProperty_ShowInfo", _diagnostics);
        if (!THRHasType(show, CFDictionaryGetTypeID())) return nil;
        id groups = THRField(_runtime, show, "kAPEndpointManagerShowInfoKey_AggregateShowInfos");
        if (!THRHasType(groups, CFArrayGetTypeID())) return nil;
        NSDictionary *group = nil; NSUInteger matches = 0;
        for (id row in groups) {
            if (!THRHasType(row, CFDictionaryGetTypeID())) return nil;
            if ([THRField(_runtime, row, "kAPEndpointShowInfoKey_RoutingContextID") isEqual:contextID]) { group = row; matches++; }
        }
        NSString *aggregateID = THRField(_runtime, group, "kAPEndpointShowInfoKey_EndpointID");
        if (matches != 1 || !THRString(aggregateID) ||
            !THRFlag(THRField(_runtime, group, "kAPEndpointShowInfoKey_Activated"), YES) ||
            !THRFlag(THRField(_runtime, group, "kAPEndpointShowInfoKey_IsRemoteControlEndpoint"), NO)) return nil;
        id members = THRField(_runtime, group, "kAPEndpointShowInfoKey_SubEndpointShowInfoDicts");
        if (!THRHasType(members, CFArrayGetTypeID()) || [members count] != 1) return nil;
        id member = members[0];
        if (!THRHasType(member, CFDictionaryGetTypeID()) ||
            !THRFlag(THRField(_runtime, member, "kAPEndpointShowInfoKey_Activated"), YES) ||
            !THRFlag(THRField(_runtime, member, "kAPEndpointShowInfoKey_IsRemoteControlEndpoint"), NO)) return nil;
        NSString *identifier = THRField(_runtime, member, "kAPEndpointShowInfoKey_DeviceID");
        if (!THRString(identifier)) return nil;
        leaf = THRCopyUniqueLeaf(_runtime, [_endpointDiscovery availableEndpointReferencesWithError:NULL],
            identifier, _diagnostics, @"existingStreamDiscoveryCandidates");
        if (!leaf) return nil;
        NSString *name = THRRead(_runtime, leaf, "kFigEndpointProperty_Name", _diagnostics);
        NSDictionary *device = THRHALForExistingAggregate(_runtime, aggregateID);
        if (!THRString(name) || !device ||
            ![THRRead(_runtime, context, "kFigRoutingContextProperty_ContextUUID", _diagnostics) isEqual:contextID] ||
            !THRContextIsUnselected(_runtime, context, _diagnostics) || ![THRHALDefault(_runtime) isEqual:current]) return nil;
        return @{@"identifier":identifier, @"name":name, @"uid":device[@"uid"], @"halDeviceID":device[@"deviceID"],
            @"aggregateIdentifier":aggregateID, @"contextIdentifier":contextID,
            @"currentUID":current[@"uid"], @"currentDeviceID":current[@"deviceID"]};
    } @finally {
        if (leaf) CFRelease(leaf);
        if (manager) CFRelease(manager); if (context) CFRelease(context);
    }
}
- (NSDictionary *)verifiedExistingStreamAssociation {
    NSDictionary *first = [self existingStreamAssociationSample];
    if (!first || ![[self existingStreamAssociationSample] isEqual:first]) return nil;
    NSMutableDictionary *result = [first mutableCopy]; result[@"readbackStable"] = @YES;
    return result;
}
// A cold process may explicitly select an existing stream without owning it.
// This is a separate, live capability, never inferred by the catalog from a UID.
- (NSDictionary *)existingStreamRecoverySample {
    NSDictionary *association = [self existingStreamAssociationSample];
    if (!association || _closed) return nil;
    NSDictionary *target = THRHALExact(_runtime, association[@"uid"], YES);
    NSDictionary *origin = THRHALExact(_runtime, association[@"currentUID"], NO);
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Boolean settable = false;
    if (![target[@"deviceID"] isEqual:association[@"halDeviceID"]] ||
        ![origin[@"deviceID"] isEqual:association[@"currentDeviceID"]] ||
        !THRCanBeDefaultOutput(_runtime, target) || !THRCanBeDefaultOutput(_runtime, origin) ||
        [_runtime halSettable:kAudioObjectSystemObject address:&address value:&settable] || !settable ||
        ![THRHALExact(_runtime, association[@"uid"], YES) isEqual:target] ||
        ![THRHALDefault(_runtime) isEqual:origin]) return nil;
    return association;
}
- (NSDictionary *)verifiedExistingStreamRecovery {
    NSDictionary *first = [self existingStreamRecoverySample];
    if (!first || ![[self existingStreamRecoverySample] isEqual:first]) return nil;
    NSMutableDictionary *result = [first mutableCopy];
    result[@"readbackStable"] = @YES; result[@"canSelect"] = @YES;
    return result;
}
- (BOOL)recoverExistingStream:(NSString *)identifier isCancelled:(BOOL (^)(void))isCancelled
    isShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(THAudioMutationGate)performIfRunning error:(NSError **)error {
    NSDictionary *expected = [self verifiedExistingStreamRecovery];
    if (!expected || ![expected[@"identifier"] isEqual:identifier] || isCancelled() || [self isStopping:isShuttingDown]) {
        if (error) *error = THRError(THRetainedAudioErrorNotCaptured, NSLocalizedStringWithDefaultValue(@"native.retained.recovery_unconfirmed", nil, NSBundle.mainBundle, @"The existing audio stream or current output could not be confirmed. Recovery was not performed.", @"AirPlay status or error shown to the user."), _diagnostics);
        return NO;
    }
    _diagnostics[@"selectionMode"] = @"existingSystemStream";
    _diagnostics[@"existingStreamRecoveryState"] = @"validating";
    __block BOOL attempted = NO;
    __block OSStatus status = NSUserCancelledError;
    @try {
        THPerformAudioMutation(performIfRunning, ^{
            NSDictionary *target = THRHALExact(self->_runtime, expected[@"uid"], YES);
            status = THRSelectHALIf(self->_runtime, target, ^BOOL {
                // The gate registers this submission before the blocking reads.
                // Recheck all identities and the original output immediately at
                // the setter boundary. HAL has no cross-process compare-and-swap.
                if (isCancelled() || [self isStopping:isShuttingDown] ||
                    ![[self verifiedExistingStreamRecovery] isEqual:expected] ||
                    !THRCanBeDefaultOutput(self->_runtime, target) ||
                    ![THRHALExact(self->_runtime, expected[@"uid"], YES) isEqual:target] ||
                    ![THRHALString(self->_runtime, [target[@"deviceID"] unsignedIntValue], kAudioDevicePropertyDeviceUID) isEqual:expected[@"uid"]] ||
                    isCancelled() || [self isStopping:isShuttingDown]) return NO;
                attempted = YES;
                return YES;
            });
        });
        _diagnostics[@"existingStreamRecoveryHALStatus"] = @(status);
        _diagnostics[@"existingStreamRecoveryState"] = attempted ? @"awaitingSelection" : @"notSubmitted";
        [self event:attempted ? @"selectExistingSystemStreamSubmitted" : @"existingSystemStreamNotSubmitted" status:status];
        if (!attempted) {
            if (error) *error = THRError(THRetainedAudioErrorCapturedStreamChanged, NSLocalizedStringWithDefaultValue(@"native.retained.recovery_changed", nil, NSBundle.mainBundle, @"The existing audio stream, output, or permission to proceed has changed. Recovery was not performed.", @"AirPlay status or error shown to the user."), _diagnostics);
            return NO;
        }
        // Even a failed/throwing setter may have taken effect. Never retry it,
        // Add a new member, or infer ownership. Only complete selected readback
        // can establish a borrowed capture in this new process.
        THRetainedSystemAudioBridge *candidate = [[THRetainedSystemAudioBridge alloc]
            initWithEndpointDiscovery:_endpointDiscovery runtime:_runtime];
        NSUInteger consecutive = 0;
        NSTimeInterval deadline = [_runtime uptime] + 8;
        while (!isCancelled() && ![self isStopping:isShuttingDown] && [_runtime uptime] < deadline) {
            if ([candidate ensure:NULL isShuttingDown:isShuttingDown]) [candidate capture];
            NSDictionary *liveView = [candidate heldView];
            BOOL matches = [candidate->_session.identifier isEqual:identifier] &&
                [candidate->_session.aggregateID isEqual:expected[@"aggregateIdentifier"]] &&
                [candidate->_session.contextID isEqual:expected[@"contextIdentifier"]] &&
                [candidate->_session.captureStreamUID isEqual:expected[@"uid"]] &&
                [[candidate stream:liveView] isEqual:expected[@"uid"]] &&
                !candidate->_session.invalidated && [candidate selected:liveView];
            consecutive = matches ? consecutive + 1 : 0;
            if (consecutive >= 3 && !isCancelled() && ![self isStopping:isShuttingDown]) {
                [_session copyReferencesFrom:candidate->_session];
                _diagnostics[@"captureSource"] = @"existingSystemStreamRecovery";
                _diagnostics[@"captureState"] = @"captured";
                _diagnostics[@"existingStreamRecoveryState"] = @"confirmed";
                [self event:@"recoveredExistingSystemStreamReadbackConfirmed" status:0];
                return YES;
            }
            THRPump(_runtime); [_runtime pumpFor:0 sleepMicroseconds:150000];
        }
    } @catch (NSException *exception) {
        _diagnostics[@"existingStreamRecoveryException"] = exception.name;
    }
    // No automatic rollback: without a complete selected association it cannot
    // be proved to undo only this request. Leave actual output to fresh readback.
    _diagnostics[@"existingStreamRecoveryState"] = attempted ? @"selectionUnconfirmed" : @"notSubmitted";
    if (error) *error = THRError(attempted ? THRetainedAudioErrorCapturedSelectionUnconfirmed : THRetainedAudioErrorCapturedStreamChanged,
        attempted ? NSLocalizedStringWithDefaultValue(@"native.retained.recovery_selection_pending", nil, NSBundle.mainBundle, @"Recovery of the existing audio stream was requested. The system selection has not been fully confirmed yet.", @"AirPlay status or error shown to the user.") : NSLocalizedStringWithDefaultValue(@"native.retained.recovery_not_submitted", nil, NSBundle.mainBundle, @"Recovery of the existing audio stream was not submitted.", @"AirPlay status or error shown to the user."), _diagnostics);
    return NO;
}
- (NSDictionary *)snapshotWithError:(NSError **)error {
    return [self snapshotIsShuttingDown:^{ return NO; } error:error];
}
- (NSDictionary *)snapshotIsShuttingDown:(BOOL (^)(void))isShuttingDown error:(NSError **)error {
    if (![self enter:error]) return nil;
    @try {
        if ([self isStopping:isShuttingDown]) return [self stoppedSnapshot];
        if (![self ensure:error isShuttingDown:isShuttingDown])
            return [self isStopping:isShuttingDown] ? [self stoppedSnapshot] : nil;
        if ([self isStopping:isShuttingDown]) return [self stoppedSnapshot];
        [self settleCompletedOperation];
        BOOL sessionReadable = [self recoverUncapturedSessionIsShuttingDown:isShuttingDown];
        if ([self isStopping:isShuttingDown]) return [self stoppedSnapshot];
        if (sessionReadable) [self capture];
        if ([self isStopping:isShuttingDown]) return [self stoppedSnapshot];
        NSDictionary *view = [self heldView]; BOOL selected = view && !_session.invalidated && [self selected:view];
        BOOL pending = (_transaction.add && !atomic_load(&_transaction.add->done)) || (_transaction.remove && !atomic_load(&_transaction.remove->done));
        BOOL idle = view && [self empty:view] && [self localUnselected];
        BOOL eligible = _session.leaf && THRLeafEligible(_runtime, _session.leaf, _session.identifier, _diagnostics);
        // Double-read live aggregate/member/stream/HAL identity independently
        // from selection capability. Neither a cached UID nor canSelect proves it.
        NSDictionary *associatedDevice = !selected ? [self verifiedHeldStreamDevice:view] : nil;
        NSString *associatedUID = associatedDevice[@"uid"];
        NSDictionary *capturedDevice = !selected ? [self capturedStreamDevice:view] : nil;
        BOOL capturedStreamAvailable = associatedUID && [capturedDevice[@"uid"] isEqual:associatedUID] &&
            [[self capturedStreamDevice:[self heldView]] isEqual:capturedDevice] && [self localUnselected];
        BOOL cleanupBlocked = _transaction.owned && [_diagnostics[@"runtimeCleanupState"] isEqual:@"blocked"];
        BOOL canSelect = !_session.invalidated && !pending && !cleanupBlocked && !_transaction.mustClean && eligible && (selected || (!_transaction.owned && idle) || capturedStreamAvailable);
        NSString *state = !_session.aggregate ? @"uncaptured" : _session.invalidated || !view ? @"invalid" : cleanupBlocked ? @"cleanupFailed" : pending ? @"pending" :
            _transaction.mustClean ? @"cleanupRequired" : selected ? @"selected" : canSelect ? @"retained" : @"unavailable";
        NSString *reason = [state isEqual:@"uncaptured"] ? NSLocalizedStringWithDefaultValue(@"native.retained.reason.uncaptured", nil, NSBundle.mainBundle, @"The receiver selected by the system has not been captured yet", @"Explanation shown for an unavailable retained AirPlay receiver.") :
            [state isEqual:@"invalid"] ? NSLocalizedStringWithDefaultValue(@"native.retained.reason.route_changed", nil, NSBundle.mainBundle, @"The original route has changed. Select the receiver again in system settings", @"Explanation shown for an unavailable retained AirPlay receiver.") :
            cleanupBlocked ? NSLocalizedStringWithDefaultValue(@"native.retained.reason.cleanup_blocked", nil, NSBundle.mainBundle, @"Cleanup of the previous connection could not be confirmed. Select the receiver again in system settings", @"Explanation shown for an unavailable retained AirPlay receiver.") :
            pending ? NSLocalizedStringWithDefaultValue(@"native.retained.reason.operation_pending", nil, NSBundle.mainBundle, @"Waiting for the system to finish the previous operation", @"Explanation shown for an unavailable retained AirPlay receiver.") : (_transaction.mustClean || (_transaction.owned && !selected)) ? NSLocalizedStringWithDefaultValue(@"native.retained.reason.cleanup_pending", nil, NSBundle.mainBundle, @"Waiting to clean up the previous connection", @"Explanation shown for an unavailable retained AirPlay receiver.") :
            !eligible && _session.aggregate ? NSLocalizedStringWithDefaultValue(@"native.retained.reason.receiver_unavailable", nil, NSBundle.mainBundle, @"The receiver is currently unavailable", @"Explanation shown for an unavailable retained AirPlay receiver.") : !canSelect && _session.aggregate ? NSLocalizedStringWithDefaultValue(@"native.retained.reason.reuse_unsafe", nil, NSBundle.mainBundle, @"The current system route cannot be safely reused", @"Explanation shown for an unavailable retained AirPlay receiver.") : @"";
        // Discovery may still be warming up when an already-selected route is
        // captured and immediately left. A second complete live validation may
        // describe that usable held receiver independently of the directory.
        // Neither an old handle nor its remembered stream UID grants a row.
        NSDictionary *catalogRoute = nil;
        if (canSelect && !selected && [state isEqual:@"retained"]) {
            NSDictionary *latestView = [self heldView];
            BOOL stillIdle = idle && [self empty:latestView];
            BOOL stillCapturedStream = capturedStreamAvailable && associatedUID &&
                [[self capturedStreamDevice:latestView][@"uid"] isEqual:associatedUID];
            NSString *liveName = THRRead(_runtime, _session.leaf, "kFigEndpointProperty_Name", _diagnostics);
            if (!_session.invalidated && [latestView isEqual:view] && (stillIdle || stillCapturedStream) &&
                [self localUnselected] && THRLeafEligible(_runtime, _session.leaf, _session.identifier, _diagnostics) && THRString(liveName)) {
                catalogRoute = @{@"identifier":_session.identifier, @"name":liveName, @"transport":@"airplay",
                    @"uid":associatedUID ?: (id)NSNull.null, @"readbackStable":@YES};
            }
        }
        // Independent association must not repeatedly obtain temporary getters
        // while this retained session is invalid or its recovery is in backoff.
        NSDictionary *existing = sessionReadable ? [self verifiedExistingStreamAssociation] : nil;
        if ([self isStopping:isShuttingDown]) return [self stoppedSnapshot];
        _diagnostics[@"existingStreamAssociationAvailable"] = @(existing != nil);
        NSDictionary *publicExisting = existing ? [existing dictionaryWithValuesForKeys:
            @[@"identifier", @"name", @"uid", @"aggregateIdentifier", @"contextIdentifier", @"readbackStable"]] : nil;
        _diagnostics[@"existingStreamAssociation"] = publicExisting ?: (id)NSNull.null;
        // Keep this comparison separate from selection capability. The system's
        // CopyRoutes can omit a member that the raw aggregate and HAL still use.
        // A stable match is only a readback diagnostic, not proof of exit handoff.
        NSMutableDictionary *memberReadStatus = [NSMutableDictionary dictionary];
        NSArray *(^routeMemberIDs)(NSArray *) = ^NSArray *(NSArray *routes) {
            if (!routes) return nil;
            NSMutableArray *identifiers = [NSMutableArray array];
            for (id endpoint in routes) {
                id identifier = THRRead(self->_runtime, (__bridge CFTypeRef)endpoint, "kFigEndpointProperty_ID", memberReadStatus);
                if (!THRString(identifier) || [identifiers containsObject:identifier]) return nil;
                [identifiers addObject:identifier];
            }
            return [identifiers sortedArrayUsingSelector:@selector(compare:)];
        };
        NSString *memberContextID = THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextUUID", memberReadStatus);
        BOOL memberContextValid = _session.aggregate && !_session.invalidated && [memberContextID isEqual:_session.contextID] &&
            [THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextType", memberReadStatus) isEqual:@1];
        NSArray *systemMemberIDs = routeMemberIDs(THRRoutes(_runtime, _session.context, memberReadStatus));
        NSArray *rawMemberIDs = view[@"members"];
        BOOL rawMemberIDsValid = rawMemberIDs && [NSSet setWithArray:rawMemberIDs].count == rawMemberIDs.count;
        for (id identifier in rawMemberIDs) if (!THRString(identifier)) rawMemberIDsValid = NO;
        rawMemberIDs = rawMemberIDsValid ? [rawMemberIDs sortedArrayUsingSelector:@selector(compare:)] : nil;
        NSDictionary *latestMemberView = memberContextValid ?
            [self view:_session.aggregate identifier:_session.aggregateID context:_session.contextID] : nil;
        NSArray *latestSystemMemberIDs = routeMemberIDs(THRRoutes(_runtime, _session.context, memberReadStatus));
        BOOL memberReadbackStable = memberContextValid && rawMemberIDs && systemMemberIDs &&
            [view isEqual:latestMemberView] && [systemMemberIDs isEqual:latestSystemMemberIDs] &&
            [memberContextID isEqual:THRRead(_runtime, _session.context, "kFigRoutingContextProperty_ContextUUID", memberReadStatus)];
        BOOL selectedForComparison = selected && memberContextValid && [self selected:latestMemberView];
        NSString *memberComparison = !selectedForComparison || !memberReadbackStable ? @"unknown" :
            [systemMemberIDs isEqual:rawMemberIDs] ? @"matches" : @"mismatch";
        _diagnostics[@"systemRouteMemberComparison"] = @{
            @"systemContextMemberIDs":systemMemberIDs ?: (id)NSNull.null,
            @"rawAggregateMemberIDs":rawMemberIDs ?: (id)NSNull.null,
            @"readbackStable":@(memberReadbackStable), @"selectedForComparison":@(selectedForComparison),
            @"comparison":memberComparison,
            @"readStatus":[memberReadStatus copy]};
        if ([self isStopping:isShuttingDown]) return [self stoppedSnapshot];
        // Later reads in this same snapshot must not contradict the identity
        // already sampled above. Revoke it (and dependent reuse capability),
        // rather than publishing an old UID or authorizing a replacement stream.
        if (associatedDevice && (_session.invalidated || ![latestMemberView isEqual:view] ||
            ![[self heldStreamDevice:latestMemberView] isEqual:associatedDevice])) {
            associatedUID = nil; capturedStreamAvailable = NO; catalogRoute = nil; canSelect = NO;
            state = _session.invalidated ? @"invalid" : @"unavailable";
            reason = NSLocalizedStringWithDefaultValue(@"native.retained.reason.route_changed", nil, NSBundle.mainBundle, @"The original route has changed. Select the receiver again in system settings", @"Explanation shown for an unavailable retained AirPlay receiver.");
        }
        if ([self isStopping:isShuttingDown]) return [self stoppedSnapshot];
        if (existing && ![[self verifiedExistingStreamAssociation] isEqual:existing]) {
            existing = nil; publicExisting = nil;
        }
        NSDictionary *recovery = sessionReadable && existing ? [self verifiedExistingStreamRecovery] : nil;
        if (recovery) {
            NSMutableDictionary *recoveryAssociation = [recovery mutableCopy];
            [recoveryAssociation removeObjectForKey:@"canSelect"];
            if (![recoveryAssociation isEqual:existing]) {
                recovery = nil; existing = nil; publicExisting = nil;
            }
        }
        if (existing && !recovery && ![[self verifiedExistingStreamAssociation] isEqual:existing]) {
            existing = nil; publicExisting = nil;
        }
        _diagnostics[@"existingStreamAssociationAvailable"] = @(existing != nil);
        _diagnostics[@"existingStreamAssociation"] = publicExisting ?: (id)NSNull.null;
        NSDictionary *publicRecovery = recovery ? [recovery dictionaryWithValuesForKeys:
            @[@"identifier", @"name", @"uid", @"aggregateIdentifier", @"contextIdentifier", @"readbackStable", @"canSelect"]] : nil;
        _diagnostics[@"existingStreamRecovery"] = publicRecovery ?: (id)NSNull.null;
        if ([self isStopping:isShuttingDown]) return [self stoppedSnapshot];
        [self updateDiagnostics]; _diagnostics[@"canSelect"] = @(canSelect); _diagnostics[@"isSelected"] = @(selected);
        _diagnostics[@"state"] = state; _diagnostics[@"ownedMember"] = @(_transaction.owned); _diagnostics[@"callbackPending"] = @(pending);
        _diagnostics[@"availableSelectionMode"] = selected ? @"alreadySelected" : capturedStreamAvailable ? @"existingCapturedStream" :
            canSelect && idle ? @"newAggregateMember" : @"unavailable";
        _diagnostics[@"associatedUID"] = associatedUID ?: (id)NSNull.null;
        // C comparison expressions box as CFNumber. The strict Swift adapter
        // requires an actual CFBoolean for authorization/identity markers.
        BOOL associationReadbackStable = associatedUID != nil;
        _diagnostics[@"associationReadbackStable"] = @(associationReadbackStable);
        NSDictionary *retained = _session.aggregate ? @{@"identifier":_session.identifier, @"name":_session.name, @"canSelect":@(canSelect),
            @"isSelected":@(selected), @"reason":reason, @"state":state,
            @"associatedUID":associatedUID ?: (id)NSNull.null, @"associationReadbackStable":@(associationReadbackStable),
            @"catalogRoute":catalogRoute ?: (id)NSNull.null} : nil;
        return @{@"retained":retained ?: (id)NSNull.null, @"existingStreamAssociation":publicExisting ?: (id)NSNull.null,
            @"existingStreamRecovery":publicRecovery ?: (id)NSNull.null,
            @"sessionReadSucceeded":@((BOOL)(sessionReadable && (!_session.aggregate || view != nil))),
            @"diagnostics":[_diagnostics copy]};
    } @catch (NSException *exception) {
        _diagnostics[@"exception"] = exception.name;
        if (error) *error = THRError(THRetainedAudioErrorReadFailed, NSLocalizedStringWithDefaultValue(@"native.retained.read_failed", nil, NSBundle.mainBundle, @"Unable to read the retained AirPlay route.", @"AirPlay status or error shown to the user."), _diagnostics); return nil;
    } @finally { _busy = NO; }
}
- (BOOL)selectIdentifier:(NSString *)identifier isCancelled:(BOOL (^)(void))isCancelled isShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(THAudioMutationGate)performIfRunning error:(NSError **)error {
    if (![self enter:error]) return NO;
    BOOL success = NO, capturedHALAttempted = NO;
    __block BOOL attemptedThisCall = NO;
    NSString *capturedTargetUID = nil, *capturedReturnLocalUID = nil;
    @try {
        if (![self ensure:error]) return NO;
        [self settleCompletedOperation]; [self capture];
        if ((isCancelled() || isShuttingDown())) { if (error) *error = THRError(NSUserCancelledError, NSLocalizedStringWithDefaultValue(@"native.retained.switch_cancelled", nil, NSBundle.mainBundle, @"Switching was cancelled.", @"AirPlay status or error shown to the user."), _diagnostics); return NO; }
        if (!_session.aggregate) {
            return [self recoverExistingStream:identifier isCancelled:isCancelled isShuttingDown:isShuttingDown
                performIfRunning:performIfRunning error:error];
        }
        if (!_session.aggregate || ![_session.identifier isEqual:identifier] || _session.invalidated || _transaction.mustClean) {
            if (error) *error = THRError(THRetainedAudioErrorNotCaptured, NSLocalizedStringWithDefaultValue(@"native.retained.route_not_captured", nil, NSBundle.mainBundle, @"No reusable system route is available yet. Select this receiver in system settings first.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
        }
        NSDictionary *view = [self heldView];
        BOOL pending = (_transaction.add && !atomic_load(&_transaction.add->done)) || (_transaction.remove && !atomic_load(&_transaction.remove->done));
        if (!pending && !_transaction.mustClean && [self selected:view]) { success = YES; return YES; }
        if ([self capturedStreamDevice:view] && [self localUnselected]) {
            capturedTargetUID = [_session.captureStreamUID copy];
            capturedReturnLocalUID = [THRHALDefault(_runtime)[@"uid"] copy];
            _diagnostics[@"selectionMode"] = @"existingCapturedStream";
            _diagnostics[@"capturedRollback"] = @"notNeeded";
            // Re-read association and both exact HAL identities immediately
            // before the only forward write. The member remains borrowed.
            NSDictionary *device = [self capturedStreamDevice:[self heldView]];
            if (!device || !THRHALExact(_runtime, capturedReturnLocalUID, NO) || ![self localUnselected] ||
                ![THRHALDefault(_runtime)[@"uid"] isEqual:capturedReturnLocalUID] || (isCancelled() || isShuttingDown())) {
                if (error) *error = THRError((isCancelled() || isShuttingDown()) ? NSUserCancelledError : 22,
                    NSLocalizedStringWithDefaultValue(@"native.retained.stream_changed", nil, NSBundle.mainBundle, @"The original audio stream or current output has changed. Switching was not performed.", @"AirPlay status or error shown to the user."), _diagnostics);
                return NO;
            }
            capturedHALAttempted = YES;
            OSStatus status = THRSubmitHAL(_runtime, device, performIfRunning); [self event:@"selectCapturedAudioStreamSubmitted" status:status];
            if (status) { if (error) *error = THRError(status, NSLocalizedStringWithDefaultValue(@"native.retained.stream_selection_failed", nil, NSBundle.mainBundle, @"The system could not select the original AirPlay audio stream.", @"AirPlay status or error shown to the user."), _diagnostics); return NO; }
            if ([self confirmSelectedStream:capturedTargetUID isCancelled:isCancelled]) {
                success = YES; [self event:@"selectedCapturedStreamReadbackConfirmed" status:0]; return YES;
            }
            if (error) *error = THRError((isCancelled() || isShuttingDown()) ? NSUserCancelledError : 23,
                NSLocalizedStringWithDefaultValue(@"native.retained.stream_selection_unconfirmed", nil, NSBundle.mainBundle, @"The system selection of the original AirPlay audio stream could not be confirmed.", @"AirPlay status or error shown to the user."), _diagnostics);
            return NO;
        }
        if (_transaction.owned || _transaction.add || _transaction.remove || ![self empty:view] || ![self localUnselected] || !THRLeafEligible(_runtime, _session.leaf, identifier, _diagnostics)) {
            if (error) *error = THRError(THRetainedAudioErrorUnsafeRoute, NSLocalizedStringWithDefaultValue(@"native.retained.route_unsafe", nil, NSBundle.mainBundle, @"The current route does not allow safe switching.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
        }
        THRAggregateOperation add = THRAggregateMethod(_runtime, _session.aggregate, 1, _diagnostics);
        CFStringRef usage = THRKey(_runtime, "kFigEndpointActivateOptionKey_PrimaryUsage"), playback = THRKey(_runtime, "kFigEndpointPrimaryUsage_Playback"),
            avoid = THRKey(_runtime, "kFigEndpointActivateOptionKey_AvoidAuthPrompt"), pid = THRKey(_runtime, "kFigEndpointActivateOptionKey_ClientPID");
        if (!add || !usage || !playback || !avoid || !pid) { if (error) *error = THRError(THRetainedAudioErrorReuseUnavailable, NSLocalizedStringWithDefaultValue(@"native.retained.reuse_unavailable", nil, NSBundle.mainBundle, @"Route reuse is unavailable on this system.", @"AirPlay status or error shown to the user."), _diagnostics); return NO; }
        NSDictionary *options = @{(__bridge id)usage:(__bridge id)playback, (__bridge id)avoid:@YES, (__bridge id)pid:@(getpid())};
        _transaction.returnLocalUID = [THRHALDefault(_runtime)[@"uid"] copy];
        if (!THRHALExact(_runtime, _transaction.returnLocalUID, NO) || ![self empty:[self heldView]] || ![self localUnselected] || (isCancelled() || isShuttingDown())) {
            if (error) *error = THRError(THRetainedAudioErrorOutputChanged, NSLocalizedStringWithDefaultValue(@"native.retained.output_changed", nil, NSBundle.mainBundle, @"The system output has changed or switching was cancelled.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
        }
        _transaction.add = THRNewOperation(_session.aggregate, _session.leaf, _session.context, _session.manager);
        if (!_transaction.add) { if (error) *error = THRError(THRetainedAudioErrorAllocation, NSLocalizedStringWithDefaultValue(@"native.retained.allocation_failed", nil, NSBundle.mainBundle, @"Unable to allocate state for the routing operation.", @"AirPlay status or error shown to the user."), _diagnostics); return NO; }
        _diagnostics[@"selectionMode"] = @"newAggregateMember";
        _diagnostics[@"runtimeCleanupState"] = @"adding";
        __block SInt32 status = NSUserCancelledError;
        if (!THPerformAudioMutation(performIfRunning, ^{
            // An accepted call owns its possible remote side effects even if
            // the proxy throws before returning to the caller.
            attemptedThisCall = YES;
            self->_transaction.owned = YES;
            status = add(self->_session.aggregate, self->_session.leaf, (__bridge CFDictionaryRef)options, THRComplete, self->_transaction.add);
        })) {
            THRReleaseOperation(_transaction.add); THRReleaseOperation(_transaction.add); _transaction.add = NULL;
            if (error) *error = THRError(NSUserCancelledError, NSLocalizedStringWithDefaultValue(@"native.retained.connection_quitting", nil, NSBundle.mainBundle, @"The app is quitting. No connection request was submitted.", @"AirPlay status or error shown to the user."), _diagnostics);
            return NO;
        }
        [self event:@"addRetainedMemberSubmitted" status:status];
        BOOL done = THRWait(_runtime, _transaction.add, 15, isShuttingDown);
        if (!done || !atomic_load(&_transaction.add->objectsMatch) || atomic_load(&_transaction.add->status) != 0 || status) {
            if (error) *error = THRError(status ?: 10, NSLocalizedStringWithDefaultValue(@"native.retained.connection_unconfirmed", nil, NSBundle.mainBundle, @"The system has not confirmed the AirPlay connection. The original reference has been kept for cleanup.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
        }
        NSTimeInterval end = [_runtime uptime] + 8; NSDictionary *device = nil;
        do {
            view = [self heldView]; NSString *uid = [self stream:view];
            if (uid) {
                if (_transaction.ownStreamUID && !THOwnedAirPlayStreamMatches(_transaction.ownStreamUID, uid)) {
                    _session.invalidated = YES; _diagnostics[@"reason"] = @"ownStreamReplacedDuringAdd"; break;
                }
                if (!_transaction.ownStreamUID) _transaction.ownStreamUID = [uid copy];
                device = THRHALExact(_runtime, uid, YES);
            }
            if (device || (isCancelled() || isShuttingDown())) break; THRPump(_runtime);
        } while ([_runtime uptime] < end);
        if (!device || (isCancelled() || isShuttingDown()) || ![self localUnselected] || ![[self stream:[self heldView]] isEqual:_transaction.ownStreamUID] ||
            ![THRHALDefault(_runtime)[@"uid"] isEqual:_transaction.returnLocalUID]) {
            if (error) *error = THRError((isCancelled() || isShuttingDown()) ? NSUserCancelledError : 11, NSLocalizedStringWithDefaultValue(@"native.retained.device_not_ready", nil, NSBundle.mainBundle, @"The connection was cancelled or the new audio device is not ready yet.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
        }
        // Resolve the new stream again immediately before this one HAL write.
        device = THRHALExact(_runtime, _transaction.ownStreamUID, YES);
        if (!device || (isCancelled() || isShuttingDown())) {
            if (error) *error = THRError((isCancelled() || isShuttingDown()) ? NSUserCancelledError : 17, NSLocalizedStringWithDefaultValue(@"native.retained.device_changed", nil, NSBundle.mainBundle, @"The new audio device has changed or switching was cancelled.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
        }
        status = THRSubmitHAL(_runtime, device, performIfRunning); [self event:@"selectNewAudioStreamSubmitted" status:status];
        if (status) { if (error) *error = THRError(status, NSLocalizedStringWithDefaultValue(@"native.retained.new_device_selection_failed", nil, NSBundle.mainBundle, @"The system could not select the new AirPlay audio device.", @"AirPlay status or error shown to the user."), _diagnostics); return NO; }
        if ([self confirmSelectedStream:_transaction.ownStreamUID isCancelled:isCancelled]) {
            success = YES; _diagnostics[@"runtimeCleanupState"] = @"selected";
            [self event:@"selectedReadbackConfirmed" status:0]; return YES;
        }
        if (error) *error = THRError((isCancelled() || isShuttingDown()) ? NSUserCancelledError : 12, NSLocalizedStringWithDefaultValue(@"native.retained.target_selection_unconfirmed", nil, NSBundle.mainBundle, @"The system selection of the target AirPlay receiver could not be confirmed.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
    } @catch (NSException *exception) {
        _diagnostics[@"exception"] = exception.name;
        if (error) *error = THRError(THRetainedAudioErrorSelectionFailed, NSLocalizedStringWithDefaultValue(@"native.retained.selection_failed", nil, NSBundle.mainBundle, @"AirPlay switching failed. The original route has been kept for safe cleanup.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
    } @finally {
        @try {
            if (!isShuttingDown() && capturedHALAttempted && !success) [self rollbackCapturedOutput:capturedTargetUID toLocalUID:capturedReturnLocalUID performIfRunning:performIfRunning];
            if (!isShuttingDown() && attemptedThisCall && !success && _transaction.owned) { _transaction.mustClean = YES; [self rollbackOwnOutputPerformIfRunning:performIfRunning]; [self reconcile:NULL isShuttingDown:isShuttingDown performIfRunning:performIfRunning]; }
        } @catch (NSException *exception) { _diagnostics[@"cleanupException"] = exception.name; }
        _busy = NO;
    }
}
- (BOOL)prepareToLeaveWithError:(NSError **)error {
    if (![self enter:error]) return NO;
    @try { if ([self ensure:NULL]) [self capture]; return YES; }
    @catch (NSException *exception) { _diagnostics[@"captureException"] = exception.name; return YES; }
    @finally { _busy = NO; }
}
- (BOOL)reconcileRuntimeStateIsShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(THAudioMutationGate)performIfRunning error:(NSError **)error {
    if (![self enter:error]) return NO;
    @try {
        if (isShuttingDown() || !_transaction.owned) return YES;
        [self settleCompletedOperation];
        return [self reconcile:error isShuttingDown:isShuttingDown performIfRunning:performIfRunning waitForCompletion:NO];
    } @catch (NSException *exception) {
        _diagnostics[@"cleanupException"] = exception.name;
        return [self deferCleanup:error reason:@"runtimeCleanupException" pending:NO];
    } @finally { _busy = NO; }
}
- (BOOL)completedLeaveIsShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(THAudioMutationGate)performIfRunning error:(NSError **)error {
    if (![self enter:error]) return NO;
    @try {
        if (!_transaction.owned) return YES;
        NSTimeInterval end = [_runtime uptime] + 3;
        while (!isShuttingDown() && ![self localUnselected] && [_runtime uptime] < end) THRPump(_runtime);
        if ([self reconcile:error isShuttingDown:isShuttingDown performIfRunning:performIfRunning]) return YES;
        if (error && !*error) *error = THRError(THRetainedAudioErrorCleanupUnconfirmed, NSLocalizedStringWithDefaultValue(@"native.retained.cleanup_waiting", nil, NSBundle.mainBundle, @"The previous AirPlay reference has been kept until safe cleanup can be confirmed.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
    } @catch (NSException *exception) {
        _diagnostics[@"cleanupException"] = exception.name;
        if (error) *error = THRError(THRetainedAudioErrorCleanupException, NSLocalizedStringWithDefaultValue(@"native.retained.cleanup_exception", nil, NSBundle.mainBundle, @"Cleanup conditions could not be confirmed. The original route reference has been kept.", @"AirPlay status or error shown to the user."), _diagnostics); return NO;
    } @finally { _busy = NO; }
}
// An explicit failed selection owns this continuation. Ordinary observation,
// capture and termination never enter it or perform route cleanup themselves.
- (BOOL)finishFailedSelectionIsShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(THAudioMutationGate)performIfRunning error:(NSError **)error {
    if (![self enter:error]) return NO;
    @try {
        if (isShuttingDown() || !_transaction.mustClean) return YES;
        if (_transaction.removeSubmissionFailed) return [self deferCleanup:error reason:@"removeSubmissionFailed" pending:NO];
        BOOL pending = (_transaction.add && !atomic_load(&_transaction.add->done)) || (_transaction.remove && !atomic_load(&_transaction.remove->done));
        if (pending) {
            if (error) *error = THRError(THRetainedAudioErrorPending, NSLocalizedStringWithDefaultValue(@"native.retained.callback_pending", nil, NSBundle.mainBundle, @"Waiting for the submitted connection operation to return.", @"AirPlay status or error shown to the user."), _diagnostics);
            return NO;
        }
        if ([self reconcile:NULL isShuttingDown:isShuttingDown performIfRunning:performIfRunning]) return YES;
        pending = (_transaction.add && !atomic_load(&_transaction.add->done)) || (_transaction.remove && !atomic_load(&_transaction.remove->done));
        if (error) *error = THRError(pending ? THRetainedAudioErrorPending : THRetainedAudioErrorCleanupBlocked, NSLocalizedStringWithDefaultValue(@"native.retained.failed_cleanup_unconfirmed", nil, NSBundle.mainBundle, @"Safe cleanup of the failed connection could not be confirmed.", @"AirPlay status or error shown to the user."), _diagnostics);
        return NO;
    } @catch (NSException *exception) {
        _diagnostics[@"cleanupException"] = exception.name;
        if (error) *error = THRError(THRetainedAudioErrorCleanupBlocked, NSLocalizedStringWithDefaultValue(@"native.retained.failed_cleanup_error", nil, NSBundle.mainBundle, @"An internal error occurred while finishing the failed connection.", @"AirPlay status or error shown to the user."), _diagnostics);
        return NO;
    } @finally { _busy = NO; }
}
// Read-only quit preflight proves local ownership. Removal remains on the
// regular HAL-leave/Remove path after the user confirms the quit plan.
- (NSString *)exitRemovalLedgerRejection {
    if (_closed) return @"bridgeClosed";
    if (!_transaction.owned) return @"noOwnedAdd";
    THROperation *add = _transaction.add;
    if (!add) return @"addOperationMissing";
    if (!atomic_load(&add->done)) return @"addCallbackPending";
    if (!atomic_load(&add->objectsMatch)) return @"addCallbackIdentityMismatch";
    if (atomic_load(&add->status) != 0) return @"addCallbackFailed";
    if (add->aggregate != _session.aggregate || add->leaf != _session.leaf ||
        add->context != _session.context || add->manager != _session.manager) return @"addReferencesChanged";
    if (!THRString(_transaction.ownStreamUID)) return @"ownStreamNotWitnessed";
    return nil;
}
- (NSString *)exitRemovalRejectionForView:(NSDictionary *)view {
    NSString *ledgerRejection = [self exitRemovalLedgerRejection];
    if (ledgerRejection) return ledgerRejection;
    if (!view || _session.invalidated) return @"retainedRouteInvalid";
    if ([self empty:view]) return @"ownStreamAlreadyAbsent";
    if (!THOwnedAirPlayStreamMatches(_transaction.ownStreamUID, [self stream:view])) return @"ownStreamIdentityChanged";
    if (!THRLeafIdentity(_runtime, _session.leaf, _session.identifier, _diagnostics)) return @"leafIdentityChanged";
    if (![self selected:view] && ![self localUnselected]) return @"outputIdentityUnconfirmed";
    return nil;
}
// Quit must not turn a previous Remove's empty intermediate observation into
// completion. A rejected/pending capsule is not permission to submit again.
- (NSString *)quitRemovalRejection {
    if (_transaction.removeSubmissionFailed) return @"removeSubmissionFailed";
    THROperation *remove = _transaction.remove;
    if (!remove) return _transaction.removeAttempted ? @"removeOperationMissing" : nil;
    if (!atomic_load(&remove->done)) return @"removeCallbackPending";
    if (!atomic_load(&remove->objectsMatch)) return @"removeCallbackIdentityMismatch";
    if (atomic_load(&remove->status) != 0) return @"removeCallbackFailed";
    if (remove->aggregate != _session.aggregate || remove->leaf != _session.leaf ||
        remove->context != _session.context || remove->manager != _session.manager) return @"removeReferencesChanged";
    return nil;
}
- (NSDictionary<NSString *, id> *)ownedStreamForExitWithError:(NSError **)error {
    if (![self enter:error]) return nil;
    @try {
        if (!_transaction.owned) return @{@"ownedStream":NSNull.null};
        NSString *rejection = [self exitRemovalLedgerRejection];
        if (!rejection) rejection = [self quitRemovalRejection];
        NSDictionary *view = rejection ? nil : [self heldView];
        if (!rejection && [self empty:view] && [self confirmEmptyView:view requireLocal:NO])
            return @{@"ownedStream":NSNull.null};
        if (!rejection && _transaction.remove) rejection = @"removeReadbackUnconfirmed";
        if (!rejection) rejection = [self exitRemovalRejectionForView:view];
        NSDictionary *readback = rejection ? nil : [self heldView];
        if (!rejection && (![readback isEqual:view] || [self exitRemovalRejectionForView:readback]))
            rejection = @"ownershipChangedDuringQuitPreflight";
        if (rejection) {
            _diagnostics[@"quitPreflightRejection"] = rejection;
            BOOL pending = [rejection isEqual:@"addCallbackPending"] || [rejection isEqual:@"removeCallbackPending"] ||
                [rejection isEqual:@"removeReadbackUnconfirmed"];
            BOOL removalFailed = [rejection hasPrefix:@"remove"] && !pending;
            NSString *message = pending ? NSLocalizedStringWithDefaultValue(@"native.retained.quit_pending", nil, NSBundle.mainBundle, @"The previous connection or cleanup operation has not been confirmed complete. The app will keep running. No additional output switch or cleanup request was submitted.", @"AirPlay status or error shown to the user.") :
                removalFailed ? NSLocalizedStringWithDefaultValue(@"native.retained.quit_removal_failed", nil, NSBundle.mainBundle, @"The previous audio stream cleanup failed or returned an unexpected identity, so cleanup cannot be submitted again. The app will keep running. No additional output switch was requested.", @"AirPlay status or error shown to the user.") :
                NSLocalizedStringWithDefaultValue(@"native.retained.quit_cleanup_unconfirmed", nil, NSBundle.mainBundle, @"Cleanup conditions for the old audio stream could not be confirmed. The app did not quit or switch outputs.", @"AirPlay status or error shown to the user.");
            if (error) *error = THRError(pending ? THRetainedAudioErrorPending : THRetainedAudioErrorCleanupBlocked,
                message, _diagnostics);
            return nil;
        }
        return @{@"ownedStream":@{@"receiverID":_session.identifier,
            @"name":_session.name ?: _session.identifier, @"streamUID":_transaction.ownStreamUID}};
    } @catch (NSException *exception) {
        _diagnostics[@"quitPreflightException"] = exception.name;
        if (error) *error = THRError(THRetainedAudioErrorCleanupException,
            NSLocalizedStringWithDefaultValue(@"native.retained.quit_read_failed", nil, NSBundle.mainBundle, @"Unable to read the old audio stream state. The app did not quit.", @"AirPlay status or error shown to the user."), _diagnostics);
        return nil;
    } @finally { _busy = NO; }
}
- (BOOL)shutdownWithError:(NSError **)error {
    if (![self enter:error]) return NO;
    @try {
        _closed = YES;
        // Termination owns references and subscriptions, never the system route.
        // Submitted callbacks hold their own capsule reference until completion;
        // releasing our reference cannot free their refcon or issue route writes.
        [self clearOwnership];
        [self releaseHeld];
        [_session releaseAll];
        [self event:@"releasedApplicationReferences" status:0];
        return YES;
    } @finally { _busy = NO; }
}

@end

