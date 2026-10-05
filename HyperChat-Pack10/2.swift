// В ChatViewModel.swift (Pack 10) замени целия метод `sendDocument(from:)` с този.
//
// FIX: AttachmentPolicy съществуваше, но нищо не я викаше — документите се
// изпращаха без проверка. Сега файлът се проверява по съдържание, преди да
// бъде криптиран и качен.

    func sendDocument(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            errorMessage = "Couldn't read that file: \(error.localizedDescription)"
            return
        }

        switch AttachmentPolicy.inspect(data: data, declaredExtension: url.pathExtension) {
        case .failure(let rejection):
            errorMessage = rejection.localizedDescription
            return
        case .success:
            break
        }

        await sendMediaGuarded {
            try await self.messagingService.sendMedia(
                rawData: data, thumbnail: nil, mediaType: .document, in: self.conversation
            )
        }
    }
