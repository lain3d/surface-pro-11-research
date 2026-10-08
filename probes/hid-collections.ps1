# hid-collections.ps1 - enumerate every HID top-level collection on this machine
# and print the declared report sizes for each one.
#
# Why this exists: the open question for multi-touch was "can the digitizer emit a
# 2-D frame at all?", and the plan was to answer it by dumping
# /sys/class/hidraw/*/device/report_descriptor on booted Linux. Windows parses the
# same report descriptor the device hands to any host, so the answer is available
# here, today, with no boot. See ../docs/multitouch-heatmap.md.
#
#   .\hid-collections.ps1                       # print to stdout
#   .\hid-collections.ps1 -Out ..\data\hid-collections.txt
param([string]$Out)

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'HidEnum.cs'
$exe = Join-Path $env:TEMP 'HidEnum.exe'

# Use whichever .NET Framework compiler matches the host (FrameworkArm64 on this machine).
$csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework*\v4.0.30319\csc.exe' |
       Sort-Object { $_.FullName -notlike '*Arm64*' } | Select-Object -First 1
if (-not $csc) { throw 'No .NET Framework C# compiler found.' }

& $csc.FullName /nologo /platform:anycpu /out:$exe $src
if ($LASTEXITCODE -ne 0) { throw "Compile failed (exit $LASTEXITCODE)." }

if ($Out) { & $exe | Out-File -FilePath $Out -Encoding utf8; Write-Host "OK -> $Out" }
else      { & $exe }
