import SwiftUI
import ReplayKit

/// The call screen's screen-share button.
///
/// iOS only starts a screen broadcast from its own system picker, so this
/// button triggers a hidden `RPSystemBroadcastPickerView` pre-set to the
/// HyperChat Screen Share extension. If sharing can't work (voice call,
/// extension missing) it shows the reason instead.
struct ScreenShareButton: View {
    @ObservedObject var service: CallService
    @StateObject private var picker = BroadcastPickerHolder()

    var body: some View {
        Button {
            if service.screenShareUnavailableReason != nil {
                Task { await service.toggleScreenShare() }
            } else {
                picker.present()
            }
        } label: {
            Image(systemName: service.isScreenSharing ? "rectangle.inset.filled.and.person.filled" : "rectangle.inset.filled.on.rectangle")
                .font(.title3)
                .foregroundStyle(service.isScreenSharing ? .black : .white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(service.isScreenSharing ? Color.white : Color.white.opacity(0.2)))
        }
        .background(BroadcastPickerHost(holder: picker).frame(width: 1, height: 1).opacity(0.02))
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
    /// the standard way to open it from a custom button.
    func present() {
        for case let button as UIButton in pickerView.subviews {
            button.sendActions(for: .touchUpInside)
            return
        }
    }
}

private struct BroadcastPickerHost: UIViewRepresentable {
    let holder: BroadcastPickerHolder

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.addSubview(holder.pickerView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
