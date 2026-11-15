from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, StrictBool, field_serializer
from sqlalchemy import func, select, update, or_
from sqlalchemy.orm import Session
from geoalchemy2 import Geometry
from geoalchemy2.functions import ST_X, ST_Y

from .auth import get_current_user, get_db
from .models import Alert, EmergencyContactLink, Notification, User


router = APIRouter(prefix="/notifications", tags=["notifications"])
Category = Literal["emergency", "connection"]


class NotificationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    recipient_user_id: int
    category: Category
    event_type: str
    source_id: int
    created_at: datetime
    read_at: datetime | None
    title: str
    message: str

    @field_serializer("created_at", "read_at")
    def utc_timestamp(self, value: datetime | None):
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat()


class NotificationPage(BaseModel):
    items: list[NotificationResponse]
    total: int
    limit: int
    offset: int
    has_more: bool


class UnreadCount(BaseModel):
    unread_count: int


class NotificationUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    read: StrictBool


def _filters(user_id: int, category: Category | None, unread_only: bool):
    conditions = [Notification.recipient_user_id == user_id, Notification.deleted_at.is_(None)]
    if category is not None:
        conditions.append(Notification.category == category)
    if unread_only:
        conditions.append(Notification.read_at.is_(None))
    return conditions


@router.get("", response_model=NotificationPage)
def list_notifications(
    response: Response,
    category: Category | None = None,
    unread_only: bool = False,
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0, le=1_000_000),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    response.headers["Cache-Control"] = "no-store"
    conditions = _filters(current_user.id, category, unread_only)
    total = db.scalar(select(func.count()).select_from(Notification).where(*conditions))
    items = db.scalars(select(Notification).where(*conditions).order_by(
        Notification.created_at.desc(), Notification.id.desc(),
    ).limit(limit).offset(offset)).all()
    return dict(items=items, total=total, limit=limit, offset=offset,
                has_more=offset + len(items) < total)


@router.get("/unread-count", response_model=UnreadCount)
def unread_count(
    response: Response,
    category: Category | None = None,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    response.headers["Cache-Control"] = "no-store"
    count = db.scalar(select(func.count()).select_from(Notification).where(
        *_filters(current_user.id, category, True),
    ))
    return {"unread_count": count}


@router.patch("/{notification_id}", response_model=NotificationResponse)
def update_notification(
    notification_id: int,
    update: NotificationUpdate,
    response: Response,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    response.headers["Cache-Control"] = "no-store"
    notification = db.scalar(select(Notification).where(
        Notification.id == notification_id,
        Notification.recipient_user_id == current_user.id,
        Notification.deleted_at.is_(None),
    ).with_for_update())
    if notification is None:
        raise HTTPException(status_code=404, detail="Notification not found")
    if not update.read:
        notification.read_at = None
    elif notification.read_at is None:
        notification.read_at = datetime.now(timezone.utc)
    try:
        db.commit()
    except Exception:
        db.rollback()
        raise
    db.refresh(notification)
    return notification


class ManagedCount(BaseModel):
    affected: int


@router.post("/mark-all-read", response_model=ManagedCount)
def mark_all_read(category: Category | None = None, current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        result = db.execute(update(Notification).where(*_filters(current_user.id, category, True))
                            .values(read_at=datetime.now(timezone.utc)))
        db.commit()
        return {"affected": result.rowcount}
    except Exception:
        db.rollback()
        raise


@router.delete("", response_model=ManagedCount)
def clear_notifications(scope: Literal["read", "all"], category: Category | None = None,
                        current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    conditions = _filters(current_user.id, category, False)
    if scope == "read":
        conditions.append(Notification.read_at.is_not(None))
    try:
        result = db.execute(update(Notification).where(*conditions).values(deleted_at=datetime.now(timezone.utc)))
        db.commit()
        return {"affected": result.rowcount}
    except Exception:
        db.rollback()
        raise


@router.get("/{notification_id}", response_model=NotificationResponse)
def get_notification(notification_id: int, response: Response, current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    response.headers["Cache-Control"] = "no-store"
    row = db.scalar(select(Notification).where(Notification.id == notification_id, *_filters(current_user.id, None, False)))
    if row is None:
        raise HTTPException(status_code=404, detail="Notification not found")
    return row


@router.get("/{notification_id}/alert")
def get_emergency_notification_alert(
    notification_id: int,
    response: Response,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return the exact active panic alert owned by this inbox notification."""
    response.headers["Cache-Control"] = "no-store"
    notice = db.scalar(select(Notification).where(
        Notification.id == notification_id,
        Notification.recipient_user_id == current_user.id,
        Notification.category == "emergency",
        Notification.event_type == "emergency.panic",
        Notification.deleted_at.is_(None),
    ))
    if notice is None:
        raise HTTPException(status_code=404, detail="Emergency alert not found")

    alert = db.scalar(select(Alert).where(
        Alert.id == notice.source_id,
        Alert.kind == "panic",
    ))
    if alert is None:
        raise HTTPException(status_code=404, detail="Emergency alert not found")
    if alert.status != "active":
        raise HTTPException(status_code=410, detail="Emergency alert is no longer active")

    accepted_link = db.scalar(select(EmergencyContactLink.id).where(
        EmergencyContactLink.status == "accepted",
        or_(
            (EmergencyContactLink.inviter_user_id == alert.user_id)
            & (EmergencyContactLink.invitee_user_id == current_user.id),
            (EmergencyContactLink.invitee_user_id == alert.user_id)
            & (EmergencyContactLink.inviter_user_id == current_user.id),
        ),
    ))
    if accepted_link is None:
        raise HTTPException(status_code=404, detail="Emergency alert not found")

    point = db.execute(select(
        ST_Y(Alert.location.cast(Geometry)).label("latitude"),
        ST_X(Alert.location.cast(Geometry)).label("longitude"),
    ).where(Alert.id == alert.id)).one()
    return {
        "id": alert.id,
        "owner_user_id": alert.user_id,
        "kind": alert.kind,
        "status": alert.status,
        "location_label": alert.location_label,
        "latitude": point.latitude,
        "longitude": point.longitude,
        "created_at": alert.created_at.isoformat(),
    }


@router.delete("/{notification_id}", response_model=ManagedCount)
def delete_notification(notification_id: int, current_user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    row = db.scalar(select(Notification).where(Notification.id == notification_id, *_filters(current_user.id, None, False)).with_for_update())
    if row is None:
        raise HTTPException(status_code=404, detail="Notification not found")
    row.deleted_at = datetime.now(timezone.utc)
    try:
        db.commit()
        return {"affected": 1}
    except Exception:
        db.rollback()
        raise
