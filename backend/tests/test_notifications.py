"""Real API/SQLAlchemy transactions against disposable SQLite, synthetic auth."""

from datetime import datetime, timezone

import pytest
from sqlalchemy import func, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models import EmergencyContact, EmergencyContactLink, Notification, User
from app.notification_events import record_connection_event
from app.notifications import router

from test_contact_links import client, database, headers, invite, respond  # Shared real DB/auth fixtures.


@pytest.fixture
def inbox(client):
    client.app.include_router(router)
    return client


def get_page(inbox, user=1, **params):
    response = inbox.get("/notifications", headers=headers(user), params=params)
    assert response.status_code == 200
    return response.json()


def events(database):
    with Session(database) as db:
        return [dict(row) for row in db.execute(select(Notification.__table__).order_by(Notification.id)).mappings()]


def seed(database):
    # These are test-only records, including the reserved emergency category.
    with Session(database) as db:
        for id_, recipient, category, day, read in [
            (1, 1, "connection", 1, False), (2, 1, "emergency", 3, False),
            (3, 1, "connection", 3, True), (4, 2, "emergency", 5, False),
            (5, 1, "emergency", 2, False),
        ]:
            db.add(Notification(
                id=id_, recipient_user_id=recipient, category=category,
                event_type=f"{category}.synthetic_test", source_id=10 + id_,
                created_at=datetime(2026, 1, day, tzinfo=timezone.utc),
                read_at=datetime(2026, 1, 4, tzinfo=timezone.utc) if read else None,
                title="Synthetic test event", message="Test fixture only.",
            ))
        db.commit()


REQUESTS = [("GET", "/notifications", None), ("GET", "/notifications/unread-count", None),
            ("PATCH", "/notifications/1", {"read": True})]


@pytest.mark.parametrize("method,path,body", REQUESTS)
@pytest.mark.parametrize("auth", [None, "Basic synthetic", "Bearer invalid"])
def test_authentication_is_required(inbox, method, path, body, auth):
    response = inbox.request(method, path, headers={"Authorization": auth} if auth else {}, json=body)
    assert response.status_code == 401


@pytest.mark.parametrize("method,path,body", REQUESTS)
def test_verified_identity_without_backend_profile_is_forbidden(inbox, monkeypatch, method, path, body):
    monkeypatch.setattr("app.auth.firebase_auth.verify_id_token", lambda _: {"uid": "synthetic-missing-profile"})
    assert inbox.request(method, path, headers=headers(1), json=body).status_code == 403


def test_empty_response_and_cache_control(inbox):
    response = inbox.get("/notifications", headers=headers(1))
    assert response.json() == {"items": [], "total": 0, "limit": 20, "offset": 0, "has_more": False}
    assert response.headers["cache-control"] == "no-store"
    count = inbox.get("/notifications/unread-count", headers=headers(1))
    assert count.json() == {"unread_count": 0}
    assert count.headers["cache-control"] == "no-store"


def test_owner_pagination_chronology_and_tie_breaking(inbox, database):
    seed(database)
    first = get_page(inbox, limit=2)
    second = get_page(inbox, limit=2, offset=2)
    assert [row["id"] for row in first["items"]] == [3, 2]
    assert [row["id"] for row in second["items"]] == [5, 1]
    assert first["total"] == second["total"] == 4
    assert first["has_more"] is True and second["has_more"] is False
    assert get_page(inbox, offset=99)["items"] == []
    assert [row["id"] for row in get_page(inbox, user=2)["items"]] == [4]
    assert get_page(inbox, user=3)["total"] == 0
    # Unrecognized user parameters cannot override the verified recipient.
    assert get_page(inbox, user=2, recipient_user_id=1)["total"] == 1


def test_filtering_counts_and_reads_never_change_read_state(inbox, database):
    seed(database)
    before = events(database)
    assert [row["id"] for row in get_page(inbox, category="connection")["items"]] == [3, 1]
    assert [row["id"] for row in get_page(inbox, category="emergency")["items"]] == [2, 5]
    assert [row["id"] for row in get_page(inbox, unread_only=True)["items"]] == [2, 5, 1]
    assert [row["id"] for row in get_page(inbox, unread_only=True, category="connection")["items"]] == [1]
    for user, category, expected in [(1, None, 3), (1, "emergency", 2), (1, "connection", 1), (2, None, 1), (3, None, 0)]:
        result = inbox.get("/notifications/unread-count", headers=headers(user),
                           params={"category": category} if category else {})
        assert result.json() == {"unread_count": expected}
    assert events(database) == before


@pytest.mark.parametrize("query", ["limit=0", "limit=101", "limit=wrong", "offset=-1", "offset=1000001",
                                   "category=unknown", "unread_only=wrong"])
def test_invalid_queries_are_rejected(inbox, query):
    assert inbox.get(f"/notifications?{query}", headers=headers(1)).status_code == 422


def test_invalid_count_category(inbox):
    assert inbox.get("/notifications/unread-count?category=unknown", headers=headers(1)).status_code == 422


@pytest.mark.parametrize("body", [{}, {"read": None}, {"read": "true"}, {"read": 1},
    {"read": True, "recipient_user_id": 2}, {"read": True, "title": "forged"},
    {"read": True, "read_at": "2026-01-01T00:00:00Z"}])
def test_patch_is_strict_read_only_contract(inbox, database, body):
    seed(database)
    before = events(database)
    assert inbox.patch("/notifications/1", headers=headers(1), json=body).status_code == 422
    assert events(database) == before


def test_read_unread_idempotence_response_privacy_and_utc(inbox, database):
    seed(database)
    response = inbox.patch("/notifications/1", headers=headers(1), json={"read": True})
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    row = response.json()
    assert set(row) == {"id", "recipient_user_id", "category", "event_type", "source_id", "created_at", "read_at", "title", "message"}
    assert datetime.fromisoformat(row["created_at"]).utcoffset().total_seconds() == 0
    assert datetime.fromisoformat(row["read_at"]).utcoffset().total_seconds() == 0
    assert inbox.patch("/notifications/1", headers=headers(1), json={"read": True}).json() == row
    unread = inbox.patch("/notifications/1", headers=headers(1), json={"read": False}).json()
    assert unread == {**row, "read_at": None}
    assert inbox.patch("/notifications/1", headers=headers(1), json={"read": False}).json() == unread


def test_other_recipient_and_unknown_notification_are_indistinguishable(inbox, database):
    seed(database)
    before = events(database)
    other = inbox.patch("/notifications/1", headers=headers(2), json={"read": True})
    missing = inbox.patch("/notifications/999", headers=headers(2), json={"read": True})
    assert other.status_code == missing.status_code == 404
    assert other.json() == missing.json() == {"detail": "Notification not found"}
    assert events(database) == before


def test_invitation_is_persistent_recipient_only_and_has_safe_copy(inbox, database):
    link = invite(inbox).json()
    assert get_page(inbox, 1)["items"] == []
    assert get_page(inbox, 3)["items"] == []
    row = get_page(inbox, 2)["items"][0]
    assert (row["recipient_user_id"], row["category"], row["event_type"], row["source_id"]) == (2, "connection", "connection.invited", link["id"])
    assert row["read_at"] is None
    assert row["title"] == "SafeCircle invitation"
    assert "@" not in row["message"] and "0000000000" not in row["message"]
    assert len(events(database)) == 1  # A fresh DB session sees the committed event.
    assert invite(inbox).status_code == 409
    assert invite(inbox, 2, 1).status_code == 409
    assert invite(inbox, 1, 1).status_code == 400
    assert len(events(database)) == 1


@pytest.mark.parametrize("action,status", [("accept", "accepted"), ("reject", "rejected")])
def test_response_events_preserve_original_invitation_and_read_independence(inbox, database, action, status):
    link = invite(inbox).json()
    original = get_page(inbox, 2)["items"][0]
    read = inbox.patch(f"/notifications/{original['id']}", headers=headers(2), json={"read": True}).json()
    with Session(database) as db:
        assert db.get(EmergencyContactLink, link["id"]).status == "pending"
    assert respond(inbox, link["id"], action).json()["status"] == status
    assert get_page(inbox, 2)["items"] == [read]
    event = get_page(inbox, 1)["items"][0]
    assert (event["event_type"], event["source_id"], event["read_at"]) == (f"connection.{status}", link["id"], None)
    assert respond(inbox, link["id"], action).status_code == 409
    assert len(events(database)) == 2
    assert inbox.patch(f"/notifications/{original['id']}", headers=headers(2), json={"read": False}).status_code == 200
    with Session(database) as db:
        assert db.get(EmergencyContactLink, link["id"]).status == status


@pytest.mark.parametrize("accepted", [False, True])
@pytest.mark.parametrize("actor", [1, 2])
def test_revocation_notifies_other_participant_and_preserves_history(inbox, database, accepted, actor):
    link = invite(inbox).json()
    if accepted:
        assert respond(inbox, link["id"]).status_code == 200
    before = events(database)
    assert inbox.delete(f"/contact-links/{link['id']}", headers=headers(3)).status_code == 404
    assert events(database) == before
    assert inbox.delete(f"/contact-links/{link['id']}", headers=headers(actor)).status_code == 200
    after = events(database)
    assert after[:-1] == before
    assert (after[-1]["event_type"], after[-1]["recipient_user_id"], after[-1]["source_id"]) == ("connection.revoked", 3 - actor, link["id"])
    assert inbox.delete(f"/contact-links/{link['id']}", headers=headers(actor)).status_code == 409
    assert events(database) == after
    assert inbox.get("/contact-links/relationships", headers=headers(actor)).json() == []


def test_rejected_cannot_be_revoked_or_generate_another_event(inbox, database):
    link = invite(inbox).json()
    assert respond(inbox, link["id"], "reject").status_code == 200
    before = events(database)
    assert inbox.delete(f"/contact-links/{link['id']}", headers=headers(1)).status_code == 409
    assert events(database) == before


def test_new_invitation_after_terminal_status_has_distinct_source_event(inbox, database):
    first = invite(inbox).json()
    respond(inbox, first["id"], "reject")
    second = invite(inbox).json()
    assert first["id"] != second["id"]
    assert {row["source_id"] for row in get_page(inbox, 2)["items"]} == {first["id"], second["id"]}


def test_idempotent_producer_and_unique_constraint_do_not_reset_read_state(inbox, database):
    link = invite(inbox).json()
    original = get_page(inbox, 2)["items"][0]
    inbox.patch(f"/notifications/{original['id']}", headers=headers(2), json={"read": True})
    before = events(database)
    with Session(database) as db:
        event = record_connection_event(db, link=db.get(EmergencyContactLink, link["id"]),
            recipient_user_id=2, event_type="connection.invited", created_at=datetime.now(timezone.utc))
        assert event.id == original["id"]
        db.commit()
    assert events(database) == before
    with Session(database) as db:
        db.add(Notification(recipient_user_id=2, category="connection", event_type="connection.invited",
            source_id=link["id"], title="Duplicate", message="Must not persist."))
        with pytest.raises(IntegrityError):
            db.commit()
        db.rollback()
    assert events(database) == before


def test_producer_rejects_unrelated_recipient(inbox, database):
    link = invite(inbox).json()
    before = events(database)
    with Session(database) as db, pytest.raises(ValueError):
        record_connection_event(db, link=db.get(EmergencyContactLink, link["id"]), recipient_user_id=3,
            event_type="connection.invited", created_at=datetime.now(timezone.utc))
    assert events(database) == before


@pytest.mark.parametrize("operation", ["invite", "accept", "reject", "revoke_pending", "revoke_accepted"])
def test_notification_insert_failure_rolls_back_entire_relationship_operation(inbox, database, operation):
    link_id = None
    if operation != "invite":
        link_id = invite(inbox).json()["id"]
        if operation == "revoke_accepted":
            respond(inbox, link_id)
    with Session(database) as db:
        before_link = db.execute(select(EmergencyContactLink.__table__)).all()
        before_contacts = db.execute(select(EmergencyContact.__table__)).all()
    before_events = events(database)
    with database.begin() as connection:
        connection.execute(text("CREATE TRIGGER fail_notification BEFORE INSERT ON notifications "
                                "BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END"))
    with pytest.raises(IntegrityError):
        if operation == "invite":
            invite(inbox)
        elif operation in ("accept", "reject"):
            respond(inbox, link_id, operation)
        else:
            inbox.delete(f"/contact-links/{link_id}", headers=headers(1))
    assert events(database) == before_events
    with Session(database) as db:
        assert db.execute(select(EmergencyContactLink.__table__)).all() == before_link
        assert db.execute(select(EmergencyContact.__table__)).all() == before_contacts


def test_commit_failure_rolls_back_already_flushed_relationship_and_event(inbox, database, monkeypatch):
    def failed_commit(_):
        raise RuntimeError("Synthetic commit failure")
    monkeypatch.setattr(Session, "commit", failed_commit)
    with pytest.raises(RuntimeError, match="Synthetic commit failure"):
        invite(inbox)
    assert events(database) == []
    with Session(database) as db:
        assert db.scalar(select(func.count()).select_from(EmergencyContactLink)) == 0


def test_read_commit_failure_leaves_existing_event_unread(inbox, database, monkeypatch):
    invite(inbox)
    row = get_page(inbox, 2)["items"][0]
    def failed_commit(_):
        raise RuntimeError("Synthetic commit failure")
    monkeypatch.setattr(Session, "commit", failed_commit)
    with pytest.raises(RuntimeError):
        inbox.patch(f"/notifications/{row['id']}", headers=headers(2), json={"read": True})
    assert events(database)[0]["read_at"] is None


def test_notification_history_survives_source_deletion(inbox, database):
    link = invite(inbox).json()
    before = events(database)
    with Session(database) as db:
        db.delete(db.get(EmergencyContactLink, link["id"]))
        db.commit()
    assert events(database) == before


def test_router_registered_in_real_app():
    from app.main import app
    schema = app.openapi()
    assert "get" in schema["paths"]["/notifications"]
    assert "get" in schema["paths"]["/notifications/unread-count"]
    assert "patch" in schema["paths"]["/notifications/{notification_id}"]
