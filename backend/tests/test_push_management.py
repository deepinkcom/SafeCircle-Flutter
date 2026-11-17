from datetime import datetime, timedelta, timezone

import pytest
from firebase_admin import messaging
from sqlalchemy import event, select
from sqlalchemy.orm import Session

from app.models import Alert, Device, DeviceInstallation, EmergencyContactLink, Notification, PushDelivery
from app.push_worker import _claim, _deliver_claim, deliver_one
from test_contact_links import client, database, headers, invite, respond
from test_notifications import inbox, get_page, events


def device(database, user, token):
    with Session(database) as db:
        db.add(Device(user_id=user, fcm_token=token, platform="android"))
        db.commit()


def test_bulk_read_and_deletion_are_filtered_owned_and_retain_event_keys(inbox, database):
    link=invite(inbox).json()
    notice=get_page(inbox,2)["items"][0]
    assert inbox.post('/notifications/mark-all-read?category=emergency',headers=headers(2)).json()=={'affected':0}
    assert inbox.post('/notifications/mark-all-read?category=connection',headers=headers(2)).json()=={'affected':1}
    assert inbox.delete(f"/notifications/{notice['id']}",headers=headers(1)).status_code==404
    assert inbox.delete('/notifications?scope=read',headers=headers(1)).json()=={'affected':0}
    assert inbox.delete('/notifications?scope=read',headers=headers(2)).json()=={'affected':1}
    assert get_page(inbox,2)['items']==[]
    assert inbox.get(f"/notifications/{notice['id']}",headers=headers(2)).status_code==404
    assert inbox.patch(f"/notifications/{notice['id']}",headers=headers(2),json={'read':False}).status_code==404
    with Session(database) as db:
        assert db.get(Notification,notice['id']).deleted_at is not None
        assert db.get(EmergencyContactLink,link['id']).status=='pending'
    assert respond(inbox,link['id']).status_code==200
    assert get_page(inbox,1)['items'][0]['event_type']=='connection.accepted'
    assert get_page(inbox,2)['items']==[]


@pytest.mark.parametrize('method,path', [('POST','/notifications/mark-all-read'),('DELETE','/notifications?scope=all'),('DELETE','/notifications/1'),('GET','/notifications/1')])
def test_management_auth(inbox,method,path):
    assert inbox.request(method,path).status_code==401


def test_clear_all_does_not_clear_relationships_or_other_accounts(inbox,database):
    link=invite(inbox).json();respond(inbox,link['id'])
    assert inbox.delete('/notifications?scope=all',headers=headers(1)).json()=={'affected':1}
    assert get_page(inbox,2)['total']==1
    with Session(database) as db:
        assert db.get(EmergencyContactLink,link['id']).status=='accepted'


def test_connection_commit_enqueues_all_recipient_devices_only(inbox,database):
    device(database,2,'synthetic-device-two-a');device(database,2,'synthetic-device-two-b');device(database,1,'synthetic-device-one')
    invite(inbox)
    with Session(database) as db:
        jobs=db.scalars(select(PushDelivery)).all();assert len(jobs)==2
        assert all(db.get(Device,j.device_id).user_id==2 for j in jobs)
        assert len(db.scalars(select(Notification)).all())==1


def test_worker_sends_only_owned_jobs_once_and_inbox_is_unchanged(inbox,database):
    device(database,2,'synthetic-device-two');invite(inbox);calls=[]
    with Session(database) as db:
        assert deliver_one(db,lambda token,row,uid:calls.append((token,row.id,uid)))
        assert not deliver_one(db,lambda *args:calls.append(args))
        assert db.scalar(select(PushDelivery)).status=='sent'
    assert calls==[('synthetic-device-two',get_page(inbox,2)['items'][0]['id'],'synthetic-uid-2')]
    assert len(events(database))==1


def test_deleted_notification_cancels_queued_push(inbox,database):
    device(database,2,'synthetic-device-two');invite(inbox)
    inbox.delete('/notifications?scope=all',headers=headers(2))
    with Session(database) as db:
        assert deliver_one(db,lambda *args:pytest.fail('Deleted notification sent'))
        assert db.scalar(select(PushDelivery)).status=='cancelled'


def test_retry_failure_does_not_corrupt_relationship_or_notification(inbox,database):
    device(database,2,'synthetic-device-two');link=invite(inbox).json()
    def fail(*args):raise RuntimeError('synthetic sensitive provider detail')
    now=datetime.now(timezone.utc)
    with Session(database) as db:
        assert deliver_one(db,fail,now=now)
        job=db.scalar(select(PushDelivery));assert job.status=='pending' and job.attempts==1
        assert not deliver_one(db,fail,now=now)
        assert db.get(EmergencyContactLink,link['id']).status=='pending'
        assert db.get(Notification,job.notification_id).deleted_at is None


def test_unregistered_token_removes_device_without_deleting_inbox(inbox,database):
    device(database,2,'synthetic-device-two');invite(inbox)
    def invalid(*args):raise messaging.UnregisteredError('synthetic invalid token')
    with Session(database) as db:
        assert deliver_one(db,invalid)
        assert db.scalars(select(Device)).all()==[]
        assert len(db.scalars(select(Notification)).all())==1


def test_emergency_delivery_worker_sends_owned_jobs(inbox, database):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    device(database, 2, 'synthetic-emergency-device')
    calls = []

    with Session(database) as db:
        alert = Alert(
            user_id=1,
            kind="panic",
            status="active",
            notification_events_status="complete",
        )
        db.add(alert)
        db.flush()
        notice = Notification(
            recipient_user_id=2,
            category='emergency',
            event_type='emergency.panic',
            source_id=alert.id,
            title='Emergency alert',
            message='A contact needs help.',
        )
        db.add(notice)
        db.flush()

        notice_id = notice.id
        device_id = db.scalar(select(Device.id))

        job = PushDelivery(
            notification_id=notice.id,
            device_id=device_id,
        )
        db.add(job)
        db.commit()

        assert deliver_one(
            db,
            lambda token, row, uid: calls.append(
                (token, row.id, uid)
            ),
        )

        assert job.status == 'sent'

    assert calls == [
        ('synthetic-emergency-device', notice_id, 'synthetic-uid-2')
    ]


def test_emergency_delivery_locks_authorization_before_device(inbox, database):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    device(database, 2, "synthetic-lock-order-device")
    statements = []

    def capture(_connection, _cursor, statement, _parameters, _context, _many):
        if statement.lstrip().lower().startswith("select"):
            statements.append(" ".join(statement.lower().split()))

    event.listen(database, "before_cursor_execute", capture)
    try:
        now = datetime.now(timezone.utc)
        with Session(database) as db:
            alert = Alert(
                user_id=1,
                kind="panic",
                status="active",
                notification_events_status="complete",
            )
            db.add(alert)
            db.flush()
            notice = Notification(
                recipient_user_id=2,
                category="emergency",
                event_type="emergency.panic",
                source_id=alert.id,
                title="Emergency alert",
                message="Safe synthetic notification.",
            )
            db.add(notice)
            db.flush()
            db.add(PushDelivery(
                notification_id=notice.id,
                device_id=db.scalar(select(Device.id).where(Device.user_id == 2)),
                next_attempt_at=now,
            ))
            db.flush()
            lease = _claim(db, now)
            assert lease is not None and lease is not True
            statements.clear()

        with Session(database) as db:
            assert _deliver_claim(db, lease, lambda *_args: None, now)
    finally:
        event.remove(database, "before_cursor_execute", capture)

    alert_index = next(i for i, sql in enumerate(statements) if "from alerts" in sql)
    link_index = next(
        i for i, sql in enumerate(statements) if "from emergency_contact_links" in sql
    )
    device_index = next(i for i, sql in enumerate(statements) if "from devices" in sql)
    assert alert_index < link_index < device_index


@pytest.mark.parametrize("stale_reason", ["resolved", "revoked"])
def test_emergency_worker_cancels_stale_or_unauthorized_jobs(
    inbox, database, stale_reason
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    device(database, 2, f"synthetic-stale-{stale_reason}")
    with Session(database) as db:
        alert = Alert(
            user_id=1,
            kind="panic",
            status="active",
            notification_events_status="complete",
        )
        db.add(alert)
        db.flush()
        notice = Notification(
            recipient_user_id=2,
            category="emergency",
            event_type="emergency.panic",
            source_id=alert.id,
            title="Emergency alert",
            message="Safe synthetic notification.",
        )
        db.add(notice)
        db.flush()
        job = PushDelivery(
            notification_id=notice.id,
            device_id=db.scalar(select(Device.id).where(Device.user_id == 2)),
        )
        db.add(job)
        db.flush()
        alert_id, job_id = alert.id, job.id
        db.commit()

    if stale_reason == "resolved":
        with Session(database) as db:
            db.get(Alert, alert_id).status = "resolved"
            db.commit()
    else:
        assert inbox.delete(
            f"/contact-links/{link['id']}", headers=headers(1)
        ).status_code == 200

    calls = []
    with Session(database) as db:
        assert deliver_one(
            db,
            lambda *args: calls.append(args),
        )
        assert db.get(PushDelivery, job_id).status == "cancelled"
    assert calls == []


@pytest.mark.parametrize("stale_reason", ["resolved", "revoked"])
def test_emergency_worker_rechecks_policy_after_job_claim(
    inbox, database, stale_reason
):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "accept").status_code == 200
    device(database, 2, f"synthetic-claimed-{stale_reason}")
    now = datetime.now(timezone.utc)
    with Session(database) as db:
        alert = Alert(
            user_id=1,
            kind="panic",
            status="active",
            notification_events_status="complete",
        )
        db.add(alert)
        db.flush()
        notice = Notification(
            recipient_user_id=2,
            category="emergency",
            event_type="emergency.panic",
            source_id=alert.id,
            title="Emergency alert",
            message="Safe synthetic notification.",
        )
        db.add(notice)
        db.flush()
        job = PushDelivery(
            notification_id=notice.id,
            device_id=db.scalar(select(Device.id).where(Device.user_id == 2)),
            next_attempt_at=now,
        )
        db.add(job)
        db.flush()
        alert_id, job_id = alert.id, job.id
        lease = _claim(db, now)
        assert lease is not None and lease is not True

    if stale_reason == "resolved":
        with Session(database) as db:
            db.get(Alert, alert_id).status = "resolved"
            db.commit()
    else:
        assert inbox.delete(
            f"/contact-links/{link['id']}", headers=headers(1)
        ).status_code == 200

    calls = []
    with Session(database) as db:
        assert _deliver_claim(db, lease, lambda *args: calls.append(args), now)
        assert db.get(PushDelivery, job_id).status == "cancelled"
    assert calls == []


def test_push_job_insert_failure_rolls_back_relationship_and_notification(inbox, database):
    from sqlalchemy import event
    device(database, 2, 'synthetic-rollback-device')
    def fail(mapper, connection, target):
        raise RuntimeError('synthetic push job persistence failure')
    event.listen(PushDelivery, 'before_insert', fail)
    try:
        with pytest.raises(RuntimeError, match='synthetic push job'):
            invite(inbox)
    finally:
        event.remove(PushDelivery, 'before_insert', fail)
    with Session(database) as db:
        assert db.scalars(select(EmergencyContactLink)).all() == []
        assert db.scalars(select(Notification)).all() == []
        assert db.scalars(select(PushDelivery)).all() == []


def test_device_removal_is_authenticated_and_owner_scoped(inbox, database):
    from app.devices import router as devices_router
    inbox.app.include_router(devices_router)
    device(database, 2, 'synthetic-remove-device')
    body = {'fcm_token': 'synthetic-remove-device'}
    assert inbox.request('DELETE', '/devices', json=body).status_code == 401
    assert inbox.request('DELETE', '/devices', headers=headers(1), json=body).status_code == 200
    with Session(database) as db:
        assert db.scalar(select(Device)) is not None
    assert inbox.request('DELETE', '/devices', headers=headers(2), json=body).status_code == 200
    with Session(database) as db:
        assert db.scalar(select(Device)) is None
    # Repeating cleanup for the already-removed token is safe and idempotent.
    repeated = inbox.request('DELETE', '/devices', headers=headers(2), json=body)
    assert repeated.status_code == 200
    assert repeated.json() == {'success': True}
    with Session(database) as db:
        assert db.scalar(select(Device)) is None


def test_legacy_cleanup_status_is_auth_only_and_returns_no_registration_details(inbox, database):
    from app.devices import router as devices_router

    inbox.app.include_router(devices_router)
    device(database, 2, 'synthetic-legacy-status-token')
    assert inbox.get('/devices/cleanup-status').status_code == 401
    status = inbox.get('/devices/cleanup-status', headers=headers(2))
    assert status.status_code == 200
    assert status.json() == {'has_registrations': True}
    assert 'synthetic-legacy-status-token' not in status.text


def test_installation_cleanup_is_authenticated_idempotent_and_scoped(inbox, database):
    from app.devices import router as devices_router

    inbox.app.include_router(devices_router)
    install_a, install_b = 'a' * 64, 'b' * 64
    invite(inbox)
    with Session(database) as db:
        db.add_all([
            DeviceInstallation(installation_id=install_a, owner_user_id=2),
            DeviceInstallation(installation_id=install_b, owner_user_id=2),
            Device(user_id=2, fcm_token='synthetic-phone-one', platform='android', installation_id=install_a),
            Device(user_id=2, fcm_token='synthetic-phone-two', platform='android', installation_id=install_b),
        ])
        db.commit()
    with Session(database) as db:
        rows = db.scalars(select(Device).order_by(Device.id)).all()
        # Give each installation a pending delivery for the same inbox item.
        notice = db.scalar(select(Notification).where(Notification.recipient_user_id == 2))
        jobs = [PushDelivery(notification_id=notice.id, device_id=row.id) for row in rows]
        db.add_all(jobs)
        db.commit()
        job_ids = [job.id for job in jobs]

    body = {'installation_id': install_a}
    assert inbox.request('DELETE', '/devices/installation', json=body).status_code == 401
    assert inbox.request('DELETE', '/devices/installation', headers=headers(1), json=body).status_code == 409
    response = inbox.request('DELETE', '/devices/installation', headers=headers(2), json=body)
    assert response.status_code == 200
    assert response.json() == {
        'success': True,
        'revoked_count': 1,
        'installation_registrations_remain': False,
        'unattributed_legacy_registrations_remain': False,
    }
    again = inbox.request('DELETE', '/devices/installation', headers=headers(2), json=body)
    assert again.status_code == 200 and again.json()['revoked_count'] == 0
    with Session(database) as db:
        remaining = db.scalars(select(Device)).all()
        assert len(remaining) == 1 and remaining[0].installation_id == install_b
        by_id = [db.get(PushDelivery, job_id) for job_id in job_ids]
        assert by_id[0].status == 'cancelled' and by_id[0].device_id is None
        assert by_id[1].status == 'pending' and by_id[1].device_id == remaining[0].id
    switched = inbox.post(
        '/devices', headers=headers(1),
        json={'fcm_token': 'synthetic-phone-one', 'platform': 'android', 'installation_id': install_a},
    )
    assert switched.status_code == 200
    calls = []
    with Session(database) as db:
        replacement = db.scalar(select(Device).where(Device.fcm_token == 'synthetic-phone-one'))
        assert replacement.user_id == 1
        assert db.get(PushDelivery, job_ids[0]).status == 'cancelled'
        db.get(PushDelivery, job_ids[1]).status = 'cancelled'
        db.commit()
        assert not deliver_one(db, lambda *args: calls.append(args))
    assert calls == []


def test_installation_cleanup_reconciles_only_presented_legacy_token(inbox, database):
    from app.devices import router as devices_router

    inbox.app.include_router(devices_router)
    install_a, install_b = 'c' * 64, 'd' * 64
    with Session(database) as db:
        db.add_all([
            DeviceInstallation(installation_id=install_a, owner_user_id=2),
            DeviceInstallation(installation_id=install_b, owner_user_id=2),
            Device(user_id=2, fcm_token='synthetic-legacy-current', platform='android'),
            Device(user_id=2, fcm_token='synthetic-legacy-other-phone', platform='android'),
        ])
        db.commit()
    response = inbox.request(
        'DELETE', '/devices/installation', headers=headers(2),
        json={'installation_id': install_a, 'fcm_token': 'synthetic-legacy-current'},
    )
    assert response.status_code == 200
    assert response.json()['revoked_count'] == 1
    assert response.json()['installation_registrations_remain'] is False
    assert response.json()['unattributed_legacy_registrations_remain'] is True
    with Session(database) as db:
        tokens = {row.fcm_token: row.installation_id for row in db.scalars(select(Device)).all()}
        assert tokens == {'synthetic-legacy-other-phone': None}
        assert db.get(DeviceInstallation, install_a).owner_user_id is None
    switched = inbox.post(
        '/devices', headers=headers(1),
        json={'fcm_token': 'synthetic-new-account-token', 'platform': 'android', 'installation_id': install_a},
    )
    assert switched.status_code == 200


def test_installation_revocation_cancels_queued_emergency_push(inbox, database):
    from app.devices import router as devices_router

    inbox.app.include_router(devices_router)
    install = 'f' * 64
    with Session(database) as db:
        db.add(DeviceInstallation(installation_id=install, owner_user_id=2))
        target = Device(
            user_id=2, fcm_token='synthetic-emergency-phone', platform='android',
            installation_id=install,
        )
        db.add(target)
        db.flush()
        notice = Notification(
            recipient_user_id=2, category='emergency',
            event_type='emergency.panic', source_id=812,
            title='SafeCircle emergency alert', message='Test event.',
        )
        db.add(notice)
        db.flush()
        job = PushDelivery(notification_id=notice.id, device_id=target.id)
        db.add(job)
        db.commit()
        job_id, notice_id = job.id, notice.id

    response = inbox.request(
        'DELETE', '/devices/installation', headers=headers(2),
        json={'installation_id': install},
    )
    assert response.status_code == 200
    calls = []
    with Session(database) as db:
        assert not deliver_one(db, lambda *args: calls.append(args))
        assert db.get(PushDelivery, job_id).status == 'cancelled'
        assert db.get(PushDelivery, job_id).device_id is None
        assert db.get(Notification, notice_id).deleted_at is None
    assert calls == []


def test_token_rotation_keeps_and_revokes_all_installation_tokens(inbox, database):
    from app.devices import router as devices_router

    inbox.app.include_router(devices_router)
    install = '9' * 64
    for token in ('synthetic-rotated-token-old', 'synthetic-rotated-token-current'):
        response = inbox.post(
            '/devices', headers=headers(2),
            json={'fcm_token': token, 'platform': 'android', 'installation_id': install},
        )
        assert response.status_code == 200

    with Session(database) as db:
        rows = db.scalars(select(Device).where(Device.installation_id == install)).all()
        assert {row.fcm_token for row in rows} == {
            'synthetic-rotated-token-old', 'synthetic-rotated-token-current'
        }

    cleanup = inbox.request(
        'DELETE', '/devices/installation', headers=headers(2),
        json={'installation_id': install},
    )
    assert cleanup.status_code == 200
    assert cleanup.json()['revoked_count'] == 2
    with Session(database) as db:
        assert db.scalars(select(Device).where(Device.installation_id == install)).all() == []


def test_installation_cleanup_rejects_foreign_token_without_revealing_it(inbox, database):
    from app.devices import router as devices_router

    inbox.app.include_router(devices_router)
    install = 'e' * 64
    device(database, 1, 'synthetic-foreign-token')
    response = inbox.request(
        'DELETE', '/devices/installation', headers=headers(2),
        json={'installation_id': install, 'fcm_token': 'synthetic-foreign-token'},
    )
    assert response.status_code == 409
    assert 'synthetic-foreign-token' not in response.text
    with Session(database) as db:
        assert db.scalar(select(Device).where(Device.fcm_token == 'synthetic-foreign-token')) is not None


def test_reused_fcm_token_cannot_deliver_old_account_inbox_to_new_account(inbox, database):
    from app.devices import router as devices_router

    inbox.app.include_router(devices_router)
    token = 'synthetic-account-switch-token'
    device(database, 2, token)
    with Session(database) as db:
        old_device = db.scalar(select(Device).where(Device.fcm_token == token))
        notice = Notification(
            recipient_user_id=2,
            category='connection',
            event_type='connection.invited',
            source_id=71,
            title='Synthetic invitation',
            message='A synthetic account received an invitation.',
        )
        db.add(notice)
        db.flush()
        job = PushDelivery(notification_id=notice.id, device_id=old_device.id)
        db.add(job)
        db.commit()
        notice_id, job_id = notice.id, job.id

    removed = inbox.request(
        'DELETE', '/devices', headers=headers(2), json={'fcm_token': token}
    )
    assert removed.status_code == 200
    registered = inbox.post(
        '/devices', headers=headers(1),
        json={'fcm_token': token, 'platform': 'android'},
    )
    assert registered.status_code == 200

    with Session(database) as db:
        replacement = db.scalar(select(Device).where(Device.fcm_token == token))
        old_job = db.get(PushDelivery, job_id)
        old_notice = db.get(Notification, notice_id)
        assert replacement.user_id == 1
        assert old_job.status == 'cancelled'
        assert old_job.device_id is None
        assert old_notice.recipient_user_id == 2
