
from datetime import datetime
from typing import Annotated

from firebase_admin import auth as firebase_auth
from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db, initialize_firebase, bearer_scheme
from .models import User
from fastapi.security import HTTPAuthorizationCredentials


router = APIRouter(prefix="/users", tags=["users"])


class ProfileSyncRequest(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    city: str = Field(min_length=1, max_length=100)
    phone: str = Field(min_length=1, max_length=50)


SearchEmail = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=3,
        max_length=255,
        pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$",
    ),
]


class UserSearchResult(BaseModel):
    name: str
    email: str


@router.get(
    "/search",
    response_model=list[UserSearchResult],
    summary="Look up a registered user by complete email address",
)
def search_users(
    q: Annotated[SearchEmail, Query(description="Complete email address; case-insensitive exact lookup")],
    response: Response,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    response.headers["Cache-Control"] = "no-store"
    if q.lower() == current_user.email.lower():
        return []

    matches = db.execute(
        select(User.name, User.email)
        .where(func.lower(User.email) == q.lower(), User.id != current_user.id)
        .order_by(User.id)
        .limit(2)
    ).all()

    # The database's email uniqueness is case-sensitive. Fail closed if legacy
    # case variants would make an otherwise exact lookup ambiguous.
    if len(matches) != 1:
        return []

    return [UserSearchResult(name=matches[0].name, email=matches[0].email)]


@router.post("/me")
def sync_my_profile(
    profile: ProfileSyncRequest,
    credentials: HTTPAuthorizationCredentials | None = Depends(
        bearer_scheme
    ),
    db: Session = Depends(get_db),
):
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=401,
            detail="Missing Firebase ID token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        initialize_firebase()
        decoded_token = firebase_auth.verify_id_token(
            credentials.credentials
        )
    except Exception:
        raise HTTPException(
            status_code=401,
            detail="Invalid or expired Firebase ID token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    firebase_uid = decoded_token.get("uid")
    token_email = decoded_token.get("email")

    if not firebase_uid or not token_email:
        raise HTTPException(
            status_code=401,
            detail="Firebase token must contain a UID and email",
        )

    if not profile.name.strip() or not profile.city.strip() or not profile.phone.strip():
        raise HTTPException(
            status_code=422,
            detail="Name, city and phone are required",
        )

    email = token_email.strip().lower()

    existing_user = db.scalar(
        select(User).where(User.firebase_uid == firebase_uid)
    )

    if existing_user is not None:
        if existing_user.email.lower() != email:
            raise HTTPException(
                status_code=409,
                detail="The Firebase account email does not match its linked profile",
            )

        existing_user.name = profile.name.strip()
        existing_user.city = profile.city.strip()
        existing_user.phone = profile.phone.strip()
        db.commit()
        db.refresh(existing_user)

        return {
            "id": existing_user.id,
            "firebase_uid": existing_user.firebase_uid,
            "name": existing_user.name,
            "email": existing_user.email,
            "city": existing_user.city,
            "phone": existing_user.phone,
        }

    email_owner = db.scalar(
        select(User).where(User.email == email)
    )

    if email_owner is not None:
        raise HTTPException(
            status_code=409,
            detail=(
                "This email already belongs to a SafeCircle database profile. "
                "It has not been linked to a different Firebase account."
            ),
        )

    new_user = User(
        firebase_uid=firebase_uid,
        name=profile.name.strip(),
        email=email,
        city=profile.city.strip(),
        phone=profile.phone.strip(),
        created_at=datetime.utcnow(),
    )

    try:
        db.add(new_user)
        db.commit()
        db.refresh(new_user)
    except IntegrityError:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail="The profile conflicts with an existing database record",
        )

    return {
        "id": new_user.id,
        "firebase_uid": new_user.firebase_uid,
        "name": new_user.name,
        "email": new_user.email,
        "city": new_user.city,
        "phone": new_user.phone,
    }
