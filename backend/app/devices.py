from datetime import datetime, timezone
import logging
import sqlite3

from fastapi import APIRouter, Depends, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db
from .models import Device, User
from .device_cleanup import remove_registration


logger = logging.getLogger(__name__)


class _PrivateDeviceRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def private_handler(request):
            try:
                return await handler(request)
            except RequestValidationError:
                # FastAPI's default validation body includes rejected input.
                raise HTTPException(422, "Invalid device registration details") from None

        return private_handler


router = APIRouter(prefix="/devices", tags=["devices"], route_class=_PrivateDeviceRoute)


def _is_token_conflict(error):
    original = error.orig
    if (getattr(original, "pgcode", None) or getattr(original, "sqlstate", None)) == "23505":
        return getattr(getattr(original, "diag", None), "constraint_name", None) == "uq_devices_fcm_token"
    return (isinstance(original, sqlite3.IntegrityError)
            and getattr(original, "sqlite_errorcode", None) == sqlite3.SQLITE_CONSTRAINT_UNIQUE
            and str(original) == "UNIQUE constraint failed: devices.fcm_token")


def _rollback(db):
    try:
        db.rollback()
    except Exception:
        logger.warning("Device registration rollback failed")


def _device_response(device):
    return {"id": device.id, "user_id": device.user_id, "platform": device.platform,
            "registered_at": device.registered_at.isoformat()}


def _check_owner(device, owner_id):
    if device.user_id != owner_id:
        raise HTTPException(409, "This device token is already registered to another user")


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
    owner_id = current_user.id
    try:
        device = db.scalar(
            select(Device).where(Device.fcm_token == device_data.fcm_token).with_for_update()
        )
        if device is not None:
            _check_owner(device, owner_id)
            device.platform = device_data.platform
            device.registered_at = datetime.now(timezone.utc)
        else:
            device = Device(user_id=owner_id, fcm_token=device_data.fcm_token,
                            platform=device_data.platform, registered_at=datetime.now(timezone.utc))
            db.add(device)
        try:
            db.commit()
        except IntegrityError as error:
            _rollback(db)
            if not _is_token_conflict(error):
                raise
            # The unique index, not the initial lookup, decides concurrent inserts.
            device = db.scalar(select(Device).where(
                Device.fcm_token == device_data.fcm_token).with_for_update())
            if device is None:
                raise HTTPException(409, "Device registration changed; retry the request")
            _check_owner(device, owner_id)
            return _device_response(device)
        db.refresh(device)
        return _device_response(device)
    except HTTPException:
        raise
    except Exception:
        _rollback(db)
        # Neither SQLAlchemy parameters nor PostgreSQL DETAIL may reach logs.
        logger.warning("Device registration storage operation failed")
        raise HTTPException(503, "Device registration is unavailable; please retry") from None


class DeviceRemove(BaseModel):
    model_config = ConfigDict(extra="forbid")
    fcm_token: str = Field(min_length=1, max_length=500)

    @field_validator("fcm_token")
    @classmethod
    def validate_fcm_token(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("FCM token cannot be empty")
        return value


@router.delete("")
def unregister_device(body: DeviceRemove, current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        device = db.scalar(select(Device).where(
            Device.fcm_token == body.fcm_token, Device.user_id == current_user.id).with_for_update())
        if device is not None:
            remove_registration(db, device)
            db.commit()
        return {"success": True}
    except Exception:
        _rollback(db)
        logger.warning("Device unregistration storage operation failed")
        raise HTTPException(503, "Device unregistration is unavailable; please retry") from None
