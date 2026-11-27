import XCTest
@testable import SkyEyeCore

final class NetworkActivityTests: XCTestCase {
    private func flow(_ pid: Int32 = 10, local: String = "192.168.1.2", localPort: Int = 50000,
                      remote: String = "8.8.8.8", port: Int = 443, incoming: UInt64 = 0, outgoing: UInt64 = 0,
                      proto: String = "tcp4") -> Traffic.Flow {
        Traffic.Flow(pid: pid, proto: proto, localPort: localPort, ip: remote, port: port,
                     bytesIn: incoming, bytesOut: outgoing, localIP: local)
    }
    private func at(_ time: Double) -> Date { Date(timeIntervalSince1970: time) }

    func testRatesUseSocketDeltasAndActualElapsedTime() {
        var recorder = Activity.Recorder()
        let baseline = recorder.record([flow(incoming: 10_000, outgoing: 2_000)], at: at(100))
        XCTAssertTrue(baseline.warmingUp)
        XCTAssertEqual(baseline.received, 0)
        let next = recorder.record([flow(incoming: 10_800, outgoing: 2_100)], at: at(102))
        XCTAssertFalse(next.warmingUp)
        XCTAssertEqual(next.received, 400)
        XCTAssertEqual(next.sent, 50)
        XCTAssertEqual(next.links[0].connections, 1)
        XCTAssertEqual(next.links[0].received, 400)
    }

    func testClosedConnectionsDoNotHideTrafficOnSurvivingSockets() {
        var recorder = Activity.Recorder()
        _ = recorder.record([flow(incoming: 50_000), flow(localPort: 50001, incoming: 1_000)], at: at(100))
        let next = recorder.record([flow(localPort: 50001, incoming: 1_200)], at: at(101))
        XCTAssertEqual(next.received, 200)
        XCTAssertEqual(next.links[0].connections, 1)
        let reset = recorder.record([flow(localPort: 50001, incoming: 10)], at: at(102))
        XCTAssertEqual(reset.received, 0)
        let new = recorder.record([flow(localPort: 50002, incoming: 300)], at: at(103))
        XCTAssertEqual(new.received, 300)
        let gap = recorder.record([flow(localPort: 50002, incoming: 20_000)], at: at(110))
        XCTAssertTrue(gap.warmingUp)
        XCTAssertEqual(gap.received, 0)
    }

    func testInternalSocketsArePairedAndCountedOnceInBothDirections() {
        var recorder = Activity.Recorder()
        let identities: [Int32: Activity.Identity] = [10: .init(id: "browser", name: "Browser"), 20: .init(id: "api", name: "API")]
        func pair(_ incoming: UInt64, _ outgoing: UInt64) -> [Traffic.Flow] {
            [flow(10, local: "127.0.0.1", remote: "127.0.0.1", port: 8000, incoming: incoming, outgoing: outgoing),
             flow(20, local: "127.0.0.1", localPort: 8000, remote: "127.0.0.1", port: 50000, incoming: outgoing, outgoing: incoming)]
        }
        _ = recorder.record(pair(100, 200), identities: identities, at: at(100))
        let sample = recorder.record(pair(500, 400), identities: identities, at: at(101))
        XCTAssertEqual(sample.nodes.count, 2)
        XCTAssertEqual(sample.links.count, 1)
        XCTAssertEqual(sample.links[0].connections, 1)
        XCTAssertEqual(sample.internalRate, 600)
        XCTAssertEqual(sample.sent + sample.received, 0)
        // The link is ordered API → Browser, reversing the lower PID's socket counters.
        XCTAssertEqual(sample.links[0].from, "api")
        XCTAssertEqual(sample.links[0].sent, 400)
        XCTAssertEqual(sample.links[0].received, 200)
        XCTAssertEqual(sample.links[0].ports, [8000, 50000])
    }

    func testUDPPairAndSameMachineInterfaceAddressAreInternal() {
        var recorder = Activity.Recorder()
        let sample = recorder.record([
            flow(10, localPort: 50000, remote: "192.168.1.2", port: 5353, proto: "udp4"),
            flow(20, localPort: 5353, remote: "192.168.1.2", port: 50000, proto: "udp4"),
        ], at: at(100))
        XCTAssertEqual(sample.links.count, 1)
        XCTAssertTrue(sample.links[0].local)
        XCTAssertEqual(sample.links[0].protocols, ["UDP"])
        XCTAssertEqual(sample.nodes.filter { $0.kind == "remote" }.count, 0)
    }

    func testSelfConnectionsAndUnattributedLocalEndpointRemainVisible() {
        var recorder = Activity.Recorder()
        let sample = recorder.record([
            flow(local: "::1", localPort: 50000, remote: "::1", port: 8000, proto: "tcp6"),
            flow(local: "::1", localPort: 8000, remote: "::1", port: 50000, proto: "tcp6"),
            flow(20, local: "127.0.0.1", remote: "127.0.0.1", port: 5432),
        ], at: at(100))
        XCTAssertEqual(sample.links.count, 2)
        XCTAssertEqual(sample.links.reduce(0) { $0 + $1.connections }, 2)
        XCTAssertEqual(sample.nodes.filter { $0.kind == "local" }.count, 1)
    }

    func testUnknownRemoteAddressesStayDistinctAndGroupsRetainPIDs() {
        var recorder = Activity.Recorder()
        let sample = recorder.record([
            flow(remote: "203.0.113.1"), flow(11, remote: "203.0.113.2"), flow(12, remote: "203.0.113.1"),
        ], identities: [10: .init(id: "app", name: "App"), 11: .init(id: "app", name: "App"), 12: .init(id: "app", name: "App")], at: at(100))
        XCTAssertEqual(sample.nodes.filter { $0.kind == "remote" }.count, 2)
        XCTAssertEqual(sample.nodes.first { $0.id == "app" }?.pids.sorted(), [10, 11, 12])
        XCTAssertEqual(sample.links.reduce(0) { $0 + $1.connections }, 3)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(sample.chartJSON().utf8)))
    }

    func testKnownHostKeepsItsIPAddressForSearchAndDetails() {
        var recorder = Activity.Recorder()
        let sample = recorder.record([flow(remote: "203.0.113.1")],
                                     owners: ["203.0.113.1": Outgoing.Owned(owner: "Example", host: "api.example.test")], at: at(100))
        XCTAssertEqual(sample.nodes.first { $0.kind == "remote" }?.name, "Example")
        XCTAssertEqual(sample.links[0].hosts, ["203.0.113.1", "api.example.test"])
    }

    func testFrameReaderHandlesSplitUTF8AndRepeatedHeaders() {
        let header = "time,,interface,state,bytes_in,bytes_out,\n"
        let first = header + "12:00:00,程序.10,,,0,0,\n"
        let bytes = Data((first + header + "12:00:01,app.10,,,0,0,\n" + header).utf8)
        var reader = NettopFrames()
        var frames: [String] = []
        for byte in bytes { frames += reader.append(Data([byte])) }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0] + "\n", first)
        XCTAssertTrue(frames[1].contains("12:00:01,app"))
        XCTAssertFalse(reader.overflowed)
    }

    func testParsedFlowsKeepLocalIPv4AndIPv6Addresses() {
        let header = "time,,interface,state,bytes_in,bytes_out,\n"
        let text = header + "12:00:00,app.10,,,0,0,\n"
            + "12:00:00,tcp4 127.0.0.1:50000<->127.0.0.1:8000,lo0,Established,10,20,\n"
            + "12:00:00,tcp6 fe80::1%lo0.50001<->::1.8000,lo0,Established,10,20,\n"
        XCTAssertEqual(Traffic.parseNettop(text) { _ in "app" }.map(\.localIP), ["127.0.0.1", "fe80::1"])
    }

    func testSampleTimeUsesCounterTimeAcrossBufferedFramesAndMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 86_402)
        let header = "time,,interface,state,bytes_in,bytes_out,\n"
        let previous = try XCTUnwrap(NettopFrames.sampledAt(header + "23:59:59.500000,app.10,,,0,0,", near: now, calendar: calendar))
        let next = try XCTUnwrap(NettopFrames.sampledAt(header + "00:00:00.500000,app.10,,,0,0,", near: now, calendar: calendar))
        XCTAssertEqual(previous.timeIntervalSince1970, 86_399.5, accuracy: 0.001)
        XCTAssertEqual(next.timeIntervalSince(previous), 1, accuracy: 0.001)
        XCTAssertNil(NettopFrames.sampledAt("invalid", near: now, calendar: calendar))
    }
}
