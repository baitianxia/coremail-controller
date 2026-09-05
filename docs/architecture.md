# Coremail Interface-First Connector Architecture

Status: current normative design
Last updated: 2026-09-05
Release line: 0.9.0

## Purpose

This repository ships a Windows package that gives the current Windows user a
local, user-scoped MCP server for Coremail mailboxes. MCP is the product
runtime. Claude Code's Skill discovery is optional documentation and is not a
runtime dependency.

The installer never creates, replaces, enumerates, moves, repairs, or deletes
anything below `%USERPROFILE%\.claude\skills`. A pre-existing Skill directory
may be locked, inaccessible, or owned by another process; that state is
irrelevant to installation, upgrade, and uninstall. This separation is
intentional: Claude user-scope MCP registration belongs in Claude's user
configuration, while executable release files belong in the application's
user-data directory.

When Coremail is the registered Windows mail client, account setup first
attempts to attach to the already authenticated shared Simple MAPI session.
The call uses a null profile, null password, and no UI flags. If that documented
interface is not available, setup asks for explicit IMAP/SMTP settings and
stores the protocol password only in Windows Credential Manager.

The connector never starts Coremail, opens Coremail webmail, captures a window,
clicks controls, sends keystrokes, or extracts a saved password. The supported
transports are:

1. `windows_simple_mapi`: a recognized Coremail default-mail-client
   registration plus a successful no-UI shared-session probe; or
2. `imap_smtp`: authenticated IMAP and SMTP over TLS, configured by the user.

## Natural-language MCP contract

Claude Code receives the Coremail tools from the user-scope MCP registration.
Tool descriptions and the MCP `initialize.instructions` field contain the
natural-language policy, so no installed Skill is required and no slash-command
reload is required for correctness. After installation, restarting Claude Code
(or reconnecting the MCP entry in its normal UI) is sufficient.

The server exposes status/discovery, connection checking, folder listing,
search, message reads, explicit seen-state changes, draft preparation, draft
save, and confirmation-gated send. Sending is always two steps:

1. `coremail_prepare_message` validates and freezes the message and attachment
   manifest in server memory.
2. `coremail_send_prepared` consumes the token only with the exact phrase
   `确认发送`.

Mailbox content and browser-derived data are untrusted. A separate browser MCP
may be orchestrated by Claude Code for public-web research, but it is a
separate trust domain and is never bundled or called by this package.

## Components

- `.claude-plugin/plugin.json`: package identity and release metadata. It is
  checked by the release verifier; it is not installed through Claude's plugin
  inventory.
- `.mcp.json`: development/package declaration. It is not the target user's
  registration mechanism.
- `mcp/server.py`, `mcp/coremail_backend.py`, `mcp/windows_mapi.py`, and
  `mcp/local_discovery.py`: MCP framing, transport logic, Simple MAPI, and
  bounded local discovery.
- `scripts/register_claude_user_mcp.py`: the only component allowed to mutate
  the Claude user MCP entry. It performs transactional `remove -> add -> get`,
  verifies the actual `.claude.json` entry, and restores a byte-for-byte backup
  on failure.
- `INSTALL.cmd`, `CONFIGURE-ACCOUNT.cmd`, and `UNINSTALL.cmd`: user entry
  points.
- `scripts/install.ps1`: validates a gated package, stages an immutable release
  under `%LOCALAPPDATA%\CoremailController`, registers the MCP, and optionally
  runs account setup.
- `scripts/uninstall.ps1`: removes the user-scope MCP registration only. It
  intentionally retains immutable release directories so an open Python or
  PowerShell handle cannot turn uninstall into a permission/UAC problem.
- `scripts/windows-lifecycle-common.ps1`: logging, path/reparse validation,
  native invocation, locks, snapshots, atomic same-volume moves, and bounded
  retries. It contains no elevation or Skill-directory repair path.
- `mcp/run-server.ps1`: verifies and launches the exact Python executable pinned
  at installation.

The archive may contain `SKILL.md` files as human-readable policy references,
but lifecycle scripts never copy them into Claude's Skill directory and Claude
does not need to discover them to use the MCP.

## User-scope MCP registration

The installer resolves an existing Claude Code executable as either a native
`claude.exe` or a validated npm installation. For npm installations it follows
the package-declared `claude` bin and directly invokes the declared native PE or
the existing `node.exe` plus JavaScript entry; it never evaluates a `.cmd` file
or passes arguments through `cmd.exe`.

Before any MCP configuration mutation it:

1. records the informational Claude version output;
2. runs `claude mcp --help` as a capability probe, keeping successful probe output in the diagnostic log rather than flooding the interactive console; and
3. verifies the gated package and the local Python runtime.

The version number is informational. Capability, not a hard-coded Claude
version floor, determines compatibility.

The registrar invokes the real CLI with user scope:

```text
claude mcp remove coremail-controller --scope user
claude mcp add --transport stdio --scope user coremail-controller -- \
  <SystemRoot>\System32\WindowsPowerShell\v1.0\powershell.exe \
  -NoLogo -NoProfile -NonInteractive -File \
  %LOCALAPPDATA%\CoremailController\releases\<immutable>\mcp\run-server.ps1
claude mcp get coremail-controller
```

An absent old entry is the only non-zero `remove` result that may be ignored.
Successful stderr is diagnostic, not failure; exit codes are authoritative.
The registrar separately parses the actual user configuration and requires the
exact PowerShell executable, launcher path, stdio shape, and no injected
environment secrets.

The default user configuration is `%USERPROFILE%\.claude.json`. If
`CLAUDE_CONFIG_DIR` is set, both install and uninstall use
`<CLAUDE_CONFIG_DIR>\.claude.json`; the value must be an absolute local-drive
path. Relative paths, `~`, UNC paths, existing-file roots, and paths traversing
a link or reparse point are rejected before mutation.

## Runtime layout and immutable upgrade rule

All managed executable files are below the current user's LocalAppData root:

```text
%LOCALAPPDATA%\CoremailController\
  .lifecycle.lock
  staging\<unique-staging>\
  releases\coremail-controller-<version>-<source>-<python>\
```

`<source>` is derived from the verified 40-character build commit and
`<python>` from the generated pinned-runtime descriptor hash. The name is
deterministic for a particular package/runtime pair. A fully verified existing
directory is reused; otherwise a new unique directory is published. No
published directory is modified in place, and an existing directory is never
overwritten or recursively merged.

The package is copied to a unique same-volume staging directory, the internal
manifest and Windows-gated metadata are verified, the Python descriptor is
generated, and the MCP smoke test runs before publication. Publication uses
`[IO.Directory]::Move` with bounded exponential retry. Before each retry the
source must still exist and the destination must still be absent; ambiguous
source/destination states stop without cleanup. A lifecycle lock below the same
application root serializes install/upgrade/uninstall.

The installer does not inspect a legacy `.claude\skills\coremail-controller`
directory. It does not need to know whether that directory is valid, locked,
or protected. Upgrading therefore cannot fail because an older Skill is open,
and no UAC request or manual permission instruction is part of the normal
workflow. The old directory, if present, is left exactly as it was.

Uninstall first removes the user-scope MCP entry transactionally and then
leaves the immutable release directory in place. Retention is deliberate and
recoverable: it avoids deleting files that Claude, Python, Defender, or an
indexer may still hold. A later maintenance command may remove a release only
after an explicit, separately verified cleanup operation; cleanup is never a
prerequisite for installation or uninstallation.

## Account and credential boundary

- `windows_simple_mapi` passes no username or password to `MAPILogon` and
  requires an already authenticated shared session.
- `imap_smtp` stores only non-secret settings in
  `%APPDATA%\ClaudeCode\Coremail\config.json`; the password is a Generic
  Credential in Windows Credential Manager.
- Passwords are not accepted through MCP arguments, environment variables,
  logs, or repository files. Coremail's private saved credentials are never
  decrypted.
- TLS verification is always enabled; plaintext transports and bypass switches
  are rejected.

Account setup validates a same-directory staged JSON before creating a new
credential and atomically publishing the configuration. A failure after
credential creation removes only the new credential and leaves the old
configuration byte-for-byte unchanged. Existing account settings and
credentials are preserved on package upgrade.

## Browser isolation and local-data boundary

The browser MCP and Coremail MCP have separate processes, packages, launch
configuration, credentials, storage, and update lifecycles. The permitted
bridge transfers only bounded public facts, source titles, and canonical URLs.
It never transfers mailbox bodies, recipients, account settings, credentials,
cookies, attachment roots, raw DOM, scripts, or downloads.

Discovery is bounded and read-only. Roots are limited to known user/program
locations or explicitly supplied roots; links and reparse points are skipped;
file counts, sizes, depth, and `.eml` header limits are enforced. Secret-like
keys are redacted and SQLite is opened read-only.

## Release verification and acceptance

Runtime requirements are Windows 10/11, Python 3.10+, and an existing Claude
Code installation exposing the user-scope MCP commands. The target installer
never installs, upgrades, repairs, or downloads Claude Code and never requests
UAC.

The pinned Python descriptor records executable path, version, pointer width,
and SHA-256. `mcp/run-server.ps1` and smoke tests launch it with `-B -I`; later
`PATH` or `COREMAIL_PYTHON` changes cannot redirect the server. PowerShell 5.1
parses every packaged script before the lifecycle test, and native stderr is
kept separate from machine-readable stdout.

The clean Windows x64 release gate proves package integrity, MCP initialization
and tool listing, registrar rollback, native and npm Claude compatibility,
first install, reinstall while a legacy Skill fixture is locked, immutable
runtime reuse/publication, active-runtime handle retention, reversible MCP
uninstall, account rollback, unchanged fixture data, and secret-free logs.

Only the exact ZIP exercised by that gate may be uploaded to
`gated-release/releases/<version>/`. Local ZIPs are visibly `UNVERIFIED` and
the target installer refuses them.

Acceptance invariants include:

1. no desktop/UI automation or Simple MAPI UI flag;
2. MCP initialization and tool listing before account configuration;
3. bounded, redacted local discovery;
4. TLS verification and confirmation-gated sending;
5. no passwords in repository files, settings, logs, or tool output;
6. transactional, hash-verified, reversible user-scope registration;
7. immutable LocalAppData releases with atomic, bounded-retry publication;
8. no lifecycle read/write/elevation operation under `.claude\skills`;
9. no hard-coded Claude version floor; and
10. no Windows archive released before the clean standard-user gate passes.
