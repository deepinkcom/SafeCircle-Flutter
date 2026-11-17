"""Associate registered push devices with app installations.

Revision ID: a91b8c7d6e5f
Revises: e17d6a10bc25
"""
from alembic import op
import sqlalchemy as sa


revision = "a91b8c7d6e5f"
down_revision = "e17d6a10bc25"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "device_installations",
        sa.Column("installation_id", sa.String(length=64), primary_key=True),
        sa.Column(
            "owner_user_id",
            sa.Integer(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
    )
    op.add_column(
        "devices", sa.Column("installation_id", sa.String(length=64), nullable=True)
    )
    op.create_index(
        "ix_devices_user_installation", "devices", ["user_id", "installation_id"]
    )
def downgrade():
    bind = op.get_bind()
    if bind.scalar(sa.text("SELECT count(*) FROM device_installations")):
        raise RuntimeError(
            "Installation ownership records prevent downgrade; no data was removed"
        )
    if bind.scalar(
        sa.text("SELECT count(*) FROM devices WHERE installation_id IS NOT NULL")
    ):
        raise RuntimeError(
            "Attributed device registrations prevent downgrade; no data was removed"
        )
    op.drop_index("ix_devices_user_installation", table_name="devices")
    with op.batch_alter_table("devices") as batch:
        batch.drop_column("installation_id")
    op.drop_table("device_installations")
