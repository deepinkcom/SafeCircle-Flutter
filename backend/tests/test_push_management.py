from datetime import datetime, timedelta, timezone

import pytest
from firebase_admin import messaging
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Device, EmergencyContactLink, Notification, PushDelivery
from app.push_worker import deliver_one
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


def test_no_automatic_emergency_delivery(inbox,database):
    device(database,2,'synthetic-device-two')
    with Session(database) as db:
        notice=Notification(recipient_user_id=2,category='emergency',event_type='emergency.synthetic',source_id=7,title='Test',message='Fixture only')
        db.add(notice);db.flush()
        db.add(PushDelivery(notification_id=notice.id,device_id=db.scalar(select(Device.id))));db.commit()
        assert deliver_one(db,lambda *args:pytest.fail('Emergency policy was broadened'))
        assert db.scalar(select(PushDelivery)).status=='cancelled'


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
