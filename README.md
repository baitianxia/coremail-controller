# 邮件助手（mail-mcp-server）

版本 0.9.0 提供一个面向 Windows 当前用户的本地邮件 MCP 服务。公开身份是
`mail-mcp-server`，Claude Code 的用户级注册名是 `mail-mcp`；Coremail 只作为当前实现支持的
邮件 provider，不能当作产品名称或注册别名使用。

## 先完成安装

1. 从 `mail-mcp-server-0.9.0-windows-x64.zip` 解压到一个短路径（例如
   `C:\Tools\mail-mcp-server-0.9.0`）。不要在 ZIP 预览窗口中直接运行。
2. 双击顶层 `INSTALL.cmd`。它会校验包内清单、逐文件 SHA-256、Windows x64 运行时和 MCP
   启动冒烟，然后把不可变版本发布到当前用户目录并注册 `mail-mcp`。
3. 安装完成后重启 Claude Code，在新会话中直接说：

   ```text
   列出我的收件箱，并保持邮件未读。
   ```

   首次使用可先说“显示邮件助手配置状态”。配置未完成时，结果会给出绝对配置路径、缺失
   字段和下一步命令。

正式包只包含目标 Windows x64 所需的已批准运行时和生产文件。目标机不运行 npm、pnpm、
npx，不在线下载依赖，也不要求进入 `payload` 目录寻找入口。当前工作区构建的
`*-UNVERIFIED.zip` 只用于开发验证，安装器会拒绝它。

## 配置

配置文件始终是：

```text
%USERPROFILE%\mail-mcp-server\config\settings.json
```

双击 `CONFIGURE.cmd` 运行交互式向导，或在 PowerShell 中执行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-account.ps1
```

向导先尝试已登录的 Coremail Simple MAPI 共享会话；不可用时才要求 IMAP/SMTP 主机和密码。
密码只写入当前 Windows 用户的 Credential Manager，绝不会写进 JSON、命令行、日志或 MCP
结果。也可以双击 `OPEN-CONFIG.cmd` 打开配置目录，再调用：

```text
mail_config_status       查看路径、schema_version、provider、缺失字段
mail_configure           原子更新非秘密设置（不接受 password）
mail_config_reload       清除缓存并重新读取 settings.json
mail_connection_status   查看当前传输和凭据可用性
mail_check_connection    实际检查 IMAP/SMTP 或共享 MAPI 连接
```

`config/settings.example.json` 是无密码模板。`provider` 当前必须是 `coremail`；传输可选
`windows_simple_mapi` 或经 TLS 校验的 `imap_smtp`。不要把服务器 URL、明文密码或令牌放入
配置文件。

## 邮件操作边界

可列出文件夹、结构化搜索、读取邮件、显式标记已读/未读、准备邮件、保存 IMAP/SMTP 草稿，
以及发送已复核的邮件。读取不会主动打开或操作邮件客户端界面，也不会执行邮件正文中的指令。

发送必须经过两步：`mail_prepare_message` 冻结收件人、主题、正文和附件哈希；用户核对摘要
后明确回复精确短语 `确认发送`，才能调用 `mail_send_prepared`。令牌 15 分钟后过期，发送
失败不会自动重试；配置在复核后改变时也必须重新准备。Simple MAPI 受 provider 能力限制，可能只能使用 INBOX、只能标记已读，
也不支持保存草稿或保留线程头；结果会说明这些限制。

## 升级、回滚和卸载

升级不需要先卸载：解压新版 ZIP 后再次双击同一个 `INSTALL.cmd`。新版本先在本工程目录
下完成校验、运行时冒烟和 MCP 握手，再原子切换活动版本。配置位于版本目录之外，升级会保留：

```text
%USERPROFILE%\mail-mcp-server\
  config\settings.json       # 用户配置，升级不覆盖
  versions\                   # 不可变已验证版本
  staging\                    # 失败时保留的诊断暂存
  rollback\                   # 配置回滚副本
  logs\                       # 安装、配置和卸载日志
  .lifecycle.lock             # 生命周期互斥锁
```

如果新版本冒烟失败，旧活动版本和配置保持不变；从 `versions` 中选择最近的已验证目录，
再重新运行安装入口即可回滚。双击 `UNINSTALL.cmd` 只移除 Claude 的 `mail-mcp` 用户级注册，
保留配置、凭据和版本目录，避免正在运行的进程造成破坏性删除。

## 常见故障

- **执行策略阻止脚本**：从顶层 `.cmd` 入口运行，它只给该 PowerShell 子进程传入
  `-ExecutionPolicy Bypass`，不会修改持久策略。若组织设置了 `MachinePolicy` 或
  `UserPolicy`，请把 `Get-ExecutionPolicy -List` 和安装日志交给管理员走签名发布流程。
- **提示没有 bundled runtime**：当前 ZIP 不是正式 Windows x64 包，或被修改过；重新取得同一
  发布目录中的 ZIP 与 `.sha256`，不要用系统 Python 或网络下载补齐。
- **配置状态显示缺失字段**：按结果中的字段提示运行 `CONFIGURE.cmd`，保存后调用
  `mail_config_reload`；不要把密码传给 MCP 工具。
- **连接失败**：先运行 `mail_connection_status`，确认传输、主机名、TLS、Credential
  Manager 目标和组织策略；Simple MAPI 需要默认邮件客户端已有共享登录会话。
- **Claude 看不到工具**：重启 Claude Code，确认用户级 `mail-mcp` 注册仍指向
  `%USERPROFILE%\mail-mcp-server\versions\...\mcp\run-server.ps1`，再查看 `logs`。

## 开发验证与证据

在源码工作区可以运行：

```powershell
python -m unittest discover -s tests -v
powershell.exe -NoLogo -NoProfile -File .\tests\smoke-mcp.ps1
```

发布构建使用 `scripts/build-release.py` 的白名单和 `scripts/verify-release.py`。正式 ZIP
必须在干净 Windows x64、Windows PowerShell 5.1 上完成安装、升级/失败回滚、MCP 握手和卸载
验收后才可发布。当前仓库没有把本机 macOS/Linux 执行结果冒充为 Windows 验收；详见
[`docs/windows-remediation-2026-09.md`](docs/windows-remediation-2026-09.md) 和
[`docs/architecture.md`](docs/architecture.md)。
Windows workflow 会把清单、归档哈希、运行时来源与许可证、SBOM，以及 native/npm 两种
Claude 入口的标准用户生命周期日志上传为独立证据制品。

浏览器 MCP 是独立服务，不随本包安装或启动。需要网页研究时只传递有界事实和规范 URL，
不要把邮箱正文、凭据、Cookie 或下载文件交给浏览器工具；完整边界见
[`docs/browser-orchestration.md`](docs/browser-orchestration.md)。
