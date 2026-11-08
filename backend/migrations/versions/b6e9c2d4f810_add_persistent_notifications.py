"""Add recipient-owned notification history without changing existing data.

Revision ID: b6e9c2d4f810
Revises: 8c2f7d1a6b90
"""

from alembic import op
import sqlalchemy as sa


revision = "b6e9c2d4f810"
down_revision = "8c2f7d1a6b90"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "notifications",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("recipient_user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("category", sa.String(20), nullable=False),
        sa.Column("event_type", sa.String(64), nullable=False),
        sa.Column("source_id", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("CURRENT_TIMESTAMP"), nullable=False),
        sa.Column("read_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("title", sa.String(160), nullable=False),
        sa.Column("message", sa.String(500), nullable=False),
        sa.CheckConstraint("category IN ('emergency', 'connection')", name="ck_notifications_category"),
        sa.CheckConstraint("source_id > 0", name="ck_notifications_source_id"),
        sa.CheckConstraint("length(trim(event_type)) BETWEEN 1 AND 64", name="ck_notifications_event_type"),
        sa.CheckConstraint("length(trim(title)) BETWEEN 1 AND 160", name="ck_notifications_title"),
        sa.CheckConstraint("length(trim(message)) BETWEEN 1 AND 500", name="ck_notifications_message"),
        sa.UniqueConstraint("recipient_user_id", "category", "event_type", "source_id", name="uq_notifications_recipient_event_source"),
    )
    op.create_index("ix_notifications_recipient_created", "notifications", ["recipient_user_id", "created_at", "id"])
    op.create_index("ix_notifications_unread", "notifications", ["recipient_user_id", "category"],
                    postgresql_where=sa.text("read_at IS NULL"), sqlite_where=sa.text("read_at IS NULL"))


def downgrade() -> None:
    # Destructive for notification history: only execute with explicit approval.
    op.drop_index("ix_notifications_unread", table_name="notifications")
    op.drop_index("ix_notifications_recipient_created", table_name="notifications")
    op.drop_table("notifications")
