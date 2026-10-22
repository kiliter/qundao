import Foundation

/// 监视配置文件所在目录；编辑器常以“写临时文件再替换”保存，因此监视目录而非文件句柄。
/// 变化合并 300ms 后在主线程回调。
final class ConfigWatcher {
  private var source: DispatchSourceFileSystemObject?
  private var pending: DispatchWorkItem?
  init?(url: URL, onChange: @escaping @MainActor () -> Void) {
    let dir = url.deletingLastPathComponent()
    let fd = open(dir.path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                           queue: .main)
    source.setEventHandler { [weak self] in
      self?.pending?.cancel()
      let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
      self?.pending = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    self.source = source
  }
  deinit { pending?.cancel(); source?.cancel() }
}
