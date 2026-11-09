from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth import get_db
from app.devices import router
from app.models import Device, Notification, PushDelivery
from test_contact_links import database, headers

TOKEN = 'synthetic-device-token-private-marker'

@pytest.fixture
def client(database, monkeypatch):
    app = FastAPI()
    app.include_router(router)
    def sessions():
        with Session(database) as db: yield db
    def identity(token):
        for user in (1, 2):
            if token == f'synthetic-test-user-{user}': return {'uid': f'synthetic-uid-{user}'}
        raise ValueError('Invalid synthetic identity')
    app.dependency_overrides[get_db] = sessions
    monkeypatch.setattr('app.auth.initialize_firebase', lambda: None)
    monkeypatch.setattr('app.auth.firebase_auth.verify_id_token', identity)
    with TestClient(app) as client: yield client

def register(client, user=1, token=TOKEN, platform='android'):
    return client.post('/devices', headers=headers(user), json={'fcm_token': token, 'platform': platform})

@pytest.mark.parametrize('winner', [1, 2])
def test_real_unique_conflict_is_recovered_without_transferring_owner(client, database, monkeypatch, winner, caplog):
    original = Session.commit
    raced = False
    def commit(db):
        nonlocal raced
        if not raced and any(isinstance(item, Device) and item.fcm_token == TOKEN for item in db.new):
            raced = True
            with Session(database) as other:
                other.add(Device(user_id=winner, fcm_token=TOKEN, platform='android'))
                original(other)
        return original(db)
    monkeypatch.setattr(Session, 'commit', commit)
    result = register(client)
    assert result.status_code == (200 if winner == 1 else 409)
    with Session(database) as db:
        rows = db.scalars(select(Device)).all()
        assert len(rows) == 1 and rows[0].user_id == winner
        if winner == 1: assert result.json()['id'] == rows[0].id
    assert TOKEN not in result.text and TOKEN not in caplog.text

@pytest.mark.parametrize('owners', [(1, 1), (1, 2)])
def test_parallel_registration_keeps_one_owner(client, database, owners):
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda owner: register(client, owner), owners))
    codes = sorted(response.status_code for response in results)
    assert codes == ([200, 200] if owners[0] == owners[1] else [200, 409])
    with Session(database) as db:
        rows = db.scalars(select(Device)).all()
        assert len(rows) == 1
        for response, owner in zip(results, owners):
            if response.status_code == 200: assert rows[0].user_id == owner


def test_reregistration_preserves_device_and_delivery_ids(client, database):
    first = register(client).json()
    with Session(database) as db:
        notice = Notification(recipient_user_id=1, category='connection', event_type='connection.invited', source_id=1, title='Synthetic', message='Fixture only')
        db.add(notice); db.flush()
        job = PushDelivery(notification_id=notice.id, device_id=first['id'])
        db.add(job); db.commit(); job_id = job.id
    second = register(client, platform='ios')
    assert second.status_code == 200 and second.json()['id'] == first['id']
    with Session(database) as db:
        assert db.get(PushDelivery, job_id).device_id == first['id']
        assert db.get(Device, first['id']).platform == 'ios'

@pytest.mark.parametrize('operation', ['register', 'unregister'])
def test_unexpected_database_error_is_sanitized_and_rolled_back(client, database, monkeypatch, caplog, operation):
    register(client)
    def fail(db):
        error = RuntimeError('sensitive driver detail ' + TOKEN)
        raise IntegrityError('SQL containing ' + TOKEN, {'fcm_token': TOKEN}, error)
    monkeypatch.setattr(Session, 'commit', fail)
    result = register(client) if operation == 'register' else client.request('DELETE', '/devices', headers=headers(1), json={'fcm_token': TOKEN})
    assert result.status_code == 503
    assert TOKEN not in result.text and TOKEN not in caplog.text
    with Session(database) as db: assert len(db.scalars(select(Device)).all()) == 1

@pytest.mark.parametrize('operation', ['POST', 'DELETE'])
def test_validation_does_not_echo_token(client, operation):
    token = TOKEN * 30
    data = {'fcm_token': token, **({'platform': 'android'} if operation == 'POST' else {})}
    response = client.request(operation, '/devices', headers=headers(1), json=data)
    assert response.status_code == 422
    assert TOKEN not in response.text


def test_postgres_unique_error_classifier_uses_constraint_name_only():
    from app.devices import _is_token_conflict
    original = SimpleNamespace(pgcode='23505', diag=SimpleNamespace(constraint_name='uq_devices_fcm_token'))
    assert _is_token_conflict(IntegrityError('statement', {}, original))
    original.diag.constraint_name = 'different_constraint'
    assert not _is_token_conflict(IntegrityError('statement', {}, original))


def test_cleanup_uses_same_token_normalization_as_registration(client, database):
    response = register(client, token='  ' + TOKEN + '  ')
    assert response.status_code == 200
    removed = client.request('DELETE', '/devices', headers=headers(1), json={'fcm_token': ' ' + TOKEN + ' '})
    assert removed.status_code == 200
    with Session(database) as db:
        assert db.scalars(select(Device)).all() == []


def test_application_engine_hides_bound_parameters_in_database_errors():
    from sqlalchemy import text
    from sqlalchemy.exc import DBAPIError
    from app.database import engine
    with engine.connect() as connection:
        with pytest.raises(DBAPIError) as captured:
            connection.execute(text('SELECT :secret FROM synthetic_missing_relation_for_redaction'), {'secret': TOKEN})
    assert TOKEN not in str(captured.value)
