import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The attachment menu in the composer: camera, library, document, GIF.
///
/// Replaces the single paperclip that only opened the photo library.
struct AttachmentMenu: View {
    @Binding var selectedPhotoItem: PhotosPickerItem?
    let isDisabled: Bool
    let onCamera: () -> Void
    let onDocument: () -> Void
    let onGIF: () -> Void
    var tint: Color = .accentColor

    var body: some View {
        Menu {
            Button {
                onCamera()
            } label: {
                Label("Camera", systemImage: "camera")
            }

            // `PhotosPicker` inside a `Menu` works because the picker presents
            // itself; it doesn't need the menu to stay alive.
            PhotosPicker(selection: $selectedPhotoItem, matching: .any(of: [.images, .videos])) {
                Label("Photo or Video", systemImage: "photo.on.rectangle")
            }

            Button {
                onDocument()
            } label: {
                Label("Document", systemImage: "doc")
            }

            Button {
                onGIF()
            } label: {
                Label("GIF", systemImage: "face.smiling")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(isDisabled ? Color.secondary : tint)
        }
        .disabled(isDisabled)
        .accessibilityLabel("Add attachment")
    }
}

/// `UIDocumentPickerViewController` wrapper.
///
/// The type list is an allow-list at the picker level too — not as a security
/// control (`AttachmentPolicy` is that, and it inspects bytes), but so the
/// user doesn't pick a file, wait for it to copy, and only then be told it
/// isn't allowed.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    let onCancelled: () -> Void

    private static let allowedTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .rtf, .commaSeparatedText]
        // Office formats aren't in `UTType`'s static list, so they're built
        // from their identifiers; `compactMap` drops any the OS doesn't know.
        let officeIdentifiers = [
            "org.openxmlformats.wordprocessingml.document",   // .docx
            "org.openxmlformats.spreadsheetml.sheet",         // .xlsx
            "org.openxmlformats.presentationml.presentation", // .pptx
            "com.microsoft.word.doc",
            "com.microsoft.excel.xls",
            "com.microsoft.powerpoint.ppt",
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
///
/// `UIImagePickerController` is deprecated for *library* access — that's what
/// `PhotosPicker` replaced — but it remains the supported way to capture from
/// the camera with a system UI. `AVCaptureSession` is the alternative and
/// means building the entire capture interface by hand.
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
        // Two minutes. Long enough for anything sent in a chat, short enough
        // that the file stays a reasonable size.
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
               // Re-encoded to JPEG rather than sent as a `UIImage`: the
               // capture is already in memory uncompressed, and 0.8 quality
               // is visually indistinguishable at a fraction of the size.
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
