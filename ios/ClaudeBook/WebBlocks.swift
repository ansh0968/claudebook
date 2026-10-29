import UIKit
import WebKit
import SwiftUI

extension API {
    // The authenticated fetch stays outside WKWebView: authored code never sees a token.
    private func webRequest(_ path: String, json: [String: Any]? = nil, method: String = "GET") async throws -> Data {
        var req = URLRequest(url: base.appending(path: "api").appending(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        if let json { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (bytes, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(status: status, body: "Block request failed") }
        return bytes
    }
    func webHTML(_ file: String) async throws -> String { String(decoding: try await webRequest("blocks/\(file)"), as: UTF8.self) }
    func webPoster(_ file: String) async throws -> UIImage? { UIImage(data: try await webRequest("blocks/\(file)")) }
    func webLog(page: String, item: ClaudeItem, lines: [String]) async throws {
        _ = try await webRequest("pages/\(page)/blocks/\(item.id)/log", json: ["rev": item.rev ?? 1, "lines": lines], method: "POST")
    }
    func webPoster(page: String, item: ClaudeItem, png: Data) async throws {
        _ = try await webRequest("pages/\(page)/blocks/\(item.id)/poster", json: ["rev": item.rev ?? 1, "png": png.base64EncodedString()], method: "PUT")
    }
}

/// Native controls beside PencilKit take touches only inside their own block rectangles.
final class WebBlockOverlay: UIView {
    private weak var owner: UIViewController?
    private var cards: [String: WebBlockCard] = [:]
    private var pageRects: [String: CGRect] = [:]
    private var fullKey: String?
    private var replay: (() -> Void)?
    init(owner: UIViewController) {
        self.owner = owner; super.init(frame: .zero); clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func background() { for card in cards.values { card.pause() } }
    @objc private func foreground() { replay?(); if let key = fullKey, let card = cards[key], !card.userPaused { card.play() } }
    func suspend() { for card in cards.values where card.superview === self { card.pause() } }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        for child in subviews.reversed() { if let hit = child.hitTest(convert(point, to: child), with: event) { return hit } }
        return nil
    }
    func update(pages: [Page], canvas: UIScrollView, content: UIView, enabled: Bool) {
        replay = { [weak self, weak canvas, weak content] in
            guard let canvas, let content else { return }; self?.update(pages: pages, canvas: canvas, content: content, enabled: enabled)
        }
        isHidden = !enabled
        let running = enabled && window != nil && UIApplication.shared.applicationState == .active
        guard canvas.zoomScale > 0 else { return }
        let middle = NotebookLayout.index(forY: (canvas.contentOffset.y + canvas.bounds.height/2)/canvas.zoomScale, count: pages.count)
        var visible: [(String, String, ClaudeItem, CGRect, Int)] = []
        for (index, page) in pages.enumerated() { for item in page.claudeLayer where item.type == "web" {
            guard let x = item.x, let y = item.y, let w = item.w, let h = item.h else { continue }
            let s = canvas.zoomScale
            let rect = content.convert(CGRect(x: CGFloat(x)*s, y: (NotebookLayout.offset(index)+CGFloat(y))*s, width: CGFloat(w)*s, height: CGFloat(h)*s), to: self)
            if rect.intersects(bounds) { visible.append(("\(page.id):\(item.id)", page.id, item, rect, index)) }
        } }
        let wanted = Set(visible.map { $0.0 })
        for key in cards.keys.filter({ !wanted.contains($0) && $0 != fullKey }) { cards[key]?.pause(); cards[key]?.removeFromSuperview(); cards[key] = nil; pageRects[key] = nil }
        var slots = fullKey == nil ? 3 : 2
        for (key, page, item, rect, index) in visible.sorted(by: { abs($0.3.midY-bounds.midY) < abs($1.3.midY-bounds.midY) }) {
            pageRects[key] = rect
            if key == fullKey { cards[key]?.refresh(item); continue }
            let card: WebBlockCard
            if let existing = cards[key], existing.item.rev == item.rev { card = existing; card.refresh(item) }
            else {
                cards[key]?.pause(); cards[key]?.removeFromSuperview()
                card = WebBlockCard(page: page, item: item, owner: owner)
                card.requestPlay = { [weak self, weak card] in
                    guard let self, let card else { return }
                    let others = self.cards.values.filter { $0 !== card && $0.isLive }
                    if others.count >= 3 { others.first?.pause() }
                    card.userPaused = false; card.play()
                }
                card.fullscreen = { [weak self, weak card] in
                    guard let self, let card, let owner = self.owner, self.fullKey == nil else { return }
                    self.fullKey = key
                    card.removeFromSuperview()
                    owner.present(WebBlockFullscreen(card: card) { [weak self, weak card] in
                        guard let self, let card else { return }
                        self.fullKey = nil
                        if let rect = self.pageRects[key] { card.frame = rect }
                        self.addSubview(card); card.userPaused = true; card.pause()
                        self.replay?()
                    }, animated: true)
                }
                cards[key] = card; addSubview(card)
            }
            card.frame = rect
            let automatic = index == middle && item.autoplay != false && !card.userPaused
            if running && slots > 0 && (automatic || card.isLive) { if automatic { card.play() }; slots -= 1 }
            else { card.pause() }
        }
    }
}

private final class WebBridge: NSObject, WKScriptMessageHandler {
    weak var card: WebBlockCard?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { card?.receive(message) }
}

final class WebBlockCard: UIView, WKNavigationDelegate, WKUIDelegate {
    let page: String
    private(set) var item: ClaudeItem
    private weak var owner: UIViewController?
    private var web: WKWebView?
    private var loading: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var generation = UUID()
    private let poster = UIImageView()
    private let label = UILabel()
    private let playButton = UIButton(type: .system)
    private let menu = UIButton(type: .system)
    private var bridge: WebBridge?
    private var logs: [String] = []
    private var captured = false
    private var initialNavigation = true
    private var bridgeMessages = 0
    var userPaused = false
    var requestPlay: (() -> Void)?
    var fullscreen: (() -> Void)?
    var isLive: Bool { web != nil || loading != nil }
    private static var rules: WKContentRuleList?
    private static let encodedRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^https://(cdnjs\\.cloudflare\\.com|cdn\\.jsdelivr\\.net|unpkg\\.com)(/|$)","url-filter-is-case-sensitive":false},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^(data:|blob:|about:blank)"},"action":{"type":"ignore-previous-rules"}}]"#
    init(page: String, item: ClaudeItem, owner: UIViewController?) {
        self.page = page; self.item = item; self.owner = owner
        super.init(frame: .zero)
        clipsToBounds = true; backgroundColor = UIColor(StudyPalette.background)
        poster.contentMode = .scaleToFill; addSubview(poster)
        label.text = item.title ?? "Interactive block"; label.font = .preferredFont(forTextStyle: .footnote); label.textColor = UIColor(StudyPalette.teal); addSubview(label)
        playButton.setTitle("Play", for: .normal); playButton.tintColor = UIColor(StudyPalette.teal)
        playButton.accessibilityIdentifier = "web.play.\(item.id)"
        playButton.addAction(UIAction { [weak self] _ in self?.requestPlay?() }, for: .touchUpInside); addSubview(playButton)
        menu.setTitle("...", for: .normal); menu.backgroundColor = UIColor(StudyPalette.background); menu.tintColor = UIColor(StudyPalette.teal)
        menu.accessibilityIdentifier = "web.menu.\(item.id)"; menu.accessibilityLabel = "Block controls"; menu.showsMenuAsPrimaryAction = true
        menu.menu = UIMenu(children: [
            UIAction(title: "Reload") { [weak self] _ in self?.pause(); self?.requestPlay?() },
            UIAction(title: "Pause") { [weak self] _ in self?.userPaused = true; self?.pause() },
            UIAction(title: "Fullscreen") { [weak self] _ in self?.fullscreen?() }
        ])
        addSubview(menu); fetchPoster()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { loading?.cancel(); imageTask?.cancel(); logTask?.cancel(); snapshotTask?.cancel(); web?.configuration.userContentController.removeScriptMessageHandler(forName: "claudebook") }
    func refresh(_ value: ClaudeItem) {
        if item.rev != value.rev {
            pause(); item = value; poster.image = nil; label.text = value.title; captured = false; userPaused = false; play()
        } else { let changed = item.poster != value.poster; item = value; if changed && web == nil { fetchPoster() } }
    }
    private func fetchPoster() {
        imageTask?.cancel()
        guard let file = item.poster, let api = API.current else { return }
        imageTask = Task { [weak self] in guard let image = try? await api.webPoster(file), !Task.isCancelled else { return }; self?.poster.image = image }
    }
    override func layoutSubviews() {
        super.layoutSubviews(); poster.frame = bounds; web?.frame = bounds
        label.frame = CGRect(x: 8, y: 8, width: max(0, bounds.width-60), height: 24)
        playButton.frame = CGRect(x: 0, y: max(0, bounds.midY-22), width: bounds.width, height: 44)
        menu.frame = CGRect(x: max(0, bounds.width-44), y: 0, width: 44, height: 44)
    }
    func play() {
        guard !isLive, let file = item.file, let api = API.current else { return }
        let token = generation
        loading = Task { [weak self] in
            do {
                let html = try await api.webHTML(file)
                let list: WKContentRuleList
                if let existing = Self.rules { list = existing }
                else {
                    guard let compiled = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ClaudeBookBlocks-v1", encodedContentRuleList: Self.encodedRules) else {
                        throw NSError(domain: "ClaudeBookBlocks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not install block network sandbox"])
                    }
                    list = compiled; Self.rules = compiled
                }
                guard let self, !Task.isCancelled, token == self.generation else { return }
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent(); config.allowsInlineMediaPlayback = true; config.mediaTypesRequiringUserActionForPlayback = []
                config.preferences.javaScriptCanOpenWindowsAutomatically = false
                config.userContentController.add(list)
                let handler = WebBridge(); handler.card = self; self.bridge = handler; config.userContentController.add(handler, name: "claudebook")
                let width = self.item.w ?? 800, height = self.item.h ?? 500
                // A page-unit CSS viewport gives layouts the same geometry in-page and fullscreen.
                let viewport = "(()=>{const fixed='width=\(width),height=\(height)';const enforce=()=>{const own=document.querySelector('meta[data-claudebook-viewport]');if(!own)return;document.querySelectorAll('meta[name=viewport]').forEach(m=>{if(m!==own)m.remove()});if(own.content!==fixed)own.content=fixed};new MutationObserver(enforce).observe(document,{subtree:true,childList:true,attributes:true,attributeFilter:['content','name']});document.addEventListener('DOMContentLoaded',enforce)})();"
                config.userContentController.addUserScript(WKUserScript(source: viewport, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                let view = WKWebView(frame: self.bounds, configuration: config)
                view.navigationDelegate = self; view.uiDelegate = self; view.scrollView.isScrollEnabled = false
                view.isOpaque = false; view.backgroundColor = UIColor(StudyPalette.background); view.accessibilityIdentifier = "web.live.\(self.item.id)"
                self.initialNavigation = true; self.bridgeMessages = 0; self.captured = false; self.web = view; self.insertSubview(view, belowSubview: self.menu)
                self.label.isHidden = true; self.playButton.isHidden = true
                view.loadHTMLString(html, baseURL: nil); self.loading = nil
            } catch { guard let self, !Task.isCancelled, token == self.generation else { return }; self.loading = nil; self.record("App: \(error.localizedDescription)") }
        }
    }
    func pause() {
        generation = UUID(); loading?.cancel(); loading = nil; snapshotTask?.cancel(); snapshotTask = nil
        guard let old = web else { return }
        capture(old); web = nil; old.stopLoading(); old.configuration.userContentController.removeScriptMessageHandler(forName: "claudebook"); old.removeFromSuperview(); bridge = nil
        playButton.isHidden = false; label.isHidden = poster.image != nil
    }
    func receive(_ message: WKScriptMessage) {
        guard bridgeMessages < 100 else { return }; bridgeMessages += 1
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "poster-ready" { scheduleSnapshot(); return }
        guard ["error", "warn"].contains(kind), let line = body["message"] as? String else { return }
        record("\(kind): \(line.prefix(1000))")
    }
    private func record(_ line: String) {
        logs.append(String(line.prefix(1000))); logs = Array(logs.suffix(20))
        guard logTask == nil else { return }
        logTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let lines = self.logs; self.logs = []; self.logTask = nil
            try? await API.current?.webLog(page: self.page, item: self.item, lines: lines)
        }
    }
    private func scheduleSnapshot() {
        guard !captured, snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, let web = self.web else { return }
            self.capture(web); self.snapshotTask = nil
        }
    }
    private func capture(_ view: WKWebView) {
        let config = WKSnapshotConfiguration(); config.snapshotWidth = NSNumber(value: min(1400, item.w ?? 800))
        let pageId = page, value = item
        // Retain the offscreen view only until WebKit finishes its final snapshot.
        view.takeSnapshot(with: config) { [weak self, view] image, _ in
            guard let image else { return }; if self?.item.rev == value.rev { self?.captured = true; self?.poster.image = image }
            guard let png = image.pngData(), png.count <= 2*1024*1024 else { return }
            Task { try? await API.current?.webPoster(page: pageId, item: value, png: png) }; _ = view
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { scheduleSnapshot() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { record("Web content process stopped; reload the block"); pause() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if initialNavigation && action.navigationType == .other && url?.absoluteString == "about:blank" { initialNavigation = false; decisionHandler(.allow); return }
        decisionHandler(.cancel)
        guard action.navigationType == .linkActivated, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let owner else { return }
        let alert = UIAlertController(title: "Open link in Safari?", message: url.host, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in UIApplication.shared.open(url) }); (owner.presentedViewController ?? owner).present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

private final class WebBlockFullscreen: UIViewController {
    private let card: WebBlockCard
    private let closed: () -> Void
    init(card: WebBlockCard, closed: @escaping () -> Void) { self.card = card; self.closed = closed; super.init(nibName: nil, bundle: nil); modalPresentationStyle = .fullScreen }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = UIColor(StudyPalette.background); view.addSubview(card)
        let close = UIButton(type: .system); close.setTitle("Close fullscreen", for: .normal); close.tintColor = UIColor(StudyPalette.teal); close.accessibilityIdentifier = "web.fullscreen.close"
        close.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let cleanup = self.closed
            self.dismiss(animated: true, completion: cleanup)
        }, for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(close)
        NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor), close.heightAnchor.constraint(equalToConstant: 44)])
        card.userPaused = false; card.requestPlay?()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let rect = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 0, dy: 44)
        let aspect = CGFloat((card.item.w ?? 800)/(card.item.h ?? 500))
        let w = min(rect.width, rect.height*aspect), h = min(rect.height, rect.width/aspect)
        card.frame = CGRect(x: rect.midX-w/2, y: rect.midY-h/2, width: w, height: h)
    }
}
