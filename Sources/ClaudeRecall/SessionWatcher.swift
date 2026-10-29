import Foundation
import CoreServices

/// 监听本地 Claude Code 会话目录。只在 App 运行期间工作，不驻留。
final class SessionWatcher {
    private let root: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.joshuami449.ccjv.session-watcher")
    private var stream: FSEventStreamRef?
    private var retryWorkItem: DispatchWorkItem?

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        onChange: @escaping () -> Void
    ) {
        self.root = root
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: root.path) else {
            scheduleRetry()
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SessionWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.notify()
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            scheduleRetry()
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            scheduleRetry()
            return
        }
        self.stream = stream
        if retryWorkItem != nil {
            retryWorkItem = nil
            notify()
        }
    }

    private func scheduleRetry() {
        guard retryWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.start()
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange()
        }
    }
}
