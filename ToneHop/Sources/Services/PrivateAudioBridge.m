#import "PrivateAudioBridge.h"
#import "THPrivateAudioRuntime.h"
#import "THPrivateAudioErrors.h"
#import "THPrivateDeviceEvidence.h"
#import <objc/message.h>
#import <objc/runtime.h>

// These declarations provide ARC's init-family ownership convention, not linkage
// to private classes. Every private call is checked against its runtime ABI.
@protocol THPrivateDiscoveryInitializer
- (instancetype)initWithDeviceFeatures:(NSUInteger)features;
@end


// Verified against this system's routing factory: the system-wide-context
// entitlement check returns this status. Nil alone is not a permission result.
static const SInt32 THSystemContextPermissionDenied = -12029;
typedef struct OpaqueFigRoutingContext *THFigRoutingContextRef;
static NSError *THPrivateError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:THPrivateAudioErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL THMatches(id target, NSString *name, const char *encoding) {
    if (!target) return NO;
    Method method = class_getInstanceMethod(object_getClass(target), NSSelectorFromString(name));
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}
static id THObject(id target, NSString *name) {
    if (!THMatches(target, name, "@16@0:8")) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(name));
}
static NSString *THString(id target, NSString *name) {
    id result = THObject(target, name);
    return [result isKindOfClass:NSString.class] && [result length] ? result : nil;
}
static BOOL THBool(id target, NSString *name, BOOL fallback) {
    if (!THMatches(target, name, "B16@0:8")) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(name));
}
static NSArray *THArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSString *THIdentifier(id device) { return THString(device, @"deviceID"); }

@interface THPrivateAudioBridge ()
@property (nonatomic, strong) id discovery;
@property (nonatomic, strong) id systemContext;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic, copy) NSDictionary<NSString *, id> *devicesByID;
@property (nonatomic, copy) NSString *systemContextFactoryState;
@property (nonatomic, copy) NSString *systemContextFactoryClass;
@property (nonatomic, strong) NSNumber *systemContextFactoryStatus;
@property (nonatomic) NSUInteger systemContextFactoryAttempts;
@property (nonatomic) BOOL systemContextFactoryReturnedContext;
@property (nonatomic) BOOL systemContextPermissionDenied;
@end

@implementation THPrivateAudioBridge {
    THPrivateAudioRuntime *_runtime;
    THAudioMutationGate _performIfRunning;
}
- (instancetype)initWithPerformIfRunning:(THAudioMutationGate)performIfRunning {
    return [self initWithRuntime:THPrivateAudioRuntime.systemRuntime performIfRunning:performIfRunning];
}
- (instancetype)initWithRuntime:(THPrivateAudioRuntime *)runtime performIfRunning:(THAudioMutationGate)performIfRunning {
    if ((self = [super init])) { _runtime = runtime; _performIfRunning = [performIfRunning copy]; }
    return self;
}
- (void)resetSystemContextDiagnostics {
    self.systemContextFactoryState = @"notAttempted";
    self.systemContextFactoryClass = @"unavailable";
    self.systemContextFactoryStatus = nil;
    self.systemContextFactoryAttempts = 0;
    self.systemContextFactoryReturnedContext = NO;
    self.systemContextPermissionDenied = NO;
}

- (void)refreshSystemContext {
    // Entitlements cannot change while this process is running. Suppress only
    // the verified denial; transient errors and unavailable ABIs remain retryable.
    if (self.systemContext || self.systemContextPermissionDenied) return;
    self.systemContext = THObject([_runtime classNamed:@"AVOutputContext"], @"sharedSystemAudioContext");
    if (self.systemContext) return;

    self.systemContextFactoryStatus = nil;
    self.systemContextFactoryReturnedContext = NO;
    id factory = THObject([_runtime classNamed:@"AVFigRoutingContextOutputContextImpl"], @"routingContextFactory");
    self.systemContextFactoryClass = factory ? NSStringFromClass([factory class]) : @"unavailable";
    NSString *selector = @"copySystemAudioContextWithAllocator:options:context:";
    if (!THMatches(factory, selector, "i40@0:8^{__CFAllocator=}16^{__CFDictionary=}24^^{OpaqueFigRoutingContext}32")) {
        self.systemContextFactoryState = factory ? @"unsupportedABI" : @"unavailable";
        return;
    }

    THFigRoutingContextRef context = NULL;
    self.systemContextFactoryAttempts += 1;
    self.systemContextFactoryState = @"calling";
    @try {
        SInt32 status = ((SInt32 (*)(id, SEL, CFAllocatorRef, CFDictionaryRef, THFigRoutingContextRef *))objc_msgSend)(
            factory, NSSelectorFromString(selector), kCFAllocatorDefault, NULL, &context);
        self.systemContextFactoryStatus = @(status);
        self.systemContextFactoryReturnedContext = context != NULL;
        self.systemContextPermissionDenied = status == THSystemContextPermissionDenied;
        self.systemContextFactoryState = self.systemContextPermissionDenied ? @"permissionDenied" :
            (status == 0 ? (context ? @"copiedForDiagnosis" : @"successWithoutContext") : @"retryableFailure");
    } @finally {
        // Copy transfers a CF reference. This is diagnostic only: do not replace
        // the AVOutputContext or change the established selection path.
        if (context) CFRelease(context);
    }
}

- (BOOL)startWithError:(NSError **)error {
    if (self.discovery) return YES;
    [self resetSystemContextDiagnostics];
    @try {
        Class cls = [_runtime classNamed:@"AVOutputDeviceDiscoverySession"];
        Method initializer = class_getInstanceMethod(cls, NSSelectorFromString(@"initWithDeviceFeatures:"));
        if (!_runtime.avRoutingAvailable || !initializer || strcmp(method_getTypeEncoding(initializer), "@24@0:8Q16") != 0) {
            if (error) *error = THPrivateError(1, NSLocalizedStringWithDefaultValue(@"native.discovery.unavailable", nil, NSBundle.mainBundle, @"AirPlay discovery is unavailable on this system.", @"AirPlay status or error shown to the user."));
            return NO;
        }
        id session = [(id<THPrivateDiscoveryInitializer>)[cls alloc] initWithDeviceFeatures:1];
        if (!THMatches(session, @"setDiscoveryMode:", "v24@0:8q16") ||
            !THMatches(session, @"availableOutputDevicesObject", "@16@0:8")) {
            if (error) *error = THPrivateError(2, NSLocalizedStringWithDefaultValue(@"native.discovery.session_failed", nil, NSBundle.mainBundle, @"Unable to create an AirPlay discovery session.", @"AirPlay status or error shown to the user."));
            return NO;
        }
        if (!THPerformAudioMutation(_performIfRunning, ^{
            // Keep a possibly effective/throwing submission for scoped teardown.
            // A rejected gate leaves only the local, unstarted session to release.
            self.discovery = session;
            self.startedAt = NSDate.date;
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(session, NSSelectorFromString(@"setDiscoveryMode:"), 2);
        })) {
            if (error) *error = THPrivateError(NSUserCancelledError, NSLocalizedStringWithDefaultValue(@"native.discovery.quitting", nil, NSBundle.mainBundle, @"The app is quitting. AirPlay discovery was not started.", @"AirPlay status or error shown to the user."));
            return NO;
        }
        [self refreshSystemContext];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = THPrivateError(3, [NSLocalizedStringWithDefaultValue(@"native.discovery.initialization_failed", nil, NSBundle.mainBundle, @"Unable to initialize AirPlay: ", @"AirPlay status or error shown to the user. Followed by an unlocalized system exception name; preserve the trailing space.") stringByAppendingString:exception.name]);
        [self stop];
        return NO;
    }
}

- (NSDictionary<NSString *, id> *)snapshotWithError:(NSError **)error {
    if (!self.discovery && ![self startWithError:error]) return nil;
    @try {
        // Keep this discovery session detailed until stop sets mode 0.
        [self refreshSystemContext];
        id available = THObject(self.discovery, @"availableOutputDevicesObject");
        if (!available || !THMatches(available, @"otherDevices", "@16@0:8")) {
            if (error) *error = THPrivateError(4, NSLocalizedStringWithDefaultValue(@"native.discovery.list_unreadable", nil, NSBundle.mainBundle, @"AirPlay discovery did not return a readable device list.", @"AirPlay status or error shown to the user."));
            return nil;
        }
        id otherValue = THObject(available, @"otherDevices");
        NSArray *other = THArray(otherValue);
        NSArray *recent = THArray(THObject(available, @"recentlyUsedDevices"));
        NSArray *selected = THArray(THObject(self.systemContext, @"outputDevices"));
        NSMutableSet *selectedIDs = [NSMutableSet set];
        NSMutableSet *ambiguousSelectedIDs = [NSMutableSet set];
        for (id device in selected) {
            NSString *identifier = THIdentifier(device);
            if (identifier) {
                if ([selectedIDs containsObject:identifier]) [ambiguousSelectedIDs addObject:identifier];
                [selectedIDs addObject:identifier];
            }
        }
        NSMutableDictionary *devices = [NSMutableDictionary dictionary];
        NSMutableSet *duplicateIDs = [NSMutableSet set];
        NSMutableArray *discoveredIDs = [NSMutableArray array];
        BOOL discoveryIdentityComplete = [otherValue isKindOfClass:NSArray.class];
        for (id device in other) {
            NSString *identifier = THIdentifier(device);
            if (!identifier) { discoveryIdentityComplete = NO; continue; }
            [discoveredIDs addObject:identifier];
            if (![identifier isEqualToString:THIdentifier(device)]) discoveryIdentityComplete = NO;
            if (devices[identifier]) [duplicateIDs addObject:identifier];
            else devices[identifier] = device;
        }
        // A selected device can move out of the discovery group after routing.
        // Keep the context-proven current device by the same private device ID.
        for (id device in selected) {
            NSString *identifier = THIdentifier(device);
            if (identifier && !devices[identifier]) devices[identifier] = device;
        }
        BOOL contextReadable = THMatches(self.systemContext, @"outputDevices", "@16@0:8");
        BOOL contextWritable = contextReadable && THMatches(self.systemContext, @"setOutputDevice:options:", "v32@0:8@16@24");
        NSMutableArray *routes = [NSMutableArray array];
        for (NSString *identifier in devices) {
            id device = devices[identifier];
            NSString *name = THString(device, @"deviceName");
            if (!name || !THMatches(device, @"deviceFeatures", "Q16@0:8")) continue;
            NSUInteger features = ((NSUInteger (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"deviceFeatures"));
            if ((features & 1) == 0) continue;
            // Do not guess transport numbers or claim a MAC address is a HAL UID.
            BOOL selectable = contextWritable && ![duplicateIDs containsObject:identifier] &&
                !THBool(device, @"isCached", YES) && !THBool(device, @"isDeviceDisabled", YES) &&
                !THBool(device, @"requiresAuthorization", YES);
            [routes addObject:@{@"identifier":identifier, @"name":name, @"transport":@"unknown",
                @"isSelected":@([selectedIDs containsObject:identifier]), @"canSelect":@(selectable),
                // This evidence cannot grant AV permission. It distinguishes a
                // missing writable context from an ineligible or ambiguous device
                // when a separately verified retained route is available.
                @"selectionEvidence":@{@"contextWritable":@(contextWritable),
                    @"identityUnique":@((BOOL)(![duplicateIDs containsObject:identifier] && ![ambiguousSelectedIDs containsObject:identifier])),
                    @"deviceEligibility":THPrivateDeviceEligibility(device)},
                @"iconEvidence":THPrivateDeviceIconEvidence(device, _runtime)}];
        }
        self.devicesByID = devices;
        NSString *issue = @"";
        if (self.systemContextPermissionDenied) issue = NSLocalizedStringWithDefaultValue(@"native.discovery.permission_missing", nil, NSBundle.mainBundle, @"This build lacks system audio routing permission. Seamless AirPlay switching is unavailable.", @"AirPlay status or error shown to the user.");
        else if (!contextReadable) issue = NSLocalizedStringWithDefaultValue(@"native.discovery.context_unreadable", nil, NSBundle.mainBundle, @"Network audio devices cannot be read right now. The AirPlay list may be incomplete.", @"AirPlay status or error shown to the user.");
        else if (routes.count == 0) issue = NSLocalizedStringWithDefaultValue(@"native.discovery.list_pending", nil, NSBundle.mainBundle, @"The AirPlay device list is not available yet. Connecting to a device for the first time has not been verified.", @"AirPlay status or error shown to the user.");
        NSString *diagnostics = [NSString stringWithFormat:@"AVRouting: other=%lu, recent=%lu, systemContext=%@, selected=%lu, mode=2, systemContextFactory=%@, factoryStatus=%@, factoryState=%@, factoryAttempts=%lu, factoryReturnedContext=%@; empty results do not prove no devices", (unsigned long)other.count, (unsigned long)recent.count, contextReadable ? @"available" : @"nil", (unsigned long)selected.count, self.systemContextFactoryClass, self.systemContextFactoryStatus ?: @"notAttempted", self.systemContextFactoryState, (unsigned long)self.systemContextFactoryAttempts, self.systemContextFactoryReturnedContext ? @"yes" : @"no"];
        return @{@"routes":routes, @"issue":issue, @"diagnostics":diagnostics, @"elapsed":@(-self.startedAt.timeIntervalSinceNow),
            // Separate raw discovery inventory survives display filtering and
            // deduplication. Recent/retained devices are not live discovery.
            @"discoveryIdentity":@{@"identifiers":[discoveredIDs copy],
                @"conflictedIdentifiers":duplicateIDs.allObjects, @"isComplete":@(discoveryIdentityComplete)}};
    } @catch (NSException *exception) {
        if (error) *error = THPrivateError(5, [NSLocalizedStringWithDefaultValue(@"native.discovery.status_failed", nil, NSBundle.mainBundle, @"Unable to read AirPlay status: ", @"AirPlay status or error shown to the user. Followed by an unlocalized system exception name; preserve the trailing space.") stringByAppendingString:exception.name]);
        return nil;
    }
}

- (BOOL)selectIdentifier:(NSString *)identifier isCancelled:(BOOL (^)(void))isCancelled performIfRunning:(BOOL (^)(void (^operation)(void)))performIfRunning error:(NSError **)error {
    if (isCancelled()) {
        if (error) *error = THPrivateError(8, NSLocalizedStringWithDefaultValue(@"native.selection.request_cancelled", nil, NSBundle.mainBundle, @"The switch request was cancelled.", @"AirPlay status or error shown to the user."));
        return NO;
    }
    NSDictionary *snapshot = [self snapshotWithError:error];
    if (!snapshot) return NO;
    NSDictionary *targetRow = nil;
    for (NSDictionary *row in snapshot[@"routes"]) if ([row[@"identifier"] isEqual:identifier]) { targetRow = row; break; }
    id target = self.devicesByID[identifier];
    if (!target || ![targetRow[@"canSelect"] boolValue]) {
        if (error) *error = THPrivateError(6, NSLocalizedStringWithDefaultValue(@"native.selection.device_unavailable", nil, NSBundle.mainBundle, @"Seamless switching to this AirPlay device is unavailable right now. Refresh and try again.", @"AirPlay status or error shown to the user."));
        return NO;
    }
    @try {
        // Nil options preserve framework defaults. No synthesized descriptor, cached
        // target, guessed name, permission override, or system-panel fallback.
        // A snapshot read may outlive the caller's timeout. Never submit it late.
        if (isCancelled()) {
            if (error) *error = THPrivateError(8, NSLocalizedStringWithDefaultValue(@"native.selection.request_cancelled", nil, NSBundle.mainBundle, @"The switch request was cancelled.", @"AirPlay status or error shown to the user."));
            return NO;
        }
        BOOL submitted = THPerformAudioMutation(performIfRunning, ^{
            ((void (*)(id, SEL, id, id))objc_msgSend)(self.systemContext, NSSelectorFromString(@"setOutputDevice:options:"), target, nil);
        });
        if (!submitted) {
            if (error) *error = THPrivateError(8, NSLocalizedStringWithDefaultValue(@"native.selection.quitting", nil, NSBundle.mainBundle, @"The app is quitting. No switch request was submitted.", @"AirPlay status or error shown to the user."));
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = THPrivateError(7, [NSLocalizedStringWithDefaultValue(@"native.selection.request_failed", nil, NSBundle.mainBundle, @"The AirPlay switch request failed: ", @"AirPlay status or error shown to the user. Followed by an unlocalized system exception name; preserve the trailing space.") stringByAppendingString:exception.name]);
        return NO;
    }
}

- (void)stop {
    @try {
        if (THMatches(self.discovery, @"setDiscoveryMode:", "v24@0:8q16"))
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(self.discovery, NSSelectorFromString(@"setDiscoveryMode:"), 0);
    } @catch (__unused NSException *exception) { }
    self.discovery = nil;
    self.systemContext = nil;
    self.devicesByID = @{};
    self.startedAt = nil;
    [self resetSystemContextDiagnostics];
}
@end
