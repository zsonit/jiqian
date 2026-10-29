import SwiftUI
import SwiftData
import UIKit

struct SummaryView: View {
    @State private var range: SummaryRange = .day
    @State private var text: String = ""
    @State private var copied = false
    @State private var showEmptyAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("范围", selection: $range) {
                        ForEach(SummaryRange.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

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
                            Haptic.success()
                        }
                        BigButton(title: "分享文字", style: .ghost) {
                            shareAsText()
                        }
                    }

                    Text("分享图片在微信里最稳；如果对方用邮件或备忘录，可以选「分享文字」。摘要只写事实：时间、次数、时长、间隔。")
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
            .background(Pal.bg.ignoresSafeArea())
            .navigationTitle("就诊摘要")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { reload() }
            .onChange(of: range) { _, _ in
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
        Haptic.tap()
        Sharer.share([text])
    }

    private func shareAsImage() {
        guard !text.isEmpty else { showEmptyAlert = true; return }
        Haptic.tap()
        if let image = renderSummaryImage() {
            Sharer.share([image])
        } else {
            Sharer.share([text])
        }
    }

    /// 把摘要文本渲染成白底长图，微信等以图片形式接收
    @MainActor
    private func renderSummaryImage() -> UIImage? {
        let title = "胎动 · 就诊摘要（\(range.label)）\n\(Fmt.longDate(Date()))"
        let content = VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color(hex: 0x16232B))
            Rectangle()
                .fill(Color(hex: 0x2A9D8F))
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
        text = SummaryBuilder.build(range: range)
    }
}
