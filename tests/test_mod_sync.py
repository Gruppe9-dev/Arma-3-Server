"""Run real sync control flow with isolated files and mocked Steam/host helpers."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


COMMON = r'''
$fixture = Split-Path -Parent $PSScriptRoot
function Get-FrameworkConfig {
    [PSCustomObject]@{ SteamCMDPath="$fixture\steamcmd"; WorkshopStagingPath="$fixture\workshop";
        ServerInstallPath="$fixture\shared"; SteamUsername='fixture' }
}
function Write-Log { param($Message,$Level='Info') Write-Output "[$Level] $Message" }
function Enter-FrameworkMaintenanceLock { return 'fixture-lock' }
function Exit-FrameworkMaintenanceLock { param($Lock,$Config) }
function Get-Profile { param($ProfileName) return (Get-Content "$fixture\profile.json" -Raw | ConvertFrom-Json) }
function Get-ProfileWorkshopEntries { param($Profile) $Profile.WorkshopIds }
function Get-SharedWorkshopCatalog { param($AdditionalEntries) }
function Get-ServerProcesses { }
function Assert-ServersIdle { }
function Read-SteamPassword { param($Username,$Config) return 'fixture-password' }
function Invoke-RestMethod {
    param($Method,$Uri,$Body,$ContentType,$TimeoutSec)
    if ($Uri -ne 'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/') { throw 'Unexpected API' }
    return (Get-Content "$fixture\metadata.json" -Raw | ConvertFrom-Json)
}
function Invoke-SteamCMD {
    param($SteamCMDExe,$Username,$Password,$PreLoginCommands,$Commands)
    if (Test-Path "$fixture\fail-download") { return 9 }
    foreach ($command in $Commands) {
        if ($command -notmatch '^workshop_download_item 107410 (\d+) validate$') { throw 'Unexpected Steam command' }
        $id=$Matches[1]
        $path=Join-Path $fixture "workshop\steamapps\workshop\content\107410\$id"
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $path 'fixture.pbo') -Value "updated-$id"
    }
    return 0
}
'''


@unittest.skipUnless(sys.platform == "win32", "PowerShell sync integration")
class ModSyncTests(unittest.TestCase):
    def run_sync(self, *, failed=False, update=False, excluded=False, check_only=False, sync=False, download_failure=False):
        with tempfile.TemporaryDirectory(prefix="arma-sync-tests-") as folder:
            root = Path(folder)
            for name in ("scripts", "mods", "shared", "steamcmd", "workshop"):
                (root / name).mkdir()
            shutil.copyfile(Path(__file__).resolve().parents[1] / "mods/Sync-Mods.ps1", root / "mods/Sync-Mods.ps1")
            (root / "scripts/Common.ps1").write_text(COMMON, encoding="utf-8-sig")
            (root / "steamcmd/steamcmd.exe").write_text("never executed")
            if download_failure:
                (root / "fail-download").touch()
            mods = [{"Id": "100", "FolderName": "@available"}]
            details = [{"publishedfileid": "100", "result": 1, "consumer_app_id": 107410,
                        "time_updated": 2 if update else 1, "title": "Available mod"}]
            if failed:
                mods.append({"Id": "3746219164", "FolderName": "@unavailable"})
                details.append({"publishedfileid": "3746219164", "result": 9})
            for mod in mods:
                target = root / "shared" / mod["FolderName"]
                target.mkdir()
                (target / "fixture.pbo").write_text("original")
            (root / "profile.json").write_text(json.dumps({"WorkshopIds": mods}))
            (root / "metadata.json").write_text(json.dumps({"response": {"publishedfiledetails": details}}))
            (root / "workshop/workshop-deploy-state.json").write_text(json.dumps({"100": {"TimeUpdated": 1}}))
            (root / "mods/update-exclusions.json").write_text(json.dumps({"WorkshopIds": ["100"] if excluded else []}))
            result = subprocess.run([os.environ.get("ARMA_TEST_POWERSHELL", "powershell.exe"),
                                     "-NoProfile", "-NonInteractive", "-File", str(root / "mods/Sync-Mods.ps1"),
                                     "-Profile", "fixture", *( ["-Force"] if sync else ["-Update"] ),
                                     *( ["-CheckOnly"] if check_only else [] )], capture_output=True, text=True, timeout=30)
            files = {mod["Id"]: (root / "shared" / mod["FolderName"] / "fixture.pbo").read_text().strip() for mod in mods}
            return result.returncode, result.stdout + result.stderr, files

    def test_unavailable_item_is_failure_without_false_success(self):
        code, output, files = self.run_sync(failed=True)
        self.assertEqual(code, 1, output)
        self.assertIn("3746219164 (@unavailable)", output)
        self.assertIn("FileNotFound", output)
        self.assertIn("Sync Incomplete", output)
        self.assertNotIn("everything is current", output)
        self.assertEqual(files["3746219164"], "original")

    def test_available_updates_proceed_despite_unavailable_item(self):
        code, output, files = self.run_sync(failed=True, update=True)
        self.assertEqual(code, 1, output)
        self.assertIn("Sync Incomplete", output)
        self.assertEqual(files["100"], "updated-100", output)
        self.assertEqual(files["3746219164"], "original")
        summary = json.loads(next(line.removeprefix("MOD_SYNC_RESULT=") for line in output.splitlines() if line.startswith("MOD_SYNC_RESULT=")))
        self.assertEqual(summary, dict(Mode="update", Total=2, Current=0, Deployed=1, Pending=0, Excluded=0, Failed=1, NotProcessed=0))

    def test_structured_counts_for_checks_sync_and_batch_failure(self):
        cases = [({"check_only": True}, "check", 0, 1, 0, 0),
                 ({"check_only": True, "update": True}, "check", 0, 0, 1, 0),
                 ({"sync": True}, "sync", 1, 0, 0, 0),
                 ({"update": True, "download_failure": True}, "update", 0, 0, 0, 1)]
        for options, mode, deployed, current, pending, failed in cases:
            with self.subTest(options=options):
                code, output, _ = self.run_sync(**options)
                self.assertEqual(code, 1 if failed else 0, output)
                records = [line.removeprefix("MOD_SYNC_RESULT=") for line in output.splitlines() if line.startswith("MOD_SYNC_RESULT=")]
                self.assertEqual(len(records), 1, output)
                self.assertEqual(json.loads(records[0]), dict(Mode=mode, Total=1, Deployed=deployed,
                    Current=current, Pending=pending, Excluded=0, Failed=failed, NotProcessed=0))

    def test_current_and_excluded_summaries_are_distinct(self):
        for excluded in (False, True):
            with self.subTest(excluded=excluded):
                code, output, _ = self.run_sync(excluded=excluded)
                self.assertEqual(code, 0, output)
                self.assertIn("explicitly excluded" if excluded else "everything is current", output)
                if excluded:
                    self.assertNotIn("everything is current", output)


if __name__ == "__main__":
    unittest.main()
