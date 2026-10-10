<#
.SYNOPSIS
    Installs the newest signed Apollo build from GitHub releases.

.DESCRIPTION
    This script runs as SYSTEM from the scheduled tasks "ApolloUpdate"
    (nightly, with the stream guard) and "ApolloUpdateNow" (on demand,
    without the stream guard, and it tries again a release that failed
    before). Install-ApolloUpdateTask.ps1 installs it.

    It reads the signed manifest of the newest releases of
    catapultam/apollo-microphone, verifies each RSA signature with the public
    key in this file, and uses the release with the highest signed run_id
    for the channel. It refuses a run_id that is lower than the last
    installed run_id. It verifies the SHA-256 of Apollo.exe from the signed
    manifest, makes a backup, runs the installer silently and checks the
    result. If the check fails, it restores the backup.

    The signature check is the only thing that stops a malicious release
    from being installed as SYSTEM. Do not remove it.

    All files of the updater are in C:\ProgramData\ApolloUpdate:
      ApolloUpdate.ps1    this script (Users: read and execute)
      logs\               ApolloUpdate.log (Users: read)
      data\               downloads, backups, state, lock (SYSTEM and
                          Administrators only)

    Exit codes:
       0  The new build is installed.
      10  Skipped: no newer release (up to date).
      11  Skipped: a stream is possibly active (nightly guard).
      12  Skipped: this release failed before (use -Force or
          -IgnoreFailedMarker).
       1  Error before a change to the installation.
       2  Installation failed. The backup was restored.
       3  Installation failed and the restore also failed.
       4  A different ApolloUpdate run is active.
       5  No release with a valid signed manifest for the channel.
       6  Apollo.exe does not agree with the signed manifest.
       7  Not sufficient time in the task time limit to install safely.

    Compatible with Windows PowerShell 5.1. Use only ASCII in this file.

.PARAMETER Channel
    The branch name to follow. The signed manifest must have the line
    "channel: <Channel>".

.PARAMETER Force
    Install again the release with the last installed run_id, and install
    also a release that failed before. Never installs a lower run_id.

.PARAMETER CheckOnly
    Find and verify the release and do the checks, but do not stop,
    change or install Apollo. It downloads the small manifest files.

.PARAMETER SkipStreamGuard
    Do not look for an active Moonlight stream. The on-demand task uses
    this: a manual start means that the user accepts that the stream stops.

.PARAMETER IgnoreFailedMarker
    Try again a release that failed before (data\failed\<tag>). The
    on-demand task uses this, so that a user can try again after a
    temporary failure. The nightly task does not use it. It does not
    change the run_id checks.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Channel = 'master',
    [switch]$Force,
    [switch]$CheckOnly,
    [switch]$SkipStreamGuard,
    [switch]$IgnoreFailedMarker
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
$Repo            = 'catapultam/apollo-microphone'
$InstallDir      = 'C:\Program Files\Apollo'
$ConfigDir       = Join-Path $InstallDir 'config'
$SunshineExe     = Join-Path $InstallDir 'sunshine.exe'
$SunshineLog     = Join-Path $ConfigDir 'sunshine.log'
$SunshineConf    = Join-Path $ConfigDir 'sunshine.conf'
$ServiceName     = 'ApolloService'
$DefaultBasePort = 47989

$RootDir         = 'C:\ProgramData\ApolloUpdate'
$LogDir          = Join-Path $RootDir 'logs'
$LogFile         = Join-Path $LogDir 'ApolloUpdate.log'
$DataDir         = Join-Path $RootDir 'data'
$DownloadRoot    = Join-Path $DataDir 'downloads'
$BackupDir       = Join-Path $DataDir 'backups'
$FailedDir       = Join-Path $DataDir 'failed'
$StateFile       = Join-Path $DataDir 'state.json'
$LockFile        = Join-Path $DataDir 'update.lock'

$LogMaxBytes           = 5MB
$KeepBackups           = 3
$MaxCandidates         = 10
$InstallerTimeoutSec   = 600
$ServiceWaitSec        = 90
$StableSec             = 30
$TaskLimitMin          = 60
$MinRemainingMin       = 15
$StreamLogWindowSec    = 60
$StreamIoBytesPerSec   = 100KB
$StreamIoSamples       = 3
$AssetExe        = 'Apollo.exe'
$AssetManifest   = 'apollo-update-manifest.txt'
$AssetSignature  = 'apollo-update-manifest.txt.sig'
$AssetNames      = @($AssetExe, $AssetManifest, $AssetSignature)
$ManifestFormat  = 'apollo-update-manifest-1'
$UserAgent       = 'ApolloUpdate/2 (+https://github.com/catapultam/apollo-microphone)'

# Public key for the manifest signature: RSA 3072, exponent 65537.
# The private key is only in the secret APOLLO_UPDATE_SIGNING_KEY of the
# GitHub environment "release". The same key is in
# scripts/updater/apollo-update-signing.pub.pem. See README.md to change it.
$PublicKeyModulusBase64 = @(
    'v6LSm+UqWrsEpWpF0GUTcBPOHAdcAqJL7R626Yk9AYyiOo5jnJKtRLMUE1e6wUc+mJ+CAVLMOReUlNGXG/6m'
    'cWx7Sqz5VZ4AJXNdu8mpI4xsjsx98vivGkR44z5bvaRNZN72fiqJdBb5dQv2D7VwFhuwz08nkMW14mHzRWc2'
    'v1HvFMmOQ+q0J8Hz9QDklyG1rxlbh1LjR8Qac9ExcbboCyUycsu+sCMo2suRI9FtpKGEzIzUVmMmi/Xhn5GD'
    'yJgTflw8IKPcrdXkHioLhh0piJxomRtS+zVZZNOC79ihd3bKyuoJ7/ekzGCaiT2COoAwMXXlzekko+enSIcb'
    '/jBRqSVkklstYtiepbsGLpfRyB4TBr5IcrpD4ZqK/OEOGZLMQDrXUKZj1GItcvHlmDBAkGH9GQBvhwVroSiE'
    '/TuldO96qsUKfYEuaKWd0FBJvruqpRiKzdTMfKii9RRA8E4pSalAFsN7lYhI+NFOsZfY3ZwwskH4hvfaXUtK'
    '85LvxXjr'
) -join ''
$PublicKeyExponentBase64 = 'AQAB'

$SidSystem = 'S-1-5-18'
$SidAdmins = 'S-1-5-32-544'

$script:StartTime = Get-Date
$script:LogReady = $false
$script:LockStream = $null

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogReady) {
        try {
            [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8)
        } catch {
            Write-Host ('Cannot write the log file: ' + $_.Exception.Message)
        }
    }
}

function Initialize-Log {
    try {
        if (Test-Path -LiteralPath $LogFile) {
            $size = (Get-Item -LiteralPath $LogFile -Force).Length
            if ($size -ge $LogMaxBytes) {
                $old = $LogFile + '.1'
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
                Move-Item -LiteralPath $LogFile -Destination $old -Force
            }
        }
    } catch {
        Write-Host ('Cannot rotate the log file: ' + $_.Exception.Message)
    }
    $script:LogReady = $true
}

# ---------------------------------------------------------------------------
# Folders
# ---------------------------------------------------------------------------
function Test-AdminOwned {
    param([string]$Path)
    $owner = (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    return ($owner -eq $SidAdmins -or $owner -eq $SidSystem)
}

function Assert-SafeFolder {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { throw "$Path is not a folder." }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "$Path is a reparse point (link or junction)."
    }
    if (-not (Test-AdminOwned -Path $Path)) {
        throw "The owner of $Path is not Administrators or SYSTEM. Run Install-ApolloUpdateTask.ps1 again."
    }
}

function New-AdminOnlySecurity {
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($sid in @($SidSystem, $SidAdmins)) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, $full, $inherit, $prop, $allow)))
    }
    return $sec
}

# Makes a folder in the updater folder. A new data folder gets an
# admin-only ACL in the same step. An existing folder is only examined.
# This script does not change the ACL of an existing tree.
function Initialize-Folder {
    param([string]$Path, [bool]$AdminOnly)
    if (Test-Path -LiteralPath $Path) {
        Assert-SafeFolder -Path $Path
    } elseif ($AdminOnly) {
        $null = [System.IO.Directory]::CreateDirectory($Path, (New-AdminOnlySecurity))
    } else {
        $null = [System.IO.Directory]::CreateDirectory($Path)
    }
}

# Removes a folder tree. "rmdir /s" does not go into junctions or links,
# but Remove-Item -Recurse in Windows PowerShell 5.1 can.
function Remove-DirectoryTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $out = & cmd.exe /d /c rmdir /s /q "$Path" 2>&1
    if (Test-Path -LiteralPath $Path) { throw "Cannot remove ${Path}: $out" }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
function Read-State {
    $state = New-Object PSObject -Property @{ RunId = [int64]0; Commit = ''; Tag = ''; Channel = ''; InstalledAt = '' }
    if (Test-Path -LiteralPath $StateFile) {
        $j = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        $state.RunId = [int64]$j.RunId
        $state.Commit = [string]$j.Commit
        $state.Tag = [string]$j.Tag
        $state.Channel = [string]$j.Channel
        $state.InstalledAt = [string]$j.InstalledAt
    }
    return $state
}

function Write-State {
    param($Manifest, [string]$Tag)
    $obj = [ordered]@{
        RunId = $Manifest.RunId; Commit = $Manifest.Commit; Tag = $Tag
        Channel = $Manifest.Channel; InstalledAt = (Get-Date -Format 's')
    }
    $tmp = $StateFile + '.tmp'
    [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json), [System.Text.Encoding]::ASCII)
    Move-Item -LiteralPath $tmp -Destination $StateFile -Force
    Write-Log "State: last installed run_id $($Manifest.RunId), commit $($Manifest.Commit), tag $Tag"
}

# ---------------------------------------------------------------------------
# GitHub and manifest
# ---------------------------------------------------------------------------
function Invoke-GitHubApi {
    param([string]$Uri)
    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = 'application/vnd.github+json' }
    return Invoke-RestMethod -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 60
}

function Get-Asset {
    param([string]$Url, [string]$Path)
    if (-not $Url.StartsWith("https://github.com/$Repo/releases/download/")) {
        throw "Unexpected asset URL: $Url"
    }
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 600 -Headers @{ 'User-Agent' = $UserAgent }
}

# Returns the newest releases that are possibly for the channel. The release
# body is not signed. It only makes the list shorter. The signed manifest
# decides.
function Get-CandidateReleases {
    param([string]$Branch)
    $found = @()
    for ($page = 1; $page -le 3; $page++) {
        $uri = "https://api.github.com/repos/$Repo/releases?per_page=100&page=$page"
        # Windows PowerShell 5.1 can give the JSON array as one object.
        # ForEach-Object makes it a flat list in all versions.
        $releases = @(Invoke-GitHubApi -Uri $uri | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
        if ($releases.Count -eq 0) { break }
        foreach ($r in $releases) {
            if ($r.draft) { continue }
            $tag = [string]$r.tag_name
            if ($tag -cnotmatch '^build-[0-9]+-[0-9a-f]{7}(-a[0-9]+)?$') { continue }
            $b = [regex]::Match([string]$r.body, '(?m)^branch:[ \t]*(\S+)[ \t]*\r?$')
            if (-not $b.Success -or ($b.Groups[1].Value -cne $Branch)) { continue }
            $urls = @{}
            foreach ($a in @($r.assets)) {
                if ($AssetNames -ccontains [string]$a.name) { $urls[[string]$a.name] = [string]$a.browser_download_url }
            }
            if ($urls.Count -ne $AssetNames.Count) { continue }
            $date = $r.published_at
            if (-not $date) { $date = $r.created_at }
            $found += New-Object PSObject -Property @{ Tag = $tag; Published = [datetime]$date; Urls = $urls }
        }
        if ($releases.Count -lt 100) { break }
    }
    return @($found | Sort-Object -Property Published -Descending | Select-Object -First $MaxCandidates)
}

function Test-ManifestSignature {
    param([byte[]]$Data, [byte[]]$Signature)
    try {
        $p = New-Object System.Security.Cryptography.RSAParameters
        $p.Modulus = [Convert]::FromBase64String($PublicKeyModulusBase64)
        $p.Exponent = [Convert]::FromBase64String($PublicKeyExponentBase64)
        if ($p.Modulus.Length -ne 384) { throw 'The embedded public key is not RSA 3072.' }
        if ($Signature.Length -ne 384) { throw "The signature has $($Signature.Length) bytes, not 384." }
        # On .NET Framework, use RSACng: RSACryptoServiceProvider can refuse
        # SHA-256 with some CSP types.
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $rsa = New-Object System.Security.Cryptography.RSACng
        } else {
            $rsa = [System.Security.Cryptography.RSA]::Create()
        }
        try {
            $rsa.ImportParameters($p)
            return [bool]$rsa.VerifyData($Data, $Signature,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        } finally {
            $rsa.Dispose()
        }
    } catch {
        Write-Log ('Signature check error: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

# Parses the verified manifest bytes. Returns $null and logs the reason if
# the manifest is not correct for this repository and channel.
function ConvertFrom-Manifest {
    param([byte[]]$Bytes, [string]$Tag)
    $fields = @{}
    foreach ($line in ([System.Text.Encoding]::ASCII.GetString($Bytes) -split "`n")) {
        $line = $line.TrimEnd("`r")
        if ($line -eq '') { continue }
        $m = [regex]::Match($line, '^([a-z0-9_]+): (.*)$')
        if (-not $m.Success) { Write-Log "${Tag}: bad manifest line: $line" 'WARN'; return $null }
        if ($fields.ContainsKey($m.Groups[1].Value)) { Write-Log "${Tag}: duplicate manifest key $($m.Groups[1].Value)" 'WARN'; return $null }
        $fields[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    $checks = @(
        @('format', "^$([regex]::Escape($ManifestFormat))$"),
        @('repository', "^$([regex]::Escape($Repo))$"),
        @('channel', '^[A-Za-z0-9._/-]+$'),
        @('commit', '^[0-9a-f]{40}$'),
        @('run_id', '^[0-9]{1,18}$'),
        @('apollo_exe_sha256', '^[0-9a-f]{64}$')
    )
    foreach ($c in $checks) {
        if (-not $fields.ContainsKey($c[0]) -or ($fields[$c[0]] -cnotmatch $c[1])) {
            Write-Log "${Tag}: manifest field $($c[0]) is missing or not correct" 'WARN'
            return $null
        }
    }
    if ($fields['channel'] -cne $Channel) {
        Write-Log "${Tag}: signed channel is $($fields['channel']), not $Channel. Refuse it." 'WARN'
        return $null
    }
    $tagSha = [regex]::Match($Tag, '^build-[0-9]+-([0-9a-f]{7})').Groups[1].Value
    if (-not $fields['commit'].StartsWith($tagSha)) {
        Write-Log "${Tag}: signed commit $($fields['commit']) does not agree with the tag. Refuse it." 'WARN'
        return $null
    }
    return New-Object PSObject -Property @{
        Tag = $Tag; Channel = $fields['channel']; Commit = $fields['commit']
        RunId = [int64]::Parse($fields['run_id']); ExeSha256 = $fields['apollo_exe_sha256']
    }
}

# Downloads, verifies and parses the manifest of a release.
function Get-VerifiedManifest {
    param($Release)
    $dir = Join-Path (Join-Path $DownloadRoot '_manifests') $Release.Tag
    Remove-DirectoryTree -Path $dir
    $null = New-Item -ItemType Directory -Path $dir -Force
    $mPath = Join-Path $dir $AssetManifest
    $sPath = Join-Path $dir $AssetSignature
    Get-Asset -Url $Release.Urls[$AssetManifest] -Path $mPath
    Get-Asset -Url $Release.Urls[$AssetSignature] -Path $sPath
    $bytes = [System.IO.File]::ReadAllBytes($mPath)
    if ($bytes.Length -gt 4096) { Write-Log "$($Release.Tag): manifest is too large" 'WARN'; return $null }
    if (-not (Test-ManifestSignature -Data $bytes -Signature ([System.IO.File]::ReadAllBytes($sPath)))) {
        Write-Log "$($Release.Tag): the manifest signature is NOT valid. Refuse it." 'ERROR'
        return $null
    }
    $m = ConvertFrom-Manifest -Bytes $bytes -Tag $Release.Tag
    if ($m) {
        $m | Add-Member -NotePropertyName Urls -NotePropertyValue $Release.Urls
        $m | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $mPath
    }
    return $m
}

function Get-StreamSha256 {
    param([System.IO.Stream]$Stream)
    $Stream.Position = 0
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Stream) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Installed build
# ---------------------------------------------------------------------------
# The CI build has a ProductVersion like 0.0.0.977136a.dirty. Returns the
# short sha, or $null if there is no sha.
function Get-InstalledSha {
    if (-not (Test-Path -LiteralPath $SunshineExe)) { return $null }
    $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($SunshineExe).ProductVersion
    $m = [regex]::Match([string]$v, '\.([0-9a-f]{7,40})(\.dirty)?$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-InstalledVersion {
    if (-not (Test-Path -LiteralPath $SunshineExe)) { return '(not installed)' }
    return [string][System.Diagnostics.FileVersionInfo]::GetVersionInfo($SunshineExe).ProductVersion
}

function Test-ShaMatch {
    param([string]$ShortSha, [string]$FullSha)
    if (-not $ShortSha -or $ShortSha.Length -lt 7) { return $false }
    return $FullSha.StartsWith($ShortSha)
}

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------
function Get-BasePort {
    if (Test-Path -LiteralPath $SunshineConf) {
        foreach ($line in [System.IO.File]::ReadAllLines($SunshineConf)) {
            $m = [regex]::Match($line, '^\s*port\s*=\s*([0-9]+)\s*$')
            if ($m.Success) { return [int]$m.Groups[1].Value }
        }
    }
    return $DefaultBasePort
}

function Get-SunshineProcesses {
    return @(Get-CimInstance -ClassName Win32_Process -Filter "Name='sunshine.exe'" |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $SunshineExe) })
}

# Returns the ports of $Ports that a sunshine.exe process listens on.
function Get-SunshineListenPorts {
    param([int[]]$Ports)
    $pids = @(Get-SunshineProcesses | ForEach-Object { [int]$_.ProcessId })
    $result = @()
    foreach ($port in $Ports) {
        $owners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
            ForEach-Object { [int]$_.OwningProcess })
        foreach ($o in $owners) {
            if ($pids -contains $o) { $result += $port; break }
        }
    }
    return $result
}

# The state before the update. The check after the update requires the
# same: if sunshine.exe ran and listened on a port before, it must do this
# after the update too.
function Get-HealthBaseline {
    $base = Get-BasePort
    $ports = @($base, ($base + 1))
    $procs = @(Get-SunshineProcesses)
    $listen = @()
    if ($procs.Count -gt 0) { $listen = @(Get-SunshineListenPorts -Ports $ports) }
    $b = New-Object PSObject -Property @{ SunshineRan = ($procs.Count -gt 0); Ports = $listen }
    Write-Log ("Health before the update: sunshine.exe running: {0}; listen ports: {1}" -f $b.SunshineRan, (($listen | ForEach-Object { $_ }) -join ', '))
    return $b
}

function Test-UninstallerRunning {
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process)) {
        $name = [string]$p.Name
        if ($name -in @('Au_.exe', 'Un_A.exe', 'Un.exe')) { return $true }
        $path = [string]$p.ExecutablePath
        if ($path -and $path.StartsWith($InstallDir + '\', [System.StringComparison]::OrdinalIgnoreCase) -and $name -like 'Uninstall*') { return $true }
    }
    return $false
}

# Waits until the installation is healthy, then makes sure that it stays
# healthy for $StableSec. $FullSha can be $null (no version check).
function Wait-Healthy {
    param([string]$FullSha, $Baseline)
    $deadline = (Get-Date).AddSeconds($ServiceWaitSec)
    $pidSeen = $null
    $reason = ''
    while ($true) {
        $reason = ''
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (Test-UninstallerRunning) { $reason = 'the old uninstaller still runs' }
        elseif (-not $svc) { $reason = "$ServiceName does not exist" }
        elseif ($svc.Status -ne 'Running') { $reason = "$ServiceName is $($svc.Status)" }
        elseif ($FullSha -and -not (Test-ShaMatch -ShortSha (Get-InstalledSha) -FullSha $FullSha)) { $reason = "sunshine.exe has version $(Get-InstalledVersion)" }
        elseif ($Baseline.SunshineRan) {
            $procs = @(Get-SunshineProcesses)
            if ($procs.Count -eq 0) { $reason = 'sunshine.exe does not run' }
            else {
                $listen = @(Get-SunshineListenPorts -Ports $Baseline.Ports)
                if ($listen.Count -ne @($Baseline.Ports).Count) { $reason = 'sunshine.exe does not listen on all ports: ' + (@($Baseline.Ports) -join ', ') }
                else { $pidSeen = [int]$procs[0].ProcessId }
            }
        }
        if (-not $reason) { break }
        if ((Get-Date) -gt $deadline) {
            Write-Log "Not healthy after $ServiceWaitSec s: $reason" 'ERROR'
            return $false
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "Healthy. Version $(Get-InstalledVersion). Make sure that it stays healthy for $StableSec s."
    $end = (Get-Date).AddSeconds($StableSec)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') { Write-Log "$ServiceName stopped during the stable time" 'ERROR'; return $false }
        if ($pidSeen) {
            if (-not (Get-Process -Id $pidSeen -ErrorAction SilentlyContinue)) {
                Write-Log "sunshine.exe (process $pidSeen) stopped during the stable time" 'ERROR'
                return $false
            }
        }
    }
    if ($Baseline.SunshineRan) {
        $listen = @(Get-SunshineListenPorts -Ports $Baseline.Ports)
        if ($listen.Count -ne @($Baseline.Ports).Count) { Write-Log 'sunshine.exe stopped to listen during the stable time' 'ERROR'; return $false }
    } else {
        Write-Log 'sunshine.exe did not run before the update, so the process and port checks are not done.' 'WARN'
    }
    Write-Log 'Stable.'
    return $true
}

# ---------------------------------------------------------------------------
# Stream guard (nightly task only)
# ---------------------------------------------------------------------------
function Get-OpenFileLength {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    $share = [System.IO.FileShare]'ReadWrite, Delete'
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    } catch {
        return -1
    }
    try { return $fs.Length } finally { $fs.Dispose() }
}

function Get-SunshineIoBytes {
    $total = [double]0
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='sunshine.exe'")) {
        $total += [double]$p.ReadTransferCount + [double]$p.WriteTransferCount + [double]$p.OtherTransferCount
    }
    return $total
}

# Returns a text that tells why a stream is possibly active, or $null.
# A stream is possibly active if one of these rules is true:
# 1. sunshine.log was written in the last 60 s (last write time), or its
#    length changed during the I/O samples.
# 2. The mean I/O rate of all sunshine.exe processes (read + write + other
#    transfer bytes of Win32_Process) over 3 samples of 1 s is more than
#    100 KB/s. It is not known if all socket traffic is in these counters.
function Get-StreamActivity {
    $lenBefore = Get-OpenFileLength -Path $SunshineLog
    if ($lenBefore -ge 0) {
        $age = ([datetime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($SunshineLog)).TotalSeconds
        if ($age -lt $StreamLogWindowSec) {
            return ('sunshine.log was written {0:N0} s ago' -f $age)
        }
    }
    $rates = @()
    $prev = Get-SunshineIoBytes
    $prevTime = [datetime]::UtcNow
    for ($i = 0; $i -lt $StreamIoSamples; $i++) {
        Start-Sleep -Seconds 1
        $now = Get-SunshineIoBytes
        $nowTime = [datetime]::UtcNow
        $delta = $now - $prev
        if ($delta -lt 0) { $delta = 0 }
        $rates += ($delta / ($nowTime - $prevTime).TotalSeconds)
        $prev = $now
        $prevTime = $nowTime
    }
    $mean = ($rates | Measure-Object -Average).Average
    Write-Log ('sunshine.exe I/O samples (bytes/s): {0}; mean {1:N0}' -f (($rates | ForEach-Object { '{0:N0}' -f $_ }) -join ', '), $mean)
    if ($mean -gt $StreamIoBytesPerSec) {
        return ('sunshine.exe I/O mean is {0:N0} bytes/s' -f $mean)
    }
    $lenAfter = Get-OpenFileLength -Path $SunshineLog
    if ($lenBefore -ge 0 -and $lenAfter -ne $lenBefore) {
        return ('sunshine.log grew from {0} to {1} bytes during the samples' -f $lenBefore, $lenAfter)
    }
    return $null
}

# ---------------------------------------------------------------------------
# Service control
# ---------------------------------------------------------------------------
function Stop-Apollo {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Log "Stop $ServiceName"
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 60))
    }
    $deadline = (Get-Date).AddSeconds(20)
    while ($true) {
        $procs = @(Get-Process -Name sunshine -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) { throw 'sunshine.exe does not stop.' }
        foreach ($p in $procs) {
            Write-Log "Stop sunshine.exe process $($p.Id)"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
}

function Start-Apollo {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { throw "Service $ServiceName does not exist." }
    if ($svc.Status -ne 'Running') {
        Write-Log "Start $ServiceName"
        Start-Service -Name $ServiceName
    }
}

# Runs a .bat file from the Apollo scripts folder and waits (maximum 120 s).
function Invoke-ApolloScript {
    param([string]$Name)
    $path = Join-Path (Join-Path $InstallDir 'scripts') $Name
    if (-not (Test-Path -LiteralPath $path)) { Write-Log "Cannot find $path" 'WARN'; return }
    Write-Log "Run $path"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /c "' + $path + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        if (-not $proc.WaitForExit(120000)) {
            Write-Log "$Name did not stop in 120 s. Stop it." 'ERROR'
            $null = & taskkill.exe /PID $proc.Id /T /F 2>&1
        } else {
            Write-Log "$Name exit code: $($proc.ExitCode)"
        }
    } finally {
        $proc.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Backup and restore
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-Backup {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $zipPath = Join-Path $BackupDir "auto-$ts.zip"
    $cfgPath = Join-Path $BackupDir "auto-config-$ts"
    $aclPath = Join-Path $BackupDir "auto-config-$ts.acl"
    Write-Log "Back up $InstallDir (without *.log) to $zipPath"
    $root = $InstallDir.TrimEnd('\') + '\'
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    $count = 0
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $InstallDir -Recurse -File -Force)) {
            if ($f.Extension -eq '.log') { continue }
            $rel = $f.FullName.Substring($root.Length).Replace('\', '/')
            $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $count++
        }
    } finally {
        $zip.Dispose()
    }
    Write-Log "Backup zip has $count files"
    Write-Log "Copy $ConfigDir (with credentials, without *.log) to $cfgPath"
    $null = New-Item -ItemType Directory -Path $cfgPath -Force
    $cfgRoot = $ConfigDir.TrimEnd('\') + '\'
    foreach ($f in @(Get-ChildItem -LiteralPath $ConfigDir -Recurse -File -Force)) {
        if ($f.Extension -eq '.log') { continue }
        $dest = Join-Path $cfgPath $f.FullName.Substring($cfgRoot.Length)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }
    # Save the ACLs of the config folder (credentials) to restore them.
    $out = & icacls.exe $ConfigDir /save $aclPath /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls /save failed: $out" }
    Remove-OldBackups
    return New-Object PSObject -Property @{ Zip = $zipPath; Config = $cfgPath; Acl = $aclPath }
}

function Remove-OldBackups {
    $zips = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'auto-*.zip' -File -Force | Sort-Object Name -Descending)
    foreach ($z in ($zips | Select-Object -Skip $KeepBackups)) {
        Write-Log "Remove old backup $($z.FullName)"
        Remove-Item -LiteralPath $z.FullName -Force
    }
    $acls = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'auto-config-*.acl' -File -Force | Sort-Object Name -Descending)
    foreach ($a in ($acls | Select-Object -Skip $KeepBackups)) {
        Remove-Item -LiteralPath $a.FullName -Force
    }
    $dirs = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'auto-config-*' -Directory -Force | Sort-Object Name -Descending)
    foreach ($d in ($dirs | Select-Object -Skip $KeepBackups)) {
        Write-Log "Remove old backup $($d.FullName)"
        Remove-DirectoryTree -Path $d.FullName
    }
}

function Restore-Backup {
    param($Backup, $Baseline)
    Write-Log "Restore the backup $($Backup.Zip) and $($Backup.Config)" 'WARN'
    $deadline = (Get-Date).AddSeconds(120)
    while ((Test-UninstallerRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    Stop-Apollo
    $root = [System.IO.Path]::GetFullPath($InstallDir.TrimEnd('\') + '\')
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Backup.Zip)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }
            $dest = [System.IO.Path]::GetFullPath((Join-Path $root $e.FullName.Replace('/', '\')))
            if (-not $dest.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Zip entry is outside the install folder: $($e.FullName)"
            }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
            # ExtractToFile cannot replace a hidden or read-only file (access
            # denied). Apollo has hidden files in config\credentials. Remove
            # the attributes, extract, then set them again.
            $attr = $null
            if ([System.IO.File]::Exists($dest)) {
                $attr = [System.IO.File]::GetAttributes($dest)
                [System.IO.File]::SetAttributes($dest, [System.IO.FileAttributes]::Normal)
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
            if ($null -ne $attr) { [System.IO.File]::SetAttributes($dest, $attr) }
        }
    } finally {
        $zip.Dispose()
    }
    $null = New-Item -ItemType Directory -Path $ConfigDir -Force
    Copy-Item -Path (Join-Path $Backup.Config '*') -Destination $ConfigDir -Recurse -Force
    # Put back the ACLs of the config folder (credentials).
    $out = & icacls.exe $InstallDir /restore $Backup.Acl /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log "icacls /restore failed: $out" 'ERROR' }
    # The old uninstaller removes the service and the firewall rules. Make
    # them again with the restored scripts.
    Invoke-ApolloScript -Name 'delete-firewall-rule.bat'
    Invoke-ApolloScript -Name 'add-firewall-rule.bat'
    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        Write-Log "$ServiceName does not exist. Install it again." 'WARN'
        Invoke-ApolloScript -Name 'install-service.bat'
        Invoke-ApolloScript -Name 'autostart-service.bat'
    }
    Start-Apollo
    if (-not (Wait-Healthy -FullSha $null -Baseline $Baseline)) {
        throw "The restored installation is not healthy. Version $(Get-InstalledVersion)."
    }
    Write-Log "Restore complete. sunshine.exe has version $(Get-InstalledVersion)" 'WARN'
}

# ---------------------------------------------------------------------------
# Installer
# ---------------------------------------------------------------------------
function Invoke-Installer {
    param([string]$Path)
    Write-Log "Run $Path /S (maximum $InstallerTimeoutSec s)"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.Arguments = '/S'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        if (-not $proc.WaitForExit($InstallerTimeoutSec * 1000)) {
            Write-Log "The installer did not stop in $InstallerTimeoutSec s. Stop it and its child processes." 'ERROR'
            $out = & taskkill.exe /PID $proc.Id /T /F 2>&1
            Write-Log "taskkill: $out"
            return $false
        }
        Write-Log "Installer exit code: $($proc.ExitCode)"
        return ($proc.ExitCode -eq 0)
    } finally {
        $proc.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Update {
    $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Log "ApolloUpdate start. User: $who. Channel: $Channel. Force: $Force. CheckOnly: $CheckOnly. SkipStreamGuard: $SkipStreamGuard. IgnoreFailedMarker: $IgnoreFailedMarker."

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    # 1. Find the release with the highest signed run_id for the channel.
    $candidates = @(Get-CandidateReleases -Branch $Channel)
    Write-Log "Candidate releases: $(($candidates | ForEach-Object { $_.Tag }) -join ', ')"
    $best = $null
    foreach ($c in $candidates) {
        try {
            $m = Get-VerifiedManifest -Release $c
        } catch {
            Write-Log "$($c.Tag): cannot get the manifest: $($_.Exception.Message)" 'WARN'
            continue
        }
        if (-not $m) { continue }
        Write-Log "$($m.Tag): valid signature, channel $($m.Channel), run_id $($m.RunId), commit $($m.Commit)"
        if (-not $best -or $m.RunId -gt $best.RunId) { $best = $m }
    }
    if (-not $best) {
        Write-Log "No release with a valid signed manifest for channel $Channel." 'ERROR'
        return 5
    }
    Write-Log "Selected release $($best.Tag): run_id $($best.RunId), commit $($best.Commit)"

    # 2. Compare with the installed build and the state.
    $state = Read-State
    $installedSha = Get-InstalledSha
    $installedMatch = Test-ShaMatch -ShortSha $installedSha -FullSha $best.Commit
    Write-Log "Installed sunshine.exe version: $(Get-InstalledVersion). Last installed run_id: $($state.RunId)."
    if ($best.RunId -lt $state.RunId) {
        Write-Log "The newest valid release has run_id $($best.RunId), lower than the last installed run_id $($state.RunId). Refuse a downgrade." 'WARN'
        return 10
    }
    if ($best.RunId -eq $state.RunId -and -not $Force) {
        if ($installedMatch) {
            Write-Log 'Up to date.'
        } else {
            Write-Log 'This release was installed before, but the installed build is different (manual rollback?). Do not install it again. Use -Force to install it.' 'WARN'
        }
        return 10
    }
    if ($installedMatch -and -not $Force) {
        Write-Log 'The installed build has the release commit. Up to date.'
        if (-not $CheckOnly) { Write-State -Manifest $best -Tag $best.Tag }
        return 10
    }

    $failedMarker = Join-Path $FailedDir $best.Tag
    if (Test-Path -LiteralPath $failedMarker) {
        if ($Force -or $IgnoreFailedMarker) {
            Write-Log "Release $($best.Tag) failed before ($failedMarker). Try it again."
        } else {
            Write-Log "Release $($best.Tag) failed before ($failedMarker). Skip it. Use -Force or -IgnoreFailedMarker to try again." 'WARN'
            return 12
        }
    }

    if (-not $SkipStreamGuard) {
        $active = Get-StreamActivity
        if ($active) { Write-Log "A stream is possibly active ($active). Skip the update."; return 11 }
        Write-Log 'No active stream found.'
    }

    if ($CheckOnly) {
        Write-Log "CheckOnly: an update to $($best.Tag) is available. No change made."
        return 0
    }

    # 3. Download and verify before anything stops.
    $tagDir = Join-Path $DownloadRoot $best.Tag
    Remove-DirectoryTree -Path $tagDir
    $null = New-Item -ItemType Directory -Path $tagDir -Force
    Copy-Item -LiteralPath $best.ManifestPath -Destination (Join-Path $tagDir $AssetManifest) -Force
    $exePath = Join-Path $tagDir $AssetExe
    Write-Log "Download $AssetExe"
    Get-Asset -Url $best.Urls[$AssetExe] -Path $exePath

    # Keep Apollo.exe open without write or delete share from the hash check
    # until the installer stops. Thus nobody can replace it between the check
    # and the start.
    $exeLock = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $backup = $null
    $baseline = $null
    try {
        $actual = Get-StreamSha256 -Stream $exeLock
        if ($actual -ne $best.ExeSha256) {
            Write-Log "Apollo.exe SHA-256 is $actual, but the signed manifest has $($best.ExeSha256). Stop. Nothing was installed." 'ERROR'
            return 6
        }
        Write-Log "Apollo.exe SHA-256 agrees with the signed manifest: $actual"

        if (-not $SkipStreamGuard) {
            $active = Get-StreamActivity
            if ($active) { Write-Log "A stream is possibly active ($active). Skip the update."; return 11 }
        }

        $elapsedMin = ((Get-Date) - $script:StartTime).TotalMinutes
        if ($elapsedMin -gt ($TaskLimitMin - $MinRemainingMin)) {
            Write-Log ("{0:N1} min of the {1} min task limit are used. Less than {2} min stay. Do not start the installation." -f $elapsedMin, $TaskLimitMin, $MinRemainingMin) 'ERROR'
            return 7
        }

        # 4. Stop, back up, install.
        $baseline = Get-HealthBaseline
        try {
            Stop-Apollo
            $backup = New-Backup
        } catch {
            Write-Log ('Stop or backup failed: ' + $_.Exception.Message + '. Start the service again. Nothing was installed.') 'ERROR'
            try { Start-Apollo } catch { Write-Log ('Cannot start the service: ' + $_.Exception.Message) 'ERROR' }
            return 1
        }

        $ok = $false
        try {
            if (Invoke-Installer -Path $exePath) {
                $ok = Wait-Healthy -FullSha $best.Commit -Baseline $baseline
            }
        } catch {
            Write-Log ('Installation error: ' + $_.Exception.Message) 'ERROR'
            $ok = $false
        }
    } finally {
        $exeLock.Dispose()
    }

    if ($ok) {
        Write-State -Manifest $best -Tag $best.Tag
        Write-Log "Update to $($best.Tag) complete. Remove the download folder."
        try { Remove-DirectoryTree -Path $tagDir } catch { Write-Log $_.Exception.Message 'WARN' }
        return 0
    }

    # 5. Roll back.
    Set-Content -LiteralPath $failedMarker -Value ("Failed at {0}" -f (Get-Date -Format 's')) -Encoding ASCII
    try {
        Restore-Backup -Backup $backup -Baseline $baseline
        Write-Log "Update to $($best.Tag) failed. The backup is restored. The download stays in $tagDir." 'ERROR'
        return 2
    } catch {
        Write-Log ('Restore failed: ' + $_.Exception.Message + ". Restore manually from $($backup.Zip) and $($backup.Config).") 'ERROR'
        return 3
    }
}

$exitCode = 1
try {
    if (-not (Test-Path -LiteralPath $RootDir)) {
        throw "$RootDir does not exist. Run Install-ApolloUpdateTask.ps1 first."
    }
    Assert-SafeFolder -Path $RootDir
    Initialize-Folder -Path $LogDir -AdminOnly $false
    Initialize-Log
    Initialize-Folder -Path $DataDir -AdminOnly $true
    foreach ($d in @($DownloadRoot, $BackupDir, $FailedDir)) { Initialize-Folder -Path $d -AdminOnly $true }

    # A lock file in the admin-only folder. A normal user cannot open it, so
    # a normal user cannot block the updater.
    try {
        $script:LockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {
        Write-Log ('A different ApolloUpdate run is active, or the lock file cannot be opened: ' + $_.Exception.Message) 'WARN'
        $exitCode = 4
    }
    if ($script:LockStream) {
        $exitCode = [int](Invoke-Update | Select-Object -Last 1)
    }
} catch {
    Write-Log ('Error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage) 'ERROR'
    $exitCode = 1
} finally {
    if ($script:LockStream) { $script:LockStream.Dispose() }
}
Write-Log "ApolloUpdate end. Exit code: $exitCode"
exit $exitCode
