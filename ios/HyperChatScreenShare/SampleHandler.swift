import ReplayKit
import Network
import CoreImage
import os

/// Broadcast Upload Extension: receives the phone's screen from ReplayKit and
/// passes downscaled JPEG frames to HyperChat over 127.0.0.1.
///
/// Extensions are limited to ~50 MB of memory, so frames are throttled to 12 fps,
/// capped at 1280 px on the long side, and dropped (not queued) while the
/// previous frame is still being sent.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "com.hyperchat.screenshare.send")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var isReady = false
    private var isSending = false
    private var lastSent: CFTimeInterval = 0
    private var finished = false

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let logger = Logger(subsystem: "com.HyperChat.ScreenShare", category: "broadcast")

    private static let minInterval: CFTimeInterval = 1.0 / 12
    private static let maxLongSide: CGFloat = 1280
    private static let jpegQuality: CGFloat = 0.55

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let port = NWEndpoint.Port(rawValue: ScreenShareWire.port) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.withLock { self.isReady = true }
                connection.send(content: ScreenShareWire.encode(ScreenShareWire.magic), completion: .idempotent)
            case .waiting, .failed:
                // Nothing is listening: HyperChat isn't in a video call.
                self.finish("Start a video call in HyperChat first, then share your screen.")
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CACurrentMediaTime()
        let canSend: Bool = lock.withLock {
            guard isReady, !isSending, now - lastSent >= Self.minInterval else { return false }
            isSending = true
            lastSent = now
            return true
        }
        guard canSend else { return }

        guard let frame = makeFrame(from: sampleBuffer) else {
            lock.withLock { isSending = false }
            return
        }

        connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.withLock { self.isSending = false }
            if error != nil {
                self.finish("HyperChat stopped receiving the screen share.")
            }
        })
    }

    /// Length-prefixed frame: [UInt32 length][UInt8 orientation][JPEG].
    private func makeFrame(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let longSide = max(image.extent.width, image.extent.height)
        if longSide > Self.maxLongSide {
            let scale = Self.maxLongSide / longSide
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard let jpeg = ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Self.jpegQuality]
        ) else { return nil }

        let orientation = (CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber)?.uint8Value ?? 1

        var frame = ScreenShareWire.encode(UInt32(jpeg.count + 1))
        frame.append(orientation)
        frame.append(jpeg)
        return frame
    }

    private func finish(_ message: String) {
        let shouldFinish: Bool = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldFinish else { return }
        connection?.cancel()
        finishBroadcastWithError(NSError(
            domain: "com.hyperchat.screenshare",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}
