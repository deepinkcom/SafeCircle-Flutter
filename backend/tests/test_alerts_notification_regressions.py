
"""Existing alert handlers with controlled storage, no real PostGIS or delivery.

The nearby SQL is compiled for PostgreSQL; this does not claim to execute its
spatial operators. Any notification-table access or push would fail these fakes.
"""

from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy.dialects import postgresql

from app.alerts import router
from app.auth import get_current_user, get_db
from app.models import Alert, AlertAcknowledgement, EmergencyContactLink


class Rows:
    def __init__(self, values):
        self.values = values

    def all(self):
        return self.values

    def one(self):
        return self.values[0]


class AlertStore:
    def __init__(self):
        self.alert = Alert(
            id=7,
            user_id=2,
            kind="panic",
            status="active",
            location_label="Synthetic area",
            created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        )
        self.ack = None
        self.accepted_link = None
        self.accepted_owner_ids = set()
        self.added = []
        self.commits = 0
        self.nearby_sql = None
        self.nearby_params = None
        self.scalar_queries = []

    def add(self, obj):
        assert isinstance(obj, (Alert, AlertAcknowledgement))
        self.added.append(obj)
        obj.id = 8

        if isinstance(obj, AlertAcknowledgement):
            obj.created_at = datetime.now(timezone.utc)
            self.ack = obj

    def flush(self):
        pass

    def commit(self):
        self.commits += 1

    def refresh(self, obj):
        pass

    def scalar(self, statement):
        self.scalar_queries.append(statement)
        entity = statement.column_descriptions[0]["entity"]
        params = statement.compile().params

        if entity is AlertAcknowledgement:
            return self.ack

        if entity is EmergencyContactLink:
            return self.accepted_link

        assert entity is Alert

        if params.get("id_1") != self.alert.id:
            return None

        if "user_id_1" in params:
            actor_id = params["user_id_1"]
            if "alerts.user_id !=" in str(statement):
                if actor_id == self.alert.user_id:
                    return None
            elif actor_id != self.alert.user_id:
                return None

        if (
            "status_1" in params
            and self.alert.status != params["status_1"]
        ):
            return None

        return self.alert

    def scalars(self, statement):
        entity = statement.column_descriptions[0]["entity"]

        if entity is EmergencyContactLink:
            return Rows(self.accepted_owner_ids)

        assert entity is Alert
        return Rows([])

    def execute(self, statement):
        sql = statement.compile(dialect=postgresql.dialect())

        if "ST_DWithin" in str(sql):
            self.nearby_sql = str(sql)
            self.nearby_params = sql.params
            return Rows([(self.alert, 500.0, 0.0, 0.0)])

        if "ST_Y" in str(sql):
            return Rows([SimpleNamespace(latitude=0.0, longitude=0.0)])

        assert "alert_acknowledgements" in str(sql)
        return Rows([(self.ack, self.alert)] if self.ack else [])


@pytest.fixture
def emergency():
    store = AlertStore()
    app = FastAPI()
    app.include_router(router)

    # Only the actor ID is used by these existing handlers.
    app.dependency_overrides[get_current_user] = (
        lambda: type("Actor", (), {"id": 1})()
    )
    app.dependency_overrides[get_db] = lambda: store

    with TestClient(app) as client:
        yield client, store


def test_panic_creation_saves_alert_without_accepted_contacts(emergency):
    client, store = emergency

    response = client.post(
        "/alerts/panic",
        json={
            "latitude": 0,
            "longitude": 0,
            "location_label": "Synthetic area",
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "active"
    assert response.json()["user_id"] == 1
    assert len(store.added) == 1
    assert isinstance(store.added[0], Alert)
    assert store.commits == 2


@pytest.mark.parametrize(
    "lat,lng",
    [
        (91, 0),
        (-91, 0),
        (0, 181),
        (0, -181),
    ],
)
def test_panic_coordinate_validation_is_unchanged(emergency, lat, lng):
    client, store = emergency

    response = client.post(
        "/alerts/panic",
        json={"latitude": lat, "longitude": lng},
    )

    assert response.status_code == 422
    assert store.added == []
    assert store.commits == 0


def test_resolution_remains_owner_only_and_does_not_add_notifications(emergency):
    client, store = emergency

    assert client.post("/alerts/7/resolve").status_code == 404

    store.alert.user_id = 1

    assert client.post("/alerts/7/resolve").json()["status"] == "resolved"
    assert client.post("/alerts/7/resolve").status_code == 409
    assert store.added == []
    assert store.commits == 1


def test_acknowledgement_is_idempotent_and_history_is_real_activity(emergency, monkeypatch):
    # Notification persistence is exercised with the real database fixture in
    # test_emergency_notification_events; this fake store isolates row locking.
    monkeypatch.setattr(
        "app.alerts.record_emergency_acknowledgement_event", lambda *_args, **_kwargs: None
    )
    client, store = emergency
    store.accepted_link = 1

    assert client.get("/alerts/history").json() == []

    response = client.post("/alerts/7/acknowledge")

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "on_my_way"
    locked_sql = [
        str(statement.compile(dialect=postgresql.dialect()))
        for statement in store.scalar_queries
        if "FOR UPDATE" in str(statement.compile(dialect=postgresql.dialect()))
    ]
    assert len(locked_sql) == 2
    assert "FROM alerts" in locked_sql[0]
    assert "emergency_contact_links" in locked_sql[1]
    assert len(store.added) == 1
    assert isinstance(store.added[0], AlertAcknowledgement)

    assert (
        client.post("/alerts/7/acknowledge").json()["id"]
        == response.json()["id"]
    )
    assert len(store.added) == 1

    history = client.get("/alerts/history").json()

    assert len(history) == 1
    assert history[0]["kind"] == "nearby_received"
    assert history[0]["alert_id"] == store.alert.id
    assert history[0]["location_label"] is None


def test_nearby_redacts_exact_location_from_unaccepted_users(emergency):
    client, store = emergency

    response = client.get("/alerts/nearby?lat=0&lng=0&radius_km=1")

    assert response.status_code == 200, response.text
    assert response.headers["cache-control"] == "no-store"
    assert response.json()[0]["id"] == 7
    assert response.json()[0]["latitude"] is None
    assert response.json()[0]["longitude"] is None
    assert response.json()[0]["location_label"] is None
    assert response.json()[0]["distance_km"] == 0.5
    assert "alerts.user_id !=" in store.nearby_sql
    assert "ST_DWithin" in store.nearby_sql
    assert store.nearby_params["user_id_1"] == 1
    assert store.nearby_params["status_1"] == "active"
    assert 1000 in store.nearby_params.values()
    assert store.added == []
    assert store.commits == 0


def test_nearby_returns_exact_location_to_accepted_connection(emergency):
    client, store = emergency
    store.accepted_owner_ids = {2}

    response = client.get("/alerts/nearby?lat=0&lng=0&radius_km=1")

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json()[0]["id"] == 7
    assert response.json()[0]["latitude"] == 0.0
    assert response.json()[0]["longitude"] == 0.0
    assert response.json()[0]["location_label"] == "Synthetic area"
    assert "alerts.user_id !=" in store.nearby_sql
    assert "alerts.status =" in store.nearby_sql
    assert "ST_DWithin" in store.nearby_sql
    assert store.nearby_params["user_id_1"] == 1
    assert store.nearby_params["status_1"] == "active"
    assert 1000 in store.nearby_params.values()
    assert store.added == []
    assert store.commits == 0


def test_location_updates_are_owner_only_and_active_only(emergency):
    client, store = emergency
    payload = {"latitude": -33.9, "longitude": 18.4}
    assert client.post("/alerts/7/location", json=payload).status_code == 404
    assert store.commits == 0

    store.alert.user_id = 1
    response = client.post("/alerts/7/location", json=payload)
    assert response.status_code == 200
    assert response.json() == {"id": 7, "status": "active"}
    assert store.alert.location is not None
    assert store.commits == 1

    store.alert.status = "resolved"
    assert client.post("/alerts/7/location", json=payload).status_code == 404


def test_location_reads_require_owner_or_accepted_connection(emergency):
    client, store = emergency
    assert client.get("/alerts/7/location").status_code == 404

    store.accepted_link = 1
    response = client.get("/alerts/7/location")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["latitude"] == 0.0
    assert response.json()["longitude"] == 0.0

    store.accepted_link = None
    store.alert.status = "resolved"
    assert client.get("/alerts/7/location").status_code == 404
