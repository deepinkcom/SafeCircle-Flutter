"""Exercise the recovery-marker revision against an isolated SQLite database."""

from datetime import datetime
from pathlib import Path

import pytest
from alembic.config import Config
from alembic.migration import MigrationContext
from alembic.operations import Operations
from alembic.script import ScriptDirectory
from sqlalchemy import (
    Column,
    DateTime,
    ForeignKey,
    Integer,
    MetaData,
    String,
    Table,
    create_engine,
    insert,
    text,
)
from sqlalchemy.exc import IntegrityError


BACKEND = Path(__file__).resolve().parents[1]
REVISION = "e17d6a10bc25"
PARENT = "d9a4f6b2c730"


@pytest.fixture
def legacy_alert_database(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'alerts.db'}")
    metadata = MetaData()
    users = Table(
        "users", metadata,
        Column("id", Integer, primary_key=True),
    )
    alerts = Table(
        "alerts", metadata,
        Column("id", Integer, primary_key=True),
        Column("user_id", Integer, ForeignKey("users.id"), nullable=False),
        Column("kind", String(50), nullable=False),
        Column("status", String(50), nullable=False),
        Column("created_at", DateTime, nullable=False),
    )
    metadata.create_all(engine)
    with engine.begin() as connection:
        connection.execute(insert(users).values(id=1))
        connection.execute(insert(alerts).values(
            id=41, user_id=1, kind="panic", status="active",
            created_at=datetime(2026, 11, 1, 12, 0, 0),
        ))
    yield engine, alerts
    engine.dispose()


def _revision():
    script = ScriptDirectory.from_config(Config(str(BACKEND / "alembic.ini")))
    return script.get_revision(REVISION)


def test_recovery_marker_migration_preserves_alerts_and_defaults_complete(
    legacy_alert_database,
):
    engine, alerts = legacy_alert_database
    revision = _revision()
    assert revision.down_revision == PARENT

    with engine.begin() as connection:
        context = MigrationContext.configure(connection)
        with Operations.context(context):
            revision.module.upgrade()
        assert connection.execute(text(
            "SELECT id, user_id, kind, status, notification_events_status "
            "FROM alerts WHERE id = 41"
        )).one() == (41, 1, "panic", "active", "complete")
        connection.execute(text(
            "INSERT INTO alerts (id, user_id, kind, status, created_at, "
            "notification_events_status) VALUES (42, 1, 'panic', 'active', "
            "'2026-11-02 12:00:00', 'pending')"
        ))
        assert connection.scalar(text(
            "SELECT notification_events_status FROM alerts WHERE id = 42"
        )) == "pending"

    with engine.begin() as connection:
        with pytest.raises(IntegrityError):
            connection.execute(text(
                "INSERT INTO alerts (id, user_id, kind, status, created_at, "
                "notification_events_status) VALUES (43, 1, 'panic', 'active', "
                "'2026-11-03 12:00:00', 'lost')"
            ))
        assert connection.scalar(text("SELECT count(*) FROM alerts")) == 2


def test_downgrade_refuses_to_discard_pending_recovery_state(legacy_alert_database):
    engine, _ = legacy_alert_database
    revision = _revision()
    with engine.begin() as connection:
        with Operations.context(MigrationContext.configure(connection)):
            revision.module.upgrade()
        connection.execute(text(
            "UPDATE alerts SET notification_events_status = 'pending' WHERE id = 41"
        ))

    with engine.begin() as connection:
        with Operations.context(MigrationContext.configure(connection)):
            with pytest.raises(RuntimeError, match="Pending panic event recovery"):
                revision.module.downgrade()
        assert connection.scalar(text(
            "SELECT notification_events_status FROM alerts WHERE id = 41"
        )) == "pending"

    with engine.begin() as connection:
        connection.execute(text(
            "UPDATE alerts SET notification_events_status = 'complete' WHERE id = 41"
        ))
        with Operations.context(MigrationContext.configure(connection)):
            revision.module.downgrade()
        columns = {row[1] for row in connection.execute(text("PRAGMA table_info(alerts)"))}
        assert "notification_events_status" not in columns
        assert connection.scalar(text("SELECT count(*) FROM alerts WHERE id = 41")) == 1
