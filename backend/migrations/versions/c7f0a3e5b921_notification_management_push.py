"""Soft deletion, persistent push jobs, unique device ownership.

Revision ID: c7f0a3e5b921
Revises: b6e9c2d4f810
"""
from alembic import op
import sqlalchemy as sa

revision = "c7f0a3e5b921"
down_revision = "b6e9c2d4f810"
branch_labels = None
depends_on = None

def upgrade():
    op.add_column("notifications", sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True))
    # Fail on conflicting existing tokens; never silently reassign/delete them.
    op.create_index("uq_devices_fcm_token", "devices", ["fcm_token"], unique=True)
    op.create_table("push_deliveries",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("notification_id", sa.Integer(), sa.ForeignKey("notifications.id", ondelete="CASCADE"), nullable=False),
        sa.Column("device_id", sa.Integer(), sa.ForeignKey("devices.id", ondelete="CASCADE"), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("notification_id", "device_id", name="uq_push_delivery_notification_device"),
        sa.CheckConstraint("status IN ('pending','sending','sent','failed','cancelled')", name="ck_push_delivery_status"))
    op.create_index("ix_push_delivery_due", "push_deliveries", ["status", "next_attempt_at"])

def downgrade():
    op.drop_index("ix_push_delivery_due", table_name="push_deliveries")
    op.drop_table("push_deliveries")
    op.drop_index("uq_devices_fcm_token", table_name="devices")
    op.drop_column("notifications", "deleted_at")
