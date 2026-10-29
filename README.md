# 胎动 JiQian

孕期记录 iOS App —— 胎动计数、宫缩计时、就诊摘要，**快捷指令优先**。

原生 SwiftUI + SwiftData + **App Intents / App Shortcuts**。装好之后，Siri、操作按钮、控制中心、锁屏都能一句话记一次胎动或一次宫缩。

> 这不是医疗设备。全部提示都是「建议联系产科机构」，不做任何诊断判断。

---

## 为什么是「云端编译」

编译 iOS App 必须有 macOS + Xcode。你的机器没有 Mac，所以这个仓库自带一条 GitHub Actions 流水线：**推到 GitHub 上，云端 macOS 机器自动编译，产出可以直接拿去自签名的 `.ipa`。**

整条链路不需要你本地装任何东西。

---

## 三步拿到可安装的 IPA

### 1. 推到你的 GitHub

仓库已经在本地提交好（分支 `main`）。在仓库目录执行：

```bash
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

### 2. 等云端编译

推送后自动触发 `Build unsigned IPA`：

- 进入仓库 → **Actions** → 选 `Build unsigned IPA`
- 等 3～5 分钟，变绿
- 点进这次运行 → 页面底部 **Artifacts** → 下载 `JiQian-unsigned-ipa`
- 解压得到 `JiQian-unsigned.ipa`

也可以手动触发：Actions → Build unsigned IPA → Run workflow。

### 3. 用你的证书自签名

这个 IPA 是**未签名**的，正是给自签名工具用的。任选一种：

| 工具 | 平台 | 说明 |
|---|---|---|
| **Sideloadly** | Win / Mac | 最直接，支持自备 `.p12` + `.mobileprovision` |
| **AltStore / SideStore** | Win / Mac | 用 Apple ID 签名，免费账号 7 天需续签 |
| **ESign / 爱思助手** | iOS / Win | 手机上直接签名安装 |

**关键一点：Bundle ID 必须和你的描述文件匹配。** 打开 `project.yml`，改这一行再重新构建：

```yaml
PRODUCT_BUNDLE_IDENTIFIER: com.jiqian.app   # 改成你证书里注册过的 App ID
```

Sideloadly 里也可以直接勾选修改 Bundle ID，两者选一个即可。

装好后如果提示「不受信任的开发者」：设置 → 通用 → VPN 与设备管理 → 信任你的证书。iOS 16 以上还需要：设置 → 隐私与安全性 → **开发者模式** → 打开并重启。

---

## 装好后怎么用快捷指令

**不用你手动搭快捷指令。** App 首次启动时就把动作注册进系统了，`App Shortcuts` 会自动出现在「快捷指令」App、Siri、聚焦搜索里。

### 五个动作

| 动作 | Siri 短语 | 行为 |
|---|---|---|
| 记一次胎动 | 记一次胎动 | 立刻写一条，本轮第 N 次，不打开界面 |
| 开始数胎动 | 开始数胎动 | 新建一轮计数会话（会打开 App） |
| 宫缩开始 / 结束 | 记录宫缩 | 没在计时就开始，在计时就结束并保存 |
| 结束宫缩计时 | 结束宫缩 | 只做结束，绝不误开新计时 |
| 就诊摘要 | 打开就诊摘要 | 直接跳到摘要页 |

### 三个入口

- **Siri**：「嘿 Siri，记一次胎动」
- **操作按钮**（iPhone 15 及以后）：设置 → 操作按钮 → 快捷指令 → 选「记一次胎动」
- **控制中心 / 锁屏**：控制中心 → 添加控制 → 快捷指令；锁屏小组件同理

如果 Siri 一开始不认识，**对着手机说一次短语**即可，系统会把它记进建议。

> 设计上刻意只留 5 个动作：宫缩天然是「开 / 关」两态，一个动作就够；胎动则是「单次」和「开始一轮」两个语义，不能合并。

---

## 本地构建（有 Mac 时）

```bash
brew install xcodegen
xcodegen generate
open JiQian.xcodeproj
```

Xcode 里选你的 Team 就能直接跑真机。

---

## 目录结构

```
project.yml                     XcodeGen 工程定义（Bundle ID / 版本号在这里改）
JiQian/
  JiQianApp.swift               应用入口
  Models/Models.swift           SwiftData 模型：会话 + 原始事件
  Core/
    Store.swift                 全局 ModelContainer（App 与 Intent 共用）
    Prefs.swift                 设置项
    PregnancyClock.swift        孕周推算 + 时间格式化
    KickRecorder.swift          胎动：去重、会话续接、撤销、窗口提示
    ContractionRecorder.swift   宫缩：三态计时、间隔、规则引擎
    SummaryBuilder.swift        就诊摘要（只写事实）
  Intents/JiQianIntents.swift   App Intents + App Shortcuts 注册
  Views/                        首页 / 胎动 / 宫缩 / 摘要 / 动作 / 设置
.github/workflows/build-ipa.yml 云端编译流水线
```

---

## 关键设计取舍

- **原始事件与结论分离**：每条记录只存时间、来源、时区；「是否需要联系」在读取时按当前规则重算，历史记录不会被未来的规则改写。
- **不静默丢数据**：宫缩的开始与结束都是立即落库。App 被杀、来电打断、锁屏，重开仍能恢复。
- **1.2 秒去重**：同来源、同 1.2 秒内的重复点按视为误触，不重复计数。
- **本地优先**：无账号、无后端、不上传。所有数据在设备内的 SwiftData 里。
- **文案红线**：所有 Siri 返回只讲「已记录 / 已保存 / 请确认」，绝不输出「正常 / 异常 / 该不该去医院」。

宫缩提示口径（与网页版一致）：近 1 小时有效收缩 ≥ 6 次、平均持续 ≥ 45 秒、平均间隔 ≤ 10 分钟。存在高风险因素（未足月、多胎、既往早产/急产、计划剖宫产等）时，未达阈值也会更早提示。

---

## 已知限制

- 没有 Live Activity 扩展：灵动岛/锁屏实时计时需要额外的 Widget Extension target，会显著增加自签名复杂度（多一个 bundle id 与 profile）。留在 v1.1。
- 没有 CloudKit 同步：单机存储，换机需重装。
- 没有 HealthKit 写入。
- 免费 Apple ID 签名 7 天过期，需用工具续签；付费开发者证书则为 1 年。

---

## 与网页版的关系

同一套产品逻辑另有一份 PWA 版本（`jiqian/`），用于没有 Apple 开发者环境时快速试用。原生版的规则引擎、文案、数据模型与它一一对应，可以互相校对。

---

规则阈值仅用于教育提示与联系触发，不替代医生评估。实际随访、早产风险与入院方案，以你建档产科机构的具体指示为准。
