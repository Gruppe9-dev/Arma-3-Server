"""Authorization for every command and autocomplete interaction."""

import logging

import discord

import config
from access import valid_profile

log = logging.getLogger(__name__)


def has_admin_auth(interaction: discord.Interaction) -> bool:
    """Owner-only maintenance, scoped to an explicitly allowed guild."""
    if not isinstance(interaction.user, discord.Member) or interaction.guild_id not in config.GUILD_IDS:
        return False
    if config.ACCESS_POLICY:
        return config.ACCESS_POLICY.is_owner(interaction.guild_id, interaction.user.id)
    return interaction.user.id in config.ADMIN_USER_IDS or bool(
        {role.id for role in interaction.user.roles} & config.ADMIN_ROLE_IDS
    )


def can_access(interaction: discord.Interaction, action: str, profile: str) -> bool:
    if not valid_profile(profile) or not isinstance(interaction.user, discord.Member):
        return False
    if config.ACCESS_POLICY:
        return config.ACCESS_POLICY.allows(
            interaction.guild_id, interaction.user.id,
            {role.id for role in interaction.user.roles}, action, profile,
        )
    return has_admin_auth(interaction)


async def require_access(interaction: discord.Interaction, action: str, profile: str) -> bool:
    if can_access(interaction, action, profile):
        return True
    log.warning("Denied action=%s guild=%s user=%s profile=%r", action, interaction.guild_id, interaction.user.id, profile)
    await interaction.response.send_message("You do not have access to this instance/action.", ephemeral=True)
    return False


def has_any_access(interaction: discord.Interaction) -> bool:
    if config.ACCESS_POLICY:
        return any(can_access(interaction, "list", profile)
                   for profile in config.ACCESS_POLICY.guilds.get(interaction.guild_id, {}))
    return has_admin_auth(interaction)
