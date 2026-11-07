from datetime import datetime

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import Session

from app.auth import get_db
from app.contact_links import router as contact_links_router
from app.models import EmergencyContact, EmergencyContactLink, User
from app.users import router


def headers(user=1):
    return {"Authorization": f"Bearer synthetic-search-user-{user}"}


@pytest.fixture
def database(tmp_path):
    engine = create_engine(
        f"sqlite+pysqlite:///{tmp_path / 'user_search.db'}",
        connect_args={"check_same_thread": False},
    )

    @event.listens_for(engine, "connect")
    def enable_foreign_keys(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")

    for model in (User, EmergencyContact, EmergencyContactLink):
        model.__table__.create(engine)
    with Session(engine) as db:
        db.add_all([
            User(
                id=i, firebase_uid=f"synthetic-search-uid-{i}",
                name=name, email=email, city="Private city", phone="0000000000",
                created_at=datetime(2026, 1, 1),
            )
            for i, name, email in [
                (1, "Caller", "caller@example.invalid"),
                (2, "Invitee", "invitee@example.invalid"),
                (3, "Another invitee", "invitee.other@example.invalid"),
            ]
        ])
        db.flush()
        db.add(EmergencyContact(
            user_id=1, name="Phone-only contact", relationship="Friend",
            phone="0000000000", enabled=True,
        ))
        db.commit()
    yield engine
    engine.dispose()


@pytest.fixture
def client(database, monkeypatch):
    app = FastAPI()
    app.include_router(router)
    app.include_router(contact_links_router)

    def test_db():
        with Session(database) as db:
            yield db

    def verify_synthetic_identity(token):
        if token == "synthetic-unlinked-search-user":
            return {"uid": "synthetic-unlinked-search-uid"}
        for i in (1, 2, 3):
            if token == f"synthetic-search-user-{i}":
                return {"uid": f"synthetic-search-uid-{i}",
                        "email": "caller@example.invalid" if i == 1 else f"user{i}@example.invalid"}
        raise ValueError("Invalid synthetic test identity")

    app.dependency_overrides[get_db] = test_db
    monkeypatch.setattr("app.auth.initialize_firebase", lambda: None)
    monkeypatch.setattr("app.users.initialize_firebase", lambda: None)
    monkeypatch.setattr("app.auth.firebase_auth.verify_id_token", verify_synthetic_identity)
    with TestClient(app) as test_client:
        yield test_client


def search(client, query, **params):
    return client.get("/users/search", params={"q": query, **params}, headers=headers())


def snapshot(database):
    with database.connect() as connection:
        return {
            model.__tablename__: connection.execute(
                select(model.__table__).order_by(model.id)
            ).all()
            for model in (User, EmergencyContact, EmergencyContactLink)
        }


@pytest.mark.parametrize("query", [
    "invitee@example.invalid", "INVITEE@EXAMPLE.INVALID", " Invitee@Example.Invalid ",
])
def test_exact_email_search_is_case_insensitive_and_trimmed(client, query):
    response = search(client, query)
    assert response.status_code == 200
    assert response.json() == [{"name": "Invitee", "email": "invitee@example.invalid"}]
    assert response.headers["cache-control"] == "no-store"


def test_search_handles_mixed_case_stored_email(client, database):
    with Session(database) as db:
        db.get(User, 2).email = "Invitee@Example.Invalid"
        db.commit()
    response = search(client, "INVITEE@EXAMPLE.INVALID")
    assert response.status_code == 200
    assert response.json() == [{"name": "Invitee", "email": "Invitee@Example.Invalid"}]


@pytest.mark.parametrize("query", ["caller@example.invalid", "CALLER@EXAMPLE.INVALID"])
def test_search_excludes_authenticated_user(client, query):
    response = search(client, query)
    assert response.status_code == 200
    assert response.json() == []


def test_unknown_user_returns_empty_list(client):
    response = search(client, "unknown@example.invalid")
    assert response.status_code == 200
    assert response.json() == []


@pytest.mark.parametrize("auth_headers,expected", [
    ({}, 401),
    ({"Authorization": "Basic synthetic-value"}, 401),
    ({"Authorization": "Bearer invalid-synthetic-search-user"}, 401),
    ({"Authorization": "Bearer synthetic-unlinked-search-user"}, 403),
])
def test_search_requires_valid_linked_firebase_identity(client, auth_headers, expected):
    response = client.get(
        "/users/search", params={"q": "invitee@example.invalid"}, headers=auth_headers,
    )
    assert response.status_code == expected
    assert "Invitee" not in response.text


@pytest.mark.parametrize("query", [
    "", " ", "ab", "Invitee", "inv", "invitee@", "@example.invalid",
    "invitee@example", "invitee@@example.invalid", "invitee @example.invalid",
    "invitee@example.invalid extra", "%", "_", "*", "example.invalid",
    "a" * 256 + "@example.invalid", "x' OR 1=1 --@example.invalid",
])
def test_invalid_partial_or_broad_search_is_rejected(client, query):
    response = search(client, query)
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], list)


def test_search_term_is_required(client):
    assert client.get("/users/search", headers=headers()).status_code == 422


@pytest.mark.parametrize("query", [
    "%@example.invalid", "invitee%@example.invalid", "invitee_@example.invalid",
    "*@example.invalid", "x'OR'1'='1@example.invalid",
])
def test_wildcards_and_sql_metacharacters_never_expand_search(client, query):
    response = search(client, query)
    assert response.status_code == 200
    assert response.json() == []


def test_search_discloses_only_name_and_already_supplied_email(client):
    response = search(client, "invitee@example.invalid")
    assert response.status_code == 200
    assert set(response.json()[0]) == {"name", "email"}
    for value in ("firebase_uid", "synthetic-search-uid", "Private city", "0000000000", "created_at"):
        assert value not in response.text


@pytest.mark.parametrize("extra_params", [{}, {"limit": 10000}, {"offset": 1}, {"page": 2}])
def test_result_cap_cannot_be_expanded_or_paged(client, extra_params):
    response = search(client, "invitee@example.invalid", **extra_params)
    assert response.status_code == 200
    assert response.json() == [{"name": "Invitee", "email": "invitee@example.invalid"}]


def test_case_variant_duplicate_accounts_fail_closed(client, database):
    with Session(database) as db:
        db.get(User, 3).email = "INVITEE@example.invalid"
        db.commit()
    response = search(client, "invitee@example.invalid")
    assert response.status_code == 200
    assert response.json() == []


def test_own_email_stays_hidden_even_with_another_case_variant_profile(client, database):
    with Session(database) as db:
        db.get(User, 3).email = "CALLER@example.invalid"
        db.commit()
    response = search(client, "caller@example.invalid")
    assert response.status_code == 200
    assert response.json() == []


def test_search_never_changes_profiles_contacts_or_relationships(client, database):
    before = snapshot(database)
    for query in ("invitee@example.invalid", "caller@example.invalid", "unknown@example.invalid"):
        assert search(client, query).status_code == 200
    assert snapshot(database) == before


@pytest.mark.parametrize("stored_email", ["invitee@example.invalid", "Invitee@Example.Invalid"])
def test_discovered_email_can_be_used_by_existing_invitation_api(client, database, stored_email):
    with Session(database) as db:
        db.get(User, 2).email = stored_email
        db.commit()
    found = search(client, "INVITEE@EXAMPLE.INVALID")
    assert found.status_code == 200
    response = client.post(
        "/contact-links/invites", headers=headers(),
        json={"email": found.json()[0]["email"]},
    )
    assert response.status_code == 201
    assert response.json()["status"] == "pending"
    assert response.json()["invitee_user_id"] == 2


def test_ambiguous_email_cannot_select_an_arbitrary_invitation_recipient(client, database):
    with Session(database) as db:
        db.get(User, 3).email = "INVITEE@example.invalid"
        db.commit()
    response = client.post(
        "/contact-links/invites", headers=headers(),
        json={"email": "invitee@example.invalid"},
    )
    assert response.status_code == 404
    assert response.json() == {"detail": "SafeCircle user not found"}
    with Session(database) as db:
        assert db.scalars(select(EmergencyContactLink)).all() == []


def test_profile_sync_still_updates_own_profile_after_search(client, database):
    assert search(client, "invitee@example.invalid").status_code == 200
    response = client.post("/users/me", headers=headers(), json={
        "name": "Updated caller", "city": "Updated city", "phone": "0000000001",
    })
    assert response.status_code == 200
    assert response.json()["id"] == 1
    assert response.json()["name"] == "Updated caller"
    with Session(database) as db:
        assert db.get(User, 1).city == "Updated city"
        assert db.get(User, 2).name == "Invitee"
