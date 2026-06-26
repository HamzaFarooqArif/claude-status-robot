# =====================================================================
#  Claude Code status app - MULTI-SESSION monitor.
#  Tray icon = aggregate (WAIT if any session waits > BUSY if any works > IDLE).
#  Floating widget = one mini-robot row per active session: project / state / waited.
#  Driven by per-session state files written by the hooks (keyed by project dir).
#
#  Run (hidden):  powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File cc_status.ps1
# =====================================================================

# ---- config (overridden by config.json; edit via tray "Settings...") ----
$FrameMs           = 90
$StepEvery         = 1
$PollEvery         = 3
$SoundOnWait       = $true
$ToastOnWait       = $true
$ShowWidgetOnStart = $true
$Cell              = 3       # tray-icon robot cell size
$WidgetW           = 240
$RowH              = 30
$MaxRows           = 6
$SessionsDir       = Join-Path $env:USERPROFILE ".claude\cc_status\sessions"
$WaitWav           = Join-Path $PSScriptRoot "assets\voices\excited.wav"

$SelfTest = ($args -contains '-SelfTest')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class CcToast {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DATA {
    public int cbSize; public IntPtr hWnd; public int uID; public int uFlags;
    public int uCallbackMessage; public IntPtr hIcon;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string szTip;
    public int dwState; public int dwStateMask;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string szInfo;
    public int uVersionOrTimeout;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string szInfoTitle;
    public int dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon;
  }
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
  static extern bool Shell_NotifyIcon(int msg, ref DATA d);
  public static bool Show(IntPtr hWnd, int uID, string title, string text, IntPtr hBalloonIcon) {
    var d = new DATA(); d.cbSize = Marshal.SizeOf(typeof(DATA));
    d.hWnd = hWnd; d.uID = uID; d.uFlags = 0x10;
    d.szInfo = text; d.szInfoTitle = title; d.dwInfoFlags = 0x4 | 0x20;
    d.hBalloonIcon = hBalloonIcon; return Shell_NotifyIcon(0x1, ref d);
  }
}
"@

$colors = @{
    BUSY = [System.Drawing.Color]::FromArgb(255, 176, 0); WAIT = [System.Drawing.Color]::FromArgb(255, 215, 0)
    IDLE = [System.Drawing.Color]::FromArgb(105, 165, 235); UNKNOWN = [System.Drawing.Color]::FromArgb(150, 150, 150)
}
$label = @{ BUSY = "on it!"; WAIT = "your turn!"; IDLE = "zzz"; UNKNOWN = "hmm?" }
$Clay = [System.Drawing.Color]::FromArgb(255, 210, 119, 85)
$White = [System.Drawing.Color]::FromArgb(255, 245, 245, 245)
$TAU = 2 * [math]::PI

# tray-icon geometry
$Pad = 2
$IconSize = 13 * $Cell + 2 * $Pad
$OX = $Pad; $OY = [int](($IconSize - 11 * $Cell) / 2)

$BodyRows = @("..XXXXXXXXX..", "..XXXXXXXXX..", "..XXOXXXOXX..", "..XXOXXXOXX..", "XXXXXXXXXXXXX", "XXXXXXXXXXXXX", "..XXXXXXXXX..", "..XXXXXXXXX..")

# load user settings
$VoiceDir = Join-Path $PSScriptRoot "assets\voices"
$ConfigFile = Join-Path $env:USERPROFILE ".claude\cc_status\config.json"
if (Test-Path $ConfigFile) {
    try {
        $cf = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cf.PSObject.Properties.Name -contains 'SoundOnWait') { $SoundOnWait = [bool]$cf.SoundOnWait }
        if ($cf.PSObject.Properties.Name -contains 'ToastOnWait') { $ToastOnWait = [bool]$cf.ToastOnWait }
        if ($cf.PSObject.Properties.Name -contains 'ShowWidgetOnStart') { $ShowWidgetOnStart = [bool]$cf.ShowWidgetOnStart }
        if (($cf.PSObject.Properties.Name -contains 'Voice') -and $cf.Voice) { $vp = Join-Path $VoiceDir $cf.Voice; if (Test-Path $vp) { $WaitWav = $vp } }
    }
    catch {}
}

function Draw-Sprite {
    param($g, [int]$ox, [int]$oy, [int]$cell, $rows, $bodyCol, $eyeCol)
    $bb = New-Object System.Drawing.SolidBrush $bodyCol; $eb = New-Object System.Drawing.SolidBrush $eyeCol
    for ($r = 0; $r -lt $rows.Count; $r++) {
        $line = $rows[$r]
        for ($c = 0; $c -lt $line.Length; $c++) {
            if ($line[$c] -eq 'X') { $g.FillRectangle($bb, $ox + $c * $cell, $oy + $r * $cell, $cell, $cell) }
            elseif ($line[$c] -eq 'O') { $g.FillRectangle($eb, $ox + $c * $cell, $oy + $r * $cell, $cell, $cell) }
        }
    }
    $bb.Dispose(); $eb.Dispose()
}

# Draw a robot at (ox,oy) with given cell size: state-colored glow + pixel body +
# wiggling pixel-tentacle legs + blinking eyes. Used at cell 3 (tray) and cell 2 (rows).
function Draw-RobotAt {
    param($g, [int]$ox, [int]$oy, [int]$cell, [string]$st, [int]$frame)
    $col = if ($colors.ContainsKey($st)) { $colors[$st] } else { $colors.UNKNOWN }
    switch ($st) {
        "BUSY" { $gm = 0.45 + 0.85 * (0.5 - 0.5 * [math]::Cos($TAU * ($frame % 16) / 16)); $amp = $cell * 1.6; $spd = 0.50 }
        "WAIT" { $gm = 0.20 + 1.55 * [math]::Pow((0.5 - 0.5 * [math]::Cos(2 * $TAU * ($frame % 10) / 10)), 0.6); $amp = $cell * 1.3; $spd = 0.85 }
        "IDLE" { $gm = 0.50; $amp = $cell * 0.4; $spd = 0.16 }
        default { $gm = 0.40; $amp = $cell * 0.3; $spd = 0.15 }
    }
    # glow
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $cx = $ox + 6.5 * $cell; $cy = $oy + 5.0 * $cell; $rad = 6.5 * $cell
    $ao = [math]::Min(170, [int](85 * $gm)); $ai = [math]::Min(215, [int](110 * $gm))
    if ($ao -gt 0) { $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($ao, $col.R, $col.G, $col.B)); $g.FillEllipse($b, [single]($cx - $rad), [single]($cy - $rad), [single]($rad * 2), [single]($rad * 2)); $b.Dispose() }
    if ($ai -gt 0) { $ri = $rad * 0.6; $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($ai, $col.R, $col.G, $col.B)); $g.FillEllipse($b, [single]($cx - $ri), [single]($cy - $ri), [single]($ri * 2), [single]($ri * 2)); $b.Dispose() }
    # bob (BUSY) / shake (WAIT)
    $by = if ($st -eq "BUSY") { [int][math]::Round($cell * 0.6 * [math]::Sin($frame * 0.5)) } else { 0 }
    $sx = if ($st -eq "WAIT") { [int][math]::Round($cell * 0.6 * [math]::Sin($frame * 0.9)) } else { 0 }
    $oy2 = $oy + $by; $ox2 = $ox + $sx
    # pixel-tentacle legs
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $topY = $oy2 + 8 * $cell; $segs = 4
    $bb = New-Object System.Drawing.SolidBrush $Clay; $li = 0
    foreach ($lc in 2, 4, 8, 10) {
        $baseX = $ox2 + $lc * $cell
        for ($k = 0; $k -lt $segs; $k++) {
            $frac = $k / ($segs - 1.0)
            $xoff = ($amp * $frac) * [math]::Sin($frame * $spd + $frac * 2.6 + $li * 0.9)
            $g.FillRectangle($bb, [int][math]::Round($baseX + $xoff), ($topY + $k * $cell), $cell, $cell)
        }
        $li++
    }
    $bb.Dispose()
    $eye = if ($st -eq "WAIT" -and (($frame % 22) -lt 3)) { $Clay } elseif ($st -eq "IDLE" -and (($frame % 40) -lt 3)) { $Clay } else { $White }
    Draw-Sprite $g $ox2 $oy2 $cell $BodyRows $Clay $eye
}

# tray icons: one set of animated frames per aggregate state
function New-RobotIcon {
    param([string]$st, [int]$frame)
    $bmp = New-Object System.Drawing.Bitmap $IconSize, $IconSize
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::Transparent)
    Draw-RobotAt $g $OX $OY $Cell $st $frame
    $g.Dispose(); $h = $bmp.GetHicon(); $bmp.Dispose()
    return [System.Drawing.Icon]::FromHandle($h)
}
$icons = @{}
$icons.BUSY = @(0..7  | ForEach-Object { New-RobotIcon "BUSY" $_ })
$icons.WAIT = @(0..9  | ForEach-Object { New-RobotIcon "WAIT" $_ })
$icons.IDLE = @(0..17 | ForEach-Object { New-RobotIcon "IDLE" $_ })
$icons.UNKNOWN = @(New-RobotIcon "UNKNOWN" 0)
$ToastIcon = New-RobotIcon "WAIT" 4

$fProj = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$fStat = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)

function Format-Age([double]$s) {
    $s = [int]$s
    if ($s -lt 60) { return "${s}s" }
    $m = [int]($s / 60); if ($m -lt 60) { return "${m}m" }
    return ("" + [int]($m / 60) + "h" + ($m % 60) + "m")
}
function Read-Sessions {
    $list = @()
    if (Test-Path $SessionsDir) {
        foreach ($f in Get-ChildItem $SessionsDir -Filter *.txt -ErrorAction SilentlyContinue) {
            try { $raw = (Get-Content $f.FullName -Raw -ErrorAction Stop).Trim() } catch { continue }
            if (-not $raw) { continue }
            $parts = $raw -split '\|', 2
            $state = $parts[0].Trim().ToUpper()
            $proj = if ($parts.Count -gt 1 -and $parts[1].Trim()) { Split-Path $parts[1].Trim() -Leaf } else { $f.BaseName }
            $age = ((Get-Date) - $f.LastWriteTime).TotalSeconds
            if ($state -eq 'IDLE' -and $age -gt 900) { continue }       # drop long-finished sessions
            if ($age -gt 7200) { continue }                              # drop very stale entries
            $list += [pscustomobject]@{ state = $state; project = $proj; age = $age }
        }
    }
    $order = @{ WAIT = 0; BUSY = 1; IDLE = 2; UNKNOWN = 3 }
    return @($list | Sort-Object @{e = { $order[$_.state] } }, @{e = { $_.age } })
}
function Get-Aggregate($list) {
    if (@($list | Where-Object { $_.state -eq 'WAIT' }).Count -gt 0) { return 'WAIT' }
    if (@($list | Where-Object { $_.state -eq 'BUSY' }).Count -gt 0) { return 'BUSY' }
    if (@($list).Count -gt 0) { return 'IDLE' }
    return 'IDLE'
}

function Draw-WidgetContent($g, $sessions, $frame) {
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    if (-not $sessions -or @($sessions).Count -eq 0) {
        Draw-RobotAt $g 8 6 2 'IDLE' $frame
        $b = New-Object System.Drawing.SolidBrush $colors.UNKNOWN
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.DrawString("no active sessions", $fStat, $b, [single]44, [single]15); $b.Dispose()
        return
    }
    $i = 0
    foreach ($s in $sessions) {
        if ($i -ge $MaxRows) { break }
        $top = 5 + $i * $RowH
        Draw-RobotAt $g 8 ($top + 2) 2 $s.state $frame
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pb = New-Object System.Drawing.SolidBrush $White
        $g.DrawString($s.project, $fProj, $pb, [single]44, [single]($top + 1)); $pb.Dispose()
        $col = if ($colors.ContainsKey($s.state)) { $colors[$s.state] } else { $colors.UNKNOWN }
        $txt = if ($label.ContainsKey($s.state)) { $label[$s.state] } else { $label.UNKNOWN }
        if ($s.state -eq 'WAIT') { $txt = $txt + "    " + (Format-Age $s.age) }
        $sb = New-Object System.Drawing.SolidBrush $col
        $g.DrawString($txt, $fStat, $sb, [single]44, [single]($top + 15)); $sb.Dispose()
        $i++
    }
}

# ---- shared state ----
$script:sessions = @(); $script:aggState = "IDLE"; $script:lastAgg = $null
$script:tick = 0; $script:step = 0; $script:shownRows = -1
$script:drag = $false; $script:dx = 0; $script:dy = 0

# RenderPng <path>: render the widget with mock sessions, for visual inspection
$RenderPng = $null
for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -eq '-RenderPng') { $RenderPng = $args[$i + 1] } }
if ($RenderPng) {
    $mock = @(
        [pscustomobject]@{ state = 'WAIT'; project = 'claude_status'; age = 134 },
        [pscustomobject]@{ state = 'BUSY'; project = 'my-api'; age = 3 },
        [pscustomobject]@{ state = 'IDLE'; project = 'notes'; age = 22 }
    )
    $h = $mock.Count * $RowH + 10
    $bmp = New-Object System.Drawing.Bitmap $WidgetW, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::FromArgb(28, 28, 30))
    Draw-WidgetContent $g $mock 4
    $g.Dispose(); $bmp.Save($RenderPng, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Write-Host "Rendered widget -> $RenderPng"; exit 0
}
if ($SelfTest) {
    $bmp = New-Object System.Drawing.Bitmap $WidgetW, ($RowH * 3 + 10)
    $tg = [System.Drawing.Graphics]::FromImage($bmp)
    Draw-WidgetContent $tg @([pscustomobject]@{ state = 'WAIT'; project = 'x'; age = 5 }) 4
    $tg.Dispose(); $bmp.Dispose()
    Write-Host "SelfTest OK: tray busy=$($icons.BUSY.Count) wait=$($icons.WAIT.Count); widget paints OK"; exit 0
}

# ---- widget form ----
$widget = New-Object System.Windows.Forms.Form
$widget.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$widget.ShowInTaskbar = $false; $widget.TopMost = $true
$widget.Width = $WidgetW; $widget.Height = $RowH + 10
$widget.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 30)
$widget.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$widget.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($widget, $true, $null)
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$widget.Left = $wa.Right - $WidgetW - 12; $widget.Top = $wa.Bottom - $widget.Height - 12

function Set-WidgetRegion($w, $h) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath; $d = 16
    $p.AddArc(0, 0, $d, $d, 180, 90); $p.AddArc($w - $d, 0, $d, $d, 270, 90)
    $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90); $p.AddArc(0, $h - $d, $d, $d, 90, 90); $p.CloseAllFigures()
    $widget.Region = New-Object System.Drawing.Region $p
}
Set-WidgetRegion $WidgetW $widget.Height

$widget.add_Paint({ param($s, $e) Draw-WidgetContent $e.Graphics $script:sessions $script:tick })
$widget.add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:drag = $true; $script:dx = $e.X; $script:dy = $e.Y } })
$widget.add_MouseMove({ param($s, $e) if ($script:drag) { $widget.Left += ($e.X - $script:dx); $widget.Top += ($e.Y - $script:dy) } })
$widget.add_MouseUp({ $script:drag = $false })
$wMenu = New-Object System.Windows.Forms.ContextMenuStrip
$wMenu.Items.Add("Hide widget").add_Click({ Set-Widget $false }) | Out-Null
$widget.ContextMenuStrip = $wMenu

# ---- tray icon + menu ----
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $icons.IDLE[0]; $ni.Text = "Claude Code status"; $ni.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miToggle = New-Object System.Windows.Forms.ToolStripMenuItem("Show widget"); $menu.Items.Add($miToggle) | Out-Null
$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem("Settings..."); $miSettings.add_Click({ Show-Settings }); $menu.Items.Add($miSettings) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem("Exit Claude status"); $menu.Items.Add($miExit) | Out-Null
$ni.ContextMenuStrip = $menu

function Set-Widget([bool]$show) {
    if ($show) { $script:shownRows = -1; $widget.Show(); $widget.BringToFront(); $miToggle.Text = "Hide widget"; $miToggle.Checked = $true }
    else { $widget.Hide(); $miToggle.Text = "Show widget"; $miToggle.Checked = $false }
}
$miToggle.add_Click({ Set-Widget (-not $widget.Visible) })
$miExit.add_Click({ $ni.Visible = $false; $ni.Dispose(); $widget.Close(); [System.Windows.Forms.Application]::Exit() })

function Show-RobotToast($title, $text) {
    try {
        $t = $ni.GetType()
        $uid = [int]$t.GetField('id', [System.Reflection.BindingFlags]'NonPublic,Instance').GetValue($ni)
        $hwnd = $t.GetField('window', [System.Reflection.BindingFlags]'NonPublic,Instance').GetValue($ni).Handle
        [void][CcToast]::Show($hwnd, $uid, $title, $text, $ToastIcon.Handle)
    }
    catch { $ni.ShowBalloonTip(2500, $title, $text, [System.Windows.Forms.ToolTipIcon]::None) }
}

function Save-Config {
    $obj = @{ SoundOnWait = [bool]$script:SoundOnWait; ToastOnWait = [bool]$script:ToastOnWait; ShowWidgetOnStart = [bool]$script:ShowWidgetOnStart; Voice = [System.IO.Path]::GetFileName($script:WaitWav) }
    $d = Split-Path $ConfigFile; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    [System.IO.File]::WriteAllText($ConfigFile, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
}
function Show-Settings {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Claude Status - Settings"; $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen; $f.ClientSize = New-Object System.Drawing.Size(330, 205)
    $chkSound = New-Object System.Windows.Forms.CheckBox; $chkSound.Text = "Play sound when waiting"; $chkSound.AutoSize = $true; $chkSound.Location = New-Object System.Drawing.Point(18, 16); $chkSound.Checked = $script:SoundOnWait
    $chkToast = New-Object System.Windows.Forms.CheckBox; $chkToast.Text = "Show toast notification when waiting"; $chkToast.AutoSize = $true; $chkToast.Location = New-Object System.Drawing.Point(18, 44); $chkToast.Checked = $script:ToastOnWait
    $chkWidget = New-Object System.Windows.Forms.CheckBox; $chkWidget.Text = "Show session list on start"; $chkWidget.AutoSize = $true; $chkWidget.Location = New-Object System.Drawing.Point(18, 72); $chkWidget.Checked = $script:ShowWidgetOnStart
    $lblVoice = New-Object System.Windows.Forms.Label; $lblVoice.Text = "Waiting voice:"; $lblVoice.AutoSize = $true; $lblVoice.Location = New-Object System.Drawing.Point(18, 108)
    $cmbVoice = New-Object System.Windows.Forms.ComboBox; $cmbVoice.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList; $cmbVoice.Location = New-Object System.Drawing.Point(110, 105); $cmbVoice.Width = 140
    if (Test-Path $VoiceDir) { Get-ChildItem $VoiceDir -Filter *.wav | ForEach-Object { [void]$cmbVoice.Items.Add([System.IO.Path]::GetFileNameWithoutExtension($_.Name)) } }
    $curVoice = [System.IO.Path]::GetFileNameWithoutExtension($script:WaitWav)
    if ($cmbVoice.Items.Contains($curVoice)) { $cmbVoice.SelectedItem = $curVoice } elseif ($cmbVoice.Items.Count -gt 0) { $cmbVoice.SelectedIndex = 0 }
    $btnTest = New-Object System.Windows.Forms.Button; $btnTest.Text = "Test"; $btnTest.Location = New-Object System.Drawing.Point(258, 104); $btnTest.Width = 55
    $btnTest.add_Click({ $s = $cmbVoice.SelectedItem; if ($s) { (New-Object System.Media.SoundPlayer (Join-Path $VoiceDir "$s.wav")).Play() } })
    $btnOK = New-Object System.Windows.Forms.Button; $btnOK.Text = "Save"; $btnOK.Location = New-Object System.Drawing.Point(160, 160); $btnOK.Width = 75
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "Cancel"; $btnCancel.Location = New-Object System.Drawing.Point(245, 160); $btnCancel.Width = 75
    $btnCancel.add_Click({ $f.Close() }); $f.CancelButton = $btnCancel
    $btnOK.add_Click({
            $script:SoundOnWait = $chkSound.Checked; $script:ToastOnWait = $chkToast.Checked; $script:ShowWidgetOnStart = $chkWidget.Checked
            $sel = $cmbVoice.SelectedItem
            if ($sel) { $script:WaitWav = Join-Path $VoiceDir "$sel.wav"; try { $script:waitPlayer = New-Object System.Media.SoundPlayer $script:WaitWav; $script:waitPlayer.Load() } catch { $script:waitPlayer = $null } }
            Save-Config; $f.Close()
        })
    $f.Controls.AddRange(@($chkSound, $chkToast, $chkWidget, $lblVoice, $cmbVoice, $btnTest, $btnOK, $btnCancel))
    [void]$f.ShowDialog()
}

$waitPlayer = $null
if (Test-Path $WaitWav) { try { $waitPlayer = New-Object System.Media.SoundPlayer $WaitWav; $waitPlayer.Load() } catch { $waitPlayer = $null } }

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = $FrameMs
$timer.add_Tick({
        $script:tick++
        if (($script:tick % $PollEvery) -eq 0 -or $null -eq $script:lastAgg) {
            $script:sessions = Read-Sessions
            $agg = Get-Aggregate $script:sessions
            $script:aggState = $agg
            $nb = @($script:sessions | Where-Object { $_.state -eq 'BUSY' }).Count
            $nw = @($script:sessions | Where-Object { $_.state -eq 'WAIT' }).Count
            $ni.Text = "Claude: $(@($script:sessions).Count) session(s)" + $(if ($nw) { " - $nw waiting" } elseif ($nb) { " - $nb working" } else { " - idle" })
            if ($agg -ne $script:lastAgg) {
                if ($agg -eq 'WAIT') {
                    if ($SoundOnWait) { if ($waitPlayer) { $waitPlayer.Play() } else { [System.Media.SystemSounds]::Asterisk.Play() } }
                    if ($ToastOnWait) { $wp = (@($script:sessions | Where-Object { $_.state -eq 'WAIT' } | ForEach-Object { $_.project }) -join ', '); Show-RobotToast "Claude needs you" ("Waiting: $wp") }
                }
                elseif ($script:lastAgg -eq 'WAIT' -and $ToastOnWait) { $ni.Visible = $false; $ni.Visible = $true }
                $script:lastAgg = $agg
            }
            if ($widget.Visible) {
                $n = [Math]::Max(1, [Math]::Min($MaxRows, @($script:sessions).Count))
                if ($n -ne $script:shownRows) {
                    $hh = $n * $RowH + 10; $bottom = $widget.Top + $widget.Height
                    $widget.Height = $hh; $widget.Top = $bottom - $hh
                    Set-WidgetRegion $WidgetW $hh; $script:shownRows = $n
                }
            }
        }
        $script:step++
        $frames = if ($icons.ContainsKey($script:aggState)) { $icons[$script:aggState] } else { $icons.UNKNOWN }
        $ni.Icon = $frames[$script:step % $frames.Count]
        if ($widget.Visible) { $widget.Invalidate() }
    })
$timer.Start()
Set-Widget $ShowWidgetOnStart

[System.Windows.Forms.Application]::Run()
