# 命名空间改为 com.passwordpie — 需求 v2

v1 全部保留，追加（用户 2026-11-13：商店标题要有 password manager，扩展页面为搜索排名出力），同一个 PR、同一个 0.5.0：

1. Chrome 构建 manifest `name` = `PasswordPie: Password Manager for Mac`（≤75），加 `short_name: 'PasswordPie'`；`action.default_title`、右键菜单文案不变。
2. Chrome 构建 `description`（商店 summary，≤132）= `Autofill passwords from PasswordPie, the KeePass password manager for Mac. Needs the PasswordPie app.` 如实、不堆关键词。
3. Safari 构建 name 保持 `PasswordPie`。已查：App 和扩展里都没有按扩展 name 匹配的逻辑（#49 的 profile 判断走连接上报的焦点，不看 name）。
4. LISTING.md 的 name/summary 一行同步；Description 第一段自然带一次 "password manager for Mac"。
5. 测试：Chrome name 含 "Password Manager" 且 ≤75，summary ≤132，Safari name 为 PasswordPie。

另记（v1 补充）：开着 Chrome 密码同步的用户，升级后 macOS 会再问一次 Chrome Safe Storage（钥匙串项的 ACL 认旧签名）；这是 Chrome 功能本身的一次授权，选「始终允许」后不再问。文档已写明。
