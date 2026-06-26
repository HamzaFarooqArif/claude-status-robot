# Synthesize cute EMO-style robot voices -> assets\voices\*.wav
# Richer than pure sines: additive harmonics + detuned chorus + vibrato + low-pass,
# 32 kHz / 16-bit, peak-normalized. Each voice = a sequence of pitch glides (an emotion).
# Run: powershell -ExecutionPolicy Bypass -File assets\make_voices.ps1
$ErrorActionPreference = 'Stop'
$sr = 32000
$Transpose = 0.5     # global pitch scale: lower = deeper. 1.0 = original, 0.5 = an octave down
$dir = Join-Path $PSScriptRoot "voices"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$TAU = 2 * [math]::PI

function Make-Voice {
    param([string]$name, $segs, [double]$vibDepth = 0.06, [double]$vibRate = 40)
    # harmonic weights -> fuller timbre than a single sine
    $h1 = 1.0; $h2 = 0.45; $h3 = 0.22
    $detune = 1.006          # 2nd oscillator slightly sharp -> chorus/width
    $lpA = 0.6               # one-pole low-pass smoothing (tames harshness)

    $total = 0; foreach ($s in $segs) { $total += [int]($sr * $s.d) }
    $att = [int](0.008 * $sr); $rel = [int](0.035 * $sr)
    $buf = New-Object 'System.Collections.Generic.List[double]'
    $p1 = 0.0; $p2 = 0.0; $lp = 0.0; $idx = 0
    foreach ($s in $segs) {
        $cnt = [int]($sr * $s.d)
        $a = [double]$s.a * $Transpose
        $b = if ($s.ContainsKey('b')) { [double]$s.b * $Transpose } else { $a }
        for ($i = 0; $i -lt $cnt; $i++) {
            if ($a -le 0) { $buf.Add(0.0); $idx++; continue }
            $frac = $i / [double]$cnt
            $t = $idx / $sr
            $f = ($a + ($b - $a) * $frac) * (1.0 + $vibDepth * [math]::Sin($TAU * $vibRate * $t))
            $p1 += $TAU * $f / $sr
            $p2 += $TAU * $f * $detune / $sr
            $o1 = $h1 * [math]::Sin($p1) + $h2 * [math]::Sin(2 * $p1) + $h3 * [math]::Sin(3 * $p1)
            $o2 = $h1 * [math]::Sin($p2) + $h2 * [math]::Sin(2 * $p2) + $h3 * [math]::Sin(3 * $p2)
            $raw = ($o1 + $o2)
            $env = 1.0
            if ($idx -lt $att) { $env = $idx / $att }
            elseif ($idx -gt ($total - $rel)) { $env = ($total - $idx) / $rel }
            $raw *= $env
            $lp += $lpA * ($raw - $lp)     # low-pass
            $buf.Add($lp)
            $idx++
        }
    }
    # peak-normalize to 0.85
    $peak = 0.0; foreach ($v in $buf) { $av = [math]::Abs($v); if ($av -gt $peak) { $peak = $av } }
    $scale = if ($peak -gt 0) { 0.85 / $peak } else { 1.0 }

    $dataLen = $buf.Count * 2
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF")); $bw.Write([int32](36 + $dataLen))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("WAVE")); $bw.Write([System.Text.Encoding]::ASCII.GetBytes("fmt "))
    $bw.Write([int32]16); $bw.Write([int16]1); $bw.Write([int16]1)
    $bw.Write([int32]$sr); $bw.Write([int32]($sr * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("data")); $bw.Write([int32]$dataLen)
    foreach ($v in $buf) {
        $iv = [int]($v * $scale * 32767)
        if ($iv -gt 32767) { $iv = 32767 } elseif ($iv -lt -32767) { $iv = -32767 }
        $bw.Write([int16]$iv)
    }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes((Join-Path $dir "$name.wav"), $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
    Write-Host ("  $name.wav  (" + [math]::Round($buf.Count / $sr, 2) + "s)")
}

Write-Host "Generating EMO-style robot voices (richer synth):"
Make-Voice "happy"   @(@{a = 620; b = 820; d = 0.08}, @{a = 820; b = 1240; d = 0.10}, @{a = 1240; d = 0.07}) 0.06 42
Make-Voice "curious" @(@{a = 900; d = 0.06}, @{a = 760; b = 760; d = 0.05}, @{a = 760; b = 1380; d = 0.16}) 0.05 38
Make-Voice "excited" @(@{a = 1100; b = 1500; d = 0.06}, @{a = 1500; b = 1150; d = 0.06}, @{a = 1150; b = 1650; d = 0.06}, @{a = 1650; d = 0.07}) 0.10 48
Make-Voice "emo"     @(@{a = 1000; b = 880; d = 0.14}, @{a = 880; b = 460; d = 0.28}) 0.04 18
Make-Voice "chirpy"  @(@{a = 1500; d = 0.06}, @{a = 0; d = 0.035}, @{a = 1850; d = 0.08}) 0.07 44
Make-Voice "walle"   @(@{a = 520; b = 1320; d = 0.18}, @{a = 1320; b = 720; d = 0.16}) 0.11 30
Write-Host ("Done -> " + $dir)
