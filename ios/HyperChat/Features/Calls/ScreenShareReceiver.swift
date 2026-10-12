import Foundation
import Network
import CoreImage
import CoreVideo
import QuartzCore
import os

/// Receives screen frames from the HyperChat Screen Share extension over
/// 127.0.0.1 and turns them into pixel buffers for the call's video track.
///
/// Only listens while a video call is active, and accepts one connection at
/// a time that must start with the expected handshake.
final class ScreenShareReceiver {
    typealias FrameHandler = (_ pixelBuffer: CVPixelBuffer, _ rotationDegrees: Int, _ timestampNs: Int64) -> Void
    typealias StateHandler = (_ isSharing: Bool) -> Void

    private let queue = DispatchQueue(label: "com.hyperchat.screenshare.receive")
    private let logger = Logger(subsystem: "com.HyperChat", category: "screenshare")
    private var listener: NWListener?
    private var active: NWConnection?
    private var onFrame: FrameHandler?
    private var onState: StateHandler?

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    func start(onFrame: @escaping FrameHandler, onState: @escaping StateHandler) {
        queue.async { [self] in
            guard listener == nil, let port = NWEndpoint.Port(rawValue: ScreenShareWire.port) else { return }
            self.onFrame = onFrame
            self.onState = onState

            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: parameters, on: port)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        self?.logger.error("Screen-share listener failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                logger.error("Couldn't start the screen-share listener")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            if active != nil { endActive() }
            onFrame = nil
            onState = nil
        }
    }

    // MARK: Connection

    private func accept(_ connection: NWConnection) {
        guard active == nil else {
            connection.cancel()
            return
        }
        active = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { if self?.active === connection { self?.endActive() } }
            default:
                break
            }
        }
        connection.start(queue: queue)

        receive(4, on: connection) { [weak self] data in
            guard let self, let data, ScreenShareWire.decodeUInt32(data) == ScreenShareWire.magic else {
                connection.cancel()
                return
            }
            self.onState?(true)
            self.readFrame(on: connection)
        }
    }

    private func endActive() {
        active?.cancel()
        active = nil
        onState?(false)
    }

    private func readFrame(on connection: NWConnection) {
        receive(4, on: connection) { [weak self] header in
            guard let self, let header else { return }
            let length = Int(ScreenShareWire.decodeUInt32(header))
            guard length > 1, length <= ScreenShareWire.maxFrameBytes else {
                connection.cancel()
                return
            }
            self.receive(length, on: connection) { [weak self] body in
                guard let self, let body else { return }
                self.deliver(orientation: body.first ?? 1, jpeg: body.dropFirst())
                self.readFrame(on: connection)
            }
        }
    }

    private func receive(_ count: Int, on connection: NWConnection, completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            guard error == nil, let data, data.count == count else {
                completion(nil)
                return
            }
            completion(data)
        }
    }

    // MARK: Decoding

    private func deliver(orientation: UInt8, jpeg: Data) {
        guard let onFrame,
              let image = CIImage(data: jpeg),
              let pixelBuffer = makePixelBuffer(size: image.extent.size) else { return }
        ciContext.render(image, to: pixelBuffer)
        let timestamp = Int64(CACurrentMediaTime() * 1_000_000_000)
        onFrame(pixelBuffer, Self.rotation(forOrientation: orientation), timestamp)
    }

    /// `RPVideoSampleOrientationKey` uses CGImagePropertyOrientation values.
    private static func rotation(forOrientation raw: UInt8) -> Int {
        switch raw {
        case 3: return 180   // down
        case 6: return 90    // right
        case 8: return 270   // left
        default: return 0    // up
        }
    }

    private func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(size.width),
                kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
