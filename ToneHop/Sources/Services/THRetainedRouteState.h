#import <Foundation/Foundation.h>
#import <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (*THRCallback)(CFTypeRef, CFTypeRef, uint64_t, uint64_t, SInt32, void *);
typedef SInt32 (*THRAggregateOperation)(CFTypeRef, CFTypeRef, CFDictionaryRef _Nullable, THRCallback, void *);

/// Callback and transaction have independent references. A timeout or shutdown
/// may release the owner, but cannot release the callback's refcon prematurely.
typedef struct {
    atomic_uint references;
    atomic_bool done, objectsMatch;
    atomic_int status;
    CFTypeRef aggregate, leaf, context, manager;
} THROperation;
FOUNDATION_EXPORT void THRReleaseOperation(THROperation * _Nullable operation);
FOUNDATION_EXPORT void THRComplete(CFTypeRef aggregate, CFTypeRef leaf, uint64_t word2, uint64_t word3, SInt32 status, void *refcon);
FOUNDATION_EXPORT THROperation * _Nullable THRNewOperation(CFTypeRef aggregate, CFTypeRef leaf, CFTypeRef context, CFTypeRef manager);

/// Audio-executor-owned CF references and captured identity. This object never
/// performs discovery, reads system state, or writes a route.
@interface THRetainedRouteSession : NSObject
@property(nonatomic, readonly, nullable) CFTypeRef context;
@property(nonatomic, readonly, nullable) CFTypeRef manager;
@property(nonatomic, readonly, nullable) CFTypeRef aggregate;
@property(nonatomic, readonly, nullable) CFTypeRef leaf;
@property(nonatomic, copy, nullable) NSString *contextID;
@property(nonatomic, copy, nullable) NSString *aggregateID;
@property(nonatomic, copy, nullable) NSString *identifier;
@property(nonatomic, copy, nullable) NSString *name;
@property(nonatomic, copy, nullable) NSString *captureStreamUID;
@property(nonatomic) BOOL invalidated;
/// Adopt a successful Copy reference; caller transfers its +1 ownership.
- (void)adoptContext:(CFTypeRef)context;
- (void)adoptManager:(CFTypeRef)manager;
- (void)adoptAggregate:(CFTypeRef)aggregate leaf:(CFTypeRef)leaf;
- (void)copyReferencesFrom:(THRetainedRouteSession *)other;
- (void)releaseCapture;
- (void)releaseAll;
@end

typedef NS_ENUM(NSUInteger, THRetainedRemovePhase) {
    THRetainedRemovePhaseNotAttempted,
    THRetainedRemovePhaseSubmitted,
    THRetainedRemovePhaseSubmissionFailed,
};

/// An attempted Add's local ledger, distinct from borrowed capture references.
/// Callback completion remains in the capsule; this phase records submission,
/// not the eventual server result, and does not permit a retry by itself.
@interface THOwnedRouteTransaction : NSObject
@property(nonatomic, assign, nullable) THROperation *add;
@property(nonatomic, assign, nullable) THROperation *remove;
@property(nonatomic) BOOL owned;
@property(nonatomic) BOOL mustClean;
@property(nonatomic, copy, nullable) NSString *ownStreamUID;
@property(nonatomic, copy, nullable) NSString *returnLocalUID;
@property(nonatomic) THRetainedRemovePhase removePhase;
@property(nonatomic) NSTimeInterval removeSubmittedAt;
@property(nonatomic, readonly) BOOL removeAttempted;
@property(nonatomic, readonly) BOOL removeSubmissionFailed;
- (void)forgetRouteIdentity;
- (void)clear;
@end

NS_ASSUME_NONNULL_END
