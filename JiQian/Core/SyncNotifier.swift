import Foundation
import UserNotifications
import UIKit

// MARK: - 权限申请通知
//
// 只读端（B）点「申请编辑权限」后，写端（A）需要立刻知道。
// 这里用本地通知：A 的 App 在前台时，轮询（6 秒）发现新申请即提醒；
// A 切回前台时也会补提醒（App 被系统挂起时无法联网，故不是服务器推送）。
// 点通知直接打开 App 并跳到「配对同步」页审批。

extension Notification.Name {
    /// 点了「有人申请编辑权限」的通知：App 内需要跳到配对同步页
    static let jiqianOpenSync = Notification.Name("jiqian.openSync")
}

final class SyncNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = SyncNotifier()

    private let center = UNUserNotificationCenter.current()

    /// 设成通知代理：前台也弹横幅，点通知能跳转
    func prepare() {
        center.delegate = self
    }

    /// 请求通知权限。只在真正开始用配对同步时调用，不打扰只用本机记录的人。
    func requestAuthorization() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                let detail = error.map { " err=\($0.localizedDescription)" } ?? ""
                AppLog.i("Notify", "通知权限：\(granted)\(detail)")
            }
        }
    }

    /// 提醒「这些设备在申请编辑权限」。同一台设备只提醒一次（去重在 SyncManager 里做）。
    func notifyPermissionRequests(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "有设备申请编辑权限"
        content.body = ids.count == 1
            ? "设备 \(ids[0]) 想修改胎动记录，点开审批"
            : "\(ids.joined(separator: "、")) 想修改胎动记录，点开审批"
        content.sound = .default
        content.threadIdentifier = "jiqian.acl"
        content.userInfo = ["open": "sync"]

        let key = ids.sorted().joined(separator: "-")
        let request = UNNotificationRequest(identifier: "jiqian.acl.\(key)",
                                            content: content,
                                            trigger: nil)
        center.add(request) { error in
            if let error { AppLog.w("Notify", "通知发送失败：\(error.localizedDescription)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// App 在前台时也显示横幅 + 声音（默认前台不显示）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// 点通知：打开 App 并跳到配对同步页
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["open"] as? String == "sync" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .jiqianOpenSync, object: nil)
            }
        }
        completionHandler()
    }
}
