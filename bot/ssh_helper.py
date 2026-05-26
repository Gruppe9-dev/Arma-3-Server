"""
SSH / SFTP helpers for communicating with the Windows host.

All functions open a fresh connection per call — this keeps things simple and
avoids stale connection issues for a low-frequency management bot.
"""

import base64
import logging

import asyncssh

import config

log = logging.getLogger(__name__)

_ssh_key: asyncssh.SSHKey | None = None


def _get_key() -> asyncssh.SSHKey:
    """Load the private key once and cache it for the process lifetime."""
    global _ssh_key
    if _ssh_key is None:
        _ssh_key = asyncssh.read_private_key(config.SSH_KEY_PATH)
    return _ssh_key


def _connection_params() -> dict:
    return dict(
        host=config.SSH_HOST,
        port=config.SSH_PORT,
        username=config.SSH_USER,
        client_keys=[_get_key()],
        known_hosts=None,   # host-key pinning is not required for local container→host traffic
    )


# ── Command execution ──────────────────────────────────────────────────────────

async def run_ps_file(rel_path: str, *args: str) -> tuple[int, str]:
    """
    Execute a PowerShell script file from SCRIPTS_PATH on the host via SSH.

    rel_path uses forward slashes relative to SCRIPTS_PATH,
    e.g. "scripts/Start-Server.ps1" or "mods/Sync-Mods.ps1".
    """
    abs_path = config.SCRIPTS_PATH.rstrip("\\") + "\\" + rel_path.replace("/", "\\")
    extra    = " ".join(args)
    cmd      = f'powershell.exe -ExecutionPolicy Bypass -NonInteractive -File "{abs_path}" {extra}'.strip()
    return await _exec(cmd)


async def run_ps_command(ps_code: str) -> tuple[int, str]:
    """
    Execute an inline PowerShell expression via -EncodedCommand.
    Avoids any shell-escaping issues with special characters.
    """
    encoded = base64.b64encode(ps_code.encode("utf-16-le")).decode()
    cmd     = f"powershell.exe -ExecutionPolicy Bypass -NonInteractive -EncodedCommand {encoded}"
    return await _exec(cmd)


async def _exec(cmd: str) -> tuple[int, str]:
    log.info("SSH exec → %s", cmd)
    try:
        async with asyncssh.connect(**_connection_params()) as conn:
            result = await conn.run(cmd, check=False)
    except (asyncssh.Error, OSError) as exc:
        log.error("SSH error: %s", exc)
        return 1, f"SSH-Verbindungsfehler: {exc}"

    output = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode or 0, output


# ── File upload ────────────────────────────────────────────────────────────────

async def upload_bytes(data: bytes, remote_path: str) -> None:
    """
    Upload raw bytes to an absolute Windows path on the host via SFTP.

    remote_path is the Windows-style absolute path, e.g.:
        C:\\#Arma Server\\Framework\\Arma-3-Server\\presets\\Preset.html
    The path is converted to forward slashes for the SFTP protocol.
    """
    sftp_path = remote_path.replace("\\", "/")
    parent    = sftp_path.rsplit("/", 1)[0]
    log.info("SFTP upload → %s", sftp_path)

    try:
        async with asyncssh.connect(**_connection_params()) as conn:
            async with conn.start_sftp_client() as sftp:
                try:
                    await sftp.makedirs(parent, exist_ok=True)
                except asyncssh.SFTPError:
                    pass  # directory already exists — makedirs may raise on some servers

                async with await sftp.open(sftp_path, "wb") as f:
                    await f.write(data)
    except (asyncssh.Error, OSError) as exc:
        raise RuntimeError(f"SFTP-Upload fehlgeschlagen: {exc}") from exc


# ── Shared reply helpers ───────────────────────────────────────────────────────

def split_output(text: str, size: int = config.MAX_CHARS) -> list[str]:
    """Split output into chunks that fit within Discord's message limit."""
    if not text:
        return ["(no output)"]
    return [text[i : i + size] for i in range(0, len(text), size)]


    # Lines containing these strings are dropped from Discord output (verbose noise)
_SKIP_PATTERNS = [
    # PowerShell CLIXML progress-stream serialisation (appears when stdout is captured via SSH)
    "#< clixml",
    "<objs ",
    "<obj ",
    "<tn ",
    "<tnref ",
    "<ms>",
    "<i64 ",
    "<pr>",
    "<pr ",
    "<av>",
    "<ai>",
    "<nil ",
    "<pi>",
    "<pc>",
    "<t>",
    "<sr>",
    "<sd>",
    "</",
    # General framework noise
    "already deployed",
    "config loaded from",
    # SteamCMD boilerplate
    "running steamcmd",
    "redirecting stderr",
    "logging directory",
    "checking for available updates",
    "verifying installation",
    "steam console client",
    "loading steam api",
    "logging in user",
    "waiting for client config",
    "waiting for user info",
    "unloading steam api",
    "please use force_install_dir",
    # Server start verbose lines
    "command:",           # full command-line with all mods (huge)
    "launching server",
    "waiting for server on port",
    "server did not respond to udp",
    "starting hcs in",
    "server    :",        # detail block inside HC start
    "hc name   :",
    "fps limit :",
    "-mod=",              # stray mod-list continuation lines
    "connect=127",        # HC connect line
    "pid saved to",
    "hc pids saved",
    "branch     :",
    "maxplayers :",
    "binary     :",
    "mods       :",
    "port       :",       # startup info block (not the final summary)
    "enableht",           # command-line continuation
]

# Lines containing these strings are always kept
_KEEP_PATTERNS = [
    "warn",
    "error",
    "fail",
    "[ok]",
    "===",
    "success",
    "downloading item",
    "deployed:",
    "key copied",
    "next step",
    "pid      :",
    "port     :",
    "profile  :",
    "hcs      :",
    "to stop",
]


def filter_output(text: str, max_lines: int = 30) -> str:
    """
    Filter verbose PowerShell script output for Discord display.

    Drops repetitive noise (already-deployed notices, SteamCMD boilerplate).
    Always keeps warnings, errors, summaries, and the last few lines.
    """
    if not text:
        return ""

    lines = text.splitlines()

    def _keep(line: str) -> bool:
        lower = line.lower()
        if any(p in lower for p in _KEEP_PATTERNS):
            return True
        if any(p in lower for p in _SKIP_PATTERNS):
            return False
        return True

    filtered = [line for line in lines if _keep(line)]

    # Always include the last 5 lines (summary / next-step hints)
    tail = lines[-5:]
    for line in tail:
        if line not in filtered:
            filtered.append(line)

    # Hard cap — take the last max_lines if still too long
    if len(filtered) > max_lines:
        filtered = [f"… ({len(filtered) - max_lines} lines hidden) …"] + filtered[-max_lines:]

    return "\n".join(filtered)
