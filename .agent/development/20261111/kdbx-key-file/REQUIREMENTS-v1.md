# KDBX key file — 需求 v1

日期：2026-11-11。需求和方向用户已确认（任务书），本文只做记录，写完直接编码。

## 为什么

库文件被盗（如网盘泄露）且主密码被破解时，密码和两步验证密钥会一起丢。方案：给整个库加第二把钥匙——key file
留在本机、不跟库一起同步，作用等同 1Password 的 Secret Key。不给 `otp` 字段单独加密。

## 范围

1. **Core**
   - KDBX composite key = SHA256(SHA256(密码) ‖ keyFileKey)；只有 key file、没有密码时只含 key file 一项（同 KeePassXC）。
   - 认得五种 key file：XML v1（Base64）、XML v2（十六进制 + Hash 校验）、32 字节二进制、64 个十六进制字符、其他文件取 SHA-256。
   - 打开、保存、修复（KDBXRecovery 重写）、后台重读、导入后写出的 `.kdbx`，凡是算 composite 的地方都带 key file。
   - 保存绝不写出打不开的文件：写出后用同一组钥匙读回验证再替换。改钥匙（加/换/去 key file、改主密码）先用新钥匙读回验证再替换；失败原文件不变。
   - 与 KeePassXC 互操作：它建的库我们能开，我们写的库它能开。
2. **App**
   - 锁屏 `.kdbx` 也显示 key file 一行。
   - 第一次用 key file 解锁成功后记进本机钥匙串（按数据库区分，`.kdb` 同样），之后只需主密码或 Touch ID；可见的 Forget Key File。沙盒版可用，不依赖原文件路径。
   - Preferences（当前已解锁的库）：Add Key File…（生成 XML v2，`SecRandomCopyBytes` 32 字节，`NSSavePanel` 选位置，读回校验后重新加密）、Use Existing Key File…、Remove Key File；操作前英文警告：丢了文件就打不开、PasswordPie 无法找回、备份别和库放在同一文件夹/网盘。
   - 新建数据库可选带 key file。
   - 改主密码保留 key file。
   - 用已存钥匙开库的地方（Touch ID、并列打开的其他库、后台重读）带 key file 照常工作。AutoFill 扩展目前不开库（只做 Credential Exchange 入口），无需改动。
3. **新建库 Argon2 默认** 32 MiB → 64 MiB（3 passes / 2 lanes 不变），只影响新建库。M2 实测解锁耗时写进 PR；明显超过 0.5 s 则保持 32 MiB。
4. **文档和测试**：TDD；更新 `docs/UX.md`、`DESIGN.md`、`docs/CHANNELS.md`、`README.md`。界面文案和文档用英文。

## 不做

YubiKey / challenge-response；`otp` 单独加密；自动给已有库加 key file 或改 KDF。尽量不碰 `TOTP.swift`、`Pages.swift`、`BrowserFill.swift`、`extension/`（并行的 `otp-qr-scan` 在改）。

## 验收

- `swift test` 全绿，两个渠道都能构建。
- 真机：测试库 Add Key File → 锁定 → 只用密码解锁（key file 来自钥匙串）→ Forget Key File 后只用密码打不开 → 重新选 key file 能打开。锁屏、Preferences 各一张截图进 PR。
- KeePassXC 互操作命令和输出写进 PR；KeePassXC 生成的小样本库和 key file 作为 fixture 提交。
