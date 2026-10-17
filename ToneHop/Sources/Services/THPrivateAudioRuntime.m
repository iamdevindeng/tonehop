#import "THPrivateAudioRuntime.h"
#import <dlfcn.h>
#import <unistd.h>

typedef SInt32 (*THRuntimeCopyProperty)(CFTypeRef, CFStringRef, CFAllocatorRef, CFTypeRef *);

BOOL THPerformAudioMutation(THAudioMutationGate gate, void (^operation)(void)) {
    __block NSException *failure = nil;
    BOOL submitted = gate(^{
        @try { operation(); }
        @catch (NSException *exception) { failure = exception; }
    });
    if (failure) @throw failure;
    return submitted;
}

@implementation THPrivateAudioRuntime {
    CFStringRef (^_keyResolver)(const char *);
    CFStringRef (^_coreMediaKeyResolver)(const char *);
    NSString *(^_symbolResolver)(const void *);
    Class (^_classResolver)(NSString *);
    NSTimeInterval (^_uptime)(void);
    void (^_pump)(NSTimeInterval, useconds_t);
}
+ (instancetype)systemRuntime {
    static THPrivateAudioRuntime *runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Handles and exported-key addresses remain valid for process lifetime.
        void *core = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY | RTLD_LOCAL);
        void *experience = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_LAZY | RTLD_LOCAL);
        void *sender = dlopen("/System/Library/PrivateFrameworks/AirPlaySender.framework/AirPlaySender", RTLD_LAZY | RTLD_LOCAL);
        void *routing = dlopen("/System/Library/Frameworks/AVRouting.framework/AVRouting", RTLD_LAZY | RTLD_LOCAL);
        // Optional, read-only system model-to-symbol mapping. Its absence does
        // not affect discovery, route health, or any write capability.
        dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_LAZY | RTLD_LOCAL);
        THPrivateAudioFunctions functions = {0};
#define TH_LOAD(field, handle, symbol) functions.field = handle ? dlsym(handle, symbol) : NULL
        TH_LOAD(copyContext, experience, "FigRoutingContextRemoteCopySystemAudioContext");
        TH_LOAD(copyManager, core, "FigEndpointManagerRemoteCopyAirPlayManager");
        TH_LOAD(getVTable, core, "CMBaseObjectGetVTable");
        TH_LOAD(contextType, experience, "FigRoutingContextGetTypeID");
        TH_LOAD(endpointType, core, "FigEndpointGetTypeID");
        TH_LOAD(streamType, core, "FigEndpointStreamGetTypeID");
        TH_LOAD(managerType, core, "FigEndpointManagerGetTypeID");
        TH_LOAD(copyArray, core, "CMBaseObjectCopyCFArrayProperty");
        TH_LOAD(copyString, core, "CMBaseObjectCopyCFStringProperty");
        TH_LOAD(copyNumber, core, "CMBaseObjectCopyCFNumberProperty");
        TH_LOAD(getBoolean, core, "CMBaseObjectGetBooleanProperty");
#undef TH_LOAD
        functions.halRead = AudioObjectGetPropertyData;
        functions.halSize = AudioObjectGetPropertyDataSize;
        functions.halSettable = AudioObjectIsPropertySettable;
        functions.halWrite = AudioObjectSetPropertyData;
        runtime = [[self alloc] initWithFunctions:functions keyResolver:^CFStringRef(const char *name) {
            CFStringRef *p = core ? dlsym(core, name) : NULL;
            if (!p && experience) p = dlsym(experience, name);
            if (!p && sender) p = dlsym(sender, name);
            return p && *p && CFGetTypeID(*p) == CFStringGetTypeID() ? *p : NULL;
        } coreMediaKeyResolver:^CFStringRef(const char *name) {
            CFStringRef *p = core ? dlsym(core, name) : NULL;
            return p && *p && CFGetTypeID(*p) == CFStringGetTypeID() ? *p : NULL;
        } symbolName:^NSString *(const void *function) {
            Dl_info info = {0};
            return function && dladdr(function, &info) && info.dli_sname ? @(info.dli_sname) : @"";
        } classResolver:^Class(NSString *name) { return NSClassFromString(name); }
        avRoutingAvailable:routing != NULL uptime:^{ return NSProcessInfo.processInfo.systemUptime; }
        pump:^(NSTimeInterval seconds, useconds_t microseconds) {
            if (seconds > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
            if (microseconds) usleep(microseconds);
        }];
    });
    return runtime;
}
- (instancetype)initWithFunctions:(THPrivateAudioFunctions)functions
                     keyResolver:(CFStringRef (^)(const char *))keyResolver
            coreMediaKeyResolver:(CFStringRef (^)(const char *))coreMediaKeyResolver
                      symbolName:(NSString *(^)(const void *))symbolName
                   classResolver:(Class (^)(NSString *))classResolver
              avRoutingAvailable:(BOOL)avRoutingAvailable
                          uptime:(NSTimeInterval (^)(void))uptime
                            pump:(void (^)(NSTimeInterval, useconds_t))pump {
    if ((self = [super init])) {
        _functions = functions; _keyResolver = [keyResolver copy]; _coreMediaKeyResolver = [coreMediaKeyResolver copy]; _symbolResolver = [symbolName copy];
        _classResolver = [classResolver copy]; _avRoutingAvailable = avRoutingAvailable;
        _uptime = [uptime copy]; _pump = [pump copy];
    }
    return self;
}
- (SInt32)copyContext:(CFAllocatorRef)allocator options:(CFDictionaryRef)options output:(CFTypeRef *)output { return _functions.copyContext(allocator, options, output); }
- (SInt32)copyManager:(CFTypeRef *)output { return _functions.copyManager(output); }
- (OSStatus)halRead:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(const void *)qualifier size:(UInt32 *)size output:(void *)output { return _functions.halRead(object, address, qualifierSize, qualifier, size, output); }
- (OSStatus)halSize:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(const void *)qualifier size:(UInt32 *)size { return _functions.halSize(object, address, qualifierSize, qualifier, size); }
- (OSStatus)halSettable:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address value:(Boolean *)value { return _functions.halSettable(object, address, value); }
- (OSStatus)halWrite:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(const void *)qualifier size:(UInt32)size value:(const void *)value { return _functions.halWrite(object, address, qualifierSize, qualifier, size, value); }
- (CFStringRef)key:(const char *)name { return _keyResolver(name); }
- (CFStringRef)coreMediaKey:(const char *)name { return _coreMediaKeyResolver(name); }
- (NSString *)symbolName:(const void *)function { return _symbolResolver(function); }
- (Class)classNamed:(NSString *)name { return _classResolver(name); }
- (NSTimeInterval)uptime { return _uptime(); }
- (void)pumpFor:(NSTimeInterval)seconds sleepMicroseconds:(useconds_t)microseconds { _pump(seconds, microseconds); }
- (id)readProperty:(CFTypeRef)object name:(const char *)name diagnostics:(NSMutableDictionary *)diagnostics recordSuccess:(BOOL)recordSuccess {
    if (!object || !_functions.getVTable) return nil;
    CFTypeID type = CFGetTypeID(object);
    BOOL supported = (_functions.contextType && type == _functions.contextType()) ||
        (_functions.endpointType && type == _functions.endpointType()) ||
        (_functions.streamType && type == _functions.streamType()) ||
        (_functions.managerType && type == _functions.managerType());
    if (!supported) return nil;
    CFStringRef key = [self key:name];
    const void * const *table = _functions.getVTable(object);
    const void * const *base = table ? table[1] : NULL;
    THRuntimeCopyProperty copy = base ? (THRuntimeCopyProperty)base[6] : NULL;
    if (!key || !copy || ![[self symbolName:copy] hasSuffix:@"CopyProperty"]) {
        diagnostics[@(name)] = @"unsupportedPropertyABI"; return nil;
    }
    CFTypeRef value = NULL;
    @try {
        SInt32 status = copy(object, key, kCFAllocatorDefault, &value);
        if (recordSuccess || status) diagnostics[@(name)] = @(status);
        if (status) return nil;
        id result = value ? CFBridgingRelease(value) : nil;
        value = NULL;
        return result;
    } @finally {
        // Copy may populate its out parameter before throwing. ARC exception
        // cleanup cannot release a CF reference whose ownership was not moved.
        if (value) CFRelease(value);
    }
}
- (NSString *)halString:(AudioObjectID)object selector:(AudioObjectPropertySelector)selector {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef value = NULL; UInt32 size = sizeof(value);
    @try {
        OSStatus status = [self halRead:object address:&address qualifierSize:0 qualifier:NULL size:&size output:&value];
        if (status || size != sizeof(value) || !value || CFGetTypeID(value) != CFStringGetTypeID()) return nil;
        NSString *result = CFBridgingRelease(value);
        value = NULL;
        return result;
    } @finally {
        if (value) CFRelease(value);
    }
}
- (BOOL)halScalar:(AudioObjectID)object selector:(AudioObjectPropertySelector)selector value:(UInt32 *)value {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(*value);
    return [self halRead:object address:&address qualifierSize:0 qualifier:NULL size:&size output:value] == noErr && size == sizeof(*value);
}
@end
