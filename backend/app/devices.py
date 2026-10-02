from datetime import datetime

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from .database import SessionLocal
from .models import Device


router = APIRouter(prefix="/devices", tags=["devices"])


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class DeviceCreate(BaseModel):
    fcm_token: str
    platform: str


@router.post("")
def register_device(
    device_data: DeviceCreate,
    user_id: int = 1,
    db: Session = Depends(get_db),
):
    device = Device(
        user_id=user_id,
        fcm_token=device_data.fcm_token,
        platform=device_data.platform,
        registered_at=datetime.utcnow(),
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