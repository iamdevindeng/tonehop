import SwiftUI

struct OutputDevicesView: View {
    let store: AudioStore
    var interactions: AudioInteractionCoordinator? = nil
    var onContentSizeChange: ((CGSize) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offlineExpanded = false

    var body: some View {
        OutputDevicesContent(store: store, interactions: interactions,
                             onContentSizeChange: onContentSizeChange,
                             offlineExpanded: $offlineExpanded,
                             offlineExpansion: offlineExpanded ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: offlineExpanded)
            .onChange(of: interactions?.shortcuts.offlineBindings.isEmpty ?? true) { _, isEmpty in
                if isEmpty { offlineExpanded = false }
            }
    }
}

/// One interpolated value lays out the rows, disclosure and footer. Geometry
/// reports these actual intermediate sizes; AppKit follows without a second
/// resize animation. Text and native controls are laid out, never scaled.
private struct OutputDevicesContent: View, Animatable {
    let store: AudioStore
    let interactions: AudioInteractionCoordinator?
    let onContentSizeChange: ((CGSize) -> Void)?
    @Binding var offlineExpanded: Bool
    nonisolated var offlineExpansion: CGFloat

    nonisolated var animatableData: CGFloat {
        get { offlineExpansion }
        set { offlineExpansion = newValue }
    }

    private let maximumVisibleRows = 7
    private let confirmingRowHeight: CGFloat = 61
    private var confirmingBindings: [ShortcutBinding] { interactions?.shortcuts.confirmingBindings ?? [] }
    private var offlineBindings: [ShortcutBinding] { interactions?.shortcuts.offlineBindings ?? [] }
    private var offlineContentHeight: CGFloat { min(CGFloat(offlineBindings.count * 33 + 5), 140) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "ui.output.title", defaultValue: "Sound Output"))
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
                .padding(.bottom, 3)

            Divider().padding(.horizontal, 10)

            if store.devices.isEmpty && confirmingBindings.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(store.devices) { device in
                            VStack(spacing: 0) {
                                DeviceRowView(
                                    device: device,
                                    isCurrent: store.currentDeviceID == device.id,
                                    isSwitching: store.isSwitching || store.isPreparingToQuit,
                                    select: { store.select(device) },
                                    interactions: interactions
                                )
                                Divider().padding(.horizontal, 10)
                                    .opacity(device.id != store.devices.last?.id || !confirmingBindings.isEmpty ? 1 : 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let interactions {
                            ForEach(confirmingBindings) { binding in
                                VStack(spacing: 0) {
                                    confirmingRow(binding, shortcuts: interactions.shortcuts)
                                    Divider().padding(.horizontal, 10)
                                        .opacity(binding.id != confirmingBindings.last?.id ? 1 : 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: visibleRowsHeight)
                .accessibilityLabel(String(localized: "ui.output.discovered", defaultValue: "Discovered sound output devices"))
            }

            if let interactions, !offlineBindings.isEmpty {
                Divider().padding(.horizontal, 10)
                DisclosureGroup(String(localized: "ui.output.offline_count", defaultValue: "Devices Not Found (\(offlineBindings.count))"), isExpanded: $offlineExpanded) {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(offlineBindings) { binding in
                                HStack(spacing: 10) {
                                    Text(interactions.shortcuts.displayName(for: binding))
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(interactions.shortcuts.displayName(for: binding))
                                    Spacer(minLength: 4)
                                    readOnlyKeycap(ShortcutKeyDisplay.label(binding.shortcut))
                                        .accessibilityLabel(String(localized: "ui.shortcut.saved_label", defaultValue: "Saved shortcut for \(interactions.shortcuts.displayName(for: binding))"))
                                        .accessibilityValue(ShortcutKeyDisplay.label(binding.shortcut))
                                    Button(String(localized: "ui.record.remove_menu", defaultValue: "Remove Record")) { interactions.removeRecord(binding) }
                                        .buttonStyle(.borderless)
                                        .fixedSize()
                                        .disabled(!interactions.shortcuts.canEdit)
                                        .accessibilityLabel(String(localized: "ui.record.remove_label", defaultValue: "Remove the local record for \(interactions.shortcuts.displayName(for: binding))"))
                                        .help(String(localized: "ui.record.remove_help", defaultValue: "Remove the record and shortcut without changing sound output. The device will appear again when discovered."))
                                }
                                .frame(minHeight: 28)
                            }
                        }
                        .padding(.top, 5)
                    }
                    .frame(height: offlineContentHeight)
                }
                .disclosureGroupStyle(PanelDisclosureStyle(expansion: offlineExpansion))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            }

            Divider().padding(.horizontal, 10)

            AudioFeedbackView(store: store, shortcuts: interactions?.shortcuts)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 328)
        .fixedSize(horizontal: true, vertical: true)
        .onGeometryChange(for: CGSize.self) { geometry in
            geometry.size
        } action: { size in
            onContentSizeChange?(size)
        }
        // The Animatable parent already supplied this frame's layout progress.
        // Do not let descendant frames or the system disclosure animate again.
        .transaction { $0.animation = nil }
    }

    private var visibleRowsHeight: CGFloat {
        let deviceHeights = store.devices.map { device in
            let hint = DeviceRowView.unavailableHint(for: device, isCurrent: store.currentDeviceID == device.id)
            let hintHeight = hint.map {
                DeviceRowView.unavailableHintHeight(for: $0) + DeviceRowView.unavailableHintSpacing
            } ?? 0
            let volumeHint: CGFloat = DeviceVolumeView.hasHint(deviceID: device.id, store: interactions?.volume)
                ? DeviceRowView.issueHeight + 3 : 0
            let shortcutHint: CGFloat = device.shortcutTarget.flatMap { interactions?.shortcuts.rowIssue(for: $0) } != nil
                ? DeviceRowView.issueHeight + DeviceRowView.unavailableHintSpacing : 0
            let baseHeight: CGFloat = interactions == nil ? 48 : DeviceRowView.baseHeight
            return baseHeight + hintHeight + volumeHint + shortcutHint
        }
        let rowHeights = deviceHeights + Array(repeating: confirmingRowHeight, count: confirmingBindings.count)
        // Keep a separator slot even after the last row so lazy height
        // estimation and the viewport agree before every row is measured.
        let desired = rowHeights.prefix(maximumVisibleRows).reduce(CGFloat.zero) { $0 + $1 + 1 }
        let available = (NSScreen.main?.visibleFrame.height ?? 900)
            - (230 + offlineContentHeight * offlineExpansion)
        return min(desired, max(150, available))
    }

    private func confirmingRow(_ binding: ShortcutBinding, shortcuts: ShortcutStore) -> some View {
        let name = shortcuts.displayName(for: binding)
        return HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
                .background { Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.75) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(name)
                    Spacer(minLength: 3)
                    readOnlyKeycap(ShortcutKeyDisplay.label(binding.shortcut))
                        .accessibilityLabel(String(localized: "ui.shortcut.saved_pending", defaultValue: "Saved shortcut for \(name), checking device identity"))
                        .accessibilityValue(ShortcutKeyDisplay.label(binding.shortcut))
                }
                .frame(height: 26)
                Text(String(localized: "ui.device.confirming", defaultValue: "Checking device identity…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: 20, alignment: .leading)
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func readOnlyKeycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11))
            .frame(width: DeviceRowView.shortcutWidth, height: 26)
            .background { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.75) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
                Text(String(localized: "ui.output.reading", defaultValue: "Reading sound output devices…"))
            } else {
                Image(systemName: "speaker.slash").font(.system(size: 24))
                Text(String(localized: "ui.output.empty", defaultValue: "No sound output devices available"))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .accessibilityElement(children: .combine)
    }
}

private struct PanelDisclosureStyle: DisclosureGroupStyle {
    let expansion: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(90 * expansion))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? String(localized: "ui.disclosure.expanded", defaultValue: "Expanded") : String(localized: "ui.disclosure.collapsed", defaultValue: "Collapsed"))

            DisclosureReveal(expansion: expansion) {
                configuration.content
                    .fixedSize(horizontal: false, vertical: true)
            }
                .clipped()
                .contentShape(Rectangle())
                .opacity(min(1, expansion * 4))
                .allowsHitTesting(configuration.isExpanded)
                .accessibilityHidden(!configuration.isExpanded)
        }
    }
}

/// Propose the content's natural height, then expose only the current fraction.
/// Layout participates in measurement so the host receives intermediate sizes.
private struct DisclosureReveal: Layout {
    let expansion: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * expansion)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: .init(width: bounds.width, height: nil))
    }
}
