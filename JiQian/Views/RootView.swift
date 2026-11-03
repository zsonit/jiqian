import SwiftUI
import SwiftData
import Combine

struct RootView: View {
    @State private var tab: Int = 0
    @State private var showSyncSheet = false
    @State private var quickToast: String?
    @State private var toastToken = UUID()
    @ObservedObject private var sync = SyncManager.shared

    /// 待我审批的编辑权限申请（本机可编辑时才有）
    private var pendingRequests: [SyncSnapshot.ACL.Req] {
        guard sync.canEdit else { return [] }
        return sync.acl?.req ?? []
    }

    var body: some View {
        ZStack {
            // 固定背景层：不参与切页动画，避免缩放时露出空白，也不再重复渲染模糊
            GlassBackdrop()
            page(HomeView(), index: 0)
            page(SummaryView(), index: 1)
            page(SettingsView(), index: 2)
        }
        // 页面切换：轻柔淡入上浮，快速到位、不晃眼
        .animation(.easeOut(duration: 0.26), value: tab)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if sync.pairedCode != nil && !sync.canEdit {
                    // 查看模式横幅：这台手机只能看，改不了
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.system(size: 11, weight: .semibold))
                        Text("查看模式 · 修改数据需在「设置 → 配对同步」申请权限")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Pal.ink2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Pal.brandSoft)
                }
                if !pendingRequests.isEmpty {
                    // 有人申请编辑权限：常驻横幅，点一下直接进审批页
                    Button {
                        showSyncSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bell.badge.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text(pendingRequests.count == 1
                                 ? "设备 \(pendingRequests[0].id) 申请编辑权限 · 点此审批"
                                 : "\(pendingRequests.count) 台设备申请编辑权限 · 点此审批")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(Pal.brand)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassTabBar(selection: $tab)
        }
        // 点系统通知进来：直接弹审批页
        .sheet(isPresented: $showSyncSheet) {
            NavigationStack {
                SyncView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showSyncSheet = false }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jiqianOpenSync)) { _ in
            showSyncSheet = true
        }
        // 锁屏 / 桌面组件点按进来的结果提示
        .overlay(alignment: .bottom) {
            if let quickToast {
                Text(quickToast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Pal.brand.opacity(0.96)))
                    .shadow(color: Pal.brand.opacity(0.30), radius: 12, x: 0, y: 5)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .tint(Pal.brand)
        .onOpenURL { url in
            if url.host == "summary" { tab = 1; return }
            if url.host == "kick" { tab = 0; return }
            // 组件开关：立刻落库，并把结果提示出来
            if let action = QuickAction(url: url) {
                tab = action.pageIndex
                let feedback = QuickActions.run(action)
                toast(feedback.text)
            }
        }
    }

    @MainActor
    private func toast(_ text: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.18)) { quickToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard toastToken == token else { return }
            withAnimation(.easeIn(duration: 0.22)) { quickToast = nil }
        }
    }

    @ViewBuilder
    private func page(_ view: some View, index: Int) -> some View {
        let active = tab == index
        view
            .opacity(active ? 1 : 0)
            // 只做轻微上浮（14pt），无缩放，观感稳定不眼花
            .offset(y: active ? 0 : 14)
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

/// 点按时玻璃轻轻下压，松手缓出回弹（不弹跳）
private struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.14),
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
        .animation(.easeOut(duration: 0.22), value: selection)
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
