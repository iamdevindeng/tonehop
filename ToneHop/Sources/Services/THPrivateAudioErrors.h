#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSErrorDomain const THRetainedAudioErrorDomain;
FOUNDATION_EXPORT NSErrorDomain const THPrivateEndpointErrorDomain;
FOUNDATION_EXPORT NSErrorDomain const THSystemAudioSnapshotErrorDomain;
FOUNDATION_EXPORT NSErrorDomain const THPrivateAudioErrorDomain;

/// Stable application codes. Raw system OSStatus values may also be returned
/// unchanged in these domains; callers must not reinterpret those as this enum.
typedef NS_ERROR_ENUM(THRetainedAudioErrorDomain, THRetainedAudioErrorCode) {
    THRetainedAudioErrorExecutor = 1,
    THRetainedAudioErrorRuntimeUnavailable = 2,
    THRetainedAudioErrorContextUnavailable = 3,
    THRetainedAudioErrorManagerUnavailable = 4,
    THRetainedAudioErrorReadFailed = 5,
    THRetainedAudioErrorNotCaptured = 6,
    THRetainedAudioErrorUnsafeRoute = 7,
    THRetainedAudioErrorReuseUnavailable = 8,
    THRetainedAudioErrorOutputChanged = 9,
    THRetainedAudioErrorConnectionUnconfirmed = 10,
    THRetainedAudioErrorDeviceNotReady = 11,
    THRetainedAudioErrorSelectionUnconfirmed = 12,
    THRetainedAudioErrorSelectionFailed = 13,
    THRetainedAudioErrorCleanupUnconfirmed = 14,
    THRetainedAudioErrorAllocation = 16,
    THRetainedAudioErrorDeviceChanged = 17,
    THRetainedAudioErrorCleanupException = 18,
    THRetainedAudioErrorCapturedStreamChanged = 22,
    THRetainedAudioErrorCapturedSelectionUnconfirmed = 23,
    THRetainedAudioErrorPending = 24,
    THRetainedAudioErrorCleanupBlocked = 25,
};
NS_ASSUME_NONNULL_END
