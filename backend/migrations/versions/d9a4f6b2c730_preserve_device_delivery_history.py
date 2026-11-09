"""Preserve delivery history when a registration is removed.

Revision ID: d9a4f6b2c730
Revises: c7f0a3e5b921
"""
from alembic import context, op
import sqlalchemy as sa

revision = "d9a4f6b2c730"
down_revision = "c7f0a3e5b921"
branch_labels = None
depends_on = None


def _change(nullable, ondelete):
    sqlite = op.get_bind().dialect.name == "sqlite"
    name = "fk_push_deliveries_device_id_devices" if sqlite else "push_deliveries_device_id_fkey"
    convention = {"fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s"}
    with op.batch_alter_table("push_deliveries", naming_convention=convention) as batch:
        batch.drop_constraint(name, type_="foreignkey")
        batch.alter_column("device_id", existing_type=sa.Integer(), nullable=nullable)
        batch.create_foreign_key(name, "devices", ["device_id"], ["id"], ondelete=ondelete)


def upgrade():
    _change(True, "SET NULL")
    op.create_index("ix_push_delivery_device", "push_deliveries", ["device_id"])


def downgrade():
    bind = op.get_bind()
    if context.is_offline_mode():
        op.execute("LOCK TABLE push_deliveries IN ACCESS EXCLUSIVE MODE")
        op.execute("DO $$ BEGIN IF EXISTS (SELECT 1 FROM push_deliveries WHERE device_id IS NULL) "
                   "THEN RAISE EXCEPTION 'Detached delivery history prevents downgrade'; END IF; END; $$")
    else:
        if bind.dialect.name == "postgresql":
            op.execute("LOCK TABLE push_deliveries IN ACCESS EXCLUSIVE MODE")
        if bind.scalar(sa.text("SELECT count(*) FROM push_deliveries WHERE device_id IS NULL")):
            raise RuntimeError("Detached delivery history prevents downgrade; no rows were removed")
    op.drop_index("ix_push_delivery_device", table_name="push_deliveries")
    _change(False, "CASCADE")
