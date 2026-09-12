import Foundation

enum InjectionIntent: Equatable {
  case automatic
  case manual
}

enum InjectionOperation: Equatable {
  case injecting(id: UUID, expectedPID: Int32?, intent: InjectionIntent)
  case restartingDock(id: UUID, previousPID: Int32)
  case waitingToInject(id: UUID, dockPID: Int32, intent: InjectionIntent)
}

enum InjectionDockRestartAction: Equatable {
  case none
  case refresh
  case deferInjection(pid: Int32, intent: InjectionIntent)
  case scheduleInjection(pid: Int32, intent: InjectionIntent)
}

struct InjectionLifecyclePolicy {
  static func dockRestartAction(
    operation: InjectionOperation?,
    launchedPID: Int32,
    automaticInjectionEnabled: Bool
  ) -> InjectionDockRestartAction {
    switch operation {
    case .injecting(_, let expectedPID, let intent):
      guard expectedPID != launchedPID else { return .none }
      return .deferInjection(pid: launchedPID, intent: intent)
    case .restartingDock(_, let previousPID):
      guard previousPID != launchedPID else { return .none }
      return .scheduleInjection(pid: launchedPID, intent: .manual)
    case .waitingToInject(_, let dockPID, let intent):
      guard dockPID != launchedPID else { return .none }
      return .scheduleInjection(pid: launchedPID, intent: intent)
    case nil:
      return automaticInjectionEnabled
        ? .scheduleInjection(pid: launchedPID, intent: .automatic)
        : .refresh
    }
  }
}
