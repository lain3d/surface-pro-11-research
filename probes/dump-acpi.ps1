# Dump all ACPI tables via GetSystemFirmwareTable. No driver needed.
# Usage: powershell -ExecutionPolicy Bypass -File dump-acpi.ps1 [-OutDir <path>]
param([string]$OutDir = "$PSScriptRoot\..\data\acpi")

$sig = @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern uint EnumSystemFirmwareTables(uint FirmwareTableProviderSignature, byte[] pFirmwareTableEnumBuffer, uint BufferSize);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern uint GetSystemFirmwareTable(uint FirmwareTableProviderSignature, uint FirmwareTableID, byte[] pFirmwareTableBuffer, uint BufferSize);
'@
Add-Type -MemberDefinition $sig -Name FW -Namespace Native | Out-Null

# 'ACPI' as little-endian DWORD
$ACPI = 0x41435049

New-Item -ItemType Directory -Force $OutDir | Out-Null

$size = [Native.FW]::EnumSystemFirmwareTables($ACPI, $null, 0)
$buf = New-Object byte[] $size
[Native.FW]::EnumSystemFirmwareTables($ACPI, $buf, $size) | Out-Null

$results = @()
for ($i = 0; $i -lt $size; $i += 4) {
    $tag = [System.Text.Encoding]::ASCII.GetString($buf, $i, 4)
    $id  = [BitConverter]::ToUInt32($buf, $i)

    # MSDM carries the OEM Windows product key in plaintext. Never write it to disk.
    if ($tag -eq 'MSDM') {
        Write-Output "  (skipping MSDM - contains OEM product key)"
        continue
    }
    $tsz = [Native.FW]::GetSystemFirmwareTable($ACPI, $id, $null, 0)
    if ($tsz -eq 0) { continue }
    $tbuf = New-Object byte[] $tsz
    [Native.FW]::GetSystemFirmwareTable($ACPI, $id, $tbuf, $tsz) | Out-Null

    # Disambiguate multiple tables with the same signature (SSDTs) by OEM Table ID
    $oemTableId = ''
    if ($tsz -ge 24) { $oemTableId = ([System.Text.Encoding]::ASCII.GetString($tbuf, 16, 8)).Trim([char]0, ' ') }
    $name = $tag
    $n = 0
    while (Test-Path (Join-Path $OutDir "$name.aml")) { $n++; $name = "$tag`_$n" }
    [IO.File]::WriteAllBytes((Join-Path $OutDir "$name.aml"), $tbuf)

    $results += [PSCustomObject]@{ Signature=$tag; File="$name.aml"; Bytes=$tsz; OemTableId=$oemTableId }
}
$results | Sort-Object Signature | Format-Table -AutoSize
Write-Output ""
Write-Output "Wrote $($results.Count) tables to $OutDir"
