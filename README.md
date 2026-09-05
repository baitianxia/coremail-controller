# Claude Code Coremail 接口优先连接器

> **当前发布线：0.9.0。** 只安装 Windows PowerShell 5.1 生命周期门禁成功上传、且
> ZIP 与相邻 `.sha256` 文件匹配的 `coremail-controller-windows-gated` 产物。
> 私有仓库的 `gated-release/releases/0.9.0/` 保存同一对已复核文件。

这是一个供 Windows 上 Claude Code 使用的本地用户级 MCP 包。MCP 是运行时；安装器不把
包复制到 Claude 的 Skill 目录，也不依赖 Skill 发现。用户只需用文字描述邮件任务，Claude
Code 会根据 MCP 的工具描述和初始化说明调用服务。

安装器从已登录的 Coremail 客户端尝试复用 Windows Simple MAPI 共享会话；只有该无界面
接口不可用时，才进入 IMAP/SMTP 配置并在安全密码提示中要求凭据。它不会启动、显示或
操作 Coremail 界面，不读取或解密客户端保存的密码。

## 能力范围

- 查看传输和连接状态，发现本地配置候选；
- 列出文件夹、搜索和读取邮件；IMAP 读取使用 `BODY.PEEK[]` 保持未读；
- 按明确要求标记已读/未读；
- 先冻结并复核邮件，再保存草稿或发送；
- 发送必须在准备摘要后收到精确短语 `确认发送`；
- 可将独立浏览器 MCP 的有界公共网页事实整理为 Coremail 草稿，但不会安装或合并浏览器
  MCP。

删除、撤回、日历/联系人、共享邮箱管理、Coremail 私有协议和桌面 UI 自动化不在范围内。

## 运行时位置（重要）

所有可执行文件和版本目录都在当前用户的 LocalAppData：

```text
%LOCALAPPDATA%\CoremailController\
  .lifecycle.lock
  staging\<unique-staging>\
  releases\coremail-controller-<version>-<source>-<python>\
```

版本目录先完整校验，再用同卷原子移动发布；已发布目录永不原地修改或覆盖。升级时即使
旧目录被 Claude、Explorer、Defender 或索引器锁定，也不会检查、搬移或修复它，安装仍可
发布新的不可变目录。安装器不请求 UAC，不显示人工 ACL 指令，也不要求重新打包。

卸载只事务性地删除 Claude user-scope MCP 注册；为避免正在运行的 Python/PowerShell 句柄
造成权限问题，版本目录保留不删，邮箱配置和 Windows 凭据也保留。

包内的 `SKILL.md`/`skills/` 仅是可选的阅读材料，不会被安装到用户 Skill 目录；删掉这些
材料不会影响 MCP 的工具调用。

## 环境要求

- Windows 10/11；
- 已安装且当前用户可运行的 Claude Code，提供 `mcp add`、`mcp remove`、`mcp get`；
  支持原生 `claude.exe` 和标准 npm `claude.cmd`，不设固定版本下限；
- Python 3.10+。安装器固定实际解释器及 SHA-256，运行时不随 `PATH` 漂移；
- 接口模式要求 Coremail 为默认 Windows 邮件客户端且已有共享登录会话；
- 协议模式要求管理员允许 IMAP/SMTP、准确的服务器主机名和组织认可的域密码或客户端
  专用密码。

## 安装

完整解压正式 ZIP 后，双击：

```text
INSTALL.cmd
```

安装器会自动完成：包清单和 Windows 门禁元数据校验、Python 固定、Claude `mcp` 能力探测、
用户级 `remove → add → get` 注册、MCP 冒烟测试和账号配置。它只写：

- `%LOCALAPPDATA%\CoremailController`；
- Claude 的 user-scope 配置 `%USERPROFILE%\.claude.json`（或绝对本机路径
  `CLAUDE_CONFIG_DIR` 下的 `.claude.json`）；
- `%APPDATA%\ClaudeCode\Coremail\config.json` 和按需的 Windows Credential Manager
  凭据。

旧的 Claude Skill 目录不在上述写入范围内，任何锁定或无权限状态都不会阻塞安装。
安装/升级/卸载日志位于 `%TEMP%\CoremailController`，不含密码。

命令行等价形式：

```powershell
powershell.exe -NoProfile -File .\scripts\install.ps1
```

本地构建的 ZIP 会标成 `UNVERIFIED`，正式安装器会拒绝。不要在压缩包预览窗口中运行。

## 账号配置和已登录态复用

首次安装默认使用 `auto`：先检测 Coremail 的默认客户端注册，再调用
`MAPILogon(profile=NULL, password=NULL, flags=0)` 语义的无 UI 探测。共享会话可用时不
要求密码；不可用时才询问完整邮箱、IMAP/SMTP 主机和密码。密码只写入 Windows Credential
Manager，不进入 Claude 对话、命令行或 JSON。

以后更换设置时双击 `CONFIGURE-ACCOUNT.cmd`，或运行：

```powershell
powershell.exe -NoProfile -File .\scripts\configure-account.ps1
```

配置完成后重启 Claude Code（不需要安装或发现 Skill），然后可运行：

```text
claude mcp get coremail-controller
claude mcp list
```

## 使用示例

可以直接对 Claude Code 说：

- “检查 Coremail 连接，并搜索本周来自 alice@example.com 的未读邮件。”
- “读取刚才的 UID 123，保持未读。”
- “给 bob@example.com 起草项目进度邮件，不要发送。”
- “展示完整收件人、主题和附件清单；我确认后再发送。”

发送永远分两步：准备工具返回冻结摘要，用户明确回复 `确认发送` 后才提交。令牌 15 分钟
失效，提交失败不会自动重试。

## 与浏览器 MCP 协同

浏览器 MCP 由用户独立安装和配置。让 Claude 先研究公共网页，再把有来源的有限事实整理
为 Coremail 草稿；网页内容不可信，不能指定收件人、授权附件或替代发送确认。需要严格隔离
时，使用两个互斥工具集的 Claude 会话。详细规则见
[docs/browser-orchestration.md](docs/browser-orchestration.md)。

## 验证

```powershell
python -m unittest discover -s tests -v
powershell.exe -NoProfile -File .\tests\smoke-mcp.ps1
powershell.exe -NoProfile -File .\tests\smoke-mcp.ps1 -CheckConnection -TimeoutMilliseconds 60000
```

只有 `.github/workflows/windows-release-gate.yml` 在干净 `windows-2022` 上测试过的 ZIP 才能
进入 `gated-release`。门禁覆盖 Windows PowerShell 5.1、原生/npm Claude、不可变运行时、
被锁定的旧 Skill 目录不影响安装、注册回滚、账号回滚和卸载保留策略。

## 卸载

在解压目录双击 `UNINSTALL.cmd`，或运行：

```powershell
powershell.exe -NoProfile -File .\scripts\uninstall.ps1
```

卸载先移除 Claude user-scope MCP，然后保留 `%LOCALAPPDATA%\CoremailController\releases`、
账号配置和 Windows 凭据。没有删除操作，不会触碰任何 Skill 目录；如需清理凭据，请在确认
目标名后通过 Windows“凭据管理器”手动完成。

实现和安全边界以 [docs/architecture.md](docs/architecture.md) 为准。
