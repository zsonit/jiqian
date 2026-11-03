import Foundation

/// 组件 → App 的动作链接。
/// 组件本身不直接写数据库（扩展与 App 数据容器相互隔离），
/// 而是用 Link 打开 App 并带上这个 URL，由 App 在 onOpenURL 里立即完成记录，
/// 用户点一下 = 记一次，只多了一次「App 被唤起」的过程，没有任何多余步骤。
enum QuickLink {
    static let scheme = "jiqian"

    static let kick = URL(string: "jiqian://quick-kick")!
    static let contraction = URL(string: "jiqian://quick-contraction")!
}
