#import "THPrivateDeviceEvidence.h"
#import "THPrivateAudioRuntime.h"
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL THDeviceEvidenceMatches(id device, NSString *name, const char *encoding) {
    Method method = device ? class_getInstanceMethod(object_getClass(device), NSSelectorFromString(name)) : NULL;
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}

static id THDeviceBooleanEvidence(id device, NSString *name) {
    @try {
        if (!THDeviceEvidenceMatches(device, name, "B16@0:8")) return NSNull.null;
        return @(((BOOL (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(name)));
    } @catch (__unused NSException *exception) { return NSNull.null; }
}

NSDictionary<NSString *, id> *THPrivateDeviceTraits(id device) {
    id features = NSNull.null;
    @try {
        if (THDeviceEvidenceMatches(device, @"deviceFeatures", "Q16@0:8")) {
            features = @(((NSUInteger (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"deviceFeatures")));
        }
    } @catch (__unused NSException *exception) { }
    id supportsAudio = features == NSNull.null ? NSNull.null : @((BOOL)(([features unsignedIntegerValue] & 1) != 0));
    return @{@"deviceFeatures":features, @"supportsAudio":supportsAudio,
             @"isCached":THDeviceBooleanEvidence(device, @"isCached"),
             @"isDeviceDisabled":THDeviceBooleanEvidence(device, @"isDeviceDisabled"),
             @"requiresAuthorization":THDeviceBooleanEvidence(device, @"requiresAuthorization")};
}

NSDictionary<NSString *, id> *THPrivateDeviceEligibility(id device) {
    return [THPrivateDeviceTraits(device) dictionaryWithValuesForKeys:
        @[@"supportsAudio", @"isCached", @"isDeviceDisabled", @"requiresAuthorization"]];
}

id THPrivateDeviceIdentifier(id device) {
    @try {
        if (!THDeviceEvidenceMatches(device, @"deviceID", "@16@0:8")) return NSNull.null;
        id value = ((id (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"deviceID"));
        return [value isKindOfClass:NSString.class] && [value length] ? [value copy] : NSNull.null;
    } @catch (__unused NSException *exception) { return NSNull.null; }
}

static id THDeviceStringEvidence(id device, NSString *name) {
    @try {
        if (!THDeviceEvidenceMatches(device, name, "@16@0:8")) return NSNull.null;
        id value = ((id (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(name));
        return [value isKindOfClass:NSString.class] && [value length] ? [value copy] : NSNull.null;
    } @catch (__unused NSException *exception) { return NSNull.null; }
}

NSString *THAudioDeviceSymbolForModelIdentifier(NSString *modelIdentifier, THPrivateAudioRuntime *runtime) {
    @try {
        if (![modelIdentifier isKindOfClass:NSString.class] || !modelIdentifier.length) return nil;
        Class controller = [runtime classNamed:@"MPAVRoutingController"];
        NSString *selector = @"_symbolNameForModelID:";
        if (!THDeviceEvidenceMatches(controller, selector, "@24@0:8@16")) return nil;
        id value = ((id (*)(id, SEL, id))objc_msgSend)(controller, NSSelectorFromString(selector), modelIdentifier);
        return [value isKindOfClass:NSString.class] && [value length] ? [value copy] : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

NSDictionary<NSString *, id> *THPrivateDeviceIconEvidence(id device, THPrivateAudioRuntime *runtime) {
    id identifier = THPrivateDeviceIdentifier(device);
    id model = THDeviceStringEvidence(device, @"modelID");
    id directSymbol = THDeviceStringEvidence(device, @"routeSymbolName");
    id modelReadback = THDeviceStringEvidence(device, @"modelID");
    id symbolReadback = THDeviceStringEvidence(device, @"routeSymbolName");
    id identifierReadback = THPrivateDeviceIdentifier(device);
    BOOL identityStable = identifier != NSNull.null && [identifier isEqual:identifierReadback];
    BOOL modelStable = model != NSNull.null && [model isEqual:modelReadback];
    BOOL directStable = directSymbol != NSNull.null && [directSymbol isEqual:symbolReadback];
    id symbol = identityStable && directStable ? directSymbol : NSNull.null;
    if (identityStable && symbol == NSNull.null && modelStable)
        symbol = THAudioDeviceSymbolForModelIdentifier(model, runtime) ?: NSNull.null;
    return @{@"identifier":identifier, @"readbackIdentifier":identifierReadback,
             @"readbackStable":@(identityStable), @"modelIdentifier":modelStable ? model : NSNull.null,
             @"symbolName":symbol};
}
