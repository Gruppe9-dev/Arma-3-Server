"""Discord embeds shared by commands and persistent status messages."""

import json

import discord


def parse_mod_summary(output: str) -> dict | None:
    """Accept only bounded aggregate counters, never arbitrary host log text."""
    for line in reversed(output.splitlines()):
        if not line.startswith("MOD_SYNC_RESULT="):
            continue
        if len(line) > 2048:
            return None
        try:
            data = json.loads(line.removeprefix("MOD_SYNC_RESULT="))
        except ValueError:
            return None
        counts = ("Total", "Current", "Deployed", "Pending", "Excluded", "Failed", "NotProcessed")
        if not isinstance(data, dict) or data.get("Mode") not in ("check", "update", "sync"):
            return None
        if any(type(data.get(key)) is not int or not 0 <= data[key] <= 1_000_000 for key in counts):
            return None
        if sum(data[key] for key in counts[1:]) != data["Total"]:
            return None
        return {"Mode": data["Mode"], **{key: data[key] for key in counts}}
    return None


def display_text(value, limit=1024):
    """Keep host/game text within Discord limits and neutralize formatting."""
    text = discord.utils.escape_mentions(discord.utils.escape_markdown(str(value or "—")))
    return text if len(text) <= limit else text[:limit - 1] + "…"


def job_embed(job_id: int, action: str, profile: str, status: str, *, mod_summary=None) -> discord.Embed:
    states = {
        "queued": ("⏳ Queued", discord.Color.blue(), "Waiting for the current operation to finish."),
        "running": ("🔄 Running", discord.Color.blue(), "The operation is running. This message updates automatically."),
        "completed": ("✅ Completed", discord.Color.green(), "The operation completed successfully."),
        "failed": ("❌ Failed", discord.Color.red(), "The owner can inspect the private bot/host logs."),
        "denied": ("⛔ Access revoked", discord.Color.red(), "Your access changed while this operation was queued. Nothing was executed."),
        "unknown": ("⚠️ Outcome unknown", discord.Color.orange(), "The host operation may still be running. Check server status before retrying."),
        "interrupted": ("⚠️ Interrupted", discord.Color.orange(), "Check server status before retrying."),
    }
    label, color, description = states[status]
    if status == "completed" and action in {"start", "restart"}:
        description = "The server process started. Check the status panel for game availability."
    embed = discord.Embed(title=f"{display_text(action.replace('-', ' ').title(), 180)} • Job #{job_id}",
                          description=description, color=color, timestamp=discord.utils.utcnow())
    embed.add_field(name="Instance", value=display_text(profile or "Shared installation"))
    embed.add_field(name="Status", value=label)
    if mod_summary:
        mode = mod_summary["Mode"]
        if status == "completed":
            embed.description = "Update check finished. No mods were changed." if mode == "check" else "Mod processing finished."
        embed.add_field(name="Mods selected", value=str(mod_summary["Total"]))
        if mode == "check":
            embed.add_field(name="Updates available", value=str(mod_summary["Pending"]))
        else:
            embed.add_field(name="Updated successfully" if mode == "update" else "Installed successfully", value=str(mod_summary["Deployed"]))
        embed.add_field(name="Already installed" if mode == "sync" else "Up to date", value=str(mod_summary["Current"]))
        embed.add_field(name="Failed", value=str(mod_summary["Failed"]))
        embed.add_field(name="Excluded", value=str(mod_summary["Excluded"]))
        if mod_summary["NotProcessed"]:
            embed.add_field(name="Not processed", value=str(mod_summary["NotProcessed"]))
    embed.set_footer(text="One message per operation • details stay in private logs")
    return embed


def format_uptime(seconds: int) -> str:
    hours, seconds = divmod(max(0, int(seconds)), 3600)
    minutes, seconds = divmod(seconds, 60)
    return f"{hours}h {minutes:02d}m" if hours else f"{minutes}m {seconds:02d}s"


def status_embed(profile: str, status: dict, info=None) -> discord.Embed:
    running = status["Running"]
    if not running:
        info = None
    label = "🟢 Server Online" if info else "🟡 Server Running • Query Unavailable" if running else "🔴 Server Offline"
    color = discord.Color.green() if info else discord.Color.orange() if running else discord.Color.red()
    embed = discord.Embed(title=f"{label} — {display_text(profile, 160)}", color=color,
                          timestamp=discord.utils.utcnow())
    if running:
        if not info:
            embed.description = "The process is running, but the game query is not responding yet."
        embed.add_field(name="👥 Players", value=f"{info.player_count} / {info.max_players}" if info else "Query unavailable")
        embed.add_field(name="🗺️ Map", value=display_text(info.map_name) if info else "Query unavailable")
        embed.add_field(name="⏱️ Uptime", value=format_uptime(status["UptimeSeconds"]))
        embed.add_field(name="🎯 Mission (RPT)", value=display_text(status.get("Mission") or "Waiting for mission"), inline=False)
        embed.add_field(name="💻 CPU", value=f"{status['CpuPercent']:.1f}%")
        embed.add_field(name="💾 RAM", value=f"{status['RamMB']:,.0f} MB")
        embed.add_field(name="🔢 PID", value=str(status["PID"]))
        embed.add_field(name="⚙️ Processes", value=f"{status['Processes']} total • {status['HeadlessClients']} HC(s)")
    else:
        embed.description = "The server process is stopped."
    embed.add_field(name="📦 Preset", value=display_text(status["Preset"]))
    embed.add_field(name="🔌 Port", value=str(status["Port"]))
    embed.set_footer(text="CPU/RAM: this instance + its HCs • CPU: share of host capacity • refresh every 30s" if running else
                     "Offline • automatic checks paused • resumes on bot start/restart or a manual status check")
    return embed
