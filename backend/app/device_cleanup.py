"""Caller holds the device lock; cleanup joins its transaction and never commits."""
from sqlalchemy import select

from .models import PushDelivery


def remove_registration(db, device, *, failed_job_id=None):
    # All final send/cleanup paths lock device first, then jobs in ID order.
    jobs = db.scalars(select(PushDelivery).where(
        PushDelivery.device_id == device.id,
        PushDelivery.status.in_(["pending", "sending"]),
    ).order_by(PushDelivery.id).with_for_update().execution_options(populate_existing=True)).all()
    for job in jobs:
        job.status = "failed" if job.id == failed_job_id else "cancelled"
    db.flush()
    db.delete(device)  # SET NULL preserves terminal statuses and attempt counts.
    db.flush()
