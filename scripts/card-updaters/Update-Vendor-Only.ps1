[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

function RegionHash([IO.FileStream]$Stream,[long]$Offset,[long]$Length) {
    [void]$Stream.Seek($Offset,[IO.SeekOrigin]::Begin)
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        $buffer=New-Object byte[] ([int][Math]::Min(8388608L,$Length))
        $left=$Length
        while($left -gt 0){
            $wanted=[int][Math]::Min([long]$buffer.Length,$left)
            $count=$Stream.Read($buffer,0,$wanted)
            if($count -le 0){throw 'Incomplete region read'}
            [void]$hash.TransformBlock($buffer,0,$count,$buffer,0)
            $left-=$count
        }
        [void]$hash.TransformFinalBlock([byte[]]@(),0,0)
        return ([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant()
    } finally {$hash.Dispose()}
}

$stream=$null
$vendorVolume=$null
$vendorLocked=$false
try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'Right-click UPDATE-VENDOR-ONLY.cmd and choose Run as administrator.'
    }
    Write-Host 'RG34XX SP v45 Fast Vendor Partition Patcher (512 MB - takes ~30 seconds)' -ForegroundColor Cyan
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'v45-manifest.json') -Raw | ConvertFrom-Json
    $venImg=Join-Path $PSScriptRoot 'RG34XXSP-v45-vendor.img'

    $cards=@(Get-Disk | Where-Object {
        $_.BusType -in @('USB','SD') -and $_.Size -ge 14000000000L -and $_.Size -le 2199023255552L -and
        $_.PartitionStyle -eq 'GPT' -and -not $_.IsBoot -and -not $_.IsSystem -and -not $_.IsReadOnly
    })
    if($cards.Count -ne 1){
        throw 'Connect exactly one writable USB/SD card (16GB+) with the RG34XX SP Android layout.'
    }
    $card=$cards[0]
    $partitions=@(Get-Partition -DiskNumber $card.Number)
    if($partitions.Count -ne 8){throw 'Unexpected partition count. No changes made.'}
    $venPart=@($partitions | Where-Object PartitionNumber -eq 6)
    if($venPart.Count -ne 1 -or $venPart[0].Offset -ne 2436890624L -or $venPart[0].Size -ne 536870912L){
        throw 'Unexpected vendor partition offset/size on card. No changes made.'
    }

    # Clear old log files on BOOTLOG (I:\) so next boot has a fresh log
    $bootVol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'BOOTLOG' } | Select-Object -First 1
    if ($bootVol -and $bootVol.DriveLetter) {
        $dl = "$($bootVol.DriveLetter):\"
        Remove-Item -Force -ErrorAction SilentlyContinue "$dl\RG34XXSP-ANDROID-BOOT-REPORT.txt", "$dl\RG34XXSP-ANDROID-LOGCAT.txt"
        Write-Host "Cleared old boot logs on $dl"
    }

    Write-Host ("Opening Disk {0} ({1}, {2:N1} GB)..." -f $card.Number, $card.FriendlyName, ($card.Size/1GB))
    $stream=[IO.File]::Open(('\\.\PhysicalDrive{0}'-f $card.Number),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)

    if((RegionHash $stream 222298112 67108864) -ne $manifest.boot_sha256){
        throw 'Boot partition hash mismatch. No changes made.'
    }

    if(-not ('RG34XXVolumeControl' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RG34XXVolumeControl {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access,
        uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    public static SafeFileHandle OpenVolume(string path) {
        SafeFileHandle handle=CreateFileW(path, 0xc0000000u, 3, IntPtr.Zero, 3,
                                         0x80000000u, IntPtr.Zero);
        if (handle.IsInvalid) {
            int error=Marshal.GetLastWin32Error(); handle.Dispose();
            throw new Win32Exception(error);
        }
        return handle;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool DeviceIoControl(SafeFileHandle handle, uint code,
        IntPtr input, uint inputSize, IntPtr output, uint outputSize,
        out uint returned, IntPtr overlapped);
    public static void Apply(SafeFileHandle handle, uint code) {
        uint returned;
        if (!DeviceIoControl(handle, code, IntPtr.Zero, 0, IntPtr.Zero, 0,
                             out returned, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
    }
    Write-Host 'Obtaining exclusive access to the vendor partition...'
    $volumePath='\\?\GLOBALROOT\Device\Harddisk{0}\Partition6' -f $card.Number
    $volumeHandle=[RG34XXVolumeControl]::OpenVolume($volumePath)
    try {$vendorVolume=New-Object IO.FileStream($volumeHandle,[IO.FileAccess]::ReadWrite,4096,$false)}
    catch {$volumeHandle.Dispose();throw}
    [RG34XXVolumeControl]::Apply($vendorVolume.SafeFileHandle,0x00090018)
    $vendorLocked=$true
    [RG34XXVolumeControl]::Apply($vendorVolume.SafeFileHandle,0x00090020)

    $Offset = 2436890624L
    $Length = 536870912L
    $ExpectedSha256 = $manifest.vendor_sha256

    Write-Host "Writing updated v45 vendor partition (512 MB)..."
    $src=[IO.File]::OpenRead($venImg)
    try {
        if($src.Length -ne $Length -or (RegionHash $src 0 $Length) -ne $ExpectedSha256){
            throw "Source vendor.img verification failed."
        }
        [void]$src.Seek(0,[IO.SeekOrigin]::Begin)
        [void]$stream.Seek($Offset,[IO.SeekOrigin]::Begin)
        $buffer=New-Object byte[] (8*1024*1024)
        $written=0L
        while($written -lt $Length){
            $wanted=[int][Math]::Min([long]$buffer.Length,$Length-$written)
            $count=$src.Read($buffer,0,$wanted)
            if($count -le 0){throw "Incomplete read from $venImg"}
            $stream.Write($buffer,0,$count)
            $written+=$count
            if(($written % 67108864) -eq 0){
                Write-Host ("  Writing vendor: {0:P0}" -f ($written/[double]$Length))
            }
        }
    } finally {$src.Dispose()}

    $stream.Flush($true)
    Write-Host "Verifying vendor partition read-back..."
    if((RegionHash $stream $Offset $Length) -ne $ExpectedSha256){
        throw "Read-back verification failed!"
    }
    Write-Host "SUCCESS! Vendor partition patched and verified. Safely eject the card and boot the handheld!" -ForegroundColor Green
} catch {
    Write-Host ('STOPPED: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if($null -ne $vendorVolume){
        if($vendorLocked){try {[RG34XXVolumeControl]::Apply($vendorVolume.SafeFileHandle,0x0009001c)}catch {}}
        $vendorVolume.Dispose()
    }
    if($null -ne $stream){$stream.Dispose()}
}
