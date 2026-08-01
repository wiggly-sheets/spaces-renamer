import AppKit
import Foundation
import os

enum InjectionState: Equatable {
    case unsupported(String)
    case prerequisitesMissing(String)
    case ready
    case injecting
    case restartingDock
    case loaded(pid: Int32, payloadVersion: String)
    case injected(pid: Int32, payloadVersion: String)
    case updateRequired(pid: Int32, loadedVersion: String, bundledVersion: String)
    case authorizationCancelled(pid: Int32?)
    case error(String)

    var title: String {
        switch self {
        case .unsupported: return "Unavailable"
        case .prerequisitesMissing: return "Setup required"
        case .ready: return "Ready to inject"
        case .injecting: return "Injecting"
        case .restartingDock: return "Restarting Dock"
        case .loaded: return "Injected — awaiting verification"
        case .injected: return "Injected"
        case .updateRequired: return "Dock hook update required"
        case .authorizationCancelled: return "Authorization cancelled"
        case .error: return "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .unsupported(let reason): return reason
        case .prerequisitesMissing(let reason): return reason
        case .ready: return "The boot argument and System Integrity Protection configuration are ready for injection."
        case .injecting: return "Loading the bundled payload into Dock…"
        case .restartingDock: return "Waiting for macOS to relaunch Dock before injecting the bundled payload…"
        case .loaded(let pid, let payloadVersion):
            return "Dock PID \(pid) loaded payload version \(payloadVersion). Open Mission Control once to verify the renaming hook."
        case .injected(let pid, let payloadVersion):
            return "Dock PID \(pid) verified payload version \(payloadVersion) in Mission Control."
        case .updateRequired(let pid, let loadedVersion, let bundledVersion):
            return "Dock PID \(pid) is running payload \(loadedVersion), but this app contains \(bundledVersion). Click Inject Now to approve a Dock restart and update it."
        case .authorizationCancelled:
            return "The administrator prompt was cancelled. Automatic reinjection will not ask again for this Dock process; click Inject Now to retry."
        case .error(let reason): return reason
        }
    }

    var symbol: String {
        switch self {
        case .injected: return "checkmark.circle.fill"
        case .injecting, .restartingDock, .loaded: return "clock.arrow.circlepath"
        case .ready: return "checkmark.shield"
        case .prerequisitesMissing, .updateRequired, .authorizationCancelled:
            return "exclamationmark.triangle.fill"
        case .unsupported, .error: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class InjectionManager: ObservableObject {
    @Published private(set) var state: InjectionState = .ready
    @Published private(set) var operationInProgress = false
    @Published private(set) var prerequisitesWarning: String?

    private weak var preferences: PreferencesStore?
    private var observers: [NSObjectProtocol] = []
    private var reinjectionWorkItem: DispatchWorkItem?
    private var pendingInjectionAfterDockRestart = false

    private static let handshakeURL = URL(
        fileURLWithPath: "/tmp/spaces-renamer-injection-\(getuid()).json"
    )
    private static let injectionProtocolVersion = "1"
    private static let cancelledDockPIDDefaultsKey = "cancelledAutomaticInjectionDockPID"

    private static var bundledPayloadVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    private enum InjectionAttemptResult: Sendable {
        case success
        case cancelled
        case failed(String)
    }

    private struct Handshake {
        let dockPID: Int32
        let payloadVersion: String
        let hookActive: Bool
    }

    // MARK: - Lifecycle
    func start(preferences: PreferencesStore) {
        self.preferences = preferences
        checkPlatform()
        guard case .unsupported = state else {
            observeDockAndPayload()
            refresh()
            return
        }
    }

    func stop() {
        reinjectionWorkItem?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Public API
    func refresh(injectIfEnabled: Bool = false) {
        guard isAppleSilicon else {
            state = .unsupported("Dock injection is supported only on Apple silicon.")
            return
        }
        guard !operationInProgress else { return }
        updatePrerequisitesWarning()
        if let handshake = activeHandshake() {
            updateStateOrVersionWarning(from: handshake)
            return
        }
        if let warning = prerequisitesWarning {
            state = .prerequisitesMissing(warning)
            return
        }
        let dockPID = currentDockPID
        if automaticInjectionWasCancelled(for: dockPID) {
            state = .authorizationCancelled(pid: dockPID)
            return
        }
        state = .ready
        if injectIfEnabled, preferences?.automaticInjectionEnabled == true {
            injectionAttempt(expectedPID: dockPID)
        }
    }

    func injectNow() {
        guard !operationInProgress else { return }
        guard isAppleSilicon else {
            state = .unsupported("Dock injection is supported only on Apple silicon.")
            return
        }
        clearCancelledDockPID()
        updatePrerequisitesWarning()
        guard let warning = prerequisitesWarning else {
            if let handshake = activeHandshake() {
                if handshake.payloadVersion == Self.bundledPayloadVersion {
                    updateState(from: handshake)
                } else {
                    requestDockRestartForUpdate(handshake: handshake)
                }
                return
            }
            injectionAttempt(expectedPID: currentDockPID)
            return
        }
        state = .prerequisitesMissing(warning)
    }

    private func injectionAttempt(expectedPID: Int32?) {
        guard !operationInProgress else { return }
        operationInProgress = true
        state = .injecting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = Self.performInjectionViaAdminScript()
            Task { @MainActor in
                self.operationInProgress = false
                switch result {
                case .success:
                    self.scheduleHandshakeCheck(expectedPID: expectedPID)
                case .cancelled:
                    self.rememberCancelledDockPID(expectedPID)
                    self.state = .authorizationCancelled(pid: expectedPID)
                case .failed(let message):
                    self.state = .error(message)
                }
            }
        }
    }

    // MARK: - Private helpers
    private var isAppleSilicon: Bool {
        var supported: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &supported, &size, nil, 0) == 0 && supported == 1
    }

    private func checkPlatform() {
        if !isAppleSilicon {
            state = .unsupported("Dock injection is supported only on Apple silicon.")
        }
    }

    private func updatePrerequisitesWarning() {
        var problems: [String] = []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/nvram")
        process.arguments = ["boot-args"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let arguments = String(decoding: data, as: UTF8.self)
            let requiredArguments = ["-arm64e_preview_abi"]
            let tokens = Set(arguments.split(whereSeparator: \.isWhitespace).map(String.init))
            let missingArguments = requiredArguments.filter { !tokens.contains($0) }
            if !missingArguments.isEmpty {
                let noun = missingArguments.count == 1 ? "argument" : "arguments"
                problems.append("Missing required boot \(noun): \(missingArguments.joined(separator: " ")).")
            }
        } catch {
            problems.append("Could not verify the required boot argument.")
        }

        let sipProcess = Process()
        sipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        sipProcess.arguments = ["status"]
        let sipOutput = Pipe()
        sipProcess.standardOutput = sipOutput
        sipProcess.standardError = sipOutput
        do {
            try sipProcess.run()
            sipProcess.waitUntilExit()
            let data = sipOutput.fileHandleForReading.readDataToEndOfFile()
            let status = String(decoding: data, as: UTF8.self).lowercased()
            if status.contains("custom configuration") {
                let requiredDisabledProtections = [
                    "filesystem protections: disabled",
                    "debugging restrictions: disabled",
                    "nvram protections: disabled",
                ]
                let missingProtections = requiredDisabledProtections.filter {
                    !status.contains($0)
                }
                if !missingProtections.isEmpty {
                    problems.append("The partial System Integrity Protection configuration must disable filesystem, debugging, and NVRAM protections.")
                }
            } else if status.contains("status: enabled") {
                problems.append("System Integrity Protection is fully enabled; disable it or use the documented partial configuration.")
            } else if !status.contains("status: disabled") {
                problems.append("Could not verify that System Integrity Protection is disabled or partially disabled.")
            }
        } catch {
            problems.append("Could not verify System Integrity Protection status.")
        }

        prerequisitesWarning = problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    nonisolated private static func performInjectionViaAdminScript() -> InjectionAttemptResult {
        guard let scriptURL = Bundle.main.resourceURL?
                .appendingPathComponent("Injection")
                .appendingPathComponent("run.sh") else {
            Logger(subsystem: "com.wiggly-sheets.spaces-renamer", category: "InjectionManager")
                .error("Injection script not found in bundle.")
            return .failed("The bundled injection script could not be found.")
        }
        let scriptPath = scriptURL.path
        // Build command: /bin/bash <script_path>
        let command = "/bin/bash \(shellQuoted(scriptPath))"
        let appleScript = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        let appleScriptObj = NSAppleScript(source: appleScript)
        var errorInfo: NSDictionary?
        let _ = appleScriptObj?.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            Logger(subsystem: "com.wiggly-sheets.spaces-renamer", category: "InjectionManager")
                .error("AppleScript error: \(error)")
            if (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue == -128 {
                return .cancelled
            }
            let message = error["NSAppleScriptErrorMessage"] as? String
                ?? "Injection failed; see Console for details."
            return .failed(message)
        }
        // A zero exit only starts handshake verification; it does not prove the payload loaded.
        return .success
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func appleScriptQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private var currentDockPID: Int32? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.dock"
        }?.processIdentifier
    }

    private func automaticInjectionWasCancelled(for pid: Int32?) -> Bool {
        guard let pid else { return false }
        let storedPID = UserDefaults.standard.object(
            forKey: Self.cancelledDockPIDDefaultsKey
        ) as? NSNumber
        if storedPID?.int32Value == pid {
            return true
        }
        if storedPID != nil {
            clearCancelledDockPID()
        }
        return false
    }

    private func rememberCancelledDockPID(_ pid: Int32?) {
        guard let pid else { return }
        UserDefaults.standard.set(Int(pid), forKey: Self.cancelledDockPIDDefaultsKey)
    }

    private func clearCancelledDockPID() {
        UserDefaults.standard.removeObject(forKey: Self.cancelledDockPIDDefaultsKey)
    }

    private func requestDockRestartForUpdate(handshake: Handshake) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restart Dock to update its hook?"
        alert.informativeText = "Dock is running Spaces Renamer \(handshake.payloadVersion), while this app contains \(Self.bundledPayloadVersion). Mission Control will close briefly. macOS will then request administrator approval to inject the updated hook."
        alert.addButton(withTitle: "Restart Dock and Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            updateStateOrVersionWarning(from: handshake)
            return
        }

        guard let dock = NSRunningApplication(processIdentifier: handshake.dockPID) else {
            state = .error("Could not find the running Dock process.")
            return
        }
        pendingInjectionAfterDockRestart = true
        operationInProgress = true
        state = .restartingDock
        guard dock.terminate() else {
            pendingInjectionAfterDockRestart = false
            operationInProgress = false
            state = .error("Dock did not accept the restart request. Restart Dock manually, then click Inject Now.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.pendingInjectionAfterDockRestart else { return }
            self.pendingInjectionAfterDockRestart = false
            self.operationInProgress = false
            self.state = .error("Dock did not relaunch in time. Restart Dock manually, then click Inject Now.")
        }
    }

    // MARK: - Observation
    private func observeDockAndPayload() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                application.bundleIdentifier == "com.apple.dock"
            else { return }
            Task { @MainActor in self?.dockDidRestart(pid: application.processIdentifier) }
        })
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(payloadDidLoad(_:)),
            name: Notification.Name("com.wiggly-sheets.SpacesRenamer.Injected"),
            object: nil
        )
    }

    @objc private func payloadDidLoad(_ notification: Notification) {
        refresh()
    }

    private func dockDidRestart(pid: Int32) {
        reinjectionWorkItem?.cancel()
        if !automaticInjectionWasCancelled(for: pid) {
            clearCancelledDockPID()
        }
        let shouldInject = pendingInjectionAfterDockRestart
            || preferences?.automaticInjectionEnabled == true
        guard shouldInject else {
            operationInProgress = false
            refresh()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingInjectionAfterDockRestart = false
                self.operationInProgress = false
                self.refresh(injectIfEnabled: true)
            }
        }
        reinjectionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func scheduleHandshakeCheck(expectedPID: Int32?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if let handshake = self.activeHandshake(),
               expectedPID == nil || expectedPID == handshake.dockPID {
                self.updateState(from: handshake)
            } else {
                self.state = .error("The injector finished, but Dock did not report the payload.")
            }
        }
    }

    private func activeHandshake() -> Handshake? {
        guard
            let data = try? Data(contentsOf: Self.handshakeURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let protocolVersion = object["protocolVersion"] as? String,
            protocolVersion == Self.injectionProtocolVersion,
            let payloadVersion = object["payloadVersion"] as? String,
            !payloadVersion.isEmpty,
            let number = object["dockPID"] as? NSNumber
        else { return nil }
        let pid = number.int32Value
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" else {
            return nil
        }
        return Handshake(
            dockPID: pid,
            payloadVersion: payloadVersion,
            hookActive: object["phase"] as? String == "active"
        )
    }

    private func updateState(from handshake: Handshake) {
        if handshake.hookActive {
            state = .injected(
                pid: handshake.dockPID,
                payloadVersion: handshake.payloadVersion
            )
        } else {
            state = .loaded(
                pid: handshake.dockPID,
                payloadVersion: handshake.payloadVersion
            )
        }
    }

    private func updateStateOrVersionWarning(from handshake: Handshake) {
        let bundledVersion = Self.bundledPayloadVersion
        guard handshake.payloadVersion != bundledVersion else {
            updateState(from: handshake)
            return
        }
        state = .updateRequired(
            pid: handshake.dockPID,
            loadedVersion: handshake.payloadVersion,
            bundledVersion: bundledVersion
        )
    }
}
