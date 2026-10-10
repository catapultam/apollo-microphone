<#
.SYNOPSIS
    Installs ApolloUpdate.ps1 and the scheduled tasks "ApolloUpdate" and
    "ApolloUpdateNow".

.DESCRIPTION
    Run this script one time in an elevated Windows PowerShell 5.1.
    Run it again to update the script or to change the channel. It keeps
    the backups, the state and the log.

    1. Makes C:\ProgramData\ApolloUpdate (owner Administrators, protected
       ACL: SYSTEM and Administrators full control, Users read and execute).
       Thus a normal user cannot change the script that SYSTEM runs.
       If the folder exists but its owner is not Administrators or SYSTEM,
       a different user made it: the script removes it fully first.
       The data subfolder gets an ACL for SYSTEM and Administrators only.
    2. Copies ApolloUpdate.ps1 into it.
    3. Registers two tasks that run as SYSTEM with highest privileges:
       \ApolloUpdate     daily at 04:00, with the stream guard.
       \ApolloUpdateNow  no trigger, for a manual start, without the
                         stream guard (-SkipStreamGuard). It tries again
                         a release that failed before
                         (-IgnoreFailedMarker).
       Both: start on demand permitted, no start after a missed start,
       stop after 60 minutes, no second instance.
    4. Sets the security descriptor of both tasks. Authenticated Users can
       read and run the tasks, but cannot change or delete them:
         D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)

.PARAMETER Channel
    The branch that the tasks follow. Default: master.

.PARAMETER SourceScript
    The ApolloUpdate.ps1 to install. Default: the file next to this script.

.PARAMETER At
    The time of the daily start. Default: 04:00.

.PARAMETER ResetState
    Delete the state file (last installed run_id). Use it when you change
    to a channel with older builds. The updater never installs a run_id
    that is lower than the run_id in the state file.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Channel = 'master',
    [string]$SourceScript = (Join-Path $PSScriptRoot 'ApolloUpdate.ps1'),
    [string]$At = '04:00',
    [switch]$ResetState
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$TaskPath   = '\'
$RootDir    = 'C:\ProgramData\ApolloUpdate'
$DataDir    = Join-Path $RootDir 'data'
$LogDir     = Join-Path $RootDir 'logs'
$DestScript = Join-Path $RootDir 'ApolloUpdate.ps1'
$StateFile  = Join-Path $DataDir 'state.json'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$TimeLimit  = New-TimeSpan -Minutes 60

# SYSTEM: full access. Administrators: full access.
# Authenticated Users: GR (read) + GX (execute = run the task). No GW, so
# they cannot change, disable or delete the task.
$TaskSddl = 'D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)'

$SidSystem = 'S-1-5-18'
$SidAdmins = 'S-1-5-32-544'
$SidUsers  = 'S-1-5-32-545'

function New-FolderSecurity {
    param([bool]$UsersRead)
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($SidAdmins)))
    $sec.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $rules = @(
        @($SidSystem, [System.Security.AccessControl.FileSystemRights]::FullControl),
        @($SidAdmins, [System.Security.AccessControl.FileSystemRights]::FullControl)
    )
    if ($UsersRead) { $rules += ,@($SidUsers, [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) }
    foreach ($r in $rules) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($r[0])
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, $r[1], $inherit, $prop, $allow)))
    }
    return $sec
}

function Test-AdminOwned {
    param([string]$Path)
    $owner = (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    return ($owner -eq $SidAdmins -or $owner -eq $SidSystem)
}

function Assert-NotReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "$Path is a reparse point (link or junction). Examine it and remove it manually."
    }
}

# Makes the folder with its ACL in one step, so that no other user can put
# a file in it first. For an existing folder that Administrators or SYSTEM
# own, it sets the ACL of the folder only (not recursive).
function Set-Folder {
    param([string]$Path, [bool]$UsersRead)
    $sec = New-FolderSecurity -UsersRead $UsersRead
    if (Test-Path -LiteralPath $Path) {
        Assert-NotReparsePoint -Path $Path
        if (-not (Test-AdminOwned -Path $Path)) { throw "The owner of $Path is not Administrators or SYSTEM." }
        Set-Acl -LiteralPath $Path -AclObject $sec
    } else {
        $null = [System.IO.Directory]::CreateDirectory($Path, $sec)
    }
}

if (-not (Test-Path -LiteralPath $SourceScript)) { throw "Cannot find $SourceScript" }
$sourceHash = (Get-FileHash -LiteralPath $SourceScript -Algorithm SHA256).Hash

# 1. Folders.
# A normal user can make folders in C:\ProgramData. If the folder exists and
# a normal user owns it, it is not ours: remove it fully.
if (Test-Path -LiteralPath $RootDir) {
    Assert-NotReparsePoint -Path $RootDir
    if (-not (Test-AdminOwned -Path $RootDir)) {
        Write-Host "$RootDir has a different owner. Remove it fully."
        $null = & icacls.exe $RootDir /setowner "*$SidAdmins" /T /C /Q 2>&1
        $null = & icacls.exe $RootDir /grant "*${SidAdmins}:(OI)(CI)F" /T /C /Q 2>&1
        # "rmdir /s" does not go into junctions or links.
        $null = & cmd.exe /d /c rmdir /s /q "$RootDir" 2>&1
        if (Test-Path -LiteralPath $RootDir) { throw "Cannot remove $RootDir" }
    }
}
Set-Folder -Path $RootDir -UsersRead $true
Set-Folder -Path $DataDir -UsersRead $false
if (-not (Test-Path -LiteralPath $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir }
Assert-NotReparsePoint -Path $LogDir

Copy-Item -LiteralPath $SourceScript -Destination $DestScript -Force
if ((Get-FileHash -LiteralPath $DestScript -Algorithm SHA256).Hash -ne $sourceHash) {
    throw "The copy of $SourceScript is not the same as the source."
}
if ($ResetState -and (Test-Path -LiteralPath $StateFile)) {
    Remove-Item -LiteralPath $StateFile -Force
    Write-Host "Removed $StateFile"
}

Write-Host "Folder SDDL $RootDir : $((Get-Acl -LiteralPath $RootDir).Sddl)"
Write-Host "Folder SDDL $DataDir : $((Get-Acl -LiteralPath $DataDir).Sddl)"
Write-Host "Script SHA-256: $sourceHash"

# 2. Scheduled tasks.
$systemName = (New-Object System.Security.Principal.SecurityIdentifier($SidSystem)).Translate([System.Security.Principal.NTAccount]).Value
$principal = New-ScheduledTaskPrincipal -UserId $systemName -LogonType ServiceAccount -RunLevel Highest

function Register-UpdateTask {
    param([string]$Name, [string]$ExtraArgs, $Trigger, [string]$Description)
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$DestScript`" -Channel $Channel $ExtraArgs".Trim()
    $action = New-ScheduledTaskAction -Execute $PowerShell -Argument $arguments
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit $TimeLimit `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    $settings.StartWhenAvailable = $false
    $settings.AllowDemandStart = $true
    $settings.Enabled = $true
    if ($Trigger) {
        $task = New-ScheduledTask -Action $action -Trigger $Trigger -Principal $principal -Settings $settings -Description $Description
    } else {
        $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings -Description $Description
    }
    $null = Register-ScheduledTask -TaskName $Name -TaskPath $TaskPath -InputObject $task -Force

    # Task security descriptor.
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $registered = $service.GetFolder($TaskPath).GetTask($Name)
    $registered.SetSecurityDescriptor($TaskSddl, 0)

    $check = Get-ScheduledTask -TaskName $Name -TaskPath $TaskPath
    Write-Host "Registered task $TaskPath$Name as $systemName"
    Write-Host "  Arguments: $arguments"
    # 4 = DACL_SECURITY_INFORMATION
    Write-Host "  Security descriptor: $($registered.GetSecurityDescriptor(4))"
    Write-Host "  StartWhenAvailable: $($check.Settings.StartWhenAvailable); ExecutionTimeLimit: $($check.Settings.ExecutionTimeLimit); AllowDemandStart: $($check.Settings.AllowDemandStart); RunLevel: $($check.Principal.RunLevel)"
}

$logPath = Join-Path $LogDir 'ApolloUpdate.log'
Register-UpdateTask -Name 'ApolloUpdate' -ExtraArgs '' -Trigger (New-ScheduledTaskTrigger -Daily -At $At) `
    -Description "Nightly: installs the newest signed Apollo build (channel $Channel) if no stream is active. Log: $logPath"
Register-UpdateTask -Name 'ApolloUpdateNow' -ExtraArgs '-SkipStreamGuard -IgnoreFailedMarker' -Trigger $null `
    -Description "On demand: installs the newest signed Apollo build (channel $Channel) now. An active stream stops. Log: $logPath"

Write-Host ''
Write-Host 'Done. A normal user can start an update now with:  schtasks /run /tn ApolloUpdateNow'
Write-Host "Log: $logPath"
