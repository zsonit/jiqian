import SwiftUI
import UIKit
import AudioToolbox

/// 与网页版一致的视觉语言：暖白纸感 + 深青主色，深色模式自动切换。
enum Pal {
    static let bg = Color.dyn(0xF6F4EF, 0x121614)
    static let bg2 = Color.dyn(0xEFECE4, 0x171D1A)
    static let card = Color.dyn(0xFFFFFF, 0x1B2220)
    static let card2 = Color.dyn(0xFBFAF6, 0x202925)
    static let ink = Color.dyn(0x16232B, 0xEEF3F0)
    static let ink2 = Color.dyn(0x5F6D74, 0xA9B6B1)
    static let ink3 = Color.dyn(0x8B979C, 0x7D8B86)
    static let line = Color.dyn(0xE5E1D7, 0x2B3531)
    static let brand = Color.dyn(0x0F5A50, 0x5CC0AE)
    static let brandSoft = Color.dyn(0xE4EFEC, 0x1D3330)
    static let gold = Color.dyn(0xA8772C, 0xD3A45F)
    static let goldSoft = Color.dyn(0xFBF2E2, 0x2A2418)
    static let danger = Color.dyn(0xB2362D, 0xE0796F)
    static let dangerSoft = Color.dyn(0xFBECEB, 0x331E1C)
}

extension Color {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }

    init(hex: UInt32) {
        self = Color(UIColor(rgb: hex))
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(rgb & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}

enum Haptic {
    // 常驻生成器 + prepare()，避免临时对象被提前释放导致震动丢失
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private static let notifGen = UINotificationFeedbackGenerator()

    /// 系统级强震动兜底：不依赖触感反馈生成器，任何机型都能震出来
    private static func systemVibrate() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    static func soft() {
        guard Prefs.hapticOn else { return }
        lightGen.impactOccurred()
        systemVibrate()
    }
    static func tap() {
        guard Prefs.hapticOn else { return }
        rigidGen.prepare()
        rigidGen.impactOccurred()
        systemVibrate()
    }
    static func strong() {
        guard Prefs.hapticOn else { return }
        heavyGen.prepare()
        heavyGen.impactOccurred()
        systemVibrate()
    }
    static func success() {
        guard Prefs.hapticOn else { return }
        notifGen.notificationOccurred(.success)
        systemVibrate()
    }
    static func warning() {
        guard Prefs.hapticOn else { return }
        notifGen.notificationOccurred(.warning)
        systemVibrate()
    }
}

/// 用 UIKit 直接弹系统分享面板，兼容性最好
@MainActor
enum Sharer {
    static func share(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }
}

// MARK: - 液态玻璃风格

/// 彩色渐晕背景：给毛玻璃材质提供透出来的颜色层次
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let strength = scheme == .dark ? 0.55 : 1.0
        return ZStack {
            Pal.bg
            GeometryReader { geo in
                ZStack {
                    blob(Pal.brand.opacity(0.22 * strength),
                         size: geo.size.width * 1.05,
                         center: CGPoint(x: -geo.size.width * 0.18, y: -geo.size.height * 0.05))
                    blob(Pal.gold.opacity(0.18 * strength),
                         size: geo.size.width * 0.95,
                         center: CGPoint(x: geo.size.width * 1.05, y: geo.size.height * 0.28))
                    blob(Pal.danger.opacity(0.13 * strength),
                         size: geo.size.width * 0.9,
                         center: CGPoint(x: geo.size.width * 0.42, y: geo.size.height * 1.08))
                }
                .blur(radius: 70)
            }
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, size: CGFloat, center: CGPoint) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .position(center)
    }
}

/// 玻璃描边：上亮下暗的高光，模拟玻璃厚度
private struct GlassStroke: View {
    var cornerRadius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06), .white.opacity(0.22)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

// MARK: - 基础容器

struct CardBox<Content: View>: View {
    var padding: CGFloat
    var fill: Color
    var stroke: Color
    let content: Content

    /// fill 为默认值时走液态玻璃，传入自定义色时保持原实底（用于金色提示等特殊卡）
    private var useGlass: Bool { fill == Pal.card }

    init(padding: CGFloat = 16,
         fill: Color = Pal.card,
         stroke: Color = Pal.line,
         @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.fill = fill
        self.stroke = stroke
        self.content = content()
    }

    var body: some View {
        if useGlass {
            glassBody
        } else {
            solidBody
        }
    }

    private var glassBody: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(GlassStroke(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.09), radius: 18, x: 0, y: 8)
    }

    private var solidBody: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Pal.ink3)
            .padding(.horizontal, 2)
    }
}

struct Pill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Pal.brand)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Pal.brandSoft)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Pal.brand.opacity(0.28), lineWidth: 1))
    }
}

struct BigButton: View {
    enum Style: Equatable { case solid, ghost, danger }
    let title: String
    var subtitle: String? = nil
    var style: Style = .solid
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .opacity(0.72)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(buttonStroke)
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch style {
        case .solid: return .white
        case .ghost: return Pal.ink
        case .danger: return Pal.danger
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .solid:
            // 主按钮：品牌色玻璃渐变 + 顶部高光
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Pal.brand.opacity(0.88), Pal.brand],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    LinearGradient(colors: [.white.opacity(0.32), .clear, .white.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                )
                .shadow(color: Pal.brand.opacity(0.35), radius: 14, x: 0, y: 6)
        case .ghost:
            // 次按钮：纯玻璃
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        case .danger:
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Pal.dangerSoft)
        }
    }

    @ViewBuilder
    private var buttonStroke: some View {
        if style == .ghost {
            GlassStroke(cornerRadius: 20)
        }
    }
}

struct AlertBox: View {
    let title: String
    let message: String
    var phone: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Pal.danger)
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(Pal.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let phone, !phone.isEmpty, let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })") {
                Link(destination: url) {
                    Text("拨打 \(phone)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Pal.danger)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.dangerSoft)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct DisclaimerCard: View {
    var body: some View {
        Text("这不是医疗设备。胎动只帮你把时间点记清楚，方便你和医生沟通。任何「提示联系」都不等于诊断；胎动明显减少、破水、出血、持续剧痛时，请直接联系产科机构或急诊。")
            .font(.system(size: 12.5))
            .foregroundStyle(Pal.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card2)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Pal.line, lineWidth: 1)
            )
    }
}

struct StatCell: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Pal.ink)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Pal.ink2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(GlassStroke(cornerRadius: 18))
    }
}
