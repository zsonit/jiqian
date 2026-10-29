import SwiftUI
import SwiftData

@main
struct JiQianApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(JiQianStore.container)
    }
}
