#if canImport(UIKit) && !os(watchOS)
import UIKit
import Foundation

/// Streams periodic JPEG screenshot frames to WebSocket subscribers.
/// Frame format: `[4-byte sequence number (LE uint32)][JPEG data]`
final class ScreenshotStreamer {
    private let broadcaster: EventBroadcaster
    private let subscriptionManager: SubscriptionManager
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.apus.screenshot-streamer", qos: .utility)

    private var sequenceNumber: UInt32 = 0
    private var isSending = false
    private let sendLock = NSLock()

    /// Default frames per second.
    static let defaultFPS: Double = 5
    /// Maximum frames per second.
    static let maxFPS: Double = 15
    /// Default JPEG quality (0.0–1.0).
    static let defaultQuality: CGFloat = 1.0
    /// Default scale factor.
    static let defaultScale: CGFloat = 2.0

    init(broadcaster: EventBroadcaster, subscriptionManager: SubscriptionManager) {
        self.broadcaster = broadcaster
        self.subscriptionManager = subscriptionManager
    }

    /// Start streaming at the given FPS.
    func start(
        fps: Double = defaultFPS,
        scale: CGFloat = defaultScale,
        quality: CGFloat = defaultQuality
    ) {
        stop()

        let clampedFPS = min(max(fps, 1), Self.maxFPS)
        let interval = 1.0 / clampedFPS

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.captureAndBroadcast(scale: scale, quality: quality)
        }
        timer.resume()
        self.timer = timer
    }

    /// Stop streaming.
    func stop() {
        timer?.cancel()
        timer = nil
        sendLock.lock()
        sequenceNumber = 0
        isSending = false
        sendLock.unlock()
    }

    /// Whether the streamer is currently running.
    var isStreaming: Bool {
        timer != nil
    }

    // MARK: - Private

    private func captureAndBroadcast(scale: CGFloat, quality: CGFloat) {
        // Frame skipping: skip if previous frame hasn't finished sending
        guard beginSend() else {
            return
        }

        let subscribers = subscriptionManager.subscribers(for: EventBroadcaster.screenshotsChannel)
        guard !subscribers.isEmpty else {
            markSendComplete()
            return
        }

        Task { @MainActor in
            let jpegData = Self.captureJPEG(scale: scale, quality: quality)

            if let jpegData {
                let seq = self.nextSequenceNumber()

                // Build frame: [4-byte seq LE uint32][JPEG data]
                var frame = Data(capacity: 4 + jpegData.count)
                var seqLE = seq.littleEndian
                withUnsafeBytes(of: &seqLE) { frame.append(contentsOf: $0) }
                frame.append(jpegData)

                self.broadcaster.broadcastScreenshotFrame(frame, to: subscribers)
            }

            self.markSendComplete()
        }
    }

    private func markSendComplete() {
        sendLock.lock()
        isSending = false
        sendLock.unlock()
    }

    private func beginSend() -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }
        if isSending {
            return false
        }
        isSending = true
        return true
    }

    private func nextSequenceNumber() -> UInt32 {
        sendLock.lock()
        defer { sendLock.unlock() }
        let seq = sequenceNumber
        sequenceNumber &+= 1
        return seq
    }

    /// Capture the current screen as JPEG data.
    @MainActor
    static func captureJPEG(
        scale: CGFloat = defaultScale,
        quality: CGFloat = defaultQuality
    ) -> Data? {
        guard let window = preferredCaptureWindow() else { return nil }

        let renderer = UIGraphicsImageRenderer(
            size: window.bounds.size,
            format: {
                let format = UIGraphicsImageRendererFormat()
                format.scale = scale
                return format
            }()
        )

        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }

        return image.jpegData(compressionQuality: quality)
    }

    @MainActor
    private static func preferredCaptureWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                activationPriority(lhs.activationState) > activationPriority(rhs.activationState)
            }

        for scene in scenes {
            if let keyWindow = scene.windows.first(where: { $0.isKeyWindow && !$0.isHidden }) {
                return keyWindow
            }
            if let visibleWindow = scene.windows.first(where: {
                !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal
            }) {
                return visibleWindow
            }
        }
        return nil
    }

    private static func activationPriority(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive:
            return 3
        case .foregroundInactive:
            return 2
        case .background:
            return 1
        case .unattached:
            return 0
        @unknown default:
            return -1
        }
    }
}
#endif
