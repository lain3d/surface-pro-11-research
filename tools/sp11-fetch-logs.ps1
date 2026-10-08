<#
.SYNOPSIS
  Copy the boot diagnostics off the internal NVMe's EFI System Partition into
  Documents, where they can be opened normally.

.DESCRIPTION
  sp11-winlog and the dracut hooks write to the internal ESP, because it is a
  different physical disk from the T7 and survives the T7 going away. That makes
  the logs readable after a failed boot -- but the ESP itself is awkward to get
  at from Windows:

    * it is FAT32, so it has no ACLs and icacls cannot grant access to it
    * Windows gates the EFI System Partition at the volume level, to SYSTEM and
      genuinely elevated processes
    * Explorer never runs elevated, so it denies you even from an admin account

  So there is no way to "fix" Explorer. Copy the files out instead.

  MUST BE RUN ELEVATED. mountvol /s and reading the volume both require it.

.EXAMPLE
  .\tools\sp11-fetch-logs.ps1
  .\tools\sp11-fetch-logs.ps1 -Dest D:\somewhere\else
#>
[CmdletBinding()]
param(
    [string]$Dest  = "$env:USERPROFILE\Documents\sp11-logs",
    [string]$Drive = 'W'
)

$ErrorActionPreference = 'Stop'

$elevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) {
    Write-Error "Not elevated. The EFI System Partition cannot be read otherwise - reopen the terminal as Administrator."
    exit 1
}

# mountvol assignments do not persist across a reboot, so re-establish it every time
$mountedHere = $false
if (-not (Test-Path "${Drive}:\")) {
    mountvol "${Drive}:" /s
    $mountedHere = $true
    if (-not (Test-Path "${Drive}:\")) { throw "could not mount the ESP as ${Drive}:" }
}

try {
    $src = "${Drive}:\sp11-diag"
    if (-not (Test-Path $src)) { throw "no $src - has anything written there yet?" }

    New-Item -ItemType Directory -Force $Dest | Out-Null

    $n = 0
    Get-ChildItem $src -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $Dest $_.Name) -Force
        $n++
    }

    Write-Output "copied $n file(s) to $Dest"
    Get-ChildItem $Dest -File |
        Sort-Object LastWriteTime |
        Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}, LastWriteTime |
        Format-Table -AutoSize
}
finally {
    # leave the drive letter as we found it
    if ($mountedHere) { mountvol "${Drive}:" /D }
}
