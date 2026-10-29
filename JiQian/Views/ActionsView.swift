import SwiftUI
import UIKit

struct ActionsView: View {
    private struct ActionItem: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let icon: String
        let phrase: String
    }

    private let items: [ActionItem] = [
        ActionItem(title: "记一次胎动", detail: "不打开应用，直接落库并返回结果", icon: "waveform.path.ecg", phrase: "记一次胎动"),
        ActionItem(title: "开始数胎动", detail: "新建一轮计数会话", icon: "timer", phrase: "开始数胎动"),
        ActionItem(title: "宫缩开始 / 结束", detail: "一个动作覆盖两个状态", icon: "bolt.fill", phrase: "记录宫缩"),
        ActionItem(title: "结束宫缩计时", detail: "只做「结束」，不会误开新计时", icon: "checkmark.circle", phrase: "结束宫缩"),
        ActionItem(title: "就诊摘要", detail: "直接打开可以念给医生的记录", icon: "doc.text", phrase: "打开就诊摘要")
    ]

    @State private var copiedTitle: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("动作")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Pal.ink)
                        Text("装好就已经注册到系统，不需要你自己搭快捷指令。")
                            .font(.system(size: 14))
                            .foregroundStyle(Pal.ink2)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "可用动作")
                        CardBox(padding: 4) {
                            VStack(spacing: 0) {
                                ForEach(items) { item in
                                    HStack(spacing: 12) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 16))
                                            .foregroundStyle(Pal.brand)
                                            .frame(width: 40, height: 40)
                                            .background(Pal.brandSoft)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(Pal.ink)
                                            Text(item.detail)
                                                .font(.system(size: 12))
                                                .foregroundStyle(Pal.ink3)
                                        }
                                        Spacer()
                                        Button {
                                            UIPasteboard.general.string = "嘿 Siri，\(item.phrase)"
                                            copiedTitle = item.title
                                            Haptic.success()
                                        } label: {
                                            Text(copiedTitle == item.title ? "已复制" : "语音")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(Pal.brand)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 7)
                                                .background(Pal.brandSoft)
                                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 11)
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "三个入口")
                        CardBox {
                            VStack(alignment: .leading, spacing: 12) {
                                entry(icon: "mic.fill", title: "对 Siri 说", detail: "「嘿 Siri，记一次胎动」——说的就是上面的短语")
                                entry(icon: "iphone.gen3", title: "操作按钮", detail: "设置 → 操作按钮 → 快捷指令 → 选「记一次胎动」")
                                entry(icon: "square.grid.2x2", title: "控制中心 / 锁屏", detail: "控制中心 → 添加控制 → 快捷指令；锁屏小组件同理")
                            }
                        }
                    }

                    Button {
                        if let url = URL(string: "shortcuts://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("打开「快捷指令」App")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 54)
                            .background(Pal.brand)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Text("如果先在 Siri 里找不到，对着手机说一次「嘿 Siri，记一次胎动」，系统就会把这个动作记进建议里。动作只在需要时写入，不会在后台常驻。")
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
            .navigationTitle("动作")
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
