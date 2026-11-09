"""Opt-in real PostgreSQL tests, hard-wired to the disposable retention DB.

SAFECIRCLE_RETENTION_POSTGRES=1 enables these tests. No development URL fallback.
Each test gets its own schema; the database/container must be created separately.
"""
import os
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from io import StringIO
from threading import Event
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, event, inspect, select, text
from sqlalchemy.engine import URL
from sqlalchemy.orm import Session

from app.database import settings
from app.devices import DeviceRemove, unregister_device
from app.models import Device, EmergencyContact, Notification, PushDelivery, User
from app.push_worker import _claim, _deliver_claim, deliver_one


PARENT = "c7f0a3e5b921"
REVISION = "d9a4f6b2c730"
pytestmark = pytest.mark.skipif(
    os.environ.get("SAFECIRCLE_RETENTION_POSTGRES") != "1",
    reason="Requires the separately approved disposable PostgreSQL container",
)


@pytest.fixture
def pg_database(monkeypatch):
    schema = "retention_" + uuid4().hex
    url = URL.create("postgresql+psycopg2", username="retention_test",
                     password="synthetic-isolated-test-only", host="127.0.0.1", port=52156,
                     database="safecircle_retention_test_20261109")
    admin = create_engine(url, hide_parameters=True)
    with admin.begin() as c:
        assert c.scalar(text("SELECT current_database()")) == "safecircle_retention_test_20261109"
        c.execute(text(f'CREATE SCHEMA "{schema}"'))
    test_url = url.update_query_dict({"options": f"-csearch_path={schema}"})
    engine = create_engine(test_url, hide_parameters=True)
    monkeypatch.setattr(settings, "database_url", test_url.render_as_string(hide_password=False))
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    try:
        User.__table__.create(engine)
        EmergencyContact.__table__.create(engine)
        with engine.begin() as c:
            # Historical baseline: the c7 revision adds token uniqueness itself.
            c.execute(text("CREATE TABLE devices (id SERIAL PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), "
                           "fcm_token VARCHAR(500) NOT NULL, platform VARCHAR(50) NOT NULL, registered_at TIMESTAMP NOT NULL)"))
        command.upgrade(config, PARENT)
        with Session(engine) as db:
            db.add_all([User(id=i, firebase_uid=f"synthetic-uid-{i}", name=f"User {i}",
                             email=f"user{i}@example.invalid", city="Test", phone="000") for i in (1, 2)])
            db.commit()
        yield engine, config
    finally:
        engine.dispose()
        with admin.begin() as c:
            c.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        admin.dispose()


def seed(engine, statuses=("sent", "failed", "cancelled", "pending", "sending")):
    with Session(engine) as db:
        device = Device(user_id=2, fcm_token="synthetic-retention-device", platform="android")
        db.add(device)
        db.flush()
        ids = []
        for i, status in enumerate(statuses, 1):
            notice = Notification(recipient_user_id=2, category="connection", event_type="connection.invited",
                                  source_id=i, title="Synthetic event", message="Isolated fixture only")
            db.add(notice)
            db.flush()
            job = PushDelivery(notification_id=notice.id, device_id=device.id, status=status,
                               attempts=2 if status != "pending" else 0,
                               next_attempt_at=datetime(2020, 1, 1, tzinfo=timezone.utc))
            db.add(job)
            db.flush()
            ids.append(job.id)
        db.commit()
        return device.id, ids


def test_logout_preserves_history_and_cancels_unfinished(pg_database):
    engine, config = pg_database
    command.upgrade(config, "head")
    device_id, ids = seed(engine)
    with Session(engine) as db:
        unregister_device(DeviceRemove(fcm_token="synthetic-retention-device"), db.get(User, 2), db)
    with Session(engine) as db:
        assert db.get(Device, device_id) is None
        jobs = db.scalars(select(PushDelivery).order_by(PushDelivery.id)).all()
        assert [job.id for job in jobs] == ids
        assert [job.status for job in jobs] == ["sent", "failed", "cancelled", "cancelled", "cancelled"]
        assert [job.attempts for job in jobs] == [2, 2, 2, 0, 2]
        assert all(job.device_id is None for job in jobs)


def test_migration_retains_rows_and_other_constraints(pg_database):
    engine, config = pg_database
    _, ids = seed(engine)
    with engine.connect() as c:
        before = list(c.execute(select(PushDelivery.__table__).order_by(PushDelivery.id)))
    command.upgrade(config, "head")
    with engine.connect() as c:
        assert c.scalar(text("SELECT version_num FROM alembic_version")) == REVISION
        assert list(c.scalars(select(PushDelivery.id).order_by(PushDelivery.id))) == ids
        assert list(c.execute(select(PushDelivery.__table__).order_by(PushDelivery.id))) == before
    inspector = inspect(engine)
    fk = next(fk for fk in inspector.get_foreign_keys("push_deliveries") if fk["constrained_columns"] == ["device_id"])
    assert fk["options"]["ondelete"] == "SET NULL"
    assert next(col for col in inspector.get_columns("push_deliveries") if col["name"] == "device_id")["nullable"]
    assert any(c["name"] == "uq_push_delivery_notification_device" for c in inspector.get_unique_constraints("push_deliveries"))
    assert any(i["name"] == "ix_push_delivery_due" for i in inspector.get_indexes("push_deliveries"))
    notification_fk = next(fk for fk in inspector.get_foreign_keys("push_deliveries")
                           if fk["constrained_columns"] == ["notification_id"])
    assert notification_fk["options"]["ondelete"] == "CASCADE"
    assert any(i["name"] == "ix_push_delivery_device" for i in inspector.get_indexes("push_deliveries"))


def upgrade_and_seed(pg_database, statuses=("pending",)):
    engine, config = pg_database
    command.upgrade(config, REVISION)
    device_id, ids = seed(engine, statuses)
    return engine, config, device_id, ids


def no_send(*args):
    pytest.fail("Unavailable registration must never reach FCM")


def test_detached_pending_jobs_cancel_without_an_attempt(pg_database):
    engine, _, device_id, ids = upgrade_and_seed(pg_database)
    # Also handle administrative physical deletion that bypasses API cleanup.
    with engine.begin() as c:
        c.execute(Device.__table__.delete().where(Device.id == device_id))
    with Session(engine) as db:
        assert deliver_one(db, no_send)
        job = db.get(PushDelivery, ids[0])
        assert (job.status, job.attempts, job.device_id) == ("cancelled", 0, None)


def test_logout_invalidates_lease_and_new_account_cannot_adopt_history(pg_database):
    engine, _, old_id, ids = upgrade_and_seed(pg_database)
    now = datetime.now(timezone.utc)
    with Session(engine) as db:
        lease = _claim(db, now)
    with Session(engine) as db:
        unregister_device(DeviceRemove(fcm_token="synthetic-retention-device"), db.get(User, 2), db)
        replacement = Device(user_id=1, fcm_token="synthetic-retention-device", platform="android")
        db.add(replacement)
        db.commit()
        assert replacement.id != old_id
    with Session(engine) as db:
        assert not _deliver_claim(db, lease, no_send, now)
        job = db.get(PushDelivery, ids[0])
        assert (job.status, job.attempts, job.device_id) == ("cancelled", 1, None)
        assert db.get(Notification, job.notification_id).recipient_user_id == 2


def test_new_generation_fences_stale_worker(pg_database):
    engine, _, _, ids = upgrade_and_seed(pg_database)
    now = datetime.now(timezone.utc)
    with Session(engine) as db:
        first = _claim(db, now)
    with Session(engine) as db:
        second = _claim(db, now + timedelta(minutes=3))
    assert second.generation == first.generation + 1
    with Session(engine) as db:
        assert not _deliver_claim(db, first, no_send, now + timedelta(minutes=3))
        assert db.get(PushDelivery, ids[0]).status == "sending"
    calls = []
    with Session(engine) as db:
        assert _deliver_claim(db, second, lambda *args: calls.append(1), now + timedelta(minutes=3))
        assert (db.get(PushDelivery, ids[0]).status, db.get(PushDelivery, ids[0]).attempts) == ("sent", 2)
    assert calls == [1]
    with Session(engine) as db:
        assert not _deliver_claim(db, second, no_send, now + timedelta(minutes=3))


def test_expired_unreclaimed_lease_cannot_send(pg_database):
    engine, _, _, _ = upgrade_and_seed(pg_database)
    now = datetime.now(timezone.utc)
    with Session(engine) as db:
        lease = _claim(db, now)
        assert not _deliver_claim(db, lease, no_send, now + timedelta(minutes=3))


@pytest.mark.parametrize("error_type", ["UnregisteredError", "SenderIdMismatchError"])
def test_invalid_token_keeps_completed_and_failed_history(pg_database, error_type, caplog):
    from firebase_admin import messaging
    engine, _, device_id, ids = upgrade_and_seed(pg_database, ("sent", "pending", "pending"))
    def invalid(*args):
        raise getattr(messaging, error_type)("synthetic private provider response")
    with Session(engine) as db:
        assert deliver_one(db, invalid)
        db.expire_all()
        assert db.get(Device, device_id) is None
        jobs = [db.get(PushDelivery, i) for i in ids]
        assert [j.status for j in jobs] == ["sent", "failed", "cancelled"]
        assert [j.attempts for j in jobs] == [2, 1, 0]
        assert all(j.device_id is None for j in jobs)
    assert "synthetic private provider response" not in caplog.text


def test_transient_failures_retry_five_times_then_remain_failed(pg_database):
    engine, _, device_id, ids = upgrade_and_seed(pg_database)
    now = datetime.now(timezone.utc)
    def fail(*args):
        raise TimeoutError("Synthetic transport timeout")
    with Session(engine) as db:
        for attempt in range(1, 6):
            assert deliver_one(db, fail, now=now)
            job = db.get(PushDelivery, ids[0])
            assert job.attempts == attempt
            assert job.status == ("failed" if attempt == 5 else "pending")
            if attempt < 5:
                assert not deliver_one(db, no_send, now=now)
                now = job.next_attempt_at + timedelta(seconds=1)
        assert not deliver_one(db, no_send, now=now + timedelta(days=1))
        assert db.get(Device, device_id) is not None


def test_atomic_cleanup_rolls_back_cancellation_and_deletion(pg_database):
    from fastapi import HTTPException
    engine, _, device_id, ids = upgrade_and_seed(pg_database)
    def refuse_delete(*args):
        raise RuntimeError("Synthetic delete failure")
    event.listen(Device, "before_delete", refuse_delete)
    try:
        with Session(engine) as db, pytest.raises(HTTPException) as error:
            unregister_device(DeviceRemove(fcm_token="synthetic-retention-device"), db.get(User, 2), db)
        assert error.value.status_code == 503
    finally:
        event.remove(Device, "before_delete", refuse_delete)
    with Session(engine) as db:
        assert db.get(Device, device_id) is not None
        assert (db.get(PushDelivery, ids[0]).status, db.get(PushDelivery, ids[0]).attempts) == ("pending", 0)


def test_foreign_owner_cannot_remove_registration_or_cancel_jobs(pg_database):
    engine, _, device_id, ids = upgrade_and_seed(pg_database)
    with Session(engine) as db:
        assert unregister_device(DeviceRemove(fcm_token="synthetic-retention-device"), db.get(User, 1), db) == {"success": True}
        assert db.get(Device, device_id) is not None
        assert db.get(PushDelivery, ids[0]).status == "pending"


def test_safe_downgrade_roundtrip_retains_attached_history(pg_database):
    engine, config, _, ids = upgrade_and_seed(pg_database, ("sent",))
    command.downgrade(config, PARENT)
    inspector = inspect(engine)
    assert not next(c for c in inspector.get_columns("push_deliveries") if c["name"] == "device_id")["nullable"]
    command.upgrade(config, REVISION)
    with Session(engine) as db:
        assert (db.get(PushDelivery, ids[0]).status, db.get(PushDelivery, ids[0]).attempts) == ("sent", 2)


def test_downgrade_refuses_detached_history_without_changing_rows_or_revision(pg_database):
    engine, config, _, ids = upgrade_and_seed(pg_database, ("sent",))
    with Session(engine) as db:
        unregister_device(DeviceRemove(fcm_token="synthetic-retention-device"), db.get(User, 2), db)
    with pytest.raises(RuntimeError, match="Detached delivery history prevents downgrade"):
        command.downgrade(config, PARENT)
    with Session(engine) as db:
        assert db.scalar(text("SELECT version_num FROM alembic_version")) == REVISION
        job = db.get(PushDelivery, ids[0])
        assert (job.status, job.attempts, job.device_id) == ("sent", 2, None)
    assert any(i["name"] == "ix_push_delivery_device" for i in inspect(engine).get_indexes("push_deliveries"))


def test_multiple_detached_deliveries_keep_unique_live_device_pairs(pg_database):
    from sqlalchemy.exc import IntegrityError
    engine, _, old_id, ids = upgrade_and_seed(pg_database, ("sent",))
    with Session(engine) as db:
        second = Device(user_id=2, fcm_token="synthetic-second-device", platform="android")
        db.add(second)
        db.flush()
        first_job = db.get(PushDelivery, ids[0])
        db.add(PushDelivery(notification_id=first_job.notification_id, device_id=second.id, status="sent", attempts=1))
        db.commit()
        db.add(PushDelivery(notification_id=first_job.notification_id, device_id=second.id))
        with pytest.raises(IntegrityError):
            db.commit()
        db.rollback()
        db.delete(db.get(Device, old_id))
        db.delete(db.get(Device, second.id))
        db.commit()
        assert len(db.scalars(select(PushDelivery)).all()) == 2
        assert all(j.device_id is None for j in db.scalars(select(PushDelivery)))


def wait_for_database_lock(engine, application):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        with engine.connect() as c:
            if c.scalar(text("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() "
                             "AND application_name=:application AND wait_event_type='Lock'"), {"application": application}):
                return
        time.sleep(0.02)
    pytest.fail("Concurrent operation did not reach the expected PostgreSQL lock")


def test_logout_waits_for_send_and_then_preserves_history(pg_database):
    engine, _, device_id, ids = upgrade_and_seed(pg_database)
    sending, release = Event(), Event()
    calls = []
    application = "retention_logout_" + uuid4().hex
    def sender(*args):
        calls.append(1)
        sending.set()
        assert release.wait(10)
    def send_job():
        with Session(engine) as db:
            return deliver_one(db, sender)
    def logout():
        with Session(engine) as db:
            db.execute(text("SELECT set_config('application_name',:name,true)"), {"name": application})
            return unregister_device(DeviceRemove(fcm_token="synthetic-retention-device"), db.get(User, 2), db)
    with ThreadPoolExecutor(max_workers=2) as pool:
        sending_job = pool.submit(send_job)
        try:
            assert sending.wait(8)
            cleanup = pool.submit(logout)
            wait_for_database_lock(engine, application)
            assert not cleanup.done()
        finally:
            release.set()
        assert sending_job.result(timeout=10)
        assert cleanup.result(timeout=10) == {"success": True}
    with Session(engine) as db:
        assert db.get(Device, device_id) is None
        job = db.get(PushDelivery, ids[0])
        assert (job.status, job.attempts, job.device_id) == ("sent", 1, None)
        assert not deliver_one(db, no_send)
    assert calls == [1]


def test_locked_job_is_not_claimed_by_second_worker(pg_database):
    engine, _, _, _ = upgrade_and_seed(pg_database)
    sending, release = Event(), Event()
    def sender(*args):
        sending.set()
        assert release.wait(10)
    def send_job():
        with Session(engine) as db:
            return deliver_one(db, sender)
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(send_job)
        try:
            assert sending.wait(8)
            with Session(engine) as db:
                assert not deliver_one(db, no_send)
        finally:
            release.set()
        assert future.result(timeout=10)


def test_waiting_stale_worker_is_fenced_by_concurrent_reclaim(pg_database):
    engine, _, device_id, ids = upgrade_and_seed(pg_database)
    now = datetime.now(timezone.utc)
    with Session(engine) as db:
        old_lease = _claim(db, now)
    application = "retention_stale_" + uuid4().hex
    def old_worker():
        with Session(engine) as db:
            db.execute(text("SELECT set_config('application_name',:name,true)"), {"name": application})
            return _deliver_claim(db, old_lease, no_send)
    with Session(engine) as blocker, ThreadPoolExecutor(max_workers=1) as pool:
        blocker.scalar(select(Device).where(Device.id == device_id).with_for_update())
        future = pool.submit(old_worker)
        try:
            wait_for_database_lock(engine, application)
            with Session(engine) as db:
                new_lease = _claim(db, now + timedelta(minutes=3))
            assert new_lease.generation == 2
        finally:
            blocker.rollback()
        assert not future.result(timeout=10)
    with Session(engine) as db:
        assert _deliver_claim(db, new_lease, lambda *args: None, now + timedelta(minutes=3))
        job = db.get(PushDelivery, ids[0])
        assert (job.status, job.attempts) == ("sent", 2)


def test_wrong_recipient_after_claim_never_sends(pg_database):
    engine, _, device_id, ids = upgrade_and_seed(pg_database)
    now = datetime.now(timezone.utc)
    with Session(engine) as db:
        lease = _claim(db, now)
    with engine.begin() as c:
        c.execute(Device.__table__.update().where(Device.id == device_id).values(user_id=1))
    with Session(engine) as db:
        assert _deliver_claim(db, lease, no_send, now)
        assert db.get(PushDelivery, ids[0]).status == "cancelled"


def test_notification_suppression_retains_job_and_prevents_submission(pg_database):
    engine, _, _, ids = upgrade_and_seed(pg_database)
    with Session(engine) as db:
        job = db.get(PushDelivery, ids[0])
        db.get(Notification, job.notification_id).deleted_at = datetime.now(timezone.utc)
        db.commit()
        assert deliver_one(db, no_send)
        assert db.get(PushDelivery, ids[0]).status == "cancelled"
        assert db.get(PushDelivery, ids[0]).attempts == 0


@pytest.mark.parametrize("detached", [False, True])
def test_offline_downgrade_sql_preserves_or_refuses_history(pg_database, detached):
    import psycopg2
    engine, config, _, ids = upgrade_and_seed(pg_database, ("sent",))
    if detached:
        with Session(engine) as db:
            unregister_device(DeviceRemove(fcm_token="synthetic-retention-device"), db.get(User, 2), db)
    buffer = StringIO()
    config.output_buffer = buffer
    command.downgrade(config, f"{REVISION}:{PARENT}", sql=True)
    raw = engine.raw_connection()
    try:
        with raw.cursor() as cursor:
            if detached:
                with pytest.raises(psycopg2.Error, match="Detached delivery history prevents downgrade"):
                    cursor.execute(buffer.getvalue())
                raw.rollback()
            else:
                cursor.execute(buffer.getvalue())
    finally:
        raw.close()
    with Session(engine) as db:
        assert db.get(PushDelivery, ids[0]).status == "sent"
        assert db.scalar(text("SELECT version_num FROM alembic_version")) == (REVISION if detached else PARENT)
