# Coremail Interface-First Connector Architecture

Status: current normative design
Last updated: 2026-09-05
Release line: 0.8.0

## Purpose

This repository ships a Windows package that gives Claude Code a local, user-scoped
MCP server for Coremail mailboxes. It also installs a user skill so a person can
describe mailbox work in natural language. The package does not depend on Claude
Code's plugin inventory or enablement lifecycle.

When Coremail is the registered Windows mail client, account setup first attempts
to attach to the already authenticated shared Simple MAPI session. The call uses a
null profile, null password, and no UI flags. If that documented interface is not
available, setup asks the user for explicit IMAP/SMTP settings and stores the
protocol password only in Windows Credential Manager.

The connector never starts Coremail, opens Coremail webmail, captures a window,
clicks controls, sends keystrokes, or extracts a saved password. The two supported
transports are:

1. `windows_simple_mapi`: a recognized Coremail default-mail-client registration
   plus a successful no-UI shared-session probe; or
2. `imap_smtp`: authenticated IMAP and SMTP over TLS, configured by the user.

An independently installed browser MCP may be orchestrated for public-web research,
but it is a separate trust domain and is never bundled or called by this package.

## Supported capabilities

- Inspect likely Coremail data/configuration locations without modifying them.
- Detect a registered Coremail Simple MAPI provider and attach to its shared session.
- List folders, search, read, and explicitly change supported message state.
- Preserve unread state with IMAP `BODY.PEEK[]` or request `MAPI_PEEK` for Simple MAPI.
- Prepare an immutable message and attachment manifest, save an IMAP draft, and send
  only after the exact confirmation phrase `确认发送`.
- Convert bounded, untrusted results from an existing browser MCP into a reviewed
  Coremail draft or prepared message through Claude Code orchestration.

Deleting, recalling, moving, calendar/contact operations, shared-mailbox
administration, proprietary Coremail APIs, UI automation, and browser-server
implementation are out of scope. Simple MAPI exposes only the receive surface and
cannot reliably mark unread, save drafts, or carry Internet threading headers.

## Components

- `.claude-plugin/plugin.json`: package identity and release metadata. It remains in
  the archive for compatibility and integrity checking; lifecycle scripts do not
  call `claude plugin validate`, `plugin enable`, or `plugin list`.
- `.mcp.json`: the development/package declaration (`coremail-windows`). It is not
  the target user's registration mechanism.
- `SKILL.md`: the top-level user skill installed at
  `%USERPROFILE%\.claude\skills\coremail-controller\SKILL.md`. Claude Code versions
  that scan user skills by immediate child can therefore discover the natural-language
  entry without a plugin inventory.
- `skills/coremail/SKILL.md` and `skills/web-to-coremail/SKILL.md`: detailed mailbox
  and browser-to-mail policies shipped alongside the root skill.
- `scripts/register_claude_user_mcp.py`: the only component allowed to mutate the
  Claude user MCP entry. It executes a transactional `remove → add → get`, verifies
  the actual `.claude.json` entry, and restores a byte-for-byte backup on failure.
- `INSTALL.cmd`, `CONFIGURE-ACCOUNT.cmd`, and `UNINSTALL.cmd`: user entry points.
- `scripts/install.ps1`: validates a gated package, stages the package under the
  current user's Claude directory, publishes either the fixed skill package or an
  immutable upgrade release, registers the user MCP, and runs account setup.
- `scripts/uninstall.ps1`: removes the user MCP and moves the registered package to
  `plugins-disabled` without deleting it; an older fixed skill left behind by an
  immutable upgrade is treated as a compatibility skill and is not touched.
- `scripts/windows-tool-discovery.ps1`: resolves native and npm Claude entry points
  without invoking a package manager or a command shell.
- `scripts/windows-lifecycle-common.ps1`: path validation, native invocation,
  logging, locks, atomic moves, bounded retries, rollback, and the constrained
  legacy-ACL repair path.
- `mcp/run-server.ps1`: verifies and launches the exact Python executable pinned at
  installation.
- `mcp/server.py`, `mcp/coremail_backend.py`, `mcp/windows_mapi.py`, and
  `mcp/local_discovery.py`: MCP framing, transport logic, Simple MAPI, and bounded
  local discovery.

## Data flow

```text
Natural-language request
  -> Claude Code user skill
    -> Coremail MCP (user-scope entry in <config-root>\.claude.json)
      -> settings in %APPDATA%\ClaudeCode\Coremail\config.json
      -> windows_simple_mapi
        -> recognize Coremail default client
        -> MAPILogon(NULL, NULL, 0), no UI
      -> imap_smtp
        -> password from Windows Credential Manager
        -> IMAPS + authenticated SMTPS/STARTTLS

Optional public-web task:
  existing browser MCP -> bounded facts + canonical URLs -> Claude Code
    -> Coremail prepare/review -> exact `确认发送` -> transport submission
```

The Coremail user interface is outside this flow. Discovery output is a candidate,
not authorization to connect or to overwrite account settings.

## User-scope MCP registration contract

The installer resolves an existing Claude Code executable as either a native
`claude.exe` or a validated npm installation. For npm installations it follows the
package-declared `claude` bin and directly invokes the declared native PE or the
installation's existing `node.exe` plus JavaScript entry; it never evaluates a
`.cmd` file or passes arguments through `cmd.exe`.

Before any package replacement or Claude configuration mutation, the installer:

1. runs and records the informational Claude version output (the output does not
   need to be semantic version text);
2. runs `claude mcp --help` as a capability probe; and
3. verifies the gated package and the local Python runtime.

The version number is not a policy gate. Claude Code 2.1.84 and current releases
are supported when they implement the required commands. A release that lacks the
commands fails closed before the lifecycle lock, staging, or configuration write.

The registrar then invokes the real CLI with these user-scope operations:

```text
claude mcp remove coremail-controller --scope user
claude mcp add --transport stdio --scope user coremail-controller -- \
  <SystemRoot>\System32\WindowsPowerShell\v1.0\powershell.exe \
  -NoLogo -NoProfile -NonInteractive -File <installed>\mcp\run-server.ps1
claude mcp get coremail-controller
```

An absent old entry is the only non-zero `remove` result that may be ignored.
Successful stderr is diagnostic, not failure; exit codes are authoritative. The
registrar separately parses the actual user configuration and requires the exact
PowerShell executable, launcher path, stdio shape, and no injected environment
secrets. It does not print `mcp get` output, which could contain user configuration.

The default user configuration is `%USERPROFILE%\.claude.json`. If
`CLAUDE_CONFIG_DIR` is set, both install and uninstall use
`<CLAUDE_CONFIG_DIR>\.claude.json`; the value must be an absolute local-drive path.
Relative paths, `~`, UNC paths, existing-file roots, and paths traversing a link or
reparse point are rejected before mutation. The target skill/package remains under
the current profile's `.claude\skills` directory.

The root `SKILL.md` is intentional: user-scope skill discovery in supported Claude
releases looks for an immediate `SKILL.md` below each child of `.claude\skills`.
The nested workflow files remain documentation and policy references, not a second
registration mechanism.

## Browser MCP isolation boundary

The browser MCP and Coremail MCP have separate processes, packages, launch
configuration, credentials, storage, and update lifecycles. Claude Code is the only
orchestrator. The permitted bridge is one-way:

- transfer only bounded public facts, source titles, and canonical URLs;
- never transfer mailbox bodies, recipients, account settings, credentials, cookies,
  local discovery output, attachment roots, raw DOM, scripts, or downloads;
- treat browser content as untrusted data that cannot choose recipients, authorize
  attachments, call Coremail tools, or satisfy `确认发送`.

Two local stdio processes launched by one Claude Code session normally run as the
same Windows identity, and the model context is shared. That is logical isolation,
not a complete OS or cryptographic boundary. For stronger confidentiality use two
sessions with disjoint MCP availability and a human-reviewed handoff. Do not use
Coremail webmail as a substitute for the independent browser MCP.

## Local-data boundary

Discovery is bounded and read-only. Roots are limited to known user/program-data
locations or explicitly supplied roots; links and reparse points are skipped; file
counts, sizes, depth, and `.eml` header limits are enforced. SQLite is opened
read-only and only schema names are returned. Password-, token-, cookie-, session-,
and authorization-like keys are redacted. Discovery never silently selects a host,
credential, or transport.

## Account and credential boundary

- `windows_simple_mapi` passes no username or password to `MAPILogon` and requires
  an already authenticated shared session.
- `imap_smtp` stores only non-secret settings in
  `%APPDATA%\ClaudeCode\Coremail\config.json`; the password is a Generic
  Credential in Windows Credential Manager.
- Passwords are not accepted through MCP arguments, environment variables, logs, or
  repository files. Coremail's private saved credentials are never decrypted.
- TLS verification is always enabled; plaintext transports and bypass switches are
  rejected. MFA, CAPTCHA, protocol policy, and client-password requirements are not
  bypassed.

Account setup validates a same-directory staged JSON before creating a new credential
and atomically publishing the configuration. A failure after credential creation
removes only the new credential and leaves the old configuration byte-for-byte
unchanged. Existing account settings and credentials are preserved on package
upgrade.

## Message identity and send transaction

IMAP actions carry folder, UID, and UIDVALIDITY together. Reads use `BODY.PEEK[]`;
state changes verify UIDVALIDITY when supplied. Simple MAPI identifiers are opaque,
session-scoped values and the provider-dependent unread side effect is disclosed.
Incoming attachments are metadata-only; they are not materialized by reads.

Sending is always two steps:

1. `coremail_prepare_message` validates headers, allowed From addresses, recipients,
   body limits, attachment roots, sizes, and SHA-256 hashes, then stores an immutable
   expiring token in MCP-server memory.
2. `coremail_send_prepared` accepts that token only with the exact phrase `确认发送`.
   Attachments are re-hashed immediately before submission and the token is consumed
   when the attempt starts.

The server never retries an uncertain SMTP or provider handoff automatically. Drafts
and Sent-copy behavior follow the active transport; SMTP `sent_copy_mode` defaults to
`none` to avoid duplicate Coremail Sent entries.

## Installation, rollback, and ACL boundary

Normal operations are user-scoped and do not elevate. The installer validates every
allowlisted file against the internal manifest and requires Windows-native gated
metadata. A local archive is visibly `UNVERIFIED` and is refused by the target
installer.

The package is copied to a unique staging directory below the current user's
`.claude` root, validated, and published with same-volume `[IO.Directory]::Move`.
On a normal upgrade an accessible recognized package may be moved to
`.claude\plugin-backups`, outside skill discovery; it is never overwritten or
recursively deleted. If that live package is protected or held open after the
bounded retry and one constrained UAC attempt, the interactive installer prints
the exact path, current-user SID, and a narrowly scoped `icacls` example. The
user can release the handle or repair the ACL and press `R` to retry in the same
run, without rebuilding or downloading the package; pressing `V` (or running
without an interactive console) leaves the old skill directory untouched and
publishes the new verified package to a unique immutable directory under
`.claude\coremail-releases`, then points the user-scope MCP entry at that release.
This is the same versioned-release principle used by the intranet browser agent:
an active client never has to unload its current runtime before an upgrade can
complete. A lifecycle lock serializes install/upgrade/uninstall. Directory moves
retry only while source exists and destination is absent; ambiguous states stop
without cleanup. A failed activation restores the prior package and user MCP
configuration, and quarantines an uncommitted replacement for diagnosis.

The only elevation exception is a withdrawn package whose exact active directory
cannot be inspected or renamed by the current user. After identity, path, and
reparse checks,
the constrained compatibility path may request one UAC approval. The approved
helper runs the protected System32 `icacls.exe` against the current account SID
and then performs the same-volume `Directory.Move` to the one generated quarantine
directory (`plugin-backups` during upgrade or `plugins-disabled` during uninstall):

- the source is exactly `%USERPROFILE%\.claude\skills\coremail-controller`;
- the manifest name and already-verified version are checked again in the elevated
  process;
- the grant is inheritable `Modify` on that exact source (`/L`, never `/T`);
- no recursion, ACL reset, ownership transfer, arbitrary group grant, overwrite,
  or deletion is possible.

This avoids relying on a medium-integrity user token to rename a directory whose
parent, integrity label, or inherited policy still denies `DELETE_CHILD`. The
ordinary process verifies the source/destination postcondition. If the elevated
child reports that a lock or policy still blocks the move, the installer records
the child diagnostic and offers the same-run manual recovery prompt; choosing the
immutable release path (or running without a console) leaves the source and
mailbox data intact without requiring a repackaged download. `-NoLegacyPermissionRepair` disables the UAC attempt, but the
same non-destructive immutable-release fallback remains available. The helper is
never used for the `.claude` root, custom config roots, staging, backups other than
the generated destination, account data, or arbitrary paths.

Uninstall first removes the user-scope `coremail-controller` entry transactionally,
using the package path recorded in that entry when an immutable upgrade release is
active, then moves that recognized package to `.claude\plugins-disabled`. If an
immutable release was active, an older fixed skill directory may remain as an
untouched compatibility skill; it is not treated as an active MCP package. If the
move fails, the exact user configuration is restored. If the active package is
absent, uninstall is idempotently successful without requiring Claude Code; an
inaccessible existing fixed skill still requires verification and fails closed.

## Runtime and release verification

Runtime requirements are Windows 10/11, Python 3.10+, and an existing Claude Code
installation exposing the user-scope MCP commands. The release gate tests both a
native and an npm Claude entry, and specifically performs a real isolated
user-scope `remove/add/get` registration with the exact Claude Code 2.1.84 fixture.
The target installer never installs, upgrades, repairs, or downloads Claude Code.

The pinned Python descriptor records executable path, version, pointer width, and
SHA-256. `mcp/run-server.ps1` and smoke tests launch it with `-B -I`; later `PATH` or
`COREMAIL_PYTHON` changes cannot redirect the server. PowerShell 5.1 parses every
packaged script before the lifecycle test, and native stderr is kept separate from
machine-readable stdout.

The clean Windows x64 gate runs as a disposable standard user and proves:

- package manifest/hash and PowerShell/Credential Manager compilation;
- MCP stdio initialization and tool listing before account setup;
- registrar transaction, rollback fault matrix, and exact 2.1.84 compatibility;
- first install, upgrade backup, lock contention, ACL move retry, account rollback,
  constrained legacy ACL repair, reversible uninstall, reinstall, and final removal;
- unchanged mailbox fixture data and absence of secrets in logs.

Only the exact ZIP exercised by that gate may be uploaded to
`gated-release/releases/<version>/`. Local tests and a local ZIP are not release
evidence.

## Acceptance criteria

1. No implementation starts Coremail, automates a desktop, captures a screen, or
   passes a Simple MAPI UI flag.
2. MCP initialization and tool listing work before account configuration.
3. Local discovery is bounded, read-only, and redacts secret-like values.
4. TLS verification cannot be disabled through configuration or tool input.
5. Reads preserve IMAP unread state or disclose the provider-dependent MAPI result.
6. Sending requires an immutable prepared token and exact `确认发送` confirmation.
7. Passwords are absent from repository files, JSON settings, logs, and tool output.
8. Offline tests cover MIME, mailbox encoding, path boundaries, expiry/immutability,
   redaction, registration rollback, and MCP framing.
9. Browser and Coremail services remain separate with a one-way bounded data bridge.
10. Documentation distinguishes logical, OS, and two-session context isolation.
11. Installation is transactional, reversible, allowlisted, and hash-verified.
12. Simple MAPI is selected only after Coremail registration and a no-UI shared probe.
13. The same pinned Python runtime is used for setup, MCP, and verification.
14. PowerShell 5.1 launch paths do not rely on quote-sensitive inline Python or
    redirected native stderr for success/failure.
15. No Windows archive is released before the clean standard-user gate passes.
16. Directory mutation is serialized, atomic, bounded-retry, and fail-closed.
17. The installed MCP is registered in Claude's user scope through `mcp remove/add/get`
    and the actual `.claude.json` entry is verified; no hard-coded Claude version floor
    or plugin inventory lifecycle is required, and Claude Code 2.1.84 is covered.
18. Account configuration and new credential creation form a recoverable transaction.
19. Every lifecycle writes a persistent secret-free diagnostic log.
20. Legacy ACL repair is limited to the exact active package path and current SID.
