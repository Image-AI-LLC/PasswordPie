# 两步验证码扫二维码 — 需求 v1

用户已于 2026-11-11 确认方案，本文件只做记录，不再等待确认。

## 背景

网站开通两步验证时给的是二维码，PasswordPie 现在只能在编辑窗口粘贴 Base32 或 `otpauth://` 文本。

## 要做

1. **解析加固（Core）**
   - `otpauth://` 里重复参数不再让 App 崩溃，取第一个值。
   - 只接受 `totp`；`hotp` 不再被当成 TOTP。
   - 新的扫码解析入口：给出 issuer、账号、设置、规范化 URI，或者明确的错误（不是 otpauth、HOTP、Google Authenticator 导出、坏 Base32、digits 不在 6–8、period ≤ 0、未知算法）。每种错误一句英文说明。未知算法拒绝，不回落 SHA1。
   - 候选条目排序：同站点优先，同站点里用户名等于账号的最前。
2. **编辑窗口**
   - 「One-time password」行加扫码按钮：读剪贴板（图片解码 / otpauth 文本）、Choose Image…、拖图片或图片文件到这一行、在文本框里粘贴图片。
   - 解码用系统 Vision，只认 QR，全部本机完成。失败时行下方显示错误说明。
   - 有合法的码后显示当前验证码预览，走 `OneTimeCodes.access`；没有 Premium 显示锁定行。
   - 不加 entitlement、不录屏、不用摄像头、不加网络代码。App Store 沙盒版可用。
3. **浏览器扩展：扫描本页二维码**
   - 弹窗按钮「Scan QR code on this page」，只能用户点击触发。
   - 先找视口内的 `<img>`、`<canvas>`、`<svg>`，找不到再截当前标签页。不加权限。
   - 解码器打包进扩展，不加载远程代码；图片和密钥只在内存，不写 storage、不打日志、不联网。
4. **Bridge 与 App 确认**
   - 新请求把 otpauth URI 和页面 origin 交给 App；回包只说「收到了」，不透露库里有没有匹配条目。
   - App 显示确认：issuer、账号、预选候选、同站点其他候选、搜索别的条目、新建条目；Add / Cancel。不经确认绝不写库。
   - 锁着先解锁。待确认扫描只在内存，2 分钟过期；新的替换旧的。
   - 目标已有码要问「Replace the existing code?」；旧密钥可从 KDBX 条目历史找回。
   - Add 后保存，显示当前验证码可复制；扩展可按 pending code 机制填码（仍受 `browserCodeAllowed` 约束）。没有 Premium 显示锁定行。
   - 扫码和保存密钥免费，只有生成验证码是 Premium。
5. **文档和测试**：TDD；更新 `docs/UX.md`、`docs/BROWSER_EXTENSION.md`、`README.md`、`DESIGN.md`。

## 不做

屏幕录制、摄像头、`otpauth-migration` 导入、HOTP、Steam 码、给 `otp` 字段单独加密。

## 验收

- `swift test`、扩展 `pnpm test` 全绿，两个渠道都能构建。
- 实际跑：编辑窗口从剪贴板截图扫进一个码；Chrome 测试页上扫描、App 确认、看到验证码。各一张截图放进 PR。
