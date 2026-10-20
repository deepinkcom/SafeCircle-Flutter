
from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db
from .models import Device, User


router = APIRouter(prefix="/devices", tags=["devices"])

class DeviceCreate(BaseModel):
    fcm_token: str
    platform: str



@router.post("")
def register_device(
    device_data: DeviceCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    fcm_token = device_data.fcm_token.strip()
    platform = device_data.platform.strip().lower()

    if not fcm_token:
        from fastapi import HTTPException
        raise HTTPException(
            status_code=422,
            detail="FCM token cannot be empty",
        )

    if platform not in {"android", "ios"}:
        from fastapi import HTTPException
        raise HTTPException(
            status_code=422,
            detail="Platform must be android or ios",
        )

    device = Device(
        user_id=current_user.id,
        fcm_token=fcm_token,
        platform=platform,
        registered_at=datetime.now(timezone.utc),
    )

    db.add(device)
    db.commit()
    db.refresh(device)

    return {
        "id": device.id,
        "user_id": device.user_id,
        "fcm_token": device.fcm_token,
        "platform": device.platform,
        "registered_at": device.registered_at.isoformat(),
    }
