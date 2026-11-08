
from datetime import datetime
from typing import Annotated

from firebase_admin import auth as firebase_auth
from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field, StringConstraints
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .auth import get_current_user, get_db, initialize_firebase, bearer_scheme
from .models import User
from fastapi.security import HTTPAuthorizationCredentials


router = APIRouter(prefix="/users", tags=["users"])


class ProfileSyncRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1, max_length=255)
    city: str = Field(min_length=1, max_length=100)
    phone: str = Field(min_length=1, max_length=50)


class ProfileReadiness(BaseModel):
    id: int | None
    profile_ready: bool
    missing_fields: list[str]


def _missing_fields(user):
    return [field for field in ("name", "phone", "city")
            if user is None or not getattr(user, field).strip()]


def _identity(credentials):
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=401, detail="Missing Firebase ID token",
                            headers={"WWW-Authenticate": "Bearer"})
    try:
        initialize_firebase()
        claims = firebase_auth.verify_id_token(credentials.credentials)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired Firebase ID token",
                            headers={"WWW-Authenticate": "Bearer"})
    uid, email = claims.get("uid"), claims.get("email")
    if not isinstance(uid, str) or not uid.strip() or not isinstance(email, str) or not email.strip():
        raise HTTPException(status_code=401, detail="Firebase token must contain a UID and email")
    return uid, email.strip().lower()


def _check_email(user, email):
    if user is not None and user.email.strip().lower() != email:
        raise HTTPException(status_code=409, detail="The Firebase account email does not match its linked profile")


@router.get("/me", response_model=ProfileReadiness)
def my_profile_readiness(response: Response,
                         credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
                         db: Session = Depends(get_db)):
    uid, email = _identity(credentials)
    user = db.scalar(select(User).where(User.firebase_uid == uid))
    _check_email(user, email)
    response.headers["Cache-Control"] = "no-store"
    missing = _missing_fields(user)
    return {"id": user.id if user else None,
            "profile_ready": user is not None and not missing, "missing_fields": missing}


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
    if _missing_fields(current_user):
        raise HTTPException(status_code=403, detail="Complete your SafeCircle profile before discovery")
    if q.lower() == current_user.email.lower():
        return []

    matches = db.execute(
        select(User.name, User.email, User.phone, User.city)
        .where(func.lower(User.email) == q.lower(), User.id != current_user.id)
        .order_by(User.id)
        .limit(2)
    ).all()

    # The database's email uniqueness is case-sensitive. Fail closed if legacy
    # case variants would make an otherwise exact lookup ambiguous.
    if len(matches) != 1 or any(not getattr(matches[0], field).strip() for field in ("name", "phone", "city")):
        return []

    return [UserSearchResult(name=matches[0].name, email=matches[0].email)]


def _profile_response(user):
    return {field: getattr(user, field) for field in
            ("id", "firebase_uid", "name", "email", "city", "phone")}


@router.post("/me")
def sync_my_profile(
    profile: ProfileSyncRequest,
    response: Response,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: Session = Depends(get_db),
):
    firebase_uid, email = _identity(credentials)
    response.headers["Cache-Control"] = "no-store"
    if not profile.name.strip() or not profile.city.strip() or not profile.phone.strip():
        raise HTTPException(status_code=422, detail="Name, city and phone are required")

    # Existing rows change only through this explicit Personal Details action.
    # Registration/login/restoration use GET /me and never perform an upsert.
    existing = db.scalar(select(User).where(User.firebase_uid == firebase_uid).with_for_update())
    if existing is not None:
        _check_email(existing, email)
        try:
            existing.name = profile.name.strip()
            existing.city = profile.city.strip()
            existing.phone = profile.phone.strip()
            db.commit()
        except Exception:
            db.rollback()
            raise
        db.refresh(existing)
        return _profile_response(existing)

    owner = db.scalar(select(User).where(func.lower(User.email) == email))
    if owner is not None:
        if owner.firebase_uid == firebase_uid:
            # Another request committed between our UID lookup and this lookup.
            return _profile_response(owner)
        raise HTTPException(status_code=409, detail="This email belongs to another linked profile; no account was linked")
    user = User(firebase_uid=firebase_uid, email=email, name=profile.name.strip(),
                city=profile.city.strip(), phone=profile.phone.strip(), created_at=datetime.utcnow())
    try:
        db.add(user)
        db.commit()
    except IntegrityError:
        db.rollback()
        # A concurrent creation for the SAME verified UID is an idempotent
        # success. Return the winner without overwriting its profile fields.
        winner = db.scalar(select(User).where(User.firebase_uid == firebase_uid))
        if winner is not None:
            _check_email(winner, email)
            return _profile_response(winner)
        raise HTTPException(status_code=409, detail="The profile conflicts with an existing database record")
    except Exception:
        db.rollback()
        raise
    db.refresh(user)
    return _profile_response(user)
