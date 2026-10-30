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

// MARK: - 真·液态玻璃底部栏（iOS 26 glassEffect，旧系统自动降级）

/// iOS 26：苹果系统级 Liquid Glass（真实折射 + 高光随手势移动 + 触摸弹性）
/// iOS 26 以下：毛玻璃 + 描边降级
private struct LiquidGlass: ViewModifier {
    var interactive: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular,
                                 in: .capsule)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .clipShape(Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10)],
                                                     startPoint: .top, endPoint: .bottom),
                                      lineWidth: 0.9)
                }
                .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 6)
    }
}

/// 点按时的玻璃弹性：按下轻微压缩，松手回弹
private struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.55),
                       value: configuration.isPressed)
    }
}

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
        .modifier(LiquidGlass(interactive: true))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func item(icon: String, title: String, tag: Int) -> some View {
        let selected = selection == tag
        return Button {
            guard selection != tag else { return }
            // 果冻感的液态滑动：弹性略大，让选中块像液体一样荡过去
            withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) {
                selection = tag
            }
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
                    // 选中指示块：品牌色玻璃渐变，液体般滑到新位置
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Pal.brand.opacity(0.92), Pal.brand],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: Pal.brand.opacity(0.32), radius: 9, x: 0, y: 4)
                        .matchedGeometryEffect(id: "tabSel", in: ns)
                }
            }
        }
        .buttonStyle(GlassPressStyle())
    }
}
