#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class THPrivateAudioRuntime;

/// Read-only association of a system-selected AirPlay aggregate with its receiver.
/// Own on one serial executor. Each snapshot releases all copied CF references;
/// this class never discovers, activates, selects, adds or removes a route.
@interface THSystemAudioSnapshotBridge : NSObject
- (instancetype)initWithRuntime:(THPrivateAudioRuntime *)runtime
    NS_SWIFT_UNAVAILABLE("Runtime dependencies remain on the audio executor.");
/// Returns { selection: typed evidence or NSNull, diagnostics: dictionary }.
/// An absent/ambiguous association is not a selectable receiver or a cached UID.
- (nullable NSDictionary<NSString *, id> *)snapshotWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(snapshot());
@end

NS_ASSUME_NONNULL_END
