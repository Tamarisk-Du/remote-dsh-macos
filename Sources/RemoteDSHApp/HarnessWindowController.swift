import AppKit
import RemoteDSHCore
import WebKit

@MainActor
final class HarnessWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    private let harnessURL: URL?
    private let displayModelName: String?
    private let statusContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let openBrowserButton = NSButton(title: "Open in Browser", target: nil, action: nil)
    private let webView: WKWebView?

    var configuredSSHAlias: String?
    var retryHandler: (() -> Void)?
    var openBrowserHandler: (() -> Void)?

    init(harnessURL: URL?, displayModelName: String?) {
        self.harnessURL = harnessURL
        self.displayModelName = displayModelName
        if harnessURL != nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: .zero, configuration: configuration)
        } else {
            webView = nil
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Remote DSH for macOS"
        window.minSize = NSSize(width: 820, height: 560)
        window.center()
        super.init(window: window)
        configureContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func showConfigurationError(path: String, field: String, detail: String) {
        let presentation = ConfigurationFailurePresentation(
            path: path,
            field: field,
            detail: detail
        )
        showNativeStatus(
            title: presentation.title,
            detail: presentation.detail,
            isBusy: false,
            showsRetry: false,
            showsBrowser: false
        )
    }

    func showStatus(_ status: CoordinatorStatus) {
        let presentation = presentation(for: status)
        showNativeStatus(
            title: presentation.title,
            detail: presentation.detail,
            isBusy: presentation.isBusy,
            showsRetry: presentation.showsRetry,
            showsBrowser: presentation.showsBrowser
        )
    }

    func showHarness() {
        guard let webView, let harnessURL else { return }
        spinner.stopAnimation(nil)
        statusContainer.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: harnessURL))
        window?.makeKeyAndOrderFront(nil)
    }

    private func configureContent(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusContainer)

        var constraints = [
            statusContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            statusContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ]
        if let webView {
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.isHidden = true
            contentView.addSubview(webView)
            constraints.append(contentsOf: [
                webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                webView.topAnchor.constraint(equalTo: contentView.topAnchor),
                webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 10
        detailLabel.preferredMaxLayoutWidth = 680
        spinner.style = .spinning
        spinner.controlSize = .regular

        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.bezelStyle = .rounded
        openBrowserButton.target = self
        openBrowserButton.action = #selector(openBrowserPressed)
        openBrowserButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [retryButton, openBrowserButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        let statusStack = NSStackView(views: [spinner, titleLabel, detailLabel, buttons])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 14
        statusContainer.addSubview(statusStack)
        constraints.append(contentsOf: [
            statusStack.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            statusStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: statusContainer.leadingAnchor,
                constant: 40
            ),
            statusStack.trailingAnchor.constraint(
                lessThanOrEqualTo: statusContainer.trailingAnchor,
                constant: -40
            )
        ])
        NSLayoutConstraint.activate(constraints)
        showStatus(.idle)
    }

    private func showNativeStatus(
        title: String,
        detail: String,
        isBusy: Bool,
        showsRetry: Bool,
        showsBrowser: Bool
    ) {
        statusContainer.isHidden = false
        webView?.isHidden = true
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        retryButton.isHidden = showsRetry == false
        openBrowserButton.isHidden = showsBrowser == false
        if isBusy {
            spinner.startAnimation(nil)
            spinner.isHidden = false
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    @objc private func retryPressed() {
        retryHandler?()
    }

    @objc private func openBrowserPressed() {
        openBrowserHandler?()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let harnessURL else {
            decisionHandler(.cancel)
            return
        }
        switch NavigationPolicy.destination(for: url, allowedOrigin: harnessURL) {
        case .embedded:
            decisionHandler(.allow)
        case .externalBrowser:
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        case .reject:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url,
              let harnessURL else { return nil }
        switch NavigationPolicy.destination(for: url, allowedOrigin: harnessURL) {
        case .externalBrowser:
            NSWorkspace.shared.open(url)
        case .embedded:
            webView.load(navigationAction.request)
        case .reject:
            break
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        showWebError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        showWebError(error)
    }

    private func showWebError(_ error: Error) {
        showNativeStatus(
            title: "Remote DSH for macOS could not load Harness",
            detail: DiagnosticSanitizer.clean(String(describing: error)),
            isBusy: false,
            showsRetry: true,
            showsBrowser: true
        )
    }

    private func presentation(
        for status: CoordinatorStatus
    ) -> (title: String, detail: String, isBusy: Bool, showsRetry: Bool, showsBrowser: Bool) {
        let modelDetail = displayModelName.map { " Configured model: \($0)." } ?? ""
        let alias = configuredSSHAlias.map { "“\($0)”" } ?? "the configured SSH alias"
        switch status {
        case .idle:
            return (
                "Remote DSH for macOS is ready to connect",
                "The configured services have not been started yet.\(modelDetail)",
                false,
                true,
                false
            )
        case .checkingTunnel:
            return (
                "Remote DSH for macOS is checking the tunnel",
                "Checking the local endpoint associated with \(alias).",
                true,
                false,
                false
            )
        case .startingTunnel:
            return (
                "Remote DSH for macOS is connecting the tunnel",
                "Connecting through \(alias) from your existing SSH configuration.",
                true,
                false,
                false
            )
        case .checkingHarness:
            return (
                "Remote DSH for macOS is checking Harness",
                "Validating the configured local Harness endpoint.\(modelDetail)",
                true,
                false,
                false
            )
        case .startingHarness:
            return (
                "Remote DSH for macOS is starting Harness",
                "Waiting for the configured Harness launcher to finish initialization.\(modelDetail)",
                true,
                false,
                false
            )
        case .ready:
            return (
                "Remote DSH for macOS is ready",
                "Loading the configured Harness page.\(modelDetail)",
                true,
                false,
                true
            )
        case .failed(let failure):
            return (
                "Remote DSH for macOS could not connect",
                failureDetail(failure),
                false,
                true,
                harnessURL != nil
            )
        }
    }

    private func failureDetail(_ failure: CoordinatorFailure) -> String {
        switch failure {
        case .foreignHarness:
            return "The configured Harness endpoint is occupied by another service. That service was left unchanged."
        case .tunnelLaunchFailed(let detail):
            return "The connection through the configured SSH alias could not be started.\n\(detail)"
        case .tunnelStartupTimedOut:
            return "The connection through the configured SSH alias did not become ready in time."
        case .harnessLaunchFailed(let detail):
            return "The configured Harness launcher could not be started.\n\(detail)"
        case .harnessStartupTimedOut:
            return "The configured Harness endpoint did not become ready in time."
        case .tunnelUnavailable:
            return "The tunnel became unavailable and the bounded retry sequence did not restore it."
        case .ownedChildStillRunning(let pid):
            return "A process started by Remote DSH for macOS (PID \(pid)) is still running and was not force-terminated."
        case .shutdownTimedOut(let pids):
            return "Processes started by Remote DSH for macOS are still running and were not force-terminated: \(pids.map(String.init).joined(separator: ", "))"
        }
    }
}
