# Coremail Controller：Windows 三步开始

> **适用于 0.7.1。** 只使用成功的 Windows PowerShell 5.1 自动生命周期门禁所上传的
> `coremail-controller-windows-gated` 产物，并核对随包 SHA-256。0.7.0 及更早构建已被
> 0.7.1 取代；0.6.0 及更早构建已撤回。

本插件先尝试复用已登录 Coremail 的 Windows Simple MAPI 共享会话；接口不可用时再
安全配置 IMAP/SMTP。两种模式都不启动或操作 Coremail 桌面、网页界面。

## 1. 完整解压

把发布 ZIP 完整解压到本机普通目录。不要直接在压缩包预览窗口中运行文件。

如果发布包旁有 `.sha256` 文件，可在 PowerShell 中核对：

```powershell
Get-FileHash .\coremail-controller-0.7.1-windows.zip -Algorithm SHA256
Get-Content .\coremail-controller-0.7.1-windows.zip.sha256
```

两处哈希不一致时停止，不要安装。

## 2. 双击安装

进入解压出的目录，双击 `INSTALL.cmd`。向导会自动：

1. 核对包内完整性和 Windows 门禁元数据，固定 Python 3.10+；
2. 用真实 Claude Code 严格验证插件；2.1.84–2.1.156 会在验证前被明确识别为不支持，需先升级到 2.1.157+；
3. 显式启用并核对 `coremail-controller@skills-dir` 的版本和实际路径；
4. 首先检查 Coremail 是否注册了可复用的已登录共享 MAPI 会话；
5. 探测成功时免密码配置；失败时才询问邮箱、IMAP/SMTP 主机和域/Coremail 密码，
   并把密码写入 Windows 凭据管理器；
6. 执行 MCP 离线冒烟测试，并尝试检查真实邮箱连接。

安装和账号配置正常都在当前用户范围内。只有检测到已撤回旧版遗留的固定插件目录仅
允许 `SYSTEM/Administrators` 访问时，才会出现一次 UAC：受限地给当前用户 SID 增加
`Modify` 后继续，不删除旧目录或邮件配置。升级时默认保留现有账号配置。
当前版本只管理默认的 `%USERPROFILE%\.claude`；若进程设置了其他
`CLAUDE_CONFIG_DIR`，安装或卸载会在改动前明确停止。
失败或成功后都可在 `%TEMP%\CoremailController` 找到不含密码的诊断日志。

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
