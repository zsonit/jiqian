import Foundation
import SwiftData

/// 锁屏 / 桌面组件点按后落到 App 的动作。
/// 组件用 `jiqian://quick-kick`、`jiqian://quick-contraction` 打开 App，
/// App 在 onOpenURL 里解析成这里的枚举并立刻落库，用户点一下就是一次记录。
enum QuickAction: String {
    case kick = "quick-kick"
    case contraction = "quick-contraction"

    init?(url: URL) {
        guard url.scheme == "jiqian", let host = url.host, let action = QuickAction(rawValue: host) else {
            return nil
        }
        self = action
    }

    /// 落库后停留的页面（两种动作都在首页，记录结果就在眼前）
    var pageIndex: Int { 0 }
}

/// 组件动作的实际执行（与 App 内按钮走同一套记录器，只读端同样会被拦截）
@MainActor
enum QuickActions {
    struct Feedback {
        var text: String
        var ok: Bool
    }

    static func run(_ action: QuickAction) -> Feedback {
        // 查看模式（配对但未获授权）：和 App 内按钮一样直接拦掉
        guard SyncManager.shared.canEdit else {
            return Feedback(text: "查看模式：请先在「设置 → 配对同步」申请编辑权限", ok: false)
        }
        do {
            switch action {
            case .kick:
                let outcome = try KickRecorder.record(source: .widget)
                if outcome.duplicate {
                    return Feedback(text: "刚刚已经记过一次，没有重复记录", ok: false)
                }
                guard outcome.saved else {
                    return Feedback(text: "这次没有保存，打开 App 再试一次", ok: false)
                }
                Haptic.success()
                let remain: String
                if let start = outcome.sessionStart {
                    let left = max(0, KickRecorder.roundLength - Date().timeIntervalSince(start))
                    remain = String(format: "，本轮还剩 %d:%02d", Int(left) / 60, Int(left) % 60)
                } else {
                    remain = ""
                }
                return Feedback(text: "已记下第 \(outcome.count) 次胎动\(remain)", ok: true)

            case .contraction:
                let running = (try? ContractionRecorder.openEvent(in: JiQianStore.context)) ?? nil
                if running != nil {
                    let outcome = try ContractionRecorder.end()
                    Haptic.success()
                    let gap = outcome.gap > 0 ? "，距上次 \(Fmt.clock(outcome.gap))" : ""
                    return Feedback(text: "已保存本次宫缩 \(Fmt.clock(outcome.duration))\(gap)", ok: true)
                }
                let outcome = try ContractionRecorder.start(source: .widget)
                guard outcome.started else {
                    return Feedback(text: "已经有一段宫缩在计时了", ok: false)
                }
                Haptic.tap()
                return Feedback(text: "宫缩计时已开始，再点一下结束", ok: true)
            }
        } catch {
            AppLog.e("Quick", "组件动作失败：\(error)")
            return Feedback(text: "记录失败，请打开 App 重试", ok: false)
        }
    }
}
