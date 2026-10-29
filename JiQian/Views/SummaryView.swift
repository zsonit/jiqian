import SwiftUI
import SwiftData
import UIKit

struct SummaryView: View {
    @State private var range: SummaryRange = .day
    @State private var text: String = ""
    @State private var copied = false

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

                    HStack(spacing: 10) {
                        BigButton(title: copied ? "已复制" : "复制", style: .ghost) {
                            UIPasteboard.general.string = text
                            copied = true
                            Haptic.success()
                        }
                        ShareLink(item: text) {
                            Text("分享给家人")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 54)
                                .background(Pal.brand)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }

                    Text("摘要只写事实：时间、次数、时长、间隔。不含任何判断语句，避免医生被 App 的措辞带偏。")
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
        }
    }

    private func reload() {
        text = SummaryBuilder.build(range: range)
    }
}
