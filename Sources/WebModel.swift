import SwiftUI
import UIKit
import WebKit

/// Holds the one web view the app runs the log in.
///
/// The log itself (visits, patients, notes, Check email, the Gaya report,
/// chat, voice memos) is the Field Visit Log page on claude.ai. Running that
/// page here, rather than rebuilding it, is what keeps every feature working:
/// the Claude write-ups, the Gmail check and the synced data all live behind
/// your claude.ai sign-in. What the app adds is what a web page can't do on
/// its own: phone and text links go straight to the Phone and Messages apps.
@MainActor
final class WebModel: NSObject, ObservableObject {
    static let home = URL(string: "https://claude.ai/artifact/Xeu3iUpNy86GWTd1MncezR")!

    @Published var isLoading = true
    @Published var hasLoadedOnce = false
    @Published var errorText: String?

    let webView: WKWebView
    let recorder = VisitRecorder()
    private var recorderFrame: WKFrameInfo?

    override init() {
        let config = WKWebViewConfiguration()
        let bridge = BridgeProxy()
        config.userContentController.add(bridge, name: "fvlRecorder")
        config.userContentController.addUserScript(WKUserScript(source: WebModel.bridgeJS,
                                                                injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false))
        config.websiteDataStore = .default()          // keeps you signed in between launches
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        bridge.owner = self
        recorder.send = { [weak self] event in self?.sendToPage(event) }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(named: "LaunchBg")
        webView.scrollView.backgroundColor = UIColor(named: "LaunchBg")
        webView.load(URLRequest(url: Self.home))
    }

    func reload() {
        errorText = nil
        if webView.url == nil {
            webView.load(URLRequest(url: Self.home))
        } else {
            webView.reload()
        }
    }

    // MARK: - Visit recorder bridge

    /// Put into every frame, so the log page (which runs in a frame inside
    /// claude.ai) can see it is in the app and use the phone's recorder.
    static let bridgeJS = """
    (function(){
      if (window.FVLNative) return;
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fvlRecorder;
      if (!h) return;
      function post(m){ try { h.postMessage(m); } catch (e) {} }
      window.FVLNative = {
        available: true, version: 1,
        start: function(vid, name){ post({cmd: "start", vid: String(vid || ""), name: String(name || "")}); },
        stop: function(){ post({cmd: "stop"}); },
        status: function(){ post({cmd: "status"}); },
        pending: function(){ post({cmd: "pending"}); },
        ack: function(id){ post({cmd: "ack", id: String(id || "")}); }
      };
    })();
    """

    fileprivate func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        // only the log's own pages may drive the recorder
        let origin = message.frameInfo.securityOrigin.host.lowercased()
        let page = message.frameInfo.request.url?.host?.lowercased() ?? ""
        let ours = [origin, page].contains { $0.contains("claude") || $0.contains("anthropic") }
        guard ours || origin.isEmpty else { return }
        recorderFrame = message.frameInfo
        switch cmd {
        case "start":
            recorder.start(vid: body["vid"] as? String ?? "", name: body["name"] as? String ?? "")
        case "stop":
            recorder.stop()
        case "status":
            recorder.status()
        case "pending":
            recorder.deliverPending()
        case "ack":
            recorder.acknowledge(id: body["id"] as? String ?? "")
        default:
            break
        }
    }

    private func sendToPage(_ event: [String: Any]) {
        guard let frame = recorderFrame,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__fvlNative && window.__fvlNative(\(json));"
        webView.evaluateJavaScript(js, in: frame, in: .page) { _ in }
    }

    // MARK: - Links that belong to another app

    /// Phone and text links in the log point at the small dialer page
    /// (nigh8mare.github.io/dial/#tel:9495550100), because inside claude.ai
    /// a page can't open the Phone app itself. The app can, so it pulls the
    /// number back out and opens Phone or Messages directly.
    static func nativeURL(for url: URL) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["tel", "sms", "mailto", "facetime", "facetime-audio", "maps"].contains(scheme) {
            return url
        }
        let host = url.host?.lowercased() ?? ""
        if host == "nigh8mare.github.io", let fragment = url.fragment,
           fragment.hasPrefix("tel:") || fragment.hasPrefix("sms:") {
            return URL(string: fragment)
        }
        if host == "maps.apple.com" {
            return url
        }
        return nil
    }

    /// Pages that open inside the app. Anything else you tap opens in Safari.
    static func staysInApp(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "data" || scheme == "blob" { return true }
        let host = url.host?.lowercased() ?? ""
        let home = ["claude.ai", "anthropic.com", "claudeusercontent.com", "claude.com"]
        return home.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func openOutside(_ url: URL) {
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Alerts the page asks for

    private func present(_ alert: UIAlertController) -> Bool {
        guard var top = webView.window?.rootViewController else { return false }
        while let next = top.presentedViewController { top = next }
        top.present(alert, animated: true)
        return true
    }
}

extension WebModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if let native = Self.nativeURL(for: url) {
            openOutside(native)
            decisionHandler(.cancel)
            return
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if mainFrame, navigationAction.navigationType == .linkActivated, !Self.staysInApp(url) {
            openOutside(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorText = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        hasLoadedOnce = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func loadFailed(_ error: Error) {
        isLoading = false
        let ns = error as NSError
        // a tap that was handed to Phone/Safari, or a page replaced mid-load
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) {
            return
        }
        if !hasLoadedOnce || ns.domain == NSURLErrorDomain {
            errorText = "Couldn't reach your log. Check your connection."
        }
    }
}

extension WebModel: WKUIDelegate {
    /// Links that open a new tab (every Call, Text and map link in the log does).
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if let native = Self.nativeURL(for: url) {
            openOutside(native)
        } else if Self.staysInApp(url) {
            webView.load(URLRequest(url: url))
        } else if url.scheme == "http" || url.scheme == "https" {
            openOutside(url)
        }
        return nil
    }

    /// Microphone for voice memos. Only the log's own pages get it without asking.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.lowercased()
        let ours = host.contains("claude") || host.contains("anthropic")
        decisionHandler(ours ? .grant : .prompt)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        if !present(alert) { completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        if !present(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        if !present(alert) { completionHandler(nil) }
    }
}

/// Plain container so SwiftUI can lay the shared web view out.
final class WKWebViewHost: UIView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        backgroundColor = UIColor(named: "LaunchBg")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Holds the message handler weakly, so the web view doesn't keep the model alive forever.
@MainActor
private final class BridgeProxy: NSObject, WKScriptMessageHandler {
    weak var owner: WebModel?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handle(message)
    }
}
