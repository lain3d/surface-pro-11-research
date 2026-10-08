<#
.SYNOPSIS
  Hand the Surface's boot drive back and forth between Windows and WSL.

.DESCRIPTION
  The Surface boots Linux off the Samsung T7 Shield over USB-C. Two things on it
  matter from Windows: the ESP (where the UKI is installed) and the ext4 root
  (where the journals are).

  The ESP is FAT and Windows can mount it, but it has no drive letter, so it
  needs mountvol against a volume GUID.

  The ext4 root Windows cannot read at all. `wsl --mount` is not an option here:
  on ARM64 it needs Windows build 27653+ and this machine is 26200. The route is
  usbipd-win, which passes the whole USB device through to WSL2.

  usbipd refuses while Windows holds the device ("Device busy (exported)"),
  which it does because two partitions are mounted as D: and E:. Taking the disk
  offline first dismounts them cleanly, which is much safer than `bind --force`
  yanking a mounted 1.6 TB volume.

.PARAMETER Action
  status    what is mounted where, and who owns the disk
  esp       mount the ESP as S: (or -Drive)
  esp-off   unmount it
  to-wsl    give the whole disk to WSL (unmounts the ESP first)
  to-win    take it back

.EXAMPLE
  .\sp11-disk.ps1 status
  .\sp11-disk.ps1 esp
  .\sp11-disk.ps1 to-wsl      # then: wsl -d Ubuntu-22.04 -u root bash tools/sp11-journal.sh
  .\sp11-disk.ps1 to-win
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'esp', 'esp-off', 'to-wsl', 'to-win')]
    [string]$Action = 'status',

    [string]$Drive = 'S',
    [string]$DiskName = 'Samsung PSSD T7 Shield'
)

$ErrorActionPreference = 'Stop'
$usbipd = 'C:\Program Files\usbipd-win\usbipd.exe'

# usbipd writes its "info:" progress lines to stderr, and under
# ErrorActionPreference=Stop a native command writing to stderr raises
# NativeCommandError - so a perfectly successful `bind` ("Device ... was already
# shared") aborts the handoff. Run native commands through this instead: it
# suppresses the stderr-as-error behaviour and returns the exit code, which is
# the thing actually worth checking.
#
# Two traps here, both hit while writing it:
#   - do NOT name the parameter $Args. That is an automatic variable, so the
#     splat silently expands to nothing and usbipd prints its usage text.
#   - print with Write-Host, not Write-Output. Write-Output goes to the success
#     stream, so the command's own text ends up concatenated into the return
#     value and "$rc -ne 0" compares against a page of help.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "  $_" } }
    finally { $ErrorActionPreference = $old }
    return $LASTEXITCODE
}

function Get-T7Disk {
    $d = Get-Disk | Where-Object { $_.FriendlyName -eq $DiskName }
    if (-not $d) { throw "disk '$DiskName' not found - is it plugged in?" }
    if ($d -is [array]) { throw "more than one disk named '$DiskName'" }
    return $d
}

function Get-EspGuid {
    # Identify the ESP by partition type on the T7 itself rather than by a
    # hardcoded GUID, which changes if the drive is ever repartitioned. The
    # internal NVMe also has a System partition; never touch that one.
    $disk = Get-T7Disk
    $p = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'System' }
    if (-not $p) { throw "no ESP on disk $($disk.Number)" }
    if ($p -is [array]) { $p = $p[0] }
    return $p.Guid
}

function Get-BusId {
    $line = & $usbipd list | Select-String -Pattern '04e8:61fb'
    if (-not $line) { throw 'T7 (04e8:61fb) not present in usbipd list' }
    return ($line.ToString().Trim() -split '\s+')[0]
}

function Show-Status {
    Write-Output '--- disk ---'
    Get-Disk | Where-Object { $_.FriendlyName -eq $DiskName } |
        Format-Table Number, FriendlyName, IsOffline, OperationalStatus -AutoSize
    Write-Output '--- volumes ---'
    $disk = $null
    try { $disk = Get-T7Disk } catch { }
    if ($disk) {
        Get-Partition -DiskNumber $disk.Number |
            Select-Object PartitionNumber, DriveLetter, Size, Type |
            Format-Table -AutoSize
    }
    Write-Output '--- usbipd ---'
    & $usbipd list
    Write-Output '--- ESP ---'
    if (Test-Path "${Drive}:\") {
        Get-ChildItem "${Drive}:\" -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize
    } else {
        Write-Output "  not mounted (run: .\sp11-disk.ps1 esp)"
    }
}

switch ($Action) {

    'status' { Show-Status }

    'esp' {
        if (Test-Path "${Drive}:\") { Write-Output "${Drive}: already mounted"; break }
        $guid = Get-EspGuid
        # mountvol needs the volume path quoted; unquoted, PowerShell mangles it
        # and mountvol silently prints its usage text instead of failing.
        mountvol "${Drive}:" "\\?\Volume$guid\"
        if (Test-Path "${Drive}:\") {
            Write-Output "ESP mounted at ${Drive}:  (volume $guid)"
            Get-Volume -DriveLetter $Drive | Format-Table DriveLetter, FileSystemLabel, SizeRemaining, Size -AutoSize
        } else {
            throw "mountvol did not mount ${Drive}: - are you elevated?"
        }
    }

    'esp-off' {
        mountvol "${Drive}:" /D
        Write-Output "${Drive}: unmounted"
    }

    'to-wsl' {
        if (Test-Path "${Drive}:\") { mountvol "${Drive}:" /D; Write-Output "unmounted ${Drive}:" }
        $disk = Get-T7Disk
        $busid = Get-BusId
        Write-Output "disk $($disk.Number), busid $busid"

        # usbipd attaches into a *running* WSL 2 VM. If none is up it fails with
        # "There is no WSL 2 distribution running", so poke the distro first.
        # WSL tears its VM down after vmIdleTimeout (60s default) once the last
        # session exits, so this happens constantly.
        #
        # WSL warns on stderr about drive letters it cannot automount (S: and W:
        # come and go here), and a native command writing to stderr trips
        # ErrorActionPreference=Stop and aborts the handoff before it binds.
        # Same swallow as 'to-win' below.
        try { wsl.exe -d Ubuntu-22.04 -u root true 2>&1 | Out-Null } catch { }
        Write-Output 'WSL VM is up'

        $rc = Invoke-Native $usbipd @('bind', '--busid', $busid)
        Write-Output "bind exit=$rc (already-bound is fine)"

        # Offlining is what frees the device: without it usbipd reports
        # "Device busy (exported)" and the only alternative is bind --force,
        # which pulls the rug from under mounted filesystems.
        #
        # It is NOT a clean dismount, though this used to claim it was. Linux
        # logged "Volume was not properly unmounted" for both the FAT32 ESP and
        # the exFAT relay on every boot following a handoff, and `fsutil dirty
        # query` showed both dirty from the Windows side. Flush each volume's
        # write cache first so the offline lands on a quiesced filesystem.
        foreach ($v in (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                        Where-Object { $_.DriveLetter })) {
            try {
                Write-VolumeCache -DriveLetter $v.DriveLetter -ErrorAction Stop
                Write-Output "flushed $($v.DriveLetter):"
            } catch {
                Write-Output "could not flush $($v.DriveLetter): $($_.Exception.Message)"
            }
        }

        Set-Disk -Number $disk.Number -IsOffline $true
        Start-Sleep -Milliseconds 1500

        $rc = Invoke-Native $usbipd @('attach', '--wsl', '--busid', $busid)
        if ($rc -ne 0) {
            Set-Disk -Number $disk.Number -IsOffline $false
            throw "attach failed (exit $rc); disk put back online"
        }
        Write-Output ''
        Write-Output 'attached to WSL. Now:'
        Write-Output '  wsl -d Ubuntu-22.04 -u root bash /mnt/c/Users/Crazy/projs/arm64-egpu/tools/sp11-journal.sh'
    }

    'to-win' {
        $busid = Get-BusId
        # "not mounted" is the normal case when a script already unmounted, but
        # a native command writing to stderr trips ErrorActionPreference=Stop and
        # aborts the whole handoff. Swallow it deliberately.
        try { wsl.exe -d Ubuntu-22.04 -u root umount /mnt/sp11root 2>&1 | Out-Null } catch { }
        $rc = Invoke-Native $usbipd @('detach', '--busid', $busid)
        Write-Output "detach exit=$rc"
        Start-Sleep -Milliseconds 1500
        $disk = Get-T7Disk
        Set-Disk -Number $disk.Number -IsOffline $false
        Start-Sleep -Milliseconds 1500
        Get-Disk -Number $disk.Number | Format-Table Number, FriendlyName, IsOffline -AutoSize
        Write-Output 'back on Windows. Re-mount the ESP with: .\sp11-disk.ps1 esp'
    }
}
