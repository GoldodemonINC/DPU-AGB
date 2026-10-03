# Diagnose why FSCTL_SET_SPARSE fails on P:\ and whether any drive supports it.
$ErrorActionPreference = 'Continue'

Write-Output "=== direct fsutil sparse setflag, per volume ==="
foreach ($drv in @('C:\', 'P:\')) {
    $f = Join-Path $drv 'sptest.bin'
    if (-not (Test-Path $f)) { New-Item -ItemType File -Path $f -Force | Out-Null }
    Write-Output ("--- {0} ---" -f $drv)
    (& fsutil sparse setflag $f 2>&1) | ForEach-Object { Write-Output ("    " + $_) }
    (& fsutil sparse queryflag $f 2>&1) | ForEach-Object { Write-Output ("    query: " + $_) }
}

Write-Output ""
Write-Output "=== disk 0 detail ==="
Get-Disk 0 | Format-List Number, FriendlyName, BusType, PartitionStyle, OperationalStatus, IsReadOnly, IsBoot, Size

Write-Output "=== partitions on disk 0 ==="
Get-Partition -DiskNumber 0 | Format-Table PartitionNumber, DriveLetter, @{n='SizeMB';e={[math]::Round($_.Size/1MB)}}, IsActive, IsBoot, IsSystem -AutoSize

Write-Output "=== storage stack ==="
Write-Output ("storage pools     : {0}" -f @(Get-StoragePool -ErrorAction SilentlyContinue).Count)
Write-Output ("virtual disks     : {0}" -f @(Get-VirtualDisk -ErrorAction SilentlyContinue).Count)
Write-Output ("storage subsystems: {0}" -f @(Get-StorageSubsystem -ErrorAction SilentlyContinue).Count)
Write-Output ("physical disks    : {0}" -f @(Get-PhysicalDisk -ErrorAction SilentlyContinue).Count)

Write-Output ""
Write-Output "=== volume NTFS flags (sparse-relevant) ==="
& fsutil fsinfo volumeinfo P:\ 2>&1 | Select-Object -First 12

Write-Output ""
Write-Output "=== storage filter drivers in the P: stack ==="
Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='SCSIAdapter' OR DeviceClass='HDC'" |
    Select-Object DeviceName, DriverVersion, InfName |
    Format-Table -AutoSize

Write-Output ""
Write-Output "=== cleanup ==="
Remove-Item 'C:\sptest.bin', 'P:\sptest.bin' -Force -ErrorAction SilentlyContinue
Write-Output "done"