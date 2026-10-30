import SwiftUI
import SwiftData

struct RootView: View {
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("首页", systemImage: "house") }
                .tag(0)
            SummaryView()
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("摘要", systemImage: "doc.text") }
                .tag(1)
            SettingsView()
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(2)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassTabBar(selection: $tab)
        }
        .tint(Pal.brand)
        .onOpenURL { url in
            if url.host == "summary" { tab = 1 }
            if url.host == "kick" { tab = 0 }
        }
    }
}

// MARK: - 悬浮液态玻璃底部栏

struct GlassTabBar: View {
    @Binding var selection: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            item(icon: "house", title: "首页", tag: 0)
            item(icon: "doc.text", title: "摘要", tag: 1)
            item(icon: "gearshape", title: "设置", tag: 2)
        }
        .padding(6)
        .background {
            // 毛玻璃胶囊容器
            Capsule(style: .continuous).fill(.ultraThinMaterial)
        }
        .clipShape(Capsule(style: .continuous))
        .overlay {
            // 玻璃厚度高光：上亮下暗的对角渐变（滴水感）
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.05), .white.opacity(0.20)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: 0.9)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func item(icon: String, title: String, tag: Int) -> some View {
        let selected = selection == tag
        return Button {
            guard selection != tag else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                selection = tag
            }
            Haptic.soft()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(selected ? Color.white : Pal.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if selected {
                    // 选中块：品牌色玻璃渐变 + 顶部水滴高光
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Pal.brand.opacity(0.92), Pal.brand],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay {
                            Capsule(style: .continuous)
                                .fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.02), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                                .blendMode(.plusLighter)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: Pal.brand.opacity(0.35), radius: 10, x: 0, y: 4)
                        .matchedGeometryEffect(id: "tabSel", in: ns)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
