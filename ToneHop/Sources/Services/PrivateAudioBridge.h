#import <Foundation/Foundation.h>
#import "THPrivateAudioRuntime.h"
#import "THPrivateDeviceEvidence.h"

NS_ASSUME_NONNULL_BEGIN

/// Dynamic AVRouting boundary. Call all methods from the same serial executor.
/// No entitlement impersonation, UI scripting, audio playback, or implicit fallback.
@interface THPrivateAudioBridge : NSObject
- (instancetype)initWithPerformIfRunning:(THAudioMutationGate)performIfRunning;
- (instancetype)initWithRuntime:(THPrivateAudioRuntime *)runtime performIfRunning:(THAudioMutationGate)performIfRunning
    NS_SWIFT_UNAVAILABLE("Runtime dependencies remain on the audio executor.");
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(start());
- (nullable NSDictionary<NSString *, id> *)snapshotWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(snapshot());
/// Submits a request only. The caller must confirm the system context's device ID.
- (BOOL)selectIdentifier:(NSString *)identifier isCancelled:(BOOL (^)(void))isCancelled performIfRunning:(BOOL (^)(void (^operation)(void)))performIfRunning error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(select(identifier:isCancelled:performIfRunning:));
- (void)stop;
@end

NS_ASSUME_NONNULL_END
