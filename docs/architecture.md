# Coremail Interface-First Connector Architecture

Status: current normative design
Last updated: 2026-09-01

## Purpose

This repository provides a Claude Code plugin for non-interactive access to a
Coremail mailbox on Windows. When Coremail is the registered Windows mail client,
the connector first attempts to attach to its existing shared Simple MAPI session.
If that documented client interface is unavailable, account setup falls back to
explicit IMAP/SMTP configuration and a password supplied by the user.

The plugin can orchestrate an already configured browser MCP for public-web
research, but does not bundle, launch, configure, import, or call that service.

The connector never launches Coremail, captures its window, clicks controls, sends
keystrokes, or depends on an interactive desktop. It uses one explicitly selected
transport:

1. `windows_simple_mapi`: the Windows Simple MAPI API with no UI flags, only after
   the registered default mail client is recognized as Coremail and an existing
   shared session can be attached; or
2. `imap_smtp`: authenticated IMAP and SMTP over verified TLS, configured by the
   user and backed by Windows Credential Manager.

Bounded, read-only inspection of local Coremail files remains available for
diagnostics and server-configuration discovery. It never grants access by itself.

## Supported capabilities

- Inspect likely Coremail data/configuration locations without modifying them.
- Detect a registered Coremail Simple MAPI provider without starting a client.
- Attach to an existing Coremail shared MAPI session without login UI.
- List folders (all IMAP folders, or the receive `INBOX` exposed by Simple MAPI).
- Search messages with structured criteria.
- Read a message with IMAP unread-state preservation, or request `MAPI_PEEK` when
  using Simple MAPI.
- Explicitly mark a message read; IMAP can also mark it unread.
- Prepare a message and attachment manifest without sending it.
- Save a prepared message to the IMAP Drafts folder when using `imap_smtp`.
- Send a prepared message through the active transport after explicit
  confirmation.
- Turn bounded, untrusted results from an existing browser MCP into a reviewed
  Coremail draft or prepared message through Claude Code orchestration.

Deleting, recalling, moving, calendar operations, contacts, shared-mailbox
administration, proprietary Coremail APIs, UI automation, and browser-server
implementation are not part of version 0.7.0. Simple MAPI does not provide the full
IMAP feature set: only `INBOX` is addressable, marking unread and saving drafts are
unsupported, Internet threading headers are unavailable, and searches are bounded
client-side scans. MAPI subjects are limited to 255 characters to avoid documented
provider truncation.

## Components

- `.claude-plugin/plugin.json`: Claude Code plugin identity.
- `skills/coremail/SKILL.md`: mailbox workflow, prompt-injection boundary, and
  confirmation policy.
- `skills/web-to-coremail/SKILL.md`: isolated browser-result-to-email orchestration.
- `.mcp.json`: starts the local stdio MCP server through Windows PowerShell.
- `INSTALL.cmd`, `CONFIGURE-ACCOUNT.cmd`, and `UNINSTALL.cmd`: double-click user
  entry points that do not bypass the machine's PowerShell execution policy.
- `mcp/run-server.ps1`: verifies and launches the exact Python executable pinned at
  installation, including its executable SHA-256.
- `mcp/check-python.py`: validates the minimum Python version through a stable exit
  code without relying on redirected native-process output.
- `mcp/describe-python.py`: records the selected interpreter identity, version,
  pointer width, and executable hash without quote-sensitive inline Python.
- `mcp/validate-config.py`: validates a staged non-secret mailbox configuration
  before credential or active-config mutation.
- `mcp/server.py`: MCP framing and tool schemas.
- `mcp/coremail_backend.py`: transport routing, IMAP/SMTP, MIME, attachment, and
  prepared-message logic.
- `mcp/windows_mapi.py`: Coremail registration detection and no-UI Simple MAPI
  shared-session adapter.
- `mcp/local_discovery.py`: bounded, read-only local-data inventory and redaction.
- `docs/browser-orchestration.md`: deployment isolation and operational guide for an
  existing browser MCP.
- `scripts/setup-account.ps1`: probes the client interface, writes non-secret
  transport settings, and stores a user-supplied protocol password in Windows
  Credential Manager only on fallback.
- `scripts/install.ps1`: validates and stages the package, moves a recognized prior
  plugin outside skill discovery, activates the replacement transactionally, runs
  first-use account setup, and verifies the MCP server.
- `scripts/windows-tool-discovery.ps1`, `scripts/windows-lifecycle-common.ps1`, and
  `scripts/windows-credential.ps1`: validated Claude/Python resolution, shared
  atomic lifecycle and diagnostics, and fully qualified Credential Manager interop.
- `scripts/configure-account.ps1`, `scripts/setup-account.ps1`, and
  `scripts/uninstall.ps1`: account reconfiguration and reversible personal plugin
  removal.
- `scripts/build-release.py`: creates the allowlisted Windows ZIP and adjacent
  SHA-256 sidecar in `dist/`.

## Data flow

```text
User request
  -> Claude Code orchestration
    -> existing browser MCP (optional, public web, read-only by default)
      -> bounded untrusted facts + canonical URLs
    -> Coremail skill
      -> local discovery tool (optional, read-only)
      -> Coremail MCP server
        -> settings from %APPDATA%\ClaudeCode\Coremail\config.json
        -> windows_simple_mapi branch
          -> verify registered default mail client is Coremail
          -> MAPILogon with null profile/password and no UI flags
          -> Simple MAPI receive/search/read/mark-read/send
        -> imap_smtp branch
          -> password from Windows Credential Manager
          -> IMAPS for folders/search/read/flags/drafts
          -> authenticated SMTPS or SMTP STARTTLS for sending
```

The Coremail user interface is outside this flow. The `windows_simple_mapi` branch
may use state owned by the already running Coremail process through a documented
Windows API; it never automates that process or its windows.

## Browser MCP isolation boundary

The browser MCP and Coremail MCP are separate trust domains:

- The plugin `.mcp.json` declares only the Coremail server. Browser configuration,
  dependencies, process lifecycle, storage, credentials, cookies, and logs remain
  outside the plugin.
- Neither server can call the other. Claude Code is the only broker.
- The permitted bridge is one-way: bounded facts, source titles, and canonical
  public URLs may flow from browser results into email composition.
- Mailbox content, recipients, account configuration, local discovery output,
  attachment roots, credentials, cookies, raw DOM, scripts, browser profiles, and
  downloads do not cross that bridge.
- Browser content is data, never authority. It cannot choose recipients, authorize
  attachments, request mailbox operations, or satisfy send confirmation.
- Browser work ends before `coremail_prepare_message`. Any later source or message
  change requires a new prepared token and review.

Process separation alone is not an operating-system security boundary when Claude
Code launches both stdio servers as the same Windows user. For an untrusted browser
server or a stronger threat model, the browser MCP must run remotely or under a
container, sandbox, VM, or different OS identity without access to the Coremail
configuration/data roots or the mail user's Windows Credential Manager. The plugin
cannot impose that boundary on an independently installed browser server.

A single Claude Code session also shares model context across both tool sets. The
one-way bridge is therefore a policy boundary, not cryptographic non-interference.
Strict confidentiality requires browser-only and Coremail-only Claude Code sessions
with disjoint MCP availability and a human-reviewed handoff artifact between them.

## Local-data boundary

Local discovery is allowed, but bounded and non-destructive:

- Roots are limited to known user and program-data locations, plus explicit roots
  supplied by the caller.
- Symbolic links and reparse-point escapes are not followed.
- Default discovery returns roots, bounded file metadata, and extension counts. Deep
  discovery additionally returns redacted configuration candidates, limited `.eml`
  headers, and SQLite schema names. It does not return arbitrary file contents.
- Keys resembling passwords, tokens, cookies, sessions, authorization data, or
  secrets are always redacted from tool output.
- SQLite databases are opened read-only. Unknown proprietary schemas are reported,
  not modified or guessed into a write-capable adapter.
- Discovery results are candidates only. They never silently authorize a network
  connection or override the explicit account configuration.

The connector may later add a version-specific local-cache reader after its schema
is observed and documented. Version 0.7.0 does not claim compatibility with an
undocumented Coremail cache format.

## Transport selection and connection configuration

Account setup uses this deterministic order:

1. Check the current-user and machine Windows mail-client registrations.
2. Continue only when the effective default client name is explicitly recognized
   as Coremail and has a Simple MAPI registration.
3. Call `MAPILogon` with a null profile, null password, and zero flags. This can
   attach to an existing shared session but cannot request login UI or create an
   interactive session.
4. Select `windows_simple_mapi` only if that probe succeeds. Otherwise prompt the
   user for the IMAP/SMTP settings and password and select `imap_smtp`.

There is no runtime silent fallback between transports. A later loss of the shared
MAPI session is reported as an actionable error instead of unexpectedly switching
accounts or using stored protocol credentials.

Non-secret settings live in the current user's application data directory. The
common schema includes:

- transport (`windows_simple_mapi` or `imap_smtp`)
- full mailbox username / authorized sender identity
- optional outgoing-attachment roots and size limits

The `imap_smtp` schema additionally includes:

- IMAP host, port, and `ssl` or `starttls` security mode
- SMTP host, port, and `ssl` or `starttls` security mode
- Windows Credential Manager target name
- optional Drafts/Sent folder overrides
- optional trusted CA file for an enterprise/private PKI
- sent-copy mode (`none` by default, or `append`)

The `windows_simple_mapi` schema must not contain protocol endpoints, a credential
target, CA file, folder overrides, or an IMAP Sent-copy request. The adapter requires
the configured sender to match the active Coremail profile; Simple MAPI providers
ultimately choose the submitting account, so multi-account installations must use
`imap_smtp` unless the active/default Coremail profile is unambiguous.

No host is guessed from the email domain. Coremail installations are organization
specific; a discovered value must be confirmed or supplied by the mailbox
administrator.

The JSON schema is strict: unknown fields are rejected, host values must be plain
hostnames or IP addresses rather than URLs, and secret/password fields are not
accepted.

TLS certificate verification is always enabled. Plaintext IMAP/SMTP and
certificate-verification bypasses are not supported.

## Credential boundary

- The setup script stores the user-supplied domain/Coremail or client-specific
  protocol password as a Generic Credential in Windows Credential Manager only for
  `imap_smtp`.
- The `windows_simple_mapi` transport passes neither a username nor a password to
  `MAPILogon`; it requests only an existing shared session.
- When present, the JSON configuration contains only the credential target, never
  the password.
- Environment-variable password injection is intentionally unsupported because
  sibling MCP processes can inherit the same parent environment.
- The connector does not extract, decrypt, copy, or crack Coremail's private saved
  credentials.
- MFA, CAPTCHA, organization policy, protocol disablement, and client-password
  requirements are never bypassed.

## Message identity and state

IMAP operations use folder name, UID, and UIDVALIDITY together. Search results
include UIDVALIDITY; subsequent reads or flag changes verify it when supplied. This
prevents acting on a different message after a folder is rebuilt.

Message reads use `BODY.PEEK[]`, so reading through the tool does not mark a message
as seen. Seen/unseen changes require the dedicated state-changing tool.

Simple MAPI message identifiers are opaque and valid only for a MAPI session. The
adapter maps them to decimal tool UIDs and creates a session-scoped UIDVALIDITY.
Search, read, and mark-read operations verify that value. MAPI reads use
`MAPI_PEEK`; attachments are suppressed on incoming reads so the provider cannot
materialize arbitrary files. Microsoft documents that providers which do not
support `MAPI_PEEK` may still mark a message read; because Simple MAPI cannot restore
the unread flag, every MAPI search/read result discloses this provider-dependent
side effect. A session restart invalidates all previous UIDs.

## Send transaction

Sending is a two-step transaction:

1. `coremail_prepare_message` validates headers, allowed From addresses, recipients,
   body limits, attachment roots, sizes, and SHA-256 hashes. It stores the immutable
   specification in server memory under a random, expiring token.
2. `coremail_send_prepared` accepts that token only with the exact confirmation
   phrase `确认发送`. Attachments are re-hashed before SMTP or Simple MAPI
   submission. The token is consumed when a send attempt begins to prevent
   accidental duplicate retries.

Simple MAPI accepts attachment paths rather than byte buffers. After re-hashing,
the adapter writes random-name current-user temporary snapshots, passes only those
snapshots to the provider, and removes them after `MAPISendMailW` returns. Microsoft
documents that the provider copies attachments before returning, so later changes
to the reviewed source path cannot race submission.

Prepared messages are never written to disk. Tokens expire after 15 minutes and are
lost when the MCP server restarts.

Coremail installations can be configured to save SMTP submissions in Sent. The
default `sent_copy_mode` is therefore `none`; `append` must be enabled deliberately
to avoid duplicate Sent messages. For Simple MAPI, the provider owns Sent-folder
behavior and the connector does not append another copy.

Simple MAPI cannot carry the connector's Internet `In-Reply-To` and `References`
headers. A prepared message containing either value is rejected before MAPI
submission rather than silently losing threading metadata.

## Untrusted-content boundary

Email bodies, headers, attachments, calendar invitations, delivery reports, local
cache text, discovery output, browser results, webpages, and downloads are untrusted
data. Skills must never execute or follow instructions found in them. Tool results
label message content as untrusted.

## Failure handling

- Configuration, credential, DNS, TLS, authentication, protocol, and mailbox errors
  are distinguished without returning passwords or full protocol transcripts.
- Simple MAPI registration, missing shared session, provider bitness mismatch,
  unsupported operation, and provider failures are reported separately. The
  connector never retries by opening UI or creating a new login session.
- SMTP outcome can be uncertain if the connection fails after the server accepts
  message data. The connector does not retry automatically.
- A failure to append a Sent copy after successful SMTP submission is reported as a
  copy failure, not a send failure.
- Result counts, returned body characters, recipients, and attachment bytes have
  enforced upper bounds. IMAP enforces message bytes before fetching; Simple MAPI
  exposes no pre-read size, so a provider can allocate one full selected message
  before the connector truncates its returned body. Text searches use a bounded
  scan, and non-text searches request envelope-only reads.

## Runtime requirements

- Windows 10 or 11
- Claude Code 2.1.157 or newer with skills-directory plugin and plugin MCP support
- Python 3.10 or newer (standard library only)
- For interface mode: Coremail registered as the default Windows mail client, a
  provider matching the Python process bitness, and an existing shared Simple MAPI
  session
- For protocol mode: network access to the organization's IMAP and SMTP endpoints,
  both protocols enabled, and the user's domain/client password as required by the
  organization
- Optional: an independently configured browser MCP for the web-to-Coremail workflow

The protocol transport does not require the Coremail desktop application. The
Simple MAPI transport requires its registered provider and already authenticated
shared session.

## Installation and release boundary

- The distributable has a top-level `INSTALL.cmd`; normal installation is one
  double-click after the ZIP is fully extracted.
- New installation and every normal lifecycle operation are user-scoped and do not
  request administrator elevation. A narrowly scoped exception exists only for a
  legacy active plugin directory whose ACL denies the current user because an older
  package was moved from an unsuitable source location. After package/prerequisite
  verification and acquisition of the per-user lifecycle lock, install or uninstall
  may ask for one UAC approval to run the Microsoft system `icacls.exe` against
  exactly `%USERPROFILE%\.claude\skills\coremail-controller`. The command grants
  the current account SID inheritable `Modify`, operates on the final link itself
  (`/L`), preserves all existing ACEs and ownership, and does not recurse, reset,
  delete, or grant any group. The parent path must already pass local-profile and
  reparse checks. The ordinary user process then repeats the reparse and plugin-
  identity checks before any move. Cancellation, an unexpected path, a non-account
  SID, a remaining denial, or an unrecognized manifest fails closed without moving,
  replacing, or deleting directory contents. If `icacls` already succeeded, its
  added current-user ACE remains even when later identity validation fails; existing
  ACEs and ownership still remain unchanged. `-NoLegacyPermissionRepair` disables
  this compatibility path.
- The installer requires an already usable Claude Code installation. It resolves
  native `claude.exe` and standard npm `claude.cmd` installations without running a
  package manager. For an npm installation it validates the package name and declared
  bin path inside that package: current native-backed npm releases execute the
  declared, non-reparse PE directly; older `.js`/`.cjs`/`.mjs` bins execute through
  that installation's existing `node.exe`. It never evaluates the `.cmd` text or
  passes user arguments through `cmd.exe`. The installer validates the plugin with
  the real Claude CLI, explicitly enables `coremail-controller@skills-dir`, and
  verifies the installed enabled entry. A missing, unsupported, incomplete,
  policy-blocked, or uninspectable Claude installation stops before replacing an
  existing plugin. Lifecycle probes temporarily disable Claude auto-updating and
  restore the caller's environment, so the connector neither upgrades Claude nor
  invokes a package manager as part of validation.
- V1 owns only the default per-user `%USERPROFILE%\.claude` configuration root.
  Install and uninstall reject a non-default `CLAUDE_CONFIG_DIR` before lifecycle
  mutation, because mixing a custom Claude inventory/settings root with the fixed
  skills path would make verification and rollback refer to different states.
- The installer resolves Python 3.10+ once, records the resolved `sys.executable`,
  version, pointer width, and executable SHA-256 in the staged plugin, and validates
  the MCP through that descriptor. Normal MCP and MAPI-probe startup must use the
  pinned executable and must not rediscover Python from a later Claude Code `PATH`
  or honor an inherited `COREMAIL_PYTHON` override. Installed Python launches use
  `-B -I`, and the direct release-gate MCP smoke launch uses the same flags,
  preventing runtime bytecode caches from changing the verified plugin tree. An
  environment-only bytecode switch is insufficient because isolated mode ignores
  `PYTHON*` variables.
- Before mutation, the installer validates every allowlisted release file against
  the package's internal file manifest and requires Windows-native release metadata.
  A locally built unverified candidate has a visibly different filename and metadata
  and is rejected by the target installer.
- The validated temporary tree is copied into a current-user staging directory
  under `%USERPROFILE%\.claude` before activation. The active plugin is never moved
  directly from `%TEMP%`, because an NTFS move can preserve an unsuitable source
  ACL instead of inheriting the user's Claude directory permissions.
- Legacy ACL repair is not a general permission-repair facility and is not used for
  `.claude`, `skills`, backup, disabled, staging, configuration, or arbitrary paths.
  It exists only to recover the exact active directory left by withdrawn releases;
  permanent denial anywhere else remains an administrator or policy issue.
- A recognized previous plugin is moved to
  `%USERPROFILE%\.claude\plugin-backups`, outside the auto-discovered `skills`
  directory. An unrecognized target directory is never overwritten.
- Installer and uninstaller share a current-user exclusive lifecycle lock outside the
  active plugin directory. New files are copied to a unique temporary stage and
  validated before activation. Every whole-directory publish, backup, disable, and
  rollback uses the same-volume Win32 rename exposed by `[IO.Directory]::Move`, not
  PowerShell FileSystem-provider `Move-Item`. Retryable access-denied and sharing
  failures caused by Defender, EDR, indexing, or a recently stopped process are
  retried with bounded backoff only while the source exists and destination does not.
  Ambiguous state fails closed without recursive cleanup. If activation fails after
  backup, the new directory is quarantined and the prior plugin is restored.
- All lifecycle target paths under `%USERPROFILE%\.claude` are checked before writes;
  V1 rejects a user profile, `.claude` root, or target ancestor that traverses a
  symlink, junction, or other Windows reparse point.
- Account configuration and installation summaries are constrained to the
  system-resolved `%APPDATA%` root (including a normal enterprise-redirected root)
  and reject reparse traversal below that boundary before publication.
- Existing non-secret account configuration and Windows Generic Credentials are
  preserved on upgrade. Account setup validates a same-directory staged configuration
  before credential mutation, backs up the previous configuration byte-for-byte, uses
  a new credential target by default, and atomically publishes the configuration.
  Failure before publication removes the newly created credential and leaves the old
  configuration untouched. First installation probes the client interface, selects
  it without requesting a password only after a successful shared-session check, and
  otherwise starts interactive protocol setup. Reconfiguration remains explicit.
- Offline MCP verification is mandatory. A live active-transport check runs when
  account configuration exists, but a session, network, or authentication failure
  is reported as incomplete connection verification rather than rolling back valid
  plugin files.
- MCP stdio is newline-delimited UTF-8 JSON. Because Windows PowerShell 5.1's .NET
  `ProcessStartInfo` has no configurable stdin encoding, the server accepts one
  leading BOM at stream start for interoperability with its legacy redirected
  writer; later BOMs remain invalid requests. Initialization failures report only
  protocol metadata, never mailbox configuration or message content.
- Release archives are built from an explicit file allowlist. Live configuration,
  credentials, caches, VCS data, and arbitrary untracked files are excluded. Each
  archive has an adjacent SHA-256 file encoded as ASCII with an LF terminator so
  standard verification tools behave consistently on Windows, macOS, and Linux.
- Each package also contains Windows build/source metadata and an internal
  size/SHA-256 manifest for every distributed file. These detect accidental use of a
  cross-built/local candidate and post-extraction corruption; organization signing or
  a trusted gated distribution channel remains the authenticity boundary.
- A locally built archive is only a release candidate. The only releasable artifact
  is the candidate uploaded after the packaged lifecycle test succeeds on a clean
  `windows-2022` runner under Windows PowerShell Desktop 5.1. That test parses every
  packaged PowerShell script, compiles the embedded Credential Manager C# helper,
  starts the packaged MCP server, and exercises install, replacement install,
  reversible uninstall, reinstall, and a final uninstall launched from the installed
  script itself as a disposable local standard user. The hosted runner's
  administrator identity is used only to create
  and later remove that account. The orchestrator verifies the GitHub-hosted runner
  environment before crossing the alternate-credential process boundary and passes
  an explicit verification switch because runner-only environment variables are not
  reliably inherited there. The lifecycle script then verifies its own SID and
  rejects an Administrators token so elevated access cannot hide user-profile ACL
  defects.
  The candidate ZIP is hashed before extraction and again immediately before
  upload, so the artifact uploaded is byte-for-byte the artifact exercised. For a
  successful `main` push only, a separate least-privilege publication job downloads
  that same named artifact, verifies its sidecar again, and commits the original
  ZIP and sidecar to `gated-release/releases/<version>/`. Pull-request test jobs
  retain read-only repository permission and cannot publish.
- The Windows lifecycle test uses a non-secret `windows_simple_mapi` configuration,
  skips the live connection check, hashes the configuration before and after every
  mutation, and is restricted to an ephemeral GitHub Actions profile. It cannot
  read, authenticate to, or send through a real mailbox.
- The Windows release gate uses fixed native and npm Claude Code fixtures only on the
  disposable online runner. Under disposable standard-user profiles it validates the
  plugin with the real CLI, proves a previously disabled skills-directory plugin is
  enabled, verifies the pinned Python launch, and exercises both supported Claude
  installation shapes. The pinned npm fixture uses its package-declared native PE,
  while source assertions retain compatibility with older Node-backed npm bins. The
  target installer never downloads, installs, upgrades, or repairs Claude Code.
- The gate injects a real, reversible NTFS delete denial into a staged directory and
  its parent, observes one atomic-move retry, restores both ACLs, and proves the same
  installer process completes. It also tests lifecycle-lock contention, account
  configuration rollback after a post-credential fault, and rejection of a corrupted
  extracted file and unverified release metadata.
- The gate proves a non-default `CLAUDE_CONFIG_DIR` is rejected before plugin or
  settings mutation and that `-NoLegacyPermissionRepair` leaves the inaccessible
  active plugin and its enabled state untouched.
- The gate also changes the recognized active plugin ACL to the observed legacy
  `SYSTEM`/`Administrators`-only shape, uses a release-gate-only handshake to restore
  access while the same standard-user uninstall process waits, and requires the
  legacy-repair requested/recovered log markers. Hosted CI cannot click a secure-
  desktop UAC prompt; source assertions therefore bind production elevation to the
  fixed System32 `icacls.exe`, exact target, current account SID, inheritable
  `Modify`, and `/L`, while forbidding recursion, reset, ownership change, or delete.
- Launchers do not pass `-ExecutionPolicy Bypass`; enterprise script policy must be
  satisfied through normal approval or signing.
- Uninstall moves only a recognized plugin to `plugins-disabled`. A lock or
  unrepaired ACL failure is handled by the same atomic state checks and bounded retry
  policy. A permanent or ambiguous failure reports the current Windows identity and
  a specific recovery action; it never recursively deletes the plugin, account
  configuration, or credentials. The exact legacy-ACL compatibility path above may
  run before manifest verification or during the final move, but the ordinary user
  process must still recognize the plugin before committing removal. The uninstaller
  disables the real skills-directory plugin first and restores the previous Claude
  settings if the directory move fails.
  When the exact active directory is absent, uninstall is idempotently successful
  without requiring Claude Code; an inaccessible existing directory still requires
  the real CLI before permission repair or plugin-state mutation.
- Install, reconfiguration, and uninstall launchers create a timestamped UTF-8 log in
  `%TEMP%\CoremailController`, display its path on both success and failure, and keep
  secrets and full protocol transcripts out of that log. Capturing diagnostics must
  never cause the original operation to fail. Native stderr is logged separately
  from captured stdout so warnings cannot corrupt Claude inventory or MAPI-probe JSON.
- Native-process exit codes are captured immediately after the native invocation.
  In-process PowerShell verification scripts report failure by throwing and are not
  judged through the nullable/stale `$LASTEXITCODE` value. Expected-failure native
  probes capture stderr separately under a temporary gate directory and assert the
  exact rejection reason before continuing.
- Windows PowerShell 5.1 launch paths execute the packaged no-output version probe
  and use only its exit code; they neither parse redirected native-process output
  nor pass quote-sensitive inline Python through `-c`.

## Acceptance criteria

1. No implementation path imports UI Automation, captures screens, starts Coremail,
   sends desktop input, or sets a Simple MAPI UI flag.
2. MCP initialization and tool listing work before account configuration.
3. Local discovery is read-only, bounded, and redacts secret-like values.
4. TLS verification cannot be disabled through tool input or configuration.
5. Reads use IMAP PEEK or MAPI_PEEK; message mutations verify transport-specific
   UIDVALIDITY when provided, and MAPI results disclose that PEEK support is
   provider-dependent.
6. A message cannot be sent in one tool call or without the confirmation phrase.
7. Passwords are absent from repository files, JSON settings, logs, and tool output.
8. Offline unit tests cover MIME parsing, mailbox encoding, path boundaries,
   prepared-message expiry/immutability, redaction, and MCP framing.
9. The Coremail plugin contains no browser server, browser dependency, cookie/profile
   access, or cross-server call path; orchestration preserves the one-way data bridge
   and the exact send-confirmation gate.
10. Documentation distinguishes same-session logical isolation from OS/process and
    two-session context isolation; it never claims one process per MCP is a complete
    security boundary.
11. Installation is transactional and reversible, backups cannot be auto-discovered
    as skills, first-use configuration has a double-click path, and release contents
    are allowlisted and hashed.
12. Simple MAPI is selected only for a recognized Coremail registration after a
    no-UI shared-session probe; failure falls back to explicit user-owned protocol
    setup, never credential extraction or interface automation.
13. The installation probe runs through the same resolved Python command as the MCP
    server so a MAPI provider/process bitness mismatch fails before selecting the
    interface transport.
14. Python version validation works through Windows PowerShell 5.1 without relying
    on embedded quote preservation or captured native-process output.
15. No Windows archive is released until its packaged tree passes the clean-runner
    Windows PowerShell 5.1 lifecycle gate; local unit tests or a local ZIP build do
    not satisfy this release criterion.
16. Directory mutation is serialized, atomic, retryable only from an unambiguous
    source-present/destination-absent state, and covered by real ACL fault injection;
    packaged lifecycle scripts contain no `Move-Item` directory transition.
17. The installed MCP uses the Python executable pinned during installation, and the
    Windows gate validates and enables the installed plugin through real native and
    npm Claude Code entry points before accepting the artifact.
18. Account configuration publication and new credential creation form a recoverable
    transaction, including a test fault after credential creation but before config
    publication.
19. Every target lifecycle produces a persistent secret-free diagnostic log, and the
    installer rejects non-Windows-gate metadata or any distributed file that differs
    from the internal integrity manifest.
20. A withdrawn-release `SYSTEM`/`Administrators`-only ACL can be repaired only at
    the exact active plugin path through the constrained UAC flow; normal installs do
    not elevate, and no compatibility path may reset ACLs, take ownership, recurse,
    delete data, or touch another location.
