import Foundation

private var failures = 0

private func expect(
    _ description: String,
    _ actual: InjectionDockRestartAction,
    equals expected: InjectionDockRestartAction
) {
    if actual == expected {
        print("ok - \(description)")
    } else {
        failures += 1
        print("FAIL - \(description)")
        print("  expected: \(expected)")
        print("  actual:   \(actual)")
    }
}

@main
struct InjectionLifecycleTests {
    static func main() {
        let oldPID: Int32 = 100
        let newPID: Int32 = 101

        expect(
            "manual payload update stays manual when automatic injection is disabled",
            InjectionLifecyclePolicy.dockRestartAction(
                operation: .restartingDock(id: UUID(), previousPID: oldPID),
                launchedPID: newPID,
                automaticInjectionEnabled: false
            ),
            equals: .scheduleInjection(pid: newPID, intent: .manual)
        )

        expect(
            "Dock relaunch defers instead of replacing an in-flight manual attempt",
            InjectionLifecyclePolicy.dockRestartAction(
                operation: .injecting(id: UUID(), expectedPID: oldPID, intent: .manual),
                launchedPID: newPID,
                automaticInjectionEnabled: false
            ),
            equals: .deferInjection(pid: newPID, intent: .manual)
        )

        expect(
            "an idle manager honors disabled automatic injection",
            InjectionLifecyclePolicy.dockRestartAction(
                operation: nil,
                launchedPID: newPID,
                automaticInjectionEnabled: false
            ),
            equals: .refresh
        )

        expect(
            "a duplicate launch notification for the expected Dock is ignored",
            InjectionLifecyclePolicy.dockRestartAction(
                operation: .injecting(id: UUID(), expectedPID: newPID, intent: .manual),
                launchedPID: newPID,
                automaticInjectionEnabled: true
            ),
            equals: .none
        )

        expect(
            "an idle manager schedules automatic injection when enabled",
            InjectionLifecyclePolicy.dockRestartAction(
                operation: nil,
                launchedPID: newPID,
                automaticInjectionEnabled: true
            ),
            equals: .scheduleInjection(pid: newPID, intent: .automatic)
        )

        expect(
            "duplicate launch notifications do not postpone a scheduled injection",
            InjectionLifecyclePolicy.dockRestartAction(
                operation: .waitingToInject(
                    id: UUID(),
                    dockPID: newPID,
                    intent: .manual
                ),
                launchedPID: newPID,
                automaticInjectionEnabled: false
            ),
            equals: .none
        )

        if failures > 0 {
            exit(1)
        }
    }
}
