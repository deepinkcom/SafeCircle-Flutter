from fastapi import FastAPI, HTTPException
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from .database import engine
from .alerts import router as alerts_router
from .contacts import router as contacts_router
from .devices import router as devices_router
from .test_notifications import router as test_notifications_router
from .users import router as users_router
from .contact_links import router as contact_links_router
from .notifications import router as notifications_router

app = FastAPI(
    title="SafeCircle API",
    version="0.1.0",
)

app.include_router(contacts_router)
app.include_router(alerts_router)
app.include_router(devices_router)
app.include_router(test_notifications_router)
app.include_router(users_router)
app.include_router(contact_links_router)
app.include_router(notifications_router)


@app.get("/")
def root():
    return {"message": "SafeCircle API is running"}


@app.get("/health")
def health():
    """Liveness probe: confirms the API process can serve requests."""
    return {"status": "ok"}


@app.get("/health/ready")
def readiness():
    """Readiness probe: only admit traffic when the configured DB responds."""
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
    except SQLAlchemyError:
        raise HTTPException(status_code=503, detail="Database unavailable")
    return {"status": "ready", "database": "ok"}
