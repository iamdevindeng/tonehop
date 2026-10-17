#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class THPrivateEndpointBridge, THPrivateAudioRuntime;

/// Strict, case-sensitive grammar verified for the macOS 27.0.1 aggregate Audio
/// stream constructor. Parsing alone is not route or selected-state evidence.
FOUNDATION_EXPORT BOOL THExistingStreamUIDMatchesAggregate(NSString *uid, NSString *aggregateIdentifier);
/// Cleanup requires the exact stream generation witnessed after this App's Add.
/// A missing UID, including two missing UIDs, never proves ownership.
FOUNDATION_EXPORT BOOL THOwnedAirPlayStreamMatches(NSString * _Nullable ownedUID, NSString * _Nullable liveUID);

/// Own on one dedicated non-main NSThread with a run loop. Calls must be serial,
/// including while select pumps that loop. Retains one real system route for this
/// process only, without a TTL. Never creates an aggregate or changes discovery.
@interface THRetainedSystemAudioBridge : NSObject
/// Reuses the worker's live discovery session to verify exact receiver identity.
/// Both bridges must stay on the same audio executor.
- (instancetype)initWithEndpointDiscovery:(THPrivateEndpointBridge *)endpointDiscovery;
- (instancetype)initWithEndpointDiscovery:(THPrivateEndpointBridge *)endpointDiscovery runtime:(THPrivateAudioRuntime *)runtime
    NS_SWIFT_UNAVAILABLE("Runtime dependencies remain on the audio executor.");
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// {retained: {identifier,name,canSelect,isSelected,reason,state,associatedUID,catalogRoute}|NSNull,
///  diagnostics: dictionary}. Reads and captures a fully verified system selection.
/// sessionReadSucceeded is a CFBoolean: a healthy uncaptured session is true;
/// failed recovery, unreadable captured evidence, or stopped observation is false.
/// Observation never adds/removes a member or changes the default output.
/// associatedUID is a live-validated borrowed HAL stream after switching local,
/// otherwise NSNull. It is association evidence, never a selected-state claim.
/// catalogRoute is a twice-validated, currently usable unselected receiver
/// descriptor for discovery warm-up gaps; absent for stale or invalid handles.
/// existingStreamAssociation is read-only identity evidence for a surviving
/// stream with no retained handle: {identifier,name,uid,aggregateIdentifier,
/// contextIdentifier,readbackStable}|NSNull. It grants neither switching
/// capability nor selected state. A separate existingStreamRecovery value may
/// authorize one explicit HAL recovery after stable identity and output-capability
/// checks. Only subsequent complete selected readback establishes a borrowed
/// capture; recovery never grants Add ownership or permission to Remove.
- (nullable NSDictionary<NSString *, id> *)snapshotWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(snapshot());
/// Allows the worker to cancel reference recovery when shutdown starts.
- (nullable NSDictionary<NSString *, id> *)snapshotIsShuttingDown:(BOOL (^)(void))isShuttingDown error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(snapshot(isShuttingDown:));
- (BOOL)selectIdentifier:(NSString *)identifier isCancelled:(BOOL (^)(void))isCancelled isShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(BOOL (^)(void (^operation)(void)))performIfRunning error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(select(identifier:isCancelled:isShuttingDown:performIfRunning:));
/// Best-effort capture only. A missing route must not block an ordinary HAL leave.
- (BOOL)prepareToLeaveWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(prepareToLeave());
/// Running-only lifecycle coordination, separate from read-only snapshots. It
/// never changes default output. It may submit one Remove for a verified App
/// member after HAL and system context agree that output has left AirPlay.
/// Error 24 means callback/readback is pending; 25 means cleanup is blocked.
/// Repeated calls cannot resubmit a failed or unconfirmed Remove.
- (BOOL)reconcileRuntimeStateIsShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(BOOL (^)(void (^operation)(void)))performIfRunning error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(reconcileRuntimeState(isShuttingDown:performIfRunning:));
/// No-op when no member was added here. Never changes default output.
- (BOOL)completedLeaveIsShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(BOOL (^)(void (^operation)(void)))performIfRunning error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(completedLeave(isShuttingDown:performIfRunning:));
/// Explicit continuation of a failed submitted selection, never an observation.
/// Error 24 means its callback is still pending; other errors are terminal.
- (BOOL)finishFailedSelectionIsShuttingDown:(BOOL (^)(void))isShuttingDown performIfRunning:(BOOL (^)(void (^operation)(void)))performIfRunning error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(finishFailedSelection(isShuttingDown:performIfRunning:));
/// Read-only quit preflight. {ownedStream: {receiverID,name,streamUID}|NSNull}.
/// Only this process's completed Add and exact live stream authorize cleanup.
/// Unknown/in-flight ownership returns an error; it is never treated as absent.
- (nullable NSDictionary<NSString *, id> *)ownedStreamForExitWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(ownedStreamForExit());
/// Releases only this App's references. Never writes routing state or waits for
/// a receiver to become unselected. Pending callbacks retain their own refcon.
- (BOOL)shutdownWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(shutdown());
@end

NS_ASSUME_NONNULL_END
