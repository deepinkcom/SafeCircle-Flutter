"""Persistent connection events. Never commits, sends push, or invents history."""

from datetime import datetime
import logging

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from .models import Alert, Device, EmergencyContactLink, Notification, PushDelivery, User


CONNECTION_COPY = {
    "connection.invited": ("SafeCircle invitation", "A SafeCircle member sent you a connection invitation."),
    "connection.accepted": ("Invitation accepted", "Your SafeCircle connection invitation was accepted."),
    "connection.rejected": ("Invitation rejected", "Your SafeCircle connection invitation was rejected."),
    "connection.revoked": ("Connection ended", "A SafeCircle invitation or connection involving you was revoked."),
}

logger = logging.getLogger(__name__)


def record_connection_event(
    db: Session, *, link: EmergencyContactLink, recipient_user_id: int,
    event_type: str, created_at: datetime,
) -> Notification | None:
    """Join the caller's transaction. The DB unique key is the final race guard.

    Relationship transitions already hold the row lock. Repeated calls within
    that transaction return the same event without resetting read state.
    """
    if recipient_user_id not in (link.inviter_user_id, link.invitee_user_id):
        raise ValueError("Notification recipient must be a relationship participant")
    title, message = CONNECTION_COPY[event_type]
    # Preserve existing orphan-link handling: a nonexistent account has no
    # inbox. Never substitute another user or create a dangling recipient FK.
    # Normal FK-enforced databases cascade links when their users are deleted.
    if db.scalar(select(User.id).where(User.id == recipient_user_id)) is None:
        return None
    existing = db.scalar(select(Notification).where(
        Notification.recipient_user_id == recipient_user_id,
        Notification.category == "connection",
        Notification.event_type == event_type,
        Notification.source_id == link.id,
    ))
    if existing is not None:
        return existing
    notification = Notification(
        recipient_user_id=recipient_user_id, category="connection", event_type=event_type,
        source_id=link.id, created_at=created_at, title=title, message=message,
    )
    db.add(notification)
    db.flush()  # Surface persistence errors before the relationship commit.
    for device_id in db.scalars(select(Device.id).where(Device.user_id == recipient_user_id)):
        db.add(PushDelivery(notification_id=notification.id, device_id=device_id, next_attempt_at=created_at))
    db.flush()
    return notification


def record_emergency_alert_events(
    db: Session,
    *,
    alert: Alert,
    created_at: datetime,
) -> int:
    """Create inbox notifications and push jobs for accepted contacts.

    Joins the caller's database transaction. Does not commit or send FCM.
    """
    if alert.kind != "panic":
        raise ValueError("Only panic alerts can generate emergency events")

    links = db.scalars(
        select(EmergencyContactLink).where(
            EmergencyContactLink.status == "accepted",
            or_(
                EmergencyContactLink.inviter_user_id == alert.user_id,
                EmergencyContactLink.invitee_user_id == alert.user_id,
            ),
        )
    ).all()

    recipient_ids = {
        link.invitee_user_id
        if link.inviter_user_id == alert.user_id
        else link.inviter_user_id
        for link in links
    }

    created_count = 0

    for recipient_id in recipient_ids:
        recipient_exists = db.scalar(
            select(User.id).where(User.id == recipient_id)
        )

        if recipient_exists is None:
            continue

        existing = db.scalar(
            select(Notification).where(
                Notification.recipient_user_id == recipient_id,
                Notification.category == "emergency",
                Notification.event_type == "emergency.panic",
                Notification.source_id == alert.id,
            )
        )

        if existing is not None:
            continue

        notification = Notification(
            recipient_user_id=recipient_id,
            category="emergency",
            event_type="emergency.panic",
            source_id=alert.id,
            created_at=created_at,
            title="Emergency alert",
            message="An emergency contact has triggered a SafeCircle panic alert.",
        )

        db.add(notification)
        db.flush()

        device_ids = db.scalars(
            select(Device.id).where(Device.user_id == recipient_id)
        ).all()

        for device_id in device_ids:
            db.add(
                PushDelivery(
                    notification_id=notification.id,
                    device_id=device_id,
                    next_attempt_at=created_at,
                )
            )

        db.flush()
        created_count += 1

    return created_count


def recover_one_pending_emergency_event(db: Session) -> bool:
    """Idempotently recover one saved panic alert whose event transaction failed."""
    alert = db.scalar(
        select(Alert)
        .where(Alert.notification_events_status == "pending")
        .order_by(Alert.id)
        .with_for_update(skip_locked=True)
        .limit(1)
    )
    if alert is None:
        db.rollback()
        return False

    alert_id = alert.id
    try:
        created_count = record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        alert.notification_events_status = "complete"
        db.commit()
        logger.info(
            "panic_notification_event_recovered",
            extra={"alert_id": alert_id, "notification_count": created_count},
        )
        return True
    except Exception as error:
        db.rollback()
        logger.error(
            "panic_notification_event_recovery_failed",
            extra={"alert_id": alert_id, "exception_type": type(error).__name__},
        )
        return False
