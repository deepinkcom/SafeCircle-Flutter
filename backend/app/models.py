from datetime import datetime, timezone

from geoalchemy2 import Geography
from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from .database import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    firebase_uid: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    city: Mapped[str] = mapped_column(String(100), nullable=False)
    phone: Mapped[str] = mapped_column(String(50), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )


class EmergencyContact(Base):
    __tablename__ = "emergency_contacts"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"),
        nullable=False,
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    relationship: Mapped[str] = mapped_column(String(100), nullable=False)
    phone: Mapped[str] = mapped_column(String(50), nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )


class Alert(Base):
    __tablename__ = "alerts"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"),
        nullable=False,
    )
    kind: Mapped[str] = mapped_column(String(50), nullable=False)
    status: Mapped[str] = mapped_column(String(50), nullable=False)
    location = mapped_column(
        Geography(geometry_type="POINT", srid=4326),
        nullable=True,
    )
    location_label: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )
    resolved_at: Mapped[datetime | None] = mapped_column(
        DateTime,
        nullable=True,
    )

class AlertAcknowledgement(Base):
    __tablename__ = "alert_acknowledgements"
    __table_args__ = (
        UniqueConstraint(
            "alert_id",
            "responder_user_id",
            name="uq_alert_acknowledgements_alert_responder",
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    alert_id: Mapped[int] = mapped_column(
        ForeignKey("alerts.id"),
        nullable=False,
    )
    responder_user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"),
        nullable=False,
    )
    status: Mapped[str] = mapped_column(String(50), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )

 
class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (UniqueConstraint("fcm_token", name="uq_devices_fcm_token"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"),
        nullable=False,
    )
    fcm_token: Mapped[str] = mapped_column(String(500), nullable=False)
    platform: Mapped[str] = mapped_column(String(50), nullable=False)
    registered_at: Mapped[datetime] = mapped_column(
        DateTime,
        default=datetime.utcnow,
        nullable=False,
    )

    
class EmergencyContactLink(Base):
    """
    Represents an invitation or accepted emergency-contact relationship
    between two registered SafeCircle users.
    """

    __tablename__ = "emergency_contact_links"

    __table_args__ = (
        CheckConstraint(
            "inviter_user_id != invitee_user_id",
            name="ck_emergency_contact_links_no_self_invite",
        ),
        CheckConstraint(
            "status IN ('pending', 'accepted', 'rejected', 'revoked')",
            name="ck_emergency_contact_links_valid_status",
        ),
        Index(
            "uq_emergency_contact_links_active_unordered_pair",
            text(
                "(CASE WHEN inviter_user_id < invitee_user_id "
                "THEN inviter_user_id ELSE invitee_user_id END)"
            ),
            text(
                "(CASE WHEN inviter_user_id < invitee_user_id "
                "THEN invitee_user_id ELSE inviter_user_id END)"
            ),
            unique=True,
            postgresql_where=text("status IN ('pending', 'accepted')"),
            sqlite_where=text("status IN ('pending', 'accepted')"),
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)

    inviter_user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    invitee_user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    status: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default="pending",
        server_default="pending",
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        server_default=text("CURRENT_TIMESTAMP"),
        nullable=False,
    )

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        server_default=text("CURRENT_TIMESTAMP"),
        onupdate=lambda: datetime.now(timezone.utc),
        nullable=False,
    )

    responded_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )


class Notification(Base):
    """Recipient-owned event history; source IDs intentionally outlive sources."""

    __tablename__ = "notifications"
    __table_args__ = (
        CheckConstraint("category IN ('emergency', 'connection')", name="ck_notifications_category"),
        CheckConstraint("source_id > 0", name="ck_notifications_source_id"),
        CheckConstraint("length(trim(event_type)) BETWEEN 1 AND 64", name="ck_notifications_event_type"),
        CheckConstraint("length(trim(title)) BETWEEN 1 AND 160", name="ck_notifications_title"),
        CheckConstraint("length(trim(message)) BETWEEN 1 AND 500", name="ck_notifications_message"),
        UniqueConstraint("recipient_user_id", "category", "event_type", "source_id",
                         name="uq_notifications_recipient_event_source"),
        Index("ix_notifications_recipient_created", "recipient_user_id", "created_at", "id"),
        Index("ix_notifications_unread", "recipient_user_id", "category",
              postgresql_where=text("read_at IS NULL"), sqlite_where=text("read_at IS NULL")),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    recipient_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    category: Mapped[str] = mapped_column(String(20), nullable=False)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    # Polymorphic source reference, not a cascading FK: history must survive.
    source_id: Mapped[int] = mapped_column(nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc),
        server_default=text("CURRENT_TIMESTAMP"), nullable=False,
    )
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    title: Mapped[str] = mapped_column(String(160), nullable=False)
    message: Mapped[str] = mapped_column(String(500), nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class PushDelivery(Base):
    __tablename__ = "push_deliveries"
    __table_args__ = (
        UniqueConstraint("notification_id", "device_id", name="uq_push_delivery_notification_device"),
        CheckConstraint("status IN ('pending','sending','sent','failed','cancelled')", name="ck_push_delivery_status"),
        Index("ix_push_delivery_due", "status", "next_attempt_at"),
    )
    id: Mapped[int] = mapped_column(primary_key=True)
    notification_id: Mapped[int] = mapped_column(ForeignKey("notifications.id", ondelete="CASCADE"), nullable=False)
    device_id: Mapped[int] = mapped_column(ForeignKey("devices.id", ondelete="CASCADE"), nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="pending", nullable=False)
    attempts: Mapped[int] = mapped_column(default=0, nullable=False)
    next_attempt_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), nullable=False)
