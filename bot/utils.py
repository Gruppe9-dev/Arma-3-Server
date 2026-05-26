"""
Shared utility helpers used across cogs.
"""

import discord

import config


def has_admin_auth(interaction: discord.Interaction) -> bool:
    """
    Return True when the interaction's user is authorised to run admin commands.

    A user is authorised if:
      - their user ID is in DISCORD_ADMIN_USER_IDS, OR
      - they hold at least one role whose ID is in DISCORD_ADMIN_ROLE_IDS
    """
    member = interaction.user
    if not isinstance(member, discord.Member):
        return False

    # Direct user override (same pattern as Requiem Manager)
    if member.id in config.ADMIN_USER_IDS:
        return True

    # Role intersection check
    member_role_ids = {role.id for role in member.roles}
    return bool(member_role_ids & config.ADMIN_ROLE_IDS)
