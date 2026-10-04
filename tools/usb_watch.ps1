$ErrorActionPreference = 'SilentlyContinue'
$log = 'D:\Repo\lg6151m\usb_events.log'
"=== USB watcher started $(Get-Date -Format 'HH:mm:ss.fff') ===" | Out-File $log -Encoding utf8

# event-driven: fires the moment any PnP entity appears
Register-CimIndicationEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE TargetInstance ISA 'Win32_Pn32Entity'" -SourceIdentifier W1 | Out-Null
Register-CimIndicationEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE TargetInstance ISA Win32_PnPEntity" -SourceIdentifier W2 | Out-Null

$end = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $end) {
    $e = Get-Event -SourceIdentifier W2
    if ($e) {
        $dev = $e.SourceEventArgs.NewEvent.TargetInstance
        $line = "{0}  ARRIVE {1} | {2} | {3}" -f (Get-Date -Format 'HH:mm:ss.fff'), $dev.DeviceID, $dev.PNPClass, $dev.Name
        $line | Out-File $log -Append -Encoding utf8
        Remove-Event -EventIdentifier $e.EventIdentifier
    }
    Start-Sleep -Milliseconds 100
}
"=== watcher ended $(Get-Date -Format 'HH:mm:ss.fff') ===" | Out-File $log -Append -Encoding utf8
