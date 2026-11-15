"""Track durable recovery state for panic notification event creation.

Revision ID: e17d6a10bc25
Revises: d9a4f6b2c730
"""
from alembic import op
import sqlalchemy as sa


revision = "e17d6a10bc25"
down_revision = "d9a4f6b2c730"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("alerts") as batch:
        batch.add_column(sa.Column(
            "notification_events_status",
            sa.String(length=16),
            server_default="complete",
            nullable=False,
        ))
        batch.create_check_constraint(
            "ck_alerts_notification_events_status",
            "notification_events_status IN ('pending', 'complete')",
        )


def downgrade():
    bind = op.get_bind()
    if op.get_context().as_sql:
        op.execute(
            "DO $$ BEGIN IF EXISTS (SELECT 1 FROM alerts "
            "WHERE notification_events_status = 'pending') THEN "
            "RAISE EXCEPTION 'Pending panic event recovery prevents downgrade'; "
            "END IF; END; $$"
        )
    elif bind.scalar(
        sa.text(
            "SELECT count(*) FROM alerts "
            "WHERE notification_events_status = 'pending'"
        )
    ):
        raise RuntimeError(
            "Pending panic event recovery prevents downgrade; no rows were removed"
        )
    with op.batch_alter_table("alerts") as batch:
        batch.drop_constraint(
            "ck_alerts_notification_events_status",
            type_="check",
        )
        batch.drop_column("notification_events_status")
