import AppKit
import Foundation
import os

enum InjectionState: Equatable {
    case unsupported(String)
    case bootArgsWarning(String)
    case ready
    case injecting
    case injected(pid: Int32)
    case error(String)

    var title: String {
        switch self {
        case .unsupported: return "Unavailable"
        case .bootArgsWarning: return "Boot arguments required"
        case .ready: return "Ready to inject"
        case .injecting: return "Injecting"
        case .injected: return "Injected"
        case .error: return "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .unsupported(let reason): return reason
        case .bootArgsWarning(let reason): return reason
        case .ready: return "The required boot arguments are present; ready to inject."
        case .injecting: return "Loading the bundled payload into Dock…"
        case .injected(let pid): return "The current Dock process (PID \(pid)) has loaded Spaces Renamer."
        case .error(let reason): return reason
        }
    }

    var symbol: String {
        switch self {
        case .injected: return "checkmark.circle.fill"
        case .injecting: return "clock.arrow.circlepath"
        case .ready: return "checkmark.shield"
        case .bootArgsWarning: return "exclamationmark.triangle.fill"
        case .unsupported, .error: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class InjectionManager: ObservableObject {
    @Published private(set) var state: InjectionState = .ready
    @Published private(set) var operationInProgress = false
    @Published private(set) var bootArgumentsWarning: String?

    private weak var preferences: PreferencesStore?
    private var observers: [NSObjectProtocol] = []
    private var reinjectionWorkItem: DispatchWorkItem?

    private static let handshakeURL = URL(
        fileURLWithPath: "/tmp/spaces-renamer-injection-\(getuid()).json"
    )
    private static let injectionScriptName = "run.sh"
    private static let logger = Logger(subsystem: "com.wiggly-sheets.spaces-renamer", category: "InjectionManager")
    private static let injectionProtocolVersion = "1"

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
        if let pid = injectedDockPID() {
            state = .injected(pid: pid)
            return
        }
        // Not injected
        if case .bootArgsWarning = state {
            // already shows warning, do not auto-inject
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
        guard case .bootArgsWarning = state else {
            // boot arguments must be OK
            guard let warning = bootArgumentsWarning, !warning.isEmpty else {
                // no warning, proceed
                injectionAttempt()
                return
            }
            state = .bootArgsWarning(warning)
            return
        }
    }

    private func injectionAttempt() {
        operationInProgress = true
        state = .injecting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.performInjectionViaAdminScript()
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
            let required = arguments.contains("-arm64e_preview_abi") ||
                           arguments.contains("amfi_get_out_of_my_way=1")
            bootArgumentsWarning = required ? nil : "Required reduced-security boot arguments were not detected."
            // Update state based on warning
            if let warning = bootArgumentsWarning, !warning.isEmpty {
                if case .bootArgsWarning = state {
                    // keep
                } else {
                    state = .bootArgsWarning(warning)
                }
            } else {
                // clear warning; if currently showing warning, move to ready
                if case .bootArgsWarning = state {
                    state = .ready
                }
            }
        } catch {
            bootArgumentsWarning = "Could not verify the required boot arguments."
            if let warning = bootArgumentsWarning, !warning.isEmpty {
                if case .bootArgsWarning = state {
                    // keep
                } else {
                    state = .bootArgsWarning(warning)
                }
            }
        }
    }

    private func performInjectionViaAdminScript() -> Bool {
        guard let scriptURL = Bundle.main.resourceURL?
                .appendingPathComponent("Injection")
                .appendingPathComponent(Self.injectionScriptName) else {
            Self.logger.error("Injection script not found in bundle.")
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
            Self.logger.error("AppleScript error: \(error)")
            return false
        }
        // If we got here without error, assume script succeeded (it exits 0 on success)
        return true
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
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
            if let pid = self.injectedDockPID(), expectedPID == nil || expectedPID == pid {
                self.state = .injected(pid: pid)
            } else {
                self.state = .error("The injector finished, but Dock did not report the payload.")
            }
        }
    }

    private func injectedDockPID() -> Int32? {
        guard
            let data = try? Data(contentsOf: Self.handshakeURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let protocolVersion = object["protocolVersion"] as? String,
            protocolVersion == Self.injectionProtocolVersion,
            let number = object["dockPID"] as? NSNumber
        else { return nil }
        let pid = number.int32Value
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
            ? pid
            : nil
    }
}