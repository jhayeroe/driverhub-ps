#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Scan,[switch]$Deep)
# DriverHub PS v2.0 | Interactive Windows and OEM driver workflow.
$ErrorActionPreference='Stop'
$root=Join-Path $env:ProgramData 'DriverHubPS'
$reports=Join-Path $root 'Reports'
$backups=Join-Path $root 'Backups'
$drivers=Join-Path $root 'OEM-Drivers'
foreach($d in @($root,$reports,$backups,$drivers)){[void](New-Item -ItemType Directory -Path $d -Force)}
$admin=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Write-Host 'Run Windows PowerShell as Administrator.' -ForegroundColor Red;return}
if($PSVersionTable.PSEdition -ne 'Desktop'){Write-Host 'Use Windows PowerShell 5.1 (powershell.exe).' -ForegroundColor Red;return}
$script:cfg=[ordered]@{Backup=$true;RestorePoint=$true;Days=3}
$cfgFile=Join-Path $root 'Settings.json'
if(Test-Path $cfgFile){try{$s=Get-Content $cfgFile -Raw|ConvertFrom-Json
 $script:cfg.Backup=[bool]$s.Backup;$script:cfg.RestorePoint=[bool]$s.RestorePoint
 if($s.Days -in @(1,3,7,14)){$script:cfg.Days=[int]$s.Days}
}catch{}}
$script:prepared=$false
function Note([string]$s,[string]$c='Cyan'){Write-Host ('  '+$s) -ForegroundColor $c}
function Header([string]$s){Write-Host '';Write-Host ('='*65) -ForegroundColor DarkCyan;Write-Host ('  '+$s) -ForegroundColor White;Write-Host ('='*65) -ForegroundColor DarkCyan}
function Ask([string]$s){return ((Read-Host ($s+' [y/N]')) -match '^(?i:y|yes)$')}
function Pause-Menu{[void](Read-Host 'Press Enter to continue')}
function Save-Config{$script:cfg|ConvertTo-Json|Set-Content $cfgFile -Encoding UTF8}
function Device-Problems {
 $seen=@(Get-PnpDevice -PresentOnly)
 $map=@{};foreach($d in @(Get-CimInstance Win32_PnPEntity)){if($d.PNPDeviceID){$map[$d.PNPDeviceID]=$d}}
 foreach($d in $seen){
  $code=0
  if($map.ContainsKey($d.InstanceId)){$code=[int]$map[$d.InstanceId].ConfigManagerErrorCode}
  if($code -ne 0 -or $d.Status -ne 'OK'){
   [pscustomobject]@{Name=$d.FriendlyName;Class=$d.Class;Code=$code;Status=$d.Status;InstanceId=$d.InstanceId}
  }
 }
}
function Show-Devices([object[]]$p){
 Note ('Missing driver / Code 28: '+@($p|Where-Object {$_.Code -eq 28}).Count) 'Yellow'
 Note ('Other device problems: '+@($p|Where-Object {$_.Code -ne 28}).Count) 'Yellow'
 if($p.Count){$p|Format-Table Name,Class,Code,Status -AutoSize -Wrap|Out-Host}else{Note 'No device-manager problem codes found.' 'Green'}
 Note 'Existing drivers can still malfunction even without a Device Manager warning.' 'DarkYellow'
}
function Find-WU {
 $session=New-Object -ComObject Microsoft.Update.Session
 $session.ClientApplicationID='DriverHub PS'
 $search=$session.CreateUpdateSearcher()
 $res=$search.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
 $items=@(for($i=0;$i -lt $res.Updates.Count;$i++){
  $u=$res.Updates.Item($i);$blocked=$false;$why=''
  if($u.Title -match '(?i)\b(BIOS|UEFI|Firmware)\b'){$blocked=$true;$why='firmware excluded'}
  try{if($u.IsBeta){$blocked=$true;$why='beta excluded'}}catch{}
  try{if($u.InstallationBehavior.CanRequestUserInput){$blocked=$true;$why='requires interaction'}}catch{}
  $level=if($u.BrowseOnly){'Optional'}elseif($u.IsAssigned){'Recommended'}else{'Other'}
  [pscustomobject]@{Source='WU';Name=$u.Title;Level=$level;Allowed=(-not $blocked);Reason=$why;Update=$u;File=$null}
 })
 [pscustomobject]@{Session=$session;Items=$items}
}
function Show-WU($cat){
 if(-not $cat){Note 'Windows Update scan unavailable.' 'Yellow';return}
 Note ('Driver packages from Windows Update: '+@($cat.Items).Count) 'Green'
 for($i=0;$i -lt $cat.Items.Count;$i++){
  $u=$cat.Items[$i];$label=if($u.Allowed){$u.Level}else{'BLOCKED: '+$u.Reason}
  Write-Host ('  [{0}] [{1}] {2}' -f ($i+1),$label,$u.Name)
 }
 if(-not $cat.Items.Count){Note 'No applicable Windows Update driver packages found.' 'Yellow'}
}
function Choose-Items([int]$max){
 if($max -lt 1){return ,@()}
 $answer=Read-Host 'Select multiple numbers, e.g. 1,3-5 (blank=cancel)'
 if([string]::IsNullOrWhiteSpace($answer)){return ,@()}
 $chosen=@()
 foreach($part in ($answer -split ',')){
  $p=$part.Trim()
  if($p -match '^\d+$'){$chosen+=([int]$p)}
  elseif($p -match '^(\d+)-(\d+)$'){
   $a=[int]$Matches[1];$b=[int]$Matches[2]
   if($a -gt $b -or ($b-$a) -gt 100){Note 'Invalid range.' 'Red';return ,@()}
   $chosen+=@($a..$b)
  }else{Note 'Invalid number format.' 'Red';return ,@()}
 }
 $chosen=@($chosen|Sort-Object -Unique)
 if(@($chosen|Where-Object {$_ -lt 1 -or $_ -gt $max}).Count){Note 'A selection is outside the displayed list.' 'Red';return ,@()}
 return ,$chosen
}
function Backup-Drivers {
 $folder=Join-Path $backups (Get-Date -Format 'yyyyMMdd-HHmmss')
 [void](New-Item -ItemType Directory -Path $folder -Force)
 Note 'Backing up existing third-party driver packages ...'
 & "$env:windir\System32\pnputil.exe" /export-driver '*' $folder|Out-Host
 if($LASTEXITCODE -ne 0){throw 'Driver backup failed. Driver installation cancelled.'}
 Note ('Backup folder: '+$folder) 'Green'
}
function Safe-Prepare {
 if($script:prepared){return $true}
 if($script:cfg.Backup){try{Backup-Drivers}catch{Note $_.Exception.Message 'Red';return $false}}
 else{Note 'Driver backup has been disabled in Settings.' 'Yellow'}
 if($script:cfg.RestorePoint){
  try{Checkpoint-Computer -Description 'DriverHub pre-driver installation' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
   Note 'Restore point created.' 'Green'
  }catch{Note ('Restore point unavailable: '+$_.Exception.Message) 'Yellow'}
 }
 $script:prepared=$true
 return $true
}
function Install-WU($cat,[object[]]$items){
 if(-not $cat -or -not $items.Count){return}
 $logs=@()
 foreach($entry in $items){
  if(-not $entry.Allowed){continue}
  $u=$entry.Update;$status='Error';$msg='';$reboot=$false
  try{
   if(-not $u.EulaAccepted){$u.AcceptEula()}
   $coll=New-Object -ComObject Microsoft.Update.UpdateColl
   [void]$coll.Add($u)
   if(-not $u.IsDownloaded){
    $dl=$cat.Session.CreateUpdateDownloader();$dl.Updates=$coll
    $dlResult=$dl.Download()
    if([int]$dlResult.ResultCode -notin @(2,3)){throw ('Download failed: '+$dlResult.ResultCode)}
   }
   if(-not $u.IsDownloaded){throw 'Download incomplete.'}
   $installer=$cat.Session.CreateUpdateInstaller();$installer.Updates=$coll
   $installer.AllowSourcePrompts=$false
   if($installer.RebootRequiredBeforeInstallation){throw 'Restart required before installing.'}
   $result=$installer.Install()
   $detail=$result.GetUpdateResult(0)
   $status=switch([int]$detail.ResultCode){2{'Installed'}3{'Installed with errors'}4{'Failed'}5{'Aborted'}default{'Unknown'}}
   $msg='HRESULT '+$detail.HResult
   $reboot=[bool]$result.RebootRequired
  }catch{$msg=$_.Exception.Message}
  Note ($entry.Name+' => '+$status+'; '+$msg) $(if($status -eq 'Installed'){'Green'}else{'Yellow'})
  $logs+=([pscustomobject]@{Time=Get-Date;Driver=$entry.Name;Source='Windows Update';Result=$status;Details=$msg;Reboot=$reboot})
  if($reboot){Note 'Reboot required. Remaining packages deferred.' 'Yellow';break}
 }
 if($logs.Count){
  $file=Join-Path $reports ('WU-Install-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.csv')
  $logs|Export-Csv $file -NoTypeInformation -Encoding UTF8
  Note ('Installation log: '+$file)
 }
}
function Detect-OEM {
 $pc=Get-CimInstance Win32_ComputerSystem
 $m=[string]$pc.Manufacturer;$kind='Other';$paths=@()
 $pf86=[Environment]::GetFolderPath('ProgramFilesX86')
 if($m -match '(?i)Dell'){
  $kind='Dell'
  $paths=@((Join-Path $pf86 'Dell\CommandUpdate\dcu-cli.exe'),(Join-Path $env:ProgramFiles 'Dell\CommandUpdate\dcu-cli.exe'))
 }elseif($m -match '(?i)Hewlett|HP\b'){
  $kind='HP'
  $paths=@((Join-Path $env:ProgramFiles 'HP\HP Image Assistant\HPImageAssistant.exe'),(Join-Path $root 'HPImageAssistant\HPImageAssistant.exe'))
  $sw=Join-Path $env:SystemDrive 'SWSetup'
  if(Test-Path $sw){$paths+=@(Get-ChildItem $sw -Directory -ErrorAction SilentlyContinue|Select-Object -First 60|ForEach-Object {Join-Path $_.FullName 'HPImageAssistant.exe'})}
 }elseif($m -match '(?i)Lenovo'){
  $kind='Lenovo'
  $paths=@((Join-Path $pf86 'Lenovo\System Update\tvsu.exe'),(Join-Path $env:ProgramFiles 'Lenovo\System Update\tvsu.exe'))
 }
 $exe=$null;foreach($p in $paths){if($p -and (Test-Path -LiteralPath $p -PathType Leaf)){$exe=$p;break}}
 $valid=$false
 if($exe){try{$s=Get-AuthenticodeSignature -FilePath $exe
  $valid=($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match '(?i)Dell|HP|Hewlett|Lenovo')
 }catch{}}
 [pscustomobject]@{Kind=$kind;Manufacturer=$m;Model=$pc.Model;Exe=$exe;Valid=$valid;Status='Not scanned';Log=''}
}
function Scan-OEM($o){
 if(-not $o.Exe){$o.Status='Official updater not installed';return}
 if(-not $o.Valid){$o.Status='OEM application digital signature not verified';return}
 Note ('Scanning external '+$o.Kind+' driver catalog ...')
 $tag=Get-Date -Format 'yyyyMMdd-HHmmss'
 try{
  switch($o.Kind){
   'Dell'{
    $xml=Join-Path $reports ('Dell-'+$tag+'.xml')
    $log=Join-Path $reports ('Dell-'+$tag+'.log')
    & $o.Exe /scan '-updateType=driver' "-report=$xml" "-outputLog=$log" -silent | Out-Host
    $rc=$LASTEXITCODE;$o.Log=$log
    $o.Status=if($rc -eq 0){'Driver updates found'}elseif($rc -eq 500){'No driver updates'}else{'Scan error '+$rc}
   }
   'HP'{
    $dir=Join-Path $reports ('HP-'+$tag);[void](New-Item -ItemType Directory -Path $dir -Force)
    & $o.Exe /Operation:Analyze /Action:List /Category:Drivers /Selection:AutoInstallable /Silent "/ReportFolder:$dir"|Out-Host
    $rc=$LASTEXITCODE;$o.Log=$dir
    $o.Status=if($rc -eq 0){'Recommendations available; see report'}elseif($rc -in @(256,257)){'No auto-installable recommendations'}else{'Scan result '+$rc}
   }
   'Lenovo'{$o.Status='Driver-only OEM scan available on install'}
  }
 }catch{$o.Status=('Scan error: '+$_.Exception.Message)}
 Note ('OEM result: '+$o.Status) 'Yellow'
}
function OEM-Ready($o){
 if(-not $o -or -not $o.Exe -or -not $o.Valid){return $false}
 if($o.Status -match '(?i)^No driver|^No auto|^Scan error|signature'){return $false}
 return $true
}
function Show-OEM($o){
 Note ('PC: '+$o.Manufacturer+' | '+$o.Model)
 if($o.Kind -eq 'Other'){Note 'No integrated external OEM catalog for this manufacturer.' 'Yellow'}
 elseif(-not $o.Exe){Note ('External '+$o.Kind+' CLI is missing. Settings can install supported OEM utilities.') 'Yellow'}
 elseif(-not $o.Valid){Note 'OEM executable signature not verified; blocked from executing.' 'Red'}
 else{Note ('External '+$o.Kind+' driver-only catalog: '+$o.Status) 'Green'}
 Note 'OEM updater is presented as one driver-only batch; not individual packages.' 'DarkYellow'
}
function Install-OEM($o){
 if(-not (OEM-Ready $o)){Note 'OEM driver source is unavailable.' 'Yellow';return}
 Note ('Installing approved driver-only updates via '+$o.Kind+' OEM CLI ...') 'Yellow'
 $tag=Get-Date -Format 'yyyyMMdd-HHmmss';$rc=-1
 try{
  switch($o.Kind){
   'Dell'{
    $log=Join-Path $reports ('Dell-Install-'+$tag+'.log')
    & $o.Exe /applyUpdates '-updateType=driver' '-reboot=disable' "-outputLog=$log" -silent | Out-Host
    $rc=$LASTEXITCODE;Note ('Dell log: '+$log)
   }
   'HP'{
    $d=Join-Path $reports ('HP-Install-'+$tag);[void](New-Item -ItemType Directory -Path $d -Force)
    $dl=Join-Path $root 'HP-Downloads';[void](New-Item -ItemType Directory -Path $dl -Force)
    & $o.Exe /Operation:Analyze /Action:Install /Category:Drivers /Selection:AutoInstallable /Silent /NoReboot "/ReportFolder:$d" "/SoftPaqDownloadFolder:$dl"|Out-Host
    $rc=$LASTEXITCODE;Note ('HP report: '+$d)
   }
   'Lenovo'{
    & $o.Exe /CM -search R -action INSTALL -packagetypes 2 -includerebootpackages 3 -noreboot -noicon | Out-Host
    $rc=$LASTEXITCODE
   }
  }
 }catch{Note ('OEM install error: '+$_.Exception.Message) 'Red';return}
 Note ('OEM installation exit code: '+$rc) $(if($rc -eq 0){'Green'}else{'Yellow'})
 if($rc -in @(1,3010)){Note 'Please restart Windows manually.' 'Yellow'}
 if($rc -notin @(0,1,3010,256,257,500)){Note 'Check OEM report before assuming success.' 'Yellow'}
}
function Local-INFs {Get-ChildItem -Path $drivers -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue|Sort-Object FullName}
function Install-INFs([object[]]$files){
 foreach($f in $files){
  Note ('Applying local INF: '+$f.FullName)
  & "$env:windir\System32\pnputil.exe" /add-driver $f.FullName /install | Out-Host
  if($LASTEXITCODE -ne 0){Note ('PnPUtil returned '+$LASTEXITCODE) 'Red'}
 }
 Note 'Windows will only accept valid compatible driver packages with applicable ranking.' 'Yellow'
}
function Apply-Drivers($cat,[object[]]$selection,$oem){
 $items=@($selection|Where-Object Allowed)
 if(-not $items.Count){Note 'No installable driver packages selected.' 'Yellow';return}
 Header 'DRIVER INSTALLATION CONFIRMATION'
 foreach($i in $items){Note ('['+$i.Source+'] '+$i.Name) 'Yellow'}
 Note 'Wi-Fi/network may disconnect during a driver update.' 'Yellow'
 if(-not (Ask 'Download and install the selected drivers?')){Note 'Cancelled.';return}
 if(-not (Safe-Prepare)){return}
 if(@($items|Where-Object {$_.Source -eq 'OEM'}).Count){Install-OEM $oem}
 $infs=@($items|Where-Object {$_.Source -eq 'INF'}|ForEach-Object {$_.File})
 if($infs.Count){Install-INFs $infs}
 $wu=@($items|Where-Object {$_.Source -eq 'WU'})
 if($wu.Count){Install-WU $cat $wu}
 Note 'Driver installation pass complete. Re-scan to verify, and reboot if required.' 'Green'
}
function Wifi-Audit {
 $adapters=@()
 try{$adapters=@(Get-NetAdapter|Where-Object {$_.Name -match '(?i)Wi-?Fi|WLAN|Wireless' -or $_.InterfaceDescription -match '(?i)Wi-?Fi|WLAN|Wireless|802\.11'})}catch{}
 $signed=@(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)
 $info=@(foreach($a in $adapters){
  $d=@($signed|Where-Object {$_.DeviceName -eq $a.InterfaceDescription}|Select-Object -First 1)
  $stats=$null;try{$stats=Get-NetAdapterStatistics -Name $a.Name}catch{}
  [pscustomobject]@{Name=$a.Name;Status=$a.Status;DriverVersion=$(if($d.Count){$d[0].DriverVersion}else{'Unknown'});
   RxErrors=$(if($stats){$stats.ReceivedPacketErrors}else{'N/A'});TxErrors=$(if($stats){$stats.OutboundPacketErrors}else{'N/A'})}
 })
 $start=(Get-Date).AddDays(-[int]$script:cfg.Days)
 $wlan=@();$system=@()
 try{$wlan=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WLAN-AutoConfig/Operational';StartTime=$start} -MaxEvents 300 -ErrorAction Stop)}catch{}
 try{$system=@(Get-WinEvent -FilterHashtable @{LogName='System';StartTime=$start;Level=@(2,3)} -MaxEvents 500 -ErrorAction Stop|Where-Object {$_.ProviderName -match '(?i)Netwtw|NDIS|rtwlane|athw|mtkw|Kernel-PnP'})}catch{}
 [pscustomobject]@{Adapters=$info;WLAN=$wlan;System=$system}
}
function Show-Wifi($w){
 Header 'WI-FI DRIVER HEALTH / STABILITY'
 if($w.Adapters.Count){$w.Adapters|Format-Table -AutoSize|Out-Host}else{Note 'No Wi-Fi adapter identified. Could be missing or disabled.' 'Yellow'}
 Note ('Recent WLAN disconnect events (8003): '+@($w.WLAN|Where-Object Id -eq 8003).Count)
 Note ('WLAN warning/error events: '+@($w.WLAN|Where-Object {$_.Level -in @(2,3)}).Count)
 Note ('Relevant System network/PnP warnings/errors: '+$w.System.Count)
 if($w.System.Count){$w.System|Select-Object -First 6 TimeCreated,ProviderName,Id|Format-Table -AutoSize|Out-Host}
 Note 'These indicators suggest instability but do not prove the driver is outdated.' 'Yellow'
}
function Wifi-Menu {
 do{
  $w=Wifi-Audit;Show-Wifi $w
  Write-Host '  [1] RESTART Wi-Fi device (temporarily disconnects network)'
  Write-Host '  [2] Rescan hardware devices'
  Write-Host '  [3] View detailed recent network errors'
  Write-Host '  [4] Show wireless connection details'
  Write-Host '  [5] Reset Windows Winsock/TCP-IP stack (advanced; requires reboot)'
  Write-Host '  [0] Return to previous scan'
  $choice=Read-Host 'Choose'
  try{
   switch($choice){
    '1'{
     $dev=@(Get-PnpDevice -PresentOnly|Where-Object {$_.Class -eq 'Net' -and $_.FriendlyName -match '(?i)Wi-?Fi|Wireless|WLAN|802\.11' -and $_.FriendlyName -notmatch '(?i)Virtual|Wi-Fi Direct|VPN|Bluetooth'})
     for($i=0;$i -lt $dev.Count;$i++){Note ('['+($i+1)+'] '+$dev[$i].FriendlyName)}
     if(-not $dev.Count){Note 'Wi-Fi device not found.' 'Yellow'}
     else{
      $nums=Choose-Items $dev.Count
      if($nums.Count -and (Ask 'Restart chosen devices? This will interrupt Internet access.')){
       foreach($n in $nums){
        & "$env:windir\System32\pnputil.exe" /restart-device $dev[$n-1].InstanceId | Out-Host
        if($LASTEXITCODE -ne 0){Note ('Device restart failed: '+$LASTEXITCODE) 'Red'}
       }
      }
     }
    }
    '2'{& "$env:windir\System32\pnputil.exe" /scan-devices|Out-Host}
    '3'{$w.System|Select-Object -First 12 TimeCreated,ProviderName,Id,Message|Format-List|Out-Host
     $w.WLAN|Where-Object {$_.Level -in @(2,3)}|Select-Object -First 12 TimeCreated,Id,Message|Format-List|Out-Host}
    '4'{& "$env:windir\System32\netsh.exe" wlan show interfaces|Out-Host}
    '5'{
     Note 'Advanced repair: may reset manual IP, DNS, proxy/VPN-related network settings.' 'Yellow'
     Note 'A Windows restart will be needed. This is not proof of a driver fault.' 'Yellow'
     if(Ask 'Reset Windows Winsock and TCP/IP settings?'){
      & "$env:windir\System32\netsh.exe" winsock reset | Out-Host
      & "$env:windir\System32\netsh.exe" int ip reset | Out-Host
      Note 'Commands completed. Check their output, then restart Windows manually.' 'Yellow'
     }
    }
    '0'{Note 'Returning to scan.'}
    default{Note 'Invalid option.' 'Yellow'}
   }
  }catch{Note $_.Exception.Message 'Red'}
  if($choice -ne '0'){Pause-Menu}
 }while($choice -ne '0')
}
function Windows-Scan {
 Header 'SCAN 1 - WINDOWS UPDATE + MISSING DRIVERS'
 try{& "$env:windir\System32\pnputil.exe" /scan-devices|Out-Host}catch{}
 $p=@(Device-Problems);Show-Devices $p
 $cat=$null
 try{$cat=Find-WU;Show-WU $cat}catch{Note ('Windows Update unavailable: '+$_.Exception.Message) 'Red'}
 [pscustomobject]@{Issues=$p;Catalog=$cat}
}
function Scan1-Menu {
 $state=Windows-Scan
 do{
  Header 'SCAN 1 - CHOOSE NEXT ACTION'
  Show-WU $state.Catalog
  if(-not $state.Catalog -or -not @($state.Catalog.Items|Where-Object Allowed).Count){
   Note 'Nothing installable via Windows Update. Deep Scan is available now.' 'Yellow'
  }
  Write-Host '  [1] DOWNLOAD + INSTALL ALL Windows Update drivers (backup first)'
  Write-Host '  [2] SELECT multiple Windows Update drivers to install'
  Write-Host '  [3] PROCEED TO DEEP SCAN outside Windows Update'
  Write-Host '  [4] Re-scan missing drivers + Windows Update'
  Write-Host '  [0] Main menu'
  $choice=Read-Host 'Choose'
  try{
   switch($choice){
    '1'{if($state.Catalog){Apply-Drivers $state.Catalog @($state.Catalog.Items|Where-Object Allowed) $null;$state=Windows-Scan}}
    '2'{if($state.Catalog){$nums=Choose-Items $state.Catalog.Items.Count
      if($nums.Count){$selected=@(foreach($n in $nums){$state.Catalog.Items[$n-1]});Apply-Drivers $state.Catalog $selected $null;$state=Windows-Scan}
     }}
    '3'{Deep-Menu $state.Catalog}
    '4'{$state=Windows-Scan}
    '0'{Note 'Main menu.'}
    default{Note 'Invalid option.' 'Yellow'}
   }
  }catch{Note ('Scan error: '+$_.Exception.Message) 'Red'}
  if($choice -notin @('0','3')){Pause-Menu}
 }while($choice -ne '0')
}
function Deep-State($catalog){
 Header 'DEEP SCAN - HARDWARE / WI-FI / OFFICIAL OEM'
 $problems=@(Device-Problems);Show-Devices $problems
 $wifi=Wifi-Audit;Show-Wifi $wifi
 $oem=Detect-OEM;Show-OEM $oem
 if($oem.Exe -and $oem.Valid){Scan-OEM $oem}
 $inf=@(Local-INFs)
 Note ('Local extracted OEM INF packages: '+$inf.Count)
 if(-not $catalog){try{$catalog=Find-WU}catch{Note ('Combined Windows Update source unavailable: '+$_.Exception.Message) 'Yellow'}}
 [pscustomobject]@{Problems=$problems;Wifi=$wifi;OEM=$oem;Local=$inf;WU=$catalog}
}
function Deep-Items($ctx){
 if(OEM-Ready $ctx.OEM){[pscustomobject]@{Source='OEM';Name=($ctx.OEM.Kind+' official DRIVER-ONLY batch');Level='OEM';Allowed=$true;File=$null;Update=$null}}
 foreach($f in $ctx.Local){[pscustomobject]@{Source='INF';Name=$f.FullName;Level='Local';Allowed=$true;File=$f;Update=$null}}
 if($ctx.WU){foreach($u in $ctx.WU.Items){$u}}
}
function Deep-Menu($catalog=$null){
 $ctx=Deep-State $catalog
 do{
  Header 'DEEP SCAN - SELECT NEXT ACTION'
  Note ('Device problems found: '+$ctx.Problems.Count+' | Wi-Fi interfaces: '+$ctx.Wifi.Adapters.Count)
  Show-OEM $ctx.OEM
  $available=@(Deep-Items $ctx)
  Note ('Installable source entries: '+@($available|Where-Object Allowed).Count) 'Green'
  Write-Host '  [1] INSTALL ALL including Windows Update (backup first)'
  Write-Host '  [2] INSTALL ALL EXCLUDING Windows Update (ASUS / OEM / local)'
  Write-Host '  [3] MULTI-SELECT ASUS + OEM + local + Windows Update drivers'
  Write-Host '  [4] Wi-Fi diagnostics / targeted repair'
  Write-Host '  [5] Re-run Deep Scan'
  Write-Host '  [6] Setup official OEM updater'
  Write-Host '  [0] Return to previous menu'
  $choice=Read-Host 'Choose'
  try{
   switch($choice){
    '1'{Apply-Drivers $ctx.WU @($available|Where-Object Allowed) $ctx.OEM;$ctx=Deep-State $null}
    '2'{
     $others=@($available|Where-Object {$_.Allowed -and $_.Source -ne 'WU'})
     if($others.Count){Apply-Drivers $ctx.WU $others $ctx.OEM;$ctx=Deep-State $null}
     else{Note 'No verified ASUS/OEM/local package. Check ASUS catalog status above for reason.' 'Yellow'}
    }
    '3'{
     for($i=0;$i -lt $available.Count;$i++){
      $a=$available[$i];$tag=if($a.Allowed){$a.Source+'/'+$a.Level}else{'BLOCKED'}
      Write-Host ('  [{0}] [{1}] {2}' -f ($i+1),$tag,$a.Name)
     }
     $nums=Choose-Items $available.Count
     if($nums.Count){$selected=@(foreach($n in $nums){$available[$n-1]});Apply-Drivers $ctx.WU $selected $ctx.OEM;$ctx=Deep-State $null}
    }
    '4'{Wifi-Menu}
    '5'{$ctx=Deep-State $null}
    '6'{Setup-OEM;$ctx=Deep-State $null}
    '0'{Note 'Returning.'}
    default{Note 'Invalid option.' 'Yellow'}
   }
  }catch{Note ('Deep scan error: '+$_.Exception.Message) 'Red'}
  if($choice -notin @('0','4')){Pause-Menu}
 }while($choice -ne '0')
}
function Setup-OEM {
 $o=Detect-OEM;Header 'OFFICIAL OEM UPDATER SETUP';Show-OEM $o
 if($o.Exe -and $o.Valid){Note 'Official updater already available.' 'Green';return}
 $id=switch($o.Kind){'Dell'{'Dell.CommandUpdate'}'Lenovo'{'Lenovo.SystemUpdate'}default{''}}
 if(-not $id){Note 'No automated OEM installer configured for this manufacturer. For HP install HP Image Assistant manually from HP support.' 'Yellow';return}
 if(-not (Get-Command winget -ErrorAction SilentlyContinue)){Note 'winget is unavailable. Download the OEM updater from manufacturer support.' 'Yellow';return}
 Note ('Will use winget to install '+$id+' (manufacturer-supplied installer).') 'Yellow'
 if(-not (Ask 'Install OEM updater now?')){return}
 & winget install --id $id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
 Note ('winget exit code: '+$LASTEXITCODE)
 $check=Detect-OEM
 if(-not $check.Valid){Note 'Updater not yet found or publisher not verified. Retry after checking OEM setup.' 'Yellow'}
}
function Settings-Menu {
 do{
  Header 'SETTINGS / BACKUP / REPORTS'
  Write-Host ('  [1] Automatic backup third-party drivers: '+$script:cfg.Backup)
  Write-Host ('  [2] Attempt restore point: '+$script:cfg.RestorePoint)
  Write-Host ('  [3] Event history days: '+$script:cfg.Days)
  Write-Host '  [4] Set up official Dell / Lenovo driver utility'
  Write-Host '  [5] Import official OEM INF driver folder'
  Write-Host '  [6] Backup current drivers now'
  Write-Host '  [7] Export installed drivers + problem report'
  Write-Host '  [0] Return to main menu'
  $choice=Read-Host 'Choose'
  try{
   switch($choice){
    '1'{$script:cfg.Backup=-not $script:cfg.Backup;Save-Config}
    '2'{$script:cfg.RestorePoint=-not $script:cfg.RestorePoint;Save-Config}
    '3'{$days=Read-Host 'Choose 1,3,7,14';if($days -in @('1','3','7','14')){$script:cfg.Days=[int]$days;Save-Config}}
    '4'{Setup-OEM}
    '5'{
     Note 'Import only extracted manufacturer-approved drivers for this PC model.' 'Yellow'
     $path=Read-Host 'Source folder path (blank=cancel)'
     if($path -and (Test-Path -LiteralPath $path -PathType Container)){
      $inf=@(Get-ChildItem -LiteralPath $path -File -Filter '*.inf' -Recurse)
      if($inf.Count -and (Ask ('Import '+$inf.Count+' INF files from this folder?'))){
       $dest=Join-Path $drivers ('Imported-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
       [void](New-Item $dest -ItemType Directory -Force)
       Copy-Item -LiteralPath $path -Destination $dest -Recurse
       Note ('Local OEM packages copied: '+$dest) 'Green'
      }else{Note 'No INF files or import cancelled.' 'Yellow'}
     }
    }
    '6'{Backup-Drivers}
    '7'{
     $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
     Get-CimInstance Win32_PnPSignedDriver|Select-Object DeviceName,DriverProviderName,DriverVersion,InfName,DriverDate|
      Export-Csv (Join-Path $reports ('Installed-'+$stamp+'.csv')) -NoTypeInformation -Encoding UTF8
     @(Device-Problems)|Export-Csv (Join-Path $reports ('Problems-'+$stamp+'.csv')) -NoTypeInformation -Encoding UTF8
     Note ('Reports saved in '+$reports) 'Green'
    }
    '0'{Note 'Returning.'}
    default{Note 'Invalid option.' 'Yellow'}
   }
  }catch{Note ('Settings error: '+$_.Exception.Message) 'Red'}
  if($choice -notin @('0','1','2','3')){Pause-Menu}
 }while($choice -ne '0')
}
function Main-Menu {
 do{
  Header 'DRIVERHUB PS v2.1 | WINDOWS DRIVER RECOVERY'
  Write-Host '  [1] Scan missing drivers and device problems (Windows Update)'
  Write-Host '  [2] Deep Scan potential driver problems (OUTSIDE Windows Update)'
  Write-Host '  [3] Settings'
  Write-Host '  [4] Wi-Fi diagnostics / repair'
  Write-Host '  [5] EXIT'
  $choice=Read-Host 'Choose'
  try{
   switch($choice){
    '1'{Scan1-Menu}
    '2'{Deep-Menu}
    '3'{Settings-Menu}
    '4'{Wifi-Menu}
    '5'{Note 'Exiting DriverHub.' 'Green'}
    default{Note 'Invalid option.' 'Yellow'}
   }
  }catch{Note ('Error: '+$_.Exception.Message) 'Red';Pause-Menu}
 }while($choice -ne '5')
}

# Built-in ASUS module (self-contained in this one-line launcher)
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
      $uri.AbsolutePath -match '(?i)\.(zip|cab)$')
   }catch{}
   $hashValid=($hash -match '^[a-fA-F0-9]{64}$')
   $allowed=$hardwareFound -and $urlValid -and $hashValid -and ($versionValue -ge $installed)
   $reason=if(-not $hardwareFound){'Matching MediaTek adapter / PCI hardware ID not confirmed'}
    elseif(-not $urlValid){'Official download URL was not an approved ASUS ZIP/CAB'}
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
  if($ext -notin @('.zip','.cab')){Note 'Only hash-verifiable ZIP/CAB INF packages are eligible for automatic installation.' 'Yellow';continue}
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

$log=Join-Path $reports ('Session-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt')
$transcript=$false
try{Start-Transcript -Path $log -ErrorAction Stop|Out-Null;$transcript=$true}catch{}
try{if($Scan){Scan1-Menu}elseif($Deep){Deep-Menu}else{Main-Menu}}
finally{if($transcript){try{Stop-Transcript|Out-Null}catch{}}}
