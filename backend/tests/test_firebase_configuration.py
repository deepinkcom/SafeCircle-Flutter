import json

import pytest

from app import auth


def test_initialize_firebase_accepts_json_secret(monkeypatch):
    calls = []
    certificate = object()
    monkeypatch.setattr(auth.firebase_admin, "_apps", {})
    monkeypatch.setattr(auth.credentials, "Certificate", lambda value: calls.append(value) or certificate)
    monkeypatch.setattr(auth.firebase_admin, "initialize_app", lambda credential, options: calls.append((credential, options)))
    monkeypatch.setenv("FIREBASE_SERVICE_ACCOUNT_JSON", json.dumps({
        "type": "service_account",
        "project_id": "synthetic-test-project",
        "private_key": "synthetic-not-a-real-key",
        "client_email": "synthetic@example.invalid",
        "token_uri": "https://oauth2.googleapis.com/token",
    }))
    monkeypatch.delenv("FIREBASE_SERVICE_ACCOUNT_PATH", raising=False)

    auth.initialize_firebase()

    assert calls[0]["project_id"] == "synthetic-test-project"
    assert calls[1] == (certificate, {"projectId": "deepinkapp-124a6"})


def test_initialize_firebase_rejects_invalid_json_secret(monkeypatch):
    monkeypatch.setattr(auth.firebase_admin, "_apps", {})
    monkeypatch.setenv("FIREBASE_SERVICE_ACCOUNT_JSON", "{not-json")
    monkeypatch.delenv("FIREBASE_SERVICE_ACCOUNT_PATH", raising=False)

    with pytest.raises(RuntimeError, match="not valid JSON"):
        auth.initialize_firebase()


def test_initialize_firebase_rejects_non_object_json_secret(monkeypatch):
    monkeypatch.setattr(auth.firebase_admin, "_apps", {})
    monkeypatch.setenv("FIREBASE_SERVICE_ACCOUNT_JSON", '["not", "an", "object"]')
    monkeypatch.delenv("FIREBASE_SERVICE_ACCOUNT_PATH", raising=False)

    with pytest.raises(RuntimeError, match="JSON object"):
        auth.initialize_firebase()
