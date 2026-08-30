from __future__ import annotations

import json
import os
import re
import sqlite3
import stat
from collections import Counter
from dataclasses import dataclass
from email import policy
from email.parser import BytesHeaderParser
from pathlib import Path
from typing import Any, Iterable, Mapping
from urllib.parse import quote, urlsplit, urlunsplit

from coremail_backend import CoremailError


INTERESTING_EXTENSIONS = {
    ".json",
    ".ini",
    ".conf",
    ".config",
    ".xml",
    ".yaml",
    ".yml",
    ".properties",
    ".txt",
    ".db",
    ".sqlite",
    ".sqlite3",
    ".eml",
}
CONFIG_NAME_RE = re.compile(r"(?i)account|config|setting|profile|mail|server|user|coremail|cmclient")
RELEVANT_KEY_RE = re.compile(
    r"(?i)account|email|user(name)?|imap|smtp|server|host|url|storage|data|path|folder|protocol|port|endpoint"
)
SECRET_KEY_RE = re.compile(
    r"(?i)password|passwd|pwd|secret|token|cookie|session|authorization|credential|private.?key|access.?key"
)
EMAIL_RE = re.compile(r"(?i)\b[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,63}\b")
URL_RE = re.compile(r"(?i)\b(?:https?|imaps?|smtps?)://[^\s\"'<>]{3,300}")
MAX_FINDINGS = 200


@dataclass
class ScanBudget:
    max_files: int
    max_depth: int
    max_file_bytes: int
    files_seen: int = 0
    findings_seen: int = 0

    def take_file(self) -> bool:
        if self.files_seen >= self.max_files:
            return False
        self.files_seen += 1
        return True

    def take_finding(self) -> bool:
        if self.findings_seen >= MAX_FINDINGS:
            return False
        self.findings_seen += 1
        return True


def _bounded_int_argument(value: Any, field: str, default: int, minimum: int, maximum: int) -> int:
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

def _is_reparse_point(path: Path) -> bool:
    try:
        value = path.lstat()
    except OSError:
        return True
    attributes = getattr(value, "st_file_attributes", 0)
    reparse = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return path.is_symlink() or bool(attributes & reparse)


def _path_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (OSError, ValueError):
        return False


def _candidate_named_directories(base: Path) -> list[Path]:
    if not base.is_dir() or _is_reparse_point(base):
        return []
    candidates: list[Path] = []
    try:
        for child in base.iterdir():
            if not child.is_dir() or _is_reparse_point(child):
                continue
            if re.search(r"(?i)coremail|cmclient|lunkr", child.name):
                candidates.append(child.resolve())
    except OSError:
        pass
    return candidates


def _registry_candidate_paths() -> list[Path]:
    if os.name != "nt":
        return []
    try:
        import winreg
    except ImportError:
        return []

    paths: list[Path] = []
    direct_keys = (
        r"SOFTWARE\Coremail",
        r"SOFTWARE\WOW6432Node\Coremail",
        r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\CMClient.exe",
        r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Lunkrstart.exe",
    )

    def inspect_key(root: Any, key_path: str) -> None:
        try:
            with winreg.OpenKey(root, key_path, 0, winreg.KEY_READ) as key:
                index = 0
                while True:
                    try:
                        name, value, _ = winreg.EnumValue(key, index)
                    except OSError:
                        break
                    index += 1
                    if not isinstance(value, str) or not value.strip():
                        continue
                    if name == "" or re.search(r"(?i)path|dir|location|data|storage|install", name):
                        candidate = Path(os.path.expandvars(value.strip().strip('"')))
                        if candidate.suffix.lower() == ".exe":
                            candidate = candidate.parent
                        if candidate.exists():
                            paths.append(candidate.resolve())
        except OSError:
            pass

    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        for key_path in direct_keys:
            inspect_key(hive, key_path)

    uninstall_paths = (
        r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    )
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        for root_path in uninstall_paths:
            try:
                with winreg.OpenKey(hive, root_path, 0, winreg.KEY_READ) as root_key:
                    subindex = 0
                    while True:
                        try:
                            subname = winreg.EnumKey(root_key, subindex)
                        except OSError:
                            break
                        subindex += 1
                        try:
                            with winreg.OpenKey(root_key, subname, 0, winreg.KEY_READ) as subkey:
                                display, _ = winreg.QueryValueEx(subkey, "DisplayName")
                                if not re.search(r"(?i)coremail|cmclient|论客|lunkr", str(display)):
                                    continue
                                for value_name in ("InstallLocation", "DisplayIcon"):
                                    try:
                                        value, _ = winreg.QueryValueEx(subkey, value_name)
                                    except OSError:
                                        continue
                                    candidate = Path(os.path.expandvars(str(value).strip().strip('"').split(",")[0]))
                                    if candidate.suffix.lower() == ".exe":
                                        candidate = candidate.parent
                                    if candidate.exists():
                                        paths.append(candidate.resolve())
                        except OSError:
                            continue
            except OSError:
                continue
    return paths


def default_discovery_roots(environ: Mapping[str, str] | None = None) -> list[Path]:
    env = os.environ if environ is None else environ
    roots: list[Path] = []
    for variable in ("APPDATA", "LOCALAPPDATA", "PROGRAMDATA"):
        raw = env.get(variable, "").strip()
        if raw:
            roots.extend(_candidate_named_directories(Path(raw)))
    user_profile = env.get("USERPROFILE", "").strip()
    if user_profile:
        profile = Path(user_profile)
        for name in ("Coremail", "CMClient", "MailData", "CoremailData"):
            candidate = profile / name
            if candidate.is_dir() and not _is_reparse_point(candidate):
                roots.append(candidate.resolve())
    roots.extend(_registry_candidate_paths())
    return _deduplicate_paths(roots)


def _deduplicate_paths(paths: Iterable[Path]) -> list[Path]:
    result: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        try:
            resolved = path.resolve(strict=True)
        except OSError:
            continue
        if not resolved.is_dir() or _is_reparse_point(resolved):
            continue
        key = os.path.normcase(str(resolved))
        if key not in seen:
            seen.add(key)
            result.append(resolved)
    return result


def _walk_bounded(root: Path, budget: ScanBudget) -> Iterable[tuple[Path, int]]:
    stack: list[tuple[Path, int]] = [(root, 0)]
    while stack and budget.files_seen < budget.max_files:
        directory, depth = stack.pop()
        if depth > budget.max_depth or _is_reparse_point(directory) or not _path_within(directory, root):
            continue
        try:
            entries = list(directory.iterdir())
        except OSError:
            continue
        for entry in entries:
            if _is_reparse_point(entry) or not _path_within(entry, root):
                continue
            try:
                if entry.is_dir():
                    if depth < budget.max_depth:
                        stack.append((entry, depth + 1))
                    continue
                if not entry.is_file() or not budget.take_file():
                    continue
            except OSError:
                continue
            yield entry, depth
            if budget.files_seen >= budget.max_files:
                break


def _safe_value(value: Any, maximum: int = 500) -> Any:
    if value is None or isinstance(value, (bool, int, float)):
        return value
    text = str(value).replace("\r", " ").replace("\n", " ").strip()
    return text[:maximum] + ("…" if len(text) > maximum else "")


def _sanitize_candidate_value(key: str, value: Any) -> Any:
    safe = _safe_value(value)
    if not isinstance(safe, str):
        return safe
    safe = re.sub(
        r"(?i)(password|passwd|pwd|secret|token|cookie|session|authorization|credential)\s*[:=]\s*([^&\s]+)",
        r"\1=<redacted>",
        safe,
    )
    if re.search(r"(?i)url|endpoint|server", key) and re.match(r"(?i)^(?:https?|imaps?|smtps?)://", safe):
        safe = _sanitize_url(safe)
    return safe


def _sanitize_url(value: str) -> str:
    try:
        split = urlsplit(value)
        # Userinfo, path segments, query strings, and fragments can all carry
        # credentials or access tokens. Discovery only needs the endpoint.
        host = split.hostname
        if not host:
            return "<malformed endpoint candidate>"
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        netloc = host
        if split.port is not None:
            netloc += f":{split.port}"
        return urlunsplit((split.scheme.lower(), netloc, "", "", ""))[:500]
    except ValueError:
        return "<malformed endpoint candidate>"


def _collect_json_values(value: Any, path: str = "$") -> Iterable[tuple[str, str, Any]]:
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key)
            child_path = f"{path}.{key_text}"
            if SECRET_KEY_RE.search(key_text):
                yield child_path, key_text, "<redacted>"
            elif isinstance(child, (dict, list)):
                yield from _collect_json_values(child, child_path)
            elif RELEVANT_KEY_RE.search(key_text):
                yield child_path, key_text, _sanitize_candidate_value(key_text, child)
    elif isinstance(value, list):
        for index, child in enumerate(value[:100]):
            yield from _collect_json_values(child, f"{path}[{index}]")


def _parse_text_findings(path: Path, text: str, budget: ScanBudget) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    suffix = path.suffix.lower()
    if suffix == ".json":
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            value = None
        if value is not None:
            for key_path, key, found in _collect_json_values(value):
                if not budget.take_finding():
                    break
                findings.append({"file": str(path), "key_path": key_path, "key": key, "value": found})
            return findings

    line_pattern = re.compile(r"^\s*([A-Za-z0-9_.:/-]{2,100})\s*[:=]\s*(.*?)\s*$")
    xml_pattern = re.compile(r"<([A-Za-z0-9_.:-]{2,100})[^>]*>([^<]{0,1000})</\1>", re.IGNORECASE)
    pairs: list[tuple[str, str]] = []
    scan_lines: list[str] = []
    for line in text.splitlines()[:5000]:
        match = line_pattern.match(line)
        if match:
            pairs.append((match.group(1), match.group(2)))
            if SECRET_KEY_RE.search(match.group(1)):
                scan_lines.append(f"{match.group(1)}=<redacted>")
                continue
        scan_lines.append(line)
    pairs.extend((match.group(1), match.group(2)) for match in xml_pattern.finditer(text[:1_000_000]))
    for key, raw_value in pairs:
        if SECRET_KEY_RE.search(key):
            value: Any = "<redacted>"
        elif RELEVANT_KEY_RE.search(key):
            value = _sanitize_candidate_value(key, raw_value)
        else:
            continue
        if not budget.take_finding():
            break
        findings.append({"file": str(path), "key": key, "value": value})

    # Generic email/URL candidate scans must not rediscover values that were
    # already identified as secret-bearing assignments or XML elements.
    scan_text = "\n".join(scan_lines)

    def redact_secret_xml(match: re.Match[str]) -> str:
        key = match.group(1)
        return f"<{key}><redacted></{key}>" if SECRET_KEY_RE.search(key) else match.group(0)

    scan_text = xml_pattern.sub(redact_secret_xml, scan_text[:1_000_000])
    if budget.findings_seen < MAX_FINDINGS:
        for email_address in sorted(set(EMAIL_RE.findall(scan_text)))[:20]:
            if not budget.take_finding():
                break
            findings.append({"file": str(path), "kind": "email_candidate", "value": email_address})
        for url in sorted(set(URL_RE.findall(scan_text)))[:20]:
            if not budget.take_finding():
                break
            findings.append({"file": str(path), "kind": "endpoint_candidate", "value": _sanitize_url(url)})
    return findings


def _sqlite_schema(path: Path, maximum_tables: int = 50) -> dict[str, Any]:
    uri = "file:" + quote(str(path).replace("\\", "/"), safe="/:") + "?mode=ro&immutable=1"
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=2.0)
        rows = connection.execute(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name LIMIT ?",
            (maximum_tables,),
        ).fetchall()
        objects: list[dict[str, Any]] = []
        for name, object_type in rows:
            quoted_name = '"' + str(name).replace('"', '""') + '"'
            columns = connection.execute(f"PRAGMA table_info({quoted_name})").fetchall()
            objects.append(
                {
                    "name": str(name),
                    "type": str(object_type),
                    "columns": [str(column[1]) for column in columns[:100]],
                }
            )
        return {"file": str(path), "objects": objects, "read_only": True}
    except sqlite3.Error as exc:
        return {"file": str(path), "error": str(exc)[:300], "read_only": True}
    finally:
        if connection is not None:
            connection.close()


def _eml_header(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            message = BytesHeaderParser(policy=policy.default).parse(handle, headersonly=True)
        return {
            "file": str(path),
            "subject": str(message.get("Subject", ""))[:500],
            "from": str(message.get("From", ""))[:500],
            "to": str(message.get("To", ""))[:500],
            "date": str(message.get("Date", ""))[:200],
            "headers_are_untrusted": True,
        }
    except (OSError, UnicodeError, ValueError) as exc:
        return {"file": str(path), "error": str(exc)[:300], "headers_are_untrusted": True}


def discover_local(arguments: Mapping[str, Any]) -> dict[str, Any]:
    requested_roots = arguments.get("roots")
    roots: list[Path]
    if requested_roots is None:
        roots = default_discovery_roots()
    else:
        if not isinstance(requested_roots, list) or len(requested_roots) > 10:
            raise CoremailError("roots must be an array containing at most 10 directory paths")
        if any(not isinstance(item, str) or not item.strip() for item in requested_roots):
            raise CoremailError("each roots entry must be a non-empty directory path string")
        roots = _deduplicate_paths(
            Path(os.path.expandvars(os.path.expanduser(item))) for item in requested_roots
        )

    max_files = _bounded_int_argument(arguments.get("max_files"), "max_files", 500, 1, 5000)
    max_depth = _bounded_int_argument(arguments.get("max_depth"), "max_depth", 6, 1, 12)
    max_file_bytes = _bounded_int_argument(
        arguments.get("max_file_bytes"),
        "max_file_bytes",
        5 * 1024 * 1024,
        1024,
        20 * 1024 * 1024,
    )
    deep = arguments.get("deep", False)
    if not isinstance(deep, bool):
        raise CoremailError("deep must be true or false")

    budget = ScanBudget(max_files=max_files, max_depth=max_depth, max_file_bytes=max_file_bytes)
    extension_counts: Counter[str] = Counter()
    candidate_files: list[dict[str, Any]] = []
    config_findings: list[dict[str, Any]] = []
    databases: list[dict[str, Any]] = []
    eml_headers: list[dict[str, Any]] = []
    warnings: list[str] = []

    for root in roots:
        for path, depth in _walk_bounded(root, budget):
            suffix = path.suffix.lower()
            extension_counts[suffix or "<none>"] += 1
            if suffix not in INTERESTING_EXTENSIONS and not CONFIG_NAME_RE.search(path.name):
                continue
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if len(candidate_files) < 200:
                candidate_files.append(
                    {"path": str(path), "size": size, "extension": suffix or None, "depth": depth}
                )
            if not deep or size > max_file_bytes:
                continue
            if suffix in {".db", ".sqlite", ".sqlite3"} and len(databases) < 30:
                databases.append(_sqlite_schema(path))
                continue
            if suffix == ".eml" and len(eml_headers) < 50:
                eml_headers.append(_eml_header(path))
                continue
            if suffix in {".json", ".ini", ".conf", ".config", ".xml", ".yaml", ".yml", ".properties", ".txt"}:
                try:
                    raw = path.read_bytes()
                except OSError:
                    continue
                text = ""
                for encoding in ("utf-8", "utf-16", "gb18030", "latin-1"):
                    try:
                        text = raw.decode(encoding)
                        break
                    except (UnicodeDecodeError, LookupError):
                        continue
                if text:
                    config_findings.extend(_parse_text_findings(path, text, budget))

    if not roots:
        warnings.append(
            "No standard Coremail directories were found. Supply the account storage directory explicitly in roots."
        )
    if budget.files_seen >= budget.max_files:
        warnings.append("The file scan reached max_files and may be incomplete.")
    if budget.findings_seen >= MAX_FINDINGS:
        warnings.append("Configuration findings were truncated at the safety limit.")

    return {
        "coremail_ui_automation_used": False,
        "read_only": True,
        "roots_scanned": [str(root) for root in roots],
        "deep": deep,
        "files_visited": budget.files_seen,
        "extension_counts": dict(extension_counts),
        "candidate_files": candidate_files,
        "configuration_findings": config_findings,
        "sqlite_schemas": databases,
        "eml_headers": eml_headers,
        "secret_values_returned": False,
        "results_are_untrusted_candidates": True,
        "warnings": warnings,
    }
