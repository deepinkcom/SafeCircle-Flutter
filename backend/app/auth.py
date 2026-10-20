import os
from pathlib import Path

from dotenv import load_dotenv
import firebase_admin
from firebase_admin import auth as firebase_auth
from firebase_admin import credentials
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from .database import BASE_DIR, SessionLocal
from .models import User


load_dotenv(BASE_DIR / ".env")

bearer_scheme = HTTPBearer(auto_error=False)


def initialize_firebase():
    if not firebase_admin._apps:
        service_account_path = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH")

        if not service_account_path:
            raise RuntimeError(
                "FIREBASE_SERVICE_ACCOUNT_PATH is not configured"
            )

        path = Path(service_account_path).expanduser()

        if not path.is_file():
            raise RuntimeError(
                "Firebase service-account file was not found"
            )

        credential = credentials.Certificate(str(path))
        firebase_admin.initialize_app(
            credential,
            {"projectId": "deepinkapp-124a6"},
        )


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_current_user(
    credentials_header: HTTPAuthorizationCredentials | None = Depends(
        bearer_scheme
    ),
    db: Session = Depends(get_db),
) -> User:
    if (
        credentials_header is None
        or credentials_header.scheme.lower() != "bearer"
    ):
        raise HTTPException(
            status_code=401,
            detail="Missing Firebase ID token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        initialize_firebase()
        decoded_token = firebase_auth.verify_id_token(
            credentials_header.credentials
        )
    except Exception:
        raise HTTPException(
            status_code=401,
            detail="Invalid or expired Firebase ID token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    firebase_uid = decoded_token.get("uid")
    if not firebase_uid:
        raise HTTPException(
            status_code=401,
            detail="Invalid Firebase identity",
        )

    user = db.scalar(
        select(User).where(User.firebase_uid == firebase_uid)
    )

    if user is None:
        raise HTTPException(
            status_code=403,
            detail=(
                "Firebase account is not linked to a SafeCircle "
                "user profile"
            ),
        )

    return user
