from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.auth import get_current_user, get_db
from app.devices import router
from app.models import Device, User


class FakeSession:
    def __init__(self, existing_devices=None):
        self.existing_devices = list(existing_devices or [])
        self.added = []
        self.committed = False
        self.refreshed = False

    def scalar(self, statement):
        token = next(iter(statement.compile().params.values()), None)
        for device in self.existing_devices:
            if device.fcm_token == token:
                return device
        return None

    def add(self, device):
        self.added.append(device)

    def commit(self):
        self.committed = True
        for index, device in enumerate(self.added, start=1):
            device.id = index

    def refresh(self, device):
        self.refreshed = True
        if not hasattr(device, "registered_at") or device.registered_at is None:
            device.registered_at = datetime.now(timezone.utc)


fake_user = User(
    id=42,
    firebase_uid="fake-firebase-uid",
    name="Test User",
    email="test@example.invalid",
    city="Test City",
    phone="0000000000",
)


def create_test_client(fake_db):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_current_user] = lambda: fake_user
    app.dependency_overrides[get_db] = lambda: fake_db
    return TestClient(app)


def make_device(device_id, user_id, token, platform="android"):
    return Device(
        id=device_id,
        user_id=user_id,
        fcm_token=token,
        platform=platform,
        registered_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
    )


def test_register_new_device_stores_token_but_does_not_return_it():
    fake_db = FakeSession()
    client = create_test_client(fake_db)
    token = "fake-test-token-not-real"

    response = client.post(
        "/devices",
        json={"fcm_token": token, "platform": "android"},
    )

    assert response.status_code == 200
    assert len(fake_db.added) == 1
    stored_device = fake_db.added[0]
    assert stored_device.user_id == 42
    assert stored_device.fcm_token == token
    assert stored_device.platform == "android"
    assert fake_db.committed is True
    assert fake_db.refreshed is True
    assert response.json()["user_id"] == 42
    assert response.json()["platform"] == "android"
    assert "fcm_token" not in response.json()
    assert token not in response.text


def test_register_existing_device_for_same_user_reuses_record():
    existing = make_device(7, 42, "fake-existing-token")
    fake_db = FakeSession(existing_devices=[existing])
    client = create_test_client(fake_db)

    response = client.post(
        "/devices",
        json={"fcm_token": "fake-existing-token", "platform": "ios"},
    )

    assert response.status_code == 200
    assert fake_db.added == []
    assert existing.platform == "ios"
    assert existing.registered_at > datetime(2026, 1, 1, tzinfo=timezone.utc)
    assert fake_db.committed is True
    assert response.json()["id"] == 7
    assert "fcm_token" not in response.json()


def test_register_token_owned_by_another_user_is_rejected():
    existing = make_device(8, 99, "fake-other-users-token")
    fake_db = FakeSession(existing_devices=[existing])
    client = create_test_client(fake_db)

    response = client.post(
        "/devices",
        json={"fcm_token": "fake-other-users-token", "platform": "android"},
    )

    assert response.status_code == 409
    assert fake_db.added == []
    assert fake_db.committed is False


def test_register_device_rejects_blank_token():
    fake_db = FakeSession()
    client = create_test_client(fake_db)

    response = client.post(
        "/devices",
        json={"fcm_token": "   ", "platform": "android"},
    )

    assert response.status_code == 422
    assert fake_db.added == []
    assert fake_db.committed is False


def test_register_device_rejects_unsupported_platform():
    fake_db = FakeSession()
    client = create_test_client(fake_db)

    response = client.post(
        "/devices",
        json={"fcm_token": "fake-test-token", "platform": "windows"},
    )

    assert response.status_code == 422
    assert fake_db.added == []
    assert fake_db.committed is False
