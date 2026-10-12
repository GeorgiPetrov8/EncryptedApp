import SwiftUI
import UniformTypeIdentifiers

/// The attachment menu in the composer: camera, library, document, GIF.
///
/// The menu only raises a flag; the photo picker is attached to the chat screen
/// itself, because a `PhotosPicker` inside a `Menu` is torn down together with it.
struct AttachmentMenu: View {
    @Environment(\.appTheme) private var theme

    let isDisabled: Bool
    let onCamera: () -> Void
    let onPhotoLibrary: () -> Void
    let onDocument: () -> Void
    let onGIF: () -> Void
    /// nil = follow the theme.
    var tint: Color? = nil

    var body: some View {
        Menu {
            Button(action: onCamera) {
                Label("Camera", systemImage: "camera")
            }
            Button(action: onPhotoLibrary) {
                Label("Photo or Video", systemImage: "photo.on.rectangle")
            }
            Button(action: onDocument) {
                Label("Document", systemImage: "doc")
            }
            Button(action: onGIF) {
                Label("GIF", systemImage: "face.smiling")
            }
        } label: {
            // FIX: was hard-coded `Color.brand`, i.e. a blue "+" on a blue
            // composer. It now follows the bar it sits on.
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle((tint ?? theme.tint).opacity(isDisabled ? 0.4 : 1))
        }
        .disabled(isDisabled)
        .accessibilityLabel("Add attachment")
    }
}

/// `UIDocumentPickerViewController` wrapper.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    let onCancelled: () -> Void

    private static let allowedTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .rtf, .commaSeparatedText]
        let officeIdentifiers = [
            "org.openxmlformats.wordprocessingml.document",   // .docx
            "org.openxmlformats.spreadsheetml.sheet",         // .xlsx
            "org.openxmlformats.presentationml.presentation", // .pptx
        ]
        types.append(contentsOf: officeIdentifiers.compactMap(UTType.init))
        return types
    }()

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.allowedTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancelled: onCancelled)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPicked: (URL) -> Void
        private let onCancelled: () -> Void

        init(onPicked: @escaping (URL) -> Void, onCancelled: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancelled = onCancelled
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return onCancelled() }
            onPicked(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancelled()
        }
    }
}

/// `UIImagePickerController` for in-app capture.
struct CameraPicker: UIViewControllerRepresentable {
    enum Capture {
        case photo(Data)
        case video(URL)
    }

    let onCaptured: (Capture) -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeMedium
        picker.videoMaximumDuration = 120
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCaptured: onCaptured, onCancelled: onCancelled)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCaptured: (Capture) -> Void
        private let onCancelled: () -> Void

        init(onCaptured: @escaping (Capture) -> Void, onCancelled: @escaping () -> Void) {
            self.onCaptured = onCaptured
            self.onCancelled = onCancelled
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let movieURL = info[.mediaURL] as? URL {
                onCaptured(.video(movieURL))
                return
            }
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.8) {
                onCaptured(.photo(data))
                return
            }
            onCancelled()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancelled()
        }
    }
}
