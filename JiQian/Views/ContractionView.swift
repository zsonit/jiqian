import SwiftUI
import SwiftData

struct ContractionView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ContractionEvent.startedAt, order: .reverse) private var allEvents: [ContractionEvent]
    @AppStorage(PrefKey.phone) private var phone: String = ""
    @AppStorage(PrefKey.holdMode) private var holdMode: Bool = false

    @State private var isPressing = false

    private var openEvent: ContractionEvent? {
        allEvents.first(where: { $0.endedAt == nil })
    }

    private var finished: [ContractionEvent] {
        allEvents.filter { $0.endedAt != nil }.sorted { $0.startedAt < $1.startedAt }
    }

    private var stats: ContractionStats? {
        try? ContractionRecorder.stats()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                ring
                mainButton
                statsRow
                hintArea
                historyList
                DisclaimerCard()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .navigationTitle("宫缩")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(openEvent == nil ? "宫缩" : "正在计时")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Pal.ink)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Pal.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if let openEvent {
            return "开始于 \(Fmt.hhmm(openEvent.startedAt)) · 结束后自动算间隔"
        }
        if let last = finished.last, let end = last.endedAt {
            return "上次结束 \(Fmt.hhmm(end)) · 距现在 \(Fmt.duration(Date().timeIntervalSince(end)))"
        }
        return "开始和结束，都是这一个按钮"
    }

    private var ring: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let running = openEvent != nil
            let elapsed: TimeInterval = openEvent.map { timeline.date.timeIntervalSince($0.startedAt) } ?? 0
            let progress: Double = running ? min(1.0, (elapsed.truncatingRemainder(dividingBy: 60)) / 60.0) : 0

            ZStack {
                Circle().strokeBorder(Pal.line, lineWidth: 10).padding(10)
                Circle()
                    .trim(from: 0, to: running ? progress : 0.999)
                    .stroke(running ? Pal.danger : Pal.brand,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(10)
                VStack(spacing: 6) {
                    Text(running ? Fmt.clock(elapsed) : "00:00")
                        .font(.system(size: 52, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Pal.ink)
                    Text(running ? "本次已持续" : "准备记录下一次")
                        .font(.system(size: 13))
                        .foregroundStyle(Pal.ink2)
                    if !running, let last = finished.last {
                        Text(last.gap > 0 ? "上次间隔 \(Fmt.clock(last.gap))" : " ")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Pal.ink3)
                    }
                }
            }
            .frame(width: 288, height: 288)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var mainButton: some View {
        let running = openEvent != nil
        let label = running ? "结束本次收缩" : "开始一次收缩"
        let sub = holdMode ? "按住开始，松开结束" : "点一下开始，再点一下结束"

        if holdMode {
            buttonBody(title: label, subtitle: sub, running: running)
                .scaleEffect(isPressing ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: isPressing)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressing else { return }
                            isPressing = true
                            startIfPossible()
                        }
                        .onEnded { _ in
                            isPressing = false
                            endIfPossible()
                        }
                )
        } else {
            Button {
                if openEvent == nil { startIfPossible() } else { endIfPossible() }
            } label: {
                buttonBody(title: label, subtitle: sub, running: running)
            }
            .buttonStyle(.plain)
        }
    }

    private func buttonBody(title: String, subtitle: String, running: Bool) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
            Text(subtitle)
                .font(.system(size: 11.5, weight: .medium))
                .opacity(0.76)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 78)
        .background(running ? Pal.danger : Pal.brand)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var statsRow: some View {
        if let stats {
            HStack(spacing: 9) {
                StatCell(value: "\(stats.hourCount)", label: "近 1 小时")
                StatCell(value: stats.avgDuration > 0 ? "\(Int(stats.avgDuration.rounded()))s" : "—", label: "平均持续")
                StatCell(value: stats.avgGap > 0 ? "\(Int((stats.avgGap / 60).rounded()))′" : "—", label: "平均间隔")
            }
        }
    }

    @ViewBuilder
    private var hintArea: some View {
        if let stats, stats.trigger {
            AlertBox(
                title: "达到需要联系的参考条件",
                message: "近 1 小时 \(stats.hourCount) 次、平均持续 \(Int(stats.avgDuration.rounded())) 秒、平均间隔 \(Int((stats.avgGap / 60).rounded())) 分钟。这只是提醒阈值，不是诊断。",
                phone: phone
            )
        } else if let stats, stats.soft {
            AlertBox(
                title: "你标记了高风险因素",
                message: "即使还没到常规阈值，也建议更早联系产科机构，不要等间隔缩短。",
                phone: phone
            )
        }

        Text("提示口径：近 1 小时有效收缩 ≥ 6 次、平均持续 ≥ 45 秒、平均间隔 ≤ 10 分钟。破水、鲜红出血、持续剧痛、胎动明显减少，不必等这些条件，直接联系。")
            .font(.system(size: 13))
            .foregroundStyle(Pal.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card2)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    @ViewBuilder
    private var historyList: some View {
        if !finished.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "最近的收缩")
                CardBox(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(Array(finished.reversed().prefix(10)), id: \.id) { event in
                            HStack(spacing: 10) {
                                Circle().fill(Pal.gold).frame(width: 7, height: 7)
                                Text(Fmt.hhmm(event.startedAt))
                                    .font(.system(size: 13))
                                    .monospacedDigit()
                                    .foregroundStyle(Pal.ink2)
                                    .frame(width: 52, alignment: .leading)
                                Text("持续 \(Fmt.clock(event.duration))" + (event.gap > 0 ? " · 间隔 \(Fmt.clock(event.gap))" : "") + (event.isSuspect ? " · 待确认" : ""))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Pal.ink)
                                Spacer()
                                Button {
                                    context.delete(event)
                                    try? context.save()
                                    Haptic.soft()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Pal.ink3)
                                        .padding(8)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private func startIfPossible() {
        do {
            let outcome = try ContractionRecorder.start(source: .app)
            if outcome.alreadyRunning {
                Haptic.warning()
            } else {
                Haptic.strong()
                Sfx.tap()
            }
        } catch {
            Haptic.warning()
        }
    }

    private func endIfPossible() {
        do {
            let outcome = try ContractionRecorder.end()
            if outcome.noneRunning {
                Haptic.warning()
            } else {
                Haptic.success()
                Sfx.success()
            }
        } catch {
            Haptic.warning()
        }
    }
}
