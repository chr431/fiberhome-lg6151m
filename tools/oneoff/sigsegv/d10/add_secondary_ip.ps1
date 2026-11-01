param(
  [Parameter(Mandatory=$true)][string]$Ip,
  [string]$IfName = "以太网",
  [string]$Action = "add"   # add | del
)
if ($Action -eq "add") {
  netsh interface ip add address name="$IfName" $Ip 255.255.255.0
} else {
  netsh interface ip delete address name="$IfName" $Ip
}
exit $LASTEXITCODE
