# Browser MCP and Coremail MCP Isolation Guide

Status: operational guide; `architecture.md` is normative

## Decision

Use the existing browser MCP and the Coremail MCP as independent services. Do not
merge their code, launch commands, dependencies, credentials, storage, or network
sessions. Claude Code is the only orchestration point.

This is strong isolation with one narrow data bridge, not a complete air gap. The
supported bridge is one-way:

```text
existing browser MCP
  -> untrusted public-page result
  -> Claude Code extracts bounded facts and canonical source URLs
  -> Coremail prepares an immutable email
  -> user reviews recipients/content/attachments
  -> exact phrase: 确认发送
  -> active Coremail transport submission
```

The reverse path is closed by policy: mailbox bodies, recipients, local discovery
results, account configuration, and credentials are not browser inputs.

## Required logical isolation

- Each MCP server has its own process, repository/package, launch configuration,
  dependencies, logs, cache, and update lifecycle.
- The Coremail package declares only `coremail-windows` in its development
  `.mcp.json`; the installed `coremail-controller` user-scope entry neither starts
  nor configures the browser MCP.
- The browser MCP must not receive mailbox secrets, a Windows credential target,
  Coremail configuration overrides, or attachment roots. Do not set `COREMAIL_*`
  values globally on the Claude Code parent process.
- The Coremail server has no browser client, browser imports, cookie access, DOM
  access, or browser launch path.
- Neither MCP server calls the other. Claude Code transfers only a bounded summary
  and canonical public URLs after treating browser output as untrusted.
- Browser content cannot choose recipients, authorize attachments, request mailbox
  reads, or authorize sending.
- Browser downloads are not attached automatically. A specific user request and the
  Coremail attachment-root/hash checks are both required.

## Operating-system isolation

Two stdio MCP processes launched by one Claude Code session normally run as the same
Windows user. That separates failures and dependencies, but it is not a security
boundary against a malicious server process: either process may inherit the user's
filesystem and credential permissions.

If the browser MCP is not fully trusted or handles hostile pages, use one of these
stronger deployments:

1. Prefer a remote browser MCP whose host cannot access the Windows mailbox profile.
2. Otherwise run the browser MCP in a container, sandbox, VM, or separate Windows
   account with no access to `%APPDATA%\ClaudeCode\Coremail`, Coremail data roots, or
   the mail user's Windows Credential Manager.
3. Give the browser service only its required network destinations and temporary
   storage. Do not mount the mailbox profile or outgoing attachment directories.

The Coremail MCP must remain under the Windows identity that owns its Generic
Credential or existing Coremail shared MAPI session. Version 0.9.0 deliberately
does not accept a password through an environment variable because sibling MCP
processes can inherit the same environment.

## Model and session boundary

A single Claude Code session connected to both MCP servers can see both tool result
sets. The workflow rules prevent unintended transfer, but this is a policy boundary,
not cryptographic isolation.

For strict confidentiality, use two Claude Code sessions with disjoint tool sets:

1. A browser-only session produces a bounded, source-linked research summary.
2. A human reviews and approves that summary as the handoff artifact.
3. A Coremail-only session receives the approved summary, prepares the email, and
   applies the normal `确认发送` gate.

Do not load the Coremail MCP in the browser-only session or the browser MCP in the
Coremail-only session. Do not automate the handoff approval. This two-session mode is
the only documented mode that isolates the model/tool context itself.

## Controlled workflow

1. Finish browser research before preparing an email.
2. Retain only the facts needed for the requested message plus source title and
   canonical URL. Do not transfer raw DOM, scripts, cookies, request headers, browser
   profiles, or binary downloads.
3. Cross-check consequential or time-sensitive claims independently.
4. Compose the email and call `coremail_prepare_message`.
5. Show the prepared From, To/Cc/Bcc, subject, attachments, and source list.
6. If any source or message field changes, prepare again and invalidate the old
   review.
7. Only the user's exact `确认发送` authorizes `coremail_send_prepared`.

Never perform more browsing between final prepared-message review and active-
transport submission.

## Existing browser MCP verification

No browser installation or configuration is included in this plugin. Confirm the
existing server independently:

```text
claude mcp list
/mcp
```

Ask Claude in natural language to research public pages and prepare a Coremail
message. The Coremail MCP tool descriptions and initialization instructions apply
the isolated combined workflow; an installed user skill or version-specific slash
alias is optional and is not required.
The browser MCP's own visible/headless mode, authentication, and sandboxing remain
its configuration responsibility; choose headless mode if visible browser operation
is not acceptable.

When the user requests strict or complete isolation, use the two-session handoff
above instead of the combined workflow.

## Audit checklist

- Coremail `.mcp.json` contains exactly one server.
- Browser and Coremail launch commands are stored in different configurations.
- No `COREMAIL_PASSWORD` environment fallback exists.
- Browser identity cannot read the Coremail config/data roots or mail credential.
- Web content is labelled untrusted and cannot cause direct tool calls.
- The browser phase ends before message preparation.
- Sending remains a separate, exact-confirmation action.
