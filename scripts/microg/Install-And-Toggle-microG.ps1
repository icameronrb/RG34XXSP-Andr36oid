param(
    [ValidateSet("Install", "Enable", "Disable", "Status")]
    [string]$Action = "Status",
    [string]$Device = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Adb = Join-Path $RepoRoot "tools\platform-tools\adb.exe"
$MicroGDir = Join-Path $RepoRoot "apks\microg"

if (-not (Test-Path $Adb)) {
    throw "adb.exe not found at $Adb"
}

& $Adb start-server | Out-Null
$devs = & $Adb devices | Select-String "\s+device$"
if (-not $Device) {
    if ($devs.Count -eq 0) {
        throw "No connected RG34XX SP found over USB or Wireless ADB. Connect via USB or pass -Device <ip:port>."
    }
    $Device = ($devs[0].Line -split "\s+")[0]
} elseif ($Device -match "^\d+\.\d+\.\d+\.\d+(:\d+)?$") {
    $target = if ($Device -match ":") { $Device } else { "${Device}:5555" }
    & $Adb connect $target | Out-Null
    $Device = $target
}

Write-Host "Using device: $Device" -ForegroundColor Cyan

switch ($Action) {
    "Install" {
        $gmsApk = Join-Path $MicroGDir "microG_Services_GmsCore_v0.3.18.apk"
        $vendingApk = Join-Path $MicroGDir "microG_Companion_FakeStore_v0.3.18.apk"
        Write-Host "Installing microG Services Core (com.google.android.gms)..." -ForegroundColor Green
        & $Adb -s $Device install -r -g $gmsApk
        Write-Host "Installing microG Companion / FakeStore (com.android.vending)..." -ForegroundColor Green
        & $Adb -s $Device install -r -g $vendingApk
        Write-Host "Granting runtime permissions and enabling microG..." -ForegroundColor Green
        & $Adb -s $Device shell "pm enable com.google.android.gms; pm enable com.android.vending"
        Write-Host "microG installed and enabled! Run with -Action Disable anytime to freeze it (0 MB RAM)." -ForegroundColor Green
    }
    "Enable" {
        & $Adb -s $Device shell "pm enable com.google.android.gms; pm enable com.android.vending"
        Write-Host "microG Google Services ENABLED." -ForegroundColor Green
    }
    "Disable" {
        & $Adb -s $Device shell "pm disable-user --user 0 com.google.android.gms; pm disable-user --user 0 com.android.vending; am force-stop com.google.android.gms; am force-stop com.android.vending"
        Write-Host "microG Google Services DISABLED & stopped (0 MB background RAM used)." -ForegroundColor Yellow
    }
    "Status" {
        & $Adb -s $Device shell "pm list packages -e | grep -E 'com.google.android.gms|com.android.vending' || echo 'microG is currently DISABLED (or not installed)'"
    }
}
