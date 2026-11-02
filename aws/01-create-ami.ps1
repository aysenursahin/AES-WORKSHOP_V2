# ---------------------------------------------------------------------------
# 01 - Base makineden AMI alir
#
# Base makinede aes-workshop-setup.ps1 calismis ve elle yapilacaklar
# tamamlanmis olmali. Koi base makinede KURULU OLMAMALI.
# Not: AMI alinirken base makine yeniden baslatilir.
# ---------------------------------------------------------------------------
. "$PSScriptRoot\common.ps1"
Assert-Configured @("BaseInstanceId", "AmiName")

Write-Host "Base makine: $BaseInstanceId" -ForegroundColor Cyan
Write-Host "  - aes-workshop-setup.ps1 calisti ve tum kontroller [OK] mi?"
Write-Host "  - Claude Desktop, Cursor ve Chrome extension'lari kuruldu mu?"
Write-Host "  - Koi bu makinede KURULU DEGIL mi?"
# Base makineyi SSM ile kontrol et (SSM rolu yoksa kontrol atlanir)
$baseInst = [pscustomobject]@{ Name = "base"; InstanceId = $BaseInstanceId }
$info = Invoke-Aws @("ssm", "describe-instance-information", "--filters", "Key=InstanceIds,Values=$BaseInstanceId")
if ($info.InstanceInformationList -and $info.InstanceInformationList[0].PingStatus -eq "Online") {
    Write-Host "==> Base makine kontrol ediliyor..." -ForegroundColor Cyan
    $chk = @"
`$u = '$WorkshopUser'
`$p = @()
if (-not (Test-Path "C:\Users\`$u\Desktop\komutlar.txt")) { `$p += "`$u masaustunde komutlar.txt yok (kurulum `$u ile yapilmamis)" }
if (Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True AND Name='wsuser'") { `$p += "eski 'wsuser' kullanicisi var (V1 base makinesi)" }
if (Get-ChildItem Cert:\LocalMachine\Root | Where-Object { `$_.Subject -like '*Koi*' }) { `$p += "Koi Root CA makinede kurulu (katilimcilar kendisi kuracak)" }
if (`$p.Count) { `$p | ForEach-Object { Write-Output "SORUN: `$_" }; exit 1 }
Write-Output "Base makine temiz"
"@
    $sent = Send-SsmScript -InstanceIds @($BaseInstanceId) -Script $chk -Comment "base check" -ExecutionTimeoutSeconds 120
    $res = @(Wait-SsmCommands -Sent $sent -Instances @($baseInst) -TimeoutMinutes 5)
    if ($res[0].Status -ne "Success") {
        Write-Host "Base makine hazir degil, AMI alinmadi. Yukaridaki SORUN satirlarini duzeltin." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Not: Base makine SSM'de degil, otomatik kontrol atlandi." -ForegroundColor Yellow
}

$answer = Read-Host "Hepsi tamamsa 'evet' yazin"
if ($answer -ne "evet") { Write-Host "Iptal edildi."; exit 1 }

$name = "{0}-{1}" -f $AmiName, (Get-Date -Format "yyyyMMdd-HHmm")
$tags = @(
    @{ ResourceType = "image";    Tags = @(@{ Key = "Name"; Value = $name }, @{ Key = "Workshop"; Value = $WorkshopTag }) },
    @{ ResourceType = "snapshot"; Tags = @(@{ Key = "Name"; Value = $name }, @{ Key = "Workshop"; Value = $WorkshopTag }) }
)
$tagFile = New-JsonArgFile $tags

Write-Host "==> AMI olusturuluyor: $name (base makine yeniden baslatilacak)" -ForegroundColor Cyan
$res = Invoke-Aws @("ec2", "create-image",
    "--instance-id", $BaseInstanceId,
    "--name", $name,
    "--description", "Koi workshop base image",
    "--tag-specifications", $tagFile)
$amiId = $res.ImageId
Write-Host "    AMI: $amiId"

$deadline = (Get-Date).AddMinutes(90)
while ($true) {
    $img   = (Invoke-Aws @("ec2", "describe-images", "--image-ids", $amiId)).Images[0]
    $state = $img.State
    if ($state -eq "available") { break }
    if ($state -eq "failed")    { throw "AMI olusturulamadi: $($img.StateReason.Message)" }
    if ((Get-Date) -gt $deadline) { throw "AMI 90 dakikada hazir olmadi. AWS konsolundan kontrol edin." }
    Write-Host "  ... AMI durumu: $state"
    Start-Sleep -Seconds 30
}

Write-Host ""
Write-Host "AMI hazir: $amiId ($name)" -ForegroundColor Green
Write-Host "Siradaki adim: 02-launch-instances.ps1"
