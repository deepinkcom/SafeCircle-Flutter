from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from sqlalchemy.exc import SQLAlchemyError

from app.main import app, engine


client = TestClient(app)


def test_liveness_does_not_require_database(monkeypatch):
    def unexpected_connect():
        raise AssertionError("liveness must not open a database connection")

    monkeypatch.setattr(engine, "connect", unexpected_connect)
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readiness_returns_ready_when_database_responds(monkeypatch):
    connection = MagicMock()
    connection.__enter__.return_value = connection
    monkeypatch.setattr(engine, "connect", lambda: connection)

    response = client.get("/health/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready", "database": "ok"}
    connection.execute.assert_called_once()


def test_readiness_returns_503_when_database_is_unavailable(monkeypatch):
    def unavailable():
        raise SQLAlchemyError("synthetic database outage")

    monkeypatch.setattr(engine, "connect", unavailable)
    response = client.get("/health/ready")

    assert response.status_code == 503
    assert response.json() == {"detail": "Database unavailable"}
