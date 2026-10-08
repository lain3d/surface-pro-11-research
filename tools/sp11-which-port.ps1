<#
.SYNOPSIS
  Say which USB-C port the T7 is plugged into.

.DESCRIPTION
  The DSDT maps:

      URS0 -> 0xa600000   ACPI\QCOM0C8B\0   Linux buses 1 and 2
      URS1 -> 0xa800000   ACPI\QCOM0C8C\1   Linux buses 3 and 4

  HISTORY, AND WHY THIS NO LONGER SHOUTS AT YOU

  Until 2026-08-05 this script reported URS0 as "WRONG PORT - no boot has ever
  succeeded on this one", because at the time that was true: every successful
  boot on record came up as `usb 3-1`, and the port was a genuinely uncontrolled
  variable that produced fake per-build verdicts.

  That was a coincidence of where the drive happened to be sitting, not a
  property of the port. The real cause of the failures was three drivers
  reconfiguring hardware firmware had already set up, plus the pmic_glink
  altmode conversation - see design/session-state-20260805-evening.md. With
  those fixed, the T7 booted cleanly from URS0 at SuperSpeed Plus Gen 2x1
  (`usb 2-1`, `xhci-hcd.1.auto`, `io mem 0x0a600000`), zero errors.

  So both ports work. This now just reports which one you are on, because it is
  still worth recording in an experiment log - the two differ in the device tree
  (a800000 carries interconnects/interconnect-names and a600000 does not, an
  upstream asymmetry that is a bandwidth vote, not an enumeration gate).
#>
[CmdletBinding()]
param([string]$VidPid = 'VID_04E8&PID_61FB')   # Samsung PSSD T7 Shield

$map = @{
    'ACPI\QCOM0C8B\0' = @{ Urs = 'URS0'; Addr = '0xa600000'; Buses = '1 and 2' }
    'ACPI\QCOM0C8C\1' = @{ Urs = 'URS1'; Addr = '0xa800000'; Buses = '3 and 4' }
}

# Do NOT filter on Class here. The T7 presents as Class 'SCSIAdapter', not
# 'USB' - it is a UAS mass storage device - so a Class -eq 'USB' test silently
# finds nothing and the script reports "not plugged in" on a connected drive.
$dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -like "USB\$VidPid*" }

if (-not $dev) { Write-Host "T7 not found - is it plugged in?"; exit 2 }

# walk up to the ACPI dual-role controller
$cur = $dev[0].InstanceId
$ctrl = $null
for ($i = 0; $i -lt 8; $i++) {
    $p = (Get-PnpDeviceProperty -InstanceId $cur -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
    if (-not $p) { break }
    if ($map.ContainsKey($p)) { $ctrl = $p; break }
    $cur = $p
}

if (-not $ctrl) { Write-Host "could not find the dual-role controller above $($dev[0].InstanceId)"; exit 2 }

$m = $map[$ctrl]
Write-Host ""
Write-Host ("  controller : {0}  ({1}, {2})" -f $ctrl, $m.Urs, $m.Addr)
Write-Host ("  Linux buses: {0}" -f $m.Buses)
Write-Host ""
Write-Host "  Both ports boot as of 2026-08-05. Record which one, do not move it"
Write-Host "  mid-experiment, and carry on."
exit 0
