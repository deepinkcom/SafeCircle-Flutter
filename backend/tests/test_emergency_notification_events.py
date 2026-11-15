
"""Tests for emergency alert notification recipient selection and delivery jobs."""

from datetime import datetime, timezone

import pytest
from sqlalchemy import select
from sqlalchemy import event as sqlalchemy_event, literal
from sqlalchemy.orm import Session

from app.models import (
    Alert,
    AlertAcknowledgement,
    Device,
    Notification,
    PushDelivery,
)
from app.notification_events import record_emergency_alert_events
from app.notification_events import recover_one_pending_emergency_event
from app.alerts import router as alerts_router
from app.models import EmergencyContactLink
from app.push_worker import deliver_one

from test_contact_links import client, database, headers, invite, respond


@pytest.fixture
def inbox(client, monkeypatch, database):
    from app.notifications import router

    AlertAcknowledgement.__table__.create(database, checkfirst=True)
    client.app.include_router(router)
    client.app.include_router(alerts_router)
    monkeypatch.setattr("app.alerts.WKTElement", lambda *_args, **_kwargs: None)
    monkeypatch.setattr("app.notifications.ST_Y", lambda _point: literal(-33.9))
    monkeypatch.setattr("app.notifications.ST_X", lambda _point: literal(18.4))
    return client


def create_alert(user_id=1, alert_id=900):
    return Alert(
        id=alert_id,
        user_id=user_id,
        kind="panic",
        status="active",
        created_at=datetime.now(timezone.utc),
    )


def get_emergency_events(database, alert_id):
    with Session(database) as db:
        return db.scalars(
            select(Notification).where(
                Notification.category == "emergency",
                Notification.event_type == "emergency.panic",
                Notification.source_id == alert_id,
            )
        ).all()


def panic(inbox, user=1):
    return inbox.post(
        "/alerts/panic",
        headers=headers(user),
        json={"latitude": -33.9, "longitude": 18.4, "location_label": "Test area"},
    )


def test_panic_route_persists_alert_notification_and_only_recipient_device_job(
    inbox, database
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    with Session(database) as db:
        db.add_all([
            Device(user_id=1, fcm_token="synthetic-owner", platform="android"),
            Device(user_id=2, fcm_token="synthetic-recipient", platform="android"),
        ])
        db.commit()

    response = panic(inbox)
    assert response.status_code == 200
    body = response.json()
    assert body["notification_events_status"] == "complete"

    with Session(database) as db:
        alert = db.get(Alert, body["id"])
        notices = db.scalars(select(Notification).where(
            Notification.category == "emergency",
            Notification.source_id == alert.id,
        )).all()
        jobs = db.scalars(select(PushDelivery).where(
            PushDelivery.notification_id.in_([notice.id for notice in notices]),
        )).all()
        assert alert.user_id == 1 and alert.status == "active"
        assert alert.notification_events_status == "complete"
        assert len(notices) == 1
        assert notices[0].event_type == "emergency.panic"
        assert notices[0].recipient_user_id == 2
        assert notices[0].source_id == alert.id
        assert len(jobs) == 1
        assert db.get(Device, jobs[0].device_id).user_id == 2


@pytest.mark.parametrize("failed_model", [Notification, PushDelivery])
def test_panic_event_failure_stays_pending_and_existing_worker_recovers_once(
    inbox, database, monkeypatch, failed_model
):
    logged = []
    monkeypatch.setattr(
        "app.alerts.logger.error",
        lambda message, **extra: logged.append((message, extra)),
    )
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    with Session(database) as db:
        db.add(Device(user_id=2, fcm_token="synthetic-recovery", platform="android"))
        db.commit()

    def fail_push_insert(_mapper, _connection, _target):
        raise RuntimeError("synthetic persistence failure")

    sqlalchemy_event.listen(failed_model, "before_insert", fail_push_insert)
    try:
        response = panic(inbox)
    finally:
        sqlalchemy_event.remove(failed_model, "before_insert", fail_push_insert)

    assert response.status_code == 200
    alert_id = response.json()["id"]
    assert response.json()["notification_events_status"] == "pending"
    assert any(
        message == "panic_notification_event_creation_failed"
        and extra["extra"].get("alert_id") == alert_id
        for message, extra in logged
    )
    with Session(database) as db:
        alert = db.get(Alert, alert_id)
        assert alert.notification_events_status == "pending"
        assert get_emergency_events(database, alert_id) == []
        assert db.scalars(select(PushDelivery)).all() == []

    with Session(database) as db:
        sent = []
        assert deliver_one(db, lambda *args: sent.append(args)) is True
        assert sent == []
    with Session(database) as db:
        alert = db.get(Alert, alert_id)
        assert alert.notification_events_status == "complete"
        assert len(get_emergency_events(database, alert_id)) == 1
        assert len(db.scalars(select(PushDelivery)).all()) == 1
        assert recover_one_pending_emergency_event(db) is False
        assert len(get_emergency_events(database, alert_id)) == 1


def test_notification_alert_route_is_recipient_scoped_and_exact(inbox, database):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    alert_response = panic(inbox)
    notification = get_emergency_events(database, alert_response.json()["id"])[0]

    assert inbox.get(f"/notifications/{notification.id}/alert").status_code == 401
    assert inbox.get(
        f"/notifications/{notification.id}/alert", headers=headers(3)
    ).status_code == 404
    assert inbox.get(
        f"/notifications/{notification.id + 1000}/alert", headers=headers(2)
    ).status_code == 404

    response = inbox.get(
        f"/notifications/{notification.id}/alert", headers=headers(2)
    )
    assert response.status_code == 200
    assert response.json()["id"] == notification.source_id
    assert response.json()["status"] == "active"
    assert response.json()["latitude"] == -33.9
    assert response.json()["longitude"] == 18.4


def test_notification_alert_route_hides_unrelated_source_and_revoked_link(
    inbox, database
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    original = panic(inbox).json()
    notification = get_emergency_events(database, original["id"])[0]

    # Even a malformed/orphaned source reference is not a grant by itself.
    unrelated_alert = create_alert(user_id=3, alert_id=950)
    unrelated_alert.notification_events_status = "complete"
    with Session(database) as db:
        db.add(unrelated_alert)
        db.flush()
        db.add(Notification(
            recipient_user_id=2,
            category="emergency",
            event_type="emergency.panic",
            source_id=unrelated_alert.id,
            title="Emergency alert",
            message="Safe synthetic notification.",
        ))
        db.commit()
        unrelated_notification = db.scalar(select(Notification).where(
            Notification.recipient_user_id == 2,
            Notification.source_id == unrelated_alert.id,
        ))
    assert inbox.get(
        f"/notifications/{unrelated_notification.id}/alert", headers=headers(2)
    ).status_code == 404

    assert inbox.delete(
        f"/contact-links/{link['id']}", headers=headers(1)
    ).status_code == 200
    assert inbox.get(
        f"/notifications/{notification.id}/alert", headers=headers(2)
    ).status_code == 404


def test_notification_alert_route_returns_gone_after_alert_resolution(
    inbox, database
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    alert_id = panic(inbox).json()["id"]
    notification = get_emergency_events(database, alert_id)[0]
    with Session(database) as db:
        alert = db.get(Alert, alert_id)
        alert.status = "resolved"
        alert.resolved_at = datetime.now(timezone.utc)
        db.commit()

    response = inbox.get(
        f"/notifications/{notification.id}/alert", headers=headers(2)
    )
    assert response.status_code == 410


@pytest.mark.parametrize(
    "relationship,actor,resolve,expected_status",
    [
        ("accepted", 2, False, 200),
        ("unrelated", 3, False, 404),
        ("accepted", 1, False, 404),
        ("revoked", 2, False, 404),
        ("rejected", 2, False, 404),
        ("accepted", 2, True, 404),
    ],
)
def test_acknowledgement_requires_active_accepted_contact(
    inbox, database, relationship, actor, resolve, expected_status
):
    link = invite(inbox).json()
    if relationship == "accepted" or relationship == "revoked":
        assert respond(inbox, link["id"], "accept").status_code == 200
        if relationship == "revoked":
            assert inbox.delete(
                f"/contact-links/{link['id']}", headers=headers(1)
            ).status_code == 200
    elif relationship == "rejected":
        assert respond(inbox, link["id"], "reject").status_code == 200

    alert_response = panic(inbox)
    assert alert_response.status_code == 200
    alert_id = alert_response.json()["id"]
    if resolve:
        assert inbox.post(
            f"/alerts/{alert_id}/resolve", headers=headers(1)
        ).status_code == 200

    response = inbox.post(
        f"/alerts/{alert_id}/acknowledge", headers=headers(actor)
    )
    assert response.status_code == expected_status
    with Session(database) as db:
        acknowledgements = db.scalars(
            select(AlertAcknowledgement).where(
                AlertAcknowledgement.alert_id == alert_id
            )
        ).all()
    assert len(acknowledgements) == (1 if expected_status == 200 else 0)


def test_acknowledgement_rejects_guessed_alert_id(inbox, database):
    response = inbox.post("/alerts/999999/acknowledge", headers=headers(2))
    assert response.status_code == 404
    with Session(database) as db:
        assert db.scalars(select(AlertAcknowledgement)).all() == []


def test_accepted_inviter_receives_emergency_notification(inbox, database):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200

    alert = create_alert(user_id=1)

    with Session(database) as db:
        count = record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        db.commit()

    assert count == 1

    events = get_emergency_events(database, alert.id)
    assert len(events) == 1
    assert events[0].recipient_user_id == 2
    assert events[0].title == "Emergency alert"


def test_accepted_invitee_receives_emergency_notification(inbox, database):
    link = invite(inbox, 1, 2).json()
    assert respond(inbox, link["id"], "accept").status_code == 200

    # User 2 is the invitee and triggers the panic alert.
    alert = create_alert(user_id=2, alert_id=901)

    with Session(database) as db:
        count = record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        db.commit()

    assert count == 1

    events = get_emergency_events(database, alert.id)
    assert len(events) == 1
    assert events[0].recipient_user_id == 1


@pytest.mark.parametrize("action", ["pending", "reject"])
def test_non_accepted_contacts_do_not_receive_emergency_notifications(
    inbox, database, action
):
    link = invite(inbox).json()

    if action == "reject":
        assert respond(inbox, link["id"], "reject").status_code == 200

    alert = create_alert(user_id=1, alert_id=902)

    with Session(database) as db:
        count = record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        db.commit()

    assert count == 0
    assert get_emergency_events(database, alert.id) == []


def test_revoked_contact_does_not_receive_emergency_notification(
    inbox, database
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200

    assert inbox.delete(
        f"/contact-links/{link['id']}",
        headers=headers(1),
    ).status_code == 200

    alert = create_alert(user_id=1, alert_id=903)

    with Session(database) as db:
        count = record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        db.commit()

    assert count == 0
    assert get_emergency_events(database, alert.id) == []


def test_multiple_devices_receive_separate_push_delivery_jobs(
    inbox, database
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200

    with Session(database) as db:
        db.add_all([
            Device(
                user_id=2,
                fcm_token="synthetic-token-one",
                platform="android",
            ),
            Device(
                user_id=2,
                fcm_token="synthetic-token-two",
                platform="android",
            ),
        ])
        db.commit()

    alert = create_alert(user_id=1, alert_id=904)

    with Session(database) as db:
        record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        db.commit()

    with Session(database) as db:
        notification = db.scalar(
            select(Notification).where(
                Notification.category == "emergency",
                Notification.source_id == alert.id,
            )
        )

        deliveries = db.scalars(
            select(PushDelivery).where(
                PushDelivery.notification_id == notification.id
            )
        ).all()

        assert len(deliveries) == 2
        assert all(delivery.status == "pending" for delivery in deliveries)


def test_duplicate_emergency_event_does_not_create_duplicate_notifications(
    inbox, database
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200

    alert = create_alert(user_id=1, alert_id=905)

    with Session(database) as db:
        first_count = record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        db.commit()

    with Session(database) as db:
        second_count = record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        db.commit()

    assert first_count == 1
    assert second_count == 0
    assert len(get_emergency_events(database, alert.id)) == 1


def test_non_panic_alert_is_rejected(database):
    alert = create_alert(user_id=1)
    alert.kind = "nearby"

    with Session(database) as db:
        with pytest.raises(ValueError):
            record_emergency_alert_events(
                db,
                alert=alert,
                created_at=alert.created_at,
            )


def test_emergency_notification_can_be_created_without_registered_devices(
    inbox, database
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200

    alert = create_alert(user_id=1, alert_id=906)

    with Session(database) as db:
        count = record_emergency_alert_events(
            db,
            alert=alert,
            created_at=alert.created_at,
        )
        db.commit()

    assert count == 1
    assert len(get_emergency_events(database, alert.id)) == 1

    with Session(database) as db:
        notification = db.scalar(
            select(Notification).where(
                Notification.category == "emergency",
                Notification.source_id == alert.id,
            )
        )

        deliveries = db.scalars(
            select(PushDelivery).where(
                PushDelivery.notification_id == notification.id
            )
        ).all()

        assert deliveries == []
