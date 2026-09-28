"""Bounded client for the private SD60 Arsenal publisher API."""

import json
from pathlib import Path
from urllib.parse import quote

import aiohttp

from access import valid_profile
from arsenal_validation import content_to_json, validate_content

MAX_RESPONSE_BYTES = 768 * 1024


class ArsenalApiError(RuntimeError):
    def __init__(self, code: str, status: int):
        super().__init__(code)
        self.code = code
        self.status = status


def read_api_token(path: str) -> str:
    token_path = Path(path)
    if not token_path.is_file() or token_path.stat().st_size > 512:
        raise ValueError("Arsenal publisher token file is missing or too large")
    token = token_path.read_text(encoding="utf-8").strip()
    if not 64 <= len(token) <= 256 or not token.isascii() or any(character.isspace() for character in token):
        raise ValueError("Arsenal publisher token has an invalid format")
    return token


class ArsenalClient:
    def __init__(self, base_url: str, token_file: str, timeout_seconds: int):
        if base_url != "http://sd60-arsenal-publisher:3000":
            raise ValueError("Arsenal publisher URL is not allowlisted")
        self.base_url = base_url
        self._token = read_api_token(token_file)
        timeout = aiohttp.ClientTimeout(total=timeout_seconds, connect=min(3, timeout_seconds))
        self._session = aiohttp.ClientSession(
            timeout=timeout,
            connector=aiohttp.TCPConnector(limit=5, ttl_dns_cache=60),
            headers={"Authorization": f"Bearer {self._token}"},
            raise_for_status=False,
        )

    async def close(self) -> None:
        self._token = None
        await self._session.close()

    async def _request(self, method: str, path: str, payload: dict | None = None) -> dict:
        try:
            async with self._session.request(
                method,
                self.base_url + path,
                json=payload,
                allow_redirects=False,
            ) as response:
                raw = await response.content.read(MAX_RESPONSE_BYTES + 1)
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise ArsenalApiError("RESPONSE_TOO_LARGE", 502)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise ArsenalApiError("INVALID_RESPONSE", 502) from exc
                if not isinstance(body, dict):
                    raise ArsenalApiError("INVALID_RESPONSE", 502)
                if response.status >= 400:
                    error = body.get("error")
                    code = error.get("code") if isinstance(error, dict) else None
                    raise ArsenalApiError(code if isinstance(code, str) else "API_ERROR", response.status)
                return body
        except ArsenalApiError:
            raise
        except (aiohttp.ClientError, TimeoutError) as exc:
            raise ArsenalApiError("API_UNAVAILABLE", 503) from exc

    async def get_active(self, profile: str) -> dict:
        if not valid_profile(profile):
            raise ValueError("Invalid arsenal profile")
        body = await self._request(
            "GET", f"/v1/publisher/arsenal-profiles/{quote(profile, safe='')}/active"
        )
        profile_value = body.get("profile")
        revision = body.get("revision")
        if (body.get("schemaVersion") != 1 or not isinstance(profile_value, dict)
                or profile_value.get("key") != profile or not isinstance(revision, dict)
                or not isinstance(revision.get("number"), int)):
            raise ArsenalApiError("INVALID_RESPONSE", 502)
        body["arsenal"] = validate_content(body.get("arsenal"))
        return body

    async def publish(
        self,
        profile: str,
        expected_revision: int,
        event_id: str,
        guild_id: int,
        user_id: int,
        arsenal: dict,
    ) -> dict:
        if not valid_profile(profile) or expected_revision < 1:
            raise ValueError("Invalid publish target")
        # Round-trip through the canonical serializer before sending to ensure
        # the exact payload satisfies the same local bounds used for drafts.
        normalized = json.loads(content_to_json(arsenal))
        payload = {
            "expectedActiveRevision": expected_revision,
            "externalEventId": event_id,
            "actor": {
                "discordGuildId": str(guild_id),
                "discordUserId": str(user_id),
            },
            "arsenal": normalized,
        }
        body = await self._request(
            "POST",
            f"/v1/publisher/arsenal-profiles/{quote(profile, safe='')}/revisions",
            payload,
        )
        if (body.get("profileKey") != profile or not isinstance(body.get("revision"), int)):
            raise ArsenalApiError("INVALID_RESPONSE", 502)
        return body
