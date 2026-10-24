import XCTest
@testable import Rally

final class RallyTests: XCTestCase {
    func testServerAddressAllowsHTTPSAndLocalHTTPOnly() throws {
        for address in ["https://lobby.example.com", "http://localhost:3000", "http://192.168.1.20:3000", "http://10.0.0.3:3000", "http://[::1]:3000", "http://mac.local:3000"] {
            XCTAssertNoThrow(try ServerAddress.parse(address), address)
        }
        for address in ["http://example.com", "https://user:pass@example.com", "https://example.com/api", "https://example.com?token=abc", "https://example.com#fragment", "http://192.168.1.999", "https://example.com:0", "file:///tmp"] {
            XCTAssertThrowsError(try ServerAddress.parse(address), address)
        }
    }

    func testRoomRequiresTwoReadyPlayersBeforeStarting() {
        let host = Player(id: "host", name: "Kai", avatar: 0, host: true, ready: true)
        let waiting = Player(id: "guest", name: "Maya", avatar: 1, host: false, ready: false)
        let ready = Player(id: "guest", name: "Maya", avatar: 1, host: false, ready: true)
        func room(_ players: [Player], status: String = "waiting") -> Room {
            Room(code: "482916", locked: false, status: status, createdAt: "2026-10-24", members: players)
        }
        XCTAssertFalse(room([host]).canStart)
        XCTAssertFalse(room([host, waiting]).canStart)
        XCTAssertTrue(room([host, ready]).canStart)
        XCTAssertFalse(room([host, ready], status: "started").canStart)
        XCTAssertEqual(room([host]).displayCode, "482 916")
    }

    func testPublicRoomDecodesWithoutMembershipCredentials() throws {
        let data = Data(#"{"room":{"code":"482916","locked":false,"status":"waiting","createdAt":"2026-10-24","members":[{"id":"1","name":"Kai","avatar":0,"host":true,"ready":true}]}}"#.utf8)
        let response = try JSONDecoder().decode(RoomResponse.self, from: data)
        XCTAssertEqual(response.room.members.first?.name, "Kai")
        XCTAssertEqual(response.room.readyCount, 1)
    }
}
