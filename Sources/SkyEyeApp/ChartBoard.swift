import AppKit
import SwiftUI
import WebKit

/// The ports page's charts, drawn by the bundled D3 page.
///
/// The page shows names and titles that come from other programs on the Mac, so the web view is closed off:
/// it can load nothing but the app's own chart files, runs no inline script, and can't navigate anywhere else.
struct ChartBoard: NSViewRepresentable {
    static let scheme = "skyeye-charts"
    static let policy = "default-src 'none'; script-src 'self' skyeye-charts:; style-src 'self' skyeye-charts:; img-src 'self' data:"

    /// The chart files inside the app bundle, or nil when this build doesn't carry them (`swift run`).
    static let directory: URL? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("charts", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) else { return nil }
        return url
    }()

    let directory: URL
    /// `NetworkScan.chartJSON()`.
    let json: String
    /// `TrafficHistory.chartJSON()`: it changes between scans, and redraws only the chart that shows it.
    let history: String
    /// "ports", "traffic" or "processes".
    let tab: String
    let selected: Int32?
    let onSelect: (Int32) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BundledFiles(root: directory), forURLScheme: Self.scheme)
        configuration.userContentController.add(context.coordinator, name: "skyeye")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.allowsLinkPreview = false
        // Shown once the page reports ready, so dark mode never flashes an empty white view.
        view.isHidden = true
        context.coordinator.view = view
        view.load(URLRequest(url: URL(string: "\(Self.scheme)://board/index.html")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.show(json: json, history: history, tab: tab, selected: selected)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "skyeye")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var view: WKWebView?
        var onSelect: ((Int32) -> Void)?
        private var isReady = false
        private var json = ""
        private var history = ""
        private var tab = ""
        private var selected: Int32?
        private var drawnJSON: String?
        private var drawnHistory: String?
        private var drawnTab: String?
        private var drawnSelection: Int32?

        func show(json: String, history: String, tab: String, selected: Int32?) {
            self.json = json
            self.history = history
            self.tab = tab
            self.selected = selected
            push()
        }

        /// Sends the page whatever changed since it last drew. The tab goes first, so a scan is drawn once, for the right tab.
        private func push() {
            guard isReady, let view else { return }
            if drawnTab != tab {
                drawnTab = tab
                view.callAsyncJavaScript("window.SkyEyeCharts.show(tab)", arguments: ["tab": tab], in: nil, in: .page)
            }
            if drawnJSON != json {
                drawnJSON = json
                view.callAsyncJavaScript("window.SkyEyeCharts.render(JSON.parse(scan))", arguments: ["scan": json], in: nil, in: .page)
            }
            if drawnHistory != history {
                drawnHistory = history
                view.callAsyncJavaScript(
                    "window.SkyEyeCharts.history(JSON.parse(samples))", arguments: ["samples": history], in: nil, in: .page
                )
            }
            if drawnSelection != selected {
                drawnSelection = selected
                let pid: Any = selected.map { Int($0) } ?? NSNull()
                view.callAsyncJavaScript("window.SkyEyeCharts.select(pid)", arguments: ["pid": pid], in: nil, in: .page)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                view?.isHidden = false
                push()
            case "select":
                guard let pid = (body["pid"] as? NSNumber)?.int32Value else { return }
                drawnSelection = pid
                onSelect?(pid)
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.request.url?.scheme == ChartBoard.scheme ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            drawnJSON = nil
            drawnHistory = nil
            drawnTab = nil
            drawnSelection = nil
            webView.reload()
        }
    }
}

/// Serves the chart page's files from the app bundle, and nothing else.
private final class BundledFiles: NSObject, WKURLSchemeHandler {
    private static let types = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
    ]
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let type = Self.types[url.pathExtension] else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": type,
                  "Content-Length": String(data.count),
                  "Content-Security-Policy": ChartBoard.policy,
                  "X-Content-Type-Options": "nosniff",
                  "Cache-Control": "no-store",
              ]) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
