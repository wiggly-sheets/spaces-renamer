import AppKit
import Foundation
import os

enum InjectionState: Equatable {
    case unsupported(String)
    case prerequisitesMissing(String)
    case ready
    case injecting
    case loaded(pid: Int32, payloadVersion: String)
    case injected(pid: Int32, payloadVersion: String)
    case error(String)

    var title: String {
        switch self {
        case .unsupported: return "Unavailable"
        case .prerequisitesMissing: return "Setup required"
        case .ready: return "Ready to inject"
        case .injecting: return "Injecting"
        case .loaded: return "Injected — awaiting verification"
        case .injected: return "Injected"
        case .error: return "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .unsupported(let reason): return reason
        case .prerequisitesMissing(let reason): return reason
        case .ready: return "The required boot argument is present; ready to inject."
        case .injecting: return "Loading the bundled payload into Dock…"
        case .loaded(let pid, let payloadVersion):
            return "Dock PID \(pid) loaded payload version \(payloadVersion). Open Mission Control once to verify the renaming hook."
        case .injected(let pid, let payloadVersion):
            return "Dock PID \(pid) verified payload version \(payloadVersion) in Mission Control."
        case .error(let reason): return reason
        }
    }

    var symbol: String {
        switch self {
        case .injected: return "checkmark.circle.fill"
        case .injecting, .loaded: return "clock.arrow.circlepath"
        case .ready: return "checkmark.shield"
        case .prerequisitesMissing: return "exclamationmark.triangle.fill"
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

    private static let handshakeURL = URL(
        fileURLWithPath: "/tmp/spaces-renamer-injection-\(getuid()).json"
    )
    private static let injectionProtocolVersion = "1"

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
            refresh(injectIfEnabled: true)
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
        updateBootArgumentsWarning()
        if let handshake = activeHandshake() {
            updateState(from: handshake)
            return
        }
        if let warning = prerequisitesWarning {
            state = .prerequisitesMissing(warning)
            return
        }
        state = .ready
        if injectIfEnabled, preferences?.automaticInjectionEnabled == true {
            injectNow()
        }
    }

    func injectNow() {
        guard isAppleSilicon else {
            state = .unsupported("Dock injection is supported only on Apple silicon.")
            return
        }
        updateBootArgumentsWarning()
        guard let warning = prerequisitesWarning else {
            injectionAttempt()
            return
        }
        state = .prerequisitesMissing(warning)
    }

    private func injectionAttempt() {
        operationInProgress = true
        state = .injecting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = Self.performInjectionViaAdminScript()
            let message = success ? "" : "Injection failed; see console for details."
            Task { @MainActor in
                self.operationInProgress = false
                if success {
                    self.scheduleHandshakeCheck(expectedPID: nil)
                } else {
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

    private func updateBootArgumentsWarning() {
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
            if missingArguments.isEmpty {
                prerequisitesWarning = nil
            } else {
                let noun = missingArguments.count == 1 ? "argument" : "arguments"
                prerequisitesWarning = "Missing required boot \(noun): \(missingArguments.joined(separator: " ")). SIP must also be disabled or partially disabled."
            }
        } catch {
            prerequisitesWarning = "Could not verify the required boot argument."
        }
    }

    nonisolated private static func performInjectionViaAdminScript() -> Bool {
        guard let scriptURL = Bundle.main.resourceURL?
                .appendingPathComponent("Injection")
                .appendingPathComponent("run.sh") else {
            Logger(subsystem: "com.wiggly-sheets.spaces-renamer", category: "InjectionManager")
                .error("Injection script not found in bundle.")
            return false
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
            return false
        }
        // A zero exit only starts handshake verification; it does not prove the payload loaded.
        return true
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func appleScriptQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
            Task { @MainActor in self?.dockDidRestart() }
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

    private func dockDidRestart() {
        reinjectionWorkItem?.cancel()
        guard preferences?.automaticInjectionEnabled == true else {
            refresh()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh(injectIfEnabled: true) }
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
}
