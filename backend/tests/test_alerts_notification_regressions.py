"""Existing alert handlers with controlled storage, no real PostGIS or delivery.

The nearby SQL is compiled for PostgreSQL; this does not claim to execute its
spatial operators. Any notification-table access or push would fail these fakes.
"""

from datetime import datetime, timezone

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy.dialects import postgresql

from app.alerts import router
from app.auth import get_current_user, get_db
from app.models import Alert, AlertAcknowledgement


class Rows:
    def __init__(self, values):
        self.values = values
    def all(self):
        return self.values


class AlertStore:
    def __init__(self):
        self.alert = Alert(id=7, user_id=2, kind="panic", status="active", location_label="Synthetic area",
                           created_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
        self.ack = None
        self.added = []
        self.commits = 0
        self.nearby_sql = None
        self.nearby_params = None

    def add(self, obj):
        assert isinstance(obj, (Alert, AlertAcknowledgement))
        self.added.append(obj)
        obj.id = 8
        if isinstance(obj, AlertAcknowledgement):
            obj.created_at = datetime.now(timezone.utc)
            self.ack = obj

    def commit(self):
        self.commits += 1

    def refresh(self, obj):
        pass

    def scalar(self, statement):
        entity = statement.column_descriptions[0]["entity"]
        params = statement.compile().params
        if entity is AlertAcknowledgement:
            return self.ack
        assert entity is Alert
        if params.get("id_1") != self.alert.id:
            return None
        if "user_id_1" in params and params["user_id_1"] != self.alert.user_id:
            return None
        if "status_1" in params and self.alert.status != params["status_1"]:
            return None
        return self.alert

    def scalars(self, statement):
        assert statement.column_descriptions[0]["entity"] is Alert
        return Rows([])  # Caller has not sent any alerts.

    def execute(self, statement):
        sql = statement.compile(dialect=postgresql.dialect())
        if "ST_DWithin" in str(sql):
            self.nearby_sql = str(sql)
            self.nearby_params = sql.params
            return Rows([(self.alert, 500.0, 0.0, 0.0)])
        assert "alert_acknowledgements" in str(sql)
        return Rows([(self.ack, self.alert)] if self.ack else [])


@pytest.fixture
def emergency():
    store = AlertStore()
    app = FastAPI()
    app.include_router(router)
    # Only the actor ID is used by these existing handlers.
    app.dependency_overrides[get_current_user] = lambda: type("Actor", (), {"id": 1})()
    app.dependency_overrides[get_db] = lambda: store
    with TestClient(app) as client:
        yield client, store


def test_panic_creation_still_creates_only_an_alert(emergency):
    client, store = emergency
    response = client.post("/alerts/panic", json={"latitude": 0, "longitude": 0, "location_label": "Synthetic area"})
    assert response.status_code == 200
    assert response.json()["status"] == "active" and response.json()["user_id"] == 1
    assert len(store.added) == 1 and isinstance(store.added[0], Alert)
    assert store.commits == 1


@pytest.mark.parametrize("lat,lng", [(91, 0), (-91, 0), (0, 181), (0, -181)])
def test_panic_coordinate_validation_is_unchanged(emergency, lat, lng):
    client, store = emergency
    assert client.post("/alerts/panic", json={"latitude": lat, "longitude": lng}).status_code == 422
    assert store.added == [] and store.commits == 0


def test_resolution_remains_owner_only_and_does_not_add_notifications(emergency):
    client, store = emergency
    assert client.post("/alerts/7/resolve").status_code == 404
    store.alert.user_id = 1
    assert client.post("/alerts/7/resolve").json()["status"] == "resolved"
    assert client.post("/alerts/7/resolve").status_code == 409
    assert store.added == [] and store.commits == 1


def test_acknowledgement_remains_separate_and_history_is_real_activity(emergency):
    client, store = emergency
    assert client.get("/alerts/history").json() == []
    response = client.post("/alerts/7/acknowledge")
    assert response.status_code == 200 and response.json()["status"] == "on_my_way"
    assert len(store.added) == 1 and isinstance(store.added[0], AlertAcknowledgement)
    assert client.post("/alerts/7/acknowledge").json()["id"] == response.json()["id"]
    assert len(store.added) == 1
    history = client.get("/alerts/history").json()
    assert len(history) == 1 and history[0]["kind"] == "nearby_received"
    assert history[0]["alert_id"] == store.alert.id


def test_nearby_retains_existing_spatial_rules_without_connection_recipient_expansion(emergency):
    client, store = emergency
    response = client.get("/alerts/nearby?lat=0&lng=0&radius_km=1")
    assert response.status_code == 200 and response.json()[0]["id"] == 7
    assert "alerts.user_id !=" in store.nearby_sql
    assert "alerts.status =" in store.nearby_sql
    assert "ST_DWithin" in store.nearby_sql
    assert store.nearby_params["user_id_1"] == 1
    assert store.nearby_params["status_1"] == "active"
    assert 1000 in store.nearby_params.values()
    assert "emergency_contact_links" not in store.nearby_sql
    assert "notifications" not in store.nearby_sql
    assert store.added == [] and store.commits == 0
