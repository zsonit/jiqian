import Foundation

// MARK: - 云服务配置（配对同步）
//
// 复用萌宝成长已经在线的同款 WorkBuddy 托管后端（同一位作者的现有基础设施），
// 与萌宝共用 mengbao_sync 一张按配对码索引的表：
// * 胎动的 payload 与萌宝一样是端到端加密信封（AES-256-GCM），云端只存密文，
//   既读不出内容，也无法区分是谁写的；
// * 两端 App 创建配对码时都查同一张表做查重，天然避免两个 App 撞码；
//   误把胎动配对码输进萌宝（或反过来）只会解密失败并提示重输，不会互相污染。
//
// 若以后给胎动开通了独立的云环境，只需改下面两行 + 表名即可。
enum CloudCfg {
    static let endpoint = "https://mengbao-sync.app.workbuddy.host"
    static let publishableKey = "wbpk_z3Qd2DmHRK20lYTyzpjsTH_DG9v1WdRyKgkBsMLewH3mh5Br7EOcUlR"
    /// 按配对码索引的同步表（与萌宝成长共用，见上）
    static let table = "mengbao_sync"
}
