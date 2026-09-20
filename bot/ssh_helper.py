"""
SSH / SFTP helpers for communicating with the Windows host.

All functions open a fresh connection per call — this keeps things simple and
avoids stale connection issues for a low-frequency management bot.
"""

import base64
import logging
import json
import re
from pathlib import Path

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
        known_hosts=config.SSH_KNOWN_HOSTS,
        connect_timeout=15,
        login_timeout=15,
    )


# ── Command execution ──────────────────────────────────────────────────────────

_SCRIPTS = {
    "scripts/Start-Server.ps1": {"Profile"},
    "scripts/Stop-Server.ps1": {"Profile"},
    "scripts/Restart-Server.ps1": {"Profile"},
    "scripts/Set-InstancePreset.ps1": {"Profile", "Preset"},
    "scripts/Get-ServerStatus.ps1": {"Profile"},
    "scripts/Auto-Update.ps1": set(),
    "setup/Update-Server.ps1": set(),
    "mods/Sync-Mods.ps1": {"Profile", "Force", "Update", "RestartServer", "CheckOnly"},
    "mods/Import-Preset.ps1": {"Profile", "PresetFile", "Merge", "SyncAfter"},
}


def build_ps_invocation(rel_path: str, parameters: dict) -> str:
    """Pass untrusted values as JSON data, never as executable PowerShell text."""
    if rel_path not in _SCRIPTS or set(parameters) - _SCRIPTS[rel_path]:
        raise ValueError("Unsupported host operation or parameter")
    for key, value in parameters.items():
        if not isinstance(value, (str, bool, int)):
            raise ValueError("Unsupported parameter value")
        if key in {"Profile", "Preset"} and not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}|_all", str(value)):
            raise ValueError("Invalid profile or preset ID")
        if value == "_all" and (rel_path != "mods/Sync-Mods.ps1" or key != "Profile"):
            raise ValueError("_all is only supported for owner mod synchronization")
    payload = base64.b64encode(json.dumps(parameters, ensure_ascii=True).encode("utf-8")).decode("ascii")
    script_path = config.SCRIPTS_PATH.rstrip("\\") + "\\" + rel_path.replace("/", "\\")
    literal = "'" + script_path.replace("'", "''") + "'"
    return (
        "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; "
        f"$data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{payload}')) | ConvertFrom-Json; "
        "$parameters = @{}; foreach ($property in $data.PSObject.Properties) { $parameters[$property.Name] = $property.Value }; "
        f"try {{ $global:LASTEXITCODE = 0; & {literal} @parameters; $ok = $?; "
        "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; if (-not $ok) { exit 1 } } catch { "
        # Write-Error under ErrorActionPreference=Stop replaces the original
        # error location with this wrapper. Report metadata without source text
        # (which may contain credentials or other sensitive argument values).
        "[Console]::Error.WriteLine(('Host operation failed: {0}' -f $_.Exception.Message)); "
        "[Console]::Error.WriteLine(('At {0}:{1}' -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)); "
        "[Console]::Error.WriteLine(('Error ID: {0}' -f $_.FullyQualifiedErrorId)); exit 1 }"
    )


async def run_ps_file(rel_path: str, **parameters) -> tuple[int, str]:
    log.info("Host operation: %s profile=%r", rel_path, parameters.get("Profile"))
    return await run_ps_command(build_ps_invocation(rel_path, parameters))


async def run_ps_command(ps_code: str) -> tuple[int, str]:
    """
    Execute an inline PowerShell expression via -EncodedCommand.
    Avoids any shell-escaping issues with special characters.
    """
    # EncodedCommand can serialize redirected warning/information streams as
    # CLIXML even with -OutputFormat Text. Convert each merged stream record to
    # text before the console host serializes it; keep direct stderr and exits.
    transport = (
        "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); "
        "$ProgressPreference = 'SilentlyContinue'; & {\n" + ps_code +
        "\n} *>&1 | ForEach-Object { [Console]::Out.WriteLine([string]$_) }"
    )
    encoded = base64.b64encode(transport.encode("utf-16-le")).decode()
    cmd     = f"powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -OutputFormat Text -EncodedCommand {encoded}"
    return await _exec(cmd)


async def _exec(cmd: str) -> tuple[int, str]:
    if not Path(config.SSH_KNOWN_HOSTS).is_file():
        return 1, "SSH host key file is missing. Run setup/Export-SshHostKey.ps1 on the dedicated host."
    try:
        async with asyncssh.connect(**_connection_params()) as conn:
            result = await conn.run(cmd, check=False, timeout=config.SSH_TIMEOUT_SECONDS)
    except (asyncssh.Error, OSError, TimeoutError) as exc:
        log.error("SSH error: %s", exc)
        return 255, "SSH connection failed or timed out. The host operation may still be running; check status before retrying."

    output = ((result.stdout or "") + (result.stderr or "")).strip()
    return result.returncode if result.returncode is not None else 255, output


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
    except (asyncssh.Error, OSError, TimeoutError) as exc:
        raise RuntimeError("SFTP upload failed. See the private bot log.") from exc


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
    "[err]",
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
    Prioritizes diagnostics over routine output when the line budget is full.
    """
    if not text:
        return ""
    if max_lines < 1:
        raise ValueError("max_lines must be positive")

    lines = text.splitlines()

    def _keep(line: str) -> bool:
        lower = line.lower()
        if any(p in lower for p in _KEEP_PATTERNS):
            return True
        if re.search(r"(?:^|\]\s*)current:\s+@", lower):
            return False
        if any(p in lower for p in _SKIP_PATTERNS):
            return False
        return True

    candidates = [i for i, line in enumerate(lines) if _keep(line) or i >= len(lines) - 5]
    diagnostic = re.compile(r"\[err\]|\[warn\]|\bwarning\b|\berror\b|\bfailed\b|\bfailure\b|access denied", re.I)
    critical = [i for i in candidates if diagnostic.search(lines[i])]
    # Keep the first failure even when hundreds of later lines follow it.
    selected = set(critical[:max_lines])
    for index in reversed(candidates):
        if len(selected) >= max_lines:
            break
        selected.add(index)
    result = [lines[i] for i in sorted(selected)]
    hidden = len(lines) - len(selected)
    if hidden:
        result.insert(0, f"… ({hidden} routine or excess lines omitted; diagnostics prioritized) …")
    return "\n".join(result)
