from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
MCP_DIR = ROOT / "mcp"
sys.path.insert(0, str(MCP_DIR))

from windows_mapi import (  # noqa: E402
    MAPI_CC,
    MAPI_TO,
    MAPI_UNREAD,
    MapiMessageData,
    MapiRecipient,
    SimpleMapiClient,
    WindowsMapiUnsupported,
    is_coremail_client_name,
    probe_coremail_shared_session,
)


class FakeMapiApi:
    unicode_send_available = True

    def __init__(self) -> None:
        self.session_opened = False
        self.session_closed = False
        self.reads: list[tuple[str, bool]] = []
        self.sent = None
        self.order = ["provider-1", "provider-2"]
        self.messages = {
            "provider-1": MapiMessageData(
                subject="Older read message",
                body="ordinary body",
                date_received="2026/08/28 09:00",
                flags=0,
                originator=MapiRecipient("Alice", "SMTP:alice@example.com", 0),
                recipients=(MapiRecipient("User", "SMTP:user@example.com", MAPI_TO),),
                attachment_count=0,
            ),
            "provider-2": MapiMessageData(
                subject="Important unread report",
                body="quarterly result",
                date_received="2026/08/30 10:30",
                flags=MAPI_UNREAD,
                originator=MapiRecipient("Bob", "SMTP:bob@example.com", 0),
                recipients=(
                    MapiRecipient("User", "SMTP:user@example.com", MAPI_TO),
                    MapiRecipient("Audit", "SMTP:audit@example.com", MAPI_CC),
                ),
                attachment_count=2,
            ),
        }

    def open_shared_session(self) -> int:
        self.session_opened = True
        return 77

    def close_session(self, session: int) -> None:
        self.session_closed = session == 77

    def find_next(self, session: int, seed: str, *, unread_only: bool) -> str | None:
        order = [
            message_id
            for message_id in self.order
            if not unread_only or self.messages[message_id].flags & MAPI_UNREAD
        ]
        if not seed:
            return order[0] if order else None
        try:
            return order[order.index(seed) + 1]
        except (ValueError, IndexError):
            return None

    def read_message(
        self,
        session: int,
        message_id: str,
        *,
        peek: bool,
        envelope_only: bool = False,
    ) -> MapiMessageData:
        self.reads.append((message_id, peek))
        return self.messages[message_id]

    def send_message(self, session: int, **values) -> None:
        self.sent = {"session": session, **values}


def client_for(api: FakeMapiApi | None = None) -> SimpleMapiClient:
    return SimpleMapiClient(
        api=api or FakeMapiApi(),
        registration={
            "candidate": True,
            "registered_client": "Coremail",
            "recognized_coremail_client": True,
            "provider_registered": True,
        },
    )


class RegistrationTests(unittest.TestCase):
    def test_only_coremail_names_are_recognized(self) -> None:
        for value in ("Coremail", "Coremail Lunkr", "论客", "盈世 Coremail"):
            self.assertTrue(is_coremail_client_name(value))
        for value in (None, "", "Microsoft Outlook", "Thunderbird"):
            self.assertFalse(is_coremail_client_name(value))

    def test_probe_closes_the_attached_shared_session(self) -> None:
        api = FakeMapiApi()
        registration = {
            "candidate": True,
            "registered_client": "Coremail",
            "recognized_coremail_client": True,
            "provider_registered": True,
        }
        with patch("windows_mapi.detect_coremail_mapi_registration", return_value=registration):
            result = probe_coremail_shared_session(api)
        self.assertTrue(result["usable"])
        self.assertTrue(result["shared_session_available"])
        self.assertTrue(api.session_closed)


class SimpleMapiClientTests(unittest.TestCase):
    def test_status_attaches_shared_session_without_ui(self) -> None:
        api = FakeMapiApi()
        client = client_for(api)
        status = client.status()
        self.assertTrue(status["connected"])
        self.assertTrue(status["existing_shared_session"])
        self.assertFalse(status["ui_requested"])
        self.assertEqual(
            status["capabilities"]["preserve_unread_guarantee"],
            "provider_dependent",
        )
        self.assertTrue(api.session_opened)

    def test_search_and_read_preserve_unread_and_use_session_identity(self) -> None:
        api = FakeMapiApi()
        client = client_for(api)
        result = client.search(
            folder="INBOX",
            query={"subject": "report", "unseen": True, "since": "2026-08-29"},
            limit=10,
        )
        self.assertEqual(result["returned_count"], 1)
        self.assertFalse(result["scan_truncated"])
        self.assertIn("provider", result["unread_state_note"].lower())
        item = result["messages"][0]
        self.assertIn("unread report", item["subject"])
        self.assertEqual(item["flags"], [])
        self.assertTrue(all(peek for _, peek in api.reads))

        message = client.get_message(
            folder="INBOX",
            uid=item["uid"],
            expected_uidvalidity=result["uidvalidity"],
            max_body_chars=8,
        )
        self.assertEqual(message["body"], "quarterl…")
        self.assertTrue(message["attachments_suppressed"])
        self.assertEqual(message["provider_attachment_count"], 2)
        with self.assertRaisesRegex(Exception, "session changed"):
            client.get_message(
                folder="INBOX",
                uid=item["uid"],
                expected_uidvalidity="wrong",
                max_body_chars=100,
            )

    def test_mark_read_is_explicit_and_mark_unread_is_rejected(self) -> None:
        api = FakeMapiApi()
        client = client_for(api)
        search = client.search(folder="INBOX", query={"unseen": True}, limit=10)
        uid = search["messages"][0]["uid"]
        updated = client.set_seen(
            folder="INBOX",
            uid=uid,
            expected_uidvalidity=search["uidvalidity"],
            seen=True,
        )
        self.assertTrue(updated["updated"])
        self.assertIn(("provider-2", False), api.reads)
        with self.assertRaises(WindowsMapiUnsupported):
            client.set_seen(
                folder="INBOX",
                uid=uid,
                expected_uidvalidity=search["uidvalidity"],
                seen=False,
            )

    def test_send_hands_off_recipients_and_attachments_without_ui_flags(self) -> None:
        api = FakeMapiApi()
        client = client_for(api)
        result = client.send(
            sender_name="Sender",
            sender_address="sender@example.com",
            recipients=[(MAPI_TO, "Recipient", "recipient@example.com")],
            subject="Subject",
            body="Body",
            attachments=[("C:\\safe\\report.txt", "report.txt")],
            message_id="<local@example.com>",
        )
        self.assertTrue(result["mapi_submitted"])
        self.assertEqual(api.sent["session"], 77)
        self.assertEqual(api.sent["recipients"][0][2], "recipient@example.com")
        self.assertEqual(api.sent["attachments"][0][1], "report.txt")

    def test_unsupported_folder_and_flag_search_fail_closed(self) -> None:
        client = client_for()
        with self.assertRaises(WindowsMapiUnsupported):
            client.search(folder="Sent", query={}, limit=10)
        with self.assertRaises(WindowsMapiUnsupported):
            client.search(folder="INBOX", query={"flagged": True}, limit=10)


if __name__ == "__main__":
    unittest.main()
