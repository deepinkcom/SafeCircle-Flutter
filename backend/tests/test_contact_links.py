from datetime import datetime, timezone

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, select
from sqlalchemy.dialects import postgresql
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth import get_db
from app.contact_links import ContactLinkResponse, _link_response, _link_responses, router
from app.contacts import router as contacts_router
from app.models import EmergencyContact, EmergencyContactLink, User


RELATIONSHIP_REQUESTS = [
    ("POST", "/contact-links/invites", {"email": "user2@example.invalid"}),
    ("GET", "/contact-links/invites/incoming", None),
    ("GET", "/contact-links/invites/outgoing", None),
    ("GET", "/contact-links/relationships", None),
    ("POST", "/contact-links/1/respond", {"action": "accept"}),
    ("POST", "/contact-links/1/respond", {"action": "reject"}),
    ("DELETE", "/contact-links/1", None),
]


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


@pytest.mark.parametrize("user", [1, 2, 3])
def test_outgoing_invitations_empty_for_user_without_sent_links(client, user):
    response = client.get("/contact-links/invites/outgoing", headers=headers(user))
    assert response.status_code == 200
    assert response.json() == []


@pytest.mark.parametrize("status", ["pending", "accepted", "rejected", "revoked"])
def test_outgoing_invitations_include_only_callers_sent_history(client, status):
    sent = invite(client).json()
    if status in ("accepted", "rejected"):
        response = respond(client, sent["id"], "accept" if status == "accepted" else "reject")
        assert response.status_code == 200
    elif status == "revoked":
        response = client.delete(f"/contact-links/{sent['id']}", headers=headers(1))
        assert response.status_code == 200
    else:
        response = None
    expected = response.json() if response is not None else sent
    expected["other_user_id"] = 2  # Always relative to the sender of this list.
    expected["other_user"] = {"id": 2, "name": "User 2", "email": "user2@example.invalid"}
    assert invite(client, 3, 1).status_code == 201  # Incoming to user 1.
    assert invite(client, 2, 3).status_code == 201  # Unrelated to user 1.

    outgoing = client.get("/contact-links/invites/outgoing", headers=headers(1))
    assert outgoing.status_code == 200
    assert outgoing.json() == [expected]
    assert outgoing.json()[0]["status"] == status
    # A caller-supplied user ID cannot expose another sender's records.
    assert client.get(
        "/contact-links/invites/outgoing?inviter_user_id=2", headers=headers(1),
    ).json() == [expected]


def test_outgoing_invitations_are_newest_first_with_stable_ties(client, database):
    with Session(database) as db:
        db.add_all([
            EmergencyContactLink(
                id=20, inviter_user_id=1, invitee_user_id=2, status="rejected",
                created_at=datetime(2026, 1, 1),
            ),
            EmergencyContactLink(
                id=21, inviter_user_id=1, invitee_user_id=2, status="revoked",
                created_at=datetime(2026, 1, 3),
            ),
            EmergencyContactLink(
                id=22, inviter_user_id=1, invitee_user_id=3, status="accepted",
                created_at=datetime(2026, 1, 3),
            ),
            EmergencyContactLink(
                id=23, inviter_user_id=1, invitee_user_id=2, status="pending",
                created_at=datetime(2026, 1, 2),
            ),
        ])
        db.commit()
        before = db.execute(select(EmergencyContactLink.__table__)).all()
    response = client.get("/contact-links/invites/outgoing", headers=headers(1))
    assert response.status_code == 200
    assert [row["id"] for row in response.json()] == [22, 21, 23, 20]
    with Session(database) as db:
        assert db.execute(select(EmergencyContactLink.__table__)).all() == before


def test_create_pending_invitation(client):
    response = invite(client)
    assert response.status_code == 201
    link = response.json()
    assert set(link) == {
        "id", "inviter_user_id", "invitee_user_id", "status", "created_at",
        "updated_at", "responded_at", "revoked_at", "other_user_id",
        "other_user",
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


def test_self_invite_and_unknown_account_are_rejected(client, database):
    self_invite = invite(client, 1, 1)
    assert self_invite.status_code == 400
    assert self_invite.json() == {"detail": "You cannot invite yourself"}
    unknown = invite(client, 1, 99)
    assert unknown.status_code == 404
    assert unknown.json() == {"detail": "SafeCircle user not found"}
    with Session(database) as db:
        assert db.scalars(select(EmergencyContactLink)).all() == []


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


@pytest.mark.parametrize("method,path,payload", RELATIONSHIP_REQUESTS)
def test_all_relationship_routes_require_authentication(client, method, path, payload):
    missing = client.request(method, path, json=payload)
    assert missing.status_code == 401
    assert missing.json() == {"detail": "Missing Firebase ID token"}
    assert missing.headers["www-authenticate"] == "Bearer"
    invalid = client.request(
        method, path, json=payload, headers={"Authorization": "Bearer invalid-synthetic-identity"},
    )
    assert invalid.status_code == 401
    assert invalid.json() == {"detail": "Invalid or expired Firebase ID token"}
    assert invalid.headers["www-authenticate"] == "Bearer"


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


@pytest.mark.parametrize("method,path,payload", RELATIONSHIP_REQUESTS)
def test_unlinked_firebase_identity_cannot_access_relationship_routes(
    client, monkeypatch, method, path, payload,
):
    monkeypatch.setattr(
        "app.auth.firebase_auth.verify_id_token",
        lambda token: {"uid": "synthetic-unlinked-user"},
    )
    response = client.request(method, path, json=payload, headers=headers(1))
    assert response.status_code == 403
    assert response.json() == {
        "detail": "Firebase account is not linked to a SafeCircle user profile",
    }


@pytest.mark.parametrize("action", ["accept", "reject"])
def test_missing_invitation_returns_not_found(client, action):
    response = respond(client, 9999, action)
    assert response.status_code == 404
    assert response.json() == {"detail": "Invitation not found"}


def test_missing_relationship_returns_not_found(client):
    response = client.delete("/contact-links/9999", headers=headers(1))
    assert response.status_code == 404
    assert response.json() == {"detail": "Relationship not found"}


@pytest.mark.parametrize("method,path,payload", [
    ("POST", "/contact-links/invites", {}),
    ("POST", "/contact-links/invites", {"email": "x"}),
    ("POST", "/contact-links/1/respond", {}),
    ("POST", "/contact-links/1/respond", {"action": "accepted"}),
    ("POST", "/contact-links/1/respond", {"action": "accept", "invitee_user_id": 2}),
    ("POST", "/contact-links/not-an-id/respond", {"action": "accept"}),
    ("DELETE", "/contact-links/not-an-id", None),
])
def test_invalid_relationship_requests_return_validation_errors(client, database, method, path, payload):
    response = client.request(method, path, json=payload, headers=headers(1))
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], list)
    with Session(database) as db:
        assert db.scalars(select(EmergencyContactLink)).all() == []


def test_invitation_email_is_normalized(client):
    response = client.post(
        "/contact-links/invites", headers=headers(1),
        json={"email": " USER2@EXAMPLE.INVALID "},
    )
    assert response.status_code == 201
    assert response.json()["invitee_user_id"] == 2


@pytest.mark.parametrize("action", ["accept", "reject"])
def test_unauthorized_response_does_not_change_invitation(client, database, action):
    link_id = invite(client).json()["id"]
    with database.connect() as connection:
        before = connection.execute(select(EmergencyContactLink.__table__)).all()
    for user in (1, 3):
        response = respond(client, link_id, action, user)
        assert response.status_code == 404
        assert response.json() == {"detail": "Invitation not found"}
    with database.connect() as connection:
        assert connection.execute(select(EmergencyContactLink.__table__)).all() == before


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


def assert_other_user(link, user_id):
    assert link["other_user_id"] == user_id
    assert link["other_user"] == {
        "id": user_id, "name": f"User {user_id}",
        "email": f"user{user_id}@example.invalid",
    }


@pytest.mark.parametrize("action", ["accept", "reject"])
def test_counterparty_identity_across_creation_lists_and_response(client, action):
    created = invite(client)
    assert created.status_code == 201
    link = created.json()
    assert_other_user(link, 2)
    incoming = client.get("/contact-links/invites/incoming", headers=headers(2))
    assert incoming.status_code == 200
    assert_other_user(incoming.json()[0], 1)
    outgoing = client.get("/contact-links/invites/outgoing", headers=headers(1))
    assert outgoing.status_code == 200
    assert_other_user(outgoing.json()[0], 2)
    response = respond(client, link["id"], action)
    assert response.status_code == 200
    assert_other_user(response.json(), 1)
    outgoing = client.get("/contact-links/invites/outgoing", headers=headers(1))
    assert_other_user(outgoing.json()[0], 2)
    assert outgoing.json()[0]["status"] == ("accepted" if action == "accept" else "rejected")
    if action == "accept":
        assert_other_user(relationships(client, 1)[0], 2)
        assert_other_user(relationships(client, 2)[0], 1)
    else:
        assert relationships(client, 1) == relationships(client, 2) == []


@pytest.mark.parametrize("actor", [1, 2])
@pytest.mark.parametrize("accepted", [False, True])
def test_revocation_returns_only_the_other_participants_identity(client, actor, accepted):
    link = invite(client).json()
    if accepted:
        assert respond(client, link["id"]).status_code == 200
    response = client.delete(f"/contact-links/{link['id']}", headers=headers(actor))
    assert response.status_code == 200
    assert_other_user(response.json(), 2 if actor == 1 else 1)
    assert response.json()["status"] == "revoked"
    assert_other_user(
        client.get("/contact-links/invites/outgoing", headers=headers(1)).json()[0], 2,
    )


def test_relationship_identity_has_only_approved_fields_and_is_current(client, database):
    link_id = invite(client).json()["id"]
    with Session(database) as db:
        user = db.get(User, 2)
        user.name = "Updated display name"
        user.email = "updated@example.invalid"
        db.commit()
    response = client.get("/contact-links/invites/outgoing", headers=headers(1))
    assert response.status_code == 200
    assert response.json()[0]["id"] == link_id
    assert response.json()[0]["other_user"] == {
        "id": 2, "name": "Updated display name", "email": "updated@example.invalid",
    }
    for private_value in ("firebase_uid", "synthetic-uid", "Test City", "0000000000", "User 3", "user3@example.invalid"):
        assert private_value not in response.text


def test_outsider_cannot_read_counterparty_identity_or_spoof_list_owner(client):
    link_id = invite(client).json()["id"]
    for path in ("invites/incoming", "invites/outgoing", "relationships"):
        response = client.get(
            f"/contact-links/{path}?user_id=1&inviter_user_id=1&invitee_user_id=2",
            headers=headers(3),
        )
        assert response.status_code == 200
        assert response.json() == []
    for action in ("accept", "reject"):
        response = respond(client, link_id, action, 3)
        assert response.status_code == 404
        assert response.json() == {"detail": "Invitation not found"}
    response = client.delete(f"/contact-links/{link_id}", headers=headers(3))
    assert response.status_code == 404
    assert response.json() == {"detail": "Relationship not found"}
    assert respond(client, link_id).status_code == 200
    assert relationships(client, 3) == []


@pytest.mark.parametrize("path,status,reverse", [
    ("invites/incoming", "pending", True),
    ("invites/outgoing", "pending", False),
    ("relationships", "accepted", False),
])
@pytest.mark.parametrize("count", [1, 20])
def test_relationship_lists_batch_identity_queries(client, database, path, status, reverse, count):
    with Session(database) as db:
        db.add_all([
            User(id=i, firebase_uid=f"synthetic-batch-{i}", name=f"Batch {i}",
                 email=f"batch{i}@example.invalid", city="Private city", phone="0000000000")
            for i in range(10, 10 + count)
        ])
        db.flush()
        db.add_all([
            EmergencyContactLink(
                inviter_user_id=i if reverse else 1,
                invitee_user_id=1 if reverse else i,
                status=status,
            )
            for i in range(10, 10 + count)
        ])
        db.commit()
    statements = []

    def capture(connection, cursor, statement, parameters, context, executemany):
        if statement.lstrip().upper().startswith("SELECT"):
            statements.append(statement)

    event.listen(database, "before_cursor_execute", capture)
    try:
        response = client.get(f"/contact-links/{path}", headers=headers(1))
    finally:
        event.remove(database, "before_cursor_execute", capture)
    assert response.status_code == 200
    assert len(response.json()) == count
    assert {row["other_user"]["id"] for row in response.json()} == set(range(10, 10 + count))
    # One authentication query, one relationship query, one identity batch.
    assert len(statements) == 3
    assert "firebase_uid" not in statements[-1]
    assert "phone" not in statements[-1] and "city" not in statements[-1]


@pytest.mark.parametrize("path", ["invites/incoming", "invites/outgoing", "relationships"])
def test_empty_relationship_lists_do_not_query_unrelated_identities(client, database, path):
    statements = []

    def capture(connection, cursor, statement, parameters, context, executemany):
        if statement.lstrip().upper().startswith("SELECT"):
            statements.append(statement)

    event.listen(database, "before_cursor_execute", capture)
    try:
        response = client.get(f"/contact-links/{path}", headers=headers(1))
    finally:
        event.remove(database, "before_cursor_execute", capture)
    assert response.status_code == 200 and response.json() == []
    assert len(statements) == 2


@pytest.mark.parametrize("operation", [
    "incoming", "outgoing", "accepted", "accept", "reject", "revoke",
])
def test_missing_counterparty_returns_null_without_substituting_another_user(client, database, operation):
    reverse = operation in ("incoming", "accept", "reject")
    link = invite(client, 2, 1).json() if reverse else invite(client).json()
    if operation == "accepted":
        assert respond(client, link["id"]).status_code == 200
    # Simulate referential corruption ONLY in this disposable SQLite fixture.
    # Normal production foreign keys cascade a user's link deletion.
    with database.connect() as connection:
        connection.exec_driver_sql("PRAGMA foreign_keys=OFF")
        connection.execute(User.__table__.delete().where(User.id == 2))
        connection.commit()
        connection.exec_driver_sql("PRAGMA foreign_keys=ON")
        assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar() == 1
    if operation in ("accept", "reject"):
        response = respond(client, link["id"], operation, 1)
        result = response.json()
    elif operation == "revoke":
        response = client.delete(f"/contact-links/{link['id']}", headers=headers(1))
        result = response.json()
    else:
        path = {"incoming": "invites/incoming", "outgoing": "invites/outgoing", "accepted": "relationships"}[operation]
        response = client.get(f"/contact-links/{path}", headers=headers(1))
        assert len(response.json()) == 1
        result = response.json()[0]
    assert response.status_code == 200
    assert result["id"] == link["id"]
    assert result["other_user_id"] == 2
    assert result["other_user"] is None
    assert "User 3" not in response.text and "user3@example.invalid" not in response.text


@pytest.mark.parametrize("identity", [
    None,
    {"id": 3, "name": "Unrelated", "email": "unrelated@example.invalid"},
    {"id": 2, "name": None, "email": "user2@example.invalid"},
    {"id": 2, "name": "User 2", "email": None},
])
def test_serializer_does_not_disclose_inconsistent_counterparty_data(identity):
    link = EmergencyContactLink(id=7, inviter_user_id=1, invitee_user_id=2, status="pending")
    result = _link_response(link, 1, identity)
    assert result["other_user_id"] == 2
    assert result["other_user"] is None


def test_serializer_only_projects_approved_identity_fields():
    link = EmergencyContactLink(id=7, inviter_user_id=1, invitee_user_id=2, status="pending")
    result = _link_response(link, 1, {
        "id": 2, "name": "User 2", "email": "user2@example.invalid",
        "firebase_uid": "synthetic-private-uid", "phone": "0000000000", "city": "Private city",
    })
    assert_other_user(result, 2)


def test_corrupt_self_link_does_not_return_the_callers_identity_as_counterparty():
    link = EmergencyContactLink(id=7, inviter_user_id=1, invitee_user_id=1, status="pending")
    assert _link_response(link, 1, {
        "id": 1, "name": "User 1", "email": "user1@example.invalid",
    })["other_user"] is None


def test_batch_serializer_authorizes_all_rows_before_reading_any_identities(database):
    authorized = EmergencyContactLink(id=7, inviter_user_id=1, invitee_user_id=2, status="pending")
    unrelated = EmergencyContactLink(id=8, inviter_user_id=2, invitee_user_id=3, status="pending")
    statements = []

    def capture(connection, cursor, statement, parameters, context, executemany):
        statements.append(statement)

    event.listen(database, "before_cursor_execute", capture)
    try:
        with Session(database) as db, pytest.raises(HTTPException) as error:
            _link_responses([authorized, unrelated], 1, db)
    finally:
        event.remove(database, "before_cursor_execute", capture)
    assert error.value.status_code == 404
    assert error.value.detail == "Relationship not found"
    assert statements == []


def test_response_schema_preserves_existing_timestamp_encoding():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    link = EmergencyContactLink(
        id=7, inviter_user_id=1, invitee_user_id=2, status="pending",
        created_at=now, updated_at=now,
    )
    response = ContactLinkResponse(**_link_response(link, 1)).model_dump(mode="json")
    assert response["created_at"] == response["updated_at"] == "2026-01-01T00:00:00+00:00"
    assert response["responded_at"] is response["revoked_at"] is None


def test_openapi_documents_consistent_nullable_counterparty_schema(client):
    specification = client.app.openapi()
    schemas = specification["components"]["schemas"]
    assert set(schemas["OtherUserResponse"]["properties"]) == {"id", "name", "email"}
    assert schemas["OtherUserResponse"]["properties"]["id"]["type"] == "integer"
    assert set(schemas["ContactLinkResponse"]["properties"]) == {
        "id", "inviter_user_id", "invitee_user_id", "other_user_id", "status",
        "created_at", "updated_at", "responded_at", "revoked_at", "other_user",
    }
    assert schemas["ContactLinkResponse"]["properties"]["other_user"]["anyOf"] == [
        {"$ref": "#/components/schemas/OtherUserResponse"}, {"type": "null"},
    ]
    assert "other_user" in schemas["ContactLinkResponse"]["required"]
    for field in ("created_at", "updated_at"):
        assert schemas["ContactLinkResponse"]["properties"][field]["type"] == "string"
        assert schemas["ContactLinkResponse"]["properties"][field]["format"] == "date-time"
    for field in ("responded_at", "revoked_at"):
        assert schemas["ContactLinkResponse"]["properties"][field]["anyOf"] == [
            {"type": "string", "format": "date-time"}, {"type": "null"},
        ]
    for method, path, status_code, is_list in [
        ("post", "/contact-links/invites", "201", False),
        ("get", "/contact-links/invites/incoming", "200", True),
        ("get", "/contact-links/invites/outgoing", "200", True),
        ("get", "/contact-links/relationships", "200", True),
        ("post", "/contact-links/{link_id}/respond", "200", False),
        ("delete", "/contact-links/{link_id}", "200", False),
    ]:
        schema = specification["paths"][path][method]["responses"][status_code]["content"]["application/json"]["schema"]
        if is_list:
            assert schema["type"] == "array"
            schema = schema["items"]
        assert schema["$ref"] == "#/components/schemas/ContactLinkResponse"
