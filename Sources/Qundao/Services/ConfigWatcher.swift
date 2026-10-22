import Foundation

/// 同时监听目录替换与文件原地写入；仅监听目录会漏掉 FileHandle / 重定向保存。
/// 变化合并 300ms 后在主线程回调。
final class ConfigWatcher {
  private var source: DispatchSourceFileSystemObject?
  private var fileSource: DispatchSourceFileSystemObject?
  private var fileIdentity: UInt64?
  private var pending: DispatchWorkItem?
  private let url: URL
  private let onChange: @MainActor () -> Void
  init?(url: URL, onChange: @escaping @MainActor () -> Void) {
    self.url = url; self.onChange = onChange
    let dir = url.deletingLastPathComponent()
    let fd = open(dir.path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                           queue: .main)
    source.setEventHandler { [weak self] in self?.changed() }
    source.setCancelHandler { close(fd) }
    source.resume()
    self.source = source
    refreshFileSource()
  }
  private func changed() {
    refreshFileSource()
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.refreshFileSource()
      MainActor.assumeIsolated { self.onChange() }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }
  private func refreshFileSource() {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let identity = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    guard identity != fileIdentity else { return }
    fileSource?.cancel(); fileSource = nil; fileIdentity = nil
    guard let identity else { return }
    let fd = open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
      eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
    watcher.setEventHandler { [weak self] in self?.changed() }
    watcher.setCancelHandler { close(fd) }
    fileIdentity = identity; fileSource = watcher; watcher.resume()
  }
  deinit { pending?.cancel(); fileSource?.cancel(); source?.cancel() }
}
