#import "THPrivateEndpointBridge.h"
#import "THPrivateAudioRuntime.h"
#import "THPrivateAudioErrors.h"
#import "THPrivateDeviceEvidence.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>

typedef SInt32 (*THEPropertyCopy)(CFTypeRef, CFStringRef, CFAllocatorRef, CFTypeRef *);
typedef SInt32 (*THEModeSet)(CFTypeRef, CFStringRef, CFDictionaryRef);
static const NSTimeInterval THERecoveryRetryInterval = 3;
static const NSTimeInterval THERecoveryBackoffInterval = 30;

static CFStringRef THEKey(THPrivateAudioRuntime *runtime, NSString *symbol) {
    return [runtime coreMediaKey:symbol.UTF8String];
}

static NSError *THEError(NSInteger code, NSString *message, NSDictionary *diagnostics) {
    return [NSError errorWithDomain:THPrivateEndpointErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message, @"diagnostics":diagnostics}];
}

static NSDictionary<NSString *, NSString *> *THESetModeVerification(THPrivateAudioRuntime *runtime,
                                                                   const void * const *managerClass) {
    NSString *state, *symbol = @"";
    if (!managerClass) state = @"missingTable";
    else if ((uintptr_t)managerClass[0] != 1) state = @"versionMismatch";
    else if (!managerClass[1]) state = @"nullSlot";
    else {
        symbol = [runtime symbolName:managerClass[1]];
        // Observed with dladdr on macOS 27.0.1 (26A434). Other slots and the
        // containing image are not part of this call's verification policy.
        if (!symbol.length) state = @"symbolUnresolved";
        else if ([symbol isEqualToString:@"FigEndpointManagerRemoteXPC_SetDiscoveryMode"]) state = @"verified";
        else state = @"symbolMismatch";
    }
    return @{@"state":state, @"symbol":symbol,
        @"action":[state isEqualToString:@"verified"] ? @"allowed" : @"skipped",
        @"osVersion":NSProcessInfo.processInfo.operatingSystemVersionString};
}

static void THELogUnverifiedSetMode(NSDictionary<NSString *, NSString *> *verification) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        os_log_t log = os_log_create("com.dengziyi.ToneHop", "EndpointDiscovery");
        os_log_error(log, "SetDiscoveryMode verification: state=%{public}@ symbol=%{public}@ action=%{public}@ osVersion=%{public}@",
            verification[@"state"], verification[@"symbol"], verification[@"action"], verification[@"osVersion"]);
    });
}

static id THERead(THPrivateAudioRuntime *runtime, CFTypeRef object, NSString *symbol, THEPropertyCopy function,
                  CFTypeID expectedType, NSMutableDictionary *status, NSString *field) {
    CFStringRef key = THEKey(runtime, symbol);
    if (!function || !key) {
        status[field] = @{@"state":@"missingSymbol", @"symbol":symbol};
        return NSNull.null;
    }
    CFTypeRef value = NULL;
    @try {
        SInt32 result = function(object, key, kCFAllocatorDefault, &value);
        BOOL valid = value && CFGetTypeID(value) == expectedType;
        status[field] = @{@"status":@(result), @"state":result ? @"readFailed" :
            (value ? (valid ? @"value" : @"unexpectedType") : @"null")};
        if (result || !valid) return NSNull.null;
        id copiedValue = CFBridgingRelease(value);
        value = NULL;
        return copiedValue;
    } @catch (NSException *exception) {
        // A single raw getter failure leaves this field unknown. Manager
        // callers still receive no value and retain their recovery boundary.
        status[field] = @{@"state":@"readFailed", @"exception":exception.name};
        return NSNull.null;
    } @finally {
        if (value) CFRelease(value);
    }
}

static id THEReadBoolean(THPrivateAudioRuntime *runtime, CFTypeRef object, NSString *name, NSMutableDictionary *status, NSString *field) {
    NSString *symbol = [@"kFigEndpointProperty_" stringByAppendingString:name];
    CFStringRef key = THEKey(runtime, symbol);
    if (!runtime.functions.getBoolean || !key) {
        status[field] = @{@"state":@"missingSymbol", @"symbol":symbol};
        return NSNull.null;
    }
    Boolean wasNull = true, value = false;
    @try {
        SInt32 result = runtime.functions.getBoolean(object, key, &wasNull, &value);
        status[field] = @{@"status":@(result), @"state":result ? @"readFailed" : (wasNull ? @"null" : @"value")};
        return result || wasNull ? NSNull.null : @((BOOL)(value != false));
    } @catch (NSException *exception) {
        status[field] = @{@"state":@"readFailed", @"exception":exception.name};
        return NSNull.null;
    }
}

static BOOL THEMatches(id target, NSString *name, const char *encoding) {
    Method method = target ? class_getInstanceMethod(object_getClass(target), NSSelectorFromString(name)) : NULL;
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}

static void THEAddDeviceTraits(THPrivateAudioRuntime *runtime, CFTypeRef endpoint, NSMutableDictionary *row, NSMutableDictionary *status) {
    Class deviceClass = [runtime classNamed:@"AVOutputDevice"];
    NSString *selector = @"outputDeviceWithFigEndpoint:";
    id device = nil;
    @try {
        if (runtime.avRoutingAvailable && THEMatches(deviceClass, selector, "@24@0:8^{OpaqueFigEndpoint=}16"))
            device = ((id (*)(id, SEL, CFTypeRef))objc_msgSend)(deviceClass, NSSelectorFromString(selector), endpoint);
    } @catch (NSException *exception) { status[@"wrapper"] = @{@"state":@"readFailed", @"exception":exception.name}; }
    id rawEndpointIdentifier = row[@"identifier"];
    id endpointIdentifier = [rawEndpointIdentifier isKindOfClass:NSString.class] ? [rawEndpointIdentifier copy] : NSNull.null;
    id avIdentifier = THPrivateDeviceIdentifier(device);
    NSDictionary *traits = THPrivateDeviceTraits(device);
    for (NSString *field in @[@"deviceFeatures", @"isDeviceDisabled", @"requiresAuthorization", @"wrapperIsCached"]) {
        NSString *selectorName = [field isEqualToString:@"wrapperIsCached"] ? @"isCached" : field;
        row[field] = traits[selectorName];
        status[field] = @{@"state":traits[selectorName] == NSNull.null ? @"unavailableWrapperEvidence" : @"value"};
    }
    // Preserve the independent second eligibility observation. The adapter
    // merges restrictions from both samples, so a getter changing to denied
    // during this read cannot be hidden by reusing the first traits dictionary.
    NSDictionary *eligibility = THPrivateDeviceEligibility(device);
    row[@"deviceEligibility"] = eligibility;
    for (NSString *field in eligibility) {
        status[[@"deviceEligibility." stringByAppendingString:field]] =
            @{@"state":eligibility[field] == NSNull.null ? @"unavailableWrapperEvidence" : @"value"};
    }
    id avReadback = THPrivateDeviceIdentifier(device);
    id endpointReadback = NSNull.null;
    @try {
        endpointReadback = THERead(runtime, endpoint, @"kFigEndpointProperty_ID", runtime.functions.copyString,
                                  CFStringGetTypeID(), status, @"avIdentityEndpointReadback");
    } @catch (__unused NSException *exception) { }
    // The same live endpoint produced this wrapper. Reading both identifiers
    // again makes this an explicit current mapping, not a string-name guess.
    BOOL stable = [endpointIdentifier isKindOfClass:NSString.class] && [endpointIdentifier length] &&
        [avIdentifier isKindOfClass:NSString.class] && [avIdentifier length] &&
        [endpointIdentifier isEqual:endpointReadback] && [avIdentifier isEqual:avReadback];
    row[@"avIdentity"] = @{@"endpointIdentifier":endpointIdentifier,
        @"avDeviceIdentifier":avIdentifier, @"readbackStable":@(stable)};
    // Raw endpoint identity stability is independent of AV wrapper support.
    // A changed/failed second ID cannot prove that a different saved ID is absent.
    BOOL rawIdentityStable = [endpointIdentifier isKindOfClass:NSString.class] && [endpointIdentifier length] &&
        [endpointIdentifier isEqual:endpointReadback];
    row[@"discoveryIdentity"] = @{@"identifier":endpointIdentifier,
        @"readbackIdentifier":endpointReadback, @"readbackStable":@(rawIdentityStable)};
    NSDictionary *wrapperIcon = THPrivateDeviceIconEvidence(device, runtime);
    row[@"iconEvidence"] = wrapperIcon;
    // Some wrappers omit model/symbol getters although the live Fig endpoint
    // supplies its model. This independent, optional double read can still use
    // the system's mapping; it changes no identity or eligibility conclusions.
    if (wrapperIcon[@"symbolName"] == NSNull.null && rawIdentityStable) {
        id model = row[@"model"];
        id modelReadback = THERead(runtime, endpoint, @"kFigEndpointProperty_Model", runtime.functions.copyString,
                                  CFStringGetTypeID(), status, @"iconModelReadback");
        id iconEndpointReadback = THERead(runtime, endpoint, @"kFigEndpointProperty_ID", runtime.functions.copyString,
                                         CFStringGetTypeID(), status, @"iconEndpointReadback");
        if ([model isKindOfClass:NSString.class] && [model length] && [model isEqual:modelReadback] &&
            [endpointIdentifier isEqual:iconEndpointReadback]) {
            NSString *symbol = THAudioDeviceSymbolForModelIdentifier(model, runtime);
            if (symbol) row[@"iconEvidence"] = @{@"identifier":endpointIdentifier,
                @"readbackIdentifier":iconEndpointReadback, @"readbackStable":@YES,
                @"modelIdentifier":[model copy], @"symbolName":symbol};
        }
    }
}

static BOOL THECompleteDeviceEvidence(NSDictionary *row) {
    // Every raw row needs an identity, even when excluded from display, so a
    // hidden unknown row cannot bypass the catalog's duplicate-ID boundary.
    id identifier = row[@"identifier"];
    if (![identifier isKindOfClass:NSString.class] || ![identifier length]) return NO;
    id features = row[@"deviceFeatures"];
    BOOL knownFeatures = features && CFGetTypeID((__bridge CFTypeRef)features) == CFNumberGetTypeID();
    // Match the directory's actual exclusion evidence. An explicitly non-audio,
    // remote-only or cached receiver needs no further data to stay excluded.
    // Missing/unknown flags never prove exclusion, and rows remain in the raw
    // snapshot so their identities still participate in duplicate detection.
    if (knownFeatures && ([features unsignedLongLongValue] & 1) == 0) return YES;
    for (NSString *key in @[@"isRemoteControlOnly", @"wrapperIsCached"]) {
        id value = row[key];
        if (value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue]) return YES;
    }
    id name = row[@"name"];
    if (![name isKindOfClass:NSString.class] || ![name length]) return NO;
    if (!knownFeatures) return NO;
    // The raw IsCached getter is supplementary. Its absence cannot invalidate
    // the wrapper's independently verified cache/eligibility observations.
    for (NSString *key in @[@"isRemoteControlOnly", @"wrapperIsCached", @"isDeviceDisabled", @"requiresAuthorization"]) {
        id value = row[key];
        if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    }
    NSDictionary *eligibility = row[@"deviceEligibility"];
    for (NSString *key in @[@"supportsAudio", @"isCached", @"isDeviceDisabled", @"requiresAuthorization"]) {
        id value = eligibility[key];
        if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    }
    // Explicit restrictions are complete evidence, not a source failure.
    // Optional model/security/transport diagnostics and AV mapping are excluded.
    return YES;
}

static void THECollectFieldIssue(NSMutableDictionary *issues, NSString *field, NSDictionary *status) {
    NSString *state = status[@"state"];
    if (!state || [state isEqualToString:@"value"]) return;
    NSNumber *result = status[@"status"];
    NSString *key = [NSString stringWithFormat:@"%@/%@/%@", field, state, result ?: @""];
    NSMutableDictionary *issue = issues[key];
    if (!issue) {
        issue = [@{@"field":field, @"state":state, @"count":@0} mutableCopy];
        if (result) issue[@"status"] = result;
        issues[key] = issue;
    }
    issue[@"count"] = @([issue[@"count"] unsignedIntegerValue] + 1);
}

static NSArray<NSDictionary *> *THEFieldIssueSummary(NSArray<NSDictionary *> *rows) {
    NSMutableDictionary *issues = [NSMutableDictionary dictionary];
    for (NSDictionary *row in rows) {
        NSDictionary *statuses = row[@"propertyStatus"];
        for (NSString *field in statuses) {
            if ([field isEqualToString:@"streamIdentifiers"]) {
                for (NSDictionary *stream in statuses[field])
                    THECollectFieldIssue(issues, @"streamIdentifiers.identifier", stream[@"identifier"]);
            } else {
                THECollectFieldIssue(issues, field, statuses[field]);
            }
        }
    }
    NSMutableArray *summary = [NSMutableArray array];
    for (NSString *key in [issues.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [summary addObject:[issues[key] copy]];
    return [summary copy];
}

@interface THPrivateEndpointBridge () {
    THPrivateAudioRuntime *_runtime;
    THAudioMutationGate _performIfRunning;
    CFTypeRef _manager;
    THEModeSet _setMode;
    NSUInteger _recoveryFailures;
    NSTimeInterval _nextRecoveryAt, _lastRecoveryAt;
}
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *state;
@end

@implementation THPrivateEndpointBridge
- (instancetype)initWithPerformIfRunning:(THAudioMutationGate)performIfRunning {
    return [self initWithRuntime:THPrivateAudioRuntime.systemRuntime performIfRunning:performIfRunning];
}
- (instancetype)initWithRuntime:(THPrivateAudioRuntime *)runtime performIfRunning:(THAudioMutationGate)performIfRunning {
    if ((self = [super init])) {
        _runtime = runtime; _performIfRunning = [performIfRunning copy]; _lastRecoveryAt = -THERecoveryRetryInterval;
    }
    return self;
}
- (NSDictionary<NSString *,id> *)diagnostics {
    NSMutableDictionary *result = [self.state mutableCopy] ?: [NSMutableDictionary dictionary];
    result[@"active"] = @((BOOL)(_manager != NULL));
    return [result copy];
}

- (void)recordFieldIssuesForRows:(NSArray<NSDictionary *> *)rows incompleteDeviceCount:(NSUInteger)incompleteDeviceCount {
    NSArray<NSDictionary *> *issues = THEFieldIssueSummary(rows);
    BOOL changed = ![self.state[@"fieldIssues"] isEqual:issues] ||
        ![self.state[@"incompleteDeviceCount"] isEqual:@(incompleteDeviceCount)];
    BOOL hadObservation = self.state[@"fieldIssues"] != nil;
    self.state[@"fieldIssues"] = issues;
    self.state[@"incompleteDeviceCount"] = @(incompleteDeviceCount);
    if (!changed || (!hadObservation && !issues.count && !incompleteDeviceCount)) return;
    // Aggregate only fixed field/state labels, numeric statuses and counts.
    // Never log endpoint names/identities or exception-provided strings. Bound
    // output and report only changes, not every three-second observation.
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *issue in [issues subarrayWithRange:NSMakeRange(0, MIN(issues.count, 12))])
        [parts addObject:[NSString stringWithFormat:@"%@:%@(%@)x%@", issue[@"field"], issue[@"state"],
            issue[@"status"] ?: @"unknown", issue[@"count"]]];
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.dengziyi.ToneHop", "EndpointDiscovery"); });
    os_log_with_type(log, OS_LOG_TYPE_INFO, "Endpoint evidence changed: incomplete=%lu issues=%lu fields=%{public}@",
        (unsigned long)incompleteDeviceCount, (unsigned long)issues.count, [parts componentsJoinedByString:@", "]);
}

- (BOOL)startWithError:(NSError **)error {
    if (_manager) return YES;
    self.state = [@{@"mode":@"notStarted", @"managerStatus":NSNull.null,
        @"managerClassVersion":NSNull.null, @"startStatus":NSNull.null,
        @"endpointCount":NSNull.null, @"stopStatus":NSNull.null,
        @"stopAction":NSNull.null} mutableCopy];
    CFStringRef detailed = THEKey(_runtime, @"kFigEndpointManagerDiscoveryMode_DetailedDiscovery");
    if (!_runtime.functions.copyManager || !_runtime.functions.copyArray || !_runtime.functions.copyString || !_runtime.functions.copyNumber || !_runtime.functions.getBoolean ||
        !_runtime.functions.getVTable || !_runtime.functions.managerType || !_runtime.functions.endpointType || !_runtime.functions.streamType ||
        !detailed ||
        !THEKey(_runtime, @"kFigEndpointManagerProperty_AvailableEndpoints")) {
        if (error) *error = THEError(1, NSLocalizedStringWithDefaultValue(@"native.endpoint.interface_incomplete", nil, NSBundle.mainBundle, @"The AirPlay receiver discovery interface is incomplete on this system.", @"AirPlay status or error shown to the user."), self.diagnostics);
        return NO;
    }
    @try {
        SInt32 result = [_runtime copyManager:&_manager];
        self.state[@"managerStatus"] = @(result);
        if (result || !_manager || CFGetTypeID(_manager) != _runtime.functions.managerType()) {
            if (_manager) { CFRelease(_manager); _manager = NULL; }
            if (error) *error = THEError(2, NSLocalizedStringWithDefaultValue(@"native.endpoint.session_failed", nil, NSBundle.mainBundle, @"Unable to create an AirPlay receiver discovery session.", @"AirPlay status or error shown to the user."), self.diagnostics);
            return NO;
        }
        // macOS 27.0.1: vtable[2] is FigEndpointManager class version 1;
        // class[1] is OSStatus SetDiscoveryMode(manager, CFString, CFDictionary).
        const void * const *vtable = _runtime.functions.getVTable(_manager);
        const void * const *managerClass = vtable ? vtable[2] : NULL;
        uintptr_t version = managerClass ? (uintptr_t)managerClass[0] : 0;
        self.state[@"managerClassVersion"] = @(version);
        NSDictionary<NSString *, NSString *> *verification = THESetModeVerification(_runtime, managerClass);
        self.state[@"setDiscoveryModeVerification"] = verification;
        if ([verification[@"state"] isEqualToString:@"verified"]) {
            _setMode = (THEModeSet)managerClass[1];
            __block SInt32 startStatus = NSUserCancelledError;
            // Reference acquisition may have outlived shutdown. Only the actual
            // mode write is registered, through the same gate as route mutations.
            if (!THPerformAudioMutation(_performIfRunning, ^{
                startStatus = self->_setMode(self->_manager, detailed, NULL);
            })) {
                [self stop];
                if (error) *error = THEError(NSUserCancelledError, NSLocalizedStringWithDefaultValue(@"native.endpoint.quitting", nil, NSBundle.mainBundle, @"The app is quitting. AirPlay receiver discovery was not started.", @"AirPlay status or error shown to the user."), self.diagnostics);
                return NO;
            }
            result = startStatus;
            self.state[@"startStatus"] = @(result);
            if (result) {
                [self stop];
                if (error) *error = THEError(4, NSLocalizedStringWithDefaultValue(@"native.endpoint.start_failed", nil, NSBundle.mainBundle, @"The system could not start AirPlay receiver discovery.", @"AirPlay status or error shown to the user."), self.diagnostics);
                return NO;
            }
            self.state[@"mode"] = @"DetailedDiscovery";
        } else {
            // This optional shared-mode request must not disable endpoint reads.
            _setMode = NULL;
            self.state[@"mode"] = @"skippedUnverified";
            THELogUnverifiedSetMode(verification);
        }
        self.state[@"recoveryState"] = @"healthy";
        self.startedAt = NSDate.date;
        return YES;
    } @catch (NSException *exception) {
        [self stop];
        if (error) *error = THEError(5, [NSLocalizedStringWithDefaultValue(@"native.endpoint.start_exception", nil, NSBundle.mainBundle, @"Unable to start AirPlay receiver discovery: ", @"AirPlay status or error shown to the user. Followed by an unlocalized system exception name; preserve the trailing space.") stringByAppendingString:exception.name], self.diagnostics);
        return NO;
    }
}

- (NSArray *)readEndpointsFromManager:(CFTypeRef)manager diagnostics:(NSMutableDictionary *)diagnostics {
    @try {
        id endpoints = THERead(_runtime, manager, @"kFigEndpointManagerProperty_AvailableEndpoints",
            _runtime.functions.copyArray, CFArrayGetTypeID(), diagnostics, @"availableEndpoints");
        return [endpoints isKindOfClass:NSArray.class] ? endpoints : nil;
    } @catch (NSException *exception) {
        diagnostics[@"exception"] = exception.name;
        return nil;
    }
}

- (NSArray<NSString *> *)identitySample:(NSArray *)endpoints diagnostics:(NSMutableDictionary *)diagnostics {
    if (!endpoints) return nil;
    NSMutableArray *identifiers = [NSMutableArray array];
    for (id object in endpoints) {
        CFTypeRef endpoint = (__bridge CFTypeRef)object;
        if (CFGetTypeID(endpoint) != _runtime.functions.endpointType()) return nil;
        id identifier = THERead(_runtime, endpoint, @"kFigEndpointProperty_ID", _runtime.functions.copyString,
            CFStringGetTypeID(), diagnostics, @"endpointIdentifier");
        if (![identifier isKindOfClass:NSString.class] || ![identifier length]) return nil;
        [identifiers addObject:[identifier copy]];
    }
    // Preserve duplicates as evidence; this only checks a stable directory and
    // cannot grant unique identity or selection capability to any receiver.
    return [identifiers sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray *)recoverManager {
    NSTimeInterval now = [_runtime uptime];
    if (now < _nextRecoveryAt) { self.state[@"recoveryState"] = @"backoff"; return nil; }
    _lastRecoveryAt = now;
    _nextRecoveryAt = now + THERecoveryRetryInterval;
    CFTypeRef candidate = NULL;
    NSMutableDictionary *read = [NSMutableDictionary dictionary];
    BOOL replaced = NO;
    @try {
        SInt32 status = [_runtime copyManager:&candidate];
        read[@"managerStatus"] = @(status);
        if (status || !candidate || CFGetTypeID(candidate) != _runtime.functions.managerType()) return nil;
        NSArray *first = [self identitySample:[self readEndpointsFromManager:candidate diagnostics:read] diagnostics:read];
        if (!first) return nil;
        NSArray *endpoints = [self readEndpointsFromManager:candidate diagnostics:read];
        NSArray *second = [self identitySample:endpoints diagnostics:read];
        if (!second || ![first isEqual:second]) { read[@"reason"] = @"directoryChangedDuringRead"; return nil; }
        // Replace only the stale discovery reference. The scoped AV session is
        // still running; a recovery never writes shared Detailed/None or routes.
        CFRelease(_manager); _manager = candidate; candidate = NULL;
        _recoveryFailures = 0;
        replaced = YES;
        self.state[@"recoveryState"] = @"recovered";
        return endpoints;
    } @catch (NSException *exception) {
        read[@"exception"] = exception.name;
        return nil;
    } @finally {
        if (candidate) CFRelease(candidate);
        if (!replaced) {
            _recoveryFailures++;
            _nextRecoveryAt = [_runtime uptime] + (_recoveryFailures >= 3 ? THERecoveryBackoffInterval : THERecoveryRetryInterval);
            self.state[@"recoveryState"] = @"candidateRejected";
        }
        self.state[@"recoveryFailures"] = @(_recoveryFailures);
        self.state[@"recoveryCandidate"] = [read copy];
    }
}

- (NSArray *)availableEndpointReferencesWithError:(NSError **)error {
    if (!_manager) {
        if (error) *error = THEError(9, NSLocalizedStringWithDefaultValue(@"native.endpoint.not_started", nil, NSBundle.mainBundle, @"The AirPlay receiver discovery session has not started.", @"AirPlay status or error shown to the user."), self.diagnostics);
        return nil;
    }
    NSMutableDictionary *read = [NSMutableDictionary dictionary];
    NSArray *endpoints = [self readEndpointsFromManager:_manager diagnostics:read];
    self.state[@"availableEndpoints"] = read[@"availableEndpoints"] ?: @{@"state":@"readFailed"};
    if (endpoints) {
        // An explicitly empty directory is healthy. Do not equate absence of
        // receivers with a dead manager or restart discovery to fill the list.
        _recoveryFailures = 0;
        _nextRecoveryAt = _lastRecoveryAt + THERecoveryRetryInterval;
        self.state[@"recoveryState"] = @"healthy";
        self.state[@"recoveryFailures"] = @0;
    } else {
        self.state[@"recoveryObservation"] = [read copy];
        endpoints = [self recoverManager];
    }
    self.state[@"endpointCount"] = endpoints ? @(endpoints.count) : NSNull.null;
    if (!endpoints && error) *error = THEError(7, NSLocalizedStringWithDefaultValue(@"native.endpoint.list_invalid", nil, NSBundle.mainBundle, @"The system did not return a valid AirPlay receiver list.", @"AirPlay status or error shown to the user."), self.diagnostics);
    return endpoints;
}

- (NSDictionary<NSString *,id> *)snapshotWithError:(NSError **)error {
    if (!_manager && ![self startWithError:error]) return nil;
    @try {
        self.state[@"identityObservations"] = NSNull.null;
        NSArray *endpoints = [self availableEndpointReferencesWithError:error];
        if (!endpoints) return nil;
        NSMutableArray *rows = [NSMutableArray array];
        // Snapshot-local ordinal only: repeated references can be distinguished
        // from distinct endpoint objects without exporting a native pointer.
        NSMutableArray *referenceGroups = [NSMutableArray array];
        NSUInteger incompleteDeviceCount = 0;
        for (id object in endpoints) {
            NSUInteger referenceGroup = [referenceGroups indexOfObjectIdenticalTo:object];
            if (referenceGroup == NSNotFound) {
                referenceGroup = referenceGroups.count;
                [referenceGroups addObject:object];
            }
            CFTypeRef endpoint = (__bridge CFTypeRef)object;
            if (CFGetTypeID(endpoint) != _runtime.functions.endpointType()) {
                [rows addObject:@{@"identifier":NSNull.null, @"name":NSNull.null,
                    @"referenceGroup":@(referenceGroup),
                    @"streamUIDs":@[], @"propertyStatus":@{@"endpoint":@{@"state":@"unexpectedType"}}}];
                incompleteDeviceCount++;
                continue;
            }
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            row[@"referenceGroup"] = @(referenceGroup);
            NSMutableDictionary *status = [NSMutableDictionary dictionary];
            NSDictionary *strings = @{@"identifier":@"ID", @"name":@"Name", @"type":@"Type",
                @"subType":@"SubType", @"model":@"Model", @"routingContextUUID":@"RoutingContextUUID",
                @"authorizationType":@"AuthorizationType"};
            for (NSString *field in strings)
                row[field] = THERead(_runtime, endpoint, [@"kFigEndpointProperty_" stringByAppendingString:strings[field]],
                    _runtime.functions.copyString, CFStringGetTypeID(), status, field);
            NSDictionary *numbers = @{@"supportedFeatures":@"SupportedFeatures", @"activatedFeatures":@"ActivatedFeatures",
                @"airPlaySecurity":@"AirPlaySecurity"};
            for (NSString *field in numbers)
                row[field] = THERead(_runtime, endpoint, [@"kFigEndpointProperty_" stringByAppendingString:numbers[field]],
                    _runtime.functions.copyNumber, CFNumberGetTypeID(), status, field);
            NSDictionary *flags = @{@"isActivated":@"IsActivated", @"isConnected":@"IsConnected", @"isCached":@"IsCached",
                @"isEligibleForAudioDeviceCreation":@"IsEligibleForAudioDeviceCreation", @"isLocalDevice":@"IsLocalDevice",
                @"isRemoteControlOnly":@"IsRemoteControlOnly"};
            for (NSString *field in flags) row[field] = THEReadBoolean(_runtime, endpoint, flags[field], status, field);
            THEAddDeviceTraits(_runtime, endpoint, row, status);
            id streams = THERead(_runtime, endpoint, @"kFigEndpointProperty_Streams", _runtime.functions.copyArray, CFArrayGetTypeID(), status, @"streams");
            NSMutableArray *streamUIDs = [NSMutableArray array];
            NSMutableArray *streamStatus = [NSMutableArray array];
            if ([streams isKindOfClass:NSArray.class]) for (id stream in streams) {
                NSMutableDictionary *readStatus = [NSMutableDictionary dictionary];
                if (CFGetTypeID((__bridge CFTypeRef)stream) == _runtime.functions.streamType()) {
                    id uid = THERead(_runtime, (__bridge CFTypeRef)stream, @"kFigEndpointStreamProperty_ID",
                        _runtime.functions.copyString, CFStringGetTypeID(), readStatus, @"identifier");
                    if ([uid isKindOfClass:NSString.class] && [uid length]) [streamUIDs addObject:uid];
                } else readStatus[@"identifier"] = @{@"state":@"unexpectedType"};
                [streamStatus addObject:readStatus];
            }
            row[@"streamUIDs"] = streamUIDs;
            status[@"streamIdentifiers"] = streamStatus;
            row[@"propertyStatus"] = status;
            if (!THECompleteDeviceEvidence(row)) incompleteDeviceCount++;
            [rows addObject:row];
        }
        NSMutableArray *identityObservations = [NSMutableArray array];
        for (NSDictionary *row in rows) {
            NSMutableDictionary *identity = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"referenceGroup", @"identifier", @"type", @"routingContextUUID",
                    @"streamUIDs", @"isLocalDevice", @"isRemoteControlOnly", @"wrapperIsCached", @"avIdentity"])
                identity[key] = row[key] ?: NSNull.null;
            [identityObservations addObject:[identity copy]];
        }
        // Explicit diagnostics only. These values grant no binding/selection
        // capability and are not added to the anonymous unified-log summary.
        self.state[@"identityObservations"] = [identityObservations copy];
        [self recordFieldIssuesForRows:rows incompleteDeviceCount:incompleteDeviceCount];
        return @{@"endpoints":rows, @"endpointCount":@([endpoints count]),
            @"incompleteDeviceCount":@(incompleteDeviceCount),
            @"diagnostics":self.diagnostics, @"elapsed":@(-self.startedAt.timeIntervalSinceNow)};
    } @catch (NSException *exception) {
        if (error) *error = THEError(8, [NSLocalizedStringWithDefaultValue(@"native.endpoint.read_failed", nil, NSBundle.mainBundle, @"Unable to read AirPlay receivers: ", @"AirPlay status or error shown to the user. Followed by an unlocalized system exception name; preserve the trailing space.") stringByAppendingString:exception.name], self.diagnostics);
        return nil;
    }
}

- (void)stop {
    if (_manager) {
        // This raw setter changes shared browser state, not a per-client lease.
        // Writing None here can override Control Center's ongoing discovery.
        // The owning worker separately stops our scoped AV discovery session.
        CFRelease(_manager);
        _manager = NULL;
        self.state[@"stopAction"] = @"releasedReference";
        self.state[@"mode"] = @"released";
    }
    _setMode = NULL;
    _recoveryFailures = 0;
    _lastRecoveryAt = -THERecoveryRetryInterval;
    _nextRecoveryAt = 0;
    self.startedAt = nil;
}

- (void)dealloc {
    [self stop];
}
@end
