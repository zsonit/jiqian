import Foundation
import os.log

/// 统一日志出口（与萌宝成长 AppLog 同形：AppLog.i/w/e("Sync", "...")）
enum AppLog {
    private static let log = Logger(subsystem: "com.jiqian.app", category: "Sync")

    static func i(_ tag: String, _ msg: String) { log.info("[\(tag)] \(msg)") }
    static func w(_ tag: String, _ msg: String) { log.warning("[\(tag)] \(msg)") }
    static func e(_ tag: String, _ msg: String) { log.error("[\(tag)] \(msg)") }
}
