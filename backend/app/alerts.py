from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from geoalchemy2.elements import WKTElement
from geoalchemy2.functions import ST_DWithin, ST_Distance
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db
from .models import Alert, AlertAcknowledgement, User



router = APIRouter(prefix="/alerts", tags=["alerts"])

class PanicAlertCreate(BaseModel):
    latitude: float
    longitude: float
    location_label: str | None = None



@router.post("/panic")
def create_panic_alert(
    alert_data: PanicAlertCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    if not -90 <= alert_data.latitude <= 90:
        raise HTTPException(
            status_code=422,
            detail="Latitude must be between -90 and 90",
        )

    if not -180 <= alert_data.longitude <= 180:
        raise HTTPException(
            status_code=422,
            detail="Longitude must be between -180 and 180",
        )

    point = WKTElement(
        f"POINT({alert_data.longitude} {alert_data.latitude})",
        srid=4326,
    )

    alert = Alert(
        user_id=current_user.id,
        kind="panic",
        status="active",
        location=point,
        location_label=alert_data.location_label,
        created_at=datetime.now(timezone.utc),
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
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    statement = select(Alert).where(
        Alert.id == alert_id,
        Alert.user_id == current_user.id,
    )
    alert = db.scalar(statement)

    if alert is None:
        raise HTTPException(
            status_code=404,
            detail="Alert not found",
        )

    if alert.status != "active":
        raise HTTPException(
            status_code=409,
            detail="Only active alerts can be resolved",
        )

    alert.status = "resolved"
    alert.resolved_at = datetime.now(timezone.utc)

    db.commit()
    db.refresh(alert)

    return {
        "id": alert.id,
        "user_id": alert.user_id,
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



@router.post("/{alert_id}/acknowledge")
def acknowledge_alert(
    alert_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    alert = db.scalar(
        select(Alert).where(
            Alert.id == alert_id,
            Alert.status == "active",
        )
    )

    if alert is None:
        raise HTTPException(
            status_code=404,
            detail="Active alert not found",
        )

    if alert.user_id == current_user.id:
        raise HTTPException(
            status_code=403,
            detail="You cannot acknowledge your own alert",
        )

    acknowledgement = db.scalar(
        select(AlertAcknowledgement).where(
            AlertAcknowledgement.alert_id == alert_id,
            AlertAcknowledgement.responder_user_id == current_user.id,
        )
    )

    if acknowledgement is None:
        acknowledgement = AlertAcknowledgement(
            alert_id=alert_id,
            responder_user_id=current_user.id,
            status="on_my_way",
            created_at=datetime.now(timezone.utc),
        )
        db.add(acknowledgement)

        try:
            db.commit()
            db.refresh(acknowledgement)
        except IntegrityError:
            db.rollback()
            acknowledgement = db.scalar(
                select(AlertAcknowledgement).where(
                    AlertAcknowledgement.alert_id == alert_id,
                    AlertAcknowledgement.responder_user_id == current_user.id,
                )
            )
            if acknowledgement is None:
                raise HTTPException(
                    status_code=409,
                    detail="Could not record the acknowledgement",
                )

    return {
        "id": acknowledgement.id,
        "alert_id": acknowledgement.alert_id,
        "responder_user_id": acknowledgement.responder_user_id,
        "status": acknowledgement.status,
        "created_at": acknowledgement.created_at.isoformat(),
    }



@router.get("/history")
def get_alert_history(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    alert_statement = (
        select(Alert)
        .where(Alert.user_id == current_user.id)
        .order_by(Alert.created_at.desc())
    )

    alerts = db.scalars(alert_statement).all()

    acknowledgement_statement = (
        select(AlertAcknowledgement, Alert)
        .join(Alert, Alert.id == AlertAcknowledgement.alert_id)
        .where(
            AlertAcknowledgement.responder_user_id == current_user.id
        )
        .order_by(AlertAcknowledgement.created_at.desc())
    )

    acknowledgements = db.execute(acknowledgement_statement).all()

    history = [
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

    history.extend(
        {
            "id": acknowledgement.id,
            "alert_id": alert.id,
            "kind": "nearby_received",
            "status": acknowledgement.status,
            "location_label": alert.location_label,
            "created_at": acknowledgement.created_at.isoformat(),
            "resolved_at": None,
        }
        for acknowledgement, alert in acknowledgements
    )

    return sorted(
        history,
        key=lambda item: item["created_at"],
        reverse=True,
    )



@router.get("/nearby")
def get_nearby_alerts(
    lat: float = Query(ge=-90, le=90),
    lng: float = Query(ge=-180, le=180),
    radius_km: float = Query(default=1, gt=0, le=50),
    current_user: User = Depends(get_current_user),
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
            Alert.user_id != current_user.id,
            Alert.location.is_not(None),
            Alert.status == "active",
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
