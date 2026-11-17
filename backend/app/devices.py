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
from .models import Device, DeviceInstallation, User
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


def _validate_installation_id(value: str | None) -> str | None:
    if value is not None and (
        len(value) != 64
        or any(char not in "0123456789abcdef" for char in value)
    ):
        raise ValueError("Installation ID must be 64 lowercase hexadecimal characters")
    return value


def _claim_installation(db, installation_id: str, owner_id: int):
    installation = db.scalar(
        select(DeviceInstallation)
        .where(DeviceInstallation.installation_id == installation_id)
        .with_for_update()
    )
    if installation is None:
        try:
            with db.begin_nested():
                installation = DeviceInstallation(
                    installation_id=installation_id, owner_user_id=owner_id
                )
                db.add(installation)
                db.flush()
        except IntegrityError:
            installation = db.scalar(
                select(DeviceInstallation)
                .where(DeviceInstallation.installation_id == installation_id)
                .with_for_update()
            )
    if installation is None or installation.owner_user_id not in (None, owner_id):
        raise HTTPException(409, "This app installation is registered to another account")
    installation.owner_user_id = owner_id
    installation.updated_at = datetime.now(timezone.utc)
    return installation


def _check_owner(device, owner_id):
    if device.user_id != owner_id:
        raise HTTPException(409, "This device token is already registered to another user")


class DeviceCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    fcm_token: str = Field(min_length=1, max_length=500)
    platform: str = Field(min_length=1, max_length=50)
    installation_id: str | None = Field(default=None, min_length=64, max_length=64)

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

    @field_validator("installation_id")
    @classmethod
    def validate_installation(cls, value: str | None) -> str | None:
        return _validate_installation_id(value)


@router.post("")
def register_device(
    device_data: DeviceCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    owner_id = current_user.id
    try:
        if device_data.installation_id is not None:
            _claim_installation(db, device_data.installation_id, owner_id)
        device = db.scalar(
            select(Device).where(Device.fcm_token == device_data.fcm_token).with_for_update()
        )
        if device is not None:
            _check_owner(device, owner_id)
            if (
                device_data.installation_id is not None
                and device.installation_id not in (None, device_data.installation_id)
            ):
                raise HTTPException(409, "This token belongs to another app installation")
            device.platform = device_data.platform
            if device_data.installation_id is not None:
                # A legacy token is attributed only after this authenticated
                # installation presents that exact current FCM token.
                device.installation_id = device_data.installation_id
            device.registered_at = datetime.now(timezone.utc)
        else:
            device = Device(user_id=owner_id, fcm_token=device_data.fcm_token,
                            platform=device_data.platform,
                            installation_id=device_data.installation_id,
                            registered_at=datetime.now(timezone.utc))
            db.add(device)
        try:
            db.commit()
        except IntegrityError as error:
            _rollback(db)
            if not _is_token_conflict(error):
                raise
            # Rollback also undoes this request's installation claim. Reclaim
            # it before locking the token, preserving ownership and lock order.
            if device_data.installation_id is not None:
                _claim_installation(db, device_data.installation_id, owner_id)
            # The unique index, not the initial lookup, decides concurrent inserts.
            device = db.scalar(select(Device).where(
                Device.fcm_token == device_data.fcm_token).with_for_update())
            if device is None:
                raise HTTPException(409, "Device registration changed; retry the request")
            _check_owner(device, owner_id)
            if (
                device_data.installation_id is not None
                and device.installation_id not in (None, device_data.installation_id)
            ):
                raise HTTPException(409, "This token belongs to another app installation")
            if device_data.installation_id is not None:
                device.installation_id = device_data.installation_id
                db.commit()
            return _device_response(device)
        db.refresh(device)
        return _device_response(device)
    except HTTPException:
        _rollback(db)
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


class DeviceInstallationRemove(BaseModel):
    model_config = ConfigDict(extra="forbid")
    installation_id: str = Field(min_length=64, max_length=64)
    fcm_token: str | None = Field(default=None, min_length=1, max_length=500)

    @field_validator("installation_id")
    @classmethod
    def validate_installation(cls, value: str) -> str:
        return _validate_installation_id(value) or ""

    @field_validator("fcm_token")
    @classmethod
    def validate_token(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        if not value:
            raise ValueError("FCM token cannot be empty")
        return value


@router.get("/cleanup-status", deprecated=True)
def device_cleanup_status(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Legacy boolean check retained for older APKs; new clients use install scope."""
    has_registrations = db.scalar(
        select(Device.id).where(Device.user_id == current_user.id).limit(1)
    ) is not None
    return {"has_registrations": has_registrations}


@router.delete("/installation")
def unregister_installation(
    body: DeviceInstallationRemove,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Revoke only this authenticated account's registrations for this install."""
    try:
        # Match registration's lock order (installation, then device token) to
        # avoid deadlocks when token refresh and logout overlap.
        installation = _claim_installation(
            db, body.installation_id, current_user.id
        )

        legacy_token_device = None
        if body.fcm_token is not None:
            legacy_token_device = db.scalar(
                select(Device)
                .where(Device.fcm_token == body.fcm_token)
                .with_for_update()
            )
            if legacy_token_device is not None:
                _check_owner(legacy_token_device, current_user.id)
                if legacy_token_device.installation_id not in (
                    None, body.installation_id
                ):
                    raise HTTPException(
                        409, "This token belongs to another app installation"
                    )

        if legacy_token_device is not None:
            legacy_token_device.installation_id = body.installation_id
        if installation is not None and installation.owner_user_id is None:
            installation.owner_user_id = current_user.id

        devices = db.scalars(
            select(Device)
            .where(
                Device.user_id == current_user.id,
                Device.installation_id == body.installation_id,
            )
            .order_by(Device.id)
            .with_for_update()
        ).all()
        for device in devices:
            remove_registration(db, device)

        legacy_registration = db.scalar(
            select(Device.id)
            .where(
                Device.user_id == current_user.id,
                Device.installation_id.is_(None),
            )
            .limit(1)
        ) is not None
        installation_registration = db.scalar(
            select(Device.id)
            .where(
                Device.user_id == current_user.id,
                Device.installation_id == body.installation_id,
            )
            .limit(1)
        ) is not None

        if installation is not None:
            # Once every registration attributed to this installation is
            # revoked, release its account claim. Unattributed rows remain
            # owned by their original account and are never reassigned here.
            installation.owner_user_id = (
                current_user.id if installation_registration else None
            )
            installation.updated_at = datetime.now(timezone.utc)
        db.commit()
        return {
            "success": True,
            "revoked_count": len(devices),
            "installation_registrations_remain": installation_registration,
            # This account-scoped flag is informational. It must never make a
            # different installation's logout fail when this install supplied
            # its own current token for exact legacy reconciliation.
            "unattributed_legacy_registrations_remain": legacy_registration,
        }
    except HTTPException:
        _rollback(db)
        raise
    except Exception:
        _rollback(db)
        logger.warning("Installation device cleanup failed")
        raise HTTPException(503, "Installation device cleanup is unavailable; please retry") from None


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
