import SwiftUI
import UIKit

struct ActionsView: View {
    private struct GuideShortcut: Identifiable {
        let id = UUID()
        let title: String
        let action: String
        let detail: String
        let icon: String
        let tint: Color
    }

    private let guides: [GuideShortcut] = [
        GuideShortcut(
            title: "胎动快捷指令",
            action: "记一次胎动",
            detail: "点一下记一笔，不用打开 App。放在桌面最顺手的位置。",
            icon: "waveform.path.ecg",
            tint: Pal.brand
        ),
        GuideShortcut(
            title: "宫缩快捷指令",
            action: "宫缩开始 / 结束",
            detail: "一个动作管两个状态：开始时点一下，结束时再点一下，自动算时长和间隔。",
            icon: "bolt.fill",
            tint: Pal.danger
        )
    ]

    private let steps: [(String, String, String)] = [
        ("1", "打开「快捷指令」App", "页面最下面有直达按钮"),
        ("2", "点右上角 + 号，选「添加操作」", "在搜索框里输入「胎动」"),
        ("3", "选择你要的动作", "记一次胎动 / 宫缩开始·结束 / 结束宫缩…"),
        ("4", "给快捷指令起个名字，点「完成」", "比如「记一次胎动」「宫缩」"),
        ("5", "长按这条快捷指令 → 「添加到主屏幕」", "以后在桌面点一下就执行")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("快捷指令")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Pal.ink)
                        Text("把动作做成点一下就执行的快捷指令，放桌面、放控制中心，随点随记。")
                            .font(.system(size: 14))
                            .foregroundStyle(Pal.ink2)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "推荐创建这两个")
                        ForEach(guides) { g in
                            CardBox {
                                HStack(spacing: 14) {
                                    Image(systemName: g.icon)
                                        .font(.system(size: 20))
                                        .foregroundStyle(g.tint)
                                        .frame(width: 48, height: 48)
                                        .background(g.tint.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(g.title)
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(Pal.ink)
                                        Text("动作：「\(g.action)」")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(g.tint)
                                        Text(g.detail)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Pal.ink2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "创建步骤（一次就好）")
                        CardBox {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(steps, id: \.0) { step in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(step.0)
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 24, height: 24)
                                            .background(Pal.brand)
                                            .clipShape(Circle())
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(step.1)
                                                .font(.system(size: 14.5, weight: .semibold))
                                                .foregroundStyle(Pal.ink)
                                            Text(step.2)
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(Pal.ink2)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "更多点击入口")
                        CardBox {
                            VStack(alignment: .leading, spacing: 12) {
                                entry(icon: "iphone.gen3", title: "操作按钮", detail: "设置 → 操作按钮 → 快捷指令 → 选「记一次胎动」，侧边一按就记录")
                                entry(icon: "square.grid.2x2", title: "控制中心", detail: "控制中心 → 添加控制 → 快捷指令，下拉一点就执行")
                                entry(icon: "lock.iphone", title: "锁屏小组件", detail: "长按锁屏 → 自定义 → 添加快捷指令")
                            }
                        }
                    }

                    Button {
                        if let url = URL(string: "shortcuts://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("打开「快捷指令」App")
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 54)
                        .background(Pal.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Text("动作在快捷指令里以「胎动」开头显示，搜索不到时确认 App 已安装并打开过一次。所有动作点击即执行，执行完会弹一条结果提示；动作只在需要时写入数据，不会在后台常驻。")
                        .font(.system(size: 13))
                        .foregroundStyle(Pal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Pal.card2)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                    DisclaimerCard()
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .background(Pal.bg.ignoresSafeArea())
            .navigationTitle("快捷指令")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func entry(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Pal.ink2)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Pal.ink)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Pal.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
