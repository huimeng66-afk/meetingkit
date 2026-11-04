//
//  SharedFrameStore.swift
//  Shared
//
//  屏幕共享画面的跨进程通道：扩展写、主 App 读。
//
//  为什么用文件而不是 UserDefaults：一帧 800px 宽的 JPEG 约 40~80KB，
//  每秒 4 帧，塞进 UserDefaults 会让 cfprefsd 反复全量序列化，既慢又浪费内存。
//
//  设计约束：
//    1. 全部方法不能抛错、不能 crash —— 扩展里一次未捕获异常就是整场共享黑屏；
//    2. 写用 .atomic（临时文件 + rename），读侧永远看到完整的旧帧或完整的新帧，
//       不存在读到半个 JPEG 的情况，所以读不需要加锁；
//    3. 扩展侧调用频率高，方法内不创建多余的大对象。
//

import Foundation

struct SharedFrameStore {

    private static let fileName = "screen-share-latest.jpg"

    /// 序列化写与删除。读操作不加锁（依赖 .atomic 写入的原子性）。
    private static let fileQueue = DispatchQueue(
        label: "com.example.meetingkit.framestore",
        qos: .userInitiated
    )

    /// 共享容器内最新一帧的路径。容器不可用时返回 nil（多半是 App Group 没配好）。
    static func fileURL() -> URL? {
        guard let container = AppGroupConfig.containerURL() else { return nil }
        return container.appendingPathComponent(fileName, isDirectory: false)
    }

    /// 写入最新一帧。
    ///
    /// 注意这里是同步写：调用方（扩展的编码队列）写完紧接着就要 post frameUpdated，
    /// 如果改成异步，主 App 可能收到通知时文件还是上一帧，出现"画面总是慢一拍"的诡异现象。
    /// 写操作本身在编码队列上执行，不会阻塞 ReplayKit 的采样回调。
    static func write(jpeg data: Data) {
        fileQueue.sync {
            guard let url = fileURL() else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // 静默失败：共享画面丢一帧不影响会议，宁可什么都不做也不能中断广播。
            }
        }
    }

    /// 读取最新一帧。文件不存在或损坏时返回 nil。
    static func read() -> Data? {
        guard let url = fileURL() else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// 只在文件比 `date` 更新时才读取，用于做主 App 侧的去重。
    ///
    /// `date` 是调用方持有的"上次已消费版本"，成功读取后会被就地更新为新的修改时间；
    /// 没有新帧时既不读取文件内容，也不修改 `date`。
    static func readIfNewer(than date: inout Date?) -> Data? {
        guard let url = fileURL() else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }

        if let lastConsumed = date, modified <= lastConsumed {
            return nil
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        date = modified
        return data
    }

    /// 清空共享帧。扩展结束广播时调用，避免主 App 下次进会时看到上一场会议的残留画面。
    static func clear() {
        fileQueue.sync {
            guard let url = fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
