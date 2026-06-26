# Live view of the per-session state files the hooks write (debug tool).
#   powershell -ExecutionPolicy Bypass -File watch_state.ps1
$dir = Join-Path $env:USERPROFILE ".claude\cc_status\sessions"
Write-Host "Watching $dir   (Ctrl+C to stop)`n"
while ($true) {
    Clear-Host
    Write-Host ((Get-Date).ToString('HH:mm:ss') + "  sessions:`n")
    if (Test-Path $dir) {
        $any = $false
        Get-ChildItem $dir -Filter *.txt -ErrorAction SilentlyContinue | ForEach-Object {
            $any = $true
            $raw = (Get-Content $_.FullName -Raw).Trim()
            $p = $raw -split '\|', 2
            $proj = if ($p.Count -gt 1 -and $p[1].Trim()) { Split-Path $p[1].Trim() -Leaf } else { $_.BaseName }
            $age = [int]((Get-Date) - $_.LastWriteTime).TotalSeconds
            "  {0,-6} {1,-28} {2}s ago" -f $p[0], $proj, $age
        }
        if (-not $any) { "  (no active sessions)" }
    }
    else { "  (no sessions folder yet)" }
    Start-Sleep -Milliseconds 400
}
