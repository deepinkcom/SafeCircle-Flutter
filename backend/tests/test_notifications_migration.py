"""Exercise the real migration only against fresh disposable SQLite files."""

from datetime import datetime, timezone
from io import StringIO

import pytest
from alembic import command
from alembic.migration import MigrationContext
from alembic.operations import Operations
from alembic.script import ScriptDirectory
from sqlalchemy import inspect, select, text
from sqlalchemy.exc import IntegrityError

from app.models import EmergencyContact, EmergencyContactLink, Notification, User
from test_contact_links_migration import insert_link, migration_db, snapshot


REVISION = "b6e9c2d4f810"
PARENT = "8c2f7d1a6b90"
SCHEMA_HEAD = "d9a4f6b2c730"


def notification(**changes):
    return {"recipient_user_id": 2, "category": "connection", "event_type": "connection.invited",
            "source_id": 1, "title": "Synthetic test event", "message": "Disposable fixture only.", **changes}


def test_real_head_upgrade_preserves_all_existing_data_and_does_not_backfill(migration_db):
    engine, config = migration_db
    insert_link(engine)
    before = {model: snapshot(engine, model.__table__) for model in (User, EmergencyContact, EmergencyContactLink)}
    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == SCHEMA_HEAD
        assert connection.execute(select(Notification)).all() == []
    for model, rows in before.items():
        assert snapshot(engine, model.__table__) == rows
    inspector = inspect(engine)
    fk = inspector.get_foreign_keys("notifications")[0]
    assert fk["referred_table"] == "users" and fk["constrained_columns"] == ["recipient_user_id"]
    assert fk["options"]["ondelete"] == "CASCADE"
    assert {index["name"] for index in inspector.get_indexes("notifications")} == {
        "ix_notifications_recipient_created", "ix_notifications_unread",
    }
    assert inspector.get_unique_constraints("notifications")[0]["column_names"] == [
        "recipient_user_id", "category", "event_type", "source_id",
    ]


@pytest.mark.parametrize("changes", [
    {"recipient_user_id": 99}, {"recipient_user_id": None}, {"category": "unknown"}, {"category": None},
    {"event_type": ""}, {"event_type": " "}, {"event_type": "x" * 65},
    {"source_id": 0}, {"source_id": -1}, {"source_id": None},
    {"title": ""}, {"title": " "}, {"title": "x" * 161},
    {"message": ""}, {"message": " "}, {"message": "x" * 501},
])
def test_migrated_constraints(migration_db, changes):
    engine, config = migration_db
    command.upgrade(config, SCHEMA_HEAD)
    with pytest.raises(IntegrityError), engine.begin() as connection:
        connection.execute(Notification.__table__.insert(), notification(**changes))
    assert snapshot(engine, Notification.__table__) == []


def test_migrated_duplicate_key_and_distinct_source_recipient_event_category(migration_db):
    engine, config = migration_db
    command.upgrade(config, SCHEMA_HEAD)
    with engine.begin() as connection:
        connection.execute(Notification.__table__.insert(), notification())
    with pytest.raises(IntegrityError), engine.begin() as connection:
        connection.execute(Notification.__table__.insert(), notification())
    with engine.begin() as connection:
        for changes in [{"recipient_user_id": 1}, {"source_id": 2},
                        {"event_type": "connection.revoked"}, {"category": "emergency"}]:
            connection.execute(Notification.__table__.insert(), notification(**changes))
    assert len(snapshot(engine, Notification.__table__)) == 5


def test_user_cascade_removes_only_own_inbox_source_cascade_preserves_others_history(migration_db):
    engine, config = migration_db
    insert_link(engine)
    command.upgrade(config, SCHEMA_HEAD)
    with engine.begin() as connection:
        connection.execute(Notification.__table__.insert(), [notification(), notification(recipient_user_id=1)])
        connection.execute(User.__table__.delete().where(User.id == 2))
    assert snapshot(engine, EmergencyContactLink.__table__) == []
    remaining = snapshot(engine, Notification.__table__)
    assert len(remaining) == 1 and remaining[0].recipient_user_id == 1


def test_explicit_notification_downgrade_only_drops_new_table(migration_db):
    engine, config = migration_db
    insert_link(engine)
    command.upgrade(config, SCHEMA_HEAD)
    with engine.begin() as connection:
        connection.execute(Notification.__table__.insert(), notification())
    before = {model: snapshot(engine, model.__table__) for model in (User, EmergencyContact, EmergencyContactLink)}
    command.downgrade(config, PARENT)
    assert "notifications" not in inspect(engine).get_table_names()
    for model, rows in before.items():
        assert snapshot(engine, model.__table__) == rows
    command.upgrade(config, SCHEMA_HEAD)
    assert snapshot(engine, Notification.__table__) == []


def test_postgresql_ddl_and_revision_chain_without_server_connection(migration_db):
    _, config = migration_db
    script = ScriptDirectory.from_config(config)
    assert script.get_heads() == [SCHEMA_HEAD]
    revision = script.get_revision(REVISION)
    assert revision.down_revision == PARENT
    output = StringIO()
    context = MigrationContext.configure(dialect_name="postgresql", opts={"as_sql": True, "output_buffer": output})
    with Operations.context(context):
        revision.module.upgrade()
    sql = output.getvalue()
    assert "CREATE TABLE notifications" in sql
    assert "TIMESTAMP WITH TIME ZONE" in sql
    assert "FOREIGN KEY(recipient_user_id) REFERENCES users (id) ON DELETE CASCADE" in sql
    assert "UNIQUE (recipient_user_id, category, event_type, source_id)" in sql
    assert "WHERE read_at IS NULL" in sql
    assert "emergency_contacts" not in sql and "emergency_contact_links" not in sql
    assert all(statement not in sql for statement in ("INSERT INTO", "UPDATE ", "DELETE FROM"))
