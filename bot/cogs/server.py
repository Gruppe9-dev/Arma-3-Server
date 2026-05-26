"""
/server command group — start, stop, status, update.
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


def _build_output_embed(title: str, code: int, output: str, profile: str | None = None) -> discord.Embed:
    """Build an embed for PowerShell script output."""
    color   = discord.Color.green() if code == 0 else discord.Color.red()
    status  = "✅ Success" if code == 0 else f"❌ Error (Exit {code})"
    embed   = discord.Embed(title=title, color=color, timestamp=datetime.utcnow())

    if profile:
        embed.add_field(name="Profile", value=f"`{profile}`", inline=True)

    embed.add_field(name="Status", value=status, inline=True)

    if output:
        filtered = ssh_helper.filter_output(output)
        truncated = filtered[:990] + "\n…(truncated)" if len(filtered) > 990 else filtered
        embed.add_field(name="Output", value=f"```\n{truncated}\n```", inline=False)

    return embed


async def _reply(
    interaction: discord.Interaction,
    title: str,
    code: int,
    output: str,
    profile: str | None = None,
) -> None:
    """Edit the deferred response with an embed; send overflow as plain follow-ups."""
    embed = _build_output_embed(title, code, output, profile)
    await interaction.edit_original_response(embed=embed)

    # Send any output that didn't fit in the embed
    if len(output) > 990:
        for chunk in ssh_helper.split_output(output[990:]):
            await interaction.followup.send(f"```\n{chunk}\n```")


# ── Cog ────────────────────────────────────────────────────────────────────────

class ServerCog(commands.Cog):
    """Arma 3 Server management commands (/server group)."""

    server = app_commands.Group(name="server", description="Arma 3 server management")

    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # ── /server start ─────────────────────────────────────────────────────────

    @server.command(name="start", description="Start the server for a profile")
    @app_commands.describe(profile="Profile name (e.g. main, star_wars)")
    async def server_start(self, interaction: discord.Interaction, profile: str) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server start requested by %s — profile: %s", interaction.user, profile)

        code, out = await ssh_helper.run_ps_file("scripts/Start-Server.ps1", f"-Profile {profile}")
        await _reply(interaction, "Start Server", code, out, profile)

    # ── /server stop ──────────────────────────────────────────────────────────

    @server.command(name="stop", description="Stop the server for a profile")
    @app_commands.describe(profile="Profile name (e.g. main, star_wars)")
    async def server_stop(self, interaction: discord.Interaction, profile: str) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server stop requested by %s — profile: %s", interaction.user, profile)

        code, out = await ssh_helper.run_ps_file("scripts/Stop-Server.ps1", f"-Profile {profile}")
        await _reply(interaction, "Stop Server", code, out, profile)

    # ── /server status ────────────────────────────────────────────────────────

    @server.command(name="status", description="Show running Arma 3 processes")
    async def server_status(self, interaction: discord.Interaction) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server status requested by %s", interaction.user)

        ps = (
            "Get-Process arma3* -ErrorAction SilentlyContinue "
            "| Select-Object Id,ProcessName,"
            "@{N='CPU(s)';E={[math]::Round($_.CPU,1)}},"
            "@{N='RAM(MB)';E={[math]::Round($_.WorkingSet64/1MB,0)}} "
            "| Format-Table -AutoSize | Out-String"
        )
        code, out = await ssh_helper.run_ps_command(ps)

        embed = discord.Embed(
            title="Server Status",
            color=discord.Color.blue(),
            timestamp=datetime.utcnow(),
        )
        if out:
            filtered = ssh_helper.filter_output(out)
            embed.add_field(name="Processes", value=f"```\n{filtered[:990]}\n```", inline=False)
        else:
            embed.description = "No Arma 3 processes running."

        await interaction.edit_original_response(embed=embed)

    # ── /server update ────────────────────────────────────────────────────────

    @server.command(name="update", description="Update the Arma 3 dedicated server")
    async def server_update(self, interaction: discord.Interaction) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server update requested by %s", interaction.user)

        code, out = await ssh_helper.run_ps_file("setup/Update-Server.ps1")
        await _reply(interaction, "Server Update", code, out)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(ServerCog(bot))
