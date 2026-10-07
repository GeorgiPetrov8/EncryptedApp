import SwiftUI
import ReplayKit

/// The call screen's screen-share button. Works in voice and video calls.
///
/// iOS only starts a screen broadcast from its own system picker, so this
/// button triggers a hidden `RPSystemBroadcastPickerView` pre-set to the
/// HyperChat Screen Share extension. If sharing can't work right now it shows
/// the reason (Simulator, extension missing, call not connected yet).
struct ScreenShareButton: View {
    @ObservedObject var service: CallService
    @StateObject private var picker = BroadcastPickerHolder()

    var body: some View {
        Button {
            if service.screenShareUnavailableReason != nil {
                Task { await service.toggleScreenShare() }
            } else {
                service.clearError()
                picker.present()
            }
        } label: {
            Image(systemName: service.isScreenSharing ? "rectangle.inset.filled.and.person.filled" : "rectangle.inset.filled.on.rectangle")
                .font(.title3)
                .foregroundStyle(service.isScreenSharing ? .black : .white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(service.isScreenSharing ? Color.white : Color.white.opacity(0.2)))
        }
        .background(BroadcastPickerHost(holder: picker).frame(width: 44, height: 44).opacity(0.02).allowsHitTesting(false))
        .accessibilityLabel(service.isScreenSharing ? "Stop sharing screen" : "Share screen")
    }
}

@MainActor
final class BroadcastPickerHolder: ObservableObject {
    let pickerView: RPSystemBroadcastPickerView = {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.preferredExtension = ScreenShareCoordinator.extensionBundleIdentifier
        view.showsMicrophoneButton = false
        return view
    }()

    /// The picker has no public "show" method; tapping its internal button is
    /// the standard way to open it from a custom button. The button can be
    /// nested and is created lazily, so it's searched for recursively after
    /// a layout pass.
    func present() {
        pickerView.layoutIfNeeded()
        if let button = Self.findButton(in: pickerView) {
            button.sendActions(for: .touchUpInside)
        }
    }

    private static func findButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let nested = findButton(in: subview) { return nested }
        }
        return nil
    }
}

private struct BroadcastPickerHost: UIViewRepresentable {
    let holder: BroadcastPickerHolder

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        container.addSubview(holder.pickerView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
