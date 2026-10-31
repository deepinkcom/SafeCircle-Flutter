from app.notification_service import NotificationService


def test_send_to_token_succeeds_with_fake_sender():
    calls = []

    def fake_sender(token, title, body):
        calls.append((token, title, body))
        return "fake-message-123"

    service = NotificationService(sender=fake_sender)
    result = service.send_to_token(
        "  fake-token  ",
        "  Test alert  ",
        "  This is a test only  ",
    )

    assert result.success is True
    assert result.message_id == "fake-message-123"
    assert calls == [
        ("fake-token", "Test alert", "This is a test only")
    ]


def test_empty_token_is_rejected_without_sending():
    def fake_sender(token, title, body):
        raise AssertionError("Sender must not be called")

    service = NotificationService(sender=fake_sender)
    result = service.send_to_token("", "Test alert", "Test body")

    assert result.success is False
    assert result.error == "FCM token is empty"


def test_missing_title_or_body_is_rejected():
    def fake_sender(token, title, body):
        raise AssertionError("Sender must not be called")

    service = NotificationService(sender=fake_sender)

    missing_title = service.send_to_token("fake-token", "  ", "Test body")
    missing_body = service.send_to_token("fake-token", "Test alert", "  ")

    assert missing_title.success is False
    assert missing_title.error == "Notification title and body are required"
    assert missing_body.success is False
    assert missing_body.error == "Notification title and body are required"


def test_sender_failure_returns_safe_error():
    def fake_sender(token, title, body):
        raise RuntimeError("Simulated provider failure")

    service = NotificationService(sender=fake_sender)
    result = service.send_to_token(
        "fake-token",
        "Test alert",
        "This is a test only",
    )

    assert result.success is False
    assert result.message_id is None
    assert result.error == "Notification delivery failed"


def test_firebase_sender_uses_mocked_firebase(monkeypatch):
    from types import SimpleNamespace

    from app import auth, notification_service
    from app.notification_service import firebase_sender

    calls = []
    monkeypatch.setattr(auth, "initialize_firebase", lambda: calls.append("initialized"))

    fake_messaging = SimpleNamespace(
        Notification=lambda title, body: {
            "title": title,
            "body": body,
        },
        Message=lambda notification, token: {
            "notification": notification,
            "token": token,
        },
        send=lambda message: calls.append(message) or "fake-fcm-message-id",
    )
    monkeypatch.setattr(
        "firebase_admin.messaging.Notification",
        fake_messaging.Notification,
    )
    monkeypatch.setattr(
        "firebase_admin.messaging.Message",
        fake_messaging.Message,
    )
    monkeypatch.setattr(
        "firebase_admin.messaging.send",
        fake_messaging.send,
    )

    result = firebase_sender(
        "fake-test-token",
        "Test alert",
        "Mocked notification only",
    )

    assert result == "fake-fcm-message-id"
    assert calls[0] == "initialized"
    assert calls[1]["token"] == "fake-test-token"
    assert calls[1]["notification"] == {
        "title": "Test alert",
        "body": "Mocked notification only",
    }


def test_notification_service_defaults_to_unconfigured_sender():
    from app.notification_service import NotificationService

    service = NotificationService()
    result = service.send_to_token(
        "fake-test-token",
        "Test alert",
        "Mocked notification only",
    )

    assert result.success is False
    assert result.message_id is None
    assert result.error == "Notification delivery failed"
