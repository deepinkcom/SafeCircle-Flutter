from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import select
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db
from .models import Device, User


router = APIRouter(prefix="/devices", tags=["devices"])


class DeviceCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    fcm_token: str = Field(min_length=1, max_length=500)
    platform: str = Field(min_length=1, max_length=50)

    @field_validator("fcm_token")
    @classmethod
    def validate_fcm_token(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("FCM token cannot be empty")
        return value

    @field_validator("platform")
    @classmethod
    def validate_platform(cls, value: str) -> str:
        value = value.strip().lower()
        if value not in {"android", "ios"}:
            raise ValueError("Platform must be android or ios")
        return value


@router.post("")
def register_device(
    device_data: DeviceCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    existing_device = db.scalar(
        select(Device).where(Device.fcm_token == device_data.fcm_token)
    )

    if existing_device is not None:
        if existing_device.user_id != current_user.id:
            raise HTTPException(
                status_code=409,
                detail="This device token is already registered to another user",
            )

        existing_device.platform = device_data.platform
        existing_device.registered_at = datetime.now(timezone.utc)
        device = existing_device
    else:
        device = Device(
            user_id=current_user.id,
            fcm_token=device_data.fcm_token,
            platform=device_data.platform,
            registered_at=datetime.now(timezone.utc),
        )
        db.add(device)

    db.commit()
    db.refresh(device)

    return {
        "id": device.id,
        "user_id": device.user_id,
        "platform": device.platform,
        "registered_at": device.registered_at.isoformat(),
    }
