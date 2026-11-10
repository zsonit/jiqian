import SwiftUI
import SwiftData

@main
struct JiQianApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(JiQianStore.container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // 回到前台：立即同步一次并开启自动检查
                AppLog.i("App", "进入前台")
                BackupManager.autoIfNeeded()
                SyncManager.shared.appDidBecomeActive()
            case .background:
                // 退到后台：停轮询，抢推未上传的改动
                AppLog.i("App", "退到后台")
                SyncManager.shared.appDidEnterBackground()
            default:
                break
            }
        }
    }
}
