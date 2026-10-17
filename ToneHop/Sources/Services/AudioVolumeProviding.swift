import Foundation

/// Intentionally has no output-selection or connection API. The same hardware
/// service instance is injected into selection and volume owners by integration.
protocol AudioVolumeProviding: Sendable {
    func readVolume(for target: AudioVolumeTarget) async throws -> AudioVolumeSnapshot
    func setVolume(_ value: Float, for target: AudioVolumeTarget, permit: AudioMutationPermit) async throws -> AudioVolumeWriteResult
    func observeVolumeChanges(targets: [AudioVolumeTarget], changed: @escaping @Sendable () -> Void) async throws
    func stopObservingVolume() async
}
