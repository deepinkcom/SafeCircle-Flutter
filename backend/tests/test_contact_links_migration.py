"""Run the real Alembic revision chain only on newly created SQLite files."""

from datetime import datetime
from io import StringIO
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from alembic.migration import MigrationContext
from alembic.operations import Operations
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, event, select, text
from sqlalchemy.exc import IntegrityError

from app.database import settings
from app.models import EmergencyContact, EmergencyContactLink, User


BACKEND = Path(__file__).resolve().parents[1]
OLD_REVISION = "2549fa7ab98a"
NEW_REVISION = "8c2f7d1a6b90"


@pytest.fixture
def migration_db(tmp_path, monkeypatch):
    # There is deliberately no configurable URL or fallback to the app's .env.
    url = f"sqlite+pysqlite:///{tmp_path / 'migration.db'}"
    monkeypatch.setattr(settings, "database_url", url)
    engine = create_engine(url)

    @event.listens_for(engine, "connect")
    def enable_foreign_keys(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")

    User.__table__.create(engine)
    EmergencyContact.__table__.create(engine)
    with engine.begin() as connection:
        connection.execute(User.__table__.insert(), [
            dict(id=i, firebase_uid=f"synthetic-{i}", name=f"User {i}",
                 email=f"user{i}@example.invalid", city="Test", phone="0000000000")
            for i in (1, 2, 3)
        ])
        connection.execute(EmergencyContact.__table__.insert(), dict(
            id=10, user_id=1, name="Legacy contact", relationship="Family",
            phone="0000000000", enabled=False, created_at=datetime(2026, 1, 1),
        ))
    config = Config(str(BACKEND / "alembic.ini"))
    command.upgrade(config, OLD_REVISION)
    yield engine, config
    engine.dispose()


def snapshot(engine, table):
    with engine.connect() as connection:
        return connection.execute(select(table).order_by(table.c.id)).all()


def insert_link(engine, inviter=1, invitee=2, status="pending"):
    with engine.begin() as connection:
        connection.execute(text(
            "INSERT INTO emergency_contact_links "
            "(inviter_user_id, invitee_user_id, status) "
            "VALUES (:inviter, :invitee, :status)"
        ), dict(inviter=inviter, invitee=invitee, status=status))


def test_upgrade_preserves_all_data_and_blocks_reverse_duplicates(migration_db):
    engine, config = migration_db
    insert_link(engine)
    # Terminal history, including the reverse direction, must survive unchanged.
    insert_link(engine, 2, 1, "rejected")
    insert_link(engine, 1, 3, "revoked")
    before_contacts = snapshot(engine, EmergencyContact.__table__)
    before_users = snapshot(engine, User.__table__)
    before_links = snapshot(engine, EmergencyContactLink.__table__)
    command.upgrade(config, NEW_REVISION)
    assert snapshot(engine, EmergencyContact.__table__) == before_contacts
    assert snapshot(engine, User.__table__) == before_users
    assert snapshot(engine, EmergencyContactLink.__table__) == before_links
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == NEW_REVISION
    for inviter, invitee in ((1, 2), (2, 1)):
        with pytest.raises(IntegrityError):
            insert_link(engine, inviter, invitee)
    # Historical records do not block a new active invitation.
    insert_link(engine, 3, 1)
    insert_link(engine, 1, 2, "rejected")
    insert_link(engine, 2, 1, "revoked")


def test_conflicting_existing_pairs_abort_without_removing_data(migration_db):
    engine, config = migration_db
    # Reproduce the applied revision's gap before exercising the fix.
    insert_link(engine, 1, 2, "pending")
    insert_link(engine, 2, 1, "accepted")
    before = snapshot(engine, EmergencyContactLink.__table__)
    contacts = snapshot(engine, EmergencyContact.__table__)
    with pytest.raises(IntegrityError):
        command.upgrade(config, NEW_REVISION)
    assert snapshot(engine, EmergencyContactLink.__table__) == before
    assert snapshot(engine, EmergencyContact.__table__) == contacts
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == OLD_REVISION
        indexes = set(connection.scalars(text(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = 'emergency_contact_links'"
        )))
        assert "uq_emergency_contact_links_active_pair" in indexes
        assert "uq_emergency_contact_links_active_unordered_pair" not in indexes


def test_new_revision_downgrade_and_reupgrade_preserve_data(migration_db):
    engine, config = migration_db
    insert_link(engine)
    before = snapshot(engine, EmergencyContactLink.__table__)
    contacts = snapshot(engine, EmergencyContact.__table__)
    command.upgrade(config, NEW_REVISION)
    command.downgrade(config, OLD_REVISION)
    assert snapshot(engine, EmergencyContactLink.__table__) == before
    assert snapshot(engine, EmergencyContact.__table__) == contacts
    command.upgrade(config, NEW_REVISION)
    assert snapshot(engine, EmergencyContactLink.__table__) == before
    with pytest.raises(IntegrityError):
        insert_link(engine, 2, 1)


@pytest.mark.parametrize("inviter,invitee,status", [
    (1, 1, "pending"), (1, 2, "unknown"), (99, 2, "pending"),
    (1, 99, "pending"), (None, 2, "pending"), (1, 2, None),
])
def test_migrated_schema_enforces_constraints(migration_db, inviter, invitee, status):
    engine, config = migration_db
    command.upgrade(config, NEW_REVISION)
    with pytest.raises(IntegrityError):
        insert_link(engine, inviter, invitee, status)


def test_postgresql_revision_sql_uses_partial_unordered_unique_index():
    config = Config(str(BACKEND / "alembic.ini"))
    script = ScriptDirectory.from_config(config)
    revision = script.get_revision(NEW_REVISION)
    assert revision.down_revision == OLD_REVISION
    assert script.get_current_head() == NEW_REVISION
    output = StringIO()
    context = MigrationContext.configure(
        dialect_name="postgresql", opts={"as_sql": True, "output_buffer": output},
    )
    with Operations.context(context):
        revision.module.upgrade()
    sql = output.getvalue()
    assert "CREATE UNIQUE INDEX uq_emergency_contact_links_active_unordered_pair" in sql
    assert "((CASE WHEN inviter_user_id < invitee_user_id" in sql
    assert "WHERE status IN ('pending', 'accepted')" in sql
    assert sql.index("CREATE UNIQUE INDEX") < sql.index("DROP INDEX")
    assert "emergency_contacts" not in sql
    assert "DELETE" not in sql and "UPDATE" not in sql
