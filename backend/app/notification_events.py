"""Persistent connection events. Never commits, sends push, or invents history."""

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Device, EmergencyContactLink, Notification, PushDelivery, User


CONNECTION_COPY = {
    "connection.invited": ("SafeCircle invitation", "A SafeCircle member sent you a connection invitation."),
    "connection.accepted": ("Invitation accepted", "Your SafeCircle connection invitation was accepted."),
    "connection.rejected": ("Invitation rejected", "Your SafeCircle connection invitation was rejected."),
    "connection.revoked": ("Connection ended", "A SafeCircle invitation or connection involving you was revoked."),
}


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
