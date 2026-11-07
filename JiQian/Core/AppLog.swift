import Foundation
import os.log

/// 统一日志出口（与萌宝成长 AppLog 同形：AppLog.i/w/e("Sync", "...")）
///
/// v5.5 新增「运行日志（排查用）」：设置页独立开关（默认关）。
/// 打开后，除系统日志外，额外把最近 600 条记进内存环形缓冲，
/// 供 设置 → 运行日志 页面查看 / 复制 / 清空。只在本机内存里，不落盘、不同步、不上传。
enum AppLog {
    /// 开关的 UserDefaults 键（独立开关，不参与配对同步）
    static let enabledKey = "diagLogEnabled"

    private static let log = Logger(subsystem: "com.jiqian.app", category: "Sync")
    private static let cap = 600
    private static var buffer: [Entry] = []
    private static let lock = NSLock()

    struct Entry: Identifiable {
        let id = UUID()
        let t: Date
        let level: String   // "i" / "w" / "e"
        let text: String
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                i("Log", "运行日志已开启")
            } else {
                clear()   // 关掉即清空，不留残留
            }
        }
    }

    static func i(_ tag: String, _ msg: String) { record("i", tag, msg) { log.info("[\(tag)] \(msg)") } }
    static func w(_ tag: String, _ msg: String) { record("w", tag, msg) { log.warning("[\(tag)] \(msg)") } }
    static func e(_ tag: String, _ msg: String) { record("e", tag, msg) { log.error("[\(tag)] \(msg)") } }

    private static func record(_ level: String, _ tag: String, _ msg: String, _ write: () -> Void) {
        write()
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(Entry(t: Date(), level: level, text: "[\(tag)] \(msg)"))
        if buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
    }

    /// 最近的记录（旧的在前），给日志页展示 / 复制用
    static func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}
