#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <unistd.h>

NS_ASSUME_NONNULL_BEGIN

/// A synchronous admission boundary. Accepted operations run exactly once;
/// the gate finishes its registered submission before returning.
typedef BOOL (^THAudioMutationGate)(void (^operation)(void));

/// Keep Cocoa exceptions inside Objective-C while a Swift gate owns a registered
/// submission. Rethrow the original exception only after the gate returns.
FOUNDATION_EXPORT BOOL THPerformAudioMutation(THAudioMutationGate gate, void (^operation)(void));

/// ABI-level dependencies. Immutable after construction; injected per bridge,
/// never installed into process-global functions. CF Copy ownership is unchanged.
typedef struct {
    SInt32 (* _Nullable copyContext)(CFAllocatorRef, CFDictionaryRef _Nullable, CFTypeRef _Nullable * _Nonnull);
    SInt32 (* _Nullable copyManager)(CFTypeRef _Nullable * _Nonnull);
    const void * _Nullable const * _Nullable (* _Nullable getVTable)(CFTypeRef);
    CFTypeID (* _Nullable contextType)(void);
    CFTypeID (* _Nullable endpointType)(void);
    CFTypeID (* _Nullable streamType)(void);
    CFTypeID (* _Nullable managerType)(void);
    SInt32 (* _Nullable copyArray)(CFTypeRef, CFStringRef, CFAllocatorRef, CFTypeRef _Nullable * _Nonnull);
    SInt32 (* _Nullable copyString)(CFTypeRef, CFStringRef, CFAllocatorRef, CFTypeRef _Nullable * _Nonnull);
    SInt32 (* _Nullable copyNumber)(CFTypeRef, CFStringRef, CFAllocatorRef, CFTypeRef _Nullable * _Nonnull);
    SInt32 (* _Nullable getBoolean)(CFTypeRef, CFStringRef, Boolean *, Boolean *);
    OSStatus (*halRead)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void * _Nullable, UInt32 *, void *);
    OSStatus (*halSize)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void * _Nullable, UInt32 *);
    OSStatus (*halSettable)(AudioObjectID, const AudioObjectPropertyAddress *, Boolean *);
    OSStatus (*halWrite)(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void * _Nullable, UInt32, const void *);
} THPrivateAudioFunctions;

/// Shared low-level mechanics only. Capability and route policy stay in bridges.
@interface THPrivateAudioRuntime : NSObject
@property (nonatomic, readonly) THPrivateAudioFunctions functions;
@property (nonatomic, readonly) BOOL avRoutingAvailable;
+ (instancetype)systemRuntime NS_SWIFT_NAME(system());
- (instancetype)initWithFunctions:(THPrivateAudioFunctions)functions
                     keyResolver:(CFStringRef _Nullable (^)(const char *))keyResolver
            coreMediaKeyResolver:(CFStringRef _Nullable (^)(const char *))coreMediaKeyResolver
                    symbolName:(NSString * (^)(const void * _Nullable))symbolName
                   classResolver:(Class _Nullable (^)(NSString *))classResolver
              avRoutingAvailable:(BOOL)avRoutingAvailable
                          uptime:(NSTimeInterval (^)(void))uptime
                            pump:(void (^)(NSTimeInterval, useconds_t))pump NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// Instance entry points for calls lacking an object that identifies a session.
- (SInt32)copyContext:(CFAllocatorRef)allocator options:(nullable CFDictionaryRef)options output:(CFTypeRef _Nullable * _Nonnull)output;
- (SInt32)copyManager:(CFTypeRef _Nullable * _Nonnull)output;
- (OSStatus)halRead:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(nullable const void *)qualifier size:(UInt32 *)size output:(void *)output;
- (OSStatus)halSize:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(nullable const void *)qualifier size:(UInt32 *)size;
- (OSStatus)halSettable:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address value:(Boolean *)value;
- (OSStatus)halWrite:(AudioObjectID)object address:(const AudioObjectPropertyAddress *)address qualifierSize:(UInt32)qualifierSize qualifier:(nullable const void *)qualifier size:(UInt32)size value:(const void *)value;
- (nullable CFStringRef)key:(const char *)name;
- (nullable CFStringRef)coreMediaKey:(const char *)name;
- (NSString *)symbolName:(const void * _Nullable)function;
- (nullable Class)classNamed:(NSString *)name;
- (NSTimeInterval)uptime;
- (void)pumpFor:(NSTimeInterval)seconds sleepMicroseconds:(useconds_t)microseconds;
/// Identical property ABI used by the two SystemAudio bridges. The caller
/// chooses whether successful status codes belong in its diagnostic contract.
- (nullable id)readProperty:(CFTypeRef)object name:(const char *)name
               diagnostics:(NSMutableDictionary *)diagnostics recordSuccess:(BOOL)recordSuccess;
- (nullable NSString *)halString:(AudioObjectID)object selector:(AudioObjectPropertySelector)selector;
- (BOOL)halScalar:(AudioObjectID)object selector:(AudioObjectPropertySelector)selector value:(UInt32 *)value;
@end

NS_ASSUME_NONNULL_END
