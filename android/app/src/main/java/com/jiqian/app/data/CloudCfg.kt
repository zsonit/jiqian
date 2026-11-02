package com.jiqian.app

// 云服务配置（配对同步）。
// 复用萌宝成长已经在线的同款 WorkBuddy 托管后端，与其共用 mengbao_sync 一张按配对码索引的表：
// 胎动的 payload 是端到端加密信封，云端只存密文；两端 App 建码时查同一张表做查重，天然避免撞码。
// 若以后给胎动开通独立云环境，只需改这三行。
object CloudCfg {
    const val ENDPOINT = "https://mengbao-sync.app.workbuddy.host"
    const val PUBLISHABLE_KEY = "wbpk_z3Qd2DmHRK20lYTyzpjsTH_DG9v1WdRyKgkBsMLewH3mh5Br7EOcUlR"
    const val DB_REST = "$ENDPOINT/.cloud/database/rest/v1/mengbao_sync"
}
