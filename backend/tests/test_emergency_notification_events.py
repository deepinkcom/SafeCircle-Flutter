
"""Tests for emergency alert notification recipient selection and delivery jobs."""

from datetime import datetime, timezone

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import (
    Alert,
    Device,
    Notification,
    PushDelivery,
)
from app.notification_events import record_emergency_alert_events

from test_contact_links import client, database, headers, invite, respond


@pytest.fixture
def inbox(client):
    from app.notifications import router

    client.app.include_router(router)
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
