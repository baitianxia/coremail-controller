# Claude Code Coremail 接口优先连接器

> **当前发布线：0.7.0。** 只安装由成功的 Windows PowerShell 5.1 生命周期门禁上传、
> 且 ZIP 与相邻 `.sha256` 文件匹配的 `coremail-controller-windows-gated` 产物。
> 私有仓库的 `gated-release/releases/0.7.0/` 保存同一对已复核文件。0.6.0 及更早
> 构建已撤回，不得继续安装或测试。

这是一个供 Windows 上 Claude Code 使用的本地插件。它**不会启动、显示或操作
Coremail 客户端界面**。用户可直接用文字要求 Claude Code 搜索、读取、整理和准备
邮件。插件按以下顺序建立邮箱访问：

- 若 Windows 默认邮件客户端明确注册为 Coremail，先用系统 Simple MAPI 接口尝试
  连接**已经登录的共享会话**；调用不带用户名、密码和任何界面标志；
- 上述接口不存在或共享会话不可用时，再让用户输入邮箱地址、服务器信息和域/Coremail
  密码，通过 IMAP/SMTP 工作；密码进入 Windows 凭据管理器，不进入 Claude 对话；
- 对本地 Coremail 数据目录进行有界、只读的配置候选发现；
- 由 Claude Code 把现有浏览器 MCP 的公共网页研究结果，经受控单向边界整理成
  Coremail 草稿或待发送邮件。

Simple MAPI 是 Windows 文档化、但微软已不建议新系统依赖的兼容接口，不是对
Coremail 私有协议的猜测。插件不会读取或解密 Coremail 保存的密码，也不会通过 UI
Automation、截图、鼠标或键盘控制客户端。若 Coremail 未提供可复用的 MAPI 会话，
实时访问需要管理员启用 IMAP/SMTP。

## 能力范围

- 查看当前传输、连接状态和可用文件夹；
- 按发件人、收件人、主题、文本、日期和未读状态搜索；
- IMAP 用 `BODY.PEEK[]` 保持未读；Simple MAPI 请求 `MAPI_PEEK`，但提供程序可能忽略
  该标志并标记已读，工具结果会明确提示这一限制；
- 按明确要求标记状态：IMAP 可标记已读/未读，Simple MAPI 只能标记已读；
- 先冻结并复核邮件，再保存草稿或发送；
- 只返回传输可提供的收到附件元数据，不下载附件；发送附件受目录、大小和 SHA-256
  校验约束；
- 可调用独立的现有浏览器 MCP 完成网页研究，但不合并两个服务器。

Simple MAPI 仅暴露收件箱，搜索是最多 500 封的本地扫描，不支持标记未读、保存草稿、
Internet 回复线程头，也不会把收到的附件落盘。需要完整文件夹、草稿或回复线程时，应
重新配置为 IMAP/SMTP。当前也不支持删除、移动、撤回、联系人、日历、共享邮箱管理、
Coremail 私有协议或浏览器 MCP 的安装和实现。

## 工程目录

```text
coremail-controller/
├── INSTALL.cmd                 # Windows 双击安装
├── CONFIGURE-ACCOUNT.cmd       # 双击重新配置账号
├── UNINSTALL.cmd               # 双击可恢复式卸载
├── START-HERE.md               # 最短使用入口
├── .claude-plugin/             # Claude Code 插件清单
├── .mcp.json                   # 仅声明 Coremail MCP
├── skills/                     # Coremail 与网页转邮件工作流
├── mcp/                        # Windows MAPI 与 IMAP/SMTP 传输服务
├── scripts/                    # 安装、配置、卸载和发布脚本
├── tests/                      # 离线单测与 Windows 冒烟测试
├── docs/                       # 权威架构和隔离说明
└── dist/                       # 版本化 ZIP 与 SHA-256（构建生成）
```

## 环境要求

- Windows 10/11；
- Claude Code 2.1.157 或更高版本（支持 skills-directory 插件；原生 `claude.exe` 或标准 npm
  `claude.cmd` 安装均可）。npm 安装会按其官方包清单解析：新版包内原生 PE 直接执行，
  旧版 JS 入口使用该安装已有的 Node；不会通过 `cmd.exe` 拼接命令；
- 当前版本只管理默认的 `%USERPROFILE%\.claude` 用户配置目录；启动安装或卸载进程时，
  `CLAUDE_CONFIG_DIR` 必须未设置，或明确指向这个默认目录。其他配置根不会被猜测或改写；
- Python 3.10 或更高版本，安装时可由 `py.exe` 或 `python.exe` 找到；安装器会固定并
  校验实际 `python.exe`，以后不再随 `PATH` 漂移；
- 接口模式：Coremail 是 Windows 默认邮件客户端，并暴露与 Python 位数匹配的 Simple
  MAPI 提供程序，且当前已有共享登录会话；或
- 协议模式：邮箱账号、准确的 IMAP/SMTP 主机名、组织允许的域密码或客户端专用密码，
  并能从本机访问邮件服务器；
- 可选：已经单独配置好的浏览器 MCP；若不允许可见浏览器操作，应由该服务启用
  headless/无头模式。

Coremail 官方资料常见的加密端口是 IMAPS `993`、SMTPS `465`，但服务器主机名和
组织策略因部署而异，脚本不会根据邮箱域名猜测。请以网页邮箱“客户端设置”或管理员
提供的信息为准。

## 安装

Windows 上完整解压发布 ZIP，进入解压目录，双击：

```text
INSTALL.cmd
```

向导会先逐文件核对包内清单和 Windows 门禁元数据，固定 Python 运行时，并通过真实
Claude Code 执行严格插件验证；随后在当前用户的 `.claude` 目录暂存、验证 MCP、原子
替换插件，显式启用并再次从 `claude plugin list --json` 核对准确版本和路径。插件安装到：

```text
%USERPROFILE%\.claude\skills\coremail-controller
```

首次安装会先探测已有 Coremail 共享会话；探测成功则不询问密码，探测失败才进入
IMAP/SMTP 配置。升级默认保留已有账号配置及 Windows 凭据。
识别到旧插件时，安装器会把它移动到以下目录，而不是覆盖或删除：

```text
%USERPROFILE%\.claude\plugin-backups
```

备份刻意放在 `skills` 目录之外，避免 Claude Code 把旧版本再次加载为插件。正常流程
只在当前用户范围运行，不请求管理员权限，也不绕过机器的 PowerShell 执行策略。若
检测到已撤回旧版本留下的
`%USERPROFILE%\.claude\skills\coremail-controller` 只有 `SYSTEM/Administrators`
可访问，安装器会仅针对这个固定目录请求一次 UAC：调用 Windows 自带的
`icacls.exe` 给当前用户 SID 增加可继承的 `Modify`，保留原 ACL 和所有权，不递归、
不重置、不接管所有权、不删除内容；随后仍由普通用户进程复核路径、插件身份并完成
原子迁移。取消授权或复核失败不会移动、覆盖或删除目录内容；若系统授权已经成功，
新增的当前用户 ACE 会保留，原有 ACE 和所有权不变。企业策略禁止此兼容处理时，可用
`-NoLegacyPermissionRepair` 让流程直接安全停止。

安装、配置和卸载都会把不含密码的诊断日志写入 `%TEMP%\CoremailController`；窗口关闭
后仍可排错。

如果习惯命令行，可使用等价命令：

```powershell
powershell.exe -NoProfile -File .\scripts\install.ps1
```

更短的首次使用说明见 [START-HERE.md](START-HERE.md)。

## 配置账号与自动复用登录态

首次安装时无需单独操作。以后要更换服务器、账号或客户端专用密码，双击：

```text
CONFIGURE-ACCOUNT.cmd
```

也可从 PowerShell 运行：

```powershell
powershell.exe -NoProfile -File .\scripts\configure-account.ps1
```

默认的 `auto` 配置首先检查 Windows 当前用户/机器的默认邮件客户端注册，且只接受名称
明确匹配 Coremail/论客的提供程序；Outlook、Thunderbird 等不会被误用。随后调用
`MAPILogon(profile=NULL, password=NULL, flags=0)` 语义的无界面探测：只有现有共享
会话和 Unicode 发信入口都可用时，才选择 `windows_simple_mapi`。邮箱身份优先使用
Windows 域 UPN，不能得到
完整邮箱时才询问这一项。

如果探测失败，脚本选择 `imap_smtp`，询问完整邮箱地址、IMAP/SMTP 主机和组织允许的
域/Coremail 密码或客户端专用密码。密码只写入 Windows 凭据管理器；非敏感设置写入：

```text
%APPDATA%\ClaudeCode\Coremail\config.json
```

不要把密码粘贴到 Claude 对话、命令参数或 JSON 配置中。当前环境如果就是用 Windows
域用户名和密码登录 Coremail，可在安全密码提示框中输入该密码；若组织启用了双重认证
或协议策略，则按管理员要求使用客户端专用密码。

重新配置采用可恢复事务：先在同目录生成并验证新 JSON，再备份旧 JSON，然后写入一个
新的凭据目标，最后原子发布配置。发布前失败会删除新凭据并保持旧配置不变；脚本不会
覆盖或删除旧配置仍可能引用的密码。

也可显式选择模式：

```powershell
# 只接受已登录的 Coremail MAPI 会话；不可用时直接报错
powershell.exe -NoProfile -File .\scripts\setup-account.ps1 -Transport windows_simple_mapi

# 跳过客户端接口探测，直接配置协议和凭据
powershell.exe -NoProfile -File .\scripts\setup-account.ps1 -Transport imap_smtp
```

配置完成后重启 Claude Code，或在会话内执行 `/reload-plugins`。可用以下方式核验：

```text
claude plugin list
/coremail-controller:coremail
/coremail-controller:web-to-coremail
```

然后让 Claude “检查 Coremail 连接”。MCP 工具名均以 `coremail_` 开头。

## 使用示例

可以直接对 Claude Code 说：

- “只读发现这台电脑上的 Coremail 配置候选，不要操作客户端界面。”
- “检查当前是否正在复用已登录的 Coremail 会话。”
- “搜索收件箱中本周来自 alice@example.com 的未读邮件并摘要。”
- “读取搜索结果 UID 123，但保持未读。”
- “给 bob@example.com 起草一封主题为项目进度的纯文本邮件，不要发送。”
- “把刚才的邮件准备好并显示完整收件人、主题和附件清单。”

发送必须分两步：先调用准备工具并展示冻结后的摘要；只有用户明确回复
`确认发送` 后，Claude 才能提交。发送令牌 15 分钟失效，发送尝试开始时即被消费，
且失败后不会自动重试。

IMAP/SMTP 模式下默认 `sent_copy_mode` 为 `none`，因为部分 Coremail 部署会自动把 SMTP 邮件保存到
“已发送”；盲目追加可能产生重复副本。只有确认服务器不会自动保存时，才把它配置为
`append` 并指定或确认 Sent 文件夹。

## 与现有浏览器 MCP 协同

插件不会安装、启动、配置或打包浏览器 MCP。先独立确认你已有的服务正常：

```text
claude mcp list
/mcp
```

然后使用 `/coremail-controller:web-to-coremail`，或直接要求 Claude“用现有浏览器 MCP
研究这些公共网页，把结论整理成 Coremail 草稿”。工作流按以下顺序执行：

```text
浏览器 MCP（只读研究）
  → 有界事实、来源标题和规范 URL
  → Claude Code
  → Coremail 准备邮件
  → 用户复核
  → “确认发送”
  → 当前传输（Coremail Simple MAPI 或 SMTP）
```

两个 MCP 的进程、代码、配置、依赖、凭据、缓存和日志必须分开；Coremail 的
`.mcp.json` 只包含邮件服务器。浏览器结果属于不可信数据，不能指定收件人、授权附件、
触发邮箱读取或代替发送确认。邮箱正文、收件人、Coremail 配置、凭据、附件目录和本地
发现结果不得反向传给浏览器。

要注意：由同一个 Claude Code 会话启动的两个本地 stdio MCP 通常仍使用同一 Windows
账号，因此“两个进程”并不等于操作系统级安全隔离。如果浏览器 MCP 不完全可信，应把
它放在远程主机、容器、沙箱、虚拟机或不同 Windows 账号中，并禁止访问
`%APPDATA%\ClaudeCode\Coremail`、Coremail 数据目录和邮件用户的 Windows 凭据管理器。

同一个 Claude Code 会话还会共享模型上下文，所以只能算“逻辑强隔离”，不是密码学或
机密级隔离。若要求彻底隔离，应使用两个互斥工具集的会话：浏览器专用会话生成有来源
的摘要，人工审核交接内容，再由只加载 Coremail MCP 的会话起草和发送；不得自动批准
交接。

详细边界和审计清单见
[docs/browser-orchestration.md](docs/browser-orchestration.md)。

## 本地数据发现边界

`coremail_discover_local` 默认只盘点常见 Coremail/CMClient/论客目录。深度发现还可：

- 从文本配置中提取经脱敏的账号、主机和端口候选；
- 只读列出 SQLite 表/视图和列名，不查询业务行；
- 只读取 `.eml` 的有限头部元数据；
- 跳过符号链接和 Windows 重解析点，并限制目录深度、文件数和文件大小。

URL 候选仅保留协议、主机和端口；用户信息、路径、查询串和片段全部移除。任何发现
结果都只是“不可信候选”，不能自动覆盖账号配置。

## 验证与排错

离线测试：

```powershell
python -m unittest discover -s tests -v
```

Windows MCP 启动冒烟测试：

```powershell
powershell.exe -NoProfile -File .\tests\smoke-mcp.ps1
```

配置账号后的真实当前传输检查：

```powershell
powershell.exe -NoProfile -File .\tests\smoke-mcp.ps1 -CheckConnection -TimeoutMilliseconds 60000
```

维护者在本地生成经过文件白名单约束的候选包：

```powershell
python .\scripts\build-release.py --output-dir .\dist --force
```

本地构建结果会明确命名为
`dist\coremail-controller-0.7.0-windows-UNVERIFIED.zip`，目标安装器会拒绝它。正式
`coremail-controller-0.7.0-windows.zip` 只能由 `.github/workflows/windows-release-gate.yml`
在干净的 `windows-2022` 环境中生成。门禁使用 Windows PowerShell 5.1、一次性标准
用户和真实的原生/npm Claude Code 两种入口，验证包内清单、脚本解析、凭据 C# 编译、
Python 固定启动、Claude 启用状态、安装/覆盖安装/卸载/重装，还会注入临时目录移动
拒绝和旧版本 `SYSTEM/Administrators`-only ACL、生命周期锁冲突及“凭据已写但配置未
发布”故障并证明同进程恢复。安全桌面的 UAC 点击不能由托管 CI 代替；门禁中的普通
用户进程通过专用握手请求恢复，已提升的外层编排器独立核对一次性账号 SID、固定插件
目录、无重解析路径及插件身份/版本后，实际调用 System32 `icacls.exe` 完成同等授权，
普通用户进程再复核并继续卸载。源码约束同时保证正式路径只能使用当前用户 SID、
`Modify` 和 `/L`，禁止 `/T`、ACL reset、接管所有权或删除。它使用无密码的
离线邮箱配置且跳过真实连接，不读取或发送邮件。ZIP 在测试前后和发布任务中都会再次
核对 SHA-256；只有上传的 `coremail-controller-windows-gated` 构件可交付。

常见问题：

- `credential unavailable`：重新运行 `setup-account.ps1`，并确认当前 Windows 用户一致；
- `no existing shared login session`：保持 Coremail 已登录，确认它是默认 Windows 邮件
  客户端；若仍失败，可能未注册 MAPI 或位数不匹配，改用 `-Transport imap_smtp`；
- 协议认证失败：确认域密码/客户端专用密码是否适用于 IMAP/SMTP，并让管理员检查协议
  是否启用；
- TLS 失败：修复服务器证书；私有 CA 可通过 `-CaFile` 显式配置，不能关闭验证；
- 找不到 Drafts/Sent：用列表工具确认实际名称，再在配置脚本中指定；
- 发信连接中断：结果可能不确定，不要自动重发，先检查已发送和投递状态。

实现和安全边界以 [docs/architecture.md](docs/architecture.md) 为准。

## 卸载

在原解压目录双击 `UNINSTALL.cmd`。也可以运行：

```powershell
powershell.exe -NoProfile -File .\scripts\uninstall.ps1
```

卸载脚本只把插件移动到 `%USERPROFILE%\.claude\plugins-disabled`，不会删除账号配置或
Windows 凭据，因而可以恢复。若要删除凭据，请在确认目标名后通过 Windows“凭据
管理器”手动完成。

卸载器会先通过真实 Claude Code 核对准确的 `coremail-controller@skills-dir`，再禁用并
使用同卷原子移动；若 Defender、EDR、索引或刚结束的进程短暂占用目录，会在同一进程
中自动有界重试。若旧版本目录明确拒绝当前用户访问，则可能出现一次上述受限 UAC
修复；它只增加当前用户对固定插件目录的 `Modify`，不会接管所有权、重置 ACL、递归
处理或删除内容。若最终仍失败，插件和 Claude 设置会保持或恢复到原状态；根据窗口给出
的 `%TEMP%\CoremailController\UNINSTALL-*.log` 定点排查即可。

## 官方参考

- [Claude Code 插件参考](https://code.claude.com/docs/en/plugins-reference)
- [Claude Code MCP 配置](https://code.claude.com/docs/en/mcp)
- [Microsoft MAPILogon（Simple MAPI）](https://learn.microsoft.com/en-us/windows/win32/api/mapi/nc-mapi-mapilogon)
- [Microsoft MAPIReadMail](https://learn.microsoft.com/en-us/windows/win32/api/mapi/nc-mapi-mapireadmail)
- [Microsoft MAPISendMailW](https://learn.microsoft.com/en-us/windows/win32/api/mapi/nc-mapi-mapisendmailw)
- [Coremail 邮件客户端配置（IMAP/SMTP）](https://mail.coremail.cn/coremail/help/clientoption.jsp?locale=zh_CN)
- [Coremail 客户端授权码说明](https://support.coremail.cn/Q-3/240412.html)
- [Coremail 双重认证与客户端专用密码](https://www.coremail.cn/newsdetail_65.html)
- [Coremail 已发送邮件重复说明](https://support.coremail.cn/Q-3/240429.html)
