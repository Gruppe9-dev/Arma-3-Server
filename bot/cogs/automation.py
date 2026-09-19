"""Background scheduler for idle-only Arma 3 maintenance."""

import asyncio
import contextlib
import logging
import re

from discord.ext import commands

import config
import ssh_helper

logger = logging.getLogger(__name__)


def update_outcome(code: int, output: str) -> tuple[str, str]:
    """An idle/lock skip is not a successful engine/Workshop update."""
    if code == 255:
        return "unknown", "transport_failure"
    if code != 0:
        return "failed", "host_failure"
    markers = re.findall(r"\bAUTO_UPDATE_RESULT=([a-z_]+)\s*$", output, re.MULTILINE)
    result = markers[-1] if markers else "missing_result"
    if result == "complete":
        return "completed", result
    if result in {"skipped_active", "skipped_locked"}:
        return "skipped", result
    if result == "failed":
        return "failed", result
    return "unknown", result


class AutomationCog(commands.Cog):
    """Runs the host-side update cycle at a configured interval."""

    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot
        self._scheduler_task: asyncio.Task[None] | None = None

    async def cog_load(self) -> None:
        if not config.AUTO_UPDATE_ENABLED:
            logger.warning(
                "Automatic updates are disabled (BOT_AUTO_UPDATE_ENABLED=false). "
                "No scheduled server or mod updates will run. Set it to true and restart the bot to enable them."
            )
            return

        self._scheduler_task = asyncio.create_task(
            self._run_scheduler(), name="arma3-auto-update"
        )

    async def cog_unload(self) -> None:
        if self._scheduler_task is None:
            return

        self._scheduler_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._scheduler_task

    async def _run_scheduler(self) -> None:
        await self.bot.wait_until_ready()
        logger.info(
            "Automatic updates enabled: interval=%d minutes, initial_delay=%d seconds.",
            config.AUTO_UPDATE_INTERVAL_MINUTES,
            config.AUTO_UPDATE_INITIAL_DELAY_SECONDS,
        )

        if config.AUTO_UPDATE_INITIAL_DELAY_SECONDS:
            await asyncio.sleep(config.AUTO_UPDATE_INITIAL_DELAY_SECONDS)

        while not self.bot.is_closed():
            await self._run_update_cycle()
            logger.info("Next automatic update check in %d minutes.", config.AUTO_UPDATE_INTERVAL_MINUTES)
            await asyncio.sleep(config.AUTO_UPDATE_INTERVAL_MINUTES * 60)

    async def _run_update_cycle(self) -> None:
        timeout_seconds = config.AUTO_UPDATE_TIMEOUT_MINUTES * 60
        logger.info("Starting automatic update check.")

        try:
            async with self.bot.jobs.lock:
                job_id = self.bot.store.create(0, 0, "", "automatic-update")
                self.bot.store.mark(job_id, "running")
                try:
                    code, output = await asyncio.wait_for(
                        ssh_helper.run_ps_file("scripts/Auto-Update.ps1"),
                        timeout=timeout_seconds,
                    )
                    status, reason = update_outcome(code, output)
                    self.bot.store.mark(job_id, status, code)
                except BaseException:
                    self.bot.store.mark(job_id, "interrupted")
                    raise
        except TimeoutError:
            logger.error(
                "Automatic update timed out after %d minutes.",
                config.AUTO_UPDATE_TIMEOUT_MINUTES,
            )
            return
        except Exception:
            logger.exception("Automatic update check crashed.")
            return

        filtered = ssh_helper.filter_output(output, max_lines=80)
        if status == "completed":
            logger.info("Automatic server and Workshop updates completed.\n%s", filtered)
        elif status == "skipped":
            logger.info("Automatic updates skipped (%s); no updates were applied.\n%s", reason, filtered)
        else:
            logger.error(
                "Automatic update outcome=%s reason=%s exit_code=%d.\n%s", status, reason, code, filtered
            )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(AutomationCog(bot))
