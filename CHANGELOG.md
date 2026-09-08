# 变更记录

## 0.9.0 — 2026-09-07

- 将用户可见身份统一为 `mail-mcp-server`、邮件助手和 `mail-mcp`；Coremail 仅保留为
  provider/适配器实现名称。
- 采用本工程独立的 `%USERPROFILE%\mail-mcp-server\` 状态根和
  `config\settings.json`，不创建共享工具目录，也不迁移历史名称或旧 MCP 别名。
- 新增 `mail_config_status`、`mail_configure`、`mail_config_reload`，配置状态包含绝对路径、
  schema、缺失字段和下一步命令，密码不会进入 MCP 参数或日志。
- 顶层统一提供 `INSTALL.cmd`、`CONFIGURE.cmd`、`OPEN-CONFIG.cmd`、`UNINSTALL.cmd` 和
  `START-HERE.html`；同一安装入口支持首次安装和升级，外置配置保持不变。
- 发布构建改为单一 `mail-mcp-server-<version>-windows-x64.zip`，包含 bundled runtime、
  `release-manifest.json`、`SHA256SUMS.txt` 和包外归档校验文件；本地候选明确标记
  `UNVERIFIED`。
- Windows gate 单独保存构建摘要、清单、运行时许可证、SBOM 和 native/npm 标准用户生命周期
  日志，失败时也保留已生成的诊断证据。
- 保留无界面 Simple MAPI/IMAP/SMTP、准备—复核—`确认发送` 事务、TLS 校验、脱敏本地发现和
  浏览器单向事实桥接能力。
- 准备令牌绑定复核时的非秘密配置指纹；传输、账户、端点或发送策略改变后必须重新准备，避免
  按新的投递目标发送旧复核内容。

## 0.8.x 及更早版本（历史设计）

早期版本逐步加入了用户级 MCP 注册、不可变版本目录、配置事务、Windows Credential
Manager、Simple MAPI provider、附件哈希和 PowerShell 5.1 兼容性修复。这些历史实现不定义
当前用户身份、路径或迁移行为；从 0.9.0 开始以本文件和 `docs/architecture.md` 为准。
