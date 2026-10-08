<#
.SYNOPSIS
  Turn on Qualcomm's CSIPHY diagnostic mode in Windows and read back what it
  records about a *working* camera link.

.DESCRIPTION
  qccammipicsi8380.sys reads three values at device init from
  HKLM\SYSTEM\CurrentControlSet\Control\Qualcomm\Camera:

      CsiTestMode           enable the diagnostic path
      Csi2PhaseCtrl0        override; absent means 0xffffffff = do not patch
      Csi2PhaseLnckCtrl0    same

  With CsiTestMode set, it writes back on device teardown:

      Csi2CommonStatus1 / 3 / 6 / 8       the four status words it saves by name
      Csi2PhaseCtrl0Default / LastUsed
      Csi2PhaseLnckCtrl0Default / LastUsed
      Csi2PhaseNumOfLanes
      Csi2DataRateKbps
      Csi2PHYIndex
      Csi2PhasePhyMode

  Why this exists: the Linux side has read the same three CSIPHY status words in
  every configuration of every mission and they never change. There is no
  known-good value to compare them against, and the sensor's data rate and lane
  count are both inferences rather than measurements. This is the one place the
  shipping stack will state them outright.

  The phase-patching path the flag also enables is D-PHY only (FUN_140006b50
  returns immediately when is3Phase is set), so on the front camera -- which is
  C-PHY -- this only adds the dump.

.PARAMETER Action
  on     create the key with CsiTestMode=1
  read   print everything the driver has written back, and export it
  off    delete the key -- refuses unless an export exists

.PARAMETER ExportDir
  Where 'read' writes csitestmode-<date>.reg and .txt, and where 'off' looks
  for one before it will delete. Defaults to the repo's data/ directory.

.PARAMETER Force
  Let 'off' delete without an export. There is one good reason to use this and
  it is that you already have the export somewhere else.

.NOTES
  Needs elevation. The read happens at device init and the write at teardown, so
  the sequence is: on -> reboot -> use the front camera -> reboot -> read.

  The first time this was run, the key was deleted straight after reading and
  without an export, so the one measurement that overturned twelve missions of
  inference survived only as console output that had been hand-copied into a
  notes file. CurrentControlSet is ControlSet001 here and RegBack is empty, so
  there was nothing to recover from. Hence the export, and hence 'off' refusing
  without one.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('on', 'read', 'off')]
    [string]$Action = 'read',

    [string]$ExportDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data'),

    [switch]$Force
)

$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Qualcomm\Camera'

# The order the driver writes them, which is also the order they make sense in.
$written = @(
    'Csi2CommonStatus1', 'Csi2CommonStatus3', 'Csi2CommonStatus6', 'Csi2CommonStatus8',
    'Csi2PhaseCtrl0Default', 'Csi2PhaseCtrl0LastUsed',
    'Csi2PhaseLnckCtrl0Default', 'Csi2PhaseLnckCtrl0LastUsed',
    'Csi2PhaseNumOfLanes', 'Csi2DataRateKbps', 'Csi2PHYIndex', 'Csi2PhasePhyMode'
)

switch ($Action) {

    'on' {
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name 'CsiTestMode' -Value 1 -PropertyType DWord -Force | Out-Null
        Write-Output "CsiTestMode = 1 at $key"
        Write-Output ''
        Write-Output 'Now: reboot, open the Camera app on the FRONT camera, close it,'
        Write-Output 'then reboot again and run:  .\sp11-csitestmode.ps1 read'
    }

    'read' {
        if (-not (Test-Path $key)) { Write-Output "key absent - run 'on' first"; break }
        $p = Get-ItemProperty -Path $key
        $present = (Get-Item $key).Property
        Write-Output "values present: $($present -join ', ')"
        Write-Output ''

        # Export before anything else, so the raw data outlives this console.
        # reg.exe writes the hive form; the .txt is the same values in a form
        # that survives being read by a human or diffed against a later run.
        if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $reg = Join-Path $ExportDir "csitestmode-$stamp.reg"
        $txt = Join-Path $ExportDir "csitestmode-$stamp.txt"
        & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Control\Qualcomm\Camera' $reg /y | Out-Null
        $lines = @(
            "CsiTestMode dump, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "Source: HKLM\SYSTEM\CurrentControlSet\Control\Qualcomm\Camera",
            "Producer: qccammipicsi8380.sys on device teardown. All REG_DWORD;",
            "hex and decimal are the same four bytes shown twice. Nothing decoded.",
            ''
        )
        foreach ($n in $present) {
            $lines += ("    {0,-28} 0x{1:X8}   {2}" -f $n, ([uint32]$p.$n), ([uint32]$p.$n))
        }
        $lines | Out-File -FilePath $txt -Encoding utf8
        Write-Output "exported -> $reg"
        Write-Output "exported -> $txt"
        Write-Output ''

        $any = $false
        foreach ($n in $written) {
            if ($present -contains $n) {
                $any = $true
                $v = [uint32]$p.$n
                # Csi2DataRateKbps is the one that is meaningful in decimal.
                if ($n -eq 'Csi2DataRateKbps') {
                    "{0,-28} 0x{1:X8}   {2} kbps   ({3} Mbps)" -f $n, $v, $v, [math]::Round($v / 1000.0, 1)
                } else {
                    "{0,-28} 0x{1:X8}   {2}" -f $n, $v, $v
                }
            }
        }
        if (-not $any) {
            Write-Output 'nothing written back yet - the driver dumps these at device'
            Write-Output 'teardown, so the camera has to have been opened and the device'
            Write-Output 'released (a reboot is the reliable way) since CsiTestMode was set.'
        }
    }

    'off' {
        if (-not (Test-Path $key)) { Write-Output 'already absent'; break }

        # The values the driver wrote exist nowhere else: CurrentControlSet is
        # ControlSet001 on this machine and RegBack is empty, so a delete is
        # final. Refuse unless something on disk holds them.
        $exports = @(Get-ChildItem -Path $ExportDir -Filter 'csitestmode-*.reg' -ErrorAction SilentlyContinue)
        if ($exports.Count -eq 0 -and -not $Force) {
            Write-Output "refusing: no csitestmode-*.reg in $ExportDir"
            Write-Output "run 'read' first (it exports), or pass -Force if you have it elsewhere."
            break
        }
        if ($exports.Count -gt 0) {
            Write-Output "export on disk: $($exports[-1].Name)"
        }

        Remove-Item -Path $key -Recurse -Force
        Write-Output "removed $key"

        # 'on' creates the Qualcomm parent too. Remove it only if it is empty,
        # so this never eats a key that was already there.
        $parent = 'HKLM:\SYSTEM\CurrentControlSet\Control\Qualcomm'
        if (Test-Path $parent) {
            $kids = @(Get-ChildItem $parent -ErrorAction SilentlyContinue)
            $vals = @((Get-Item $parent).Property)
            if ($kids.Count -eq 0 -and $vals.Count -eq 0) {
                Remove-Item $parent -Force
                Write-Output "removed the empty $parent"
            } else {
                Write-Output "left $parent alone - not empty"
            }
        }
    }
}
