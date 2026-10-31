from collections.abc import Callable
from dataclasses import dataclass


@dataclass(frozen=True)
class NotificationResult:
    success: bool
    message_id: str | None = None
    error: str | None = None


Sender = Callable[[str, str, str], str]


def _not_configured_sender(
    token: str,
    title: str,
    body: str,
) -> str:
    raise RuntimeError("FCM sender is not configured")


def firebase_sender(
    token: str,
    title: str,
    body: str,
) -> str:
    """Send through Firebase Admin when explicitly configured."""
    from firebase_admin import messaging

    from .auth import initialize_firebase

    initialize_firebase()

    message = messaging.Message(
        notification=messaging.Notification(
            title=title,
            body=body,
        ),
        token=token,
    )

    return messaging.send(message)


class NotificationService:
    """Push notification service with an injectable sender for safe tests."""

    def __init__(self, sender: Sender | None = None) -> None:
        self._sender = sender or _not_configured_sender

    def send_to_token(
        self,
        token: str,
        title: str,
        body: str,
    ) -> NotificationResult:
        if not token or not token.strip():
            return NotificationResult(
                success=False,
                error="FCM token is empty",
            )

        if not title.strip() or not body.strip():
            return NotificationResult(
                success=False,
                error="Notification title and body are required",
            )

        try:
            message_id = self._sender(
                token.strip(),
                title.strip(),
                body.strip(),
            )
            return NotificationResult(
                success=True,
                message_id=message_id,
            )
        except Exception:
            # Never log tokens, location data, or provider exception details.
            return NotificationResult(
                success=False,
                error="Notification delivery failed",
            )
