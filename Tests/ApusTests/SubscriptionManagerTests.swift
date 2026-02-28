import XCTest
@testable import Apus

final class SubscriptionManagerTests: XCTestCase {

    // MARK: - Subscribe / Unsubscribe

    func testSubscribe_singleConnection_singleChannel() {
        let manager = SubscriptionManager()
        let connId = UUID()

        manager.subscribe(connectionId: connId, channel: "logs")

        XCTAssertEqual(manager.subscriberCount(for: "logs"), 1)
        XCTAssertTrue(manager.subscribers(for: "logs").contains(connId))
    }

    func testSubscribe_multipleConnections_sameChannel() {
        let manager = SubscriptionManager()
        let conn1 = UUID()
        let conn2 = UUID()

        manager.subscribe(connectionId: conn1, channel: "logs")
        manager.subscribe(connectionId: conn2, channel: "logs")

        XCTAssertEqual(manager.subscriberCount(for: "logs"), 2)
        XCTAssertEqual(manager.subscribers(for: "logs"), [conn1, conn2])
    }

    func testSubscribe_sameConnection_multipleChannels() {
        let manager = SubscriptionManager()
        let connId = UUID()

        manager.subscribe(connectionId: connId, channel: "logs")
        manager.subscribe(connectionId: connId, channel: "network")

        XCTAssertEqual(manager.subscriberCount(for: "logs"), 1)
        XCTAssertEqual(manager.subscriberCount(for: "network"), 1)
        XCTAssertEqual(manager.activeChannels, ["logs", "network"])
    }

    func testSubscribe_duplicate_doesNotDoubleCount() {
        let manager = SubscriptionManager()
        let connId = UUID()

        manager.subscribe(connectionId: connId, channel: "logs")
        manager.subscribe(connectionId: connId, channel: "logs")

        XCTAssertEqual(manager.subscriberCount(for: "logs"), 1)
    }

    func testUnsubscribe_removesSubscription() {
        let manager = SubscriptionManager()
        let connId = UUID()

        manager.subscribe(connectionId: connId, channel: "logs")
        manager.unsubscribe(connectionId: connId, channel: "logs")

        XCTAssertEqual(manager.subscriberCount(for: "logs"), 0)
        XCTAssertTrue(manager.subscribers(for: "logs").isEmpty)
    }

    func testUnsubscribe_nonExistent_doesNotCrash() {
        let manager = SubscriptionManager()
        manager.unsubscribe(connectionId: UUID(), channel: "logs")
        XCTAssertEqual(manager.subscriberCount(for: "logs"), 0)
    }

    // MARK: - RemoveAll

    func testRemoveAll_clearsAllChannelsForConnection() {
        let manager = SubscriptionManager()
        let connId = UUID()

        manager.subscribe(connectionId: connId, channel: "logs")
        manager.subscribe(connectionId: connId, channel: "network")
        manager.subscribe(connectionId: connId, channel: "screenshots")

        manager.removeAll(for: connId)

        XCTAssertEqual(manager.subscriberCount(for: "logs"), 0)
        XCTAssertEqual(manager.subscriberCount(for: "network"), 0)
        XCTAssertEqual(manager.subscriberCount(for: "screenshots"), 0)
        XCTAssertTrue(manager.activeChannels.isEmpty)
    }

    func testRemoveAll_doesNotAffectOtherConnections() {
        let manager = SubscriptionManager()
        let conn1 = UUID()
        let conn2 = UUID()

        manager.subscribe(connectionId: conn1, channel: "logs")
        manager.subscribe(connectionId: conn2, channel: "logs")

        manager.removeAll(for: conn1)

        XCTAssertEqual(manager.subscriberCount(for: "logs"), 1)
        XCTAssertTrue(manager.subscribers(for: "logs").contains(conn2))
    }

    // MARK: - Options

    func testOptions_storedPerSubscription() {
        let manager = SubscriptionManager()
        let connId = UUID()
        let opts: [String: Any] = ["fps": 10, "scale": 0.5]

        manager.subscribe(connectionId: connId, channel: "screenshots", options: opts)

        let retrieved = manager.options(for: connId, channel: "screenshots")
        XCTAssertEqual(retrieved?["fps"] as? Int, 10)
        XCTAssertEqual(retrieved?["scale"] as? Double, 0.5)
    }

    func testOptions_nilWhenNotSubscribed() {
        let manager = SubscriptionManager()
        XCTAssertNil(manager.options(for: UUID(), channel: "screenshots"))
    }

    // MARK: - ActiveChannels

    func testActiveChannels_emptyWhenNoSubscriptions() {
        let manager = SubscriptionManager()
        XCTAssertTrue(manager.activeChannels.isEmpty)
    }

    func testActiveChannels_reflectsCurrentState() {
        let manager = SubscriptionManager()
        let connId = UUID()

        manager.subscribe(connectionId: connId, channel: "logs")
        XCTAssertEqual(manager.activeChannels, ["logs"])

        manager.subscribe(connectionId: connId, channel: "network")
        XCTAssertEqual(manager.activeChannels, ["logs", "network"])

        manager.unsubscribe(connectionId: connId, channel: "logs")
        XCTAssertEqual(manager.activeChannels, ["network"])
    }

    // MARK: - Callback

    func testOnSubscriptionChange_calledOnSubscribe() {
        let manager = SubscriptionManager()
        var callbackChannel: String?
        var callbackCount: Int?

        manager.onSubscriptionChange = { channel, count in
            callbackChannel = channel
            callbackCount = count
        }

        manager.subscribe(connectionId: UUID(), channel: "logs")

        XCTAssertEqual(callbackChannel, "logs")
        XCTAssertEqual(callbackCount, 1)
    }

    func testOnSubscriptionChange_calledOnUnsubscribe() {
        let manager = SubscriptionManager()
        let connId = UUID()
        manager.subscribe(connectionId: connId, channel: "logs")

        var callbackCount: Int?
        manager.onSubscriptionChange = { _, count in
            callbackCount = count
        }

        manager.unsubscribe(connectionId: connId, channel: "logs")
        XCTAssertEqual(callbackCount, 0)
    }

    func testOnSubscriptionChange_calledForEachChannelOnRemoveAll() {
        let manager = SubscriptionManager()
        let connId = UUID()
        manager.subscribe(connectionId: connId, channel: "logs")
        manager.subscribe(connectionId: connId, channel: "network")

        var notifications: [(String, Int)] = []
        manager.onSubscriptionChange = { channel, count in
            notifications.append((channel, count))
        }

        manager.removeAll(for: connId)

        XCTAssertEqual(notifications.count, 2)
        let channels = Set(notifications.map(\.0))
        XCTAssertEqual(channels, ["logs", "network"])
        // Both should report 0 subscribers
        XCTAssertTrue(notifications.allSatisfy { $0.1 == 0 })
    }

    // MARK: - Status

    func testStatus_returnsExpectedShape() {
        let manager = SubscriptionManager()
        let conn1 = UUID()
        let conn2 = UUID()

        manager.subscribe(connectionId: conn1, channel: "logs")
        manager.subscribe(connectionId: conn2, channel: "logs")
        manager.subscribe(connectionId: conn1, channel: "network")

        let status = manager.status()
        XCTAssertEqual(status["connections"] as? Int, 2)

        let channels = status["channels"] as? [String: Int]
        XCTAssertEqual(channels?["logs"], 2)
        XCTAssertEqual(channels?["network"], 1)
    }
}
