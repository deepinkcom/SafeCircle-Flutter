"""Installation migration and lifecycle on the dedicated loopback PostGIS DB."""
import pytest
from alembic import command
from sqlalchemy import inspect, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from app.devices import DeviceCreate, DeviceInstallationRemove, register_device, unregister_installation
from app.models import Device, DeviceInstallation, User, Notification, PushDelivery
from test_emergency_notification_postgres import pg_env, pytestmark


@pytest.mark.parametrize('winner', [1, 2])
def test_installation_claim_after_real_token_conflict(pg_env, monkeypatch, winner):
    from fastapi import HTTPException
    engine, config, _ = pg_env
    command.upgrade(config, 'head')
    original_commit = Session.commit
    raced = False
    token, installation_id = 'synthetic-racing-token', 'c' * 64

    def commit(db):
        nonlocal raced
        if not raced and any(isinstance(row, Device) and row.fcm_token == token for row in db.new):
            raced = True
            with Session(engine) as other:
                other.add(Device(user_id=winner, fcm_token=token, platform='android'))
                original_commit(other)
        return original_commit(db)

    monkeypatch.setattr(Session, 'commit', commit)
    with Session(engine) as db:
        body = DeviceCreate(fcm_token=token, platform='android', installation_id=installation_id)
        if winner == 1:
            register_device(body, db.get(User, 1), db)
        else:
            with pytest.raises(HTTPException) as rejected:
                register_device(body, db.get(User, 1), db)
            assert rejected.value.status_code == 409
    with Session(engine) as db:
        installation = db.get(DeviceInstallation, installation_id)
        device = db.scalar(select(Device).where(Device.fcm_token == token))
        assert device.user_id == winner
        if winner == 1:
            assert installation.owner_user_id == 1
            assert device.installation_id == installation_id
        else:
            assert installation is None
            assert device.installation_id is None


def test_installation_upgrade_legacy_and_roundtrip(pg_env):
    engine, config, _ = pg_env
    command.upgrade(config, "e17d6a10bc25")
    with engine.begin() as c:
        c.execute(text("INSERT INTO devices(user_id,fcm_token,platform,registered_at) VALUES (1,'synthetic-legacy','android',now())"))
    command.upgrade(config, "a91b8c7d6e5f")
    with engine.connect() as c:
        assert c.execute(text("SELECT user_id,fcm_token,installation_id FROM devices")).one() == (1, 'synthetic-legacy', None)
    assert any(i['name'] == 'ix_devices_user_installation' and i['column_names'] == ['user_id', 'installation_id'] for i in inspect(engine).get_indexes('devices'))
    with Session(engine) as db:
        db.add(DeviceInstallation(installation_id='a'*64, owner_user_id=999))
        with pytest.raises(IntegrityError):
            db.commit()
    command.downgrade(config, "e17d6a10bc25")
    command.upgrade(config, "head")
    with Session(engine) as db:
        assert db.scalar(select(Device)).fcm_token == 'synthetic-legacy'


def test_installation_rotation_cleanup_and_other_phone(pg_env):
    engine, config, _ = pg_env
    command.upgrade(config, 'head')
    a, b = 'a'*64, 'b'*64
    with Session(engine) as db:
        user = db.get(User, 1)
        for token, installation in [('synthetic-old', a), ('synthetic-new', a), ('synthetic-other-phone', b)]:
            register_device(DeviceCreate(fcm_token=token, platform='android', installation_id=installation), user, db)
        target = db.scalar(select(Device).where(Device.fcm_token == 'synthetic-new'))
        notice = Notification(recipient_user_id=1, category='emergency', event_type='emergency.panic', source_id=123, title='Test emergency', message='Synthetic only')
        db.add(notice)
        db.flush()
        job = PushDelivery(notification_id=notice.id, device_id=target.id)
        db.add(job)
        db.commit()
        job_id = job.id
        result = unregister_installation(DeviceInstallationRemove(installation_id=a), user, db)
        assert result['revoked_count'] == 2
        db.expire_all()
        assert db.get(PushDelivery, job_id).status == 'cancelled'
        assert db.get(PushDelivery, job_id).device_id is None
        assert not result['installation_registrations_remain']
        assert db.scalars(select(Device.installation_id)).all() == [b]
        assert unregister_installation(DeviceInstallationRemove(installation_id=a), user, db)['revoked_count'] == 0
        register_device(DeviceCreate(fcm_token='synthetic-new', platform='android', installation_id=a), db.get(User, 2), db)
        with pytest.raises(RuntimeError, match='ownership records'):
            command.downgrade(config, 'e17d6a10bc25')
