"""
Arma 3 Server Discord Bot — entry point.
"""

import asyncio
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

import discord
from discord.ext import commands

import config
from jobs import JobRunner, JobStore

# ── Logging ────────────────────────────────────────────────────────────────────
Path("logs").mkdir(exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        RotatingFileHandler("logs/bot.log", maxBytes=5_000_000, backupCount=5, encoding="utf-8"),
        logging.StreamHandler(),
    ],
)

# Suppress asyncssh connection-level chatter (keep only warnings/errors)
logging.getLogger("asyncssh").setLevel(logging.WARNING)
logger = logging.getLogger(__name__)

# ── Bot class ──────────────────────────────────────────────────────────────────

COGS = [
    "cogs.server",
    "cogs.mods",
    "cogs.automation",
]


class ArmaBot(commands.Bot):
    def __init__(self) -> None:
        super().__init__(
            command_prefix="!",
            intents=discord.Intents.default(),
            help_command=None,
            allowed_mentions=discord.AllowedMentions.none(),
        )
        self.store = JobStore(Path(config.DATA_PATH) / "jobs.sqlite3")
        self.jobs = JobRunner(self.store)

    async def setup_hook(self) -> None:
        """Load all cogs and sync guild-specific slash commands for instant availability."""
        for cog in COGS:
            try:
                await self.load_extension(cog)
                logger.info("Loaded cog: %s", cog)
            except Exception as exc:
                logger.error("Failed to load cog %s: %s", cog, exc)
                raise

        for guild_id in config.GUILD_IDS:
            guild = discord.Object(id=guild_id)
            self.tree.copy_global_to(guild=guild)
            synced = await self.tree.sync(guild=guild)
            logger.info("Synced %d commands to guild %s.", len(synced), guild_id)

    async def on_ready(self) -> None:
        logger.info("%s is online (guilds %s).", self.user, config.GUILD_IDS)
        await self.change_presence(
            activity=discord.Activity(
                type=discord.ActivityType.watching,
                name="the Arma 3 Server",
            )
        )


# ── Entry point ────────────────────────────────────────────────────────────────

async def main() -> None:
    bot = ArmaBot()
    try:
        await bot.start(config.DISCORD_TOKEN)
    except KeyboardInterrupt:
        logger.info("Shutdown requested.")
    except Exception as exc:
        logger.error("Bot encountered an error: %s", exc)
        raise
    finally:
        await bot.close()


if __name__ == "__main__":
    asyncio.run(main())
