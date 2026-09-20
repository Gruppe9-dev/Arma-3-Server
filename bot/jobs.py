"""Serialized host operations and durable audit/status records for a single bot."""

import asyncio
import logging
import sqlite3
from pathlib import Path

import discord

import ssh_helper
import utils
from presentation import job_embed, parse_mod_summary

log = logging.getLogger(__name__)


class JobStore:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS jobs (
                id INTEGER PRIMARY KEY, guild_id TEXT NOT NULL, user_id TEXT NOT NULL,
                profile TEXT NOT NULL, action TEXT NOT NULL, status TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                finished_at TEXT, exit_code INTEGER
            );
            CREATE TABLE IF NOT EXISTS panels (
                guild_id TEXT NOT NULL, profile TEXT NOT NULL,
                channel_id TEXT NOT NULL, message_id TEXT NOT NULL,
                PRIMARY KEY (guild_id, profile)
            );
        """)
        # A host-side process may outlive SSH/bot termination. Never replay it.
        self.db.execute("UPDATE jobs SET status='interrupted' WHERE status IN ('queued','running')")
        self.db.commit()

    def create(self, guild: int, user: int, profile: str, action: str) -> int:
        cursor = self.db.execute(
            "INSERT INTO jobs(guild_id,user_id,profile,action,status) VALUES(?,?,?,?,'queued')",
            (str(guild), str(user), profile, action),
        )
        self.db.commit()
        return cursor.lastrowid

    def mark(self, job_id: int, status: str, code: int | None = None):
        self.db.execute(
            "UPDATE jobs SET status=?,exit_code=?,finished_at=CASE WHEN ?='running' THEN NULL ELSE CURRENT_TIMESTAMP END WHERE id=?",
            (status, code, status, job_id),
        )
        self.db.commit()

    def save_panel(self, guild: int, profile: str, channel: int, message: int):
        self.db.execute("INSERT OR REPLACE INTO panels VALUES(?,?,?,?)", (str(guild), profile, str(channel), str(message)))
        self.db.commit()

    def panels(self):
        return self.db.execute("SELECT guild_id,profile,channel_id,message_id FROM panels").fetchall()

    def remove_panel(self, guild: int, profile: str):
        self.db.execute("DELETE FROM panels WHERE guild_id=? AND profile=?", (str(guild), profile))
        self.db.commit()


class JobRunner:
    def __init__(self, store: JobStore):
        self.store = store
        self.lock = asyncio.Lock()
        self.pending: set[tuple[int, str]] = set()

    async def run(self, interaction, action: str, profile: str, script: str, *, owner_only=False, **parameters):
        authorized = utils.has_admin_auth(interaction) if owner_only else utils.can_access(interaction, action, profile)
        if not authorized:
            if interaction.response.is_done():
                await interaction.edit_original_response(content="You do not have permission to run this operation.")
            else:
                await interaction.response.send_message("You do not have permission to run this operation.", ephemeral=True)
            return 1
        key = (interaction.user.id, profile)
        if key in self.pending or len(self.pending) >= 20:
            if interaction.response.is_done():
                await interaction.edit_original_response(content="An operation is already queued for you, or the queue is full.")
            else:
                await interaction.response.send_message("An operation is already queued for you, or the queue is full.", ephemeral=True)
            return 1
        if interaction.channel is None:
            if interaction.response.is_done():
                await interaction.edit_original_response(content="Use a server text channel for host operations.")
            else:
                await interaction.response.send_message("Use a server text channel for host operations.", ephemeral=True)
            return 1
        self.pending.add(key)
        job_id = None
        message = None
        terminal = False
        try:
            if not interaction.response.is_done():
                await interaction.response.defer(ephemeral=True, thinking=True)
            job_id = self.store.create(interaction.guild_id, interaction.user.id, profile, action)
            # Regular bot messages survive the 15-minute interaction token limit.
            message = await interaction.channel.send(
                embed=job_embed(job_id, action, profile, "queued"),
                allowed_mentions=discord.AllowedMentions.none(),
            )
            await interaction.edit_original_response(content=f"Operation accepted: {message.jump_url}")
            async with self.lock:
                # Roles/membership may have changed while the job was queued.
                member = await interaction.guild.fetch_member(interaction.user.id)
                interaction.user = member
                allowed = utils.has_admin_auth(interaction) if owner_only else utils.can_access(interaction, action, profile)
                if not allowed:
                    self.store.mark(job_id, "denied", 1)
                    terminal = True
                    await message.edit(embed=job_embed(job_id, action, profile, "denied"))
                    return 1
                self.store.mark(job_id, "running")
                await message.edit(embed=job_embed(job_id, action, profile, "running"))
                code, output = await ssh_helper.run_ps_file(script, **parameters)
                status = "completed" if code == 0 else "unknown" if code == 255 else "failed"
                self.store.mark(job_id, status, code)
                terminal = True
                log.info("Job %s guild=%s user=%s profile=%s action=%s result=%s\n%s", job_id,
                         interaction.guild_id, interaction.user.id, profile, action, status, ssh_helper.filter_output(output, 80))
                try:
                    summary = parse_mod_summary(output) if script == "mods/Sync-Mods.ps1" and code != 255 else None
                    await message.edit(embed=job_embed(job_id, action, profile, status, mod_summary=summary))
                except discord.HTTPException:
                    log.warning("Could not publish final status for job %s; the recorded outcome is %s", job_id, status)
                return code
        except asyncio.CancelledError:
            if job_id is not None and not terminal:
                self.store.mark(job_id, "interrupted")
            raise
        except Exception:
            log.exception("Host job failed (job=%s)", job_id)
            if job_id is not None and not terminal:
                self.store.mark(job_id, "interrupted")
            if message is not None:
                try:
                    await message.edit(embed=job_embed(job_id, action, profile, "interrupted"))
                except discord.HTTPException:
                    pass
            return 1
        finally:
            self.pending.discard(key)
