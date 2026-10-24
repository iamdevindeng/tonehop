#import "../Sources/Services/THPrivateAudioRuntime.h"

NS_ASSUME_NONNULL_BEGIN

/// Simulates ABI observations, not bridge state. Every environment is independent
/// and calls the real public bridge entry points with CF-owned fixture objects.
@interface THPrivateAudioRuntimeFixture : THPrivateAudioRuntime
@property(nonatomic) NSUInteger contextCopies, managerCopies, managerReleases, halReads, halWrites, adds, removes, bufferedReads;
@property(nonatomic) SInt32 contextStatus, managerStatus, propertyStatus, modeStatus, addStatus, removeStatus, managerPropertyStatus;
@property(nonatomic) BOOL throwFromAdd, throwFromRemove, throwFromMode, deferAdd, deferRemove, mismatchAdd, mismatchRemove, invalidContext, invalidHAL, invalidAssociation;
@property(nonatomic) BOOL omitAddStream, managerWrongType, throwFromStaleSession;
@property(nonatomic) BOOL managerClassMissing, managerClassVersionMismatch, setModeSlotMissing;
/// nil uses the verified system symbol; an empty string simulates no symbol.
@property(nonatomic, copy, nullable) NSString *setModeSymbolOverride;
@property(nonatomic, copy) NSArray<NSString *> *modes;
@property(nonatomic, copy) NSArray<NSString *> *availableEndpointIdentifiers;
@property(nonatomic, copy) NSString *contextIdentifier;
@property(nonatomic, copy, nullable) NSString *selectedAggregate;
@property(nonatomic, copy, nullable) NSString *defaultUID;
/// Opt in when a scenario must observe HAL and SystemAudio independently.
/// The HAL setter still changes defaultUID; the test advances SystemAudio with
/// selectSystemAggregate/onPump only when independent readback is available.
@property(nonatomic) BOOL suppressSystemSelectionOnHALWrite;
@property(nonatomic, copy, nullable) void (^onHALWrite)(NSString *uid);
/// Context observations are independent of selected buffered AirPlay state.
/// nil uses the automatic scenario; NSNull explicitly returns an empty value.
@property(nonatomic, copy, nullable) NSArray<NSString *> *contextRouteIdentifiers;
@property(nonatomic, strong, nullable) id contextAssociatedAudioDeviceOverride, contextBufferedAggregateOverride;
@property(nonatomic, copy) NSDictionary<NSString *, id> *bluetoothRouteProperties;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *bluetoothRouteStatuses;
@property(nonatomic) SInt32 routesStatus, bufferedStatus, associatedStatus;
@property(nonatomic) BOOL routesWrongType;
@property(nonatomic, copy, nullable) void (^onRead)(NSString *kind, NSString *key);
@property(nonatomic, copy, nullable) void (^onPump)(void);
@property(nonatomic, readonly) NSTimeInterval time;
@property(nonatomic, readonly) NSUInteger sessionGeneration;
@property(nonatomic) SInt32 staleSessionStatus;
@property(nonatomic, copy, nullable) void (^onCopyContext)(void);
@property(nonatomic, copy, nullable) void (^onCopyManager)(void);
/// Inject a Copy that fills an owned out value before throwing. Optional suffix
/// for property calls identifies one exported property, e.g. property:...UUID.
@property(nonatomic, copy, nullable) NSString *throwAfterCopyOperation;
@property(nonatomic) NSUInteger faultCopies, faultCopyReleases;
@property(nonatomic) BOOL trackBufferedCopyLifetimes;
@property(nonatomic) NSUInteger trackedBufferedCopies, trackedBufferedReleases;
@property(nonatomic, copy, nullable) void (^onSetMode)(void);
- (void)rotateSystemSession;
- (void)advanceTime:(NSTimeInterval)seconds;
@property(nonatomic, readonly) BOOL addCallbackPending, removeCallbackPending;
- (instancetype)initFixture;
- (void)setAggregate:(NSString *)aggregate receiver:(nullable NSString *)receiver streams:(NSArray<NSString *> *)streams;
- (void)setAggregate:(NSString *)aggregate receivers:(NSArray<NSString *> *)receivers streams:(NSArray<NSString *> *)streams;
- (void)selectSystemAggregate:(nullable NSString *)aggregate;
- (void)selectSystemBluetoothUID:(NSString *)uid;
- (void)completeAdd;
- (void)completeRemove;
@end

NS_ASSUME_NONNULL_END
