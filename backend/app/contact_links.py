
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db
from .models import EmergencyContactLink, User


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


def _link_response(
    link: EmergencyContactLink,
    current_user_id: int,
) -> dict:
    other_user_id = (
        link.invitee_user_id
        if link.inviter_user_id == current_user_id
        else link.inviter_user_id
    )

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
    }


@router.post("/invites", status_code=201)
def send_invitation(
    invitation: InvitationCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    email = invitation.email.strip().lower()

    target_user = db.scalar(
        select(User).where(User.email == email)
    )

    if target_user is None:
        raise HTTPException(
            status_code=404,
            detail="SafeCircle user not found",
        )

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
        db.commit()
        db.refresh(link)
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail="An active invitation already exists",
        )

    return _link_response(link, current_user.id)


@router.get("/invites/incoming")
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

    return [
        _link_response(link, current_user.id)
        for link in links
    ]


@router.get("/relationships")
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

    return [
        _link_response(link, current_user.id)
        for link in links
    ]


@router.post("/{link_id}/respond")
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
        )
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

    now = datetime.utcnow()

    link.status = (
        "accepted"
        if response.action == "accept"
        else "rejected"
    )
    link.responded_at = now
    link.updated_at = now

    db.commit()
    db.refresh(link)

    return _link_response(link, current_user.id)


@router.delete("/{link_id}")
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
        )
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

    now = datetime.utcnow()

    link.status = "revoked"
    link.revoked_at = now
    link.updated_at = now

    db.commit()
    db.refresh(link)

    return _link_response(link, current_user.id)
