from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from .database import SessionLocal
from .models import EmergencyContact


router = APIRouter(prefix="/contacts", tags=["contacts"])


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class ContactCreate(BaseModel):
    name: str
    relationship: str
    phone: str
    enabled: bool = True


class ContactUpdate(BaseModel):
    name: str | None = None
    relationship: str | None = None
    phone: str | None = None
    enabled: bool | None = None


@router.get("")
def get_contacts(
    user_id: int = 1,
    db: Session = Depends(get_db),
):
    statement = select(EmergencyContact).where(
        EmergencyContact.user_id == user_id
    )
    contacts = db.scalars(statement).all()

    return [
        {
            "id": contact.id,
            "name": contact.name,
            "relationship": contact.relationship,
            "phone": contact.phone,
            "enabled": contact.enabled,
        }
        for contact in contacts
    ]


@router.post("")
def create_contact(
    contact_data: ContactCreate,
    user_id: int = 1,
    db: Session = Depends(get_db),
):
    contact = EmergencyContact(
        user_id=user_id,
        name=contact_data.name,
        relationship=contact_data.relationship,
        phone=contact_data.phone,
        enabled=contact_data.enabled,
    )

    db.add(contact)
    db.commit()
    db.refresh(contact)

    return {
        "id": contact.id,
        "name": contact.name,
        "relationship": contact.relationship,
        "phone": contact.phone,
        "enabled": contact.enabled,
    }


@router.patch("/{contact_id}")
def update_contact(
    contact_id: int,
    contact_data: ContactUpdate,
    user_id: int = 1,
    db: Session = Depends(get_db),
):
    statement = select(EmergencyContact).where(
        EmergencyContact.id == contact_id,
        EmergencyContact.user_id == user_id,
    )
    contact = db.scalar(statement)

    if contact is None:
        return {"error": "Contact not found"}

    updates = contact_data.model_dump(exclude_unset=True)

    for field, value in updates.items():
        setattr(contact, field, value)

    db.commit()
    db.refresh(contact)

    return {
        "id": contact.id,
        "name": contact.name,
        "relationship": contact.relationship,
        "phone": contact.phone,
        "enabled": contact.enabled,
    }
