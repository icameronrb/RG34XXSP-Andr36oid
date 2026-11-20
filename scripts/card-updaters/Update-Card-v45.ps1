[CmdletBinding()]
param([switch]$VerifyOnly)
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

function Write-Partition([IO.FileStream]$DiskStream,[long]$Offset,[long]$Length,[string]$ImagePath,[string]$ExpectedSha256,[string]$Label) {
    Write-Host ("Writing {0} ({1} MB) at offset {2}..." -f $Label, ($Length/1048576), $Offset)
    $src=[IO.File]::OpenRead($ImagePath)
    try {
        if($src.Length -ne $Length -or (RegionHash $src 0 $Length) -ne $ExpectedSha256){
            throw "Source image verification failed for $Label."
        }
        [void]$src.Seek(0,[IO.SeekOrigin]::Begin)
        [void]$DiskStream.Seek($Offset,[IO.SeekOrigin]::Begin)
        $buffer=New-Object byte[] (8*1024*1024)
        $written=0L
        while($written -lt $Length){
            $wanted=[int][Math]::Min([long]$buffer.Length,$Length-$written)
            $count=$src.Read($buffer,0,$wanted)
            if($count -le 0){throw "Incomplete read from $ImagePath"}
            $DiskStream.Write($buffer,0,$count)
            $written+=$count
            if(($written % 67108864) -eq 0){
                Write-Host ("  {0}: {1:P0}" -f $Label, ($written/[double]$Length))
            }
        }
    } finally {$src.Dispose()}
    $DiskStream.Flush($true)
    Write-Host ("Verifying {0} read-back..." -f $Label)
    if((RegionHash $DiskStream $Offset $Length) -ne $ExpectedSha256){
        throw "Read-back verification failed for $Label!"
    }
}

$stream=$null
try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'Right-click UPDATE-CARD-V45.cmd and choose Run as administrator.'
    }
    Write-Host 'RG34XX SP v45 Performance-First Updater (in-place system + vendor + product update)'
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'v45-manifest.json') -Raw | ConvertFrom-Json

    $sysImg=Join-Path $PSScriptRoot 'RG34XXSP-v45-system.img'
    $venImg=Join-Path $PSScriptRoot 'RG34XXSP-v45-vendor.img'
    $prdImg=Join-Path $PSScriptRoot 'RG34XXSP-v45-product.img'

    $cards=@(Get-Disk | Where-Object {
        $_.BusType -in @('USB','SD') -and $_.Size -ge 14000000000L -and $_.Size -le 2199023255552L -and
        $_.PartitionStyle -eq 'GPT' -and -not $_.IsBoot -and -not $_.IsSystem -and -not $_.IsReadOnly
    })
    if($cards.Count -ne 1){
        throw 'Connect exactly one writable USB/SD card (32GB+) with the RG34XX SP Android layout.'
    }
    $card=$cards[0]
    $bounds=@{
        1=@(37748736L,134217728L);
        2=@(171966464L,33554432L);
        3=@(205520896L,16777216L);
        4=@(222298112L,67108864L);
        5=@(289406976L,2147483648L);
        6=@(2436890624L,536870912L);
        7=@(2973761536L,536870912L)
    }
    $partitions=@(Get-Partition -DiskNumber $card.Number)
    if($partitions.Count -ne 8){throw 'Unexpected partition count. No changes made.'}
    foreach($p in $partitions){
        if($p.PartitionNumber -le 7){
            $b=$bounds[[int]$p.PartitionNumber]
            if($null -eq $b -or $p.Offset -ne $b[0] -or $p.Size -ne $b[1]){
                throw "Unexpected partition layout on partition $($p.PartitionNumber). No changes made."
            }
        }
    }

    $access=if($VerifyOnly){[IO.FileAccess]::Read}else{[IO.FileAccess]::ReadWrite}
    $stream=[IO.File]::Open(('\\.\PhysicalDrive{0}'-f $card.Number),[IO.FileMode]::Open,$access,[IO.FileShare]::ReadWrite)

    if((RegionHash $stream 222298112 67108864) -ne $manifest.boot_sha256){
        throw 'Boot partition hash mismatch (expected v34/v43 boot image). No changes made.'
    }

    if($VerifyOnly){
        Write-Host 'Card layout and boot partition verified. No changes made (-VerifyOnly).' -ForegroundColor Green
    } else {
        Write-Partition $stream 289406976L 2147483648L $sysImg $manifest.system_sha256 'system'
        Write-Partition $stream 2436890624L 536870912L $venImg $manifest.vendor_sha256 'vendor'
        Write-Partition $stream 2973761536L 536870912L $prdImg $manifest.product_sha256 'product'
        Write-Host 'SUCCESS: RG34XX SP v45 performance-first partitions written and verified!' -ForegroundColor Green
    }
} catch {
    Write-Host ('STOPPED: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if($null -ne $stream){$stream.Dispose()}
}
