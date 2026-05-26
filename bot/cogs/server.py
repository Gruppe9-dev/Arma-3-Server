"""
/server command group — start, stop, status, update.
Includes a persistent live-status embed that updates every 30 s after server start.
"""

import asyncio
import logging
import re
from datetime import datetime, timezone

import a2s
import discord
from discord import app_commands
from discord.ext import commands

import config
import ssh_helper
import utils

logger = logging.getLogger(__name__)

# ── helpers ────────────────────────────────────────────────────────────────────

_LIVE_UPDATE_INTERVAL = 30   # seconds between embed refreshes
_LIVE_MAX_RUNTIME     = 48   # hours before auto-stop (safety cap)


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
    profile: str | None = None,
) -> None:
    """Filter output first, then build embed + send overflow follow-ups."""
    filtered = ssh_helper.filter_output(output)
    chunks   = ssh_helper.split_output(filtered) if filtered else ["(no output)"]

    color  = discord.Color.green() if code == 0 else discord.Color.red()
    status = "✅ Success" if code == 0 else f"❌ Error (Exit {code})"
    embed  = discord.Embed(title=title, color=color, timestamp=datetime.now(timezone.utc))

    if profile:
        embed.add_field(name="Profile", value=f"`{profile}`", inline=True)
    embed.add_field(name="Status", value=status, inline=True)
    embed.add_field(name="Output", value=f"```\n{chunks[0]}\n```", inline=False)

    await interaction.edit_original_response(embed=embed)

    for chunk in chunks[1:]:
        await interaction.followup.send(f"```\n{chunk}\n```")


def _fmt_uptime(seconds: int) -> str:
    hours, rem = divmod(seconds, 3600)
    mins, secs = divmod(rem, 60)
    if hours:
        return f"{hours}h {mins:02d}m {secs:02d}s"
    return f"{mins}m {secs:02d}s"


def _build_live_embed(
    profile: str,
    proc: dict | None,
    a2s_info: dict | None,
) -> discord.Embed:
    """Build the live-status embed from gathered stats."""
    if proc is None:
        embed = discord.Embed(
            title=f"🔴  Server Offline — `{profile}`",
            color=discord.Color.red(),
            timestamp=datetime.now(timezone.utc),
        )
        embed.set_footer(text="Server process has stopped.")
        return embed

    embed = discord.Embed(
        title=f"🟢  Server Online — `{profile}`",
        color=discord.Color.green(),
        timestamp=datetime.now(timezone.utc),
    )

    if a2s_info:
        embed.add_field(
            name="👥  Players",
            value=f"{a2s_info['players']} / {a2s_info['max_players']}",
            inline=True,
        )
        embed.add_field(
            name="🗺️  Mission",
            value=a2s_info["map"] or "—",
            inline=True,
        )
    else:
        embed.add_field(name="👥  Players", value="—", inline=True)
        embed.add_field(name="🗺️  Mission", value="Starting…", inline=True)

    embed.add_field(name="⏱️  Uptime",   value=_fmt_uptime(proc["uptime_s"]), inline=True)
    embed.add_field(name="💻  CPU",      value=f"{proc['cpu']:.1f}s total",   inline=True)
    embed.add_field(name="💾  RAM",      value=f"{proc['ram_mb']:,} MB",       inline=True)
    embed.add_field(name="🔢  PID",      value=str(proc["pid"]),               inline=True)

    embed.set_footer(text=f"Profile: {profile}  •  auto-refresh every {_LIVE_UPDATE_INTERVAL}s")
    return embed


# ── Cog ────────────────────────────────────────────────────────────────────────

class ServerCog(commands.Cog):
    """Arma 3 Server management commands (/server group)."""

    server = app_commands.Group(name="server", description="Arma 3 server management")

    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot
        # profile → running asyncio.Task
        self._live_tasks: dict[str, asyncio.Task] = {}

    # ── internal: query process stats via SSH ──────────────────────────────────

    async def _get_proc_stats(self, pid: int) -> dict | None:
        """Return CPU/RAM/uptime dict for the given PID, or None if gone."""
        ps = (
            "$ProgressPreference = 'SilentlyContinue'; "
            f"$p = Get-Process -Id {pid} -ErrorAction SilentlyContinue; "
            "if ($p) { "
            "  $up = [math]::Floor(((Get-Date) - $p.StartTime).TotalSeconds); "
            "  \"$([math]::Round($p.CPU,2))|$([math]::Round($p.WorkingSet64/1MB,0))|$up\" "
            "} else { 'stopped' }"
        )
        _, out = await ssh_helper.run_ps_command(ps)
        # Pick first line that matches the expected format (skip CLIXML noise)
        raw = None
        for line in out.splitlines():
            line = line.strip()
            if line == "stopped":
                return None
            if re.match(r"^[\d.]+\|\d+\|\d+$", line):
                raw = line
                break
        if not raw:
            return None
        parts = raw.split("|")
        if len(parts) != 3:
            return None
        try:
            return {
                "cpu":      float(parts[0]),
                "ram_mb":   int(parts[1]),
                "uptime_s": int(parts[2]),
                "pid":      pid,
            }
        except ValueError:
            return None

    # ── internal: A2S query (run in thread — library is synchronous) ──────────

    async def _get_a2s_info(self, host: str, query_port: int) -> dict | None:
        """Query the Arma 3 server via Steam A2S. Returns None if unavailable."""
        try:
            info = await asyncio.to_thread(
                a2s.info, (host, query_port), timeout=2.0
            )
            return {
                "players":     info.player_count,
                "max_players": info.max_players,
                "map":         info.map_name,
            }
        except Exception:
            return None

    # ── internal: read PID + port from host after start ───────────────────────

    async def _get_pid_and_port(self, profile: str) -> tuple[int, int] | None:
        """SSH: read server.pid and Port from profile.json. Returns (pid, port)."""
        base = config.SCRIPTS_PATH.replace("\\", "/")
        ps = (
            "$ProgressPreference = 'SilentlyContinue'; "
            f"$serverPid = (Get-Content '{base}/profiles/{profile}/server.pid' "
            f"  -ErrorAction SilentlyContinue | Select-Object -First 1).Trim(); "
            f"$serverPort = (Get-Content '{base}/profiles/{profile}/profile.json' "
            f"  | ConvertFrom-Json).Port; "
            '"$serverPid|$serverPort"'
        )
        _, out = await ssh_helper.run_ps_command(ps)
        # Strip CLIXML noise and grab only the first line that matches pid|port
        for line in out.splitlines():
            m = re.match(r"^(\d+)\|(\d+)$", line.strip())
            if m:
                return int(m.group(1)), int(m.group(2))
        logger.warning("Could not parse pid/port from: %r", out)
        return None

    # ── internal: background live-status loop ─────────────────────────────────

    async def _live_status_loop(
        self,
        channel: discord.abc.Messageable,
        status_msg: discord.Message,
        profile: str,
        pid: int,
        query_port: int,
    ) -> None:
        host        = config.SERVER_HOST
        deadline    = asyncio.get_event_loop().time() + _LIVE_MAX_RUNTIME * 3600
        stopped     = False

        try:
            while asyncio.get_event_loop().time() < deadline:
                proc     = await self._get_proc_stats(pid)
                a2s_info = await self._get_a2s_info(host, query_port) if proc else None
                embed    = _build_live_embed(profile, proc, a2s_info)

                try:
                    await status_msg.edit(embed=embed)
                except discord.NotFound:
                    logger.info("Live-status message deleted — stopping loop for %s", profile)
                    return
                except discord.HTTPException as exc:
                    logger.warning("Edit failed: %s", exc)

                if proc is None:
                    stopped = True
                    break

                await asyncio.sleep(_LIVE_UPDATE_INTERVAL)

        except asyncio.CancelledError:
            # /server stop was called — update embed to offline
            embed = _build_live_embed(profile, None, None)
            try:
                await status_msg.edit(embed=embed)
            except discord.HTTPException:
                pass
            return

        finally:
            self._live_tasks.pop(profile, None)

        if not stopped:
            # Safety-cap reached
            embed = _build_live_embed(profile, None, None)
            try:
                await status_msg.edit(embed=embed)
            except discord.HTTPException:
                pass

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

        if code != 0:
            return

        # Cancel any previous live-status task for this profile
        if profile in self._live_tasks:
            self._live_tasks[profile].cancel()

        # Brief pause to let the PID file be written
        await asyncio.sleep(2)

        info = await self._get_pid_and_port(profile)
        if info is None:
            logger.warning("Could not start live-status for %s (no PID/port)", profile)
            return

        pid, port   = info
        query_port  = port + 1

        # Post the initial status embed as a follow-up (separate from the start reply)
        init_embed = _build_live_embed(profile, {"cpu": 0.0, "ram_mb": 0, "uptime_s": 0, "pid": pid}, None)
        init_embed.title = f"🟡  Server Starting — `{profile}`"
        init_embed.color = discord.Color.yellow()

        status_msg = await interaction.followup.send(embed=init_embed)

        # Launch background task
        task = asyncio.create_task(
            self._live_status_loop(interaction.channel, status_msg, profile, pid, query_port),
            name=f"live-status-{profile}",
        )
        self._live_tasks[profile] = task
        logger.info("Live-status task started for %s (PID %d, query port %d)", profile, pid, query_port)

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

        # Signal live-status loop to update to offline
        if profile in self._live_tasks:
            self._live_tasks[profile].cancel()

    # ── /server status ────────────────────────────────────────────────────────

    @server.command(name="status", description="Show running Arma 3 processes")
    async def server_status(self, interaction: discord.Interaction) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server status requested by %s", interaction.user)

        ps = (
            "$ProgressPreference = 'SilentlyContinue'; "
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
            timestamp=datetime.now(timezone.utc),
        )
        out = out or "No Arma 3 processes running."
        embed.add_field(name="Processes", value=f"```\n{out[:990]}\n```", inline=False)
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
