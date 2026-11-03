import WidgetKit
import SwiftUI
import UIKit

// MARK: - 时间线（组件只做入口，不读数据库，所以内容是静态的）

struct QuickEntry: TimelineEntry {
    let date: Date
}

struct QuickProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickEntry { QuickEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (QuickEntry) -> Void) {
        completion(QuickEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickEntry>) -> Void) {
        completion(Timeline(entries: [QuickEntry(date: Date())], policy: .never))
    }
}

// MARK: - 配色（与 App 内的粉系保持一致）

enum WPal {
    static let brand = Color(red: 0xD9 / 255.0, green: 0x54 / 255.0, blue: 0x8C / 255.0)
    static let brandSoft = Color(red: 0xD9 / 255.0, green: 0x54 / 255.0, blue: 0x8C / 255.0).opacity(0.16)
}

// MARK: - 锁屏：胎动

struct LockKickWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JiQianLockKick", provider: QuickProvider()) { _ in
            LockKickView()
        }
        .configurationDisplayName("胎动 · 锁屏开关")
        .description("锁屏上点一下，立刻记一次胎动。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockKickView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Link(destination: QuickLink.kick) {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "figure.walk.motion")
                            .font(.system(size: 17, weight: .semibold))
                        Text("胎动")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .widgetAccentable()
            }
        case .accessoryInline:
            Link(destination: QuickLink.kick) {
                Label("点一下记一次胎动", systemImage: "figure.walk.motion")
            }
        default:
            Link(destination: QuickLink.kick) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 20, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("胎动")
                            .font(.system(size: 15, weight: .bold))
                        Text("点一下记一次")
                            .font(.system(size: 11.5))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetAccentable()
            }
        }
    }
}

// MARK: - 锁屏：宫缩（一个开关两个状态：点一下开始，再点一下结束保存）

struct LockContractionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JiQianLockContraction", provider: QuickProvider()) { _ in
            LockContractionView()
        }
        .configurationDisplayName("宫缩 · 锁屏开关")
        .description("锁屏上点一下开始计时，再点一下结束并保存。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockContractionView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Link(destination: QuickLink.contraction) {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "timer")
                            .font(.system(size: 17, weight: .semibold))
                        Text("宫缩")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .widgetAccentable()
            }
        case .accessoryInline:
            Link(destination: QuickLink.contraction) {
                Label("点一下开始或结束宫缩计时", systemImage: "timer")
            }
        default:
            Link(destination: QuickLink.contraction) {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("宫缩")
                            .font(.system(size: 15, weight: .bold))
                        Text("点一下开始，再点结束")
                            .font(.system(size: 11.5))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetAccentable()
            }
        }
    }
}

// MARK: - 桌面：两个开关并排

struct QuickHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JiQianQuickHome", provider: QuickProvider()) { _ in
            QuickHomeView()
        }
        .configurationDisplayName("胎动 / 宫缩 快捷开关")
        .description("桌面或锁屏上一键记录，不用先翻 App。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickHomeView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(spacing: 8) {
                    header
                    QuickTile(title: "记胎动", icon: "figure.walk.motion", url: QuickLink.kick, filled: true)
                    QuickTile(title: "宫缩计时", icon: "timer", url: QuickLink.contraction, filled: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    HStack(spacing: 10) {
                        QuickTile(title: "记胎动", icon: "figure.walk.motion", url: QuickLink.kick, filled: true)
                        QuickTile(title: "宫缩计时", icon: "timer", url: QuickLink.contraction, filled: false)
                    }
                }
            }
        }
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WPal.brand)
            Text("胎动记录")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// 单个开关：整块都是点击区域
struct QuickTile: View {
    let title: String
    let icon: String
    let url: URL
    var filled: Bool

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(filled ? Color.white : WPal.brand)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(filled ? WPal.brand : WPal.brandSoft)
            )
        }
    }
}

// MARK: - 注册

@main
struct JiQianWidgets: WidgetBundle {
    var body: some Widget {
        QuickHomeWidget()
        LockKickWidget()
        LockContractionWidget()
    }
}
