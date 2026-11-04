#Requires -Version 5.1
<#
DriverHub PS v1.1 - Windows-native driver scanner and updater.
Requires Windows PowerShell 5.1 with Administrator privileges.
Uses the configured Windows Update source; does not force OEM updates.
#>
[CmdletBinding()]
param([switch]$Scan, [switch]$Auto)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'DriverHubPS'
$reports = Join-Path $root 'Reports'
$backups = Join-Path $root 'Backups'
foreach($dir in @($root,$reports,$backups)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$admin = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if(-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
 Write-Host 'Run Windows PowerShell as Administrator.' -ForegroundColor Red; return
}
if($PSVersionTable.PSEdition -ne 'Desktop'){
 Write-Host 'Use Windows PowerShell 5.1 (powershell.exe).' -ForegroundColor Red; return
}
function Note([string]$message,[string]$color='Cyan'){ Write-Host "  $message" -ForegroundColor $color }
function Audit {
 Note 'Scanning connected devices ...'
 $devices = @(Get-PnpDevice -PresentOnly)
 $all = @(Get-CimInstance Win32_PnPEntity)
 $byId = @{}
 foreach($d in $all){ if($d.PNPDeviceID){$byId[$d.PNPDeviceID] = $d} }
 $bad = @(
  foreach($d in $devices){
   $code=0; if($byId.ContainsKey($d.InstanceId) -and $null -ne $byId[$d.InstanceId].ConfigManagerErrorCode){$code=[int]$byId[$d.InstanceId].ConfigManagerErrorCode}
   if($code -ne 0 -or $d.Status -ne 'OK'){
    [pscustomobject]@{Name=$d.FriendlyName; Status=$d.Status; ProblemCode=$code; Class=$d.Class; InstanceId=$d.InstanceId}
   }
  }
 )
 Note ("Missing drivers (Code 28): "+@($bad|Where-Object ProblemCode -eq 28).Count) 'Yellow'
 Note ("Other device issues: "+@($bad|Where-Object ProblemCode -ne 28).Count) 'Yellow'
 if($bad.Count){$bad|Format-Table Name,Status,ProblemCode,Class -Wrap -AutoSize|Out-Host}
 else{Note 'No device problems reported.' 'Green'}
 return $bad
}
function Inventory {
 $d=@(Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceName | Select-Object DeviceName,DriverProviderName,DriverVersion,InfName,DriverDate)
 Note ("Driver records: "+$d.Count)
 $d|Sort-Object DeviceName|Format-Table DeviceName,DriverProviderName,DriverVersion,InfName -AutoSize -Wrap|Out-Host
 return $d
}
function Updates([switch]$Recommended){
 $criteria="IsInstalled=0 and IsHidden=0 and Type='Driver'"
 if($Recommended){$criteria+=' and IsAssigned=1 and BrowseOnly=0'}
 Note 'Searching Windows Update for applicable drivers ...'
 $session=New-Object -ComObject 'Microsoft.Update.Session'
 $session.ClientApplicationID='DriverHubPS'
 $searcher=$session.CreateUpdateSearcher()
 $res=$searcher.Search($criteria)
 $items=@(for($i=0;$i -lt $res.Updates.Count;$i++){$res.Updates.Item($i)})
 Note ("Available updates: "+$items.Count) 'Green'
 for($i=0;$i -lt $items.Count;$i++){
  $tag=if($items[$i].BrowseOnly){'OPTIONAL'}elseif($items[$i].IsAssigned){'RECOMMENDED'}else{'OTHER'}
  Write-Host ("  [{0}] ({1}) {2}" -f ($i+1),$tag,$items[$i].Title)
 }
 return [pscustomobject]@{Session=$session; Items=$items}
}
function Install-Updates($catalog,[object[]]$selected,[switch]$Unattended){
 $safe=@(foreach($u in $selected){
  $skip=$false
  if($u.IsBeta -or $u.Title -match '(?i)\b(BIOS|UEFI|Firmware)\b'){$skip=$true}
  try{if($u.InstallationBehavior.CanRequestUserInput){$skip=$true}}catch{$skip=$true}
  if($skip){Note ("Skipping potentially risky package: "+$u.Title) 'Yellow'}else{$u}
 })
 if(-not $safe.Count){Note 'No eligible updates.' 'Yellow';return}
 foreach($u in $safe){Note ("Selected: "+$u.Title)}
 if(-not $Unattended -and (Read-Host 'Install these drivers? y/N') -notmatch '^(?i:y|yes)$'){return}
 try{
  Checkpoint-Computer -Description 'DriverHubPS before driver update' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
  Note 'Restore point created.' 'Green'
 }catch{
  Note ("Restore point unavailable: "+$_.Exception.Message) 'Yellow'
  if($Unattended){Note 'Automatic update cancelled for safety.' 'Red';return}
  if((Read-Host 'Continue without a NEW restore point? y/N') -notmatch '^(?i:y|yes)$'){return}
 }
 $results=New-Object System.Collections.Generic.List[object]
 foreach($u in $safe){
  $status='ERROR';$detail='';$reboot=$false
  try {
   if(-not $u.EulaAccepted){$u.AcceptEula()}
   $coll=New-Object -ComObject 'Microsoft.Update.UpdateColl'
   [void]$coll.Add($u)
   if(-not $u.IsDownloaded){
    $dl=$catalog.Session.CreateUpdateDownloader();$dl.Updates=$coll
    [void]$dl.Download()
   }
   if(-not $u.IsDownloaded){$status='DOWNLOAD FAILED'}
   else{
    $ins=$catalog.Session.CreateUpdateInstaller();$ins.Updates=$coll
    $ins.AllowSourcePrompts=$false
    if($ins.RebootRequiredBeforeInstallation){$status='REBOOT BEFORE INSTALL';$reboot=$true}
    else{
     $res=$ins.Install()
     $status=switch([int]$res.GetUpdateResult(0).ResultCode){2{'SUCCESS'}3{'SUCCESS WITH ERRORS'}4{'FAILED'}5{'ABORTED'}default{'UNKNOWN'}}
     $detail=[string]$res.GetUpdateResult(0).HResult
     $reboot=[bool]$res.RebootRequired
    }
   }
  }catch{$detail=$_.Exception.Message}
  finally{
   Note ("$($u.Title): $status") $(if($status -eq 'SUCCESS'){'Green'}else{'Yellow'})
   $results.Add([pscustomobject]@{Time=(Get-Date);Driver=$u.Title;Result=$status;Detail=$detail;Reboot=$reboot})
  }
  if($reboot){Note 'Restart Windows manually before continuing.' 'Yellow';break}
 }
 $file=Join-Path $reports ('Install-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.csv')
 $results|Export-Csv $file -NoTypeInformation -Encoding UTF8
 Note ("Log: "+$file) 'Green'
}
function Backup {
 $p=Join-Path $backups (Get-Date -Format 'yyyyMMdd-HHmmss')
 New-Item -ItemType Directory -Path $p -Force|Out-Null
 & "$env:windir\System32\pnputil.exe" /export-driver '*' $p | Out-Host
 Note ("Backup: "+$p)
}
function Export-Reports {
 $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
 $inv=@(Get-CimInstance Win32_PnPSignedDriver|Select-Object DeviceName,DriverProviderName,DriverVersion,InfName,DriverDate)
 $inv|Export-Csv (Join-Path $reports "Installed-$stamp.csv") -NoTypeInformation -Encoding UTF8
 $issues=@(Audit)
 if($issues.Count){$issues|Export-Csv (Join-Path $reports "Problems-$stamp.csv") -NoTypeInformation -Encoding UTF8}
 Note ("Reports saved: "+$reports) 'Green'
}
function Auto-Update {
 [void](Audit)
 $c=Updates -Recommended
 if($c.Items.Count){Install-Updates $c $c.Items -Unattended}
}
function Menu {
 do{
  Clear-Host
  Write-Host '=========================================================' -ForegroundColor Cyan
  Write-Host '         DRIVERHUB PS | Windows Driver Manager' -ForegroundColor White
  Write-Host '=========================================================' -ForegroundColor Cyan
  Write-Host '  [1] Scan missing drivers and device problems'
  Write-Host '  [2] View installed drivers and versions'
  Write-Host '  [3] Check Windows Update driver updates'
  Write-Host '  [4] Install recommended driver updates'
  Write-Host '  [5] Select optional driver updates manually'
  Write-Host '  [6] Backup third-party drivers'
  Write-Host '  [7] Export CSV reports'
  Write-Host '  [0] EXIT'
  $choice=Read-Host 'Choose'
  try{
   switch($choice){
    '1'{[void](Audit)}
    '2'{[void](Inventory)}
    '3'{[void](Updates)}
    '4'{ $c=Updates -Recommended; if($c.Items.Count){Install-Updates $c $c.Items} }
    '5'{
     $c=Updates
     if($c.Items.Count){
      $pick=Read-Host 'Numbers separated by commas (blank cancels)'
      if($pick -match '^\s*\d+(\s*,\s*\d+)*\s*$'){
       $nums=@($pick -split ','|ForEach-Object {[int]$_.Trim()}|Sort-Object -Unique)
       if(@($nums|Where-Object {$_ -lt 1 -or $_ -gt $c.Items.Count}).Count -eq 0){
        $selected=@(foreach($n in $nums){$c.Items[$n-1]})
        Install-Updates $c $selected
       }else{Note 'Number outside update list.' 'Red'}
      }else{Note 'Cancelled or invalid selection.' 'Yellow'}
     }
    }
    '6'{Backup}
    '7'{Export-Reports}
    '0'{Note 'Exiting.' 'Green'}
    default{Note 'Invalid option.' 'Yellow'}
   }
  }catch{Note ("Error: "+$_.Exception.Message) 'Red'}
  if($choice -ne '0'){[void](Read-Host 'Press Enter to return')}
 }while($choice -ne '0')
}
$log=Join-Path $root ('Session-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt')
try{Start-Transcript -Path $log -ErrorAction Stop|Out-Null}catch{}
try{
 if($Scan){[void](Audit);[void](Updates)}
 elseif($Auto){Auto-Update}
 else{Menu}
}finally{try{Stop-Transcript|Out-Null}catch{}}
