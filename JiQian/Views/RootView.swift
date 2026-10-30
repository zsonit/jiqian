import SwiftUI
import SwiftData

struct RootView: View {
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house") }
                .tag(0)
            SummaryView()
                .tabItem { Label("摘要", systemImage: "doc.text") }
                .tag(1)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(2)
        }
        .tint(Pal.brand)
        .onOpenURL { url in
            if url.host == "summary" { tab = 1 }
            if url.host == "kick" { tab = 0 }
        }
    }
}
