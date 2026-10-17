#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@class THPrivateAudioRuntime;
/// Optional, read-only evidence from an existing AVOutputDevice wrapper. Each
/// unsupported, malformed, or throwing getter produces NSNull, never permission.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *THPrivateDeviceEligibility(id _Nullable device);
/// A single isolated read of the raw feature mask and each eligibility flag.
/// Includes supportsAudio derived from that same feature-mask observation.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *THPrivateDeviceTraits(id _Nullable device);
FOUNDATION_EXPORT id THPrivateDeviceIdentifier(id _Nullable device);
/// Optional icon metadata read on the audio executor from the existing wrapper.
/// Identifier/model/symbol double reads must agree; unsupported ABIs and getter
/// exceptions produce unknown evidence without changing route health.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *THPrivateDeviceIconEvidence(id _Nullable device, THPrivateAudioRuntime *runtime);
/// System-owned model-to-symbol mapping. No handwritten model table or UI calls.
FOUNDATION_EXPORT NSString * _Nullable THAudioDeviceSymbolForModelIdentifier(NSString *modelIdentifier, THPrivateAudioRuntime *runtime);
NS_ASSUME_NONNULL_END
