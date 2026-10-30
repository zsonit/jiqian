import SwiftUI
import SwiftData

struct KickView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \KickSession.startedAt, order: .reverse) private var sessions: [KickSession]
    @Query(sort: \KickEvent.occurredAt, order: .reverse) private var events: [KickEvent]
    @AppStorage(PrefKey.phone) private var phone: String = ""

    @State private var showEndConfirm = false

    private var active: KickSession? {
        sessions.first(where: { $0.endedAt == nil })
    }

    private var activeEvents: [KickEvent] {
        guard let active else { return [] }
        return events.filter { $0.sessionID == active.id }.sorted { $0.occurredAt < $1.occurredAt }
    }

    private var lastSession: KickSession? {
        sessions.first(where: { $0.endedAt != nil })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let active {
                    activeContent(active)
                } else {
                    idleContent
                }
                DisclaimerCard()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(GlassBackdrop())
        .navigationTitle("胎动")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            // 到点自动收尾本轮并无缝开启下一轮
            _ = try? KickRecorder.rolloverIfNeeded(at: now)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 从后台回来立即校正：中间错过的每一轮按时间边界补齐
            _ = try? KickRecorder.rolloverIfNeeded()
        }
        .confirmationDialog("结束这一轮？", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("结束本轮", role: .destructive) {
                try? KickRecorder.endActiveSession(reason: "manual")
            }
            Button("继续记录", role: .cancel) {}
        } message: {
            Text("结束后仍可在摘要里看到这一轮的记录。")
        }
    }

    // MARK: - 有进行中的会话

    @ViewBuilder
    private func activeContent(_ session: KickSession) -> some View {
        let count = activeEvents.count
        let roundNo = sessions.filter {
            Calendar.current.isDate($0.startedAt, inSameDayAs: session.startedAt) && $0.startedAt <= session.startedAt
        }.count

        // 每秒重算剩余时间，倒计时真正动态跳动
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remain = max(0, KickRecorder.roundLength - timeline.date.timeIntervalSince(session.startedAt))

            VStack(alignment: .leading, spacing: 4) {
                Text("第 \(roundNo) 轮 · 第 \(count) 次")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Pal.ink)
                Text("开始于 \(Fmt.hhmm(session.startedAt)) · 本轮剩余 \(Fmt.clock(remain))")
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(remain <= 300 ? Pal.danger : Pal.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            pad(count: count, remain: remain)
        }

        if count == 0 && session.lessThanUsualRaw < 0 {
            CardBox(fill: Pal.goldSoft, stroke: .clear) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("开始前先确认一下：宝宝今天是否明显少于平时？")
                        .font(.system(size: 14))
                        .foregroundStyle(Pal.ink)
                    HStack(spacing: 8) {
                        chip("和平时差不多") { try? KickRecorder.markUsual(false) }
                        chip("明显少于平时") {
                            try? KickRecorder.markUsual(true)
                            Haptic.warning()
                        }
                    }
                }
            }
        }

        if session.lessThanUsualRaw == 1 {
            AlertBox(
                title: "先联系，再继续记",
                message: "感觉明显减少时，不用等这一轮结束。直接联系产科机构，把你的感受和今天的记录一起说清楚。",
                phone: phone
            )
        }

        HStack(spacing: 10) {
            BigButton(title: "撤销最近一次", style: .ghost) {
                let ok = (try? KickRecorder.undoLast()) ?? false
                if ok { Haptic.soft() } else { Haptic.warning() }
            }
            BigButton(title: "结束本轮", style: .ghost) {
                showEndConfirm = true
            }
        }

        if !activeEvents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "本轮记录")
                CardBox(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(Array(activeEvents.reversed().prefix(12)), id: \.id) { event in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Pal.brand)
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Fmt.mdHms(event.occurredAt))
                                        .font(.system(size: 13))
                                        .monospacedDigit()
                                        .foregroundStyle(Pal.ink2)
                                    Text("第 \(activeEvents.firstIndex(where: { $0.id == event.id }).map(String.init) ?? "-") 次 · \(event.source.label)")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Pal.ink3)
                                }
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

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Pal.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Pal.card)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func pad(count: Int, remain: TimeInterval) -> some View {
        let roundProgress = min(1.0, max(0, 1.0 - remain / KickRecorder.roundLength))
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Pal.card, Pal.brandSoft],
                                     center: .center,
                                     startRadius: 12,
                                     endRadius: 180))
            Circle()
                .strokeBorder(Pal.line, lineWidth: 9)
                .padding(9)
            Circle()
                .trim(from: 0, to: roundProgress)
                .stroke(remain <= 300 ? Pal.danger : Pal.brand,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(9)
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(count)")
                        .font(.system(size: 74, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Pal.brand)
                    Text("次")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Pal.ink2)
                }
                Text("本轮剩余 \(Fmt.clock(remain))")
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(remain <= 300 ? Pal.danger : Pal.ink)
                Text("到点自动开始下一轮")
                    .font(.system(size: 12))
                    .foregroundStyle(Pal.ink3)
                Text(lastText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Pal.ink3)
            }
        }
        .frame(width: 296, height: 296)
        .contentShape(Circle())
        .onTapGesture { record() }
        .padding(.vertical, 6)
    }

    private var lastText: String {
        guard let last = activeEvents.last else { return "还没有记录" }
        return "距上次 \(Fmt.clock(Date().timeIntervalSince(last.occurredAt)))"
    }

    // MARK: - 没有进行中的会话

    private var idleContent: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("胎动")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Pal.ink)
                Text("单点一次算一次。连续翻滚算 1 次，不用追着数。")
                    .font(.system(size: 14))
                    .foregroundStyle(Pal.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let lastSession {
                let count = events.filter { $0.sessionID == lastSession.id }.count
                CardBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("上一轮 · \(Fmt.hhmm(lastSession.startedAt))")
                            .font(.system(size: 12))
                            .tracking(1)
                            .foregroundStyle(Pal.ink3)
                        Text("\(count) 次")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Pal.ink)
                        Text("用时 \(Fmt.duration((lastSession.endedAt ?? Date()).timeIntervalSince(lastSession.startedAt)))")
                            .font(.system(size: 13))
                            .foregroundStyle(Pal.ink2)
                    }
                }
            }

            BigButton(title: "开始数胎动", subtitle: "每轮 \(Prefs.roundMin) 分钟 · 到点自动下一轮") {
                _ = try? KickRecorder.startNewSession(source: .app)
                Haptic.tap()
            }

            Text("开始后每一轮 \(Prefs.roundMin) 分钟倒计时，到点自动无缝开始下一轮，随时可手动结束。离开应用用快捷指令记录同样有效。")
                .font(.system(size: 13))
                .foregroundStyle(Pal.ink2)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Pal.card2)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }


    private func record() {
        do {
            let outcome = try KickRecorder.record(source: .app)
            if outcome.duplicate {
                Haptic.warning()
                return
            }
            Haptic.tap()
            Sfx.tap()
        } catch {
            Haptic.warning()
        }
    }
}
