
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db
from .models import EmergencyContact, User


router = APIRouter(prefix="/contacts", tags=["contacts"])


class ContactCreate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    relationship: str = Field(min_length=1, max_length=100)
    phone: str = Field(min_length=1, max_length=50)
    enabled: bool = True


class ContactUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str | None = Field(default=None, min_length=1, max_length=255)
    relationship: str | None = Field(
        default=None, min_length=1, max_length=100
    )
    phone: str | None = Field(default=None, min_length=1, max_length=50)
    enabled: bool | None = None


def _contact_response(contact: EmergencyContact) -> dict:
    return {
        "id": contact.id,
        "name": contact.name,
        "relationship": contact.relationship,
        "phone": contact.phone,
        "enabled": contact.enabled,
    }


@router.get("")
def get_contacts(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    statement = select(EmergencyContact).where(
        EmergencyContact.user_id == current_user.id
    )
    contacts = db.scalars(statement).all()
    return [_contact_response(contact) for contact in contacts]


@router.post("")
def create_contact(
    contact_data: ContactCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    contact = EmergencyContact(
        user_id=current_user.id,
        name=contact_data.name.strip(),
        relationship=contact_data.relationship.strip(),
        phone=contact_data.phone.strip(),
        enabled=contact_data.enabled,
    )

    db.add(contact)
    db.commit()
    db.refresh(contact)
    return _contact_response(contact)


@router.patch("/{contact_id}")
def update_contact(
    contact_id: int,
    contact_data: ContactUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    statement = select(EmergencyContact).where(
        EmergencyContact.id == contact_id,
        EmergencyContact.user_id == current_user.id,
    )
    contact = db.scalar(statement)

    if contact is None:
        raise HTTPException(status_code=404, detail="Contact not found")

    updates = contact_data.model_dump(exclude_unset=True)

    for field, value in updates.items():
        if isinstance(value, str):
            value = value.strip()
            if not value:
                raise HTTPException(
                    status_code=422,
                    detail=f"{field} cannot be empty",
                )
        setattr(contact, field, value)

    db.commit()
    db.refresh(contact)
    return _contact_response(contact)
