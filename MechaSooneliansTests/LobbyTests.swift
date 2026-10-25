import XCTest
@testable import MechaSoonelians

final class LobbyTests: XCTestCase {
    func testLeaderboardUsesAccumulatedTotalsAndSharesRanksForTies() throws {
        let first = Player(id: UUID(), name: "Bok", avatar: 0, role: .seeker, isReady: true, points: 0, totalPoints: 220)
        let second = Player(id: UUID(), name: "Ryu", avatar: 1, role: .hider, isReady: true, points: 120, totalPoints: 220)
        let third = Player(id: UUID(), name: "Kai", avatar: 2, role: .hider, isReady: true, points: 150, totalPoints: 150)
        var state = GameState()
        state.players = [third, second, first]
        state.roundNumber = 2
        let decoded = try JSONDecoder().decode(GameState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.leaderboard.last?.id, third.id)
        XCTAssertEqual(decoded.rank(of: first), 1)
        XCTAssertEqual(decoded.rank(of: second), 1)
        XCTAssertEqual(decoded.rank(of: third), 3)
        XCTAssertEqual(decoded.player(first.id)?.points, 0)
        XCTAssertEqual(decoded.player(first.id)?.totalPoints, 220)
        // Existing saved/server states without the new optional fields still decode.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        legacy.removeValue(forKey: "roundNumber")
        legacy["players"] = try XCTUnwrap(legacy["players"] as? [[String: Any]]).map { player in
            var value = player; value.removeValue(forKey: "totalPoints"); return value
        }
        let old = try JSONDecoder().decode(GameState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.roundNumber)
        XCTAssertEqual(old.leaderboard.first?.id, third.id)
    }

    func testServerAddressAllowsHTTPSAndLocalHTTPOnly() throws {
        for address in ["https://lobby.example.com", "http://localhost:3000", "http://192.168.1.20:3000", "http://10.0.0.3:3000", "http://[::1]:3000", "http://mac.local:3000"] {
            XCTAssertNoThrow(try ServerAddress.parse(address), address)
        }
        for address in ["http://example.com", "https://user:pass@example.com", "https://example.com/api", "https://example.com?token=abc", "https://example.com#fragment", "http://192.168.1.999", "https://example.com:0", "file:///tmp"] {
            XCTAssertThrowsError(try ServerAddress.parse(address), address)
        }
    }

    func testRoomRequiresTwoReadyPlayersBeforeStarting() {
        let host = LobbyPlayer(id: "host", name: "Kai", avatar: 0, host: true, ready: true)
        let waiting = LobbyPlayer(id: "guest", name: "Maya", avatar: 1, host: false, ready: false)
        let ready = LobbyPlayer(id: "guest", name: "Maya", avatar: 1, host: false, ready: true)
        func room(_ players: [LobbyPlayer], status: String = "waiting") -> Room {
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
