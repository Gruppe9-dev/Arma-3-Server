"""Strict JSON validation for untrusted Discord arsenal imports."""

import json
import math
import re

MAX_IMPORT_BYTES = 512 * 1024
MAX_CONTENT_BYTES = 512 * 1024
MAX_ITEMS = 4096
MAX_KITS = 128
CLASS_NAME_RE = re.compile(r"[A-Za-z0-9_]{1,192}\Z")
IDENTIFIER_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
DISPLAY_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _().\[\]-]{0,127}\Z")
FORBIDDEN_KEYS = frozenset({"__proto__", "constructor", "prototype"})


class ArsenalValidationError(ValueError):
    """A safe validation failure suitable for a generic Discord response."""


def _parse_json(raw: bytes | str) -> object:
    if isinstance(raw, str):
        encoded = raw.encode("utf-8")
        text = raw
    elif isinstance(raw, bytes):
        encoded = raw
        try:
            text = raw.decode("utf-8-sig")
        except UnicodeDecodeError as exc:
            raise ArsenalValidationError("The import must use UTF-8 JSON.") from exc
    else:
        raise ArsenalValidationError("The import must be JSON text.")
    if not 0 < len(encoded) <= MAX_IMPORT_BYTES:
        raise ArsenalValidationError("The import must be between 1 byte and 512 KiB.")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise ArsenalValidationError("The import is not valid JSON.") from exc


def parse_item_payload(raw: bytes | str) -> tuple[list[str], int]:
    value = _parse_json(raw)
    if not isinstance(value, list) or not value:
        raise ArsenalValidationError("The item import must be a non-empty JSON array.")
    if len(value) > MAX_ITEMS:
        raise ArsenalValidationError(f"The item import exceeds {MAX_ITEMS} entries.")
    items = []
    seen = set()
    duplicates = 0
    for item in value:
        if not isinstance(item, str) or CLASS_NAME_RE.fullmatch(item) is None:
            raise ArsenalValidationError("Every item must be a valid Arma classname.")
        if item in seen:
            duplicates += 1
            continue
        seen.add(item)
        items.append(item)
    return items, duplicates


def parse_loadout_payload(raw: bytes | str) -> object:
    value = _parse_json(raw)
    _validate_loadout(value, depth=0, state={"nodes": 0})
    return value


def _validate_loadout(value: object, *, depth: int, state: dict[str, int]) -> None:
    state["nodes"] += 1
    if state["nodes"] > 10_000:
        raise ArsenalValidationError("The loadout exceeds the node limit.")
    if depth > 16:
        raise ArsenalValidationError("The loadout exceeds the nesting limit.")
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, (int, float)):
        if isinstance(value, float) and not math.isfinite(value):
            raise ArsenalValidationError("Loadout numbers must be finite.")
        return
    if isinstance(value, str):
        if len(value) > 512:
            raise ArsenalValidationError("A loadout string exceeds 512 characters.")
        return
    if isinstance(value, list):
        if len(value) > 512:
            raise ArsenalValidationError("A loadout array exceeds 512 entries.")
        for entry in value:
            _validate_loadout(entry, depth=depth + 1, state=state)
        return
    if isinstance(value, dict):
        if len(value) > 128:
            raise ArsenalValidationError("A loadout object contains too many keys.")
        for key, entry in value.items():
            if not isinstance(key, str) or key in FORBIDDEN_KEYS or len(key) > 128:
                raise ArsenalValidationError("The loadout contains a forbidden key.")
            _validate_loadout(entry, depth=depth + 1, state=state)
        return
    raise ArsenalValidationError("The loadout contains a non-JSON value.")


def validate_content(value: object) -> dict:
    if not isinstance(value, dict) or set(value) != {"allowedItems", "kits"}:
        raise ArsenalValidationError("The arsenal snapshot has an invalid shape.")
    items_value = value["allowedItems"]
    kits_value = value["kits"]
    if not isinstance(items_value, list) or not 1 <= len(items_value) <= MAX_ITEMS:
        raise ArsenalValidationError("The arsenal requires between 1 and 4096 items.")
    if not isinstance(kits_value, list) or not 1 <= len(kits_value) <= MAX_KITS:
        raise ArsenalValidationError("The arsenal requires between 1 and 128 kits.")

    items = []
    seen_items = set()
    for item in items_value:
        if not isinstance(item, str) or CLASS_NAME_RE.fullmatch(item) is None or item in seen_items:
            raise ArsenalValidationError("Arsenal item classnames must be valid and unique.")
        seen_items.add(item)
        items.append(item)

    kits = []
    seen_kits = set()
    for kit in kits_value:
        if not isinstance(kit, dict) or set(kit) != {"id", "displayName", "loadout"}:
            raise ArsenalValidationError("Every kit must contain id, displayName, and loadout only.")
        kit_id = kit["id"]
        display_name = kit["displayName"]
        if not isinstance(kit_id, str) or IDENTIFIER_RE.fullmatch(kit_id) is None or kit_id in seen_kits:
            raise ArsenalValidationError("Kit identifiers must be valid and unique.")
        if not isinstance(display_name, str) or DISPLAY_NAME_RE.fullmatch(display_name) is None:
            raise ArsenalValidationError("Kit display names contain unsupported characters.")
        _validate_loadout(kit["loadout"], depth=0, state={"nodes": 0})
        seen_kits.add(kit_id)
        kits.append({"id": kit_id, "displayName": display_name, "loadout": kit["loadout"]})

    normalized = {"allowedItems": items, "kits": kits}
    if len(json.dumps(normalized, separators=(",", ":"), ensure_ascii=False).encode("utf-8")) > MAX_CONTENT_BYTES:
        raise ArsenalValidationError("The complete arsenal snapshot exceeds 512 KiB.")
    return normalized


def content_to_json(content: object) -> str:
    normalized = validate_content(content)
    return json.dumps(normalized, separators=(",", ":"), ensure_ascii=False)


def content_from_json(raw: str) -> dict:
    return validate_content(_parse_json(raw))


def diff_content(active: dict, draft: dict) -> dict[str, object]:
    active = validate_content(active)
    draft = validate_content(draft)
    active_items = set(active["allowedItems"])
    draft_items = set(draft["allowedItems"])
    active_kits = {kit["id"]: kit for kit in active["kits"]}
    draft_kits = {kit["id"]: kit for kit in draft["kits"]}
    return {
        "added_items": sorted(draft_items - active_items),
        "removed_items": sorted(active_items - draft_items),
        "added_kits": sorted(set(draft_kits) - set(active_kits)),
        "removed_kits": sorted(set(active_kits) - set(draft_kits)),
        "changed_kits": sorted(
            kit_id for kit_id in set(active_kits) & set(draft_kits)
            if active_kits[kit_id] != draft_kits[kit_id]
        ),
    }
