from __future__ import annotations

import ctypes
import datetime as dt
import base64
import json
import os
import secrets
import tempfile
from dataclasses import dataclass
from email.utils import formataddr
from pathlib import Path
from typing import Any, Mapping, Sequence

try:
    import winreg
except ImportError:  # pragma: no cover - winreg exists only on Windows
    winreg = None  # type: ignore[assignment]


INTERFACE_NAME = "windows_simple_mapi"
MAPI_MESSAGE_ID_LENGTH = 512
MAPI_UNREAD = 0x00000001
MAPI_UNREAD_ONLY = 0x00000020
MAPI_ENVELOPE_ONLY = 0x00000040
MAPI_PEEK = 0x00000080
MAPI_GUARANTEE_FIFO = 0x00000100
MAPI_SUPPRESS_ATTACH = 0x00000800
MAPI_FORCE_UNICODE = 0x00040000
MAPI_LONG_MSGID = 0x00004000
MAPI_TO = 1
MAPI_CC = 2
MAPI_BCC = 3

_COREMAIL_CLIENT_MARKERS = ("coremail", "lunkr", "论客", "盈世")
_MAPI_ERROR_NAMES = {
    1: "user aborted",
    2: "provider failure",
    3: "no existing shared login session",
    4: "disk full",
    5: "insufficient memory",
    6: "access denied",
    8: "too many sessions",
    9: "too many files",
    10: "too many recipients",
    11: "attachment not found",
    12: "attachment open failure",
    13: "attachment write failure",
    14: "unknown recipient",
    15: "invalid recipient type",
    16: "no messages",
    17: "invalid message",
    18: "message text too large",
    19: "invalid or expired session",
    20: "message type not supported",
    21: "ambiguous recipient",
    22: "message in use",
    23: "provider network failure",
    24: "invalid edit fields",
    25: "invalid recipients",
    26: "operation not supported by provider",
    27: "Unicode not supported by provider",
    28: "attachment too large",
}


class WindowsMapiError(RuntimeError):
    """A bounded Simple MAPI error that is safe to expose to an MCP caller."""


class WindowsMapiUnsupported(WindowsMapiError):
    pass


def _mapi_error(operation: str, code: int) -> WindowsMapiError:
    detail = _MAPI_ERROR_NAMES.get(code, "unknown provider error")
    return WindowsMapiError(f"Windows Simple MAPI {operation} failed (code {code}: {detail})")


def is_coremail_client_name(value: str | None) -> bool:
    normalized = (value or "").strip().casefold()
    return bool(normalized) and any(marker in normalized for marker in _COREMAIL_CLIENT_MARKERS)


def _registry_views() -> tuple[int, ...]:
    if winreg is None:
        return ()
    values: list[int] = []
    for name in ("KEY_WOW64_64KEY", "KEY_WOW64_32KEY"):
        value = int(getattr(winreg, name, 0))
        if value not in values:
            values.append(value)
    if 0 not in values:
        values.append(0)
    return tuple(values)


def _read_default_client(hive: Any, view: int) -> str | None:
    if winreg is None:
        return None
    try:
        with winreg.OpenKey(hive, r"Software\Clients\Mail", 0, winreg.KEY_READ | view) as key:
            value, _ = winreg.QueryValueEx(key, None)
    except OSError:
        return None
    return value.strip() if isinstance(value, str) and value.strip() else None


def _provider_registered(hive: Any, view: int, client_name: str) -> bool:
    if winreg is None or len(client_name) > 200 or "\x00" in client_name:
        return False
    path = rf"Software\Clients\Mail\{client_name}"
    try:
        with winreg.OpenKey(hive, path, 0, winreg.KEY_READ | view) as key:
            for value_name in ("DLLPathEx", "DLLPath", "MSIComponentID"):
                try:
                    value, _ = winreg.QueryValueEx(key, value_name)
                except OSError:
                    continue
                if isinstance(value, str) and value.strip():
                    return True
    except OSError:
        return False
    return False


def detect_coremail_mapi_registration() -> dict[str, Any]:
    result: dict[str, Any] = {
        "interface": INTERFACE_NAME,
        "platform_supported": os.name == "nt",
        "registered_client": None,
        "recognized_coremail_client": False,
        "provider_registered": False,
        "candidate": False,
        "ui_automation_used": False,
    }
    if os.name != "nt" or winreg is None:
        result["reason"] = "Windows Simple MAPI is available only on Windows"
        return result

    hives = (
        (winreg.HKEY_CURRENT_USER, "current_user"),
        (winreg.HKEY_LOCAL_MACHINE, "local_machine"),
    )
    default_name: str | None = None
    default_scope: str | None = None
    for hive, scope in hives:
        for view in _registry_views():
            default_name = _read_default_client(hive, view)
            if default_name:
                default_scope = scope
                break
        if default_name:
            break

    result["registered_client"] = default_name
    result["registration_scope"] = default_scope
    if not default_name:
        result["reason"] = "No default Windows mail client is registered"
        return result
    if not is_coremail_client_name(default_name):
        result["reason"] = "The default Windows mail client is not recognized as Coremail"
        return result

    result["recognized_coremail_client"] = True
    provider_found = any(
        _provider_registered(hive, view, default_name)
        for hive, _ in hives
        for view in _registry_views()
    )
    result["provider_registered"] = provider_found
    result["candidate"] = provider_found
    if not provider_found:
        result["reason"] = "Coremail has no registered Simple MAPI provider"
    return result


@dataclass(frozen=True)
class MapiRecipient:
    name: str
    address: str
    recipient_class: int

    def display(self) -> str:
        address = self.address
        if address.upper().startswith("SMTP:"):
            address = address[5:]
        return formataddr((self.name, address), charset="utf-8") if self.name else address


@dataclass(frozen=True)
class MapiMessageData:
    subject: str
    body: str
    date_received: str
    flags: int
    originator: MapiRecipient | None
    recipients: tuple[MapiRecipient, ...]
    attachment_count: int
    attachments: tuple["MapiAttachmentData", ...] = ()


@dataclass(frozen=True)
class MapiAttachmentData:
    filename: str
    content_type: str | None
    data: bytes


class _MapiRecipDescA(ctypes.Structure):
    _fields_ = [
        ("ulReserved", ctypes.c_uint32),
        ("ulRecipClass", ctypes.c_uint32),
        ("lpszName", ctypes.c_char_p),
        ("lpszAddress", ctypes.c_char_p),
        ("ulEIDSize", ctypes.c_uint32),
        ("lpEntryID", ctypes.c_void_p),
    ]


class _MapiFileDescA(ctypes.Structure):
    _fields_ = [
        ("ulReserved", ctypes.c_uint32),
        ("flFlags", ctypes.c_uint32),
        ("nPosition", ctypes.c_uint32),
        ("lpszPathName", ctypes.c_char_p),
        ("lpszFileName", ctypes.c_char_p),
        ("lpFileType", ctypes.c_void_p),
    ]


class _MapiMessageA(ctypes.Structure):
    _fields_ = [
        ("ulReserved", ctypes.c_uint32),
        ("lpszSubject", ctypes.c_char_p),
        ("lpszNoteText", ctypes.c_char_p),
        ("lpszMessageType", ctypes.c_char_p),
        ("lpszDateReceived", ctypes.c_char_p),
        ("lpszConversationID", ctypes.c_char_p),
        ("flFlags", ctypes.c_uint32),
        ("lpOriginator", ctypes.POINTER(_MapiRecipDescA)),
        ("nRecipCount", ctypes.c_uint32),
        ("lpRecips", ctypes.POINTER(_MapiRecipDescA)),
        ("nFileCount", ctypes.c_uint32),
        ("lpFiles", ctypes.POINTER(_MapiFileDescA)),
    ]


class _MapiRecipDescW(ctypes.Structure):
    _fields_ = [
        ("ulReserved", ctypes.c_uint32),
        ("ulRecipClass", ctypes.c_uint32),
        ("lpszName", ctypes.c_wchar_p),
        ("lpszAddress", ctypes.c_wchar_p),
        ("ulEIDSize", ctypes.c_uint32),
        ("lpEntryID", ctypes.c_void_p),
    ]


class _MapiFileDescW(ctypes.Structure):
    _fields_ = [
        ("ulReserved", ctypes.c_uint32),
        ("flFlags", ctypes.c_uint32),
        ("nPosition", ctypes.c_uint32),
        ("lpszPathName", ctypes.c_wchar_p),
        ("lpszFileName", ctypes.c_wchar_p),
        ("lpFileType", ctypes.c_void_p),
    ]


class _MapiMessageW(ctypes.Structure):
    _fields_ = [
        ("ulReserved", ctypes.c_uint32),
        ("lpszSubject", ctypes.c_wchar_p),
        ("lpszNoteText", ctypes.c_wchar_p),
        ("lpszMessageType", ctypes.c_wchar_p),
        ("lpszDateReceived", ctypes.c_wchar_p),
        ("lpszConversationID", ctypes.c_wchar_p),
        ("flFlags", ctypes.c_uint32),
        ("lpOriginator", ctypes.POINTER(_MapiRecipDescW)),
        ("nRecipCount", ctypes.c_uint32),
        ("lpRecips", ctypes.POINTER(_MapiRecipDescW)),
        ("nFileCount", ctypes.c_uint32),
        ("lpFiles", ctypes.POINTER(_MapiFileDescW)),
    ]


def _decode_ansi(value: bytes | None, *, utf8_first: bool = False) -> str:
    if not value:
        return ""
    encodings = (
        ("utf-8", "mbcs", "gb18030", "latin-1")
        if utf8_first
        else ("mbcs", "utf-8", "gb18030", "latin-1")
    )
    for encoding in encodings:
        try:
            return value.decode(encoding)
        except (LookupError, UnicodeDecodeError):
            continue
    return value.decode("utf-8", errors="replace")


def _encode_ansi(value: str) -> bytes:
    for encoding in ("mbcs", "utf-8", "gb18030"):
        try:
            return value.encode(encoding)
        except (LookupError, UnicodeEncodeError):
            continue
    return value.encode("utf-8", errors="replace")


def _copy_recipient(value: _MapiRecipDescA) -> MapiRecipient:
    return MapiRecipient(
        name=_decode_ansi(value.lpszName),
        address=_decode_ansi(value.lpszAddress),
        recipient_class=int(value.ulRecipClass),
    )


class CtypesSimpleMapiApi:
    """Thin no-UI wrapper around the documented Simple MAPI entry points."""

    def __init__(self) -> None:
        if os.name != "nt" or not hasattr(ctypes, "WinDLL"):
            raise WindowsMapiUnsupported("Windows Simple MAPI is available only on Windows")
        try:
            kernel32 = ctypes.WinDLL("kernel32.dll", use_last_error=True)
            get_system_directory = kernel32.GetSystemDirectoryW
            get_system_directory.argtypes = [ctypes.POINTER(ctypes.c_wchar), ctypes.c_uint32]
            get_system_directory.restype = ctypes.c_uint32
            system_directory = ctypes.create_unicode_buffer(32768)
            length = int(get_system_directory(system_directory, len(system_directory)))
            if length == 0 or length >= len(system_directory):
                raise OSError(ctypes.get_last_error(), "GetSystemDirectoryW failed")
            library_path = Path(system_directory.value) / "MAPI32.dll"
            self.library = ctypes.WinDLL(str(library_path), use_last_error=True)
        except OSError as exc:
            raise WindowsMapiUnsupported(f"Cannot load the system Simple MAPI stub: {exc}") from exc

        self._logon = self.library.MAPILogon
        self._logon.argtypes = [
            ctypes.c_size_t,
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_size_t),
        ]
        self._logon.restype = ctypes.c_uint32
        self._logoff = self.library.MAPILogoff
        self._logoff.argtypes = [ctypes.c_size_t, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
        self._logoff.restype = ctypes.c_uint32
        self._find_next = self.library.MAPIFindNext
        self._find_next.argtypes = [
            ctypes.c_size_t,
            ctypes.c_size_t,
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_char_p,
        ]
        self._find_next.restype = ctypes.c_uint32
        self._read_mail = self.library.MAPIReadMail
        self._read_mail.argtypes = [
            ctypes.c_size_t,
            ctypes.c_size_t,
            ctypes.c_char_p,
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.POINTER(ctypes.POINTER(_MapiMessageA)),
        ]
        self._read_mail.restype = ctypes.c_uint32
        self._free_buffer = self.library.MAPIFreeBuffer
        self._free_buffer.argtypes = [ctypes.c_void_p]
        self._free_buffer.restype = ctypes.c_uint32
        try:
            self._send_mail_w = self.library.MAPISendMailW
        except AttributeError:
            self._send_mail_w = None
        if self._send_mail_w is not None:
            self._send_mail_w.argtypes = [
                ctypes.c_size_t,
                ctypes.c_size_t,
                ctypes.POINTER(_MapiMessageW),
                ctypes.c_uint32,
                ctypes.c_uint32,
            ]
            self._send_mail_w.restype = ctypes.c_uint32
        try:
            self._save_mail = self.library.MAPISaveMail
            self._save_mail.argtypes = [ctypes.c_size_t, ctypes.c_size_t, ctypes.POINTER(_MapiMessageA), ctypes.c_uint32, ctypes.c_uint32, ctypes.c_char_p]
            self._save_mail.restype = ctypes.c_uint32
        except AttributeError:
            self._save_mail = None
        try:
            self._delete_mail = self.library.MAPIDeleteMail
            self._delete_mail.argtypes = [ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint32]
            self._delete_mail.restype = ctypes.c_uint32
        except AttributeError:
            self._delete_mail = None

    @property
    def unicode_send_available(self) -> bool:
        return self._send_mail_w is not None

    @property
    def draft_save_available(self) -> bool:
        return self._save_mail is not None

    @property
    def delete_available(self) -> bool:
        return self._delete_mail is not None

    def open_shared_session(self) -> int:
        session = ctypes.c_size_t()
        # Null profile/password and zero flags intentionally forbid login UI and a
        # new interactive session. A provider must supply an existing shared login.
        result = int(self._logon(0, None, None, 0, 0, ctypes.byref(session)))
        if result != 0:
            raise _mapi_error("shared-session logon", result)
        return int(session.value)

    def close_session(self, session: int) -> None:
        if not session:
            return
        result = int(self._logoff(session, 0, 0, 0))
        if result not in {0, 19}:
            raise _mapi_error("logoff", result)

    def find_next(self, session: int, seed: str, *, unread_only: bool) -> str | None:
        output = ctypes.create_string_buffer(MAPI_MESSAGE_ID_LENGTH)
        flags = MAPI_GUARANTEE_FIFO | (MAPI_UNREAD_ONLY if unread_only else 0)
        result = int(
            self._find_next(
                session,
                0,
                None,
                _encode_ansi(seed) if seed else None,
                flags,
                0,
                output,
            )
        )
        if result == 16:
            return None
        if result != 0:
            raise _mapi_error("message enumeration", result)
        return _decode_ansi(output.value)

    def read_message(
        self,
        session: int,
        message_id: str,
        *,
        peek: bool,
        envelope_only: bool = False,
        include_attachments: bool = False,
    ) -> MapiMessageData:
        pointer = ctypes.POINTER(_MapiMessageA)()
        flags = 0 if include_attachments else MAPI_SUPPRESS_ATTACH
        if peek:
            flags |= MAPI_PEEK
        if envelope_only:
            flags |= MAPI_ENVELOPE_ONLY
        result = int(
            self._read_mail(
                session,
                0,
                _encode_ansi(message_id),
                flags,
                0,
                ctypes.byref(pointer),
            )
        )
        if result != 0:
            raise _mapi_error("message read", result)
        if not pointer:
            raise WindowsMapiError("Windows Simple MAPI returned an empty message pointer")
        try:
            value = pointer.contents
            if int(value.nRecipCount) > 1000:
                raise WindowsMapiError("Windows Simple MAPI returned too many recipient records")
            if int(value.nRecipCount) and not value.lpRecips:
                raise WindowsMapiError("Windows Simple MAPI returned an invalid recipient array")
            recipients = tuple(_copy_recipient(value.lpRecips[index]) for index in range(int(value.nRecipCount)))
            originator = _copy_recipient(value.lpOriginator.contents) if value.lpOriginator else None
            utf8_message = int(value.ulReserved) == 65001
            attachments: list[MapiAttachmentData] = []
            if include_attachments:
                if int(value.nFileCount) > 100:
                    raise WindowsMapiError("Windows Simple MAPI returned too many attachments")
                if int(value.nFileCount) and not value.lpFiles:
                    raise WindowsMapiError("Windows Simple MAPI returned an invalid attachment array")
                for index in range(int(value.nFileCount)):
                    descriptor = value.lpFiles[index]
                    path = _decode_ansi(descriptor.lpszPathName, utf8_first=utf8_message)
                    filename = _decode_ansi(descriptor.lpszFileName, utf8_first=utf8_message) or Path(path).name
                    if not path:
                        raise WindowsMapiError("Windows Simple MAPI returned an attachment without a path")
                    try:
                        temporary_root = Path(tempfile.gettempdir()).resolve()
                        resolved_path = Path(path).resolve()
                        if resolved_path == temporary_root or temporary_root not in resolved_path.parents:
                            raise WindowsMapiError("Windows Simple MAPI returned an attachment outside its temporary directory")
                    except OSError as exc:
                        raise WindowsMapiError("Windows Simple MAPI returned an invalid attachment path") from exc
                    try:
                        data = resolved_path.read_bytes()
                    except OSError as exc:
                        raise WindowsMapiError("Windows Simple MAPI attachment could not be read") from exc
                    if len(data) > 100 * 1024 * 1024:
                        raise WindowsMapiError("Windows Simple MAPI attachment exceeds the 100 MiB safety limit")
                    attachments.append(MapiAttachmentData(filename=filename, content_type=None, data=data))
                    try:
                        resolved_path.unlink(missing_ok=True)
                    except OSError:
                        pass
            return MapiMessageData(
                subject=_decode_ansi(value.lpszSubject, utf8_first=utf8_message),
                body=_decode_ansi(value.lpszNoteText, utf8_first=utf8_message),
                date_received=_decode_ansi(value.lpszDateReceived, utf8_first=utf8_message),
                flags=int(value.flFlags),
                originator=originator,
                recipients=recipients,
                attachment_count=int(value.nFileCount),
                attachments=tuple(attachments),
            )
        finally:
            self._free_buffer(pointer)

    def send_message(
        self,
        session: int,
        *,
        sender_name: str,
        sender_address: str,
        recipients: Sequence[tuple[int, str, str]],
        subject: str,
        body: str,
        attachments: Sequence[tuple[str, str]],
    ) -> None:
        if self._send_mail_w is None:
            raise WindowsMapiUnsupported("The registered Simple MAPI provider does not expose Unicode sending")

        recipient_array_type = _MapiRecipDescW * len(recipients)
        recipient_array = recipient_array_type(
            *(
                _MapiRecipDescW(
                    0,
                    recipient_class,
                    name or address,
                    f"SMTP:{address}",
                    0,
                    None,
                )
                for recipient_class, name, address in recipients
            )
        )
        file_array_type = _MapiFileDescW * len(attachments)
        file_array = file_array_type(
            *(
                _MapiFileDescW(0, 0, 0xFFFFFFFF, path, filename, None)
                for path, filename in attachments
            )
        )
        originator = _MapiRecipDescW(
            0,
            0,
            sender_name or sender_address,
            f"SMTP:{sender_address}",
            0,
            None,
        )
        message = _MapiMessageW(
            0,
            subject,
            body,
            None,
            None,
            None,
            0,
            ctypes.pointer(originator),
            len(recipients),
            recipient_array if recipients else None,
            len(attachments),
            file_array if attachments else None,
        )
        # MAPI_FORCE_UNICODE is the only flag; no interactive flag is passed.
        result = int(self._send_mail_w(session, 0, ctypes.byref(message), MAPI_FORCE_UNICODE, 0))
        if result != 0:
            raise _mapi_error("message submission", result)

    def save_draft(
        self,
        session: int,
        *,
        sender_address: str,
        recipients: Sequence[tuple[int, str, str]],
        subject: str,
        body: str,
        attachments: Sequence[tuple[str, str]],
    ) -> str:
        if self._save_mail is None:
            raise WindowsMapiUnsupported("The registered Simple MAPI provider does not expose MAPISaveMail")
        recipient_array_type = _MapiRecipDescA * len(recipients)
        recipient_buffers: list[tuple[bytes, bytes]] = []
        recipient_array = recipient_array_type()
        for index, (recipient_class, name, address) in enumerate(recipients):
            name_bytes, address_bytes = _encode_ansi(name), _encode_ansi(f"SMTP:{address}")
            recipient_buffers.append((name_bytes, address_bytes))
            recipient_array[index] = _MapiRecipDescA(0, recipient_class, name_bytes, address_bytes, 0, None)
        file_array_type = _MapiFileDescA * len(attachments)
        file_buffers: list[tuple[bytes, bytes]] = []
        file_array = file_array_type()
        for index, (path, filename) in enumerate(attachments):
            path_bytes, filename_bytes = _encode_ansi(path), _encode_ansi(filename)
            file_buffers.append((path_bytes, filename_bytes))
            file_array[index] = _MapiFileDescA(0, 0, 0xFFFFFFFF, path_bytes, filename_bytes, None)
        subject_bytes, body_bytes, sender_bytes = _encode_ansi(subject), _encode_ansi(body), _encode_ansi(sender_address)
        originator = _MapiRecipDescA(0, 0, sender_bytes, sender_bytes, 0, None)
        message = _MapiMessageA(0, subject_bytes, body_bytes, None, None, None, 0, ctypes.pointer(originator),
                                 len(recipients), recipient_array if recipients else None, len(attachments),
                                 file_array if attachments else None)
        output = ctypes.create_string_buffer(MAPI_MESSAGE_ID_LENGTH)
        result = int(self._save_mail(session, 0, ctypes.byref(message), MAPI_LONG_MSGID, 0, output))
        if result != 0:
            raise _mapi_error("draft save", result)
        return _decode_ansi(output.value)

    def delete_message(self, session: int, message_id: str) -> None:
        if self._delete_mail is None:
            raise WindowsMapiUnsupported("The registered Simple MAPI provider does not expose MAPIDeleteMail")
        result = int(self._delete_mail(session, 0, _encode_ansi(message_id), 0, 0))
        if result != 0:
            raise _mapi_error("message deletion", result)


def probe_coremail_shared_session(api: Any | None = None) -> dict[str, Any]:
    registration = detect_coremail_mapi_registration()
    result = {
        **registration,
        "shared_session_checked": False,
        "shared_session_available": False,
        "usable": False,
    }
    if not registration["candidate"]:
        return result
    session = 0
    try:
        current_api = api or CtypesSimpleMapiApi()
        result["shared_session_checked"] = True
        session = current_api.open_shared_session()
        result["shared_session_available"] = True
        result["unicode_send_available"] = bool(current_api.unicode_send_available)
        result["usable"] = bool(current_api.unicode_send_available)
        if not result["usable"]:
            result["reason"] = "The provider does not expose no-UI Unicode message submission"
        else:
            result.pop("reason", None)
    except WindowsMapiError as exc:
        result["shared_session_checked"] = True
        result["reason"] = str(exc)
    finally:
        if session:
            try:
                current_api.close_session(session)
            except WindowsMapiError:
                pass
    return result


def _folder_inbox(folder: str) -> None:
    if folder.casefold() != "inbox":
        raise WindowsMapiUnsupported("Windows Simple MAPI exposes only the INBOX receive folder")


def _query_date(value: Any, field: str) -> dt.date:
    if not isinstance(value, str):
        raise WindowsMapiError(f"Search field must be a string: {field}")
    try:
        return dt.date.fromisoformat(value)
    except ValueError as exc:
        raise WindowsMapiError(f"{field} must be an ISO date in YYYY-MM-DD form") from exc


def _received_datetime(value: str) -> dt.datetime | None:
    normalized = value.strip().replace("/", "-")
    if not normalized:
        return None
    for parser in (
        dt.datetime.fromisoformat,
        lambda text: dt.datetime.strptime(text, "%Y-%m-%d %H:%M"),
        lambda text: dt.datetime.strptime(text, "%Y-%m-%d %H:%M:%S"),
    ):
        try:
            return parser(normalized)
        except ValueError:
            continue
    return None


def _sortable_datetime(value: str) -> dt.datetime:
    parsed = _received_datetime(value)
    if parsed is None:
        return dt.datetime.min
    if parsed.tzinfo is not None:
        return parsed.astimezone(dt.timezone.utc).replace(tzinfo=None)
    return parsed


def _display_group(recipients: Sequence[MapiRecipient], recipient_class: int) -> str:
    return ", ".join(item.display() for item in recipients if item.recipient_class == recipient_class)


def _message_flags(message: MapiMessageData) -> list[str]:
    return [] if message.flags & MAPI_UNREAD else ["\\Seen"]


class SimpleMapiClient:
    def __init__(self, api: Any | None = None, registration: Mapping[str, Any] | None = None) -> None:
        self._api = api
        self._registration = dict(registration) if registration is not None else None
        self._session = 0
        self._uidvalidity = str(secrets.randbits(63) or 1)
        self._uid_by_message_id: dict[str, str] = {}
        self._message_id_by_uid: dict[str, str] = {}

    def connect(self) -> None:
        if self._session:
            return
        registration = self._registration or detect_coremail_mapi_registration()
        if not registration.get("candidate"):
            raise WindowsMapiUnsupported(str(registration.get("reason", "Coremail Simple MAPI is not registered")))
        self._api = self._api or CtypesSimpleMapiApi()
        self._session = int(self._api.open_shared_session())

    def close(self) -> None:
        session, self._session = self._session, 0
        if session and self._api is not None:
            self._api.close_session(session)
        self._uid_by_message_id.clear()
        self._message_id_by_uid.clear()
        self._uidvalidity = str(secrets.randbits(63) or 1)

    def _require_session(self) -> int:
        self.connect()
        return self._session

    def _uid_for(self, message_id: str) -> str:
        existing = self._uid_by_message_id.get(message_id)
        if existing:
            return existing
        uid = str(len(self._uid_by_message_id) + 1)
        self._uid_by_message_id[message_id] = uid
        self._message_id_by_uid[uid] = message_id
        return uid

    def _message_id_for(self, uid: str, expected_uidvalidity: str | None) -> str:
        if expected_uidvalidity is not None and str(expected_uidvalidity) != self._uidvalidity:
            raise WindowsMapiError("Simple MAPI session changed; search again before acting on this message")
        if not uid.isdigit() or uid not in self._message_id_by_uid:
            raise WindowsMapiError("Unknown Simple MAPI message UID; search again in this MCP session")
        return self._message_id_by_uid[uid]

    def status(self) -> dict[str, Any]:
        session = self._require_session()
        registration = self._registration or detect_coremail_mapi_registration()
        return {
            "transport": INTERFACE_NAME,
            "connected": bool(session),
            "registered_client": registration.get("registered_client"),
            "existing_shared_session": True,
            "ui_requested": False,
            "capabilities": {
                "folders": ["INBOX"],
                "read_body_formats": ["text/plain"],
                "send_body_formats": ["text/plain"],
                "preserve_unread_requested": True,
                "preserve_unread_guarantee": "provider_dependent",
                "mark_read": True,
                "mark_unread": False,
                "save_draft": bool(getattr(self._api, "draft_save_available", False)),
                "save_draft_folder_guarantee": False,
                "delete_message": bool(getattr(self._api, "delete_available", False)),
                "send": bool(self._api.unicode_send_available),
                "incoming_attachments_materialized": True,
                "incoming_attachments_note": "Attachments are copied to bounded in-memory bytes only when explicitly downloaded",
                "raw_rfc822": False,
                "mime_tree": False,
                "threading_headers": False,
            },
        }

    def list_folders(self) -> dict[str, Any]:
        self._require_session()
        folders = [{"name": "INBOX", "raw_name": "INBOX", "flags": ["\\Inbox"], "delimiter": None}]
        return {
            "folders": folders,
            "count": 1,
            "transport": INTERFACE_NAME,
            "capability_note": "Simple MAPI exposes only the receive INBOX folder",
        }

    def _header(self, message_id: str, message: MapiMessageData) -> dict[str, Any]:
        received = _received_datetime(message.date_received)
        return {
            "uid": self._uid_for(message_id),
            "subject": message.subject,
            "from": message.originator.display() if message.originator else "",
            "to": _display_group(message.recipients, MAPI_TO),
            "cc": _display_group(message.recipients, MAPI_CC),
            "date": received.isoformat() if received else (message.date_received or None),
            "message_id": None,
            "in_reply_to": None,
            "references": None,
            "flags": _message_flags(message),
            "size": None,
        }

    def search(self, *, folder: str, query: Mapping[str, Any], limit: int, max_scan: int = 500) -> dict[str, Any]:
        _folder_inbox(folder)
        if limit < 1 or limit > 100:
            raise WindowsMapiError("limit must be between 1 and 100")
        allowed_fields = {"from", "to", "subject", "text", "since", "before", "unseen", "flagged"}
        unknown = sorted(str(field) for field in query if field not in allowed_fields)
        if unknown:
            raise WindowsMapiError(f"Unknown search query field(s): {', '.join(unknown)}")
        if "flagged" in query:
            raise WindowsMapiUnsupported("Windows Simple MAPI does not expose flagged state")
        for field in ("unseen",):
            if field in query and not isinstance(query[field], bool):
                raise WindowsMapiError(f"Search field must be true or false: {field}")
        text_values: dict[str, str] = {}
        for field in ("from", "to", "subject", "text"):
            value = query.get(field)
            if value is None:
                continue
            if not isinstance(value, str):
                raise WindowsMapiError(f"Search field must be a string: {field}")
            if len(value) > 500 or "\r" in value or "\n" in value:
                raise WindowsMapiError(f"Invalid or too-long search field: {field}")
            if value.strip():
                text_values[field] = value.strip().casefold()
        since = _query_date(query["since"], "since") if query.get("since") else None
        before = _query_date(query["before"], "before") if query.get("before") else None

        session = self._require_session()
        seed = ""
        candidates: list[tuple[str, MapiMessageData]] = []
        truncated = False
        for index in range(max_scan + 1):
            message_id = self._api.find_next(session, seed, unread_only=query.get("unseen") is True)
            if message_id is None:
                break
            if message_id == seed:
                raise WindowsMapiError("Simple MAPI provider repeated a message identifier during enumeration")
            seed = message_id
            if index == max_scan:
                truncated = True
                break
            message = self._api.read_message(
                session,
                message_id,
                peek=True,
                envelope_only="text" not in text_values,
            )
            candidates.append((message_id, message))

        matches: list[tuple[str, MapiMessageData]] = []
        for message_id, message in candidates:
            sender = message.originator.display().casefold() if message.originator else ""
            to_recipients = _display_group(message.recipients, MAPI_TO).casefold()
            all_recipients = " ".join(item.display() for item in message.recipients).casefold()
            received = _received_datetime(message.date_received)
            is_unseen = bool(message.flags & MAPI_UNREAD)
            if "from" in text_values and text_values["from"] not in sender:
                continue
            if "to" in text_values and text_values["to"] not in to_recipients:
                continue
            if "subject" in text_values and text_values["subject"] not in message.subject.casefold():
                continue
            if "text" in text_values:
                haystack = f"{sender}\n{all_recipients}\n{message.subject}\n{message.body}".casefold()
                if text_values["text"] not in haystack:
                    continue
            if query.get("unseen") is False and is_unseen:
                continue
            if since and (received is None or received.date() < since):
                continue
            if before and (received is None or received.date() >= before):
                continue
            matches.append((message_id, message))

        matches.sort(key=lambda item: _sortable_datetime(item[1].date_received), reverse=True)
        returned = matches[:limit]
        return {
            "folder": "INBOX",
            "uidvalidity": self._uidvalidity,
            "message_count": len(candidates),
            "criteria": dict(query),
            "matched_count": len(matches),
            "returned_count": len(returned),
            "messages": [self._header(message_id, message) for message_id, message in returned],
            "transport": INTERFACE_NAME,
            "scan_limit": max_scan,
            "scan_truncated": truncated,
            "unread_state_note": (
                "MAPI_PEEK was requested. A provider that does not implement this flag can still mark messages read."
            ),
        }

    def get_message(
        self,
        *,
        folder: str,
        uid: str,
        expected_uidvalidity: str | None,
        max_body_chars: int,
    ) -> dict[str, Any]:
        _folder_inbox(folder)
        message_id = self._message_id_for(uid, expected_uidvalidity)
        message = self._api.read_message(self._require_session(), message_id, peek=True)
        body = message.body
        truncated = len(body) > max_body_chars
        if truncated:
            body = body[:max_body_chars] + "…"
        header = self._header(message_id, message)
        return {
            "folder": "INBOX",
            "uidvalidity": self._uidvalidity,
            "message_count": None,
            **header,
            "bcc": _display_group(message.recipients, MAPI_BCC),
            "reply_to": "",
            "headers": {"Subject": [message.subject]} if message.subject else {},
            "body": body,
            "body_source": "Windows Simple MAPI note text",
            "body_truncated": truncated,
            "body_text": message.body[:max_body_chars],
            "body_text_truncated": truncated,
            "body_html": None,
            "body_html_truncated": False,
            "body_calendar": None,
            "body_calendar_truncated": False,
            "body_html_unavailable_reason": (
                "Windows Simple MAPI exposes only MapiMessage note text; HTML MIME content is unavailable"
            ),
            "attachments": [],
            "attachments_suppressed": True,
            "provider_attachment_count": message.attachment_count,
            "content_is_untrusted": True,
            "transport": INTERFACE_NAME,
            "unread_state_note": (
                "MAPI_PEEK was requested. A provider that does not implement this flag can still mark this message read."
            ),
        }

    def download_attachment(
        self,
        *,
        folder: str,
        uid: str,
        expected_uidvalidity: str | None,
        index: int,
    ) -> dict[str, Any]:
        _folder_inbox(folder)
        if not isinstance(index, int) or index < 0 or index >= 100:
            raise WindowsMapiError("attachment index must be between 0 and 99")
        message_id = self._message_id_for(uid, expected_uidvalidity)
        try:
            message = self._api.read_message(self._require_session(), message_id, peek=True, include_attachments=True)
        except TypeError as exc:
            raise WindowsMapiUnsupported("The active Simple MAPI provider adapter cannot materialize attachments") from exc
        attachments = getattr(message, "attachments", ())
        if index >= len(attachments):
            raise WindowsMapiError("Attachment index is not present in this message")
        attachment = attachments[index]
        return {
            "folder": "INBOX", "uidvalidity": self._uidvalidity, "uid": uid, "part_id": str(index + 1),
            "filename": attachment.filename, "content_type": attachment.content_type,
            "size": len(attachment.data), "data_base64": base64.b64encode(attachment.data).decode("ascii"),
            "transport": INTERFACE_NAME, "content_is_untrusted": True,
        }

    def set_seen(
        self,
        *,
        folder: str,
        uid: str,
        expected_uidvalidity: str | None,
        seen: bool,
    ) -> dict[str, Any]:
        _folder_inbox(folder)
        if not seen:
            raise WindowsMapiUnsupported("This Windows Simple MAPI adapter cannot mark a message unread; use IMAP/SMTP mode")
        message_id = self._message_id_for(uid, expected_uidvalidity)
        self._api.read_message(self._require_session(), message_id, peek=False)
        return {
            "folder": "INBOX",
            "uidvalidity": self._uidvalidity,
            "message_count": None,
            "uid": uid,
            "seen": True,
            "updated": True,
            "transport": INTERFACE_NAME,
        }

    def send(
        self,
        *,
        sender_name: str,
        sender_address: str,
        recipients: Sequence[tuple[int, str, str]],
        subject: str,
        body: str,
        attachments: Sequence[tuple[str, str]],
        message_id: str,
    ) -> dict[str, Any]:
        session = self._require_session()
        self._api.send_message(
            session,
            sender_name=sender_name,
            sender_address=sender_address,
            recipients=recipients,
            subject=subject,
            body=body,
            attachments=attachments,
        )
        submitted = [address for _, _, address in recipients]
        return {
            "mapi_submitted": True,
            "transport": INTERFACE_NAME,
            "message_id": message_id,
            "submitted_recipients": submitted,
            "delivery_note": (
                "Simple MAPI accepted the handoff to the active provider; this is not recipient validation "
                "or final delivery confirmation."
            ),
            "sent_copy": {"appended": False, "reason": "Sent-folder behavior is owned by the MAPI provider"},
            "sender_identity_note": "The active Simple MAPI provider controls the final submitting account.",
        }

    def save_draft(
        self,
        *,
        sender_address: str,
        recipients: Sequence[tuple[int, str, str]],
        subject: str,
        body: str,
        attachments: Sequence[tuple[str, str]],
        message_id: str,
    ) -> dict[str, Any]:
        session = self._require_session()
        if not bool(getattr(self._api, "draft_save_available", False)) or not hasattr(self._api, "save_draft"):
            raise WindowsMapiUnsupported("The registered Simple MAPI provider does not expose draft saving")
        provider_id = self._api.save_draft(session, sender_address=sender_address,
                                           recipients=recipients, subject=subject, body=body, attachments=attachments)
        return {"saved": True, "transport": INTERFACE_NAME, "message_id": message_id,
                "provider_message_id": provider_id, "folder": None,
                "folder_note": "MAPISaveMail does not guarantee which provider folder stores the draft"}

    def delete_message(self, *, folder: str, uid: str, expected_uidvalidity: str | None, permanent: bool) -> dict[str, Any]:
        _folder_inbox(folder)
        if not permanent:
            raise WindowsMapiUnsupported("Simple MAPI has no reversible Deleted flag; use permanent=true only when explicitly authorized")
        message_id = self._message_id_for(uid, expected_uidvalidity)
        session = self._require_session()
        if not bool(getattr(self._api, "delete_available", False)) or not hasattr(self._api, "delete_message"):
            raise WindowsMapiUnsupported("The registered Simple MAPI provider does not expose MAPIDeleteMail")
        self._api.delete_message(session, message_id)
        return {"deleted": True, "permanent": True, "transport": INTERFACE_NAME,
                "uid": uid, "folder": "INBOX", "provider_note": "Simple MAPI deletion has no Trash guarantee"}


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Probe a no-UI Coremail Simple MAPI shared session")
    parser.add_argument("--probe-json", action="store_true")
    arguments = parser.parse_args()
    if not arguments.probe_json:
        parser.error("--probe-json is required")
    result = probe_coremail_shared_session()
    result["python_pointer_bits"] = ctypes.sizeof(ctypes.c_void_p) * 8
    # ASCII-only JSON survives Windows PowerShell 5.1 native-process encoding.
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
