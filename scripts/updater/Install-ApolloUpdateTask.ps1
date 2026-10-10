<#
.SYNOPSIS
    Installs ApolloUpdate.ps1 and the scheduled task "ApolloUpdate".

.DESCRIPTION
    Run this script one time in an elevated Windows PowerShell 5.1.
    You can run it again to update the script or to change the channel.

    1. Copies ApolloUpdate.ps1 to C:\ProgramData\ApolloUpdate\.
       Folder ACL: SYSTEM and Administrators full control, Users read and
       execute only. Owner: Administrators. Thus a normal user cannot change
       the script that SYSTEM runs.
    2. Registers the task \ApolloUpdate: runs as SYSTEM with highest
       privileges, daily at 04:00, start on demand is permitted, no start
       after a missed start, stops after 30 minutes.
    3. Sets the security descriptor of the task. Authenticated Users can
       read and run the task, but cannot change or delete it:
         D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)

.PARAMETER Channel
    The branch that the task follows. Default: master.

.PARAMETER SourceScript
    The ApolloUpdate.ps1 to install. Default: the file next to this script.

.PARAMETER At
    The time of the daily start. Default: 04:00.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Channel = 'master',
    [string]$SourceScript = (Join-Path $PSScriptRoot 'ApolloUpdate.ps1'),
    [string]$At = '04:00'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$TaskName   = 'ApolloUpdate'
$TaskPath   = '\'
$InstallDir = Join-Path $env:ProgramData 'ApolloUpdate'
$DestScript = Join-Path $InstallDir 'ApolloUpdate.ps1'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# SYSTEM: full access. Administrators: full access.
# Authenticated Users: GR (read) + GX (execute = run the task). No GW, so
# they cannot change, disable or delete the task.
$TaskSddl = 'D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)'

$SidSystem = 'S-1-5-18'
$SidAdmins = 'S-1-5-32-544'
$SidUsers  = 'S-1-5-32-545'

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-ScriptFolderSecurity {
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($SidAdmins)))
    $sec.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $rules = @(
        @($SidSystem, [System.Security.AccessControl.FileSystemRights]::FullControl),
        @($SidAdmins, [System.Security.AccessControl.FileSystemRights]::FullControl),
        @($SidUsers,  [System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
    )
    foreach ($r in $rules) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($r[0])
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, $r[1], $inherit, $prop, $allow)))
    }
    return $sec
}

if (-not (Test-Path -LiteralPath $SourceScript)) { throw "Cannot find $SourceScript" }
$sourceHash = Get-FileSha256 $SourceScript

# 1. Script folder.
# A normal user can make folders in C:\ProgramData. If the folder exists,
# remove it fully and make it again with the correct ACL.
if (Test-Path -LiteralPath $InstallDir) {
    $item = Get-Item -LiteralPath $InstallDir -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "$InstallDir is a reparse point (link or junction). Examine it and remove it manually."
    }
    Write-Host "Remove the old folder $InstallDir"
    $null = & icacls.exe $InstallDir /setowner "*$SidAdmins" /T /C /Q 2>&1
    $null = & icacls.exe $InstallDir /grant "*${SidAdmins}:(OI)(CI)F" /T /C /Q 2>&1
    # "rmdir /s" does not go into junctions or links.
    $null = & cmd.exe /d /c rmdir /s /q "$InstallDir" 2>&1
    if (Test-Path -LiteralPath $InstallDir) { throw "Cannot remove $InstallDir" }
}
Write-Host "Make $InstallDir"
# Make the folder with its ACL in one step, so that no other user can put
# a file in it first.
$null = [System.IO.Directory]::CreateDirectory($InstallDir, (New-ScriptFolderSecurity))
Copy-Item -LiteralPath $SourceScript -Destination $DestScript -Force
if ((Get-FileSha256 $DestScript) -ne $sourceHash) { throw "The copy of $SourceScript is not the same as the source." }

$acl = Get-Acl -LiteralPath $InstallDir
Write-Host "Folder owner: $($acl.Owner)"
Write-Host "Folder SDDL: $($acl.Sddl)"
Write-Host "Script SHA-256: $sourceHash"

# 2. Scheduled task.
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$DestScript`" -Channel $Channel"
$action = New-ScheduledTaskAction -Execute $PowerShell -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$systemName = (New-Object System.Security.Principal.SecurityIdentifier($SidSystem)).Translate([System.Security.Principal.NTAccount]).Value
$principal = New-ScheduledTaskPrincipal -UserId $systemName -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries
$settings.StartWhenAvailable = $false
$settings.AllowDemandStart = $true
$settings.Enabled = $true

$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Installs the newest signed Apollo build (channel $Channel). Script: $DestScript. Log: C:\ApolloBackup\update\ApolloUpdate.log"
$null = Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -InputObject $task -Force
Write-Host "Registered task $TaskPath$TaskName (channel $Channel, daily at $At, as $systemName)"

# 3. Task security descriptor.
$service = New-Object -ComObject Schedule.Service
$service.Connect()
$registered = $service.GetFolder($TaskPath).GetTask($TaskName)
$registered.SetSecurityDescriptor($TaskSddl, 0)
# 4 = DACL_SECURITY_INFORMATION
Write-Host "Task security descriptor: $($registered.GetSecurityDescriptor(4))"

$check = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
Write-Host "StartWhenAvailable: $($check.Settings.StartWhenAvailable)"
Write-Host "ExecutionTimeLimit: $($check.Settings.ExecutionTimeLimit)"
Write-Host "AllowDemandStart: $($check.Settings.AllowDemandStart)"
Write-Host "RunLevel: $($check.Principal.RunLevel)"
Write-Host ''
Write-Host 'Done. A normal user can start an update with:  schtasks /run /tn ApolloUpdate'
Write-Host 'Log: C:\ApolloBackup\update\ApolloUpdate.log'
