"""Exercise actual spawned processes without Firebase credentials or network."""
import multiprocessing
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from firebase_admin import messaging

from app.push_submission import bounded_firebase_delivery


def child_success(connection, token, notification_id, recipient_uid, category, event_type):
    connection.send("sent")
    connection.close()


def child_invalid(connection, token, notification_id, recipient_uid, category, event_type):
    connection.send("unregistered")
    connection.close()


def child_failure(connection, token, notification_id, recipient_uid, category, event_type):
    connection.send("failed")
    connection.close()


def child_delayed_write(connection, token, notification_id, recipient_uid, category, event_type):
    time.sleep(1)
    Path(recipient_uid).write_text("late synthetic side effect")
    connection.send("sent")


def child_requires_emergency(connection, token, notification_id, recipient_uid, category, event_type):
    connection.send(
        "sent" if (category, event_type) == ("emergency", "emergency.panic") else "failed"
    )
    connection.close()


@pytest.mark.parametrize("target,error", [(child_success, None), (child_invalid, messaging.UnregisteredError),
                                          (child_failure, RuntimeError)])
def test_child_result_is_classified_without_provider_details(target, error):
    kwargs = dict(timeout=10, _target=target)
    if error:
        with pytest.raises(error):
            bounded_firebase_delivery("synthetic-device", SimpleNamespace(id=1), "synthetic-uid", **kwargs)
    else:
        bounded_firebase_delivery("synthetic-device", SimpleNamespace(id=1), "synthetic-uid", **kwargs)


def test_timeout_stops_and_joins_submitter_before_returning(tmp_path):
    marker = tmp_path / "late-effect.txt"
    before = {p.pid for p in multiprocessing.active_children()}
    start = time.monotonic()
    with pytest.raises(TimeoutError):
        bounded_firebase_delivery("synthetic-device", SimpleNamespace(id=1), str(marker),
                                  timeout=0.2, _target=child_delayed_write)
    assert time.monotonic() - start < 5
    assert {p.pid for p in multiprocessing.active_children()} == before
    time.sleep(1.2)
    assert not marker.exists()


def test_emergency_event_type_is_passed_to_bounded_sender():
    bounded_firebase_delivery(
        "synthetic-device",
        SimpleNamespace(
            id=1,
            category="emergency",
            event_type="emergency.panic",
        ),
        "synthetic-uid",
        timeout=10,
        _target=child_requires_emergency,
    )
