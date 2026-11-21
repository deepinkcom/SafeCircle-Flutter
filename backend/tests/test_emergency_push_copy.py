from types import SimpleNamespace

import pytest
from firebase_admin import messaging

from app.notification_service import firebase_notification_delivery


@pytest.mark.parametrize(
    "category,event_type,expected_title,expected_body",
    [
        (
            "emergency",
            "emergency.panic",
            "SafeCircle emergency alert",
            "A SafeCircle connection has triggered a panic alert.",
        ),
        (
            "connection",
            "connection.invited",
            "SafeCircle",
            "You have a SafeCircle update.",
        ),
        (
            "emergency",
            "emergency.acknowledged",
            "A connection is responding",
            "Jordan is on their way to help.",
        ),
    ],
)
def test_fcm_copy_is_emergency_specific_and_contains_no_location(
    monkeypatch, category, event_type, expected_title, expected_body
):
    monkeypatch.setattr("app.auth.initialize_firebase", lambda: None)
    sent = []
    monkeypatch.setattr(
        messaging,
        "send",
        lambda message: sent.append(message) or "synthetic-message-id",
    )

    firebase_notification_delivery(
        "synthetic-device-token",
        SimpleNamespace(
            id=17,
            category=category,
            event_type=event_type,
            title=expected_title if event_type == "emergency.acknowledged" else "A connection is responding",
            message=expected_body if event_type == "emergency.acknowledged" else "Jordan is on their way to help.",
        ),
        "synthetic-recipient-uid",
    )

    assert len(sent) == 1
    assert sent[0].notification.title == expected_title
    assert sent[0].notification.body == expected_body
    assert "location" not in sent[0].notification.body.lower()
    assert "synthetic" not in sent[0].notification.body.lower()
    assert sent[0].data == {
        "notification_id": "17",
        "recipient_uid": "synthetic-recipient-uid",
    }
