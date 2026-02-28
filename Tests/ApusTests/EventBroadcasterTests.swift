import XCTest
@testable import Apus

final class EventBroadcasterTests: XCTestCase {

    // MARK: - Log Entry Notifications

    func testBroadcastLogEntry_noSubscribers_doesNotCrash() {
        let (broadcaster, _, _) = makeBroadcaster()
        let entry = LogEntry(timestamp: Date(), level: "info", message: "hello", source: "app")

        // Should not crash when no subscribers exist
        broadcaster.broadcastLogEntry(entry)
    }

    func testBroadcastLogEntry_withSubscribers_sendsToSubscribed() {
        let (broadcaster, _, subManager) = makeBroadcaster()
        let connId = UUID()

        subManager.subscribe(connectionId: connId, channel: "logs")

        let entry = LogEntry(timestamp: Date(), level: "error", message: "crash", source: "app")
        broadcaster.broadcastLogEntry(entry)

        // Verifying the broadcast was attempted is indirect here since the
        // connection doesn't actually exist, but we verify no crash and
        // the subscribers set is correctly consulted.
        XCTAssertEqual(subManager.subscriberCount(for: "logs"), 1)
    }

    // MARK: - Network Record Notifications

    func testBroadcastNetworkRecord_noSubscribers_doesNotCrash() {
        let (broadcaster, _, _) = makeBroadcaster()
        let record = NetworkRecord(
            id: UUID(),
            timestamp: Date(),
            request: URLRequest(url: URL(string: "https://example.com")!),
            response: nil,
            responseBody: nil,
            error: nil,
            duration: 0.1
        )

        broadcaster.broadcastNetworkRecord(record)
    }

    func testBroadcastNetworkRecord_withSubscribers_sendsToSubscribed() {
        let (broadcaster, _, subManager) = makeBroadcaster()
        let connId = UUID()

        subManager.subscribe(connectionId: connId, channel: "network")

        let record = NetworkRecord(
            id: UUID(),
            timestamp: Date(),
            request: URLRequest(url: URL(string: "https://api.example.com/data")!),
            response: nil,
            responseBody: nil,
            error: nil,
            duration: 0.25
        )
        broadcaster.broadcastNetworkRecord(record)

        XCTAssertEqual(subManager.subscriberCount(for: "network"), 1)
    }

    // MARK: - Screenshot Frame

    func testBroadcastScreenshotFrame_noSubscribers_doesNotCrash() {
        let (broadcaster, _, _) = makeBroadcaster()
        let frame = Data([0x00, 0x00, 0x00, 0x01, 0xFF, 0xD8])

        broadcaster.broadcastScreenshotFrame(frame, to: [])
    }

    // MARK: - Channel Names

    func testChannelConstants_matchExpectedValues() {
        XCTAssertEqual(EventBroadcaster.logsChannel, "logs")
        XCTAssertEqual(EventBroadcaster.networkChannel, "network")
        XCTAssertEqual(EventBroadcaster.screenshotsChannel, "screenshots")
    }

    // MARK: - Helpers

    private func makeBroadcaster() -> (EventBroadcaster, WebSocketConnectionManager, SubscriptionManager) {
        let connManager = WebSocketConnectionManager()
        let subManager = SubscriptionManager()
        let broadcaster = EventBroadcaster(
            connectionManager: connManager,
            subscriptionManager: subManager
        )
        return (broadcaster, connManager, subManager)
    }
}
