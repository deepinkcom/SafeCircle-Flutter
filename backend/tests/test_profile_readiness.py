from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import User, EmergencyContactLink, Notification, Device, PushDelivery
from test_user_search import client, database, snapshot

DETAILS = {'name': 'Synthetic New Member', 'city': 'Synthetic City', 'phone': '0000000000'}


def headers(account='existing'):
    return {'Authorization': 'Bearer synthetic-profile-' + account}


@pytest.fixture
def profile_client(client, monkeypatch):
    identities = {
        'existing': ('synthetic-search-uid-1', 'caller@example.invalid'),
        'other': ('synthetic-search-uid-2', 'invitee@example.invalid'),
        'new': ('synthetic-new-profile', 'new@example.invalid'),
        'conflict': ('synthetic-unrelated-uid', 'caller@example.invalid'),
        'changed-email': ('synthetic-search-uid-1', 'changed@example.invalid'),
    }
    def verify(token):
        if token == 'synthetic-profile-no-email': return {'uid': 'synthetic-new-profile'}
        key = token.removeprefix('synthetic-profile-')
        if key not in identities: raise ValueError('Synthetic invalid identity')
        uid, email = identities[key]
        return {'uid': uid, 'email': email}
    monkeypatch.setattr('app.users.firebase_auth.verify_id_token', verify)
    return client


def test_readiness_is_private_read_only_and_missing_profile_is_safe(profile_client, database):
    before = snapshot(database)
    known = profile_client.get('/users/me', headers=headers())
    assert known.status_code == 200
    assert known.json() == {'id': 1, 'profile_ready': True, 'missing_fields': []}
    assert known.headers['cache-control'] == 'no-store'
    missing = profile_client.get('/users/me', headers=headers('new'))
    assert missing.status_code == 200
    assert missing.json() == {'id': None, 'profile_ready': False, 'missing_fields': ['name', 'phone', 'city']}
    assert snapshot(database) == before


@pytest.mark.parametrize('method', ['GET', 'POST'])
@pytest.mark.parametrize('account', [None, 'invalid', 'no-email'])
def test_identity_required(profile_client, method, account):
    response = profile_client.request(method, '/users/me', headers=headers(account) if account else {}, json=DETAILS if method == 'POST' else None)
    assert response.status_code == 401


def test_complete_only_current_uid_and_idempotent_repeat(profile_client, database):
    assert profile_client.get('/users/search', params={'q': 'new@example.invalid'}, headers=headers()).json() == []
    first = profile_client.post('/users/me', headers=headers('new'), json=DETAILS)
    second = profile_client.post('/users/me', headers=headers('new'), json=DETAILS)
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    assert profile_client.get('/users/me', headers=headers('new')).json()['profile_ready'] is True
    assert profile_client.get('/users/search', params={'q': 'NEW@example.invalid'}, headers=headers()).json() == [{'name': DETAILS['name'], 'email': 'new@example.invalid'}]
    with Session(database) as db:
        rows = db.scalars(select(User).where(User.firebase_uid == 'synthetic-new-profile')).all()
        assert len(rows) == 1
        assert rows[0].email == 'new@example.invalid'


@pytest.mark.parametrize('field,value', [('city', ''), ('phone', ' '), ('name', ' '), ('city', 'x'*101)])
def test_incomplete_profile_is_not_created(profile_client, database, field, value):
    assert profile_client.post('/users/me', headers=headers('new'), json={**DETAILS, field: value}).status_code == 422
    with Session(database) as db:
        assert db.scalar(select(User.id).where(User.firebase_uid == 'synthetic-new-profile')) is None


def test_request_cannot_choose_another_uid_or_email(profile_client, database):
    before = snapshot(database)
    assert profile_client.post('/users/me', headers=headers('new'), json={**DETAILS, 'firebase_uid': 'synthetic-search-uid-1', 'email': 'caller@example.invalid'}).status_code == 422
    assert snapshot(database) == before


@pytest.mark.parametrize('account', ['conflict', 'changed-email'])
def test_identity_conflicts_never_relink_or_overwrite(profile_client, database, account):
    before = snapshot(database)
    assert profile_client.post('/users/me', headers=headers(account), json=DETAILS).status_code == 409
    if account == 'changed-email':
        assert profile_client.get('/users/me', headers=headers(account)).status_code == 409
    assert snapshot(database) == before


def test_incomplete_backend_user_not_discoverable_or_invitable(profile_client, database):
    with Session(database) as db:
        db.get(User, 2).city = ''
        db.commit()
    assert profile_client.get('/users/me', headers=headers('other')).json() == {'id': 2, 'profile_ready': False, 'missing_fields': ['city']}
    assert profile_client.get('/users/search', params={'q': 'invitee@example.invalid'}, headers=headers()).json() == []
    assert profile_client.post('/contact-links/invites', headers=headers(), json={'email': 'invitee@example.invalid'}).status_code == 404
    assert profile_client.get('/users/search', params={'q': 'caller@example.invalid'}, headers=headers('other')).status_code == 403


def test_creation_failure_rolls_back(profile_client, database, monkeypatch):
    def fail(session): raise RuntimeError('Synthetic commit failure')
    monkeypatch.setattr(Session, 'commit', fail)
    with pytest.raises(RuntimeError, match='Synthetic commit failure'):
        profile_client.post('/users/me', headers=headers('new'), json=DETAILS)
    with Session(database) as db:
        assert db.scalar(select(User.id).where(User.firebase_uid == 'synthetic-new-profile')) is None


def test_concurrent_creation_returns_winner_without_overwriting(profile_client, database, monkeypatch):
    original = Session.commit
    interleaved = False
    def commit(session):
        nonlocal interleaved
        if not interleaved and any(isinstance(row, User) and row.firebase_uid == 'synthetic-new-profile' for row in session.new):
            interleaved = True
            with Session(database) as other:
                other.add(User(firebase_uid='synthetic-new-profile', email='new@example.invalid', name='Concurrent Winner', city='Other City', phone='0000000001', created_at=datetime(2026, 1, 1)))
                original(other)
        return original(session)
    monkeypatch.setattr(Session, 'commit', commit)
    response = profile_client.post('/users/me', headers=headers('new'), json=DETAILS)
    assert response.status_code == 200
    assert response.json()['name'] == 'Concurrent Winner'
    assert response.json()['city'] == 'Other City'
    with Session(database) as db:
        assert len(db.scalars(select(User).where(User.firebase_uid == 'synthetic-new-profile')).all()) == 1


def test_parallel_repeated_creation_has_one_user(profile_client, database):
    def complete(_):
        return profile_client.post('/users/me', headers=headers('new'), json=DETAILS)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(complete, range(2)))
    assert [r.status_code for r in results] == [200, 200]
    assert results[0].json()['id'] == results[1].json()['id']


def test_explicit_profile_update_preserves_relationship_notification_device_records(profile_client, database):
    with Session(database) as db:
        db.add(Device(user_id=1, fcm_token='synthetic-preserved-device', platform='android'))
        db.commit()
    invited = profile_client.post('/contact-links/invites', headers=headers('other'), json={'email': 'caller@example.invalid'})
    assert invited.status_code == 201
    models = (EmergencyContactLink, Notification, Device, PushDelivery)
    def records():
        with database.connect() as c:
            return {m.__tablename__: c.execute(select(m.__table__).order_by(m.id)).all() for m in models}
    before = records()
    assert profile_client.post('/users/me', headers=headers(), json=DETAILS).status_code == 200
    assert records() == before
    assert profile_client.get('/users/me', headers=headers('other')).json()['id'] == 2
