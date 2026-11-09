"""Bound SDK delivery without changing Firebase configuration or using late threads."""
import multiprocessing
from types import SimpleNamespace

from firebase_admin import messaging

SUBMISSION_TIMEOUT_SECONDS = 20


def _submit(connection, token, notification_id, recipient_uid):
    from .notification_service import firebase_notification_delivery
    try:
        firebase_notification_delivery(token, SimpleNamespace(id=notification_id), recipient_uid)
        result = "sent"
    except messaging.UnregisteredError:
        result = "unregistered"
    except messaging.SenderIdMismatchError:
        result = "mismatch"
    except Exception:
        result = "failed"
    try:
        connection.send(result)
    finally:
        connection.close()


def bounded_firebase_delivery(token, notification, recipient_uid, *,
                              timeout=SUBMISSION_TIMEOUT_SECONDS, _target=_submit):
    if not 0 < timeout <= SUBMISSION_TIMEOUT_SECONDS:
        raise ValueError("Invalid push submission deadline")
    context = multiprocessing.get_context("spawn")
    receive, send = context.Pipe(duplex=False)
    child = context.Process(target=_target, args=(send, token, notification.id, recipient_uid), daemon=True)
    started = False
    try:
        child.start()
        started = True
        send.close()
        if not receive.poll(timeout):
            raise TimeoutError("Push submission deadline exceeded")
        try:
            result = receive.recv()
        except EOFError:
            raise RuntimeError("Push submission unavailable") from None
        if result == "unregistered":
            raise messaging.UnregisteredError("Registration unavailable")
        if result == "mismatch":
            raise messaging.SenderIdMismatchError("Registration unavailable")
        if result != "sent":
            raise RuntimeError("Push submission failed")
    finally:
        send.close()
        receive.close()
        if started:
            if child.is_alive():
                child.terminate()
            child.join(timeout=2)
            if child.is_alive():
                child.kill()
                child.join()  # Never unlock a registration with a live submitter.
            child.close()
