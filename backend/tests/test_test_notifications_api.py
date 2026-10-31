from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.auth import get_current_user, get_db
from app.models import Device, User
from app.notification_service import NotificationService
from app.test_notifications import router


class FakeSession:
    def __init__(self, device=None):
        self.device = device
        self.statement = None

    def scalar(self, statement):
        self.statement = statement
        return self.device


fake_user = User(
    id=42,
    firebase_uid="fake-firebase-uid",
    name="Test User",
    email="test@example.invalid",
    city="Test City",
    phone="0000000000",
)


def make_device(user_id=42, token="fake-test-token"):
    return Device(
        id=7,
        user_id=user_id,
        fcm_token=token,
        platform="android",
        registered_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
    )


def create_client(fake_db):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_current_user] = lambda: fake_user
    app.dependency_overrides[get_db] = lambda: fake_db
    return TestClient(app)


def test_test_notification_route_is_disabled_by_default(monkeypatch):
    monkeypatch.delenv("SAFECIRCLE_ENABLE_TEST_NOTIFICATIONS", raising=False)
    fake_db = FakeSession(device=make_device())
    client = create_client(fake_db)

    response = client.post("/test-notifications/me")

    assert response.status_code == 404
    assert response.json()["detail"] == "Not found"


def test_test_notification_uses_fake_sender_for_current_users_device(monkeypatch):
    monkeypatch.setenv("SAFECIRCLE_ENABLE_TEST_NOTIFICATIONS", "true")
    fake_db = FakeSession(device=make_device())
    client = create_client(fake_db)
    calls = []

    def fake_sender(token, title, body):
        calls.append((token, title, body))
        return "fake-message-id"

    monkeypatch.setattr(
        "app.test_notifications.NotificationService",
        lambda sender: NotificationService(sender=fake_sender),
    )

    response = client.post("/test-notifications/me")

    assert response.status_code == 200
    assert response.json()["success"] is True
    assert response.json()["message_id"] == "fake-message-id"
    assert calls == [
        (
            "fake-test-token",
            "SafeCircle test notification",
            "This is a test notification. No emergency alert was created.",
        )
    ]
    assert "fake-test-token" not in response.text
