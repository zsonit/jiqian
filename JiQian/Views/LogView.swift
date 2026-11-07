import SwiftUI

/// 运行日志页（排查用）：展示内存环形缓冲里最近的日志，
/// 可复制全部、清空。只读本机内存，不落盘、不同步、不上传。
struct LogView: View {
    @State private var entries: [AppLog.Entry] = []
    @State private var toast: String?

    var body: some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Text("🕊️")
                        .font(.system(size: 40))
                    Text("还没有日志")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Pal.ink2)
                    Text("打开开关后，同步、配对等关键动作会记到这里。")
                        .font(.system(size: 12))
                        .foregroundStyle(Pal.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                logRow(entry)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .onAppear {
                        if let last = entries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Pal.bg.ignoresSafeArea())
        .navigationTitle("🧾 运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        copyAll()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Pal.brand)
                    }
                    .disabled(entries.isEmpty)

                    Button {
                        AppLog.clear()
                        refresh()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Pal.danger)
                    }
                    .disabled(entries.isEmpty)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // 页面停着也能看到新进来的日志
            refresh()
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Pal.brand.opacity(0.96)))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func logRow(_ entry: AppLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(Fmt.hhmmss(entry.t))
                    .font(.system(size: 10.5, weight: .semibold).monospaced())
                    .foregroundStyle(Pal.ink3)
                Text(levelName(entry.level))
                    .font(.system(size: 9.5, weight: .bold).monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(levelColor(entry.level)))
                Spacer()
            }
            Text(entry.text)
                .font(.system(size: 11.5, weight: .regular).monospaced())
                .foregroundStyle(entry.level == "e" ? Pal.danger : Pal.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Pal.line.opacity(0.6)).frame(height: 1)
        }
        .id(entry.id)
    }

    private func levelName(_ level: String) -> String {
        switch level {
        case "w": return "WARN"
        case "e": return "ERR "
        default: return "INFO"
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "w": return Pal.gold
        case "e": return Pal.danger
        default: return Pal.teal
        }
    }

    private func refresh() {
        entries = AppLog.snapshot()
    }

    private func copyAll() {
        let text = entries.map { entry in
            "\(Fmt.hhmmss(entry.t)) [\(levelName(entry.level))] \(entry.text)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
        toast = "已复制 \(entries.count) 条日志"
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }
}
