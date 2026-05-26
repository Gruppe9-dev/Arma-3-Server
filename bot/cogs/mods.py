"""
/mods command group — sync, import-preset.
"""

import logging
from datetime import datetime

import discord
from discord import app_commands
from discord.ext import commands

import config
import ssh_helper
import utils

logger = logging.getLogger(__name__)


async def _deny(interaction: discord.Interaction) -> None:
    embed = discord.Embed(
        title="Access Denied",
        description="You need the Server-Admin role to use this command.",
        color=discord.Color.red(),
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)


async def _reply(
    interaction: discord.Interaction,
    title: str,
    code: int,
    output: str,
    fields: dict[str, str] | None = None,
) -> None:
    """Edit the deferred response with an embed; send overflow as plain follow-ups."""
    color  = discord.Color.green() if code == 0 else discord.Color.red()
    status = "✅ Success" if code == 0 else f"❌ Error (Exit {code})"
    embed  = discord.Embed(title=title, color=color, timestamp=datetime.utcnow())
    embed.add_field(name="Status", value=status, inline=True)

    if fields:
        for name, value in fields.items():
            embed.add_field(name=name, value=value, inline=True)

    if output:
        filtered = ssh_helper.filter_output(output)
        truncated = filtered[:990] + "\n…(truncated)" if len(filtered) > 990 else filtered
        embed.add_field(name="Output", value=f"```\n{truncated}\n```", inline=False)

    await interaction.edit_original_response(embed=embed)

    if len(output) > 990:
        for chunk in ssh_helper.split_output(output[990:]):
            await interaction.followup.send(f"```\n{chunk}\n```")


# ── Cog ────────────────────────────────────────────────────────────────────────

class ModsCog(commands.Cog):
    """Mod management commands (/mods group)."""

    mods = app_commands.Group(name="mods", description="Mod management")

    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # ── /mods sync ────────────────────────────────────────────────────────────

    @mods.command(name="sync", description="Download and deploy mods for a profile")
    @app_commands.describe(
        profile="Profile name (e.g. main, star_wars)",
        force="Re-download mods that are already deployed",
    )
    async def mods_sync(
        self, interaction: discord.Interaction, profile: str, force: bool = False
    ) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("mods sync requested by %s — profile: %s force: %s", interaction.user, profile, force)

        extra = f"-Profile {profile}" + (" -Force" if force else "")
        code, out = await ssh_helper.run_ps_file("mods/Sync-Mods.ps1", extra)
        await _reply(
            interaction,
            "Sync Mods",
            code,
            out,
            fields={"Profile": f"`{profile}`", "Force": "Yes" if force else "No"},
        )

    # ── /mods import-preset ───────────────────────────────────────────────────

    @mods.command(
        name="import-preset",
        description="Upload an Arma 3 Launcher HTML preset and import it into a profile",
    )
    @app_commands.describe(
        profile="Target profile (e.g. main, star_wars)",
        preset_html="HTML export file from the Arma 3 Launcher",
        merge="Keep existing mods and add new ones (instead of replacing)",
        sync_after="Download all mods immediately after import",
    )
    async def mods_import_preset(
        self,
        interaction: discord.Interaction,
        profile: str,
        preset_html: discord.Attachment,
        merge: bool = False,
        sync_after: bool = False,
    ) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        # Validate before deferring so the error shows without a thinking spinner
        if not preset_html.filename.lower().endswith(".html"):
            embed = discord.Embed(
                title="Invalid File",
                description=(
                    "Only `.html` files are accepted.\n"
                    "Arma 3 Launcher → MODS → PRESET → EXPORT"
                ),
                color=discord.Color.red(),
            )
            await interaction.response.send_message(embed=embed, ephemeral=True)
            return

        await interaction.response.defer(thinking=True)
        logger.info(
            "mods import-preset requested by %s — profile: %s file: %s",
            interaction.user, profile, preset_html.filename,
        )

        # 1. Download the HTML from Discord CDN
        try:
            html_bytes = await preset_html.read()
        except discord.HTTPException as exc:
            logger.error("Failed to download attachment: %s", exc)
            embed = discord.Embed(
                title="Download Failed",
                description=f"Could not download the file: {exc}",
                color=discord.Color.red(),
            )
            await interaction.edit_original_response(embed=embed)
            return

        # 2. Upload to the host's presets\ folder via SFTP
        remote_path = (
            config.SCRIPTS_PATH.rstrip("\\") + "\\presets\\" + preset_html.filename
        )
        try:
            await ssh_helper.upload_bytes(html_bytes, remote_path)
            logger.info("Uploaded preset to %s", remote_path)
        except RuntimeError as exc:
            logger.error("SFTP upload failed: %s", exc)
            embed = discord.Embed(
                title="Upload Failed",
                description=str(exc),
                color=discord.Color.red(),
            )
            await interaction.edit_original_response(embed=embed)
            return

        # 3. Run Import-Preset.ps1
        args = f'-PresetFile "{remote_path}" -Profile {profile}'
        if merge:
            args += " -Merge"
        if sync_after:
            args += " -SyncAfter"

        code, out = await ssh_helper.run_ps_file("mods/Import-Preset.ps1", args)
        await _reply(
            interaction,
            "Import Preset",
            code,
            out,
            fields={
                "Profile":    f"`{profile}`",
                "File":       preset_html.filename,
                "Merge":      "Yes" if merge else "No",
                "Sync After": "Yes" if sync_after else "No",
            },
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(ModsCog(bot))
