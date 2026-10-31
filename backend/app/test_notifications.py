import os

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db
from .models import Device, User
from .notification_service import NotificationService, firebase_sender


router = APIRouter(
    prefix="/test-notifications",
    tags=["development-notifications"],
)


@router.post("/me")
def send_test_notification(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    if os.getenv("SAFECIRCLE_ENABLE_TEST_NOTIFICATIONS", "").lower() != "true":
        raise HTTPException(
            status_code=404,
            detail="Not found",
        )

    device = db.scalar(
        select(Device)
        .where(
            Device.user_id == current_user.id,
            Device.platform == "android",
        )
        .order_by(Device.registered_at.desc())
    )

    if device is None:
        raise HTTPException(
            status_code=404,
            detail="No registered Android device was found",
        )

    service = NotificationService(sender=firebase_sender)
    result = service.send_to_token(
        device.fcm_token,
        "SafeCircle test notification",
        "This is a test notification. No emergency alert was created.",
    )

    if not result.success:
        raise HTTPException(
            status_code=502,
            detail="Test notification delivery failed",
        )

    return {
        "success": True,
        "message": "Test notification accepted by Firebase",
        "message_id": result.message_id,
    }
