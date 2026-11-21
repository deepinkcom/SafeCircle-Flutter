"""Isolated PostgreSQL verification for emergency-event persistence and locks.

Enable only with SAFECIRCLE_PR4_PG_TEST=1 and credentials for the dedicated
loopback-only safecircle_pr4_test database. No development URL fallback exists.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
from threading import Barrier, Event
from time import sleep
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, select, text
from sqlalchemy.engine import URL
from sqlalchemy.orm import Session

from app import alerts as alerts_module
from app import contact_links as contact_links_module
from app.auth import get_current_user, get_db
from app.database import settings
from app.models import (
    Alert,
    AlertAcknowledgement,
    Device,
    EmergencyContactLink,
    Notification,
    PushDelivery,
    User,
)
from app.notification_events import recover_one_pending_emergency_event
from app.push_worker import _claim, _deliver_claim, deliver_one


PARENT = "d9a4f6b2c730"
REVISION = "e17d6a10bc25"
HEAD = "a91b8c7d6e5f"
ENABLED = os.environ.get("SAFECIRCLE_PR4_PG_TEST") == "1"
pytestmark = pytest.mark.skipif(
    not ENABLED,
    reason="requires the separately isolated SafeCircle PR4 PostgreSQL test database",
)


def _database_url():
    expected = {
        "SAFECIRCLE_PR4_PG_HOST": "127.0.0.1",
        "SAFECIRCLE_PR4_PG_PORT": "55432",
        "SAFECIRCLE_PR4_PG_USER": "safecircle_pr4_test",
        "SAFECIRCLE_PR4_PG_DATABASE": "safecircle_pr4_test",
    }
    for key, value in expected.items():
        if os.environ.get(key) != value:
            pytest.fail(f"Unsafe PostgreSQL test configuration: {key} must be the dedicated test value")
    password = os.environ.get("SAFECIRCLE_PR4_PG_PASSWORD")
    if not password:
        pytest.fail("Dedicated PostgreSQL test password is unavailable")
    return URL.create(
        "postgresql+psycopg2",
        username=expected["SAFECIRCLE_PR4_PG_USER"],
        password=password,
        host=expected["SAFECIRCLE_PR4_PG_HOST"],
        port=int(expected["SAFECIRCLE_PR4_PG_PORT"]),
        database=expected["SAFECIRCLE_PR4_PG_DATABASE"],
    )


@pytest.fixture
def pg_env(monkeypatch):
    url = _database_url()
    admin = create_engine(url, hide_parameters=True, pool_pre_ping=True)
    schema = "pr4_" + uuid4().hex
    try:
        with admin.begin() as conn:
            identity = conn.execute(text(
                "SELECT current_database(), current_user, inet_server_addr()::text, inet_server_port()"
            )).one()
            assert identity[0:2] == ("safecircle_pr4_test", "safecircle_pr4_test")
            # PostgreSQL sees its container-side IP; the URL above is loopback-only.
            assert identity[3] == 5432
            # The fresh database may contain only PostGIS-owned reference tables.
            app_tables = conn.scalar(text(
                "SELECT count(*) FROM pg_tables WHERE schemaname='public' "
                "AND tablename NOT IN ('spatial_ref_sys')"
            ))
            assert app_tables == 0, "dedicated test database is not empty"
            conn.execute(text(f'CREATE SCHEMA "{schema}"'))
        scoped_url = url.update_query_dict({"options": f"-csearch_path={schema},public"})
        engine = create_engine(scoped_url, hide_parameters=True, pool_size=8, max_overflow=8)
        monkeypatch.setattr(settings, "database_url", scoped_url.render_as_string(hide_password=False))

        # These legacy application tables predate the versioned migration chain.
        with engine.begin() as conn:
            conn.execute(text("""
                CREATE TABLE users (
                  id SERIAL PRIMARY KEY, firebase_uid VARCHAR(255) NOT NULL UNIQUE,
                  name VARCHAR(255) NOT NULL, email VARCHAR(255) NOT NULL UNIQUE,
                  city VARCHAR(100) NOT NULL, phone VARCHAR(50) NOT NULL,
                  created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now()
                )
            """))
            conn.execute(text("""
                CREATE TABLE emergency_contacts (
                  id SERIAL PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
                  name VARCHAR(255) NOT NULL, relationship VARCHAR(100) NOT NULL,
                  phone VARCHAR(50) NOT NULL, enabled BOOLEAN NOT NULL DEFAULT true,
                  created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now()
                )
            """))
            conn.execute(text("""
                CREATE TABLE devices (
                  id SERIAL PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
                  fcm_token VARCHAR(500) NOT NULL, platform VARCHAR(50) NOT NULL,
                  registered_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now()
                )
            """))
            conn.execute(text("""
                CREATE TABLE alerts (
                  id SERIAL PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
                  kind VARCHAR(50) NOT NULL, status VARCHAR(50) NOT NULL,
                  location geography(POINT,4326), location_label VARCHAR(255),
                  created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT now(),
                  resolved_at TIMESTAMP WITH TIME ZONE
                )
            """))
            conn.execute(text("""
                CREATE TABLE alert_acknowledgements (
                  id SERIAL PRIMARY KEY, alert_id INTEGER NOT NULL REFERENCES alerts(id),
                  responder_user_id INTEGER NOT NULL REFERENCES users(id),
                  status VARCHAR(50) NOT NULL, created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL,
                  CONSTRAINT uq_alert_acknowledgements_alert_responder UNIQUE(alert_id,responder_user_id)
                )
            """))

        config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
        command.upgrade(config, PARENT)
        with Session(engine) as db:
            db.add_all([
                User(id=1, firebase_uid="pg-owner", name="Owner", email="owner@invalid.test", city="Test", phone="000"),
                User(id=2, firebase_uid="pg-contact", name="Contact", email="contact@invalid.test", city="Test", phone="001"),
                User(id=3, firebase_uid="pg-outsider", name="Outsider", email="outsider@invalid.test", city="Test", phone="002"),
            ])
            db.commit()
        yield engine, config, schema
    finally:
        if "engine" in locals():
            engine.dispose()
        with admin.begin() as conn:
            conn.execute(text(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'))
        admin.dispose()


def _add_alert(engine, *, owner=1, status="active", event_state="complete"):
    with Session(engine) as db:
        alert = Alert(
            user_id=owner,
            kind="panic",
            status=status,
            created_at=datetime.now(timezone.utc).replace(tzinfo=None),
            notification_events_status=event_state,
        )
        db.add(alert)
        db.commit()
        return alert.id


def _add_relationship(engine, status="accepted"):
    with Session(engine) as db:
        link = EmergencyContactLink(
            inviter_user_id=1,
            invitee_user_id=2,
            status=status,
            created_at=datetime.now(timezone.utc),
            updated_at=datetime.now(timezone.utc),
        )
        db.add(link)
        db.commit()
        return link.id


def _add_emergency_job(engine, *, alert_id, recipient=2):
    with Session(engine) as db:
        device = Device(user_id=recipient, fcm_token="synthetic-pg-fcm-token", platform="android")
        db.add(device)
        db.flush()
        notice = Notification(
            recipient_user_id=recipient,
            category="emergency",
            event_type="emergency.panic",
            source_id=alert_id,
            title="Synthetic emergency alert",
            message="Isolated PostgreSQL test event",
        )
        db.add(notice)
        db.flush()
        job = PushDelivery(
            notification_id=notice.id,
            device_id=device.id,
            status="pending",
            attempts=0,
            next_attempt_at=datetime.now(timezone.utc) - timedelta(minutes=1),
        )
        db.add(job)
        db.commit()
        return device.id, notice.id, job.id


def test_postgres_upgrade_preserves_alert_and_sets_complete_default(pg_env):
    engine, config, _ = pg_env
    with engine.begin() as conn:
        conn.execute(text(
            "INSERT INTO alerts (id,user_id,kind,status,created_at) "
            "VALUES (41,1,'panic','active','2026-11-01 12:00:00')"
        ))
    with engine.connect() as conn:
        before = conn.execute(text(
            "SELECT id,user_id,kind,status,created_at FROM alerts WHERE id=41"
        )).one()
    command.upgrade(config, "head")
    with engine.connect() as conn:
        assert conn.scalar(text("SELECT version_num FROM alembic_version")) == HEAD
        assert conn.execute(text(
            "SELECT id,user_id,kind,status,created_at,notification_events_status "
            "FROM alerts WHERE id=41"
        )).one() == (*before, "complete")
        assert conn.scalar(text(
            "SELECT column_default FROM information_schema.columns "
            "WHERE table_schema=current_schema() AND table_name='alerts' "
            "AND column_name='notification_events_status'"
        )).startswith("'complete'")
        checks = {item["name"] for item in inspect(conn).get_check_constraints("alerts")}
        assert "ck_alerts_notification_events_status" in checks


def test_postgres_recovery_is_idempotent_and_creates_one_notification_and_job(pg_env):
    engine, config, _ = pg_env
    command.upgrade(config, "head")
    _add_relationship(engine)
    with Session(engine) as db:
        db.add(Device(user_id=2, fcm_token="synthetic-recovery-device", platform="android"))
        db.commit()
    with Session(engine) as db:
        alert = Alert(user_id=1, kind="panic", status="active", notification_events_status="pending")
        db.add(alert)
        db.commit()
        alert_id = alert.id

    # Recovery itself creates the event and push job for the accepted recipient.
    with Session(engine) as db:
        assert recover_one_pending_emergency_event(db) is True
    with Session(engine) as db:
        assert recover_one_pending_emergency_event(db) is False
        assert db.scalar(select(Alert.notification_events_status).where(Alert.id == alert_id)) == "complete"
        assert db.scalar(select(Notification.id).where(
            Notification.category == "emergency", Notification.event_type == "emergency.panic",
            Notification.source_id == alert_id, Notification.recipient_user_id == 2,
        )) is not None
        assert db.scalar(select(PushDelivery.id).join(Notification).where(
            Notification.source_id == alert_id, Notification.recipient_user_id == 2,
        )) is not None
        assert db.scalar(select(Notification.id).where(Notification.source_id == alert_id).limit(1)) is not None
        assert db.query(Notification).filter_by(source_id=alert_id).count() == 1
        assert db.query(PushDelivery).join(Notification).filter(Notification.source_id == alert_id).count() == 1
        complete_alert_id = _add_alert(engine, event_state="complete")
        assert recover_one_pending_emergency_event(db) is False
        assert db.scalar(select(Alert.notification_events_status).where(Alert.id == complete_alert_id)) == "complete"


def test_postgres_downgrade_refuses_pending_without_partial_schema_change(pg_env):
    engine, config, _ = pg_env
    command.upgrade(config, "head")
    alert_id = _add_alert(engine, event_state="pending")
    with pytest.raises(RuntimeError, match="Pending panic event recovery"):
        command.downgrade(config, PARENT)
    with engine.connect() as conn:
        assert conn.scalar(text("SELECT version_num FROM alembic_version")) == HEAD
        assert conn.scalar(text(
            "SELECT notification_events_status FROM alerts WHERE id=:id"
        ), {"id": alert_id}) == "pending"
        assert "notification_events_status" in {column["name"] for column in inspect(conn).get_columns("alerts")}
    with Session(engine) as db:
        db.get(Alert, alert_id).notification_events_status = "complete"
        db.commit()
    command.downgrade(config, PARENT)
    with engine.connect() as conn:
        assert conn.scalar(text("SELECT version_num FROM alembic_version")) == PARENT
        assert "notification_events_status" not in {column["name"] for column in inspect(conn).get_columns("alerts")}
    command.upgrade(config, "head")


def test_postgres_concurrent_recovery_creates_a_single_event(pg_env):
    engine, config, _ = pg_env
    command.upgrade(config, "head")
    _add_relationship(engine)
    with Session(engine) as db:
        db.add(Device(user_id=2, fcm_token="synthetic-concurrent-recovery-device", platform="android"))
        alert = Alert(user_id=1, kind="panic", status="active", notification_events_status="pending")
        db.add(alert)
        db.commit()
        alert_id = alert.id
    barrier = Barrier(2)

    def recover():
        barrier.wait(timeout=5)
        with Session(engine) as db:
            return recover_one_pending_emergency_event(db)

    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(lambda _: recover(), range(2)))
    assert sum(outcomes) == 1
    with Session(engine) as db:
        assert db.query(Notification).filter_by(source_id=alert_id, recipient_user_id=2).count() == 1
        assert db.query(PushDelivery).join(Notification).filter(Notification.source_id == alert_id).count() == 1
        assert db.get(Alert, alert_id).notification_events_status == "complete"

def test_postgres_worker_cancels_job_when_relationship_was_revoked_first(pg_env):
    engine, config, _ = pg_env
    command.upgrade(config, "head")
    _add_relationship(engine)
    alert_id = _add_alert(engine)
    _, notice_id, job_id = _add_emergency_job(engine, alert_id=alert_id)
    with Session(engine) as db:
        actor = db.get(User, 1)
        contact_links_module.revoke_relationship(1, actor, db)
    sends = []
    with Session(engine) as db:
        assert deliver_one(db, lambda *args: sends.append(args)) is True
    with Session(engine) as db:
        job = db.get(PushDelivery, job_id)
        assert job.status == "cancelled"
        assert job.attempts == 0
        assert job.notification_id == notice_id
    assert sends == []


def test_postgres_worker_authorization_lock_serializes_with_relationship_revocation(pg_env):
    engine, config, _ = pg_env
    command.upgrade(config, "head")
    link_id = _add_relationship(engine)
    alert_id = _add_alert(engine)
    _, _, job_id = _add_emergency_job(engine, alert_id=alert_id)
    entered_sender, release_sender = Event(), Event()
    revoked = Event()
    now = datetime.now(timezone.utc)

    def worker():
        with Session(engine) as db:
            lease = _claim(db, now)
            assert lease is not None and lease is not True
            return _deliver_claim(db, lease, lambda *_: (entered_sender.set(), release_sender.wait(8)), now)

    def revoke():
        with Session(engine) as db:
            actor = db.get(User, 1)
            contact_links_module.revoke_relationship(link_id, actor, db)
            revoked.set()

    with ThreadPoolExecutor(max_workers=2) as pool:
        delivery = pool.submit(worker)
        assert entered_sender.wait(5), "worker did not reach bounded sender"
        revocation = pool.submit(revoke)
        sleep(0.2)
        assert not revoked.is_set(), "revocation should wait for worker authorization lock"
        release_sender.set()
        assert delivery.result(timeout=8) is True
        revocation.result(timeout=8)
    with Session(engine) as db:
        assert db.get(PushDelivery, job_id).status == "sent"
        assert db.get(EmergencyContactLink, link_id).status == "revoked"
    assert revoked.is_set()


def test_postgres_concurrent_workers_claim_one_emergency_job_once(pg_env):
    engine, config, _ = pg_env
    command.upgrade(config, "head")
    _add_relationship(engine)
    alert_id = _add_alert(engine)
    _, _, job_id = _add_emergency_job(engine, alert_id=alert_id)
    barrier = Barrier(2)
    now = datetime.now(timezone.utc)

    def claim():
        barrier.wait(timeout=5)
        with Session(engine) as db:
            return _claim(db, now)

    with ThreadPoolExecutor(max_workers=2) as pool:
        leases = list(pool.map(lambda _: claim(), range(2)))
    assert sum(lease is not None and lease is not True for lease in leases) == 1
    assert sum(lease is None for lease in leases) == 1
    lease = next(value for value in leases if value is not None)
    sends = []
    with Session(engine) as db:
        assert _deliver_claim(db, lease, lambda *args: sends.append(args), now) is True
    assert len(sends) == 1
    with Session(engine) as db:
        job = db.get(PushDelivery, job_id)
        assert job.status == "sent" and job.attempts == 1


def _ack_client(engine, actor_id):
    app = FastAPI()
    app.include_router(alerts_module.router)

    def db_override():
        with Session(engine) as db:
            yield db

    def user_override():
        with Session(engine) as db:
            yield db.get(User, actor_id)

    app.dependency_overrides[get_db] = db_override
    app.dependency_overrides[get_current_user] = user_override
    return TestClient(app)


@pytest.mark.parametrize(
    "relationship_status,actor_id,alert_status,expected",
    [
        ("accepted", 2, "active", 200),
        (None, 3, "active", 404),
        ("accepted", 1, "active", 404),
        ("revoked", 2, "active", 404),
        ("rejected", 2, "active", 404),
        ("accepted", 2, "resolved", 404),
    ],
)
def test_postgres_acknowledgement_route_enforces_relationship_and_alert_state(
    pg_env, relationship_status, actor_id, alert_status, expected
):
    engine, config, _ = pg_env
    command.upgrade(config, "head")
    alert_id = _add_alert(engine, status=alert_status)
    if relationship_status is not None:
        _add_relationship(engine, relationship_status)
    with _ack_client(engine, actor_id) as client:
        response = client.post(f"/alerts/{alert_id}/acknowledge")
    assert response.status_code == expected
    with Session(engine) as db:
        count = db.scalar(select(AlertAcknowledgement.id).where(AlertAcknowledgement.alert_id == alert_id).count()) if False else db.query(AlertAcknowledgement).filter_by(alert_id=alert_id).count()
        assert count == (1 if expected == 200 else 0)
    with _ack_client(engine, 2) as client:
        guessed = client.post(f"/alerts/{alert_id + 10000}/acknowledge")
    assert guessed.status_code == 404
