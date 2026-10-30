import SwiftUI
import SwiftData

enum HomeRoute: Hashable {
    case kick
    case contraction
}

struct HomeView: View {
    @Query(sort: \KickSession.startedAt, order: .reverse) private var sessions: [KickSession]
    @Query(sort: \KickEvent.occurredAt, order: .reverse) private var events: [KickEvent]
    @Query(sort: \ContractionEvent.startedAt, order: .reverse) private var contractions: [ContractionEvent]

    @AppStorage(PrefKey.edd) private var eddTimestamp: Double = 0
    @AppStorage(PrefKey.provider) private var provider: String = ""
    @AppStorage(PrefKey.phone) private var phone: String = ""

    private var edd: Date? {
        eddTimestamp > 0 ? Date(timeIntervalSince1970: eddTimestamp) : nil
    }

    private var activeSession: KickSession? {
        sessions.first(where: { $0.endedAt == nil })
    }

    private var activeKickCount: Int {
        guard let activeSession else { return 0 }
        return events.filter { $0.sessionID == activeSession.id }.count
    }

    private var openContraction: ContractionEvent? {
        contractions.first(where: { $0.endedAt == nil })
    }

    private var todayKicks: Int {
        events.filter { Fmt.isSameDay($0.occurredAt, Date()) }.count
    }

    private var todayContractions: Int {
        contractions.filter { $0.endedAt != nil && Fmt.isSameDay($0.startedAt, Date()) }.count
    }

    private var stats: ContractionStats? {
        try? ContractionRecorder.stats()
    }

    private var windowHint: (count: Int, target: Int, minutes: Int)? {
        try? KickRecorder.windowHint()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    cards
                    hintSection
                    todaySection
                    contactCard
                    DisclaimerCard()
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .kick: KickView()
                case .contraction: ContractionView()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Pal.brand)
                    Text("胎动")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(1.2)
                }
                Spacer()
                Pill(text: weekText)
            }
            Text(greeting)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Pal.ink)
                .padding(.top, 6)
            Text(activeSession != nil || openContraction != nil ? "正在记录中，锁屏也不会丢。" : "点一下就能记，别的都交给我。")
                .font(.system(size: 14))
                .foregroundStyle(Pal.ink2)
        }
    }

    private var weekText: String {
        guard let g = PregnancyClock.gestation(for: edd) else { return "未设定孕周" }
        return g.isPreterm ? "\(g.label) · 未足月" : g.label
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<5: return "夜里也在记"
        case 5..<11: return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        default: return "晚上好"
        }
    }

    private var cards: some View {
        VStack(spacing: 12) {
            NavigationLink(value: HomeRoute.kick) {
                BigCard(
                    caption: "胎动",
                    value: activeSession != nil ? "\(activeKickCount)" : "\(todayKicks)",
                    unit: activeSession != nil ? "次 · 本轮进行中" : "次 · 今日",
                    subtitle: activeSession != nil
                        ? "本轮进行中 · 开始于 \(Fmt.hhmm(activeSession?.startedAt ?? Date()))"
                        : "轻点进入，单点即记一次",
                    live: activeSession != nil,
                    tint: Pal.brand
                )
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeRoute.contraction) {
                BigCard(
                    caption: "宫缩",
                    value: openContraction != nil ? "计时中" : "\(todayContractions)",
                    unit: openContraction != nil ? "" : "次 · 今日",
                    subtitle: openContraction != nil
                        ? "正在计时 · 开始于 \(Fmt.hhmm(openContraction?.startedAt ?? Date()))"
                        : "开始和结束都是同一个大按钮",
                    live: openContraction != nil,
                    tint: Pal.gold
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var hintSection: some View {
        if let stats, stats.trigger {
            AlertBox(
                title: "现在的记录达到需要联系的参考条件",
                message: "近 1 小时 \(stats.hourCount) 次，平均持续 \(Int(stats.avgDuration.rounded())) 秒，平均间隔 \(Int((stats.avgGap / 60).rounded())) 分钟。这不是诊断结论，请按你与产科团队确认的方式联系。",
                phone: phone
            )
        } else if let stats, stats.soft {
            AlertBox(
                title: "你标记了高风险因素",
                message: "近 1 小时 \(stats.hourCount) 次。即使还没到常规阈值，也建议更早联系产科机构。",
                phone: phone
            )
        }

        if let hint = windowHint {
            AlertBox(
                title: "这一轮已经记了 \(hint.minutes) 分钟，还没到 \(hint.target) 次",
                message: "如果感觉比平时明显减少，或你不放心，直接联系产科机构，不需要等计数完成。本应用不做判断。",
                phone: phone
            )
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "今日")
            HStack(spacing: 9) {
                StatCell(value: "\(todayKicks)", label: "胎动记录")
                StatCell(value: "\(todayContractions)", label: "宫缩次数")
                StatCell(value: stats.map { $0.avgDuration > 0 ? "\(Int($0.avgDuration.rounded()))s" : "—" } ?? "—",
                         label: "平均持续")
            }
        }
    }

    private var contactCard: some View {
        CardBox {
            HStack(spacing: 12) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Pal.brand)
                    .frame(width: 40, height: 40)
                    .background(Pal.brandSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.isEmpty ? "产科机构" : provider)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Pal.ink)
                    Text(phone.isEmpty ? "在设置里填上电话，急用时不用翻通讯录" : "任何不确定，先打这个电话")
                        .font(.system(size: 12))
                        .foregroundStyle(Pal.ink2)
                }
                Spacer()
                if !phone.isEmpty, let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })") {
                    Link(destination: url) {
                        Text("拨打")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Pal.brand)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Pal.brandSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }
}

struct BigCard: View {
    let caption: String
    let value: String
    let unit: String
    let subtitle: String
    let live: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Pal.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Pal.ink)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 13))
                        .foregroundStyle(Pal.ink2)
                }
            }
            HStack(spacing: 6) {
                if live {
                    Circle()
                        .fill(Pal.brand)
                        .frame(width: 7, height: 7)
                }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Pal.ink2)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Pal.card, tint.opacity(0.22)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(live ? Pal.brand.opacity(0.45) : Pal.line, lineWidth: 1)
        )
    }
}
