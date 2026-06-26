# Claude Code Status Robot - uninstaller.
# Removes the status hooks from your user settings.json and the startup shortcut.
# Leaves your other settings/hooks untouched.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
$ErrorActionPreference = 'Stop'
$settings = Join-Path $env:USERPROFILE ".claude\settings.json"

if (Test-Path $settings) {
    Copy-Item $settings "$settings.bak" -Force
    $cfg = Get-Content $settings -Raw | ConvertFrom-Json
    if ($cfg.PSObject.Properties.Name -contains 'hooks') {
        $hooks = $cfg.hooks
        foreach ($ev in @($hooks.PSObject.Properties.Name)) {
            $kept = @($hooks.$ev) | Where-Object {
                $ours = $false
                foreach ($hh in @($_.hooks)) { if (("$($hh.args) $($hh.command)") -match 'set_state|remove_session') { $ours = $true } }
                -not $ours
            }
            if (@($kept).Count -eq 0) { $hooks.PSObject.Properties.Remove($ev) }
            else { $hooks.$ev = $kept }
        }
    }
    $json = $cfg | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Removed status hooks from $settings (backup: settings.json.bak)"
}
else { Write-Host "No settings.json found - nothing to remove." }

$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "Claude Status.lnk"
if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force; Write-Host "Removed startup shortcut." }

Write-Host "Done. Quit the tray robot via its right-click menu if it's running, then open /hooks or restart Claude Code."
