import SwiftUI
import SwiftData

struct RootView: View {
    @State private var tab: Int = 0

    var body: some View {
        ZStack {
            page(HomeView(), index: 0)
            page(SummaryView(), index: 1)
            page(SettingsView(), index: 2)
        }
        // 页面切换：Q 弹弹簧过渡（新页从 94% 放大弹出，旧页缩小淡出）
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: tab)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassTabBar(selection: $tab)
        }
        .tint(Pal.brand)
        .onOpenURL { url in
            if url.host == "summary" { tab = 1 }
            if url.host == "kick" { tab = 0 }
        }
    }

    @ViewBuilder
    private func page(_ view: some View, index: Int) -> some View {
        let active = tab == index
        view
            .opacity(active ? 1 : 0)
            .scaleEffect(active ? 1 : 0.94)
            .offset(y: active ? 0 : 16)
            .allowsHitTesting(active)
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

/// 点按时的玻璃弹性：按下压缩，松手 Q 弹回弹
private struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.5),
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
        .animation(.spring(response: 0.42, dampingFraction: 0.55), value: selection)
        .padding(6)
        .modifier(LiquidGlass(interactive: false))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func item(icon: String, title: String, tag: Int) -> some View {
        let selected = selection == tag
        return Button {
            // 立即切页，不等动画
            selection = tag
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(selected ? Pal.brand : Pal.ink2)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                if selected {
                    // 选中指示块：透明液态玻璃（淡品牌色透底 + 高光 + 白描边）
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [Pal.brand.opacity(0.28), Pal.brand.opacity(0.14)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.50), .white.opacity(0.06), .white.opacity(0.22)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                        Capsule(style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.70), .white.opacity(0.16)],
                                                         startPoint: .top, endPoint: .bottom),
                                          lineWidth: 0.9)
                    }
                    .shadow(color: Pal.brand.opacity(0.16), radius: 8, x: 0, y: 3)
                    .matchedGeometryEffect(id: "tabSel", in: ns)
                }
            }
        }
        .buttonStyle(GlassPressStyle())
    }
}
