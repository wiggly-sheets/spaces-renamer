import AppKit
import CryptoKit
import Foundation
import os
import Security

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
        case .restartingDock: return "Waiting for macOS to relaunch or settle Dock before injecting the bundled payload…"
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
    private var activeOperation: InjectionOperation? {
        didSet {
            let isInProgress = activeOperation != nil
            if operationInProgress != isInProgress {
                operationInProgress = isInProgress
            }
        }
    }
    private var deferredDockRestart: PendingDockRestart?
    private var handshakeCheckID: UUID?

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

    private struct PendingDockRestart {
        let pid: Int32
        let intent: InjectionIntent
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
        reinjectionWorkItem = nil
        handshakeCheckID = nil
        deferredDockRestart = nil
        activeOperation = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Public API
    func refresh(injectIfEnabled: Bool = false) {
        refresh(injectionIntent: injectIfEnabled ? .automatic : nil)
    }

    private func refresh(injectionIntent: InjectionIntent?) {
        guard isAppleSilicon else {
            state = .unsupported("Dock injection is supported only on Apple silicon.")
            return
        }
        guard activeOperation == nil else { return }
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
        if injectionIntent != .manual, automaticInjectionWasCancelled(for: dockPID) {
            state = .authorizationCancelled(pid: dockPID)
            return
        }
        if injectionIntent == .manual {
            clearCancelledDockPID()
        }
        state = .ready
        guard let injectionIntent else { return }
        if injectionIntent == .automatic,
           preferences?.automaticInjectionEnabled != true {
            return
        }
        injectionAttempt(expectedPID: dockPID, intent: injectionIntent)
    }

    func injectNow() {
        guard activeOperation == nil else { return }
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
            injectionAttempt(expectedPID: currentDockPID, intent: .manual)
            return
        }
        state = .prerequisitesMissing(warning)
    }

    private func injectionAttempt(expectedPID: Int32?, intent: InjectionIntent) {
        guard activeOperation == nil else { return }
        let operation = InjectionOperation.injecting(
            id: UUID(),
            expectedPID: expectedPID,
            intent: intent
        )
        activeOperation = operation
        state = .injecting
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.activeOperation == operation else { return }
            let result = Self.performInjectionViaAdminScript()
            guard self.activeOperation == operation else { return }

            let deferredRestart = self.deferredDockRestart
            self.deferredDockRestart = nil
            if deferredRestart == nil {
                self.activeOperation = nil
            }

            switch result {
            case .success:
                if deferredRestart == nil {
                    self.scheduleHandshakeCheck(expectedPID: expectedPID)
                }
            case .cancelled:
                self.rememberCancelledDockPID(expectedPID)
                if deferredRestart == nil {
                    self.state = .authorizationCancelled(pid: expectedPID)
                }
            case .failed(let message):
                if deferredRestart == nil {
                    self.state = .error(message)
                }
            }

            if let deferredRestart {
                self.scheduleInjectionAfterDockRestart(
                    pid: deferredRestart.pid,
                    intent: deferredRestart.intent
                )
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

    private static func performInjectionViaAdminScript() -> InjectionAttemptResult {
        guard Thread.isMainThread else {
            Logger(subsystem: "com.wiggly-sheets.spaces-renamer", category: "InjectionManager")
                .fault("Refusing to create NSAppleScript away from the main thread.")
            return .failed("The administrator prompt could not be opened safely.")
        }
        guard validateRunningBundleSignature(),
              let artifacts = loadVerifiedArtifacts(),
              validateRunningBundleSignature() else {
            Logger(subsystem: "com.wiggly-sheets.spaces-renamer", category: "InjectionManager")
                .error("The app bundle or its injection resources failed integrity validation.")
            return .failed("The bundled injection resources could not be verified. Reinstall Spaces Renamer before injecting.")
        }

        let command = InjectionCommandBuilder.privilegedCommand(for: artifacts)
        let appleScript = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        guard let appleScriptObj = NSAppleScript(source: appleScript) else {
            return .failed("The administrator prompt could not be prepared.")
        }
        var errorInfo: NSDictionary?
        appleScriptObj.executeAndReturnError(&errorInfo)
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

    private static func validateRunningBundleSignature() -> Bool {
        let resourceSeal = Bundle.main.bundleURL
            .appendingPathComponent("Contents/_CodeSignature/CodeResources")
        guard isRegularFile(resourceSeal) else { return false }

        var runningCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess,
              let runningCode else { return false }
        let runningValidationFlags = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecCodeCheckValidity(
            runningCode,
            runningValidationFlags,
            nil
        ) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return false }
        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        return SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess
    }

    private static func loadVerifiedArtifacts() -> InjectionArtifactSet? {
        guard let injectionDirectory = Bundle.main.resourceURL?
            .appendingPathComponent("Injection/lib", isDirectory: true) else {
            return nil
        }
        let injectorURL = injectionDirectory.appendingPathComponent("dylinject")
        let payloadURL = injectionDirectory.appendingPathComponent("spaces-renamer.dylib")
        guard isRegularFile(injectorURL), isRegularFile(payloadURL),
              let injectorData = try? Data(contentsOf: injectorURL, options: .mappedIfSafe),
              let payloadData = try? Data(contentsOf: payloadURL, options: .mappedIfSafe) else {
            return nil
        }
        return InjectionArtifactSet(
            injectorURL: injectorURL,
            payloadURL: payloadURL,
            injectorHash: sha256(injectorData),
            payloadHash: sha256(payloadData)
        )
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        let operation = InjectionOperation.restartingDock(
            id: UUID(),
            previousPID: handshake.dockPID
        )
        activeOperation = operation
        state = .restartingDock
        guard dock.terminate() else {
            activeOperation = nil
            state = .error("Dock did not accept the restart request. Restart Dock manually, then click Inject Now.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.activeOperation == operation else { return }
            self.activeOperation = nil
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
        handshakeCheckID = nil
        let action = InjectionLifecyclePolicy.dockRestartAction(
            operation: activeOperation,
            launchedPID: pid,
            automaticInjectionEnabled: preferences?.automaticInjectionEnabled == true
        )
        switch action {
        case .none:
            return
        case .refresh:
            reinjectionWorkItem?.cancel()
            reinjectionWorkItem = nil
            refresh()
        case .deferInjection(let pid, let intent):
            deferInjectionAfterDockRestart(pid: pid, intent: intent)
        case .scheduleInjection(let pid, let intent):
            scheduleInjectionAfterDockRestart(pid: pid, intent: intent)
        }
    }

    private func deferInjectionAfterDockRestart(pid: Int32, intent: InjectionIntent) {
        let mergedIntent: InjectionIntent
        if deferredDockRestart?.intent == .manual || intent == .manual {
            mergedIntent = .manual
        } else {
            mergedIntent = .automatic
        }
        deferredDockRestart = PendingDockRestart(pid: pid, intent: mergedIntent)
    }

    private func scheduleInjectionAfterDockRestart(pid: Int32, intent: InjectionIntent) {
        reinjectionWorkItem?.cancel()
        handshakeCheckID = nil
        let operation = InjectionOperation.waitingToInject(
            id: UUID(),
            dockPID: pid,
            intent: intent
        )
        activeOperation = operation
        state = .restartingDock
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.activeOperation == operation else { return }
                self.reinjectionWorkItem = nil
                self.activeOperation = nil
                self.refresh(injectionIntent: intent)
            }
        }
        reinjectionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func scheduleHandshakeCheck(expectedPID: Int32?) {
        let checkID = UUID()
        handshakeCheckID = checkID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self,
                  self.handshakeCheckID == checkID,
                  self.activeOperation == nil else { return }
            self.handshakeCheckID = nil
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
