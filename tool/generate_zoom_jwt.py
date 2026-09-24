"""Generate a short-lived Meeting SDK JWT locally for the iOS demo."""

import base64
import getpass
import hashlib
import hmac
import json
import time


def encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def main():
    client_id = input("Zoom Development Client ID: ").strip()
    secret = getpass.getpass("Zoom Development Client Secret (hidden): ").strip()
    if not client_id or not secret:
        raise SystemExit("Client ID and Client Secret are required.")

    issued_at = int(time.time()) - 30
    expires_at = issued_at + 7200
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "appKey": client_id,
        "iat": issued_at,
        "exp": expires_at,
        "tokenExp": expires_at,
    }
    message = ".".join(
        encode(json.dumps(item, separators=(",", ":")).encode())
        for item in (header, payload)
    )
    signature = hmac.new(secret.encode(), message.encode(), hashlib.sha256).digest()
    print("\nMeeting SDK JWT (valid for about 2 hours):\n")
    print(f"{message}.{encode(signature)}")


if __name__ == "__main__":
    main()
