# 命名空间改为 com.passwordpie — 需求 v1

来源：用户 2026-11-13 决定（原话「com.passwordpie」）。发行方 Image AI, LLC（Team 2S468LUF8V），passwordpie.com 是自有域名。需求已确认，本文只留档。

## 要做

1. 所有标识从 `com.oldcai.passwordpie` 改成 `com.passwordpie`，子标识随之改：
   `.safari` `.autofill` `.browser-host` `.account(.dev)` `.keyfile` `.premium.yearly` `.premium.lifetime` `.activate`；
   App Group → `2S468LUF8V.com.passwordpie`。
2. 源码里 `com.oldcai` 只留在「兼容」需要的地方，有测试守住，每处写明为什么留。
3. 兼容：
   - App 同时装新旧两个名字的 Chrome native messaging host 清单（同一个 host、同样 allowed_origins）；旧名是过渡，商店线上扩展版本 ≥ 0.5.0 后可删。
   - 本 PR 的扩展连新名字，版本 0.5.0（manifest.ts、package.json、protocol.ts 一致）。
   - 直装版 v0.1.0 升级：首次启动从旧 domain 迁一次设置；钥匙串旧条目（Touch ID 密码、key file、activation）能无弹窗读到就迁，读不到就让用户重输主密码、重开 Touch ID；不崩、不反复弹钥匙串授权框；辅助功能授权要重给，文案说得通。迁移有测试。
   - 开发机旧构建残留（旧钥匙串条目、旧 App Group 里的 socket）不清理，不影响新构建。
4. 商店文案：nativeMessaging 说明里 host 名改新；Host permissions 换成后台实际提交的 996 字符版；测试守住每条 justification ≤1000、Description ≤16000。

## 不做

- 不上传商店、不发 DMG/release、不动 App Store Connect、不动网站仓库。
- 网站提到 com.oldcai、ASC 是否已用旧 ID 建记录 → PR 正文列为后续/人工核对项。

## 用户看得到的变化（升级自 v0.1.0）

- 数据库列表、快捷键等设置照旧。
- Touch ID：下次用主密码解锁一次，之后照常 Touch ID。
- 辅助功能：系统会再问一次；系统设置里可能出现两个 PasswordPie，打开新的、旧的可删。
- Safari 扩展：要在 Safari 设置里重新勾选一次。
- Premium 激活：若读不到旧条目，再点一次激活链接。
