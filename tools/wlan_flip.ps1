# wlan_flip.ps1 -- safe WLAN switching with mandatory auto-revert.
# Lesson (2026-10-02): if both PC wired+wireless drop, the ZCode session dies.
# Rule: ALWAYS arm the auto-revert timer BEFORE flipping to the CPE AP.
# NOTE: ASCII-only file (PowerShell 5.1 reads .ps1 as ANSI when no BOM).
#
#   powershell -ExecutionPolicy Bypass -File tools\wlan_flip.ps1 -To cpe    # v3-test-5g, auto-revert 90s
#   powershell -ExecutionPolicy Bypass -File tools\wlan_flip.ps1 -To home   # HUAWEI-505
param(
    [string]$To = "",
    [int]$RevertSec = 90
)
$homeSsid = "HUAWEI-505"
$cpeSsid  = "v3-test-5g"

function Arm-Revert([int]$sec) {
    # detached revert timer: reconnects home regardless of what happens next
    $cmd = "Start-Sleep $sec; netsh wlan connect name='$homeSsid' | Out-Null"
    Start-Process powershell -WindowStyle Hidden -ArgumentList "-Command", $cmd
    Write-Host "auto-revert to '$homeSsid' armed: ${sec}s"
}

switch ($To) {
    "cpe" {
        Arm-Revert $RevertSec
        netsh wlan connect name="$cpeSsid"
        Write-Host "switched to $cpeSsid -- revert in ${RevertSec}s unless re-armed"
    }
    "home" {
        netsh wlan connect name="$homeSsid"
        Write-Host "switched to $homeSsid (no timer needed)"
    }
    default {
        Write-Host "usage: -To cpe|home  (cpe arms ${RevertSec}s auto-revert)"
        netsh wlan show interfaces | Select-String "SSID"
    }
}
