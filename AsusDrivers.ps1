# ASUS official catalog extension - DriverHub PS v2.1
# Supports targeted MediaTek MT7921 WLAN repairs on ASUS TUF FX506HF.
# Runs in the current PowerShell session; requires DriverHub.ps1 already loaded.

$script:PreviousDetectOEM=(Get-Command Detect-OEM).ScriptBlock
$script:PreviousShowOEM=(Get-Command Show-OEM).ScriptBlock
$script:PreviousDeepState=(Get-Command Deep-State).ScriptBlock
$script:PreviousDeepItems=(Get-Command Deep-Items).ScriptBlock

function Detect-OEM {
 $o=& $script:PreviousDetectOEM
 if([string]$o.Manufacturer -match '(?i)ASUSTeK|ASUS'){$o.Kind='ASUS'}
 return $o
}
function Show-OEM($o){
 if($o.Kind -eq 'ASUS'){
  Note ('PC: '+$o.Manufacturer+' | '+$o.Model)
  Note 'ASUS official model-specific driver catalog enabled (no Windows Update required).' 'Green'
  Note 'Driver eligibility is matched against hardware vendor and driver version.' 'Yellow'
 }else{& $script:PreviousShowOEM $o}
}
function Convert-DriverVersion([string]$text){
 try{return [version]($text -replace '^[vV]','')}catch{return [version]'0.0.0.0'}
}
function Get-ASUSCatalog($o){
 $rawModel=[string]$o.Model
 if($rawModel -notmatch '(?i)FX506HF'){
  return [pscustomobject]@{Status=('ASUS support automation is currently FX506HF-specific; detected '+$rawModel);Items=@()}
 }
 $build=0
 try{$build=[int](Get-CimInstance Win32_OperatingSystem).BuildNumber}catch{}
 if($build -lt 22621){
  return [pscustomobject]@{Status='This FX506HF WLAN package requires Windows 11 22H2 or later.';Items=@()}
 }
 $urls=@(
  'https://www.asus.com/support/api/product.asmx/GetPDDrivers?website=ph&model=FX506HF&osid=52',
  'https://rog.asus.com/support/webapi/product/GetPDDrivers?website=global&model=FX506HF&cpu=FX506HF&osid=52',
  'https://www.asus.com/support/webapi/ProductV2/GetPDDrivers?website=ph&model=FX506HF&pdhashedid=&pdid=&cpu=&osid=52'
 )
 $groups=@();$lastError='ASUS returned no matching driver data'
 foreach($url in $urls){
  try{
   Note 'Querying official ASUS model-specific driver metadata ...'
   $response=Invoke-RestMethod -Method Get -Uri $url -UseBasicParsing -TimeoutSec 20 -Headers @{'Accept'='application/json';'User-Agent'='Mozilla/5.0 (DriverHub PS)'}
   if($response -is [string]){
    $json=$response -replace '^[A-Za-z_][A-Za-z0-9_]*\(',''
    $json=$json -replace '\);?\s*$',''
    $response=$json|ConvertFrom-Json
   }
   if($response.Result -and $response.Result.Obj){
    $groups=@($response.Result.Obj)
    if($groups.Count){break}
   }
   $lastError='ASUS returned an empty or unexpected response.'
  }catch{$lastError=$_.Exception.Message}
 }
 if(-not $groups.Count){
  return [pscustomobject]@{Status=('ASUS driver feed unavailable. '+$lastError);Items=@()}
 }
 $network=@(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue|Where-Object {
  $_.DeviceName -match '(?i)MediaTek|MT7921' -and $_.DeviceName -match '(?i)Wireless|Wi-?Fi|WLAN|MT7921'
 })
 $pnp=@(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue|Where-Object {
  $_.PNPDeviceID -match '(?i)VEN_14C3'
 })
 $hardwareFound=($network.Count -gt 0 -or $pnp.Count -gt 0)
 $current='Unknown'
 if($network.Count){$current=[string]$network[0].DriverVersion}
 $installed=Convert-DriverVersion $current
 $all=@()
 foreach($group in $groups){
  foreach($f in @($group.Files)){
   if(-not $f){continue}
   $title=[string]$f.Title
   if($title -notmatch '(?i)MediaTek.*(WLAN|Wi-?Fi|Wireless)|WLAN.*MediaTek'){continue}
   $download=''
   if($f.DownloadUrl -is [string]){$download=[string]$f.DownloadUrl}
   elseif($f.DownloadUrl){$download=[string]$f.DownloadUrl.Global}
   $hash=[string]$f.sha256
   $version=[string]$f.Version
   $versionValue=Convert-DriverVersion $version
   $urlValid=$false
   try{
    $uri=[uri]$download
    $urlValid=($uri.Scheme -eq 'https' -and
      $uri.Host -in @('dlcdnets.asus.com','dlcdnets.asus.com','dlcdnweb.asus.com','www.asus.com','rog.asus.com') -and
      $uri.AbsolutePath -match '(?i)\.(zip|cab|exe)$')
   }catch{}
   $hashValid=($hash -match '^[a-fA-F0-9]{64}$')
   $allowed=$hardwareFound -and $urlValid -and $hashValid -and ($versionValue -ge $installed)
   $reason=if(-not $hardwareFound){'Matching MediaTek adapter / PCI hardware ID not confirmed'}
    elseif(-not $urlValid){'Official download URL was not an approved ASUS ZIP/CAB/EXE'}
    elseif(-not $hashValid){'Official SHA-256 missing or invalid'}
    elseif($versionValue -lt $installed){'Installed driver version is newer; downgrade blocked'}
    else{''}
   $kind=if($versionValue -eq $installed){'Same-version repair'}else{'Driver upgrade'}
   $all+=([pscustomobject]@{Source='ASUS';Name=($title+' '+$version+' | installed '+$current);Level=$kind;
     Allowed=$allowed;Reason=$reason;Update=$null;File=$null;Version=$version;VersionValue=$versionValue;
     Url=$download;Sha256=$hash})
  }
 }
 $latest=@($all|Sort-Object VersionValue -Descending|Select-Object -First 1)
 if(-not $latest.Count){
  return [pscustomobject]@{Status='ASUS feed reachable; no MediaTek WLAN driver was listed for FX506HF.';Items=@()}
 }
 $extra=if($latest[0].Allowed){'eligible for verified download'}else{$latest[0].Reason}
 $status=('ASUS FX506HF WLAN '+$latest[0].Version+'; installed '+$current+'; '+$extra)
 [pscustomobject]@{Status=$status;Items=$latest}
}
function Install-ASUS([object[]]$selected){
 foreach($entry in $selected){
  if(-not $entry.Allowed){Note ('Blocked: '+$entry.Reason) 'Yellow';continue}
  if($entry.Sha256 -notmatch '^[a-fA-F0-9]{64}$'){Note 'Missing ASUS SHA-256; blocked.' 'Red';continue}
  $uri=$null
  try{$uri=[uri]$entry.Url}catch{Note 'Invalid URL; blocked.' 'Red';continue}
  if($uri.Scheme -ne 'https' -or $uri.Host -notin @('dlcdnets.asus.com','dlcdnets.asus.com','dlcdnweb.asus.com','www.asus.com','rog.asus.com')){
   Note 'Driver source is not an approved ASUS HTTPS hostname.' 'Red';continue
  }
  $ext=[IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant()
  if($ext -notin @('.zip','.cab','.exe')){Note 'Only verified ASUS ZIP/CAB/EXE packages are allowed.' 'Yellow';continue}
  $dest=Join-Path $root ('ASUS-MediaTek-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
  [void](New-Item -ItemType Directory -Path $dest -Force)
  $file=Join-Path $dest ('MediaTekWLAN'+$ext)
  Note ('Downloading from official ASUS: '+$entry.Name) 'Yellow'
  try{
   Invoke-WebRequest -Method Get -Uri $entry.Url -UseBasicParsing -TimeoutSec 180 -OutFile $file | Out-Null
   $calculated=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
   if($calculated -ine $entry.Sha256){
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    throw 'Downloaded package SHA-256 does not match official ASUS catalog. Rejected.'
   }
   Note 'ASUS package SHA-256 verified.' 'Green'
   if($ext -eq '.exe'){
    $signature=Get-AuthenticodeSignature -LiteralPath $file
    if($signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch '(?i)ASUSTeK COMPUTER INC'){
     throw 'Driver installer signature invalid or not signed by ASUSTeK. Execution blocked.'
    }
    $fileMeta=(Get-Item -LiteralPath $file).VersionInfo
    if([string]$fileMeta.ProductName -notmatch '(?i)MediaTek.*WLAN'){
     throw 'ASUS installer ProductName is not MediaTek WLAN Driver. Execution blocked.'
    }
    if([string]$fileMeta.OriginalFilename -notmatch '(?i)^WirelessLan_.+MediaTek.+\.exe$'){
     throw 'Unexpected ASUS installer original filename. Execution blocked.'
    }
    $installerData=[IO.File]::ReadAllBytes($file)
    $isInno=[Text.Encoding]::ASCII.GetString($installerData).Contains('Inno Setup')
    if(-not $isInno){throw 'Unknown installer engine. Automatic execution blocked.'}
    Note 'ASUSTeK signature verified; MediaTek WLAN Inno Setup installer identified.' 'Green'
    $installLog=Join-Path $dest 'InnoSetup-install.log'
    $logArg='/LOG="' + $installLog + '"'
    $arguments=@('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOCLOSEAPPLICATIONS',$logArg)
    Note 'Installing official ASUS WLAN driver silently (no automatic restart) ...' 'Yellow'
    $process=Start-Process -FilePath $file -ArgumentList $arguments -PassThru -Wait -ErrorAction Stop
    if($process.ExitCode -eq 0){
     Note ('ASUS installer exited successfully. Reboot may be needed. Log: '+$installLog) 'Green'
    }else{
     Note ('ASUS installer exit code '+$process.ExitCode+'. Review log: '+$installLog) 'Red'
    }
    continue
   }
   $extract=Join-Path $dest 'Extracted'
   [void](New-Item -ItemType Directory -Path $extract -Force)
   if($ext -eq '.zip'){Expand-Archive -LiteralPath $file -DestinationPath $extract -Force}
   else{
    & "$env:windir\System32\expand.exe" -F:* $file $extract | Out-Host
    if($LASTEXITCODE -ne 0){throw ('CAB extraction failed: '+$LASTEXITCODE)}
   }
   $infs=@(Get-ChildItem -LiteralPath $extract -File -Recurse -Filter '*.inf' -ErrorAction Stop)
   if(-not $infs.Count){
    Note ('No INF found. ASUS archive saved for review at '+$dest) 'Yellow'
    continue
   }
   Note ('Found '+$infs.Count+' INF(s). Windows PnPUtil will verify signatures and applicable hardware IDs.')
   foreach($inf in $infs){
    & "$env:windir\System32\pnputil.exe" /add-driver $inf.FullName /install | Out-Host
    if($LASTEXITCODE -ne 0){Note ('PnPUtil returned '+$LASTEXITCODE+' for '+$inf.Name) 'Yellow'}
   }
   Note 'ASUS driver package processed. Check driver version after re-scan and reboot if prompted.' 'Green'
  }catch{Note ('ASUS download/install failed: '+$_.Exception.Message) 'Red'}
 }
}
function Deep-State($catalog){
 $ctx=& $script:PreviousDeepState $catalog
 if($ctx.OEM.Kind -eq 'ASUS'){
  $asus=Get-ASUSCatalog $ctx.OEM
  $ctx|Add-Member -NotePropertyName ASUS -NotePropertyValue $asus -Force
  Note ('ASUS official catalog: '+$asus.Status) $(if(@($asus.Items|Where-Object Allowed).Count){'Green'}else{'Yellow'})
 }
 return $ctx
}
function Deep-Items($ctx){
 if($ctx.ASUS){foreach($a in @($ctx.ASUS.Items)){$a}}
 & $script:PreviousDeepItems $ctx
}
function Apply-Drivers($cat,[object[]]$selection,$oem){
 $items=@($selection|Where-Object {$_.Allowed})
 if(-not $items.Count){Note 'No eligible drivers selected; nothing installed.' 'Yellow';return}
 Header 'CONFIRM DRIVER INSTALLATION'
 foreach($item in $items){Note ('['+$item.Source+'] '+$item.Name) 'Yellow'}
 Note 'Network driver changes can temporarily disconnect Wi-Fi.' 'Yellow'
 if(-not (Ask 'Download and install chosen driver packages?')){Note 'Cancelled.' 'Yellow';return}
 if(-not (Safe-Prepare)){return}
 $asus=@($items|Where-Object {$_.Source -eq 'ASUS'})
 if($asus.Count){Install-ASUS $asus}
 $oemSelected=@($items|Where-Object {$_.Source -eq 'OEM'})
 if($oemSelected.Count){Install-OEM $oem}
 $local=@($items|Where-Object {$_.Source -eq 'INF'}|ForEach-Object {$_.File})
 if($local.Count){Install-INFs $local}
 $wu=@($items|Where-Object {$_.Source -eq 'WU'})
 if($wu.Count){Install-WU $cat $wu}
 Note 'Install pass finished. Deep Scan will refresh the driver status.' 'Green'
}
