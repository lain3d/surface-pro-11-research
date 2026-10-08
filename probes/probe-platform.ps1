# Snapshot platform state relevant to external PCIe / eGPU support.
# Run once now, and again with a USB4 device attached, then diff the two.
#
#   powershell -ExecutionPolicy Bypass -File probe-platform.ps1 -Tag baseline
#   powershell -ExecutionPolicy Bypass -File probe-platform.ps1 -Tag with-enclosure
#   Compare-Object (gc ..\data\probe-baseline.txt) (gc ..\data\probe-with-enclosure.txt)

param(
    [string]$Tag = "baseline",
    [string]$OutDir = "$PSScriptRoot\..\data"
)

$ErrorActionPreference = 'SilentlyContinue'
$out = Join-Path $OutDir "probe-$Tag.txt"
New-Item -ItemType Directory -Force $OutDir | Out-Null

function Section($n) { "`n=== $n ===" }

$report = @()

$report += Section "IDENTITY"
$report += Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemType | Format-List | Out-String
$report += Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture | Format-List | Out-String

$report += Section "SECURITY POSTURE"
$report += "SecureBoot: " + (try { Confirm-SecureBootUEFI } catch { "n/a" })
$dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard
$report += "VBS status: $($dg.VirtualizationBasedSecurityStatus)"
$report += "Security services running: $($dg.SecurityServicesRunning -join ',')"
$report += "Available security properties: $($dg.AvailableSecurityProperties -join ',')"
$report += "TestSigning / integrity: "
$report += (bcdedit /enum '{current}' | Select-String 'testsigning|nointegritychecks|hypervisorlaunchtype' | Out-String)

$report += Section "PCI HOST BRIDGES (PNP0A08 / PNP0A03)"
$report += Get-PnpDevice | Where-Object { $_.InstanceId -match 'PNP0A0[38]' } |
    Select-Object InstanceId, Status, Present, FriendlyName |
    Sort-Object InstanceId | Format-Table -AutoSize | Out-String

$report += Section "PCI DEVICES AND PARENTAGE"
$report += Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^PCI' } | ForEach-Object {
    $p = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Parent').Data
    $l = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo').Data
    [PSCustomObject]@{ Name = $_.FriendlyName; Id = $_.InstanceId; Parent = $p; Location = $l }
} | Format-Table -AutoSize -Wrap | Out-String

$report += Section "PCI DEVICES WITH PROBLEMS (code 12 = insufficient resources)"
$report += Get-PnpDevice | Where-Object { $_.Status -ne 'OK' -and $_.InstanceId -match '^(PCI|ACPI\\PNP0A0)' } | ForEach-Object {
    $pc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    [PSCustomObject]@{ Name = $_.FriendlyName; Id = $_.InstanceId; Status = $_.Status; Problem = $pc }
} | Format-Table -AutoSize -Wrap | Out-String

$report += Section "MEMORY RESOURCES ASSIGNED TO PCI DEVICES"
$report += Get-CimInstance Win32_DeviceMemoryAddress | Select-Object StartingAddress, EndingAddress, Name |
    Sort-Object StartingAddress | Format-Table -AutoSize | Out-String

$report += Section "USB4 STACK"
$report += Get-PnpDevice | Where-Object { $_.InstanceId -match 'USB4|QCOM0C6D|ACPI0015' } |
    Select-Object InstanceId, Status, Class, FriendlyName | Format-Table -AutoSize -Wrap | Out-String
foreach ($svc in @('QcUsb4Bus', 'Usb4HostRouter')) {
    $s = Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -eq $svc }
    $report += "$svc : state=$($s.State) start=$($s.StartMode) path=$($s.PathName)"
}

$report += Section "USB-C / RETIMER"
$report += Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Retimer|Type-C|UCSI|UCM' } |
    Select-Object InstanceId, Status, FriendlyName | Format-Table -AutoSize -Wrap | Out-String

$report -join "`n" | Out-File -FilePath $out -Encoding utf8
Write-Output "wrote $out"
