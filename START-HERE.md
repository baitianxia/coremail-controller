# Coremail Controller：Windows 三步开始

> **暂勿安装：0.5.x 已撤回。** 现有 ZIP 尚未通过完整的 Windows PowerShell 5.1
> 自动生命周期门禁。请等待标记为 `coremail-controller-windows-gated` 的后续发布包；
> 不需要继续替维护者手工试错。

本插件先尝试复用已登录 Coremail 的 Windows Simple MAPI 共享会话；接口不可用时再
安全配置 IMAP/SMTP。两种模式都不启动或操作 Coremail 桌面、网页界面。

## 1. 完整解压

把发布 ZIP 完整解压到本机普通目录。不要直接在压缩包预览窗口中运行文件。

如果发布包旁有 `.sha256` 文件，可在 PowerShell 中核对：

```powershell
Get-FileHash .\coremail-controller-0.5.3-windows.zip -Algorithm SHA256
Get-Content .\coremail-controller-0.5.3-windows.zip.sha256
```

两处哈希不一致时停止，不要安装。

## 2. 双击安装

进入解压出的目录，双击 `INSTALL.cmd`。向导会自动：

1. 检查 Windows、Python 3.10+、Claude Code 和包结构；
2. 备份已识别的旧插件并安装新版本；
3. 首先检查 Coremail 是否注册了可复用的已登录共享 MAPI 会话；
4. 探测成功时免密码配置；失败时才询问邮箱、IMAP/SMTP 主机和域/Coremail 密码，
   并把密码写入 Windows 凭据管理器；
5. 执行 MCP 离线冒烟测试，并尝试检查真实邮箱连接。

安装和账号配置都在当前用户范围内，不要求管理员权限。升级时默认保留现有账号配置。

若企业 PowerShell 策略拦截脚本，请让管理员批准或签名，不要临时绕过组织策略。

## 3. 在 Claude Code 使用

重启 Claude Code，或执行 `/reload-plugins`，然后输入：

```text
/coremail-controller:coremail
```

需要把现有浏览器 MCP 的公共网页研究结果整理成邮件时使用：

```text
/coremail-controller:web-to-coremail
```

重新配置账号可双击 `CONFIGURE-ACCOUNT.cmd`；停用插件可双击 `UNINSTALL.cmd`。
卸载采用移动而非删除，不会删除账号配置和 Windows 凭据。
