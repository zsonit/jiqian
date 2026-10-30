import SwiftUI
import SwiftData
import UIKit

struct SummaryView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case byDay, all
        var id: String { rawValue }
        var label: String { self == .byDay ? "按日期" : "全部" }
    }

    @State private var scope: Scope = .byDay
    @State private var selectedDate = Date()
    @State private var text: String = ""
    @State private var totalKicks = 0
    @State private var copied = false
    @State private var showEmptyAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("范围", selection: $scope) {
                        ForEach(Scope.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    if scope == .byDay {
                        CardBox {
                            DatePicker(
                                "选择日期",
                                selection: $selectedDate,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .tint(Pal.brand)
                        }
                    }

                    // 右上角合计大字
                    HStack(alignment: .firstTextBaseline) {
                        Text(scope == .byDay ? "当日胎动合计" : "累计胎动合计")
                            .font(.system(size: 14))
                            .foregroundStyle(Pal.ink2)
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(totalKicks)")
                                .font(.system(size: 38, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Pal.brand)
                            Text("次")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Pal.ink2)
                        }
                    }
                    .padding(.horizontal, 4)

                    CardBox {
                        Text(text)
                            .font(.system(size: 14))
                            .lineSpacing(6)
                            .foregroundStyle(Pal.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 主分享按钮：以图片分享，微信/QQ/短信全都支持
                    Button {
                        shareAsImage()
                    } label: {
                        Text("分享给家人（图片）")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 54)
                            .background(text.isEmpty ? Pal.ink3 : Pal.brand)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(text.isEmpty)

                    HStack(spacing: 10) {
                        BigButton(title: copied ? "已复制" : "复制文字", style: .ghost) {
                            UIPasteboard.general.string = text
                            copied = true
                        }
                        BigButton(title: "分享文字", style: .ghost) {
                            shareAsText()
                        }
                    }

                    Text("小提示：微信不接收纯文本，点「分享文字」后文字已自动复制，去微信聊天框长按粘贴即可；给家人推荐用「分享给家人（图片）」，微信/QQ/短信都最稳。")
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
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .navigationTitle("就诊摘要")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { reload() }
            .onChange(of: scope) { _, _ in
                copied = false
                reload()
            }
            .onChange(of: selectedDate) { _, _ in
                copied = false
                reload()
            }
            .alert("还没有记录", isPresented: $showEmptyAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("先在胎动或宫缩页记录一些数据，再来分享摘要。")
            }
        }
    }

    // MARK: - 分享

    private func shareAsText() {
        guard !text.isEmpty else { showEmptyAlert = true; return }
        // 兜底：先复制，即使目标 App 不收纯文本，聊天框长按粘贴也能用
        UIPasteboard.general.string = text
        Sharer.share([text])
    }

    private func shareAsImage() {
        guard !text.isEmpty else { showEmptyAlert = true; return }
        if let image = renderSummaryImage() {
            Sharer.share([image])
        } else {
            Sharer.share([text])
        }
    }

    /// 把摘要文本渲染成白底长图，微信等以图片形式接收
    @MainActor
    private func renderSummaryImage() -> UIImage? {
        let periodTitle = scope == .byDay
            ? "胎动 · 就诊摘要 · \(Fmt.longDate(selectedDate))"
            : "胎动 · 就诊摘要（全部记录）"
        let title = "\(periodTitle)\n\(Fmt.longDate(Date()))"
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(hex: 0x16232B))
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(totalKicks)")
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: 0xD9548C))
                    Text("次")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: 0x5F6D74))
                }
            }
            Rectangle()
                .fill(Color(hex: 0xD9548C))
                .frame(width: 44, height: 3)
            Text(text)
                .font(.system(size: 14.5))
                .lineSpacing(6)
                .foregroundStyle(Color(hex: 0x16232B))
            Text("由「胎动」App 记录生成，仅事实记录，不含医学判断。")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x5F6D74))
        }
        .padding(22)
        .frame(width: 360, alignment: .leading)
        .background(Color.white)

        let renderer = ImageRenderer(content: content)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
    }

    private func reload() {
        text = scope == .byDay
            ? SummaryBuilder.build(day: selectedDate)
            : SummaryBuilder.build(range: .all)
        totalKicks = scope == .byDay
            ? SummaryBuilder.kicksTotal(day: selectedDate)
            : SummaryBuilder.kicksTotalAll()
    }
}
