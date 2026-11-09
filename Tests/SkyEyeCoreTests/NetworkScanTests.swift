import XCTest
@testable import SkyEyeCore

private let home = "/Users/me"
private let root = "/Users/me/dev"
private let claude = "/Users/me/Library/Application Support/Claude/claude-code/2.1.317/x/claude.app/Contents/MacOS/claude --output-format stream-json"

private let lsof = [
    "p958", "crapportd", "f14", "n*:52580", "f15", "n*:52580",
    "p1799", "cpostgres", "f7", "n[::1]:5432", "f8", "n127.0.0.1:5432",
    "p36435", "cDeepSeek Harness", "f21", "n127.0.0.1:57423", "f29", "n127.0.0.1:9230",
    "p44893", "cnode", "f13", "n127.0.0.1:3000",
    "p500", "cpython3.14", "f6", "n0.0.0.0:8000",
    "",
].joined(separator: "\n")

private let ps = [
    "    1     0 11-15:13:00  1000   0.0 /sbin/launchd",
    "  958     1 11-15:12:58  5648   0.1 /usr/libexec/rapportd",
    " 1799     1 11-15:12:24  2128   0.6 /opt/homebrew/opt/postgresql@18/bin/postgres -D /opt/homebrew/var/postgresql@18",
    "36435 36389 03-16:05:40 40096   0.3 /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness --expose-internals",
    "  316     1 01-08:17:57 99000   1.0 \(claude)",
    "44891   316 01-05:31:42  3000   0.0 /bin/zsh -c npm run dev",
    "44892 44891 01-05:31:41  4000   0.0 node /Users/me/dev/petshop/frontend/node_modules/.bin/next dev -H 127.0.0.1 -p 3000",
    "44893 44892 01-05:31:35 95056   0.0 next-server (v16.3.8) ",
    "  500   316    13:01  7616   0.1 /Users/me/dev/atlas/.venv/bin/python -m atlas.serve graph.json --port 8000",
    "",
].joined(separator: "\n")

private let established = [
    "p44643", "cGoogle Chrome Helper (Aperitif)",
    "f20", "n192.168.1.22:50000->142.251.46.69:443",
    "f21", "n[2001:db8::4]:50002->[2a03:2880:f36e:1c5:face:b00c:0:80aa]:443",
    "p777", "cminer", "f5", "n192.168.1.22:50001->203.0.113.7:3333",
    "p500", "cpython3.14", "f9", "n192.168.1.22:8000->192.168.1.40:51000",
    "f10", "n127.0.0.1:50003->127.0.0.1:5432",
    "",
].joined(separator: "\n")

private let chromeHelper =
    "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/156/Helpers/"
    + "Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)"

private func port(_ number: Int, _ address: String, status: Int? = nil, title: String? = nil, debugger: Bool = false) -> ListeningPort {
    ListeningPort(port: number, address: address, status: status, title: title, isDebugger: debugger)
}

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

final class PortScanTests: XCTestCase {
    func testLsofAndPsBecomeListenersAndProcesses() {
        let listeners = PortScan.parseLsof(lsof)
        XCTAssertEqual(listeners.map(\.pid), [958, 1799, 36435, 44893, 500])
        // IPv4 and IPv6 twins fold into one port.
        XCTAssertEqual(listeners[1].ports, [PortScan.BoundPort(port: 5432, address: "[::1]")])
        XCTAssertEqual(listeners[2].ports.map(\.port), [9230, 57423])
        XCTAssertEqual(listeners[2].process, "DeepSeek Harness")

        let procs = PortScan.parsePs(ps)
        XCTAssertEqual(procs[44893]?.command, "next-server (v16.3.8)")
        XCTAssertEqual(procs[1799]?.seconds, 11 * 86_400 + 15 * 3600 + 12 * 60 + 24)
        XCTAssertEqual(PortScan.parseEtime("13:01"), 781)
        XCTAssertEqual(PortScan.parseCwd("p44893\nfcwd\nn/Users/me/dev/petshop/frontend\n")[44893], "/Users/me/dev/petshop/frontend")
    }

    func testAWiderTwinWins() {
        let listeners = PortScan.parseLsof("p1\ncnode\nn127.0.0.1:3000\nn*:3000\n")
        XCTAssertEqual(listeners[0].ports, [PortScan.BoundPort(port: 3000, address: "*")])
    }

    func testWhoStartedAServerAndWhatStopEnds() {
        let procs = PortScan.parsePs(ps)
        XCTAssertEqual(PortScan.startedBy(44893, procs), "Claude session")
        XCTAssertEqual(PortScan.startedBy(1799, procs), "launchd")
        // next-server, the next dev wrapper and the npm shell; never the Claude session.
        XCTAssertEqual(PortScan.stopPids(44893, procs), [44893, 44892, 44891])
        XCTAssertEqual(PortScan.stopPids(500, procs), [500])
    }

    func testAListenerBelongsToTheServiceThatStartedIt() {
        let procs = PortScan.parsePs(ps)
        XCTAssertEqual(PortScan.ancestor(of: 44893, in: [44891: "web"], procs), "web")
        XCTAssertEqual(PortScan.ancestor(of: 44891, in: [44891: "web"], procs), "web")
        XCTAssertNil(PortScan.ancestor(of: 500, in: [44891: "web"], procs))
        XCTAssertNil(PortScan.ancestor(of: 1799, in: [1: "init"], procs), "launchd is nobody's service")
    }

    func testNamesSectionsAndPlaces() {
        XCTAssertEqual(PortScan.section(of: "/usr/libexec/rapportd", process: "rapportd"), .system)
        XCTAssertEqual(
            PortScan.section(of: "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness", process: "DeepSeek Harness"), .apps
        )
        XCTAssertEqual(PortScan.section(of: "codex", process: "codex"), .apps)
        XCTAssertEqual(PortScan.section(of: "next-server (v16.3.8)", process: "node"), .servers)
        XCTAssertEqual(PortScan.script(of: "/x/.venv/bin/python -m atlas.serve g.json", process: "python3.14"), "atlas.serve")
        XCTAssertEqual(
            PortScan.script(
                of: "node /a/ui/node_modules/.bin/../../../../node_modules/.pnpm/vite@8.3.5_x/node_modules/vite/bin/vite.js --host",
                process: "node"
            ),
            "vite"
        )
        XCTAssertEqual(PortScan.script(of: "node host/bin/cabby-host.mjs serve", process: "node"), "cabby-host")
        XCTAssertEqual(PortScan.name(of: "/usr/libexec/rapportd", process: "rapportd", ports: []), "Continuity")
        XCTAssertEqual(
            PortScan.name(of: "node x", process: "node", ports: [port(3000, "127.0.0.1", status: 200, title: "Pet Shop")]), "Pet Shop"
        )
        XCTAssertEqual(
            PortScan.name(of: "node x", process: "node", ports: [port(3000, "127.0.0.1", status: 404, title: "Not Found")]), "x",
            "a title that says nothing falls back to the script"
        )

        var place = PortScan.place(of: "\(root)/cabby/apps/ui", root: root, home: home)
        XCTAssertEqual(place.project, "cabby")
        XCTAssertEqual(place.place, "apps/ui")
        place = PortScan.place(of: "\(root)/cabby/.claude/worktrees/feature/web", root: root, home: home)
        XCTAssertEqual(place.project, "cabby")
        XCTAssertEqual(place.place, "worktree / feature / web")
        place = PortScan.place(of: "\(home)/.notes", root: root, home: home)
        XCTAssertNil(place.project)
        XCTAssertEqual(place.place, "~/.notes")
        place = PortScan.place(of: "/", root: root, home: home)
        XCTAssertNil(place.project)
        XCTAssertEqual(place.place, "")
    }

    func testRisk() {
        XCTAssertEqual(
            PortScan.assess(name: "DSH", process: "DSH", section: .apps, ports: [port(9230, "127.0.0.1", debugger: true)]).risk, .high
        )
        XCTAssertEqual(
            PortScan.assess(name: "x", process: "python", section: .servers, ports: [port(8000, "0.0.0.0", status: 200)]),
            PortScan.Assessment(kind: .web, risk: .high, reasons: ["Open to every network this Mac joins with no login"], exposure: .all)
        )
        XCTAssertEqual(
            PortScan.assess(name: "db", process: "postgres", section: .servers, ports: [port(5432, "192.168.1.5")]).reasons,
            ["Database open to your local network"]
        )
        XCTAssertEqual(
            PortScan.assess(name: "AirPlay", process: "ControlCenter", section: .system, ports: [port(7000, "*", status: 403)]).risk, .medium
        )
        XCTAssertEqual(
            PortScan.assess(name: "x", process: "node", section: .servers, ports: [port(3000, "127.0.0.1", status: 200)]).risk, .low
        )
        XCTAssertEqual(PortScan.assess(name: "Zed", process: "zed", section: .apps, ports: [port(44438, "127.0.0.1")]).risk, .info)
        // A 404 at / still serves the rest: open, not gated.
        XCTAssertEqual(
            PortScan.assess(name: "x", process: "python", section: .servers, ports: [port(8000, "0.0.0.0", status: 404)]).risk, .high
        )
        XCTAssertEqual(
            PortScan.assess(name: "DSH", process: "DSH", section: .apps, ports: [port(57423, "127.0.0.1", status: 401)]).reasons,
            ["This Mac only, asks for a login"]
        )
    }

    func testProbeAnswers() {
        XCTAssertEqual(PortScan.pageTitle("<html><title>Pet Shop</title></html>"), "Pet Shop")
        XCTAssertEqual(PortScan.pageTitle("<TITLE lang=en> Tom &amp; Jerry&#39;s </TITLE>"), "Tom & Jerry's")
        XCTAssertNil(PortScan.pageTitle("{\"detail\":\"Not Found\"}"))
        XCTAssertTrue(PortScan.hasDebuggerFlag("node --inspect=127.0.0.1:9229 app.js", port: 9229))
        XCTAssertTrue(PortScan.hasDebuggerFlag("/x/Chrome --remote-debugging-port=9222", port: 9222))
        XCTAssertFalse(PortScan.hasDebuggerFlag("node --inspect=9229 app.js", port: 3000))
        XCTAssertEqual(PortScan.probeURL(port(8000, "*"), path: "/json/version")?.absoluteString, "http://127.0.0.1:8000/json/version")
        XCTAssertEqual(PortScan.probeURL(port(5173, "[::1]"))?.absoluteString, "http://[::1]:5173/")
    }

    func testOpenAndStop() {
        func program(_ ports: [ListeningPort], section: ProgramSection = .servers, managed: Bool = false) -> ListeningProgram {
            ListeningProgram(
                pid: 1, name: "s", process: "node", command: "node", ports: ports, exposure: .loopback, section: section,
                kind: .web, risk: .low, reasons: [], project: nil, place: "", folder: nil, startedBy: "terminal",
                startedAt: at(0), rssKb: 0, cpu: 0, stopPids: [1], service: nil, managed: managed
            )
        }
        XCTAssertNil(PortScan.openURL(for: program([port(3000, "127.0.0.1")])), "nothing answered HTTP")
        // A web UI that answers 401 until opened with its token: no Open.
        let walled = [port(57423, "127.0.0.1", status: 401)]
        XCTAssertNil(PortScan.openURL(for: program(walled)))
        XCTAssertEqual(
            PortScan.openURL(for: program(walled + [port(3000, "127.0.0.1", status: 200)]))?.absoluteString, "http://localhost:3000/"
        )
        XCTAssertEqual(PortScan.openURL(for: program([port(5173, "[::1]", status: 200)]))?.absoluteString, "http://[::1]:5173/")
        XCTAssertTrue(PortScan.canStop(program([])))
        XCTAssertFalse(PortScan.canStop(program([], section: .apps)), "an app's helper has no Stop")
        XCTAssertTrue(PortScan.canStop(program([], section: .apps, managed: true)), "unless SkyEye runs it")

        let now = at(10 * PortScan.day)
        var old = program([])
        old.startedAt = at(7 * PortScan.day)
        XCTAssertTrue(PortScan.isStale(old, now: now))
        old.section = .system
        XCTAssertFalse(PortScan.isStale(old, now: now))
    }
}

final class OutgoingTests: XCTestCase {
    func testOwnersComeFromTheTableReverseDNSOrWhois() {
        XCTAssertEqual(Outgoing.ownerByPrefix("160.79.104.10"), "Anthropic")
        XCTAssertEqual(Outgoing.ownerByPrefix("2607:6bc0::10"), "Anthropic")
        XCTAssertEqual(Outgoing.ownerByPrefix("172.64.149.246"), "Cloudflare")
        XCTAssertEqual(Outgoing.ownerByPrefix("17.188.143.3"), "Apple")
        XCTAssertEqual(Outgoing.ownerByPrefix("192.168.1.40"), "Local network")
        XCTAssertEqual(Outgoing.ownerByPrefix("fe80:18::e464:847e:88b4:3f0"), "Local network")
        XCTAssertNil(Outgoing.ownerByPrefix("18.97.36.58"))
        // An iPhone on the same Wi-Fi, from a global IPv6 address in the Mac's own /64.
        let lan = Outgoing.localPrefixes(
            "\tinet6 fe80::1%lo0 prefixlen 64\n\tinet6 2001:db8:aa:1500:c99e:7458:2900:4 prefixlen 64 autoconf\n"
        )
        XCTAssertEqual(lan, ["2001:0db8:00aa:1500"])
        XCTAssertEqual(Outgoing.ownerByPrefix("2001:db8:aa:1500::9a", lan: lan), "Local network")
        XCTAssertNil(Outgoing.ownerByPrefix("2001:db8:aa:1501::9a", lan: lan))
        XCTAssertEqual(Outgoing.expand6("2606:4700::6810:922"), ["2606", "4700", "0000", "0000", "0000", "0000", "6810", "0922"])
        XCTAssertNil(Outgoing.expand6("1:2:3:4:5:6:7:8:9"))
        XCTAssertEqual(Outgoing.ownerByHost("ec2-18-97-36-58.compute-1.amazonaws.com."), "AWS")
        XCTAssertEqual(Outgoing.ownerByHost("lb-140-82-112-25-iad.github.com."), "GitHub")
        XCTAssertEqual(Outgoing.ownerByHost("host-1.edge.example.net."), "example.net")
        XCTAssertNil(Outgoing.ownerByHost(""))

        var record = Outgoing.ownerByWhois("NetName: NOTION-IPV6\nOrgName: Notion Labs, Inc.\n")
        XCTAssertEqual(record.owner, "Notion Labs")
        XCTAssertNil(record.referTo)
        record = Outgoing.ownerByWhois("NetName: RIPE-ERX\nOrgName: RIPE Network Coordination Centre\n")
        XCTAssertNil(record.owner)
        XCTAssertEqual(record.referTo, "whois.ripe.net")
        XCTAssertEqual(Outgoing.ownerByWhois("netname: cloud\ndescr: Microsoft\n").owner, "Microsoft")
        XCTAssertEqual(Outgoing.ownerByWhois("netname: ACE-SG\ndescr: 16 COLLYER QUAY # 18-29\ndescr: ACE\n").owner, "ACE")
        XCTAssertEqual(
            Outgoing.ownerByWhois("netname: ALISOFT\ndescr: Aliyun Computing Co., LTD\ndescr: No.391 Wen'er Road\n").owner, "Aliyun Computing"
        )
        XCTAssertEqual(Outgoing.ownerByWhois("OrgName: Amazon Technologies Inc.\n").owner, "AWS")
        XCTAssertNil(Outgoing.ownerByWhois("").owner)
    }

    func testSignaturesBundlesAndNames() {
        XCTAssertEqual(Outgoing.parseCodesign("Authority=Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)"), "OpenAI OpCo, LLC")
        XCTAssertEqual(Outgoing.parseCodesign("Authority=macOS Software Signing\nAuthority=Apple Root CA"), "Apple")
        XCTAssertEqual(Outgoing.parseCodesign("Signature=adhoc"), "ad-hoc")
        XCTAssertEqual(Outgoing.parseCodesign("/x: code object is not signed at all"), "unsigned")
        XCTAssertEqual(Outgoing.parseCodesign(""), "unknown")
        XCTAssertTrue(Outgoing.bundle(of: chromeHelper).hasSuffix("Google Chrome Helper (Aperitif).app"))
        XCTAssertEqual(Outgoing.bundle(of: "/opt/homebrew/bin/node"), "/opt/homebrew/bin/node")
        XCTAssertEqual(Outgoing.talkerName(process: "Google Chrome Helper (Aperitif)", path: chromeHelper), "Google Chrome")
        XCTAssertEqual(
            Outgoing.talkerName(process: "apsd", path: "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd"), "Apple Push"
        )
        XCTAssertEqual(
            Outgoing.talkerName(
                process: "NewsToday2",
                path: "/private/var/run/x/iOS 27.2.simruntime/Contents/News.app/PlugIns/NewsToday2.appex/NewsToday2"
            ),
            "iOS Simulator · NewsToday2"
        )
    }

    func testLoopbackIsDroppedNewProgramsAreNewsAndEarlierServicesAreKeptADay() {
        let links = Outgoing.parseLinks(established, proto: .tcp)
        XCTAssertEqual(links.map { "\($0.pid) \($0.ip):\($0.port)" }, [
            "44643 142.251.46.69:443",
            "44643 2a03:2880:f36e:1c5:face:b00c:0:80aa:443",
            "777 203.0.113.7:3333",
            "500 192.168.1.40:51000",
        ])
        let chrome = links.filter { $0.pid == 44643 }
        let paths: [Int32: String] = [44643: chromeHelper]
        let owners = [
            "142.251.46.69": Outgoing.Owned(owner: "Google"),
            "2a03:2880:f36e:1c5:face:b00c:0:80aa": Outgoing.Owned(owner: "Meta"),
        ]
        let signatures = [Outgoing.bundle(of: chromeHelper): Outgoing.Signature(signer: "Google LLC", isValid: true)]
        let first = Outgoing.buildTalkers(
            links: chrome, paths: paths, owners: owners, signatures: signatures, listening: [:], history: Outgoing.History(), now: at(1)
        )
        XCTAssertEqual(first.first?.flags, [])
        XCTAssertEqual(first.first?.peers.map(\.owner), ["Google", "Meta"])
        var history = Outgoing.remember(Outgoing.History(), first, now: at(1))
        XCTAssertEqual(history.baseline, at(1))

        // A new program after the baseline is news; Chrome stopped talking to Meta.
        let later = Outgoing.buildTalkers(
            links: [chrome[0], Outgoing.Link(pid: 9, process: "curl", local: "", ip: "142.251.46.69", port: 443, proto: .tcp)],
            paths: paths.merging([9: "/usr/bin/curl"]) { first, _ in first },
            owners: owners,
            signatures: signatures.merging(["/usr/bin/curl": Outgoing.Signature(signer: "Apple", isValid: true)]) { first, _ in first },
            listening: [:], history: history, now: at(5)
        )
        XCTAssertEqual(later.first { $0.name == "curl" }?.flags.map(\.text), [
            "A program you started talks out to Google",
            "New: first seen talking out today",
        ])
        XCTAssertEqual(later.first { $0.name == "Google Chrome" }?.earlier, ["Meta"])
        history = Outgoing.remember(history, later, now: at(5))
        XCTAssertEqual(history.pairs.keys.sorted(), ["Google Chrome→Google", "Google Chrome→Meta", "curl→Google"])
        XCTAssertEqual(history.baseline, at(1))

        // A week later the pair nobody has seen since is forgotten.
        history = Outgoing.remember(history, [], now: at(5 + 8 * PortScan.day))
        XCTAssertEqual(history.pairs, [:])
        XCTAssertEqual(history.programs.keys.sorted(), ["Google Chrome", "curl"])
    }

    func testFlags() {
        let links = Outgoing.parseLinks(established, proto: .tcp)
        let talkers = Outgoing.buildTalkers(
            links: links,
            paths: [44643: chromeHelper, 777: "/tmp/x/miner", 500: "/Users/me/dev/atlas/.venv/bin/python"],
            owners: [
                "142.251.46.69": Outgoing.Owned(owner: "Google"),
                "2a03:2880:f36e:1c5:face:b00c:0:80aa": Outgoing.Owned(owner: "Meta"),
                "203.0.113.7": Outgoing.Owned(owner: "Shady Hosting"),
                "192.168.1.40": Outgoing.Owned(owner: Outgoing.localNetwork),
            ],
            signatures: [
                Outgoing.bundle(of: chromeHelper): Outgoing.Signature(signer: "Google LLC", isValid: true),
                "/tmp/x/miner": Outgoing.Signature(signer: "unsigned", isValid: true),
                "/Users/me/dev/atlas/.venv/bin/python": Outgoing.Signature(signer: "ad-hoc", isValid: true),
            ],
            listening: [500: [8000]], history: Outgoing.History(), now: at(1)
        )
        // The unsigned program on an odd port is flagged first.
        XCTAssertEqual(talkers.map(\.name), ["miner", "python3.14", "Google Chrome"])
        XCTAssertEqual(talkers[0].flags.map(\.text), [
            "Not code-signed",
            "Unusual port 3333 to Shady Hosting",
            "A program you started talks out to Shady Hosting",
        ])
        XCTAssertTrue(talkers[0].hasAlert)
        XCTAssertEqual(talkers[1].flags.map(\.text), [
            "Ad-hoc signed: built on this Mac, no developer identity",
            "A device on your network connected in",
            "A program you started talks out to Local network",
        ])
        XCTAssertEqual(talkers[1].peers.first?.inbound, 1)
        XCTAssertEqual(talkers[2].peers.map { "\($0.owner) \($0.count)" }, ["Google 1", "Meta 1"])
        XCTAssertEqual(talkers[2].signer, "Google LLC")

        // Someone outside the network connecting in is an alert; a missing file is a note, not a broken signature.
        let outside = Outgoing.buildTalkers(
            links: [Outgoing.Link(pid: 500, process: "python3.14", local: "192.168.1.22:8000", ip: "203.0.113.7", port: 51000, proto: .tcp)],
            paths: [500: "/tmp/gone"], owners: ["203.0.113.7": Outgoing.Owned(owner: "Shady Hosting")],
            signatures: ["/tmp/gone": Outgoing.Signature(signer: Outgoing.missingFile, isValid: true)],
            listening: [500: [8000]], history: Outgoing.History(), now: at(1)
        )
        XCTAssertEqual(outside[0].flags.first, ConnectionFlag(.note, "Its file is no longer on disk: updated or deleted while it runs"))
        XCTAssertEqual(outside[0].flags[1], ConnectionFlag(.alert, "Shady Hosting connected in to a port you're listening on"))
    }
}

private let nettop = [
    "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,",
    "12:12:25.757995,launchd.1,,,0,0,0,0,0,,,,,,,,,,,,",
    "12:12:25.754448,tcp4 127.0.0.1:8021<->*:*,lo0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,",
    "12:12:25.754426,tcp6 ::1.8021<->*.*,lo0,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,",
    "12:12:25.810475,Google Chrome He.44643,,,3000,1200,0,0,0,,,,,,,,,,,,",
    "12:12:25.806177,tcp4 192.168.1.22:53265<->142.251.46.69:443,en0,Established,2000,1000,0,0,0,22.94 ms,131072,165376,RD,-,cubic,-,-,-,-,ch,",
    "12:12:25.806178,tcp6 2001:db8:aa:1500::22.57085<->2606:4700::6810:922.443,en0,Established,1000,200,0,0,0,9.1 ms,131072,165376,RD,-,cubic,-,-,-,-,ch,",
    "12:12:25.806179,udp4 192.168.1.22:5353<->224.0.0.251:5353,en0,,40,60,,,,,,,,,,,,,,so,",
    "12:12:25.806180,udp4 *:*<->*:*,,,,,,,,,,,,,,,,,,so,",
    "12:12:25.810476,python3.14.500,,,900,300,0,0,0,,,,,,,,,,,,",
    "12:12:25.806181,tcp4 127.0.0.1:50003<->127.0.0.1:5432,lo0,Established,700,300,0,0,0,0.1 ms,131072,165376,RD,-,cubic,-,-,-,-,so,",
    "12:12:25.806182,tcp4 127.0.0.1:50004<->127.0.0.1:5432,lo0,Established,200,0,0,0,0,0.1 ms,131072,165376,RD,-,cubic,-,-,-,-,so,",
    "12:12:25.810477,postgres.1799,,,300,900,0,0,0,,,,,,,,,,,,",
    "12:12:25.806183,tcp4 127.0.0.1:5432<->127.0.0.1:50003,lo0,Established,300,700,0,0,0,0.1 ms,131072,165376,RD,-,cubic,-,-,-,-,so,",
    "",
].joined(separator: "\n")

private func listener(
    _ pid: Int32, _ name: String, _ ports: [Int], section: ProgramSection = .servers, project: String? = nil, service: String? = nil
) -> ListeningProgram {
    ListeningProgram(
        pid: pid, name: name, process: name, command: name, ports: ports.map { port($0, "127.0.0.1") }, exposure: .loopback,
        section: section, kind: .service, risk: section == .servers ? .low : .info, reasons: [], project: project, place: "",
        folder: nil, startedBy: "terminal", startedAt: at(0), rssKb: 0, cpu: 0, stopPids: [pid], service: service,
        managed: service != nil
    )
}

final class TrafficTests: XCTestCase {
    func testNettopBecomesFlows() {
        let flows = Traffic.parseNettop(nettop)
        // Sockets with no far end, listening or unconnected, are not flows.
        XCTAssertEqual(flows.map { "\($0.pid) \($0.proto) \($0.ip):\($0.port)" }, [
            "44643 tcp4 142.251.46.69:443",
            "44643 tcp6 2606:4700::6810:922:443",
            "44643 udp4 224.0.0.251:5353",
            "500 tcp4 127.0.0.1:5432",
            "500 tcp4 127.0.0.1:5432",
            "1799 tcp4 127.0.0.1:50003",
        ])
        XCTAssertEqual(flows[0].bytes, 3000)
        XCTAssertEqual(flows[1].localPort, 57085)
        XCTAssertEqual(Traffic.parseNettop("nettop: unknown option\n"), [])
    }

    func testBytesGoToProgramsAndTheirPeers() {
        let flows = Traffic.parseNettop(nettop)
        let programs = Traffic.programs(
            flows: flows, names: [44643: "Google Chrome", 500: "atlas.serve"],
            owners: ["142.251.46.69": Outgoing.Owned(owner: "Google", host: "sfo03s27-in-f5.1e100.net")]
        )
        // Loopback is not traffic to other machines.
        XCTAssertEqual(programs.map(\.name), ["Google Chrome"])
        XCTAssertEqual(programs[0].bytesIn, 3040)
        XCTAssertEqual(programs[0].bytesOut, 1260)
        XCTAssertEqual(programs[0].peers.map { "\($0.owner) \($0.host) \($0.bytesIn + $0.bytesOut)" }, [
            "Google sfo03s27-in-f5.1e100.net 3000",
            "Cloudflare 2606:4700::6810:922 1200",
            "Local network 224.0.0.251 100",
        ])
    }

    func testConnectionsInsideThisMacAreCheckedAgainstDeclaredDependencies() {
        let flows = Traffic.parseNettop(nettop)
        let programs = [
            listener(1799, "PostgreSQL", [5432], service: "postgres"),
            listener(500, "atlas.serve", [8000], project: "atlas", service: "api"),
            listener(900, "worker", [9100], project: "atlas"),
            listener(880, "Zed", [44438], section: .apps),
        ]
        func map(_ dependencies: [String: [String]]) -> LocalMap {
            Traffic.localMap(flows: flows, programs: programs, dependencies: dependencies) { pid in
                pid == 500 ? Traffic.Client(id: "api", group: "atlas", service: "api") : nil
            }
        }
        let undeclared = map([:])
        // Both ends of the connection are listed by nettop; only the client's end makes a link.
        XCTAssertEqual(undeclared.links, [LocalLink(from: "api", to: "postgres", port: 5432, count: 2, bytes: 1200, declared: false)])
        XCTAssertEqual(map(["api": ["postgres"]]).links.first?.declared, true)
        // Servers are on the map even with no connection; an app's helper only when it has one.
        XCTAssertEqual(undeclared.nodes.map(\.id), ["api", "worker", "postgres"])
        XCTAssertEqual(undeclared.nodes.map(\.group), ["atlas", "atlas", "Other"])

        // A client that is not a SkyEye service: nothing to declare.
        let outsider = Traffic.localMap(flows: flows, programs: programs) { _ in Traffic.Client(id: "psql", group: "Other") }
        XCTAssertNil(outsider.links.first?.declared)
        XCTAssertTrue(outsider.nodes.contains { $0.id == "psql" })
    }

    func testProgramsWithTheSameNameGetTheirPort() {
        let labels = Traffic.labels(for: [
            listener(1, "atlas.serve", [8080]), listener(2, "atlas.serve", [8081]), listener(3, "web", [3000], service: "shop-web"),
        ])
        XCTAssertEqual(labels, [1: "atlas.serve :8080", 2: "atlas.serve :8081", 3: "shop-web"])
    }

    func testTheTreeLeadsFromLaunchdToEachListener() {
        let procs = PortScan.parsePs(ps)
        let tree = Traffic.tree(programs: [listener(44893, "Pet Shop", [3000]), listener(1799, "PostgreSQL", [5432])], procs: procs)
        XCTAssertEqual(tree.map { "\($0.pid)<\($0.ppid) \($0.name)" }, [
            "1<0 launchd",
            "316<1 Claude Code",
            "1799<1 PostgreSQL",
            "44891<316 zsh",
            "44892<44891 next",
            "44893<44892 Pet Shop",
        ])
        XCTAssertEqual(tree.last?.ports, [3000])
        XCTAssertNil(tree[3].risk, "a wrapper has no risk of its own")
        // A parent ps didn't list: the listener hangs from launchd.
        let orphan = Traffic.tree(programs: [listener(7, "lost", [7000])], procs: [7: PortScan.Proc(pid: 7, ppid: 6, seconds: 0, rssKb: 0, cpu: 0, command: "lost")])
        XCTAssertEqual(orphan.map(\.ppid), [0, 1])
        XCTAssertEqual(Traffic.displayName("/Applications/Zed.app/Contents/MacOS/zed --foreground"), "Zed")
        XCTAssertEqual(Traffic.displayName("/bin/zsh -c npm run dev"), "zsh")
    }

    func testRatesComeFromTheDifferenceBetweenSamples() {
        var recorder = Traffic.Recorder(capacity: 3)
        recorder.record(["chrome": 1000], at: at(0))
        XCTAssertEqual(recorder.history.times, [], "one sample is not a rate yet")
        recorder.record(["chrome": 3000, "curl": 500], at: at(10))
        XCTAssertEqual(recorder.history.times, [at(10)])
        // curl is new: its bytes so far are not known to be from these ten seconds.
        XCTAssertEqual(recorder.history.series, [TrafficHistory.Series(name: "chrome", rates: [200])])
        // Chrome closed connections and its total fell: nothing new, not a negative rate.
        recorder.record(["chrome": 2000, "curl": 1500], at: at(20))
        XCTAssertEqual(recorder.history.series, [
            TrafficHistory.Series(name: "chrome", rates: [200, 0]),
            TrafficHistory.Series(name: "curl", rates: [0, 100]),
        ])
        recorder.record(["curl": 1500], at: at(30))
        recorder.record(["curl": 2500], at: at(40))
        XCTAssertEqual(recorder.history.times, [at(20), at(30), at(40)], "the oldest sample falls off")
        XCTAssertEqual(recorder.history.series, [TrafficHistory.Series(name: "curl", rates: [100, 0, 100])])
        XCTAssertTrue(recorder.history.chartJSON().contains("\"times\":[20000,30000,40000]"))
    }
}

final class NetworkScannerTests: XCTestCase {
    func testScanSeesAListenerThisProcessOpened() throws {
        let (fd, number) = try listenOnFreePort()
        defer { close(fd) }
        let scanner = NetworkScanner()
        let scan = scanner.scanListening(services: [NetworkScanner.Service(name: "probe", port: number)])
        let mine = try XCTUnwrap(scan.programs.first { $0.pid == getpid() })
        XCTAssertTrue(mine.ports.contains { $0.port == number && $0.exposure == .loopback })
        XCTAssertEqual(mine.service, "probe", "a port SkyEye watches is shown as that service")
        XCTAssertFalse(mine.managed)
        XCTAssertEqual(mine.stopPids.first, getpid())
        XCTAssertGreaterThan(mine.rssKb, 0)

        let json = NetworkScan(programs: scan.programs, outgoing: [], firewall: scan.firewall, scannedAt: at(2)).chartJSON()
        XCTAssertTrue(json.contains("\"scannedAt\":2000"), "the chart page reads dates as milliseconds")
    }

    func testAListenerUnderAServiceIsManaged() throws {
        let (fd, _) = try listenOnFreePort()
        defer { close(fd) }
        let scan = NetworkScanner().scanListening(services: [NetworkScanner.Service(name: "tests", pid: getpid())])
        let mine = try XCTUnwrap(scan.programs.first { $0.pid == getpid() })
        XCTAssertEqual(mine.service, "tests")
        XCTAssertTrue(mine.managed)
        XCTAssertEqual(mine.startedBy, "SkyEye")
    }

    func testStopOnlyEndsTheProcessThatWasScanned() throws {
        let (fd, _) = try listenOnFreePort()
        defer { close(fd) }
        var mine = try XCTUnwrap(NetworkScanner().scanListening().programs.first { $0.pid == getpid() })
        mine.stopPids = [getpid(), getppid(), 1]
        XCTAssertEqual(PortScan.currentStopPids(mine), [getpid(), getppid()], "launchd is not the test runner's parent's wrapper")
        mine.stopPids = [getpid(), 1]
        XCTAssertEqual(PortScan.currentStopPids(mine), [getpid()], "a pid that is no longer the parent is left alone")
        // The same pid with another start time is another process.
        mine.startedAt = mine.startedAt.addingTimeInterval(-3600)
        XCTAssertEqual(PortScan.currentStopPids(mine), [])
    }

    /// Scans this Mac for real and writes the chart JSON. Run with
    /// `SKYEYE_LIVE_SCAN=/path/to/out.json swift test --filter testLiveScan`.
    func testLiveScan() throws {
        guard let out = ProcessInfo.processInfo.environment["SKYEYE_LIVE_SCAN"], !out.isEmpty else {
            throw XCTSkip("Set SKYEYE_LIVE_SCAN to an output path to scan this Mac.")
        }
        let scanner = NetworkScanner()
        let started = Date()
        let listening = scanner.scanListening()
        let afterListening = Date()
        let talkers = scanner.scanOutgoing(programs: listening.programs)
        let afterOutgoing = Date()
        let traffic = scanner.scanTraffic(programs: listening.programs, talkers: talkers)
        let afterTraffic = Date()
        let scan = NetworkScan(
            programs: listening.programs, outgoing: talkers, firewall: listening.firewall, scannedAt: listening.scannedAt,
            tree: listening.tree, traffic: traffic.programs, local: traffic.local
        )
        // A few samples a second apart, so the traffic-over-time chart has something to draw.
        var recorder = Traffic.Recorder()
        recorder.record(traffic.totals, at: afterTraffic)
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 1)
            recorder.record(scanner.sampleTraffic(programs: listening.programs, talkers: talkers), at: Date())
        }
        let json = "{\"scan\":\(scan.chartJSON()),\"history\":\(recorder.history.chartJSON())}"
        try Data(json.utf8).write(to: URL(fileURLWithPath: out))
        print(String(
            format: "live scan: %d programs, %d ports, %d talkers, %d tree nodes, %d traffic programs, %d local links (%d nodes), "
                + "%d series; listening %.1fs, outgoing %.1fs, traffic %.1fs",
            scan.programs.count, scan.programs.reduce(0) { $0 + $1.ports.count }, talkers.count, scan.tree.count,
            scan.traffic.count, scan.local.links.count, scan.local.nodes.count, recorder.history.series.count,
            afterListening.timeIntervalSince(started), afterOutgoing.timeIntervalSince(afterListening),
            afterTraffic.timeIntervalSince(afterOutgoing)
        ))
        XCTAssertFalse(scan.programs.isEmpty)
    }
}
