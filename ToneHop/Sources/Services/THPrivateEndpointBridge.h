#import <Foundation/Foundation.h>
#import "THPrivateAudioRuntime.h"

NS_ASSUME_NONNULL_BEGIN

@class THPrivateAudioRuntime;

/// AirPlay endpoint discovery; startup requests Detailed on the raw manager.
/// Own this object on one serial executor. The first snapshot may start discovery;
/// reads of an existing session do not change its mode.
/// No output selection, HAL writes, audio playback, or system UI is performed.
@interface THPrivateEndpointBridge : NSObject
- (instancetype)initWithPerformIfRunning:(THAudioMutationGate)performIfRunning;
- (instancetype)initWithRuntime:(THPrivateAudioRuntime *)runtime performIfRunning:(THAudioMutationGate)performIfRunning
    NS_SWIFT_UNAVAILABLE("Runtime dependencies remain on the audio executor.");
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(start());
/// Returns { endpoints: [raw rows], diagnostics: dictionary, elapsed: seconds }.
/// Raw rows retain duplicate identifiers. Missing/invalid properties are NSNull;
/// propertyStatus explains each read. streamUIDs are endpoint stream identifiers,
/// not necessarily HAL UIDs. Activation never implies system-output selection.
/// incompleteDeviceCount counts rows missing critical identity/eligibility reads;
/// explicitly excluded rows and missing optional diagnostic fields do not count.
/// Raw IsCached is supplementary; wrapper cache/eligibility reads remain required.
/// diagnostics.fieldIssues retains anonymous field/state/status counts, logged
/// only when the summary changes. Unknown property values remain NSNull.
- (nullable NSDictionary<NSString *, id> *)snapshotWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(snapshot());
/// Internal same-executor access to real endpoint objects, retained by this array.
/// Reads the existing discovery session only; never starts or changes discovery.
/// A failed manager read may replace its reference after two stable reads of a
/// new candidate; attempts are bounded (3 seconds, then 30 after three failures).
/// A healthy empty list is not a recovery trigger. Stop prevents these reads
/// from recreating a session; only an explicit start/snapshot may start it again.
/// Callers must retain a chosen object before releasing the returned array.
- (nullable NSArray *)availableEndpointReferencesWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_UNAVAILABLE("Endpoint references remain on the audio executor.");
/// Releases local references without writing the shared manager's discovery mode.
/// The owner remains responsible for stopping its scoped AV discovery session.
- (void)stop;
/// Records local release after stop; stopStatus stays null because no mode write
/// is submitted. Diagnostics reset at the next start.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *diagnostics;
@end

NS_ASSUME_NONNULL_END
