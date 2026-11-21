"""Exercise the installation revision against disposable historical SQLite data."""

import importlib.util
from pathlib import Path

import pytest
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, inspect, text


REVISION_PATH = Path(__file__).resolve().parents[1] / "migrations" / "versions" / "a91b8c7d6e5f_scope_devices_to_installation.py"
SPEC = importlib.util.spec_from_file_location("installation_revision", REVISION_PATH)
REVISION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REVISION)


@pytest.fixture
def historical_db(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'installation.db'}")
    with engine.begin() as connection:
        connection.execute(text("CREATE TABLE users (id INTEGER PRIMARY KEY)"))
        connection.execute(text(
            "CREATE TABLE devices (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, "
            "fcm_token VARCHAR(500) NOT NULL, platform VARCHAR(50) NOT NULL, "
            "registered_at DATETIME NOT NULL)"
        ))
        connection.execute(text("INSERT INTO users (id) VALUES (1)"))
        connection.execute(text(
            "INSERT INTO devices VALUES (7, 1, 'synthetic-legacy-token', 'android', '2026-01-01')"
        ))
        context = MigrationContext.configure(connection)
        with Operations.context(context):
            REVISION.upgrade()
    yield engine
    engine.dispose()


def test_upgrade_preserves_legacy_registrations_unattributed(historical_db):
    with historical_db.connect() as connection:
        row = connection.execute(text(
            "SELECT id, user_id, fcm_token, installation_id FROM devices"
        )).one()
        assert row == (7, 1, "synthetic-legacy-token", None)
        assert "device_installations" in inspect(connection).get_table_names()
        assert "ix_devices_user_installation" in {
            index["name"] for index in inspect(connection).get_indexes("devices")
        }


def test_downgrade_refuses_to_remove_attributed_identity_data(historical_db):
    with historical_db.begin() as connection:
        connection.execute(text(
            "INSERT INTO device_installations (installation_id, owner_user_id) "
            "VALUES (:id, 1)"
        ), {"id": "a" * 64})
        context = MigrationContext.configure(connection)
        with Operations.context(context), pytest.raises(RuntimeError, match="ownership records"):
            REVISION.downgrade()
    with historical_db.connect() as connection:
        assert "installation_id" in {column["name"] for column in inspect(connection).get_columns("devices")}
        assert connection.scalar(text("SELECT count(*) FROM device_installations")) == 1


def test_empty_installation_schema_can_downgrade_and_upgrade(historical_db):
    with historical_db.begin() as connection:
        context = MigrationContext.configure(connection)
        with Operations.context(context):
            REVISION.downgrade()
            REVISION.upgrade()
    with historical_db.connect() as connection:
        assert "installation_id" in {column["name"] for column in inspect(connection).get_columns("devices")}
        assert "device_installations" in inspect(connection).get_table_names()
