"""Arsenal HTTP response regressions using a local streaming server."""

import asyncio
import json
import unittest
import gzip

from test_arsenal import content  # Initialize the offline bot environment.
import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer

from arsenal_client import ArsenalApiError, ArsenalClient, MAX_RESPONSE_BYTES


class ArsenalResponseTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.raw = json.dumps({
            "schemaVersion": 1,
            "profile": {"key": "sd60-default"},
            "revision": {"number": 5},
            "arsenal": content([f"Fixture_Item_{index:04d}" for index in range(2000)]),
        }).encode("utf-8")
        self.split = 13_557
        self.status = 200
        self.length_header = False
        self.delay = 0.03
        self.gzip = False
        self.requests = 0
        self.release = None
        app = web.Application()
        app.router.add_route("*", "/{path:.*}", self._serve)
        self.server = TestServer(app)
        await self.server.start_server()
        # Only this fixture bypasses construction to inject a loopback session;
        # the production publisher URL allowlist and token loading stay intact.
        self.client = object.__new__(ArsenalClient)
        self.client.base_url = str(self.server.make_url("/")).rstrip("/")
        self.client._session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=2))

    async def asyncTearDown(self):
        if self.release is not None:
            self.release.set()
        await self.client.close()
        await self.server.close()

    async def _serve(self, request):
        self.requests += 1
        headers = {"Content-Type": "application/json"}
        if self.gzip:
            headers["Content-Encoding"] = "gzip"
        if self.length_header:
            headers["Content-Length"] = str(len(self.raw))
        response = web.StreamResponse(status=self.status, headers=headers)
        await response.prepare(request)
        try:
            await response.write(self.raw[:self.split])
            if self.release is not None:
                await self.release.wait()
            else:
                await asyncio.sleep(self.delay)
            await response.write(self.raw[self.split:])
            await response.write_eof()
        except ConnectionResetError:
            # Expected when an oversized or timed-out response is closed early.
            pass
        return response

    async def test_get_active_waits_for_all_chunks_of_a_large_snapshot(self):
        result = await self.client.get_active("sd60-default")
        self.assertEqual(result["revision"]["number"], 5)
        self.assertEqual(len(result["arsenal"]["allowedItems"]), 2000)
        self.assertEqual(result["arsenal"]["allowedItems"][-1], "Fixture_Item_1999")

    async def test_content_length_does_not_make_a_single_socket_read_complete(self):
        self.length_header = True
        result = await self.client.get_active("sd60-default")
        self.assertEqual(len(result["arsenal"]["allowedItems"]), 2000)

    async def test_split_utf8_character_is_decoded_after_the_complete_body(self):
        self.raw = json.dumps({"message": "Test α😀"}, ensure_ascii=False).encode("utf-8")
        self.split = self.raw.index("😀".encode("utf-8")) + 1
        self.assertEqual(await self.client._request("GET", "/fixture"), {"message": "Test α😀"})

    async def test_late_chunks_still_enforce_the_response_size_limit(self):
        self.raw = b'{"padding":"' + b"x" * MAX_RESPONSE_BYTES + b'"}'
        with self.assertRaises(ArsenalApiError) as raised:
            await self.client._request("GET", "/fixture")
        self.assertEqual(raised.exception.code, "RESPONSE_TOO_LARGE")

    async def test_response_at_the_size_limit_is_accepted(self):
        prefix, suffix = b'{"padding":"', b'"}'
        self.raw = prefix + b"x" * (MAX_RESPONSE_BYTES - len(prefix) - len(suffix)) + suffix
        result = await self.client._request("GET", "/fixture")
        self.assertEqual(len(result["padding"]), MAX_RESPONSE_BYTES - len(prefix) - len(suffix))

    async def test_compressed_response_limit_applies_to_decoded_bytes(self):
        self.gzip = True
        self.raw = gzip.compress(b'{"padding":"' + b"x" * MAX_RESPONSE_BYTES + b'"}')
        self.assertLess(len(self.raw), MAX_RESPONSE_BYTES)
        self.length_header = True
        self.split = len(self.raw) // 2
        with self.assertRaises(ArsenalApiError) as raised:
            await self.client._request("GET", "/fixture")
        self.assertEqual(raised.exception.code, "RESPONSE_TOO_LARGE")

    async def test_malformed_complete_json_is_rejected(self):
        self.raw = b'{"value":"really truncated'
        self.split = 8
        with self.assertRaises(ArsenalApiError) as raised:
            await self.client._request("GET", "/fixture")
        self.assertEqual(raised.exception.code, "INVALID_RESPONSE")

    async def test_fragmented_api_error_retains_status_and_code(self):
        self.status = 409
        self.raw = b'{"error":{"code":"REVISION_CONFLICT"}}'
        self.split = 12
        with self.assertRaises(ArsenalApiError) as raised:
            await self.client._request("POST", "/fixture", {"fixture": True})
        self.assertEqual((raised.exception.status, raised.exception.code), (409, "REVISION_CONFLICT"))
        self.assertEqual(self.requests, 1)

    async def test_late_response_timeout_is_not_replayed(self):
        await self.client._session.close()
        self.client._session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=0.1))
        self.release = asyncio.Event()
        with self.assertRaises(ArsenalApiError) as raised:
            await self.client._request("POST", "/fixture", {"fixture": True})
        self.assertEqual(raised.exception.code, "API_UNAVAILABLE")
        self.assertEqual(self.requests, 1)


if __name__ == "__main__":
    unittest.main()
