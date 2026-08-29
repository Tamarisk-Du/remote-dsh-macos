import AppKit
import RemoteDSHCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: ProcessCoordinator?
    private var windowController: HarnessWindowController?
    private var harnessURL: URL?

    private var activityToken: NSObjectProtocol?
    private var connectionTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var lastPresentation: AppPresentation?

    private var openProjectItem: NSMenuItem!
    private var reloadItem: NSMenuItem!
    private var openBrowserItem: NSMenuItem!
    private var stopHarnessItem: NSMenuItem!
    private var retryItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let user = environment["USER"] ?? homeDirectory.lastPathComponent
        let temporaryDirectory = environment["TMPDIR"] ?? fileManager.temporaryDirectory.path
        let configURL = RemoteDSHConfigurationLoader.defaultURL(homeDirectory: homeDirectory)
        let startupResult = StartupPolicy.prepare(
            configURL: configURL,
            homeDirectory: homeDirectory,
            user: user,
            temporaryDirectory: temporaryDirectory,
            sshAuthSock: environment["SSH_AUTH_SOCK"],
            tunnelFactory: { configuration, home, user, temporaryDirectory, sshAuthSock in
                CommandFactory.tunnel(
                    configuration: configuration,
                    home: home,
                    user: user,
                    temporaryDirectory: temporaryDirectory,
                    sshAuthSock: sshAuthSock
                )
            },
            harnessFactory: { configuration, home, user, temporaryDirectory in
                CommandFactory.harness(
                    configuration: configuration,
                    home: home,
                    user: user,
                    temporaryDirectory: temporaryDirectory
                )
            }
        )

        switch startupResult {
        case .success(let runtime):
            harnessURL = runtime.endpoints.harnessBaseURL
            windowController = HarnessWindowController(
                harnessURL: runtime.endpoints.harnessBaseURL,
                displayModelName: runtime.configuration.displayModelName
            )
            windowController?.configuredSSHAlias = runtime.configuration.sshAlias
            configureCoordinator(runtime)
        case .failure:
            harnessURL = nil
            windowController = HarnessWindowController(
                harnessURL: nil,
                displayModelName: nil
            )
        }

        configureMenus()
        windowController?.retryHandler = { [weak self] in self?.retryConnection(nil) }
        windowController?.openBrowserHandler = { [weak self] in self?.openInBrowser(nil) }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        switch startupResult {
        case .success:
            windowController?.showStatus(.idle)
            beginObservation()
            startRuntime()
        case .failure(let error):
            coordinator = nil
            windowController?.showConfigurationError(
                path: configURL.path,
                field: error.fieldName,
                detail: error.localizedDescription
            )
            refreshPresentation()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        beginActivity()
    }

    func applicationDidResignActive(_ notification: Notification) {
        endActivity()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        connectionTask?.cancel()
        observationTask?.cancel()
        stopTask?.cancel()

        guard let coordinator else {
            endActivity()
            return .terminateNow
        }
        terminationTask = Task { [weak self] in
            let report = await coordinator.shutdown()
            self?.endActivity()
            if report.timedOutPIDs.isEmpty == false {
                self?.showTimedOutProcessAlert(report.timedOutPIDs)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func openProject(_ sender: Any?) {
        guard let coordinator,
              coordinator.status == .ready,
              connectionTask == nil,
              stopTask == nil,
              terminationTask == nil else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose a Harness project directory"
        panel.prompt = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await coordinator.createWorkspace(path: directory.path)
                windowController?.showHarness()
                windowController?.window?.makeKeyAndOrderFront(nil)
            } catch {
                showAlert(
                    title: "Remote DSH for macOS could not open the project",
                    detail: workspaceErrorDetail(error)
                )
            }
        }
    }

    @objc private func reloadHarness(_ sender: Any?) {
        guard let coordinator,
              coordinator.status == .ready,
              connectionTask == nil,
              stopTask == nil,
              terminationTask == nil else { return }
        windowController?.showHarness()
    }

    @objc private func openInBrowser(_ sender: Any?) {
        guard let coordinator,
              coordinator.status == .ready,
              connectionTask == nil,
              stopTask == nil,
              terminationTask == nil,
              let harnessURL else { return }
        NSWorkspace.shared.open(harnessURL)
    }

    @objc private func stopHarness(_ sender: Any?) {
        guard let coordinator,
              coordinator.status == .ready,
              coordinator.ownsHarness,
              connectionTask == nil,
              stopTask == nil,
              terminationTask == nil else { return }
        stopTask = Task { [weak self] in
            guard let self else { return }
            defer {
                stopTask = nil
                refreshPresentation()
            }
            let report = await coordinator.stopOwnedHarness()
            if report.timedOutPIDs.isEmpty == false {
                showTimedOutProcessAlert(report.timedOutPIDs)
            }
        }
        refreshPresentation()
    }

    @objc private func retryConnection(_ sender: Any?) {
        guard let coordinator,
              connectionTask == nil,
              stopTask == nil,
              terminationTask == nil else { return }
        if coordinator.status == .ready {
            windowController?.showHarness()
            return
        }
        startRuntime()
    }

    private func configureCoordinator(_ runtime: PreparedRuntime) {
        coordinator = ProcessCoordinator(
            endpoints: runtime.endpoints,
            probe: TCPPortProbe(),
            api: HarnessClient(baseURL: runtime.endpoints.harnessBaseURL),
            launcher: FoundationProcessLauncher(),
            workspacePathPolicy: WorkspacePathPolicy(
                home: FileManager.default.homeDirectoryForCurrentUser.path
            ),
            tunnelCommand: runtime.tunnelCommand,
            harnessCommand: runtime.harnessCommand
        )
    }

    private func startRuntime() {
        guard let coordinator,
              connectionTask == nil,
              stopTask == nil,
              terminationTask == nil else { return }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                connectionTask = nil
                refreshPresentation()
            }
            do {
                if coordinator.status == .failed(.tunnelUnavailable) {
                    await coordinator.retry()
                } else {
                    try await coordinator.start()
                }
            } catch is CancellationError {
                return
            } catch {
                refreshPresentation()
            }
        }
        refreshPresentation()
    }

    private func beginObservation() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                refreshPresentation()
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    private func configureMenus() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Remote DSH for macOS",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        fileMenuItem.title = "File"
        let fileMenu = NSMenu(title: "File")
        fileMenu.autoenablesItems = false
        openProjectItem = NSMenuItem(
            title: "Open Project…",
            action: #selector(openProject(_:)),
            keyEquivalent: "o"
        )
        openProjectItem.target = self
        fileMenu.addItem(openProjectItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        viewMenuItem.title = "View"
        let viewMenu = NSMenu(title: "View")
        viewMenu.autoenablesItems = false
        reloadItem = NSMenuItem(
            title: "Reload",
            action: #selector(reloadHarness(_:)),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let harnessMenuItem = NSMenuItem()
        harnessMenuItem.title = "Harness"
        let harnessMenu = NSMenu(title: "Harness")
        harnessMenu.autoenablesItems = false
        openBrowserItem = NSMenuItem(
            title: "Open in Browser",
            action: #selector(openInBrowser(_:)),
            keyEquivalent: "b"
        )
        openBrowserItem.target = self
        harnessMenu.addItem(openBrowserItem)
        stopHarnessItem = NSMenuItem(
            title: "Stop Harness",
            action: #selector(stopHarness(_:)),
            keyEquivalent: "."
        )
        stopHarnessItem.target = self
        harnessMenu.addItem(stopHarnessItem)
        harnessMenu.addItem(.separator())
        retryItem = NSMenuItem(
            title: "Retry Connection",
            action: #selector(retryConnection(_:)),
            keyEquivalent: ""
        )
        retryItem.target = self
        harnessMenu.addItem(retryItem)
        harnessMenuItem.submenu = harnessMenu
        mainMenu.addItem(harnessMenuItem)

        NSApp.mainMenu = mainMenu
        refreshPresentation()
    }

    private func refreshPresentation() {
        guard let coordinator else {
            setMenus(.allDisabled)
            return
        }
        let presentation = AppPresentationPolicy.project(
            status: coordinator.status,
            ownsHarness: coordinator.ownsHarness,
            operationInFlight: connectionTask != nil || stopTask != nil
        )
        guard presentation != lastPresentation else { return }
        let previousContent = lastPresentation?.content
        lastPresentation = presentation
        setMenus(presentation.menu)
        stopHarnessItem?.toolTip = coordinator.ownsHarness
            ? nil
            : "Remote DSH for macOS did not start this Harness process."

        guard presentation.content != previousContent else { return }
        switch presentation.content {
        case .harness:
            windowController?.showHarness()
        case .status(let status):
            windowController?.showStatus(status)
        }
    }

    private func setMenus(_ menu: AppMenuAvailability) {
        openProjectItem?.isEnabled = menu.openProject
        reloadItem?.isEnabled = menu.reload
        openBrowserItem?.isEnabled = menu.openBrowser
        stopHarnessItem?.isEnabled = menu.stopHarness
        retryItem?.isEnabled = menu.retry
    }

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Remote DSH for macOS is active"
        )
    }

    private func endActivity() {
        guard let activityToken else { return }
        ProcessInfo.processInfo.endActivity(activityToken)
        self.activityToken = nil
    }

    private func showTimedOutProcessAlert(_ pids: [Int32]) {
        showAlert(
            title: "Remote DSH for macOS left owned processes running",
            detail: "These processes started by Remote DSH for macOS did not exit during the waiting period and were not force-terminated:\nPID "
                + pids.map(String.init).joined(separator: "\nPID ")
        )
    }

    private func showAlert(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = DiagnosticSanitizer.clean(detail)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func workspaceErrorDetail(_ error: Error) -> String {
        switch error {
        case WorkspacePathError.homeDirectoryRejected:
            return "The whole home directory cannot be used as a project root. Choose a specific project directory."
        case WorkspacePathError.notDirectory:
            return "The selected path is missing or is not a directory."
        default:
            return "Harness could not register the project.\n\(DiagnosticSanitizer.clean(String(describing: error)))"
        }
    }
}
