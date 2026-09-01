# Changelog

## Unreleased

## 0.7.0 - 2026-09-01

- Replace PowerShell provider directory moves with one shared same-volume
  `Directory.Move` primitive, exclusive per-user lifecycle locking, unambiguous
  state checks, bounded retry, quarantine, rollback, and persistent diagnostics.
- Require the real installed Claude Code CLI before mutation; validate, explicitly
  enable, and inventory-check the exact `coremail-controller@skills-dir` plugin,
  while transactionally restoring Claude settings on activation or uninstall failure.
- Resolve Python once during installation and persist its real executable, version,
  pointer width, and SHA-256; normal MCP and MAPI launches no longer rediscover a
  different runtime from `PATH` or an inherited override.
- Make IMAP/SMTP account updates recoverable by validating a same-directory staged
  config before writing a unique new Windows credential and publishing atomically;
  injected pre-publication failure removes that credential and preserves the old config.
- Add internal per-file size/SHA-256 verification and Windows-native build metadata.
  Local output is visibly `UNVERIFIED` and is rejected by the target installer.
- Expand the Windows PowerShell 5.1 standard-user gate to real native and npm Claude
  fixtures, persisted disabled-state recovery, lock contention, actual NTFS ACL move
  denial/recovery, credential/config rollback, corruption rejection, reinstall, and
  reversible uninstall.
- Move Credential Manager interop into one compiled helper with a fully qualified
  `ComTypes.FILETIME`, closing both the 0.5.2 compilation regression and credential
  cleanup gap.
- Recover the exact active plugin directory left with a withdrawn-release
  `SYSTEM`/`Administrators`-only ACL through a constrained one-time UAC grant to the
  current account SID. The compatibility path preserves existing ACLs and ownership,
  never recurses, resets, or deletes, revalidates path and plugin identity as the
  ordinary user, and is covered by a standard-user gate recovery handshake.
- Support both current native-backed and older Node-backed standard npm Claude Code
  installations by validating the package-declared bin shape and executing it
  directly, rather than assuming every npm bin is JavaScript.
- Reject a non-default `CLAUDE_CONFIG_DIR` before install/uninstall mutation, preserve
  one-element Claude plugin inventories under Windows PowerShell 5.1, and initialize
  account-launcher diagnostics before its first validation step.
- Make an already-absent uninstall idempotently successful without Claude Code, while
  keeping inaccessible existing directories behind CLI verification and fail-safe,
  best-effort lifecycle logging.
- Keep native stderr out of machine-readable stdout captures so a Claude or provider
  warning cannot corrupt JSON inventory/probe validation under Windows PowerShell 5.1.
- Make staged configuration validation import only its packaged backend under
  Python isolated mode, closing a pre-credential setup failure before publication.
- Suppress Claude Code auto-updating only around lifecycle validation and restore
  the caller environment, keeping install/uninstall deterministic without invoking
  a package manager or updater.
- Run installed Python with `-B -I` so normal MCP/account use cannot add bytecode
  caches that later make the verified plugin tree appear corrupted.
- Write Windows smoke-test stdin as BOM-free UTF-8 and accept one legacy .NET BOM
  only at MCP stream start, with safe initialization diagnostics instead of an
  opaque response-mismatch error.

## 0.6.0 - 2026-08-30

- Withdraw all 0.5.x artifacts from delivery until a packaged, clean-runner Windows
  PowerShell 5.1 lifecycle gate passes; local ZIP construction is now explicitly a
  release-candidate build rather than release evidence.
- Add a no-mailbox-side-effect Windows CI gate that parses every packaged
  PowerShell script, compiles the embedded Credential Manager helper, and exercises
  install, replacement install, MCP startup, reversible uninstall, reinstall, and
  final uninstall before artifact upload.
- Run the mutable lifecycle under a disposable non-administrator local account,
  because the elevated GitHub-hosted Windows identity would otherwise mask the
  user-profile ACL class of failures that triggered this release freeze.
- Stage activation files under the current user's Claude directory before the
  final rename so the installed tree does not preserve an unsuitable `%TEMP%` ACL.
- Make uninstall lock and ACL failures fail closed with the current Windows
  identity and actionable diagnostics instead of emitting a raw `Move-Item` error.
- Decode the UTF-8 MCP smoke-test stream explicitly so Windows legacy console code
  pages cannot drop responses containing the Chinese send-confirmation phrase.
- Carry the hosted-runner verification explicitly into the disposable user's
  process because alternate-credential launches do not reliably inherit GitHub's
  runner-only environment variables.
- Accept Windows CRLF at the embedded C# here-string terminator when the packaged
  PowerShell 5.1 gate extracts and compiles the Credential Manager helper.
- Write checksum sidecars as deterministic ASCII with an LF terminator instead of
  allowing Windows text-mode newline translation to break Unix `shasum -c`.
- Publish the exact post-gate ZIP and sidecar to an auditable private
  `gated-release` branch from a separate main-only, least-privilege job, allowing
  delivery without granting a general connector access to the repository.

## 0.5.3 - 2026-08-30

- Replace Python `--version` output parsing in both the installer and MCP launcher
  with a packaged no-output probe whose exit code expresses compatibility.
- Prevent redirected Windows PowerShell child processes from rejecting a valid
  interpreter merely because its version text was not captured, and add regression
  coverage for the probe and both launch paths.

## 0.5.2 - 2026-08-30

- Fix Windows PowerShell 5.1 compilation of the Credential Manager helper by
  explicitly selecting `System.Runtime.InteropServices.ComTypes.FILETIME` instead
  of relying on an ambiguous imported type name.
- Add a regression assertion for the fully qualified Win32 credential structure
  field and publish a replacement Windows release archive.

## 0.5.1 - 2026-08-30

- Fix Python version detection under Windows PowerShell 5.1 by using
  `python --version` instead of passing quote-sensitive inline code through
  `python -c`.
- Apply the same fix to both installation and normal MCP-server startup and add a
  regression assertion for both launch paths.

## 0.5.0 - 2026-08-30

- Add an interface-first `windows_simple_mapi` transport that accepts only a
  recognized Coremail default-client registration and attaches to an existing
  shared session with null credentials and no UI flags.
- Route INBOX search/read, explicit mark-read, and confirmed message submission
  through Simple MAPI while preserving unread state and session-scoped message
  identity.
- Make first-use setup probe the existing Coremail session automatically and fall
  back to explicit IMAP/SMTP plus a securely prompted domain/Coremail password only
  when the client interface is unusable.
- Keep IMAP/SMTP backward compatible as the default for existing configuration, and
  document Simple MAPI folder, draft, unread, attachment, threading, account, and
  process-bitness limitations.
- Preserve the immutable prepare/review/`确认发送` transaction and attachment hash
  verification for both transports.

## 0.4.0 - 2026-08-29

- Add top-level double-click installers for install, account reconfiguration, and
  reversible uninstall on Windows.
- Make installation transactional, automatically preserve recognized older plugin
  versions outside the skills discovery directory, and retain existing account
  configuration during upgrades.
- Add post-install offline MCP validation and a non-fatal live connection check.
- Add a reviewed allowlist release builder that emits a versioned Windows ZIP and
  adjacent SHA-256 file under `dist/`.
- Remove the PowerShell execution-policy bypass from launch and installation paths;
  organization policy remains authoritative.

## 0.3.0 - 2026-08-29

- Add a separate `web-to-coremail` skill for orchestrating an existing browser MCP
  without merging, launching, configuring, or depending on it.
- Define a one-way, bounded browser-result-to-email bridge with prompt-injection,
  privacy, attachment, source, and final-confirmation controls.
- Document operating-system isolation requirements for browser MCPs that are not
  fully trusted.
- Remove the `COREMAIL_PASSWORD` environment fallback so sibling MCP processes
  cannot inherit the mailbox password; Windows Credential Manager is now mandatory.

## 0.2.0 - 2026-08-29

- Replace the discarded desktop-automation prototype with a fully headless design.
- Add bounded, read-only local Coremail discovery with secret redaction.
- Add verified-TLS IMAP search/read/flag/draft operations and authenticated SMTP
  submission.
- Store the client-specific password in Windows Credential Manager.
- Add immutable prepared-message tokens, attachment hashing, and exact send
  confirmation.
- Add reversible personal-scope install/uninstall scripts, offline unit tests, and a
  Windows MCP launcher smoke test.
