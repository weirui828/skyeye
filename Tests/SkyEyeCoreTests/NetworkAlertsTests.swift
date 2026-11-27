import XCTest
@testable import SkyEyeCore

final class NetworkAlertsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func talker(_ name: String, flags: [ConnectionFlag] = [], ports: [Int] = [443], owner: String = "Google", inbound: Int = 0) -> Talker {
        Talker(
            name: name, section: .apps, path: "", pids: [1], signer: nil,
            peers: [Peer(owner: owner, count: 1, ports: ports, ips: ["192.0.2.1"], hosts: [], inbound: inbound)],
            count: 1, flags: flags, firstSeen: start, earlier: []
        )
    }

    private func sent(_ name: String, _ bytes: UInt64) -> TrafficProgram {
        TrafficProgram(name: name, bytesIn: 0, bytesOut: bytes, peers: [])
    }

    func testAlertFlagsAndRiskyPortsAlertButNotesDoNot() {
        let talkers = [
            talker("Unsigned", flags: [ConnectionFlag(.alert, "Not code-signed"), ConnectionFlag(.note, "New: first seen talking out today")]),
            talker("Torish", ports: [443, 9050], owner: "203.0.113.9"),
            talker("Server", ports: [9050], inbound: 2),
        ]
        let result = NetworkAlerts.evaluate(talkers: talkers, traffic: [], state: AlertState(), now: start)
        XCTAssertEqual(result.current.map(\.text), ["Not code-signed", "Connects to 203.0.113.9 on port 9050, Tor"])
        XCTAssertEqual(result.fresh.count, 2)
    }

    func testAnAlertIsSaidOnceADayAndTrustedOrMutedProgramsStayQuiet() {
        let talkers = [talker("Unsigned", flags: [ConnectionFlag(.alert, "Not code-signed")])]
        var state = NetworkAlerts.evaluate(talkers: talkers, traffic: [], state: AlertState(), now: start).state
        let again = NetworkAlerts.evaluate(talkers: talkers, traffic: [], state: state, now: start + 60)
        XCTAssertEqual(again.current.count, 1)
        XCTAssertTrue(again.fresh.isEmpty)
        XCTAssertEqual(NetworkAlerts.evaluate(talkers: talkers, traffic: [], state: again.state, now: start + 25 * 3600).fresh.count, 1)

        state = AlertState()
        state.mutedUntil["Unsigned"] = start + 3600
        let muted = NetworkAlerts.evaluate(talkers: talkers, traffic: [], state: state, now: start)
        XCTAssertEqual(muted.current.count, 1)
        XCTAssertTrue(muted.fresh.isEmpty)

        state = AlertState()
        state.trusted = ["Unsigned"]
        XCTAssertTrue(NetworkAlerts.evaluate(talkers: talkers, traffic: [], state: state, now: start).current.isEmpty)
    }

    func testUploadSpikesCountAgainstEachProgramsUsual() {
        var state = AlertState()
        var now = start
        var total: UInt64 = 0
        // A program that sends about 1 MB a minute, scanned every minute.
        for _ in 0...6 {
            total += 1_000_000
            state = NetworkAlerts.evaluate(talkers: [], traffic: [sent("Backup", total)], state: state, now: now).state
            now += 60
        }
        XCTAssertEqual(state.uploadSamples["Backup"], 6)
        XCTAssertEqual(state.typicalUpload["Backup"] ?? 0, 1_000_000, accuracy: 1)

        // 30 MB is thirty times its usual but under the floor; 80 MB is a spike.
        total += 30_000_000
        let small = NetworkAlerts.evaluate(talkers: [], traffic: [sent("Backup", total)], state: state, now: now)
        XCTAssertTrue(small.current.isEmpty)
        now += 60
        total += 80_000_000
        let spike = NetworkAlerts.evaluate(talkers: [], traffic: [sent("Backup", total)], state: small.state, now: now)
        XCTAssertEqual(spike.current.count, 1)
        XCTAssertTrue(spike.current[0].text.hasPrefix("Uploading 80 MB a minute"))
        // The spike does not become the usual.
        XCTAssertLessThan(spike.state.typicalUpload["Backup"] ?? 0, 10_000_000)
    }

    func testUploadIgnoresClosedConnectionsLongGapsAndNewProgramsBelowTheCeiling() {
        var state = NetworkAlerts.evaluate(talkers: [], traffic: [sent("App", 900_000_000)], state: AlertState(), now: start).state
        // Fewer bytes than before: connections closed.
        state = NetworkAlerts.evaluate(talkers: [], traffic: [sent("App", 10)], state: state, now: start + 60).state
        XCTAssertNil(state.uploadSamples["App"])
        // An hour's gap is not compared.
        let gap = NetworkAlerts.evaluate(talkers: [], traffic: [sent("App", 900_000_000)], state: state, now: start + 3700)
        XCTAssertTrue(gap.current.isEmpty)
        // A program still being learned alerts only above 500 MB a minute.
        let learning = NetworkAlerts.evaluate(talkers: [], traffic: [sent("App", 1_000_000_000)], state: gap.state, now: start + 3760)
        XCTAssertTrue(learning.current.isEmpty)
        let huge = NetworkAlerts.evaluate(talkers: [], traffic: [sent("App", 1_700_000_000)], state: learning.state, now: start + 3820)
        XCTAssertEqual(huge.current.count, 1)
    }
}
