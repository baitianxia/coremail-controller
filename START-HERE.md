# Coremail Controller：Windows 三步开始

> **适用于 0.9.0。** 只使用 Windows PowerShell 5.1 生命周期门禁成功上传的
> `coremail-controller-windows-gated` ZIP，并核对随包 SHA-256。

## 1. 完整解压并核对

把正式 ZIP 完整解压到本机普通目录，不要在压缩包预览窗口中运行：

```powershell
Get-FileHash .\coremail-controller-0.9.0-windows.zip -Algorithm SHA256
Get-Content .\coremail-controller-0.9.0-windows.zip.sha256
```

## 2. 双击安装

进入解压目录，双击 `INSTALL.cmd`。安装器会自动：

1. 校验门禁包和固定 Python；
2. 探测现有 Claude Code 的 user-scope MCP 能力；
3. 把不可变运行时发布到
   `%LOCALAPPDATA%\CoremailController\releases\...`；
4. 执行真实的 `mcp remove → add → get` 注册；
5. 先尝试复用已登录 Coremail 的无界面共享 MAPI 会话；
6. 只有接口不可用时才询问邮箱、IMAP/SMTP 主机和密码。

安装器不会访问、搬移或修复 Claude Skill 目录，不请求 UAC，也不要求人工 ACL 操作。即使
旧目录被锁定，升级仍会发布新的版本目录。卸载时版本目录保留，避免打开的进程造成权限
问题。

## 3. 用文字操作邮件

重启 Claude Code，然后直接输入：

```text
检查 Coremail 连接，并搜索本周来自 alice@example.com 的未读邮件。
```

也可以说“起草邮件但不要发送”。发送前 Claude 必须展示冻结的收件人、主题和附件清单；
只有你明确回复 `确认发送` 才会提交。

重新配置账号：双击 `CONFIGURE-ACCOUNT.cmd`。移除用户级 MCP：双击 `UNINSTALL.cmd`。两者
都不会删除邮箱配置、凭据或版本运行时。
