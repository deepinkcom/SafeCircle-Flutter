from datetime import datetime

from fastapi import APIRouter, Depends
from geoalchemy2 import Geography
from geoalchemy2.elements import WKTElement
from geoalchemy2.functions import ST_DWithin, ST_Distance
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from .database import SessionLocal
from .models import Alert


router = APIRouter(prefix="/alerts", tags=["alerts"])


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class PanicAlertCreate(BaseModel):
    latitude: float
    longitude: float
    location_label: str | None = None


@router.post("/panic")
def create_panic_alert(
    alert_data: PanicAlertCreate,
    user_id: int = 1,
    db: Session = Depends(get_db),
):
    point = WKTElement(
        f"POINT({alert_data.longitude} {alert_data.latitude})",
        srid=4326,
    )

    alert = Alert(
        user_id=user_id,
        kind="panic",
        status="active",
        location=point,
        location_label=alert_data.location_label,
        created_at=datetime.utcnow(),
    )

    db.add(alert)
    db.commit()
    db.refresh(alert)

    return {
        "id": alert.id,
        "user_id": alert.user_id,
        "kind": alert.kind,
        "status": alert.status,
        "latitude": alert_data.latitude,
        "longitude": alert_data.longitude,
        "location_label": alert.location_label,
        "created_at": alert.created_at.isoformat(),
    }


@router.post("/{alert_id}/resolve")
def resolve_alert(
    alert_id: int,
    user_id: int = 1,
    db: Session = Depends(get_db),
):
    statement = select(Alert).where(
        Alert.id == alert_id,
        Alert.user_id == user_id,
    )
    alert = db.scalar(statement)

    if alert is None:
        return {"error": "Alert not found"}

    alert.status = "resolved"
    alert.resolved_at = datetime.utcnow()

    db.commit()
    db.refresh(alert)

    return {
        "id": alert.id,
        "user_id": alert.user_id,
        "kind": alert.kind,
        "status": alert.status,
        "location_label": alert.location_label,
        "created_at": alert.created_at.isoformat(),
        "resolved_at": alert.resolved_at.isoformat(),
    }


@router.get("/history")
def get_alert_history(
    user_id: int = 1,
    db: Session = Depends(get_db),
):
    statement = (
        select(Alert)
        .where(Alert.user_id == user_id)
        .order_by(Alert.created_at.desc())
    )

    alerts = db.scalars(statement).all()

    return [
        {
            "id": alert.id,
            "kind": alert.kind,
            "status": alert.status,
            "location_label": alert.location_label,
            "created_at": alert.created_at.isoformat(),
            "resolved_at": (
                alert.resolved_at.isoformat()
                if alert.resolved_at
                else None
            ),
        }
        for alert in alerts
    ]


@router.get("/nearby")
def get_nearby_alerts(
    lat: float,
    lng: float,
    radius_km: float = 1,
    db: Session = Depends(get_db),
):
    search_point = WKTElement(
        f"POINT({lng} {lat})",
        srid=4326,
    )

    radius_meters = radius_km * 1000

    distance = ST_Distance(
        Alert.location,
        search_point,
    )

    statement = (
        select(Alert, distance.label("distance_meters"))
        .where(
            Alert.location.is_not(None),
            ST_DWithin(
                Alert.location,
                search_point,
                radius_meters,
            ),
        )
        .order_by(distance)
    )

    results = db.execute(statement).all()

    return [
        {
            "id": alert.id,
            "kind": alert.kind,
            "status": alert.status,
            "location_label": alert.location_label,
            "distance_km": round(distance_meters / 1000, 3),
            "created_at": alert.created_at.isoformat(),
        }
        for alert, distance_meters in results
    ]
