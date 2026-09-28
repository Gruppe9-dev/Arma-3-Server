"""Serialized host operations and durable audit/status records for a single bot."""

import asyncio
from dataclasses import dataclass
import logging
import sqlite3
from pathlib import Path

import discord

import ssh_helper
import utils
from presentation import job_embed, parse_mod_summary

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class ArsenalDraft:
    profile: str
    guild_id: int
    base_revision: int
    version: int
    content_json: str
    updated_by: int
    updated_at: str


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
            CREATE TABLE IF NOT EXISTS control_panels (
                guild_id TEXT NOT NULL, profile TEXT NOT NULL,
                channel_id TEXT NOT NULL, message_id TEXT NOT NULL,
                PRIMARY KEY (guild_id, profile)
            );
            CREATE TABLE IF NOT EXISTS arsenal_drafts (
                profile TEXT PRIMARY KEY,
                guild_id TEXT NOT NULL,
                base_revision INTEGER NOT NULL CHECK(base_revision > 0),
                version INTEGER NOT NULL CHECK(version > 0),
                content_json TEXT NOT NULL,
                updated_by TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
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

    def save_control_panel(self, guild: int, profile: str, channel: int, message: int):
        self.db.execute("INSERT OR REPLACE INTO control_panels VALUES(?,?,?,?)",
                        (str(guild), profile, str(channel), str(message)))
        self.db.commit()

    def control_panels(self):
        return self.db.execute("SELECT guild_id,profile,channel_id,message_id FROM control_panels").fetchall()

    def control_panel(self, guild: int, profile: str):
        return self.db.execute("SELECT channel_id,message_id FROM control_panels WHERE guild_id=? AND profile=?",
                               (str(guild), profile)).fetchone()

    def remove_control_panel(self, guild: int, profile: str, message: int):
        # An old refresh task must not erase a concurrently replaced panel.
        self.db.execute("DELETE FROM control_panels WHERE guild_id=? AND profile=? AND message_id=?",
                        (str(guild), profile, str(message)))
        self.db.commit()

    def arsenal_draft(self, profile: str) -> ArsenalDraft | None:
        row = self.db.execute(
            "SELECT profile,guild_id,base_revision,version,content_json,updated_by,updated_at "
            "FROM arsenal_drafts WHERE profile=?",
            (profile,),
        ).fetchone()
        if row is None:
            return None
        return ArsenalDraft(
            profile=row[0], guild_id=int(row[1]), base_revision=row[2], version=row[3],
            content_json=row[4], updated_by=int(row[5]), updated_at=row[6],
        )

    def save_arsenal_draft(
        self,
        profile: str,
        guild: int,
        base_revision: int,
        content_json: str,
        updated_by: int,
        *,
        expected_version: int | None,
    ) -> ArsenalDraft | None:
        self.db.execute("BEGIN IMMEDIATE")
        try:
            row = self.db.execute(
                "SELECT version FROM arsenal_drafts WHERE profile=?", (profile,)
            ).fetchone()
            if row is None:
                if expected_version is not None:
                    self.db.rollback()
                    return None
                version = 1
                self.db.execute(
                    "INSERT INTO arsenal_drafts "
                    "(profile,guild_id,base_revision,version,content_json,updated_by) "
                    "VALUES(?,?,?,?,?,?)",
                    (profile, str(guild), base_revision, version, content_json, str(updated_by)),
                )
            else:
                if expected_version is None or row[0] != expected_version:
                    self.db.rollback()
                    return None
                version = row[0] + 1
                self.db.execute(
                    "UPDATE arsenal_drafts SET guild_id=?,base_revision=?,version=?,content_json=?,"
                    "updated_by=?,updated_at=CURRENT_TIMESTAMP WHERE profile=?",
                    (str(guild), base_revision, version, content_json, str(updated_by), profile),
                )
            self.db.commit()
        except Exception:
            self.db.rollback()
            raise
        return self.arsenal_draft(profile)

    def remove_arsenal_draft(self, profile: str, *, expected_version: int) -> bool:
        cursor = self.db.execute(
            "DELETE FROM arsenal_drafts WHERE profile=? AND version=?",
            (profile, expected_version),
        )
        self.db.commit()
        return cursor.rowcount == 1


class JobRunner:
    def __init__(self, store: JobStore):
        self.store = store
        self.lock = asyncio.Lock()
        self.pending: set[tuple[int, str]] = set()

    async def run(self, interaction, action: str, profile: str, script: str, *, owner_only=False, private=False, **parameters):
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
            if private:
                # Panel buttons keep the control channel clean. The durable job
                # record and refreshed panel survive interaction-token expiry.
                await interaction.edit_original_response(embed=job_embed(job_id, action, profile, "queued"))
                message = await interaction.original_response()
            else:
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
