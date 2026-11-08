"""Run explicitly with `python -m app.push_worker`; no sender in DB transactions."""
import logging
import time
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Device, Notification, PushDelivery, User

logger = logging.getLogger(__name__)


from .notification_service import firebase_notification_delivery as firebase_delivery


def deliver_one(db: Session, sender=firebase_delivery, now=None):
    """Lease one job. At-least-once delivery; stable IDs deduplicate clients."""
    now = now or datetime.now(timezone.utc)
    job = db.scalar(select(PushDelivery).where(
        PushDelivery.status.in_(["pending", "sending"]), PushDelivery.next_attempt_at <= now,
    ).order_by(PushDelivery.id).with_for_update(skip_locked=True).limit(1))
    if job is None:
        db.rollback()
        return False
    notice = db.get(Notification, job.notification_id)
    device = db.get(Device, job.device_id)
    user = db.get(User, notice.recipient_user_id) if notice else None
    if notice is None or notice.category != "connection" or notice.deleted_at is not None or device is None or user is None or device.user_id != notice.recipient_user_id:
        job.status = "cancelled"
        db.commit()
        return True
    if job.attempts >= 5:
        job.status = "failed"
        db.commit()
        return True
    job.attempts += 1
    job.status = "sending"
    job.next_attempt_at = now + timedelta(minutes=2)
    db.commit()  # Do not hold the relationship transaction/lock during FCM.
    try:
        # Recheck suppression/ownership immediately before sending a leased job.
        db.refresh(notice); db.refresh(device)
        if notice.deleted_at is not None or device.user_id != notice.recipient_user_id:
            job.status = "cancelled"
        else:
            sender(device.fcm_token, notice, user.firebase_uid)
            job.status = "sent"
    except Exception as error:
        from firebase_admin import messaging
        if isinstance(error, (messaging.UnregisteredError, messaging.SenderIdMismatchError)):
            db.delete(device)  # Invalid token only; user's inbox is preserved.
        else:
            job.status = "failed" if job.attempts >= 5 else "pending"
            job.next_attempt_at = now + timedelta(seconds=min(3600, 30 * 2 ** job.attempts))
        logger.warning("SafeCircle push delivery failed")  # No tokens/provider text/locations.
    db.commit()
    return True


def main():
    from .database import SessionLocal
    while True:
        try:
            with SessionLocal() as db:
                sent = deliver_one(db)
            if not sent:
                time.sleep(5)
        except Exception:
            logger.warning("SafeCircle push worker retrying after storage failure")
            time.sleep(5)

if __name__ == "__main__":
    main()
