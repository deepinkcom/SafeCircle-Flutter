"""Explicit worker: generation-fenced leases and device-locked FCM submission."""
import logging
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from .device_cleanup import remove_registration
from .models import Device, Notification, PushDelivery, User
from .push_submission import bounded_firebase_delivery as firebase_delivery

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class _Lease:
    job_id: int
    device_id: int
    notification_id: int
    generation: int


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def _claim(db, now):
    job = db.scalar(select(PushDelivery).where(
        PushDelivery.status.in_(["pending", "sending"]), PushDelivery.next_attempt_at <= now,
    ).order_by(PushDelivery.id).with_for_update(skip_locked=True).limit(1))
    if job is None:
        db.rollback()
        return None
    notice = db.get(Notification, job.notification_id)
    device = db.get(Device, job.device_id) if job.device_id is not None else None
    user = db.get(User, notice.recipient_user_id) if notice else None
    if (notice is None or notice.category != "connection" or notice.deleted_at is not None
            or device is None or user is None or device.user_id != notice.recipient_user_id):
        job.status = "cancelled"
        db.commit()
        return True
    if job.attempts >= 5:
        job.status = "failed"
        db.commit()
        return True
    job.attempts += 1  # Monotonic lease generation: never reset on retries.
    job.status = "sending"
    job.next_attempt_at = now + timedelta(minutes=2)
    lease = _Lease(job.id, job.device_id, job.notification_id, job.attempts)
    db.commit()  # Release the claim's job lock before acquiring any device lock.
    return lease


def _deliver_claim(db, lease, sender, now=None):
    # Device -> notification -> job. Logout/invalid cleanup use device -> jobs.
    # A claimant holds only a job lock and never waits on a device.
    device = db.scalar(select(Device).where(Device.id == lease.device_id)
                       .with_for_update().execution_options(populate_existing=True))
    notice = db.scalar(select(Notification).where(Notification.id == lease.notification_id)
                       .with_for_update().execution_options(populate_existing=True))
    job = db.scalar(select(PushDelivery).where(PushDelivery.id == lease.job_id)
                    .with_for_update().execution_options(populate_existing=True))
    now = now or datetime.now(timezone.utc)  # Check expiry after any lock wait.
    if (job is None or job.status != "sending" or job.attempts != lease.generation
            or job.device_id != lease.device_id or _utc(job.next_attempt_at) <= now):
        db.rollback()  # Stale workers neither send nor overwrite newer state.
        return False
    user = db.get(User, notice.recipient_user_id) if notice else None
    if (device is None or notice is None or user is None or notice.category != "connection"
            or notice.deleted_at is not None or device.user_id != notice.recipient_user_id):
        job.status = "cancelled"
        db.commit()
        return True
    try:
        # Keep registration locked through the bounded provider call. A
        # confirmed logout cannot be followed by a new old-owner submission.
        sender(device.fcm_token, notice, user.firebase_uid)
        job.status = "sent"
    except Exception as error:
        from firebase_admin import messaging
        if isinstance(error, (messaging.UnregisteredError, messaging.SenderIdMismatchError)):
            remove_registration(db, device, failed_job_id=job.id)
        else:
            job.status = "failed" if job.attempts >= 5 else "pending"
            job.next_attempt_at = now + timedelta(seconds=min(3600, 30 * 2 ** job.attempts))
        logger.warning("SafeCircle push delivery failed")
    db.commit()
    return True


def deliver_one(db: Session, sender=firebase_delivery, now=None):
    """At-least-once delivery; stable notification IDs deduplicate clients."""
    lease = _claim(db, now or datetime.now(timezone.utc))
    if lease is None:
        return False
    if lease is True:
        return True
    _deliver_claim(db, lease, sender, now)
    return True


def main():
    from .database import SessionLocal
    while True:
        try:
            with SessionLocal() as db:
                processed = deliver_one(db)
            if not processed:
                time.sleep(5)
        except Exception:
            logger.warning("SafeCircle push worker retrying after storage failure")
            time.sleep(5)


if __name__ == "__main__":
    main()
