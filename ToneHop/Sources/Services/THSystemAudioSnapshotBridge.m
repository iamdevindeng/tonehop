#import "THSystemAudioSnapshotBridge.h"
#import "THPrivateAudioRuntime.h"
#import "THPrivateAudioErrors.h"
#import <CoreAudio/CoreAudio.h>

typedef SInt32 (*THSCopyBuffered)(CFTypeRef, CFStringRef, CFTypeRef *);
typedef CFTypeID (*THSTypeID)(void);

static BOOL THSTyped(CFTypeRef object, THSTypeID type) {
    return object && type && CFGetTypeID(object) == type();
}
static BOOL THSHasType(id value, CFTypeID type) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == type;
}
static BOOL THSString(id value) { return THSHasType(value, CFStringGetTypeID()) && [value length] > 0; }
static BOOL THSFlag(id value, BOOL expected) {
    // ShowInfo uses CFNumber on some builds and CFBoolean on others.
    return (THSHasType(value, CFBooleanGetTypeID()) || THSHasType(value, CFNumberGetTypeID())) &&
        [value isEqual:@(expected)];
}
static CFStringRef THSKey(THPrivateAudioRuntime *runtime, const char *name) { return [runtime key:name]; }
static NSString *THSSymbol(THPrivateAudioRuntime *runtime, const void *function) { return [runtime symbolName:function]; }
static id THSRead(THPrivateAudioRuntime *runtime, CFTypeRef object, const char *name, NSMutableDictionary *diagnostics) {
    return [runtime readProperty:object name:name diagnostics:diagnostics recordSuccess:NO];
}
static id THSField(THPrivateAudioRuntime *runtime, NSDictionary *dictionary, const char *name) {
    CFStringRef key = THSKey(runtime, name);
    return key ? dictionary[(__bridge NSString *)key] : nil;
}
static NSDictionary *THSResult(NSDictionary *selection, NSMutableDictionary *diagnostics, NSString *state) {
    diagnostics[@"state"] = state;
    return @{@"selection":selection ?: (id)NSNull.null, @"isUnselectedConfirmed":@NO, @"diagnostics":[diagnostics copy]};
}

static NSArray<NSString *> *THSAudioUIDs(THPrivateAudioRuntime *runtime, CFTypeRef aggregate, NSMutableDictionary *diagnostics, NSString **failure) {
    id streams = THSRead(runtime, aggregate, "kFigEndpointProperty_Streams", diagnostics);
    CFStringRef audioType = THSKey(runtime, "kFigEndpointStreamType_Audio");
    if (!THSHasType(streams, CFArrayGetTypeID()) || !audioType) {
        *failure = @"invalidStreams";
        return nil;
    }
    NSMutableArray<NSString *> *audioUIDs = [NSMutableArray array];
    for (id object in streams) {
        CFTypeRef stream = (__bridge CFTypeRef)object;
        if (!THSTyped(stream, runtime.functions.streamType)) { *failure = @"invalidStreamObject"; return nil; }
        id type = THSRead(runtime, stream, "kFigEndpointStreamProperty_Type", diagnostics);
        if (!THSString(type)) { *failure = @"invalidStreamType"; return nil; }
        if (![type isEqual:(__bridge id)audioType]) continue;
        id uid = THSRead(runtime, stream, "kFigEndpointStreamProperty_ID", diagnostics);
        if (!THSString(uid)) { *failure = @"invalidAudioStreamID"; return nil; }
        [audioUIDs addObject:[uid copy]];
    }
    if (audioUIDs.count != 1) { *failure = @"ambiguousAudioStreams"; return nil; }
    return [audioUIDs copy];
}

static NSDictionary<NSString *, NSString *> *THSMember(THPrivateAudioRuntime *runtime, CFTypeRef manager, NSString *aggregateID,
                                                       NSString *contextID, NSMutableDictionary *diagnostics,
                                                       NSString **failure) {
    id show = THSRead(runtime, manager, "kAPEndpointManagerProperty_ShowInfo", diagnostics);
    if (!THSHasType(show, CFDictionaryGetTypeID())) { *failure = @"invalidManagerShowInfo"; return nil; }
    id groups = THSField(runtime, show, "kAPEndpointManagerShowInfoKey_AggregateShowInfos");
    if (!THSHasType(groups, CFArrayGetTypeID())) { *failure = @"invalidAggregateArray"; return nil; }
    NSMutableArray *matches = [NSMutableArray array];
    for (id group in groups) {
        if (!THSHasType(group, CFDictionaryGetTypeID())) { *failure = @"invalidAggregateRow"; return nil; }
        if ([THSField(runtime, group, "kAPEndpointShowInfoKey_EndpointID") isEqual:aggregateID]) [matches addObject:group];
    }
    if (matches.count != 1) { *failure = @"ambiguousAggregateIdentity"; return nil; }
    NSDictionary *group = matches[0];
    if (![THSField(runtime, group, "kAPEndpointShowInfoKey_RoutingContextID") isEqual:contextID] ||
        !THSFlag(THSField(runtime, group, "kAPEndpointShowInfoKey_Activated"), YES) ||
        !THSFlag(THSField(runtime, group, "kAPEndpointShowInfoKey_IsRemoteControlEndpoint"), NO)) {
        *failure = @"managerAggregateMismatch";
        return nil;
    }
    id members = THSField(runtime, group, "kAPEndpointShowInfoKey_SubEndpointShowInfoDicts");
    if (!THSHasType(members, CFArrayGetTypeID()) || [members count] != 1) {
        *failure = @"ambiguousOrMissingMembers";
        return nil;
    }
    id member = members[0];
    if (!THSHasType(member, CFDictionaryGetTypeID()) ||
        !THSFlag(THSField(runtime, member, "kAPEndpointShowInfoKey_IsRemoteControlEndpoint"), NO) ||
        !THSFlag(THSField(runtime, member, "kAPEndpointShowInfoKey_Activated"), YES)) {
        *failure = @"invalidAudioMember";
        return nil;
    }
    id identifier = THSField(runtime, member, "kAPEndpointShowInfoKey_DeviceID");
    id name = THSField(runtime, member, "kAPEndpointShowInfoKey_Name");
    if (!THSString(identifier) || !THSString(name)) { *failure = @"invalidMemberIdentity"; return nil; }
    return @{@"identifier":[identifier copy], @"name":[name copy]};
}

static id THSHALString(THPrivateAudioRuntime *runtime, AudioObjectID object, AudioObjectPropertySelector selector) { return [runtime halString:object selector:selector]; }
static BOOL THSHALScalar(THPrivateAudioRuntime *runtime, AudioObjectID object, AudioObjectPropertySelector selector, UInt32 *value) { return [runtime halScalar:object selector:selector value:value]; }
static NSString *THSDefaultAirPlayUID(THPrivateAudioRuntime *runtime) {
    UInt32 device = 0, transport = 0, alive = 0;
    if (!THSHALScalar(runtime, kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, &device) ||
        !THSHALScalar(runtime, device, kAudioDevicePropertyTransportType, &transport) || transport != kAudioDeviceTransportTypeAirPlay ||
        !THSHALScalar(runtime, device, kAudioDevicePropertyDeviceIsAlive, &alive) || !alive) return nil;
    id uid = THSHALString(runtime, device, kAudioDevicePropertyDeviceUID);
    return THSString(uid) ? uid : nil;
}

@implementation THSystemAudioSnapshotBridge {
    THPrivateAudioRuntime *_runtime;
}
- (instancetype)init { return [self initWithRuntime:THPrivateAudioRuntime.systemRuntime]; }
- (instancetype)initWithRuntime:(THPrivateAudioRuntime *)runtime {
    if ((self = [super init])) _runtime = runtime;
    return self;
}
- (NSDictionary<NSString *,id> *)snapshotWithError:(NSError **)error {
    if (!_runtime.functions.copyContext || !_runtime.functions.copyManager || !_runtime.functions.getVTable || !_runtime.functions.contextType ||
        !_runtime.functions.endpointType || !_runtime.functions.streamType || !_runtime.functions.managerType) {
        if (error) *error = [NSError errorWithDomain:THSystemAudioSnapshotErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey:NSLocalizedStringWithDefaultValue(@"native.snapshot.unavailable", nil, NSBundle.mainBundle, @"Reading the selected AirPlay route is unavailable on this system.", @"AirPlay status or error shown to the user.")}];
        return nil;
    }
    NSMutableDictionary *diagnostics = [NSMutableDictionary dictionary];
    CFTypeRef context = NULL, aggregate = NULL, manager = NULL, repeated = NULL;
    @try {
        SInt32 status = [_runtime copyContext:kCFAllocatorDefault options:NULL output:&context];
        diagnostics[@"contextStatus"] = @(status);
        if (status || !THSTyped(context, _runtime.functions.contextType)) return THSResult(nil, diagnostics, @"contextUnavailable");
        const void * const *table = _runtime.functions.getVTable(context);
        const void * const *routing = table ? table[2] : NULL;
        if (!routing || (uintptr_t)routing[0] != 1 ||
            ![THSSymbol(_runtime, routing[18]) isEqual:@"routingContextRemoteXPC_CopySelectedBufferedEndpoint"])
            return THSResult(nil, diagnostics, @"unsupportedContextABI");
        THSCopyBuffered copyBuffered = (THSCopyBuffered)routing[18];
        id contextType = THSRead(_runtime, context, "kFigRoutingContextProperty_ContextType", diagnostics);
        id contextID = THSRead(_runtime, context, "kFigRoutingContextProperty_ContextUUID", diagnostics);
        if (!THSHasType(contextType, CFNumberGetTypeID()) || ![contextType isEqual:@1] || !THSString(contextID))
            return THSResult(nil, diagnostics, @"invalidSystemContext");
        status = copyBuffered(context, NULL, &aggregate);
        diagnostics[@"selectedBufferedStatus"] = @(status);
        if (!status && !aggregate) {
            NSMutableDictionary *result = [THSResult(nil, diagnostics, @"noSelectedAggregate") mutableCopy];
            result[@"isUnselectedConfirmed"] = @YES;
            return result;
        }
        if (status || !THSTyped(aggregate, _runtime.functions.endpointType)) return THSResult(nil, diagnostics, @"invalidSelectedAggregate");

        id aggregateID = THSRead(_runtime, aggregate, "kFigEndpointProperty_ID", diagnostics);
        id aggregateType = THSRead(_runtime, aggregate, "kFigEndpointProperty_Type", diagnostics);
        id aggregateContextID = THSRead(_runtime, aggregate, "kFigEndpointProperty_RoutingContextUUID", diagnostics);
        id active = THSRead(_runtime, aggregate, "kFigEndpointProperty_IsActivated", diagnostics);
        id remote = THSRead(_runtime, aggregate, "kFigEndpointProperty_IsRemoteControlOnly", diagnostics);
        CFStringRef airPlayAggregate = THSKey(_runtime, "kFigEndpointType_AirPlayAggregate");
        if (!THSString(aggregateID) || !airPlayAggregate || ![aggregateType isEqual:(__bridge id)airPlayAggregate] ||
            ![aggregateContextID isEqual:contextID] || !THSFlag(active, YES) || !THSFlag(remote, NO))
            return THSResult(nil, diagnostics, @"aggregateIdentityUnconfirmed");

        NSString *failure = nil;
        NSArray<NSString *> *audioUIDs = THSAudioUIDs(_runtime, aggregate, diagnostics, &failure);
        if (!audioUIDs) return THSResult(nil, diagnostics, failure);

        status = [_runtime copyManager:&manager];
        diagnostics[@"managerStatus"] = @(status);
        if (status || !THSTyped(manager, _runtime.functions.managerType)) return THSResult(nil, diagnostics, @"managerUnavailable");
        NSDictionary<NSString *, NSString *> *member = THSMember(_runtime, manager, aggregateID, contextID, diagnostics, &failure);
        if (!member) return THSResult(nil, diagnostics, failure);
        NSString *memberID = member[@"identifier"], *name = member[@"name"];

        id associated = THSRead(_runtime, context, "kFigRoutingContextProperty_AssociatedAudioDevice", diagnostics);
        NSString *halUID = THSDefaultAirPlayUID(_runtime);
        NSString *streamUID = audioUIDs[0];
        if (![associated isEqual:streamUID] || ![halUID isEqual:streamUID])
            return THSResult(nil, diagnostics, @"selectedHALMismatch");
        // Re-read selection, membership and streams: an aggregate can keep its
        // identity while its receiver membership changes. Finish with current HAL.
        // CopyRoutes may be empty on the verified aggregate path and is not a gate.
        status = copyBuffered(context, NULL, &repeated);
        if (status || !THSTyped(repeated, _runtime.functions.endpointType) ||
            ![THSRead(_runtime, repeated, "kFigEndpointProperty_ID", diagnostics) isEqual:aggregateID] ||
            ![THSRead(_runtime, repeated, "kFigEndpointProperty_RoutingContextUUID", diagnostics) isEqual:contextID] ||
            !THSFlag(THSRead(_runtime, repeated, "kFigEndpointProperty_IsActivated", diagnostics), YES) ||
            !THSFlag(THSRead(_runtime, repeated, "kFigEndpointProperty_IsRemoteControlOnly", diagnostics), NO))
            return THSResult(nil, diagnostics, @"selectionChangedDuringRead");
        NSArray<NSString *> *repeatedUIDs = THSAudioUIDs(_runtime, repeated, diagnostics, &failure);
        NSDictionary<NSString *, NSString *> *repeatedMember = THSMember(_runtime, manager, aggregateID, contextID, diagnostics, &failure);
        if (!repeatedUIDs || !repeatedMember) {
            diagnostics[@"repeatedEvidenceFailure"] = failure;
            return THSResult(nil, diagnostics, @"selectionChangedDuringRead");
        }
        if (![repeatedUIDs isEqual:audioUIDs] || ![repeatedMember isEqual:member] ||
            ![THSRead(_runtime, context, "kFigRoutingContextProperty_AssociatedAudioDevice", diagnostics) isEqual:streamUID] ||
            ![THSDefaultAirPlayUID(_runtime) isEqual:streamUID])
            return THSResult(nil, diagnostics, @"selectionChangedDuringRead");

        NSDictionary *selection = @{@"identifier":memberID, @"name":name, @"uid":streamUID,
            @"aggregateIdentifier":aggregateID, @"contextIdentifier":contextID,
            @"aggregateContextIdentifier":aggregateContextID, @"associatedUID":associated,
            @"halUID":halUID, @"audioStreamUIDs":audioUIDs,
            @"memberIdentifiers":@[memberID], @"readbackStable":@YES};
        diagnostics[@"association"] = selection;
        return THSResult(selection, diagnostics, @"verifiedSelectedAggregate");
    } @catch (NSException *exception) {
        diagnostics[@"exception"] = exception.name;
        return THSResult(nil, diagnostics, @"readFailed");
    } @finally {
        if (repeated) CFRelease(repeated);
        if (manager) CFRelease(manager);
        if (aggregate) CFRelease(aggregate);
        if (context) CFRelease(context);
    }
}
@end
