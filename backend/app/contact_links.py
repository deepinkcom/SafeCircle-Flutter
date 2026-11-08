
from collections.abc import Mapping, Sequence
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_serializer
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db
from .models import EmergencyContactLink, User
from .notification_events import record_connection_event


router = APIRouter(
    prefix="/contact-links",
    tags=["emergency-contact-links"],
)


class InvitationCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: str = Field(min_length=3, max_length=255)


class InvitationResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    action: str = Field(pattern="^(accept|reject)$")


class OtherUserResponse(BaseModel):
    id: int
    name: str
    email: str


class ContactLinkResponse(BaseModel):
    id: int
    inviter_user_id: int
    invitee_user_id: int
    other_user_id: int
    status: str
    created_at: datetime
    updated_at: datetime
    responded_at: datetime | None
    revoked_at: datetime | None
    other_user: OtherUserResponse | None

    @field_serializer("created_at", "updated_at", "responded_at", "revoked_at")
    def serialize_timestamp(self, value: datetime | None):
        # Preserve the pre-schema datetime.isoformat() response encoding.
        return value.isoformat() if value is not None else None


def _other_user_id(link: EmergencyContactLink, current_user_id: int) -> int:
    if current_user_id not in (link.inviter_user_id, link.invitee_user_id):
        raise HTTPException(status_code=404, detail="Relationship not found")
    return (
        link.invitee_user_id
        if link.inviter_user_id == current_user_id
        else link.inviter_user_id
    )


def _link_response(
    link: EmergencyContactLink,
    current_user_id: int,
    other_user: Mapping[str, object] | None = None,
) -> dict:
    other_user_id = _other_user_id(link, current_user_id)
    identity = None
    if (
        other_user is not None
        and other_user_id != current_user_id
        and other_user.get("id") == other_user_id
        and isinstance(other_user.get("name"), str)
        and isinstance(other_user.get("email"), str)
    ):
        identity = {
            "id": other_user_id,
            "name": other_user["name"],
            "email": other_user["email"],
        }

    return {
        "id": link.id,
        "status": link.status,
        "created_at": link.created_at,
        "updated_at": link.updated_at,
        "responded_at": link.responded_at,
        "revoked_at": link.revoked_at,
        "other_user_id": other_user_id,
        "inviter_user_id": link.inviter_user_id,
        "invitee_user_id": link.invitee_user_id,
        "other_user": identity,
    }


def _link_responses(
    links: Sequence[EmergencyContactLink],
    current_user_id: int,
    db: Session,
) -> list[dict]:
    # Authorize every row before querying identities. Never accept user IDs
    # supplied by a caller or fetch an unrelated profile as a fallback.
    other_ids = {_other_user_id(link, current_user_id) for link in links}
    other_ids.discard(current_user_id)
    identities = {}
    if other_ids:
        identities = {
            row["id"]: row
            for row in db.execute(
                select(User.id, User.name, User.email)
                .where(User.id.in_(other_ids))
            ).mappings()
        }
    return [
        _link_response(link, current_user_id, identities.get(_other_user_id(link, current_user_id)))
        for link in links
    ]


@router.post("/invites", status_code=201, response_model=ContactLinkResponse)
def send_invitation(
    invitation: InvitationCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    email = invitation.email.strip().lower()

    targets = db.scalars(
        select(User).where(func.lower(User.email) == email).limit(2)
    ).all()

    # Use the same exact, case-insensitive identity match as user discovery.
    # Legacy case variants must not select an arbitrary recipient.
    if len(targets) != 1:
        raise HTTPException(
            status_code=404,
            detail="SafeCircle user not found",
        )

    target_user = targets[0]

    if any(not getattr(target_user, field).strip() for field in ("name", "phone", "city")):
        raise HTTPException(status_code=404, detail="SafeCircle user not found")

    if target_user.id == current_user.id:
        raise HTTPException(
            status_code=400,
            detail="You cannot invite yourself",
        )

    existing_link = db.scalar(
        select(EmergencyContactLink).where(
            or_(
                (
                    EmergencyContactLink.inviter_user_id
                    == current_user.id
                )
                & (
                    EmergencyContactLink.invitee_user_id
                    == target_user.id
                ),
                (
                    EmergencyContactLink.inviter_user_id
                    == target_user.id
                )
                & (
                    EmergencyContactLink.invitee_user_id
                    == current_user.id
                ),
            ),
            EmergencyContactLink.status.in_(
                ["pending", "accepted"]
            ),
        )
    )

    if existing_link is not None:
        raise HTTPException(
            status_code=409,
            detail="An active relationship or invitation already exists",
        )

    link = EmergencyContactLink(
        inviter_user_id=current_user.id,
        invitee_user_id=target_user.id,
        status="pending",
    )

    try:
        db.add(link)
        db.flush()
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail="An active invitation already exists",
        )

    try:
        record_connection_event(
            db, link=link, recipient_user_id=target_user.id,
            event_type="connection.invited", created_at=link.created_at,
        )
        db.commit()
    except Exception:
        db.rollback()
        raise
    db.refresh(link)

    return _link_responses([link], current_user.id, db)[0]


@router.get("/invites/incoming", response_model=list[ContactLinkResponse])
def get_incoming_invitations(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    statement = (
        select(EmergencyContactLink)
        .where(
            EmergencyContactLink.invitee_user_id == current_user.id,
            EmergencyContactLink.status == "pending",
        )
        .order_by(EmergencyContactLink.created_at.desc())
    )

    links = db.scalars(statement).all()

    return _link_responses(links, current_user.id, db)


@router.get("/invites/outgoing", response_model=list[ContactLinkResponse])
def get_outgoing_invitations(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    statement = (
        select(EmergencyContactLink)
        .where(EmergencyContactLink.inviter_user_id == current_user.id)
        .order_by(
            EmergencyContactLink.created_at.desc(),
            EmergencyContactLink.id.desc(),
        )
    )

    links = db.scalars(statement).all()

    return _link_responses(links, current_user.id, db)


@router.get("/relationships", response_model=list[ContactLinkResponse])
def get_relationships(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    statement = (
        select(EmergencyContactLink)
        .where(
            or_(
                EmergencyContactLink.inviter_user_id
                == current_user.id,
                EmergencyContactLink.invitee_user_id
                == current_user.id,
            ),
            EmergencyContactLink.status == "accepted",
        )
        .order_by(EmergencyContactLink.updated_at.desc())
    )

    links = db.scalars(statement).all()

    return _link_responses(links, current_user.id, db)


@router.post("/{link_id}/respond", response_model=ContactLinkResponse)
def respond_to_invitation(
    link_id: int,
    response: InvitationResponse,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    link = db.scalar(
        select(EmergencyContactLink).where(
            EmergencyContactLink.id == link_id,
            EmergencyContactLink.invitee_user_id == current_user.id,
        ).with_for_update()
    )

    if link is None:
        raise HTTPException(
            status_code=404,
            detail="Invitation not found",
        )

    if link.status != "pending":
        raise HTTPException(
            status_code=409,
            detail="This invitation has already been processed",
        )

    now = datetime.now(timezone.utc)

    link.status = (
        "accepted"
        if response.action == "accept"
        else "rejected"
    )
    link.responded_at = now
    link.updated_at = now

    try:
        record_connection_event(
            db, link=link, recipient_user_id=link.inviter_user_id,
            event_type=f"connection.{link.status}", created_at=now,
        )
        db.commit()
    except Exception:
        db.rollback()
        raise
    db.refresh(link)

    return _link_responses([link], current_user.id, db)[0]


@router.delete("/{link_id}", response_model=ContactLinkResponse)
def revoke_relationship(
    link_id: int,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    link = db.scalar(
        select(EmergencyContactLink).where(
            EmergencyContactLink.id == link_id,
            or_(
                EmergencyContactLink.inviter_user_id
                == current_user.id,
                EmergencyContactLink.invitee_user_id
                == current_user.id,
            ),
        ).with_for_update()
    )

    if link is None:
        raise HTTPException(
            status_code=404,
            detail="Relationship not found",
        )

    if link.status not in ["pending", "accepted"]:
        raise HTTPException(
            status_code=409,
            detail="This relationship is no longer active",
        )

    now = datetime.now(timezone.utc)

    link.status = "revoked"
    link.revoked_at = now
    link.updated_at = now

    try:
        record_connection_event(
            db, link=link, recipient_user_id=_other_user_id(link, current_user.id),
            event_type="connection.revoked", created_at=now,
        )
        db.commit()
    except Exception:
        db.rollback()
        raise
    db.refresh(link)

    return _link_responses([link], current_user.id, db)[0]
