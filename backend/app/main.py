from fastapi import FastAPI

from .alerts import router as alerts_router
from .contacts import router as contacts_router
from .devices import router as devices_router


app = FastAPI(
    title="SafeCircle API",
    version="0.1.0",
)


app.include_router(contacts_router)
app.include_router(alerts_router)
app.include_router(devices_router)


@app.get("/")
def root():
    return {"message": "SafeCircle API is running"}


@app.get("/health")
def health():
    return {"status": "ok"}
