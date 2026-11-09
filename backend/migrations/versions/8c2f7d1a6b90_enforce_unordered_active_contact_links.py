"""Prevent active contact links in either direction for the same pair.

Revision ID: 8c2f7d1a6b90
Revises: 2549fa7ab98a
"""

from alembic import op
import sqlalchemy as sa


revision = "8c2f7d1a6b90"
down_revision = "2549fa7ab98a"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Build the stronger index first. Conflicting existing rows fail the
    # migration; never delete, merge, or silently revoke relationships.
    op.create_index(
        "uq_emergency_contact_links_active_unordered_pair",
        "emergency_contact_links",
        [
            sa.text(
                "(CASE WHEN inviter_user_id < invitee_user_id "
                "THEN inviter_user_id ELSE invitee_user_id END)"
            ),
            sa.text(
                "(CASE WHEN inviter_user_id < invitee_user_id "
                "THEN invitee_user_id ELSE inviter_user_id END)"
            ),
        ],
        unique=True,
        postgresql_where=sa.text("status IN ('pending', 'accepted')"),
        sqlite_where=sa.text("status IN ('pending', 'accepted')"),
    )
    op.drop_index(
        "uq_emergency_contact_links_active_pair",
        table_name="emergency_contact_links",
    )


def downgrade() -> None:
    # Restore the previous (directional) guarantee without removing data.
    op.create_index(
        "uq_emergency_contact_links_active_pair",
        "emergency_contact_links",
        ["inviter_user_id", "invitee_user_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('pending', 'accepted')"),
        sqlite_where=sa.text("status IN ('pending', 'accepted')"),
    )
    op.drop_index(
        "uq_emergency_contact_links_active_unordered_pair",
        table_name="emergency_contact_links",
    )
