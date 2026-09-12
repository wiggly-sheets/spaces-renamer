import Darwin
import Foundation

final class ReplacingFileWatcher {
  private let fileURL: URL
  private let directoryURL: URL
  private let onChange: () -> Void
  private let onError: (String) -> Void
  private var fileSource: DispatchSourceFileSystemObject?
  private var directorySource: DispatchSourceFileSystemObject?
  private var reloadWorkItem: DispatchWorkItem?
  private var pendingWatcherReopen = false
  private var reloadGeneration = 0

  init(
    fileURL: URL,
    onChange: @escaping () -> Void,
    onError: @escaping (String) -> Void
  ) {
    self.fileURL = fileURL
    directoryURL = fileURL.deletingLastPathComponent()
    self.onChange = onChange
    self.onError = onError
  }

  func start() {
    guard directorySource == nil else { return }
    startDirectoryWatcher()
    reopenFileWatcher()
  }

  func stop() {
    reloadGeneration += 1
    pendingWatcherReopen = false
    reloadWorkItem?.cancel()
    reloadWorkItem = nil
    fileSource?.cancel()
    fileSource = nil
    directorySource?.cancel()
    directorySource = nil
  }

  deinit { stop() }

  private func startDirectoryWatcher() {
    let fd = open(directoryURL.path, O_EVTONLY)
    guard fd >= 0 else {
      onError(String(cString: strerror(errno)))
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .rename, .delete, .revoke],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      self?.scheduleReload(reopenWatcher: true)
    }
    source.setCancelHandler { close(fd) }
    directorySource = source
    source.resume()
  }

  private func reopenFileWatcher() {
    fileSource?.cancel()
    fileSource = nil

    let fd = open(fileURL.path, O_EVTONLY)
    guard fd >= 0 else {
      if errno != ENOENT { onError(String(cString: strerror(errno))) }
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
      queue: .main
    )
    source.setEventHandler { [weak self, weak source] in
      guard let source else { return }
      let replacementEvents: DispatchSource.FileSystemEvent = [.rename, .delete, .revoke]
      self?.scheduleReload(
        reopenWatcher: !source.data.intersection(replacementEvents).isEmpty
      )
    }
    source.setCancelHandler { close(fd) }
    fileSource = source
    source.resume()
  }

  private func scheduleReload(reopenWatcher: Bool) {
    pendingWatcherReopen = pendingWatcherReopen || reopenWatcher
    reloadGeneration += 1
    let generation = reloadGeneration
    reloadWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, generation == self.reloadGeneration else { return }
      let needsReopen = self.pendingWatcherReopen
      self.pendingWatcherReopen = false
      self.reloadWorkItem = nil
      if needsReopen { self.reopenFileWatcher() }
      self.onChange()
    }
    reloadWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
  }
}
