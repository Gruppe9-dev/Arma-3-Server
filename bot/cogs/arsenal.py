"""Discord draft and publish workflow for SD60 Arsenal snapshots."""

import asyncio
import json
import logging
from pathlib import PurePath
from typing import Literal

import discord
from discord import app_commands
from discord.ext import commands

import config
import utils
from access import valid_profile
from arsenal_client import ArsenalApiError, ArsenalClient
from arsenal_validation import (
    CLASS_NAME_RE,
    DISPLAY_NAME_RE,
    IDENTIFIER_RE,
    MAX_IMPORT_BYTES,
    ArsenalValidationError,
    content_from_json,
    content_to_json,
    diff_content,
    parse_item_payload,
    parse_loadout_payload,
    validate_content,
)

log = logging.getLogger(__name__)

PROFILE_DISPLAY_NAMES = {
    "sd60-default": "60th",
}

PROFILE_INPUT_ALIASES = {
    "60th": "sd60-default",
}


def _profile_display_name(profile: str) -> str:
    return PROFILE_DISPLAY_NAMES.get(profile, profile)


def _profile_key(value: str) -> str:
    normalized = value.strip()
    return PROFILE_INPUT_ALIASES.get(normalized.casefold(), normalized)


def _diff_text(diff: dict[str, object]) -> str:
    added_items = diff["added_items"]
    removed_items = diff["removed_items"]
    added_kits = diff["added_kits"]
    removed_kits = diff["removed_kits"]
    changed_kits = diff["changed_kits"]
    lines = [
        f"Items: +{len(added_items)} / -{len(removed_items)}",
        f"Kits: +{len(added_kits)} / -{len(removed_kits)} / ~{len(changed_kits)}",
    ]
    for label, values in (
        ("Added items", added_items),
        ("Removed items", removed_items),
        ("Added kits", added_kits),
        ("Removed kits", removed_kits),
        ("Changed kits", changed_kits),
    ):
        if values:
            sample = ", ".join(f"`{value}`" for value in values[:10])
            suffix = f" (+{len(values) - 10} more)" if len(values) > 10 else ""
            lines.append(f"{label}: {sample}{suffix}")
    return "\n".join(lines)[:1900]


def _has_changes(diff: dict[str, object]) -> bool:
    return any(bool(values) for values in diff.values())


class PublishConfirmationView(discord.ui.View):
    def __init__(self, cog, owner_id: int, guild_id: int, profile: str, version: int):
        super().__init__(timeout=120)
        self.cog = cog
        self.owner_id = owner_id
        self.guild_id = guild_id
        self.profile = profile
        self.version = version

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id == self.owner_id and interaction.guild_id == self.guild_id:
            return True
        await interaction.response.send_message(
            "Only the user who requested this publication can confirm it.", ephemeral=True
        )
        return False

    @discord.ui.button(label="Publish revision", style=discord.ButtonStyle.danger)
    async def confirm(self, interaction: discord.Interaction, button: discord.ui.Button):
        button.disabled = True
        await interaction.response.defer()
        message = await self.cog.publish_confirmed(
            interaction, self.profile, self.version
        )
        self.stop()
        await interaction.edit_original_response(content=message, view=None)

    @discord.ui.button(label="Cancel", style=discord.ButtonStyle.secondary)
    async def cancel(self, interaction: discord.Interaction, button: discord.ui.Button):
        button.disabled = True
        self.stop()
        await interaction.response.edit_message(content="Publication cancelled. The draft was kept.", view=None)


class ArsenalCog(commands.Cog):
    arsenal = app_commands.Group(name="arsenal", description="Manage versioned SD60 Arsenal content")
    items = app_commands.Group(name="items", description="Manage the draft item whitelist", parent=arsenal)
    kits = app_commands.Group(name="kits", description="Manage draft loadout kits", parent=arsenal)

    def __init__(self, bot):
        self.bot = bot
        self.client = ArsenalClient(
            config.ARSENAL_API_URL,
            config.ARSENAL_API_TOKEN_FILE,
            config.ARSENAL_TIMEOUT_SECONDS,
        )
        self._locks: dict[str, asyncio.Lock] = {}

    async def cog_unload(self):
        await self.client.close()

    def _lock(self, profile: str) -> asyncio.Lock:
        return self._locks.setdefault(profile, asyncio.Lock())

    async def _profile_choices(self, interaction: discord.Interaction, current: str):
        if config.ACCESS_POLICY:
            profiles = config.ACCESS_POLICY.arsenal_profiles.get(interaction.guild_id, {})
        else:
            profiles = config.ARSENAL_PROFILES if utils.has_admin_auth(interaction) else ()
        return [
            app_commands.Choice(
                name=_profile_display_name(profile),
                value=_profile_display_name(profile),
            )
            for profile in profiles
            if (
                current.lower() in profile.lower()
                or current.lower() in _profile_display_name(profile).lower()
            )
            and utils.can_access_arsenal(interaction, "view", profile)
        ][:25]

    @staticmethod
    async def _read_input(data: str | None, attachment: discord.Attachment | None) -> bytes | str:
        if (data is None) == (attachment is None):
            raise ArsenalValidationError("Provide exactly one JSON string or one JSON/TXT attachment.")
        if data is not None:
            return data
        if attachment is None:
            raise ArsenalValidationError("An attachment is required.")
        if attachment.size <= 0 or attachment.size > MAX_IMPORT_BYTES:
            raise ArsenalValidationError("The attachment must be between 1 byte and 512 KiB.")
        if PurePath(attachment.filename).suffix.lower() not in {".json", ".txt"}:
            raise ArsenalValidationError("Only JSON or TXT attachments are accepted.")
        try:
            payload = await attachment.read(use_cached=False)
        except discord.HTTPException as direct_error:
            try:
                payload = await attachment.read(use_cached=True)
            except discord.HTTPException as cached_error:
                log.warning(
                    "Discord attachment download failed attachment_id=%s size=%s "
                    "direct_status=%s cached_status=%s",
                    getattr(attachment, "id", "unknown"),
                    attachment.size,
                    getattr(direct_error, "status", "unknown"),
                    getattr(cached_error, "status", "unknown"),
                )
                raise cached_error from direct_error
        if len(payload) != attachment.size or len(payload) > MAX_IMPORT_BYTES:
            raise ArsenalValidationError("The attachment size changed or exceeds 512 KiB.")
        return payload

    async def _reauthorize(self, interaction: discord.Interaction, action: str, profile: str) -> bool:
        if interaction.guild is None:
            return False
        try:
            interaction.user = await interaction.guild.fetch_member(interaction.user.id)
        except (discord.NotFound, discord.Forbidden, discord.HTTPException):
            return False
        return utils.can_access_arsenal(interaction, action, profile)

    def _stored_draft(self, profile: str, guild_id: int):
        draft = self.bot.store.arsenal_draft(profile)
        if draft is not None and draft.guild_id != guild_id:
            raise ArsenalValidationError("This profile has a draft owned by another Discord server.")
        return draft

    async def _active_and_draft(self, profile: str, guild_id: int):
        active = await self.client.get_active(profile)
        stored = self._stored_draft(profile, guild_id)
        content = content_from_json(stored.content_json) if stored else active["arsenal"]
        return active, stored, content

    async def _save_mutation(self, interaction, profile: str, mutate):
        async with self._lock(profile):
            active, stored, content = await self._active_and_draft(profile, interaction.guild_id)
            base_revision = stored.base_revision if stored else active["revision"]["number"]
            if base_revision != active["revision"]["number"]:
                raise ArsenalValidationError(
                    "The draft is based on an older active revision. Discard it before editing again."
                )
            updated, detail = mutate(content)
            updated = validate_content(updated)
            if not await self._reauthorize(interaction, "edit", profile):
                raise PermissionError("Arsenal edit access changed while the request was running.")
            saved = self.bot.store.save_arsenal_draft(
                profile,
                interaction.guild_id,
                base_revision,
                content_to_json(updated),
                interaction.user.id,
                expected_version=stored.version if stored else None,
            )
            if saved is None:
                raise RuntimeError("The draft changed concurrently.")
            return active, saved, updated, detail

    async def _run_edit(
        self, interaction, profile: str, mutate, *, preauthorized=False, predeferred=False
    ):
        if not preauthorized and not await utils.require_arsenal_access(interaction, "edit", profile):
            return
        if not predeferred:
            await interaction.response.defer(ephemeral=True, thinking=True)
        try:
            active, draft, content, detail = await self._save_mutation(interaction, profile, mutate)
            diff = diff_content(active["arsenal"], content)
            await interaction.edit_original_response(
                content=(
                    f"Draft `{_profile_display_name(profile)}` v{draft.version} saved. "
                    f"{detail}\n{_diff_text(diff)}"
                )
            )
        except PermissionError as exc:
            await interaction.edit_original_response(content=str(exc))
        except ArsenalValidationError as exc:
            await interaction.edit_original_response(content=str(exc))
        except ArsenalApiError:
            log.exception("Arsenal API request failed during edit profile=%s", profile)
            await interaction.edit_original_response(content="The private Arsenal publisher API is unavailable.")
        except (RuntimeError, OSError, json.JSONDecodeError):
            log.exception("Could not update arsenal draft profile=%s", profile)
            await interaction.edit_original_response(content="The arsenal draft could not be updated safely.")

    @arsenal.command(name="status", description="Show the active revision and local draft summary")
    @app_commands.autocomplete(profile=_profile_choices)
    async def arsenal_status(self, interaction: discord.Interaction, profile: str):
        profile = _profile_key(profile)
        if not await utils.require_arsenal_access(interaction, "view", profile):
            return
        await interaction.response.defer(ephemeral=True)
        try:
            active = await self.client.get_active(profile)
            stored = self._stored_draft(profile, interaction.guild_id)
            lines = [
                f"Profile: `{_profile_display_name(profile)}`",
                f"Active revision: `{active['revision']['number']}`",
                f"Active items: `{len(active['arsenal']['allowedItems'])}`",
                f"Active kits: `{len(active['arsenal']['kits'])}`",
            ]
            if stored:
                draft = content_from_json(stored.content_json)
                lines.extend([
                    f"Draft version: `{stored.version}` (base revision `{stored.base_revision}`)",
                    f"Draft items: `{len(draft['allowedItems'])}`",
                    f"Draft kits: `{len(draft['kits'])}`",
                ])
            else:
                lines.append("Draft: none")
            await interaction.edit_original_response(content="\n".join(lines))
        except ArsenalValidationError as exc:
            await interaction.edit_original_response(content=str(exc))
        except ArsenalApiError:
            log.exception("Arsenal status request failed profile=%s", profile)
            await interaction.edit_original_response(content="The private Arsenal publisher API is unavailable.")

    @items.command(name="add", description="Add one classname to the draft whitelist")
    @app_commands.autocomplete(profile=_profile_choices)
    async def items_add(self, interaction: discord.Interaction, profile: str, classname: str):
        profile = _profile_key(profile)

        def mutate(content):
            if CLASS_NAME_RE.fullmatch(classname) is None:
                raise ArsenalValidationError("Enter a valid Arma classname.")
            items = list(content["allowedItems"])
            if classname in items:
                return content, "The classname was already present."
            items.append(classname)
            return {"allowedItems": items, "kits": content["kits"]}, f"Added `{classname}`."
        await self._run_edit(interaction, profile, mutate)

    @items.command(name="remove", description="Remove one classname from the draft whitelist")
    @app_commands.autocomplete(profile=_profile_choices)
    async def items_remove(self, interaction: discord.Interaction, profile: str, classname: str):
        profile = _profile_key(profile)

        def mutate(content):
            if CLASS_NAME_RE.fullmatch(classname) is None:
                raise ArsenalValidationError("Enter a valid Arma classname.")
            items = [item for item in content["allowedItems"] if item != classname]
            if len(items) == len(content["allowedItems"]):
                return content, "The classname was not present."
            return {"allowedItems": items, "kits": content["kits"]}, f"Removed `{classname}`."
        await self._run_edit(interaction, profile, mutate)

    @items.command(name="import", description="Merge, replace, or remove a JSON classname array")
    @app_commands.autocomplete(profile=_profile_choices)
    @app_commands.describe(data="JSON array copied from Arma", attachment="JSON/TXT file for large exports")
    async def items_import(
        self,
        interaction: discord.Interaction,
        profile: str,
        mode: Literal["merge", "replace", "remove"],
        data: str | None = None,
        attachment: discord.Attachment | None = None,
    ):
        profile = _profile_key(profile)
        if not await utils.require_arsenal_access(interaction, "edit", profile):
            return
        await interaction.response.defer(ephemeral=True, thinking=True)
        try:
            raw = await self._read_input(data, attachment)
            imported, duplicates = parse_item_payload(raw)
        except (ArsenalValidationError, discord.HTTPException) as exc:
            message = (
                str(exc)
                if isinstance(exc, ArsenalValidationError)
                else "The attachment could not be downloaded from Discord. Upload it again and retry."
            )
            await interaction.edit_original_response(content=message)
            return

        def mutate(content):
            existing = list(content["allowedItems"])
            if mode == "replace":
                items = imported
            elif mode == "remove":
                removed = set(imported)
                items = [item for item in existing if item not in removed]
            else:
                seen = set(existing)
                items = existing + [item for item in imported if item not in seen]
            return (
                {"allowedItems": items, "kits": content["kits"]},
                f"Imported {len(imported)} unique classnames; ignored {duplicates} duplicate(s).",
            )
        await self._run_edit(
            interaction, profile, mutate, preauthorized=True, predeferred=True
        )

    @kits.command(name="import", description="Add or replace one loadout kit in the draft")
    @app_commands.autocomplete(profile=_profile_choices)
    @app_commands.describe(data="JSON getUnitLoadout output", attachment="JSON/TXT loadout file")
    async def kits_import(
        self,
        interaction: discord.Interaction,
        profile: str,
        kit_id: str,
        display_name: str,
        data: str | None = None,
        attachment: discord.Attachment | None = None,
    ):
        profile = _profile_key(profile)
        if not await utils.require_arsenal_access(interaction, "edit", profile):
            return
        await interaction.response.defer(ephemeral=True, thinking=True)
        try:
            if IDENTIFIER_RE.fullmatch(kit_id) is None:
                raise ArsenalValidationError("Enter a valid lowercase kit identifier.")
            if DISPLAY_NAME_RE.fullmatch(display_name) is None:
                raise ArsenalValidationError("The kit display name contains unsupported characters.")
            raw = await self._read_input(data, attachment)
            loadout = parse_loadout_payload(raw)
        except (ArsenalValidationError, discord.HTTPException) as exc:
            message = (
                str(exc)
                if isinstance(exc, ArsenalValidationError)
                else "The attachment could not be downloaded from Discord. Upload it again and retry."
            )
            await interaction.edit_original_response(content=message)
            return

        def mutate(content):
            kit = {"id": kit_id, "displayName": display_name, "loadout": loadout}
            kits = list(content["kits"])
            index = next((index for index, existing in enumerate(kits) if existing["id"] == kit_id), None)
            if index is None:
                kits.append(kit)
                detail = f"Added kit `{kit_id}`."
            else:
                kits[index] = kit
                detail = f"Replaced kit `{kit_id}`."
            return {"allowedItems": content["allowedItems"], "kits": kits}, detail
        await self._run_edit(
            interaction, profile, mutate, preauthorized=True, predeferred=True
        )

    @kits.command(name="remove", description="Remove one kit from the draft")
    @app_commands.autocomplete(profile=_profile_choices)
    async def kits_remove(self, interaction: discord.Interaction, profile: str, kit_id: str):
        profile = _profile_key(profile)

        def mutate(content):
            if IDENTIFIER_RE.fullmatch(kit_id) is None:
                raise ArsenalValidationError("Enter a valid kit identifier.")
            kits = [kit for kit in content["kits"] if kit["id"] != kit_id]
            if len(kits) == len(content["kits"]):
                return content, "The kit was not present."
            return {"allowedItems": content["allowedItems"], "kits": kits}, f"Removed kit `{kit_id}`."
        await self._run_edit(interaction, profile, mutate)

    @arsenal.command(name="diff", description="Show the unpublished draft changes")
    @app_commands.autocomplete(profile=_profile_choices)
    async def arsenal_diff(self, interaction: discord.Interaction, profile: str):
        profile = _profile_key(profile)
        if not await utils.require_arsenal_access(interaction, "view", profile):
            return
        await interaction.response.defer(ephemeral=True)
        try:
            active = await self.client.get_active(profile)
            stored = self._stored_draft(profile, interaction.guild_id)
            if stored is None:
                await interaction.edit_original_response(content="There is no draft for this profile.")
                return
            draft = content_from_json(stored.content_json)
            stale = "\nWarning: the active revision changed; discard this stale draft." if stored.base_revision != active["revision"]["number"] else ""
            await interaction.edit_original_response(content=_diff_text(diff_content(active["arsenal"], draft)) + stale)
        except ArsenalValidationError as exc:
            await interaction.edit_original_response(content=str(exc))
        except ArsenalApiError:
            log.exception("Arsenal diff request failed profile=%s", profile)
            await interaction.edit_original_response(content="The private Arsenal publisher API is unavailable.")

    @arsenal.command(name="discard", description="Discard the unpublished draft")
    @app_commands.autocomplete(profile=_profile_choices)
    async def arsenal_discard(self, interaction: discord.Interaction, profile: str):
        profile = _profile_key(profile)
        if not await utils.require_arsenal_access(interaction, "edit", profile):
            return
        await interaction.response.defer(ephemeral=True)
        async with self._lock(profile):
            try:
                stored = self._stored_draft(profile, interaction.guild_id)
            except ArsenalValidationError as exc:
                await interaction.edit_original_response(content=str(exc))
                return
            if stored is None:
                await interaction.edit_original_response(content="There is no draft for this profile.")
                return
            if not await self._reauthorize(interaction, "edit", profile):
                await interaction.edit_original_response(content="Your arsenal edit access changed. The draft was kept.")
                return
            removed = self.bot.store.remove_arsenal_draft(profile, expected_version=stored.version)
            await interaction.edit_original_response(
                content="Draft discarded." if removed else "The draft changed concurrently and was kept."
            )

    @arsenal.command(name="publish", description="Validate and publish the current draft as a new revision")
    @app_commands.autocomplete(profile=_profile_choices)
    async def arsenal_publish(self, interaction: discord.Interaction, profile: str):
        profile = _profile_key(profile)
        if not await utils.require_arsenal_access(interaction, "publish", profile):
            return
        await interaction.response.defer(ephemeral=True)
        try:
            active = await self.client.get_active(profile)
            stored = self._stored_draft(profile, interaction.guild_id)
            if stored is None:
                await interaction.edit_original_response(content="There is no draft for this profile.")
                return
            if stored.base_revision != active["revision"]["number"]:
                await interaction.edit_original_response(content="The active revision changed. Discard this stale draft before publishing.")
                return
            draft = content_from_json(stored.content_json)
            diff = diff_content(active["arsenal"], draft)
            if not _has_changes(diff):
                await interaction.edit_original_response(content="The draft contains no changes.")
                return
            view = PublishConfirmationView(
                self, interaction.user.id, interaction.guild_id, profile, stored.version
            )
            await interaction.edit_original_response(
                content=(
                    f"Publish `{_profile_display_name(profile)}` from revision "
                    f"`{stored.base_revision}` as a new immutable revision?\n"
                    + _diff_text(diff)
                ),
                view=view,
            )
        except ArsenalValidationError as exc:
            await interaction.edit_original_response(content=str(exc))
        except ArsenalApiError:
            log.exception("Arsenal publish preview failed profile=%s", profile)
            await interaction.edit_original_response(content="The private Arsenal publisher API is unavailable.")

    async def publish_confirmed(self, interaction: discord.Interaction, profile: str, version: int) -> str:
        async with self._lock(profile):
            stored = self.bot.store.arsenal_draft(profile)
            if stored is None or stored.version != version or stored.guild_id != interaction.guild_id:
                return "The draft changed or no longer exists. Nothing was published."
            if not await self._reauthorize(interaction, "publish", profile):
                return "Your publish access changed. Nothing was published."
            try:
                active = await self.client.get_active(profile)
                if active["revision"]["number"] != stored.base_revision:
                    return "The active revision changed. Nothing was published; discard the stale draft."
                content = content_from_json(stored.content_json)
                result = await self.client.publish(
                    profile,
                    stored.base_revision,
                    f"discord:{interaction.id}",
                    interaction.guild_id,
                    interaction.user.id,
                    content,
                )
            except ArsenalApiError as exc:
                if exc.code == "REVISION_CONFLICT":
                    return "The active revision changed. Nothing was published; discard the stale draft."
                log.exception("Arsenal publication failed profile=%s code=%s", profile, exc.code)
                return "The publisher API could not confirm publication. The draft was kept."
            except (ArsenalValidationError, ValueError, json.JSONDecodeError):
                log.exception("Stored arsenal draft failed validation profile=%s", profile)
                return "The stored draft failed validation and was not published."

            removed = self.bot.store.remove_arsenal_draft(profile, expected_version=version)
            if not removed:
                log.error("Published arsenal revision but failed to clear draft profile=%s version=%s", profile, version)
                return f"Revision `{result['revision']}` was published, but the local draft could not be cleared. Contact the owner."
            replayed = " (idempotent replay)" if result.get("replayed") else ""
            return (
                f"Published immutable revision `{result['revision']}` for "
                f"`{_profile_display_name(profile)}`{replayed}. "
                "It loads at the next mission start."
            )


async def setup(bot):
    await bot.add_cog(ArsenalCog(bot))
