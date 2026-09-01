from __future__ import annotations

import base64
import ctypes
import datetime as dt
import hashlib
import html
import imaplib
import ipaddress
import json
import mimetypes
import os
import re
import secrets
import smtplib
import ssl
import tempfile
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from email import policy
from email.header import decode_header
from email.headerregistry import Address
from email.message import EmailMessage, Message
from email.parser import BytesParser
from email.utils import format_datetime, formataddr, getaddresses, make_msgid, parsedate_to_datetime
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterator, Mapping, Sequence

from windows_mapi import (
    INTERFACE_NAME as WINDOWS_MAPI_TRANSPORT,
    MAPI_BCC,
    MAPI_CC,
    MAPI_TO,
    SimpleMapiClient,
    WindowsMapiError,
    detect_coremail_mapi_registration,
)

SERVER_VERSION = "0.7.0"
DEFAULT_TOKEN_TTL_SECONDS = 15 * 60
DEFAULT_MAX_MESSAGE_BYTES = 10 * 1024 * 1024
DEFAULT_MAX_BODY_CHARS = 50_000
DEFAULT_MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024
DEFAULT_MAX_RECIPIENTS = 100
ROOT_CONFIG_FIELDS = {
    "transport",
    "username",
    "credential_target",
    "imap",
    "smtp",
    "allowed_from",
    "drafts_folder",
    "sent_folder",
    "sent_copy_mode",
    "ca_file",
    "attachment_roots",
    "max_message_bytes",
    "max_body_chars",
    "max_attachment_bytes",
    "max_recipients",
    "timeout_seconds",
}
ENDPOINT_CONFIG_FIELDS = {"host", "port", "security"}


class CoremailError(RuntimeError):
    """Base error safe to expose to the MCP caller."""


class ConfigError(CoremailError):
    pass


class CredentialError(CoremailError):
    pass


class MailConnectionError(CoremailError):
    pass


class MailProtocolError(CoremailError):
    pass


class StaleMessageError(CoremailError):
    pass


class PreparedMessageError(CoremailError):
    pass


@dataclass(frozen=True)
class Endpoint:
    host: str
    port: int
    security: str


@dataclass(frozen=True)
class Settings:
    config_path: Path
    transport: str
    username: str
    credential_target: str | None
    imap: Endpoint | None
    smtp: Endpoint | None
    allowed_from: tuple[str, ...]
    drafts_folder: str | None
    sent_folder: str | None
    sent_copy_mode: str
    ca_file: Path | None
    attachment_roots: tuple[Path, ...]
    max_message_bytes: int
    max_body_chars: int
    max_attachment_bytes: int
    max_recipients: int
    timeout_seconds: float

    def public_summary(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "config_path": str(self.config_path),
            "transport": self.transport,
            "username": self.username,
            "credential_target": self.credential_target,
            "allowed_from": list(self.allowed_from),
            "drafts_folder": self.drafts_folder,
            "sent_folder": self.sent_folder,
            "sent_copy_mode": self.sent_copy_mode,
            "ca_file": str(self.ca_file) if self.ca_file else None,
            "attachment_roots": [str(path) for path in self.attachment_roots],
            "limits": {
                "max_message_bytes": self.max_message_bytes,
                "max_body_chars": self.max_body_chars,
                "max_attachment_bytes": self.max_attachment_bytes,
                "max_recipients": self.max_recipients,
                "timeout_seconds": self.timeout_seconds,
            },
        }
        result["imap"] = (
            {"host": self.imap.host, "port": self.imap.port, "security": self.imap.security}
            if self.imap
            else None
        )
        result["smtp"] = (
            {"host": self.smtp.host, "port": self.smtp.port, "security": self.smtp.security}
            if self.smtp
            else None
        )
        return result


def default_config_path(environ: Mapping[str, str] | None = None) -> Path:
    env = os.environ if environ is None else environ
    appdata = env.get("APPDATA", "").strip()
    base = Path(appdata) if appdata else Path.home() / "AppData" / "Roaming"
    return (base / "ClaudeCode" / "Coremail" / "config.json").resolve()


def _required_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"Missing or empty configuration field: {field}")
    text = value.strip()
    if "\r" in text or "\n" in text:
        raise ConfigError(f"Configuration field contains a newline: {field}")
    return text


def _reject_unknown_fields(value: Mapping[str, Any], field: str, allowed: set[str]) -> None:
    unknown = sorted(str(key) for key in value if key not in allowed)
    if unknown:
        raise ConfigError(f"Unknown configuration field(s) in {field}: {', '.join(unknown)}")


def _hostname(value: Any, field: str) -> str:
    host = _required_text(value, field)
    if len(host) > 253 or any(character.isspace() for character in host):
        raise ConfigError(f"Invalid server hostname in {field}")
    if any(character in host for character in ("/", "\\", "@", "?", "#")) or "://" in host:
        raise ConfigError(f"{field} must be a hostname or IP address, not a URL")
    ip_candidate = host[1:-1] if host.startswith("[") and host.endswith("]") else host
    try:
        return str(ipaddress.ip_address(ip_candidate))
    except ValueError:
        if ":" in host or "[" in host or "]" in host:
            raise ConfigError(f"Invalid server hostname in {field}")
    try:
        ascii_host = host.rstrip(".").encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise ConfigError(f"Invalid server hostname in {field}") from exc
    labels = ascii_host.split(".")
    if not ascii_host or any(
        not label
        or len(label) > 63
        or label.startswith("-")
        or label.endswith("-")
        or re.fullmatch(r"[A-Za-z0-9-]+", label) is None
        for label in labels
    ):
        raise ConfigError(f"Invalid server hostname in {field}")
    return ascii_host


def _positive_int(value: Any, field: str, default: int, maximum: int) -> int:
    if value is None:
        return default
    if isinstance(value, bool):
        raise ConfigError(f"Configuration field must be an integer: {field}")
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"Configuration field must be an integer: {field}") from exc
    if number <= 0 or number > maximum:
        raise ConfigError(f"Configuration field is outside the supported range: {field}")
    return number


def _bounded_tool_int(value: Any, field: str, default: int, minimum: int, maximum: int) -> int:
    if value is None:
        return default
    if isinstance(value, bool):
        raise CoremailError(f"{field} must be an integer")
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise CoremailError(f"{field} must be an integer") from exc
    if number < minimum or number > maximum:
        raise CoremailError(f"{field} must be between {minimum} and {maximum}")
    return number


def _security(value: Any, field: str, default: str) -> str:
    mode = default if value is None else str(value).strip().lower()
    if mode not in {"ssl", "starttls"}:
        raise ConfigError(f"{field} must be 'ssl' or 'starttls'; plaintext is not supported")
    return mode


def _expand_path(value: str, base: Path) -> Path:
    expanded = Path(os.path.expandvars(os.path.expanduser(value)))
    if not expanded.is_absolute():
        expanded = base / expanded
    return expanded.resolve()


def load_settings(
    path: Path | str | None = None,
    environ: Mapping[str, str] | None = None,
) -> Settings:
    env = os.environ if environ is None else environ
    config_path = default_config_path(env) if path is None else Path(path).expanduser().resolve()
    if not config_path.is_file():
        raise ConfigError(
            f"Coremail account is not configured. Run scripts/setup-account.ps1. "
            f"Expected non-secret settings at: {config_path}"
        )
    try:
        raw = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ConfigError(f"Cannot read Coremail configuration: {config_path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ConfigError("Coremail configuration root must be a JSON object")
    _reject_unknown_fields(raw, "root", ROOT_CONFIG_FIELDS)

    transport = str(raw.get("transport", "imap_smtp")).strip().lower()
    if transport not in {"imap_smtp", WINDOWS_MAPI_TRANSPORT}:
        raise ConfigError(
            f"transport must be 'imap_smtp' or '{WINDOWS_MAPI_TRANSPORT}'"
        )
    username = _required_text(raw.get("username"), "username")
    imap_raw = raw.get("imap")
    smtp_raw = raw.get("smtp")
    imap: Endpoint | None = None
    smtp: Endpoint | None = None
    if transport == "imap_smtp":
        if not isinstance(imap_raw, dict) or not isinstance(smtp_raw, dict):
            raise ConfigError("Both imap and smtp configuration objects are required for imap_smtp")
        _reject_unknown_fields(imap_raw, "imap", ENDPOINT_CONFIG_FIELDS)
        _reject_unknown_fields(smtp_raw, "smtp", ENDPOINT_CONFIG_FIELDS)

        imap = Endpoint(
            host=_hostname(imap_raw.get("host"), "imap.host"),
            port=_positive_int(imap_raw.get("port"), "imap.port", 993, 65535),
            security=_security(imap_raw.get("security"), "imap.security", "ssl"),
        )
        smtp = Endpoint(
            host=_hostname(smtp_raw.get("host"), "smtp.host"),
            port=_positive_int(smtp_raw.get("port"), "smtp.port", 465, 65535),
            security=_security(smtp_raw.get("security"), "smtp.security", "ssl"),
        )
    elif imap_raw is not None or smtp_raw is not None:
        raise ConfigError(f"imap and smtp settings are not permitted for {WINDOWS_MAPI_TRANSPORT}")

    allowed_from_raw = raw.get("allowed_from", [username])
    if not isinstance(allowed_from_raw, list) or not allowed_from_raw:
        raise ConfigError("allowed_from must be a non-empty JSON array")
    allowed_from = tuple(_required_text(item, "allowed_from[]").lower() for item in allowed_from_raw)
    if transport == WINDOWS_MAPI_TRANSPORT and allowed_from != (username.lower(),):
        raise ConfigError(
            f"allowed_from must contain only username for {WINDOWS_MAPI_TRANSPORT}"
        )

    sent_copy_mode = str(raw.get("sent_copy_mode", "none")).strip().lower()
    if sent_copy_mode not in {"none", "append"}:
        raise ConfigError("sent_copy_mode must be 'none' or 'append'")
    if transport == WINDOWS_MAPI_TRANSPORT and sent_copy_mode != "none":
        raise ConfigError(f"sent_copy_mode must be 'none' for {WINDOWS_MAPI_TRANSPORT}")

    ca_file_raw = raw.get("ca_file")
    ca_file = _expand_path(ca_file_raw, config_path.parent) if isinstance(ca_file_raw, str) and ca_file_raw.strip() else None
    if ca_file is not None and not ca_file.is_file():
        raise ConfigError(f"Configured CA file does not exist: {ca_file}")
    if transport == WINDOWS_MAPI_TRANSPORT and ca_file_raw is not None:
        raise ConfigError(f"ca_file is not permitted for {WINDOWS_MAPI_TRANSPORT}")

    roots: list[Path] = []
    configured_roots = raw.get("attachment_roots", [])
    if not isinstance(configured_roots, list):
        raise ConfigError("attachment_roots must be a JSON array")
    for item in configured_roots:
        roots.append(_expand_path(_required_text(item, "attachment_roots[]"), config_path.parent))
    project_dir = env.get("CLAUDE_PROJECT_DIR", "").strip()
    if project_dir:
        roots.append(Path(project_dir).expanduser().resolve())
    unique_roots: list[Path] = []
    seen_roots: set[str] = set()
    for root in roots:
        key = os.path.normcase(str(root))
        if key not in seen_roots:
            seen_roots.add(key)
            unique_roots.append(root)

    credential_target_raw = raw.get("credential_target")
    if transport == "imap_smtp":
        credential_target = str(
            credential_target_raw if credential_target_raw is not None else f"ClaudeCode.Coremail:{username}"
        ).strip()
        if not credential_target:
            raise ConfigError("credential_target must not be empty")
    else:
        if credential_target_raw is not None:
            raise ConfigError(f"credential_target is not permitted for {WINDOWS_MAPI_TRANSPORT}")
        credential_target = None

    drafts_folder = raw.get("drafts_folder")
    sent_folder = raw.get("sent_folder")
    if drafts_folder is not None:
        drafts_folder = _required_text(drafts_folder, "drafts_folder")
    if sent_folder is not None:
        sent_folder = _required_text(sent_folder, "sent_folder")
    if transport == WINDOWS_MAPI_TRANSPORT and (drafts_folder is not None or sent_folder is not None):
        raise ConfigError(f"drafts_folder and sent_folder are not permitted for {WINDOWS_MAPI_TRANSPORT}")

    try:
        timeout_seconds = float(raw.get("timeout_seconds", 20.0))
    except (TypeError, ValueError) as exc:
        raise ConfigError("timeout_seconds must be numeric") from exc
    if timeout_seconds < 1 or timeout_seconds > 120:
        raise ConfigError("timeout_seconds must be between 1 and 120")

    return Settings(
        config_path=config_path,
        transport=transport,
        username=username,
        credential_target=credential_target,
        imap=imap,
        smtp=smtp,
        allowed_from=allowed_from,
        drafts_folder=drafts_folder,
        sent_folder=sent_folder,
        sent_copy_mode=sent_copy_mode,
        ca_file=ca_file,
        attachment_roots=tuple(unique_roots),
        max_message_bytes=_positive_int(
            raw.get("max_message_bytes"), "max_message_bytes", DEFAULT_MAX_MESSAGE_BYTES, 100 * 1024 * 1024
        ),
        max_body_chars=_positive_int(raw.get("max_body_chars"), "max_body_chars", DEFAULT_MAX_BODY_CHARS, 500_000),
        max_attachment_bytes=_positive_int(
            raw.get("max_attachment_bytes"),
            "max_attachment_bytes",
            DEFAULT_MAX_ATTACHMENT_BYTES,
            100 * 1024 * 1024,
        ),
        max_recipients=_positive_int(raw.get("max_recipients"), "max_recipients", DEFAULT_MAX_RECIPIENTS, 500),
        timeout_seconds=timeout_seconds,
    )


class _CREDENTIALW(ctypes.Structure):
    _fields_ = [
        ("Flags", ctypes.c_uint32),
        ("Type", ctypes.c_uint32),
        ("TargetName", ctypes.c_wchar_p),
        ("Comment", ctypes.c_wchar_p),
        ("LastWrittenLow", ctypes.c_uint32),
        ("LastWrittenHigh", ctypes.c_uint32),
        ("CredentialBlobSize", ctypes.c_uint32),
        ("CredentialBlob", ctypes.c_void_p),
        ("Persist", ctypes.c_uint32),
        ("AttributeCount", ctypes.c_uint32),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", ctypes.c_wchar_p),
        ("UserName", ctypes.c_wchar_p),
    ]


def read_windows_credential(target: str) -> str:
    if os.name != "nt":
        raise CredentialError("Windows Credential Manager is available only on Windows")
    advapi32 = ctypes.WinDLL("Advapi32.dll", use_last_error=True)
    credential_pointer = ctypes.POINTER(_CREDENTIALW)()
    advapi32.CredReadW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    advapi32.CredReadW.restype = ctypes.c_int
    advapi32.CredFree.argtypes = [ctypes.c_void_p]
    advapi32.CredFree.restype = None
    if not advapi32.CredReadW(target, 1, 0, ctypes.byref(credential_pointer)):
        error_code = ctypes.get_last_error()
        raise CredentialError(
            f"Windows credential '{target}' is unavailable (error {error_code}). "
            "Run scripts/setup-account.ps1 to create or update it."
        )
    try:
        credential = credential_pointer.contents
        blob = ctypes.string_at(credential.CredentialBlob, credential.CredentialBlobSize)
        if not blob:
            raise CredentialError(f"Windows credential '{target}' contains an empty password")
        try:
            password = blob.decode("utf-16-le").rstrip("\x00")
        except UnicodeDecodeError:
            password = blob.decode("utf-8")
        if not password:
            raise CredentialError(f"Windows credential '{target}' contains an empty password")
        return password
    finally:
        advapi32.CredFree(credential_pointer)


def get_password(settings: Settings) -> str:
    if settings.transport != "imap_smtp" or not settings.credential_target:
        raise ConfigError("Windows Credential Manager is used only by the imap_smtp transport")
    return read_windows_credential(settings.credential_target)


def credential_available(settings: Settings) -> bool:
    if settings.transport != "imap_smtp":
        return False
    try:
        password = get_password(settings)
        return bool(password)
    except CredentialError:
        return False


def tls_context(settings: Settings) -> ssl.SSLContext:
    context = ssl.create_default_context()
    if settings.ca_file:
        context.load_verify_locations(cafile=str(settings.ca_file))
    if hasattr(ssl, "TLSVersion"):
        context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


@contextmanager
def imap_session(settings: Settings) -> Iterator[imaplib.IMAP4]:
    if settings.transport != "imap_smtp" or settings.imap is None:
        raise ConfigError("IMAP is unavailable for the selected transport")
    password = get_password(settings)
    client: imaplib.IMAP4 | None = None
    try:
        context = tls_context(settings)
        if settings.imap.security == "ssl":
            client = imaplib.IMAP4_SSL(
                settings.imap.host,
                settings.imap.port,
                ssl_context=context,
                timeout=settings.timeout_seconds,
            )
        else:
            client = imaplib.IMAP4(settings.imap.host, settings.imap.port, timeout=settings.timeout_seconds)
            client.starttls(ssl_context=context)
        status, _ = client.login(settings.username, password)
        if status != "OK":
            raise MailProtocolError("IMAP authentication was not accepted")
        yield client
    except (CredentialError, ConfigError, MailProtocolError):
        raise
    except imaplib.IMAP4.error as exc:
        raise MailProtocolError(f"IMAP server rejected the operation: {_safe_protocol_text(exc)}") from exc
    except (OSError, ssl.SSLError) as exc:
        raise MailConnectionError(f"IMAP connection failed: {_safe_protocol_text(exc)}") from exc
    finally:
        if client is not None:
            try:
                client.logout()
            except Exception:
                pass


@contextmanager
def smtp_session(settings: Settings) -> Iterator[smtplib.SMTP]:
    if settings.transport != "imap_smtp" or settings.smtp is None:
        raise ConfigError("SMTP is unavailable for the selected transport")
    password = get_password(settings)
    client: smtplib.SMTP | None = None
    try:
        context = tls_context(settings)
        if settings.smtp.security == "ssl":
            client = smtplib.SMTP_SSL(
                settings.smtp.host,
                settings.smtp.port,
                timeout=settings.timeout_seconds,
                context=context,
            )
        else:
            client = smtplib.SMTP(settings.smtp.host, settings.smtp.port, timeout=settings.timeout_seconds)
            client.ehlo()
            client.starttls(context=context)
            client.ehlo()
        client.login(settings.username, password)
    except (CredentialError, ConfigError):
        raise
    except smtplib.SMTPAuthenticationError as exc:
        raise MailProtocolError(f"SMTP authentication failed (code {exc.smtp_code})") from exc
    except smtplib.SMTPException as exc:
        raise MailProtocolError(f"SMTP server rejected the operation: {_safe_protocol_text(exc)}") from exc
    except (OSError, ssl.SSLError) as exc:
        raise MailConnectionError(f"SMTP connection failed: {_safe_protocol_text(exc)}") from exc

    try:
        if client is None:
            raise MailConnectionError("SMTP connection was not initialized")
        yield client
    finally:
        if client is not None:
            try:
                client.quit()
            except Exception:
                try:
                    client.close()
                except Exception:
                    pass


def _safe_protocol_text(value: Any, limit: int = 300) -> str:
    text = str(value).replace("\r", " ").replace("\n", " ")
    text = re.sub(r"(?i)(password|passwd|pwd|authorization)\s*[:=]\s*\S+", r"\1=<redacted>", text)
    return text[:limit]


def imap_utf7_encode(value: str) -> str:
    output: list[str] = []
    buffer: list[str] = []

    def flush() -> None:
        if not buffer:
            return
        raw = "".join(buffer).encode("utf-16-be")
        encoded = base64.b64encode(raw).decode("ascii").rstrip("=").replace("/", ",")
        output.append("&" + encoded + "-")
        buffer.clear()

    for character in value:
        code = ord(character)
        if 0x20 <= code <= 0x7E and character != "&":
            flush()
            output.append(character)
        elif character == "&":
            flush()
            output.append("&-")
        else:
            buffer.append(character)
    flush()
    return "".join(output)


def imap_utf7_decode(value: str) -> str:
    output: list[str] = []
    index = 0
    while index < len(value):
        if value[index] != "&":
            output.append(value[index])
            index += 1
            continue
        end = value.find("-", index)
        if end < 0:
            raise MailProtocolError("Malformed modified UTF-7 mailbox name")
        payload = value[index + 1 : end]
        if not payload:
            output.append("&")
        else:
            standard = payload.replace(",", "/")
            standard += "=" * ((4 - len(standard) % 4) % 4)
            try:
                output.append(base64.b64decode(standard).decode("utf-16-be"))
            except (ValueError, UnicodeDecodeError) as exc:
                raise MailProtocolError("Malformed modified UTF-7 mailbox name") from exc
        index = end + 1
    return "".join(output)


def _imap_quoted(value: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 1000:
        raise CoremailError("IMAP folder name must be a non-empty string of at most 1000 characters")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise CoremailError("IMAP folder name contains a control character")
    encoded = imap_utf7_encode(value)
    return '"' + encoded.replace("\\", "\\\\").replace('"', '\\"') + '"'


_LIST_RE = re.compile(r'^\((?P<flags>[^)]*)\)\s+(?P<delimiter>NIL|"(?:\\.|[^"])*")\s+(?P<name>.+)$')


def _unquote_imap(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
        value = re.sub(r"\\(.)", r"\1", value)
    return value


def list_folders_with_client(client: imaplib.IMAP4) -> list[dict[str, Any]]:
    status, rows = client.list()
    if status != "OK" or rows is None:
        raise MailProtocolError("IMAP LIST failed")
    folders: list[dict[str, Any]] = []
    for row in rows:
        if row is None:
            continue
        text = row.decode("utf-8", errors="replace") if isinstance(row, bytes) else str(row)
        match = _LIST_RE.match(text)
        if not match:
            folders.append({"name": text, "raw_name": text, "flags": [], "delimiter": None, "parse_warning": True})
            continue
        raw_name = _unquote_imap(match.group("name"))
        try:
            name = imap_utf7_decode(raw_name)
        except CoremailError:
            name = raw_name
        delimiter_raw = match.group("delimiter")
        delimiter = None if delimiter_raw == "NIL" else _unquote_imap(delimiter_raw)
        flags = [flag for flag in match.group("flags").split() if flag]
        folders.append({"name": name, "raw_name": raw_name, "flags": flags, "delimiter": delimiter})
    return folders


def _uidvalidity(client: imaplib.IMAP4) -> str | None:
    response = client.response("UIDVALIDITY")
    if not response or not response[1]:
        return None
    value = response[1][0]
    if isinstance(value, bytes):
        value = value.decode("ascii", errors="replace")
    return str(value)


def select_folder(
    client: imaplib.IMAP4,
    folder: str,
    readonly: bool,
    expected_uidvalidity: str | None = None,
) -> dict[str, Any]:
    status, data = client.select(_imap_quoted(folder), readonly=readonly)
    if status != "OK":
        raise MailProtocolError(f"Cannot select IMAP folder: {folder}")
    current_uidvalidity = _uidvalidity(client)
    if expected_uidvalidity is not None and str(expected_uidvalidity) != str(current_uidvalidity):
        raise StaleMessageError(
            f"Folder UIDVALIDITY changed for {folder}; search again before acting on a UID"
        )
    count = 0
    if data and data[0] is not None:
        try:
            count = int(data[0])
        except (TypeError, ValueError):
            count = 0
    return {"folder": folder, "uidvalidity": current_uidvalidity, "message_count": count}


def _imap_date(value: str, field: str) -> str:
    try:
        parsed = dt.date.fromisoformat(value)
    except ValueError as exc:
        raise CoremailError(f"{field} must be an ISO date in YYYY-MM-DD form") from exc
    months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    return f"{parsed.day:02d}-{months[parsed.month - 1]}-{parsed.year:04d}"


def _search_quoted(value: str, field: str) -> str:
    if "\r" in value or "\n" in value:
        raise CoremailError(f"Search field contains a newline: {field}")
    if len(value) > 500:
        raise CoremailError(f"Search field is too long: {field}")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _enable_utf8_if_possible(client: imaplib.IMAP4) -> bool:
    capabilities = {item.upper() for item in getattr(client, "capabilities", ())}
    if b"UTF8=ACCEPT" not in capabilities and "UTF8=ACCEPT" not in capabilities:
        return False
    try:
        status, _ = client.enable("UTF8=ACCEPT")
        return status == "OK"
    except (imaplib.IMAP4.error, AttributeError):
        return False


def _uid_search(client: imaplib.IMAP4, criteria: Sequence[str]) -> list[str]:
    contains_unicode = any(any(ord(character) > 127 for character in item) for item in criteria)
    if contains_unicode and _enable_utf8_if_possible(client):
        status, data = client.uid("SEARCH", None, *criteria)
    elif contains_unicode:
        encoded = [item.encode("utf-8") for item in criteria]
        status, data = client.uid("SEARCH", "CHARSET", "UTF-8", *encoded)
    else:
        status, data = client.uid("SEARCH", None, *criteria)
    if status != "OK" or not data:
        raise MailProtocolError("IMAP UID SEARCH failed")
    raw = data[0] or b""
    text = raw.decode("ascii", errors="ignore") if isinstance(raw, bytes) else str(raw)
    return [uid for uid in text.split() if uid.isdigit()]


def _decode_header_value(value: str | None) -> str:
    if not value:
        return ""
    fragments: list[str] = []
    for fragment, encoding in decode_header(value):
        if isinstance(fragment, bytes):
            for candidate in (encoding, "utf-8", "gb18030", "latin-1"):
                if not candidate:
                    continue
                try:
                    fragments.append(fragment.decode(candidate, errors="strict"))
                    break
                except (LookupError, UnicodeDecodeError):
                    continue
            else:
                fragments.append(fragment.decode("utf-8", errors="replace"))
        else:
            fragments.append(fragment)
    return "".join(fragments)


def _date_iso(value: str | None) -> str | None:
    if not value:
        return None
    try:
        parsed = parsedate_to_datetime(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.isoformat()
    except (TypeError, ValueError, OverflowError):
        return value


_UID_RE = re.compile(rb"\bUID\s+(\d+)\b")
_SIZE_RE = re.compile(rb"\bRFC822\.SIZE\s+(\d+)\b")
_FLAGS_RE = re.compile(rb"\bFLAGS\s+\(([^)]*)\)")


def _fetch_payload(rows: Sequence[Any]) -> tuple[bytes, bytes]:
    metadata = b""
    payload = b""
    for row in rows:
        if isinstance(row, tuple) and len(row) >= 2:
            if isinstance(row[0], bytes):
                metadata += row[0]
            if isinstance(row[1], bytes):
                payload += row[1]
        elif isinstance(row, bytes):
            metadata += row
    return metadata, payload


def _fetch_header(client: imaplib.IMAP4, uid: str) -> dict[str, Any]:
    status, rows = client.uid(
        "FETCH",
        uid,
        "(BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES)] FLAGS RFC822.SIZE)",
    )
    if status != "OK" or rows is None:
        raise MailProtocolError(f"IMAP FETCH failed for UID {uid}")
    metadata, payload = _fetch_payload(rows)
    if not payload:
        raise MailProtocolError(f"Message UID {uid} was not found")
    message = BytesParser(policy=policy.default).parsebytes(payload, headersonly=True)
    uid_match = _UID_RE.search(metadata)
    size_match = _SIZE_RE.search(metadata)
    flags_match = _FLAGS_RE.search(metadata)
    flags = []
    if flags_match:
        flags = [item.decode("ascii", errors="replace") for item in flags_match.group(1).split()]
    return {
        "uid": uid_match.group(1).decode("ascii") if uid_match else uid,
        "subject": _decode_header_value(message.get("Subject")),
        "from": _decode_header_value(message.get("From")),
        "to": _decode_header_value(message.get("To")),
        "cc": _decode_header_value(message.get("Cc")),
        "date": _date_iso(message.get("Date")),
        "message_id": message.get("Message-ID"),
        "in_reply_to": message.get("In-Reply-To"),
        "references": message.get("References"),
        "flags": flags,
        "size": int(size_match.group(1)) if size_match else None,
    }


def search_messages_with_client(
    client: imaplib.IMAP4,
    *,
    folder: str,
    query: Mapping[str, Any],
    limit: int,
) -> dict[str, Any]:
    if limit < 1 or limit > 100:
        raise CoremailError("limit must be between 1 and 100")
    allowed_query_fields = {"from", "to", "subject", "text", "since", "before", "unseen", "flagged"}
    unknown_query_fields = sorted(str(field) for field in query if field not in allowed_query_fields)
    if unknown_query_fields:
        raise CoremailError(f"Unknown search query field(s): {', '.join(unknown_query_fields)}")
    selected = select_folder(client, folder, readonly=True)
    criteria: list[str] = []
    mapping = (
        ("from", "FROM"),
        ("to", "TO"),
        ("subject", "SUBJECT"),
        ("text", "TEXT"),
    )
    for field, atom in mapping:
        value = query.get(field)
        if value is not None:
            if not isinstance(value, str):
                raise CoremailError(f"Search field must be a string: {field}")
            if value.strip():
                criteria.extend((atom, _search_quoted(value.strip(), field)))
    if query.get("since"):
        if not isinstance(query["since"], str):
            raise CoremailError("Search field must be a string: since")
        criteria.extend(("SINCE", _imap_date(str(query["since"]), "since")))
    if query.get("before"):
        if not isinstance(query["before"], str):
            raise CoremailError("Search field must be a string: before")
        criteria.extend(("BEFORE", _imap_date(str(query["before"]), "before")))
    for boolean_field in ("unseen", "flagged"):
        if boolean_field in query and not isinstance(query[boolean_field], bool):
            raise CoremailError(f"Search field must be true or false: {boolean_field}")
    if query.get("unseen") is True:
        criteria.append("UNSEEN")
    elif query.get("unseen") is False:
        criteria.append("SEEN")
    if query.get("flagged") is True:
        criteria.append("FLAGGED")
    elif query.get("flagged") is False:
        criteria.append("UNFLAGGED")
    if not criteria:
        criteria.append("ALL")

    uids = _uid_search(client, criteria)
    selected_uids = sorted(uids, key=int, reverse=True)[:limit]
    messages = [_fetch_header(client, uid) for uid in selected_uids]
    return {
        **selected,
        "criteria": dict(query),
        "matched_count": len(uids),
        "returned_count": len(messages),
        "messages": messages,
    }


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.ignored_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"script", "style", "noscript"}:
            self.ignored_depth += 1
        elif self.ignored_depth == 0 and tag in {"br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript"} and self.ignored_depth:
            self.ignored_depth -= 1
        elif self.ignored_depth == 0 and tag in {"p", "div", "li", "tr"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self.ignored_depth == 0:
            self.parts.append(data)

    def text(self) -> str:
        value = html.unescape("".join(self.parts)).replace("\r\n", "\n").replace("\r", "\n")
        value = re.sub(r"[ \t]+", " ", value)
        value = re.sub(r"\n{3,}", "\n\n", value)
        return value.strip()


def _html_to_text(value: str) -> str:
    parser = _TextExtractor()
    parser.feed(value)
    parser.close()
    return parser.text()


def _part_text(part: Message) -> str:
    try:
        return part.get_content()
    except (LookupError, UnicodeDecodeError, AttributeError):
        payload = part.get_payload(decode=True) or b""
        charset = part.get_content_charset() or "utf-8"
        for candidate in (charset, "utf-8", "gb18030", "latin-1"):
            try:
                return payload.decode(candidate)
            except (LookupError, UnicodeDecodeError):
                continue
        return payload.decode("utf-8", errors="replace")


def parse_message(raw: bytes, max_body_chars: int) -> dict[str, Any]:
    message = BytesParser(policy=policy.default).parsebytes(raw)
    plain_parts: list[str] = []
    html_parts: list[str] = []
    attachments: list[dict[str, Any]] = []

    parts: Sequence[Message] = list(message.walk()) if message.is_multipart() else [message]
    for part in parts:
        if part.is_multipart():
            continue
        disposition = part.get_content_disposition()
        filename = part.get_filename()
        content_type = part.get_content_type()
        if disposition == "attachment" or filename:
            payload = part.get_payload(decode=True) or b""
            attachments.append(
                {
                    "filename": _decode_header_value(filename),
                    "content_type": content_type,
                    "size": len(payload),
                    "content_id": part.get("Content-ID"),
                }
            )
            continue
        if content_type == "text/plain":
            plain_parts.append(_part_text(part))
        elif content_type == "text/html":
            html_parts.append(_part_text(part))

    body = "\n\n".join(part.strip() for part in plain_parts if part.strip())
    body_source = "text/plain"
    if not body and html_parts:
        body = _html_to_text("\n".join(html_parts))
        body_source = "text/html converted to text"
    truncated = len(body) > max_body_chars
    if truncated:
        body = body[:max_body_chars] + "…"

    return {
        "subject": _decode_header_value(message.get("Subject")),
        "from": _decode_header_value(message.get("From")),
        "to": _decode_header_value(message.get("To")),
        "cc": _decode_header_value(message.get("Cc")),
        "bcc": _decode_header_value(message.get("Bcc")),
        "reply_to": _decode_header_value(message.get("Reply-To")),
        "date": _date_iso(message.get("Date")),
        "message_id": message.get("Message-ID"),
        "in_reply_to": message.get("In-Reply-To"),
        "references": message.get("References"),
        "body": body,
        "body_source": body_source,
        "body_truncated": truncated,
        "attachments": attachments,
        "content_is_untrusted": True,
    }


def get_message_with_client(
    client: imaplib.IMAP4,
    *,
    folder: str,
    uid: str,
    expected_uidvalidity: str | None,
    max_message_bytes: int,
    max_body_chars: int,
) -> dict[str, Any]:
    if not str(uid).isdigit():
        raise CoremailError("uid must contain decimal digits only")
    selected = select_folder(client, folder, readonly=True, expected_uidvalidity=expected_uidvalidity)
    status, size_rows = client.uid("FETCH", str(uid), "(RFC822.SIZE FLAGS)")
    if status != "OK" or not size_rows:
        raise MailProtocolError(f"Cannot fetch metadata for message UID {uid}")
    size_metadata, _ = _fetch_payload(size_rows)
    size_match = _SIZE_RE.search(size_metadata)
    size = int(size_match.group(1)) if size_match else None
    if size is not None and size > max_message_bytes:
        raise CoremailError(
            f"Message size {size} exceeds the configured read limit {max_message_bytes}; increase it deliberately if needed"
        )
    status, rows = client.uid("FETCH", str(uid), "(BODY.PEEK[] FLAGS RFC822.SIZE)")
    if status != "OK" or rows is None:
        raise MailProtocolError(f"Cannot fetch message UID {uid}")
    metadata, raw = _fetch_payload(rows)
    if not raw:
        raise MailProtocolError(f"Message UID {uid} was not found")
    if len(raw) > max_message_bytes:
        raise CoremailError("Fetched message exceeds the configured read limit")
    flags_match = _FLAGS_RE.search(metadata)
    flags = []
    if flags_match:
        flags = [item.decode("ascii", errors="replace") for item in flags_match.group(1).split()]
    return {
        **selected,
        "uid": str(uid),
        "size": size if size is not None else len(raw),
        "flags": flags,
        **parse_message(raw, max_body_chars),
    }


def set_seen_with_client(
    client: imaplib.IMAP4,
    *,
    folder: str,
    uid: str,
    expected_uidvalidity: str | None,
    seen: bool,
) -> dict[str, Any]:
    if not str(uid).isdigit():
        raise CoremailError("uid must contain decimal digits only")
    selected = select_folder(client, folder, readonly=False, expected_uidvalidity=expected_uidvalidity)
    operation = "+FLAGS.SILENT" if seen else "-FLAGS.SILENT"
    status, _ = client.uid("STORE", str(uid), operation, "(\\Seen)")
    if status != "OK":
        raise MailProtocolError(f"Cannot update seen state for message UID {uid}")
    return {**selected, "uid": str(uid), "seen": seen, "updated": True}


def _extract_addr_spec(value: str, field: str) -> str:
    parsed = getaddresses([value])
    if len(parsed) != 1 or not parsed[0][1]:
        raise CoremailError(f"Invalid email address in {field}: {value}")
    address = parsed[0][1]
    if "\r" in address or "\n" in address or "@" not in address:
        raise CoremailError(f"Invalid email address in {field}: {value}")
    try:
        Address(addr_spec=address)
    except Exception as exc:
        raise CoremailError(f"Invalid email address in {field}: {value}") from exc
    return address


def _normalize_addresses(values: Any, field: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if values is None:
        return (), ()
    if not isinstance(values, list):
        raise CoremailError(f"{field} must be an array of email address strings")
    formatted: list[str] = []
    envelope: list[str] = []
    for item in values:
        if not isinstance(item, str) or not item.strip() or "\r" in item or "\n" in item:
            raise CoremailError(f"Invalid value in {field}")
        parsed = getaddresses([item])
        if len(parsed) != 1 or not parsed[0][1]:
            raise CoremailError(f"Invalid email address in {field}: {item}")
        display_name, address = parsed[0]
        _extract_addr_spec(address, field)
        formatted.append(formataddr((display_name, address), charset="utf-8") if display_name else address)
        envelope.append(address)
    return tuple(formatted), tuple(envelope)


def _safe_header(value: Any, field: str, maximum: int = 998) -> str:
    if value is None:
        return ""
    text = str(value)
    if "\r" in text or "\n" in text:
        raise CoremailError(f"{field} must not contain newlines")
    if len(text) > maximum:
        raise CoremailError(f"{field} exceeds the {maximum}-character limit")
    return text


def _path_within(path: Path, roots: Sequence[Path]) -> bool:
    for root in roots:
        try:
            path.relative_to(root.resolve())
            return True
        except ValueError:
            continue
    return False


@dataclass(frozen=True)
class AttachmentSpec:
    path: Path
    filename: str
    size: int
    sha256: str

    def summary(self) -> dict[str, Any]:
        return {"path": str(self.path), "filename": self.filename, "size": self.size, "sha256": self.sha256}


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _prepare_attachments(settings: Settings, values: Any) -> tuple[AttachmentSpec, ...]:
    if values is None:
        return ()
    if not isinstance(values, list):
        raise CoremailError("attachments must be an array of file paths")
    if values and not settings.attachment_roots:
        raise CoremailError(
            "No outgoing attachment roots are authorized. Configure attachment_roots or run Claude Code from a project directory."
        )
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "").strip()
    base = Path(project_dir).resolve() if project_dir else settings.config_path.parent
    attachments: list[AttachmentSpec] = []
    total = 0
    for raw_path in values:
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise CoremailError("Each attachment must be a non-empty file path")
        candidate = Path(os.path.expandvars(os.path.expanduser(raw_path.strip())))
        if not candidate.is_absolute():
            candidate = base / candidate
        try:
            resolved = candidate.resolve(strict=True)
        except OSError as exc:
            raise CoremailError(f"Attachment does not exist or cannot be resolved: {candidate}") from exc
        if not resolved.is_file():
            raise CoremailError(f"Attachment is not a regular file: {resolved}")
        if not _path_within(resolved, settings.attachment_roots):
            raise CoremailError(f"Attachment is outside the authorized roots: {resolved}")
        size = resolved.stat().st_size
        total += size
        if total > settings.max_attachment_bytes:
            raise CoremailError(
                f"Total attachment size exceeds the configured limit {settings.max_attachment_bytes} bytes"
            )
        attachments.append(
            AttachmentSpec(path=resolved, filename=resolved.name, size=size, sha256=_hash_file(resolved))
        )
    return tuple(attachments)


@dataclass(frozen=True)
class PreparedMessage:
    from_header: str
    from_address: str
    to_headers: tuple[str, ...]
    to_addresses: tuple[str, ...]
    cc_headers: tuple[str, ...]
    cc_addresses: tuple[str, ...]
    bcc_headers: tuple[str, ...]
    bcc_addresses: tuple[str, ...]
    subject: str
    body_text: str
    in_reply_to: str
    references: str
    attachments: tuple[AttachmentSpec, ...]
    message_id: str
    date: dt.datetime

    @property
    def all_recipients(self) -> tuple[str, ...]:
        return self.to_addresses + self.cc_addresses + self.bcc_addresses

    def summary(self, settings: Settings) -> dict[str, Any]:
        return {
            "transport": settings.transport,
            "from": self.from_header,
            "to": list(self.to_headers),
            "cc": list(self.cc_headers),
            "bcc": list(self.bcc_headers),
            "subject": self.subject,
            "body_character_count": len(self.body_text),
            "in_reply_to": self.in_reply_to or None,
            "references": self.references or None,
            "attachments": [attachment.summary() for attachment in self.attachments],
            "message_id": self.message_id,
            "date": self.date.isoformat(),
            "sent_copy_mode": settings.sent_copy_mode,
            "prepared_only": True,
        }


def prepare_message(settings: Settings, arguments: Mapping[str, Any]) -> PreparedMessage:
    from_value = str(arguments.get("from", settings.username)).strip()
    from_address = _extract_addr_spec(from_value, "from")
    if from_address.lower() not in settings.allowed_from:
        raise CoremailError(
            f"From address is not allowlisted: {from_address}. Allowed values: {', '.join(settings.allowed_from)}"
        )
    parsed_from = getaddresses([from_value])[0]
    from_header = formataddr(parsed_from, charset="utf-8") if parsed_from[0] else from_address

    to_headers, to_addresses = _normalize_addresses(arguments.get("to"), "to")
    cc_headers, cc_addresses = _normalize_addresses(arguments.get("cc"), "cc")
    bcc_headers, bcc_addresses = _normalize_addresses(arguments.get("bcc"), "bcc")
    recipient_count = len(to_addresses) + len(cc_addresses) + len(bcc_addresses)
    if recipient_count == 0:
        raise CoremailError("At least one To, Cc, or Bcc recipient is required")
    if recipient_count > settings.max_recipients:
        raise CoremailError(f"Recipient count exceeds the configured limit {settings.max_recipients}")

    subject_limit = 255 if settings.transport == WINDOWS_MAPI_TRANSPORT else 500
    subject = _safe_header(arguments.get("subject", ""), "subject", subject_limit)
    body_text = arguments.get("body_text", "")
    if not isinstance(body_text, str):
        raise CoremailError("body_text must be a string")
    if len(body_text) > 500_000:
        raise CoremailError("body_text exceeds the 500000-character limit")
    in_reply_to = _safe_header(arguments.get("in_reply_to", ""), "in_reply_to")
    references = _safe_header(arguments.get("references", ""), "references", 4000)
    attachments = _prepare_attachments(settings, arguments.get("attachments"))

    domain = from_address.rsplit("@", 1)[1]
    return PreparedMessage(
        from_header=from_header,
        from_address=from_address,
        to_headers=to_headers,
        to_addresses=to_addresses,
        cc_headers=cc_headers,
        cc_addresses=cc_addresses,
        bcc_headers=bcc_headers,
        bcc_addresses=bcc_addresses,
        subject=subject,
        body_text=body_text,
        in_reply_to=in_reply_to,
        references=references,
        attachments=attachments,
        message_id=make_msgid(domain=domain),
        date=dt.datetime.now(dt.timezone.utc),
    )


@dataclass
class _PreparedEntry:
    message: PreparedMessage
    expires_at: float


class PreparedStore:
    def __init__(self, ttl_seconds: int = DEFAULT_TOKEN_TTL_SECONDS) -> None:
        self._ttl_seconds = ttl_seconds
        self._entries: dict[str, _PreparedEntry] = {}
        self._lock = threading.Lock()

    def _cleanup(self, now: float) -> None:
        expired = [token for token, entry in self._entries.items() if entry.expires_at <= now]
        for token in expired:
            del self._entries[token]

    def put(self, message: PreparedMessage) -> tuple[str, float]:
        now = time.monotonic()
        token = secrets.token_urlsafe(32)
        expires_at = now + self._ttl_seconds
        with self._lock:
            self._cleanup(now)
            self._entries[token] = _PreparedEntry(message=message, expires_at=expires_at)
        return token, expires_at

    def get(self, token: str) -> PreparedMessage:
        now = time.monotonic()
        with self._lock:
            self._cleanup(now)
            entry = self._entries.get(token)
            if entry is None:
                raise PreparedMessageError("Prepared message token is missing, expired, consumed, or belongs to another session")
            return entry.message

    def take(self, token: str) -> PreparedMessage:
        now = time.monotonic()
        with self._lock:
            self._cleanup(now)
            entry = self._entries.pop(token, None)
            if entry is None:
                raise PreparedMessageError("Prepared message token is missing, expired, consumed, or belongs to another session")
            return entry.message


def _verified_attachment_bytes(attachment: AttachmentSpec) -> bytes:
    try:
        attachment_bytes = attachment.path.read_bytes()
    except OSError as exc:
        raise PreparedMessageError(f"Prepared attachment is no longer available: {attachment.path}") from exc
    if len(attachment_bytes) != attachment.size or hashlib.sha256(attachment_bytes).hexdigest() != attachment.sha256:
        raise PreparedMessageError(
            f"Prepared attachment changed after review: {attachment.path}. Prepare the message again."
        )
    return attachment_bytes


def build_email(message: PreparedMessage) -> EmailMessage:
    mail = EmailMessage(policy=policy.SMTP)
    mail["From"] = message.from_header
    if message.to_headers:
        mail["To"] = ", ".join(message.to_headers)
    if message.cc_headers:
        mail["Cc"] = ", ".join(message.cc_headers)
    if message.bcc_headers:
        mail["Bcc"] = ", ".join(message.bcc_headers)
    mail["Subject"] = message.subject
    mail["Date"] = format_datetime(message.date)
    mail["Message-ID"] = message.message_id
    if message.in_reply_to:
        mail["In-Reply-To"] = message.in_reply_to
    if message.references:
        mail["References"] = message.references
    mail.set_content(message.body_text)
    for attachment in message.attachments:
        attachment_bytes = _verified_attachment_bytes(attachment)
        guessed, encoding = mimetypes.guess_type(attachment.filename)
        if guessed and not encoding and "/" in guessed:
            maintype, subtype = guessed.split("/", 1)
        else:
            maintype, subtype = "application", "octet-stream"
        mail.add_attachment(
            attachment_bytes,
            maintype=maintype,
            subtype=subtype,
            filename=attachment.filename,
        )
    return mail


def _find_special_folder(client: imaplib.IMAP4, flag: str, fallbacks: Sequence[str]) -> str | None:
    folders = list_folders_with_client(client)
    for folder in folders:
        if any(item.lower() == flag.lower() for item in folder.get("flags", [])):
            return str(folder["name"])
    by_lower = {str(folder["name"]).lower(): str(folder["name"]) for folder in folders}
    for fallback in fallbacks:
        if fallback.lower() in by_lower:
            return by_lower[fallback.lower()]
    return None


def append_message(
    settings: Settings,
    message: PreparedMessage,
    *,
    kind: str,
) -> dict[str, Any]:
    mail = build_email(message)
    raw = mail.as_bytes(policy=policy.SMTP)
    with imap_session(settings) as client:
        if kind == "draft":
            folder = settings.drafts_folder or _find_special_folder(client, "\\Drafts", ("Drafts", "Draft", "草稿箱", "草稿"))
            flags = "\\Draft"
        elif kind == "sent":
            folder = settings.sent_folder or _find_special_folder(client, "\\Sent", ("Sent", "Sent Messages", "已发送", "已发送邮件"))
            flags = "\\Seen"
        else:
            raise CoremailError(f"Unsupported append kind: {kind}")
        if not folder:
            raise ConfigError(f"Cannot locate the IMAP {kind} folder; configure it explicitly")
        status, data = client.append(_imap_quoted(folder), flags, None, raw)
        if status != "OK":
            raise MailProtocolError(f"IMAP APPEND to {folder} failed")
        return {
            "appended": True,
            "transport": "imap_smtp",
            "kind": kind,
            "folder": folder,
            "message_id": message.message_id,
            "server_response": _safe_protocol_text(data[0]) if data else None,
        }


def _refused_recipients(value: Mapping[str, tuple[int, bytes | str]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for address, response in value.items():
        code, detail = response
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", errors="replace")
        result[address] = {"code": int(code), "message": _safe_protocol_text(detail)}
    return result


def send_message(settings: Settings, message: PreparedMessage) -> dict[str, Any]:
    mail = build_email(message)
    try:
        with smtp_session(settings) as client:
            refused = client.send_message(
                mail,
                from_addr=message.from_address,
                to_addrs=list(message.all_recipients),
            )
    except smtplib.SMTPRecipientsRefused as exc:
        raise MailProtocolError(f"SMTP rejected all recipients: {_refused_recipients(exc.recipients)}") from exc
    except (smtplib.SMTPServerDisconnected, OSError, ssl.SSLError) as exc:
        raise MailConnectionError(
            "SMTP connection failed during submission; delivery state may be uncertain. "
            "Do not retry automatically."
        ) from exc
    except smtplib.SMTPDataError as exc:
        raise MailProtocolError(f"SMTP rejected message data (code {exc.smtp_code})") from exc
    except smtplib.SMTPSenderRefused as exc:
        raise MailProtocolError(f"SMTP rejected the sender (code {exc.smtp_code})") from exc
    except smtplib.SMTPException as exc:
        raise MailProtocolError(f"SMTP submission failed: {_safe_protocol_text(exc)}") from exc

    refused_result = _refused_recipients(refused)
    accepted = [address for address in message.all_recipients if address not in refused]
    result: dict[str, Any] = {
        "smtp_submitted": bool(accepted),
        "transport": "imap_smtp",
        "message_id": message.message_id,
        "accepted_recipients": accepted,
        "refused_recipients": refused_result,
        "delivery_note": "SMTP acceptance is not final delivery confirmation.",
        "sent_copy_mode": settings.sent_copy_mode,
    }

    if accepted and settings.sent_copy_mode == "append":
        try:
            result["sent_copy"] = append_message(settings, message, kind="sent")
        except CoremailError as exc:
            result["sent_copy"] = {"appended": False, "error": str(exc)}
    else:
        result["sent_copy"] = {"appended": False, "reason": "sent_copy_mode is none"}
    return result


def _mapi_recipient_rows(message: PreparedMessage) -> list[tuple[int, str, str]]:
    rows: list[tuple[int, str, str]] = []
    for recipient_class, headers, addresses in (
        (MAPI_TO, message.to_headers, message.to_addresses),
        (MAPI_CC, message.cc_headers, message.cc_addresses),
        (MAPI_BCC, message.bcc_headers, message.bcc_addresses),
    ):
        for header, address in zip(headers, addresses):
            display_name = getaddresses([header])[0][0]
            rows.append((recipient_class, display_name, address))
    return rows


class CoremailBackend:
    def __init__(
        self,
        store: PreparedStore | None = None,
        mapi_client: SimpleMapiClient | None = None,
    ) -> None:
        self.store = store or PreparedStore()
        self._mapi_client = mapi_client

    def _mapi(self) -> SimpleMapiClient:
        if self._mapi_client is None:
            self._mapi_client = SimpleMapiClient()
        return self._mapi_client

    @staticmethod
    def _raise_mapi(exc: WindowsMapiError) -> None:
        raise MailProtocolError(str(exc)) from exc

    def close(self) -> None:
        if self._mapi_client is not None:
            try:
                self._mapi_client.close()
            except WindowsMapiError:
                pass

    def connection_status(self) -> dict[str, Any]:
        path = default_config_path()
        interface = detect_coremail_mapi_registration()
        if not path.is_file():
            return {
                "configured": False,
                "config_path": str(path),
                "client_interface": interface,
                "next_step": "Run scripts/setup-account.ps1, then restart or reload the MCP server.",
                "coremail_client_interface_selected": False,
                "coremail_client_interface_used": False,
                "coremail_ui_automation_used": False,
            }
        settings = load_settings(path)
        return {
            "configured": True,
            "active_transport": settings.transport,
            "credential_available": (
                credential_available(settings) if settings.transport == "imap_smtp" else None
            ),
            "settings": settings.public_summary(),
            "client_interface": interface,
            "coremail_client_interface_selected": settings.transport == WINDOWS_MAPI_TRANSPORT,
            "coremail_client_interface_used": False,
            "coremail_ui_automation_used": False,
        }

    def check_connection(self) -> dict[str, Any]:
        settings = load_settings()
        if settings.transport == WINDOWS_MAPI_TRANSPORT:
            try:
                result = self._mapi().status()
            except WindowsMapiError as exc:
                self._raise_mapi(exc)
            return {
                **result,
                "username": settings.username,
                "coremail_client_interface_used": True,
                "coremail_ui_automation_used": False,
            }

        with imap_session(settings) as imap_client:
            imap_capabilities = sorted(
                item.decode("ascii", errors="replace") if isinstance(item, bytes) else str(item)
                for item in getattr(imap_client, "capabilities", ())
            )
        with smtp_session(settings) as smtp_client:
            smtp_client.ehlo_or_helo_if_needed()
            smtp_features = sorted(smtp_client.esmtp_features.keys())
        return {
            "transport": "imap_smtp",
            "imap": {"connected": True, "capabilities": imap_capabilities},
            "smtp": {"connected": True, "features": smtp_features},
            "username": settings.username,
            "tls_verification": True,
            "coremail_client_interface_used": False,
            "coremail_ui_automation_used": False,
        }

    def list_folders(self) -> dict[str, Any]:
        settings = load_settings()
        if settings.transport == WINDOWS_MAPI_TRANSPORT:
            try:
                return self._mapi().list_folders()
            except WindowsMapiError as exc:
                self._raise_mapi(exc)
        with imap_session(settings) as client:
            folders = list_folders_with_client(client)
        return {"folders": folders, "count": len(folders), "transport": "imap_smtp"}

    def search(self, arguments: Mapping[str, Any]) -> dict[str, Any]:
        settings = load_settings()
        folder = arguments.get("folder", "INBOX")
        if not isinstance(folder, str):
            raise CoremailError("folder must be a string")
        query = arguments.get("query", {})
        if not isinstance(query, dict):
            raise CoremailError("query must be an object")
        limit = _bounded_tool_int(arguments.get("limit"), "limit", 20, 1, 100)
        if settings.transport == WINDOWS_MAPI_TRANSPORT:
            try:
                return self._mapi().search(folder=folder, query=query, limit=limit)
            except WindowsMapiError as exc:
                self._raise_mapi(exc)
        with imap_session(settings) as client:
            result = search_messages_with_client(client, folder=folder, query=query, limit=limit)
        return {**result, "transport": "imap_smtp"}

    def get_message(self, arguments: Mapping[str, Any]) -> dict[str, Any]:
        settings = load_settings()
        folder = arguments.get("folder", "INBOX")
        if not isinstance(folder, str):
            raise CoremailError("folder must be a string")
        uid = str(arguments.get("uid", ""))
        uidvalidity = arguments.get("uidvalidity")
        requested_chars = _bounded_tool_int(
            arguments.get("max_body_chars"),
            "max_body_chars",
            settings.max_body_chars,
            1,
            settings.max_body_chars,
        )
        if settings.transport == WINDOWS_MAPI_TRANSPORT:
            try:
                return self._mapi().get_message(
                    folder=folder,
                    uid=uid,
                    expected_uidvalidity=str(uidvalidity) if uidvalidity is not None else None,
                    max_body_chars=requested_chars,
                )
            except WindowsMapiError as exc:
                self._raise_mapi(exc)
        with imap_session(settings) as client:
            result = get_message_with_client(
                client,
                folder=folder,
                uid=uid,
                expected_uidvalidity=str(uidvalidity) if uidvalidity is not None else None,
                max_message_bytes=settings.max_message_bytes,
                max_body_chars=requested_chars,
            )
        return {**result, "transport": "imap_smtp"}

    def set_seen(self, arguments: Mapping[str, Any]) -> dict[str, Any]:
        settings = load_settings()
        folder = arguments.get("folder", "INBOX")
        if not isinstance(folder, str):
            raise CoremailError("folder must be a string")
        uid = str(arguments.get("uid", ""))
        uidvalidity = arguments.get("uidvalidity")
        seen = arguments.get("seen")
        if not isinstance(seen, bool):
            raise CoremailError("seen must be true or false")
        if settings.transport == WINDOWS_MAPI_TRANSPORT:
            try:
                return self._mapi().set_seen(
                    folder=folder,
                    uid=uid,
                    expected_uidvalidity=str(uidvalidity) if uidvalidity is not None else None,
                    seen=seen,
                )
            except WindowsMapiError as exc:
                self._raise_mapi(exc)
        with imap_session(settings) as client:
            result = set_seen_with_client(
                client,
                folder=folder,
                uid=uid,
                expected_uidvalidity=str(uidvalidity) if uidvalidity is not None else None,
                seen=seen,
            )
        return {**result, "transport": "imap_smtp"}

    def prepare(self, arguments: Mapping[str, Any]) -> dict[str, Any]:
        settings = load_settings()
        message = prepare_message(settings, arguments)
        token, _ = self.store.put(message)
        return {
            "prepared_token": token,
            "expires_in_seconds": DEFAULT_TOKEN_TTL_SECONDS,
            "summary": message.summary(settings),
            "network_write_performed": False,
        }

    def save_draft(self, arguments: Mapping[str, Any]) -> dict[str, Any]:
        token = str(arguments.get("prepared_token", ""))
        settings = load_settings()
        if settings.transport == WINDOWS_MAPI_TRANSPORT:
            # Reject before consuming the prepared token because no write attempt
            # can be made through this limited interface.
            self.store.get(token)
            raise CoremailError(
                "Saving drafts is not supported by Windows Simple MAPI; reconfigure imap_smtp to use Drafts"
            )
        message = self.store.take(token)
        return append_message(settings, message, kind="draft")

    def _send_mapi(self, settings: Settings, message: PreparedMessage) -> dict[str, Any]:
        if message.in_reply_to or message.references:
            raise PreparedMessageError(
                "Windows Simple MAPI cannot preserve In-Reply-To or References; use imap_smtp for this reply"
            )
        sender_name = getaddresses([message.from_header])[0][0]
        verified = [(item, _verified_attachment_bytes(item)) for item in message.attachments]
        # Simple MAPI accepts attachment paths rather than bytes. Pass random-name,
        # verified snapshots so a change to the original file after review cannot
        # race the provider's copy. Microsoft documents that attachments are copied
        # before MAPISendMailW returns, so cleanup after the call is safe.
        with tempfile.TemporaryDirectory(prefix="coremail-mapi-send-") as temporary:
            snapshots: list[tuple[str, str]] = []
            for index, (attachment, content) in enumerate(verified, start=1):
                snapshot = Path(temporary) / f"attachment-{index:03d}.bin"
                try:
                    with snapshot.open("xb") as handle:
                        handle.write(content)
                except OSError as exc:
                    raise PreparedMessageError("Cannot create a verified temporary MAPI attachment") from exc
                snapshots.append((str(snapshot), attachment.filename))
            try:
                return self._mapi().send(
                    sender_name=sender_name,
                    sender_address=message.from_address,
                    recipients=_mapi_recipient_rows(message),
                    subject=message.subject,
                    body=message.body_text,
                    attachments=snapshots,
                    message_id=message.message_id,
                )
            except WindowsMapiError as exc:
                self._raise_mapi(exc)

    def send_prepared(self, arguments: Mapping[str, Any]) -> dict[str, Any]:
        token = str(arguments.get("prepared_token", ""))
        confirmation = arguments.get("confirmation")
        if confirmation != "确认发送":
            raise PreparedMessageError("Exact confirmation phrase required: 确认发送")
        settings = load_settings()
        preview = self.store.get(token)
        if settings.transport == WINDOWS_MAPI_TRANSPORT and (preview.in_reply_to or preview.references):
            raise PreparedMessageError(
                "Windows Simple MAPI cannot preserve In-Reply-To or References; use imap_smtp for this reply"
            )
        message = self.store.take(token)
        if settings.transport == WINDOWS_MAPI_TRANSPORT:
            return self._send_mapi(settings, message)
        return send_message(settings, message)
