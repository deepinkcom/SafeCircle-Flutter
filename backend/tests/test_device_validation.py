from pydantic import ValidationError

from app.devices import DeviceCreate


def test_valid_device_input_is_normalised():
    device = DeviceCreate(
        fcm_token=" fake-token ",
        platform=" ANDROID ",
    )

    assert device.fcm_token == "fake-token"
    assert device.platform == "android"


def test_blank_token_is_rejected():
    try:
        DeviceCreate(fcm_token="   ", platform="android")
        assert False, "Blank token should be rejected"
    except ValidationError:
        pass


def test_unsupported_platform_is_rejected():
    try:
        DeviceCreate(fcm_token="fake-token", platform="windows")
        assert False, "Unsupported platform should be rejected"
    except ValidationError:
        pass


def test_unexpected_fields_are_rejected():
    try:
        DeviceCreate(
            fcm_token="fake-token",
            platform="ios",
            extra="not allowed",
        )
        assert False, "Unexpected field should be rejected"
    except ValidationError:
        pass
