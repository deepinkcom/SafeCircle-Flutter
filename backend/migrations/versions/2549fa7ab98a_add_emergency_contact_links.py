
"""add emergency contact links

Revision ID: 2549fa7ab98a
Revises:
Create Date: 2026-11-05

"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "2549fa7ab98a"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Create emergency contact relationship links."""

    op.create_table(
        "emergency_contact_links",
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column(
            "inviter_user_id",
            sa.Integer(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "invitee_user_id",
            sa.Integer(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "status",
            sa.String(length=20),
            nullable=False,
            server_default="pending",
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column(
            "responded_at",
            sa.DateTime(timezone=True),
            nullable=True,
        ),
        sa.Column(
            "revoked_at",
            sa.DateTime(timezone=True),
            nullable=True,
        ),
        sa.CheckConstraint(
            "inviter_user_id <> invitee_user_id",
            name="ck_emergency_contact_links_no_self_invite",
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'accepted', 'rejected', 'revoked')",
            name="ck_emergency_contact_links_valid_status",
        ),
    )

    op.create_index(
        "uq_emergency_contact_links_active_pair",
        "emergency_contact_links",
        ["inviter_user_id", "invitee_user_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('pending', 'accepted')"),
    )


def downgrade() -> None:
    """Remove emergency contact relationship links."""

    op.drop_index(
        "uq_emergency_contact_links_active_pair",
        table_name="emergency_contact_links",
    )

    op.drop_table("emergency_contact_links")
