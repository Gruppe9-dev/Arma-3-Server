"""Message-bound persistent server controls; authorization lives in ServerCog."""

import discord


class ServerControlView(discord.ui.View):
    def __init__(self, cog, guild_id: int, profile: str):
        super().__init__(timeout=None)
        self.cog = cog
        self.guild_id = guild_id
        self.profile = profile

    def set_state(self, running: bool | None, *, busy: bool = False):
        self.start.disabled = busy or running is True
        self.stop_server.disabled = busy or running is False

    @discord.ui.button(label="Start", emoji="▶️", style=discord.ButtonStyle.success,
                       custom_id="arma:server-control:start:v1")
    async def start(self, interaction: discord.Interaction, button: discord.ui.Button):
        await self.cog.control_action(interaction, self.guild_id, self.profile, "start")

    @discord.ui.button(label="Stop", emoji="⏹️", style=discord.ButtonStyle.danger,
                       custom_id="arma:server-control:stop:v1")
    async def stop_server(self, interaction: discord.Interaction, button: discord.ui.Button):
        await self.cog.control_action(interaction, self.guild_id, self.profile, "stop")

    @discord.ui.button(label="Refresh", emoji="🔄", style=discord.ButtonStyle.secondary,
                       custom_id="arma:server-control:refresh:v1")
    async def refresh(self, interaction: discord.Interaction, button: discord.ui.Button):
        await self.cog.control_action(interaction, self.guild_id, self.profile, "status")

    async def on_error(self, interaction: discord.Interaction, error: Exception, item):
        # Do not publish host details or tracebacks into a community channel.
        self.cog.log_control_error(error)
        if interaction.response.is_done():
            await interaction.followup.send("The panel action failed. Please try again or contact the owner.", ephemeral=True)
        else:
            await interaction.response.send_message("The panel action failed. Please try again or contact the owner.", ephemeral=True)
