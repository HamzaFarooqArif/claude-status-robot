# Claude Code Status Robot - installer.
# Adds the status hooks to YOUR user settings.json (pointing at this folder),
# unblocks the scripts, and creates the launch shortcut. Safe to re-run.
#   powershell -ExecutionPolicy Bypass -File install.ps1            # install
#   powershell -ExecutionPolicy Bypass -File install.ps1 -StartAtLogin   # + run at login
param([switch]$StartAtLogin)
$ErrorActionPreference = 'Stop'

$root      = $PSScriptRoot
$cmd       = Join-Path $root "hooks\set_state.cmd"
$removeCmd = Join-Path $root "hooks\remove_session.cmd"
$claudeD   = Join-Path $env:USERPROFILE ".claude"
$settings = Join-Path $claudeD "settings.json"
if (-not (Test-Path $claudeD)) { New-Item -ItemType Directory -Force $claudeD | Out-Null }

# unblock files downloaded from the internet (mark-of-the-web)
Get-ChildItem $root -Recurse -Include *.ps1, *.cmd, *.wav | Unblock-File -ErrorAction SilentlyContinue

# load existing settings (back up first) or start fresh
if (Test-Path $settings) {
    Copy-Item $settings "$settings.bak" -Force
    Write-Host "Backed up settings.json -> settings.json.bak"
    $cfg = Get-Content $settings -Raw | ConvertFrom-Json
}
else { $cfg = [pscustomobject]@{} }
if ($cfg.PSObject.Properties.Name -notcontains 'hooks') {
    $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
$hooks = $cfg.hooks

function New-Group($matcher, $argv) {
    $h = @{ type = 'command'; command = 'cmd'; args = $argv; async = $true }
    if ($matcher) { return @{ matcher = $matcher; hooks = @($h) } }
    return @{ hooks = @($h) }
}

$spec = @(
    @{ ev = 'UserPromptSubmit'; m = $null; a = @('/c', $cmd, 'BUSY') },
    @{ ev = 'PreToolUse'; m = $null; a = @('/c', $cmd, 'BUSY') },
    @{ ev = 'PostToolUse'; m = $null; a = @('/c', $cmd, 'BUSY') },
    @{ ev = 'PermissionRequest'; m = $null; a = @('/c', $cmd, 'WAIT') },
    @{ ev = 'Notification'; m = 'permission_prompt'; a = @('/c', $cmd, 'WAIT') },
    @{ ev = 'Stop'; m = $null; a = @('/c', $cmd, 'IDLE') },
    @{ ev = 'SessionEnd'; m = $null; a = @('/c', $removeCmd) }
)
foreach ($x in $spec) {
    # keep any of the user's own groups, drop our previous ones (idempotent re-install)
    $keep = @()
    if ($hooks.PSObject.Properties.Name -contains $x.ev) {
        $keep = @($hooks.($x.ev)) | Where-Object {
            $ours = $false
            foreach ($hh in @($_.hooks)) { if (("$($hh.args) $($hh.command)") -match 'set_state|remove_session') { $ours = $true } }
            -not $ours
        }
    }
    $combined = @($keep) + @((New-Group $x.m $x.a))
    if ($hooks.PSObject.Properties.Name -contains $x.ev) { $hooks.($x.ev) = $combined }
    else { $hooks | Add-Member -NotePropertyName $x.ev -NotePropertyValue $combined }
}

$json = $cfg | ConvertTo-Json -Depth 100
[System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Hooks installed into $settings"

# (re)create the launch shortcut for THIS folder
$lnk = Join-Path $root "Claude Status.lnk"
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\cc_status.ps1`""
$sc.WorkingDirectory = $root
$sc.IconLocation = "$root\assets\robot.ico,0"
$sc.Description = "Claude Code status robot"
$sc.WindowStyle = 7
$sc.Save()
Write-Host "Created shortcut: $lnk"

if ($StartAtLogin) {
    $startup = [Environment]::GetFolderPath('Startup')
    Copy-Item $lnk (Join-Path $startup "Claude Status.lnk") -Force
    Write-Host "Added to startup (runs at login): $startup"
}

Write-Host ""
Write-Host "Done. Next:"
Write-Host "  1) In Claude Code, open /hooks once (reloads hooks) or restart Claude Code."
Write-Host "  2) Double-click 'Claude Status.lnk' (or run start_status.cmd) to launch the robot."
Write-Host "  Uninstall later with:  powershell -ExecutionPolicy Bypass -File uninstall.ps1"
