from datetime import datetime

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, select
from sqlalchemy.dialects import postgresql
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth import get_db
from app.contact_links import router
from app.contacts import router as contacts_router
from app.models import EmergencyContact, EmergencyContactLink, User


def headers(user_id):
    return {"Authorization": f"Bearer synthetic-test-user-{user_id}"}


@pytest.fixture
def database(tmp_path):
    engine = create_engine(
        f"sqlite+pysqlite:///{tmp_path / 'relationships.db'}",
        connect_args={"check_same_thread": False},
    )

    @event.listens_for(engine, "connect")
    def enable_foreign_keys(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")

    # Exclude unrelated PostGIS tables; use the real user/contact/link models.
    for model in (User, EmergencyContact, EmergencyContactLink):
        model.__table__.create(engine)
    with Session(engine) as db:
        db.add_all([
            User(
                id=i, firebase_uid=f"synthetic-uid-{i}", name=f"User {i}",
                email=f"user{i}@example.invalid", city="Test City",
                phone="0000000000",
            )
            for i in (1, 2, 3)
        ])
        db.flush()
        db.add(EmergencyContact(
            id=10, user_id=1, name="Legacy contact", relationship="Friend",
            phone="0000000000", enabled=False,
            created_at=datetime(2026, 1, 1),
        ))
        db.commit()
    yield engine
    engine.dispose()


@pytest.fixture
def client(database, monkeypatch):
    app = FastAPI()
    app.include_router(router)
    app.include_router(contacts_router)

    def get_test_db():
        with Session(database) as db:
            yield db

    def verify_synthetic_identity(token):
        identities = {
            f"synthetic-test-user-{i}": {"uid": f"synthetic-uid-{i}"}
            for i in (1, 2, 3)
        }
        if token not in identities:
            raise ValueError("Not a synthetic test identity")
        return identities[token]

    app.dependency_overrides[get_db] = get_test_db
    monkeypatch.setattr("app.auth.initialize_firebase", lambda: None)
    monkeypatch.setattr(
        "app.auth.firebase_auth.verify_id_token", verify_synthetic_identity,
    )
    with TestClient(app) as test_client:
        yield test_client


def invite(client, inviter=1, invitee=2):
    return client.post(
        "/contact-links/invites", headers=headers(inviter),
        json={"email": f"user{invitee}@example.invalid"},
    )


def respond(client, link_id, action="accept", user=2):
    return client.post(
        f"/contact-links/{link_id}/respond", headers=headers(user),
        json={"action": action},
    )


def relationships(client, user=1):
    response = client.get("/contact-links/relationships", headers=headers(user))
    assert response.status_code == 200
    return response.json()


def test_create_pending_invitation(client):
    response = invite(client)
    assert response.status_code == 201
    link = response.json()
    assert set(link) == {
        "id", "inviter_user_id", "invitee_user_id", "status", "created_at",
        "updated_at", "responded_at", "revoked_at", "other_user_id",
    }
    assert (link["inviter_user_id"], link["invitee_user_id"]) == (1, 2)
    assert link["status"] == "pending"
    assert link["created_at"] and link["updated_at"]
    assert link["responded_at"] is None and link["revoked_at"] is None
    assert relationships(client) == []
    incoming = client.get("/contact-links/invites/incoming", headers=headers(2))
    assert incoming.status_code == 200
    assert [item["id"] for item in incoming.json()] == [link["id"]]
    for user in (1, 3):
        assert client.get(
            "/contact-links/invites/incoming", headers=headers(user),
        ).json() == []


@pytest.mark.parametrize("action,status", [("accept", "accepted"), ("reject", "rejected")])
def test_invitee_response_controls_eligibility(client, action, status):
    original = invite(client).json()
    response = respond(client, original["id"], action)
    assert response.status_code == 200
    link = response.json()
    assert link["status"] == status
    assert link["created_at"] == original["created_at"]
    assert link["responded_at"] == link["updated_at"]
    assert link["updated_at"] >= original["updated_at"]
    assert link["revoked_at"] is None
    for user, other in ((1, 2), (2, 1)):
        eligible = relationships(client, user)
        assert [item["other_user_id"] for item in eligible] == (
            [other] if status == "accepted" else []
        )
    assert relationships(client, 3) == []
    assert client.get(
        "/contact-links/invites/incoming", headers=headers(2),
    ).json() == []


@pytest.mark.parametrize("revoker", [1, 2])
@pytest.mark.parametrize("accepted", [False, True])
def test_either_participant_can_revoke_active_link(client, revoker, accepted):
    link = invite(client).json()
    if accepted:
        link = respond(client, link["id"]).json()
    response = client.delete(f"/contact-links/{link['id']}", headers=headers(revoker))
    assert response.status_code == 200
    revoked = response.json()
    assert revoked["status"] == "revoked"
    assert revoked["revoked_at"] == revoked["updated_at"]
    assert revoked["updated_at"] >= link["updated_at"]
    assert revoked["responded_at"] == link["responded_at"]
    assert relationships(client, 1) == relationships(client, 2) == []
    assert respond(client, link["id"]).status_code == 409


@pytest.mark.parametrize("accepted", [False, True])
@pytest.mark.parametrize("reverse", [False, True])
def test_duplicate_active_invites_are_rejected(client, accepted, reverse):
    link = invite(client).json()
    if accepted:
        assert respond(client, link["id"]).status_code == 200
    duplicate = invite(client, 2, 1) if reverse else invite(client)
    assert duplicate.status_code == 409


@pytest.mark.parametrize("terminal", ["rejected", "revoked"])
def test_new_invitation_allowed_after_terminal_state(client, database, terminal):
    link = invite(client).json()
    if terminal == "rejected":
        assert respond(client, link["id"], "reject").status_code == 200
    else:
        assert client.delete(
            f"/contact-links/{link['id']}", headers=headers(1),
        ).status_code == 200
    new_link = invite(client, 2, 1)
    assert new_link.status_code == 201
    assert new_link.json()["id"] != link["id"]
    with Session(database) as db:
        assert db.get(EmergencyContactLink, link["id"]).status == terminal
    assert relationships(client) == []


def test_self_invite_and_unknown_account_are_rejected(client):
    assert invite(client, 1, 1).status_code == 400
    assert invite(client, 1, 99).status_code == 404


@pytest.mark.parametrize("user", [1, 3])
def test_only_invitee_can_respond(client, user):
    link = invite(client).json()
    for action in ("accept", "reject"):
        assert respond(client, link["id"], action, user).status_code == 404
    assert respond(client, link["id"]).status_code == 200


def test_outsider_cannot_revoke_or_see_link(client):
    link = invite(client).json()
    assert client.delete(
        f"/contact-links/{link['id']}", headers=headers(3),
    ).status_code == 404
    assert respond(client, link["id"]).status_code == 200
    assert relationships(client, 3) == []


@pytest.mark.parametrize("terminal_action", ["accept", "reject", "revoke"])
def test_terminal_transitions_cannot_be_replayed(client, terminal_action):
    link_id = invite(client).json()["id"]
    if terminal_action == "revoke":
        assert client.delete(f"/contact-links/{link_id}", headers=headers(1)).status_code == 200
    else:
        assert respond(client, link_id, terminal_action).status_code == 200
    for action in ("accept", "reject"):
        assert respond(client, link_id, action).status_code == 409
    if terminal_action != "accept":
        assert client.delete(f"/contact-links/{link_id}", headers=headers(1)).status_code == 409


@pytest.mark.parametrize("method,path,payload", [
    ("POST", "/contact-links/invites", {"email": "user2@example.invalid"}),
    ("GET", "/contact-links/invites/incoming", None),
    ("GET", "/contact-links/relationships", None),
    ("POST", "/contact-links/1/respond", {"action": "accept"}),
    ("DELETE", "/contact-links/1", None),
])
def test_all_relationship_routes_require_authentication(client, method, path, payload):
    assert client.request(method, path, json=payload).status_code == 401
    assert client.request(
        method, path, json=payload, headers={"Authorization": "Bearer invalid-synthetic-identity"},
    ).status_code == 401


def test_invalid_action_and_identity_spoofing_are_rejected(client):
    link_id = invite(client).json()["id"]
    assert respond(client, link_id, "revoke").status_code == 422
    assert client.post(
        "/contact-links/invites", headers=headers(1),
        json={"email": "user3@example.invalid", "inviter_user_id": 2},
    ).status_code == 422
    assert client.post(
        "/contact-links/invites", headers=headers(1),
        json={"phone": "0000000000"},
    ).status_code == 422


def test_lifecycle_never_changes_or_links_legacy_contacts(client, database):
    def snapshot():
        with database.connect() as connection:
            return connection.execute(select(EmergencyContact.__table__)).all()

    before = snapshot()
    link_id = invite(client).json()["id"]
    assert snapshot() == before
    assert respond(client, link_id).status_code == 200
    assert snapshot() == before
    assert client.delete(f"/contact-links/{link_id}", headers=headers(2)).status_code == 200
    assert snapshot() == before
    link_id = invite(client).json()["id"]
    assert respond(client, link_id, "reject").status_code == 200
    assert snapshot() == before

    # Same phone as registered users: legacy data stays independent throughout.
    assert client.get("/contacts", headers=headers(1)).json() == [{
        "id": 10, "name": "Legacy contact", "relationship": "Friend",
        "phone": "0000000000", "enabled": False,
    }]
    assert client.get("/contacts", headers=headers(2)).json() == []
    assert client.patch("/contacts/10", headers=headers(2), json={"enabled": True}).status_code == 404
    assert client.patch("/contacts/10", headers=headers(1), json={"enabled": True}).status_code == 200
    created = client.post("/contacts", headers=headers(1), json={
        "name": "Phone only", "relationship": "Family", "phone": "0000000001",
    })
    assert created.status_code == 200


@pytest.mark.parametrize("values", [
    {"inviter_user_id": 1, "invitee_user_id": 1, "status": "pending"},
    {"inviter_user_id": 1, "invitee_user_id": 2, "status": "invalid"},
    {"inviter_user_id": 99, "invitee_user_id": 2, "status": "pending"},
    {"inviter_user_id": 1, "invitee_user_id": 99, "status": "pending"},
    {"inviter_user_id": None, "invitee_user_id": 2, "status": "pending"},
])
def test_schema_constraints_reject_invalid_rows(database, values):
    with Session(database) as db:
        db.add(EmergencyContactLink(**values))
        with pytest.raises(IntegrityError):
            db.commit()


@pytest.mark.parametrize("first_status", ["pending", "accepted"])
@pytest.mark.parametrize("reverse", [False, True])
def test_database_prevents_duplicate_active_pairs(database, first_status, reverse):
    with Session(database) as db:
        db.add(EmergencyContactLink(inviter_user_id=1, invitee_user_id=2, status=first_status))
        db.commit()
        db.add(EmergencyContactLink(
            inviter_user_id=2 if reverse else 1,
            invitee_user_id=1 if reverse else 2,
            status="pending",
        ))
        with pytest.raises(IntegrityError):
            db.commit()


def test_competing_reverse_insert_returns_conflict_and_rolls_back(client, database):
    def insert_competing_invitation(session, flush_context, instances):
        if not any(isinstance(row, EmergencyContactLink) for row in session.new):
            return
        # Another writer wins after the route's duplicate precheck, before its
        # INSERT. Exercise the real index violation and rollback handler.
        with database.begin() as connection:
            connection.execute(EmergencyContactLink.__table__.insert(), {
                "inviter_user_id": 2, "invitee_user_id": 1, "status": "pending",
            })

    event.listen(Session, "before_flush", insert_competing_invitation)
    try:
        assert invite(client).status_code == 409
    finally:
        event.remove(Session, "before_flush", insert_competing_invitation)
    with Session(database) as db:
        links = db.scalars(select(EmergencyContactLink)).all()
        assert [(row.inviter_user_id, row.invitee_user_id) for row in links] == [(2, 1)]
    assert invite(client, 1, 3).status_code == 201


def test_unlinked_firebase_identity_cannot_create_invitation(client, monkeypatch):
    monkeypatch.setattr(
        "app.auth.firebase_auth.verify_id_token",
        lambda token: {"uid": "synthetic-unlinked-user"},
    )
    assert invite(client).status_code == 403


@pytest.mark.parametrize("operation", ["respond", "revoke"])
def test_lifecycle_reads_request_postgresql_row_lock(client, operation):
    link_id = invite(client).json()["id"]
    statements = []

    def capture_sql(execution):
        if execution.is_select:
            statements.append(str(execution.statement.compile(dialect=postgresql.dialect())))

    event.listen(Session, "do_orm_execute", capture_sql)
    try:
        if operation == "respond":
            response = respond(client, link_id)
        else:
            response = client.delete(f"/contact-links/{link_id}", headers=headers(1))
        assert response.status_code == 200
    finally:
        event.remove(Session, "do_orm_execute", capture_sql)
    assert any(
        "FROM emergency_contact_links" in sql and sql.endswith("FOR UPDATE")
        for sql in statements
    )
