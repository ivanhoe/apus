import XCTest
@testable import Apus

final class WebSocketConnectionManagerTests: XCTestCase {

    func testAdd_incrementsCount() {
        let manager = WebSocketConnectionManager()
        let connection = makeConnection()

        let added = manager.add(connection)

        XCTAssertTrue(added)
        XCTAssertEqual(manager.count, 1)
    }

    func testAdd_maxConnections_rejectsExcess() {
        let manager = WebSocketConnectionManager()

        for _ in 0..<WebSocketConnectionManager.maxConnections {
            let added = manager.add(makeConnection())
            XCTAssertTrue(added)
        }

        let excess = manager.add(makeConnection())
        XCTAssertFalse(excess)
        XCTAssertEqual(manager.count, WebSocketConnectionManager.maxConnections)
    }

    func testRemove_decrementsCount() {
        let manager = WebSocketConnectionManager()
        let connection = makeConnection()

        manager.add(connection)
        manager.remove(connection.id)

        XCTAssertEqual(manager.count, 0)
    }

    func testRemove_nonExistent_doesNotCrash() {
        let manager = WebSocketConnectionManager()
        manager.remove(UUID())
        XCTAssertEqual(manager.count, 0)
    }

    func testConnectionForId_returnsCorrectConnection() {
        let manager = WebSocketConnectionManager()
        let connection = makeConnection()

        manager.add(connection)

        XCTAssertNotNil(manager.connection(for: connection.id))
        XCTAssertNil(manager.connection(for: UUID()))
    }

    func testConnectionIds_returnsAllIds() {
        let manager = WebSocketConnectionManager()
        let conn1 = makeConnection()
        let conn2 = makeConnection()

        manager.add(conn1)
        manager.add(conn2)

        XCTAssertEqual(manager.connectionIds, [conn1.id, conn2.id])
    }

    func testDisconnectAll_clearsRegistry() {
        let manager = WebSocketConnectionManager()
        manager.add(makeConnection())
        manager.add(makeConnection())

        manager.disconnectAll()

        XCTAssertEqual(manager.count, 0)
        XCTAssertTrue(manager.connectionIds.isEmpty)
    }

    func testStatus_returnsExpectedShape() {
        let manager = WebSocketConnectionManager()
        manager.add(makeConnection())

        let status = manager.status()
        XCTAssertEqual(status["activeConnections"] as? Int, 1)
        XCTAssertEqual((status["connectionIds"] as? [String])?.count, 1)
    }

    // MARK: - Helpers

    /// Creates a WebSocketConnection with a dummy NWConnection.
    /// The connection is not started — only used to test the manager's bookkeeping.
    private func makeConnection() -> WebSocketConnection {
        // Create a loopback NWConnection that we never start.
        // This is sufficient for testing the manager's add/remove/count logic.
        let nw = NWConnection(
            host: .ipv4(.loopback),
            port: .any,
            using: .tcp
        )
        return WebSocketConnection(connection: nw, queue: .global())
    }
}

import Network
