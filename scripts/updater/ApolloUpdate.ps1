<#
.SYNOPSIS
    Installs the newest signed Apollo build from GitHub releases.

.DESCRIPTION
    This script runs as SYSTEM from the scheduled task "ApolloUpdate".
    It finds the newest release of catapultam/apollo-microphone for one
    branch (the channel), verifies the RSA signature of SHA256SUMS with the
    public key in this file, verifies the SHA-256 of Apollo.exe, makes a
    backup, runs the installer silently and checks the result. If the check
    fails, it restores the backup.

    The signature check is the only thing that stops a malicious release
    from being installed as SYSTEM. Do not remove it.

    Exit codes:
      0  Installed, no update necessary, or skipped (stream active, lock busy).
      1  Error before any change to the installation.
      2  Installation failed. The backup was restored.
      3  Installation failed and the restore also failed.

    Compatible with Windows PowerShell 5.1. Use only ASCII in this file.

.PARAMETER Channel
    The branch name to follow. The release body must have the line
    "branch: <Channel>".

.PARAMETER Force
    Install also if the installed build has the same commit, and install
    also a release that failed before.

.PARAMETER CheckOnly
    Find the release and do all the checks, but do not download, change or
    install anything.

.PARAMETER SkipStreamCheck
    Do not look for an active Moonlight stream.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Channel = 'master',
    [switch]$Force,
    [switch]$CheckOnly,
    [switch]$SkipStreamCheck
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
$ServiceName     = 'ApolloService'
$BackupRoot      = 'C:\ApolloBackup'
$UpdateRoot      = Join-Path $BackupRoot 'update'
$LogFile         = Join-Path $UpdateRoot 'ApolloUpdate.log'
$LogMaxBytes     = 5MB
$KeepBackups     = 3
$InstallerTimeoutSec   = 600
$ServiceWaitSec        = 90
$StreamLogWindowSec    = 60
$StreamIoBytesPerSec   = 100KB
$StreamIoSamples       = 3
$AssetNames      = @('Apollo.exe', 'SHA256SUMS', 'SHA256SUMS.sig')
$UserAgent       = 'ApolloUpdate/1 (+https://github.com/catapultam/apollo-microphone)'

# Public key for the release signature: RSA 3072, exponent 65537.
# The private key is only in the GitHub Actions secret
# APOLLO_UPDATE_SIGNING_KEY. The same key is in
# scripts/updater/apollo-update-signing.pub.pem. See README.md to change it.
$PublicKeyModulusBase64 = @(
    '7IoWkHGl69bPZvSnU/ZvR8Q8Vs/aIUrvKJa4h2PTq8HI21OGiJG4uE3gywRHASiSfkLyN99J9e5Ho/HD2yyz'
    '1PrcMaWelAVNh5RSEGv9Bm71lD5bq35D7YFrB2u0Dxidhz25zAYrUBVaCcTu4QKgpt1/QxGUhDlnhxrTYYGt'
    'w5X+4fPFTwcoQlE3HBR+5LKRW/0jdpd95yTNbYGb5ZozJ3z/4U+EpJzCGX0z4jxjSJ1eoajH8rN7U73fcM2Q'
    'ijojja9Q/Ns1AlJUMZbXT4flnzFo8tkdPo+cl02mA0NcAatFAZSm0aWpUfALj4rAnlqH+UO0iOjV3ASeRHfx'
    'yr+MnT83mz1TxGJKYkN+HvYseStU2l/4EMCLijMCWEMnq17QnUPI25josz11xIkDo7WexbLVcY2gthFhtvoL'
    '7dgHk4ncGilOwVXmYeIhyW3AzZWiUrdadIyjN3lctx5YAkx6O5BcoxqsdgAGg8Av42FvbFx7jZXbN/wtubKc'
    '5+mWGHtf'
) -join ''
$PublicKeyExponentBase64 = 'AQAB'

$SidSystem = 'S-1-5-18'
$SidAdmins = 'S-1-5-32-544'
$SidUsers  = 'S-1-5-32-545'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:LogReady = $false

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
# Folder security
# ---------------------------------------------------------------------------
function New-SecureDirectorySecurity {
    param([bool]$UsersRead)
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
    if ($UsersRead) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($SidUsers)
        $rx = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, $rx, $inherit, $prop, $allow)))
    }
    return $sec
}

# Makes sure that only SYSTEM and Administrators can change the folder.
# A normal user can make folders in C:\, so the folder can exist before this
# script runs. Thus set the owner and replace the DACL each time.
function Set-SecureDirectory {
    param([string]$Path, [bool]$UsersRead)
    $sec = New-SecureDirectorySecurity -UsersRead $UsersRead
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer) { throw "$Path is not a folder." }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "$Path is a reparse point (link or junction). Remove it."
        }
        # Make Administrators the owner of the folder and all items in it.
        $out = & icacls.exe $Path /setowner "*$SidAdmins" /T /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { throw "icacls /setowner failed for ${Path}: $out" }
        # Replace the full DACL of the folder (protected, no inherited ACEs).
        [System.IO.Directory]::SetAccessControl($Path, $sec)
        # Remove the explicit ACEs of all items in the folder. Then they get
        # only the ACEs of the folder.
        if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
            $out = & icacls.exe (Join-Path $Path '*') /reset /T /C /Q 2>&1
            if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed for ${Path}: $out" }
        }
    } else {
        $null = [System.IO.Directory]::CreateDirectory($Path, $sec)
    }
}

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------
function Invoke-GitHubApi {
    param([string]$Uri)
    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = 'application/vnd.github+json' }
    return Invoke-RestMethod -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 60
}

function Find-NewestRelease {
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
            $tagMatch = [regex]::Match($tag, '^build-[0-9]+-([0-9a-f]{7})$')
            if (-not $tagMatch.Success) { continue }
            $body = [string]$r.body
            $b = [regex]::Match($body, '(?m)^branch:[ \t]*(\S+)[ \t]*\r?$')
            if (-not $b.Success -or ($b.Groups[1].Value -cne $Branch)) { continue }
            $c = [regex]::Match($body, '(?m)^commit:[ \t]*([0-9a-f]{40})[ \t]*\r?$')
            if (-not $c.Success) { continue }
            $sha = $c.Groups[1].Value
            if (-not $sha.StartsWith($tagMatch.Groups[1].Value)) { continue }
            $urls = @{}
            foreach ($a in @($r.assets)) {
                if ($AssetNames -ccontains [string]$a.name) { $urls[[string]$a.name] = [string]$a.browser_download_url }
            }
            if ($urls.Count -ne $AssetNames.Count) { continue }
            $date = $r.published_at
            if (-not $date) { $date = $r.created_at }
            $found += New-Object PSObject -Property @{
                Tag = $tag; Sha = $sha; Published = [datetime]$date; Urls = $urls; Name = [string]$r.name
            }
        }
        if ($releases.Count -lt 100) { break }
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object -Property Published -Descending | Select-Object -First 1)
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
# Stream detection
# ---------------------------------------------------------------------------
function Get-OpenFileLength {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    $share = [System.IO.FileShare]'ReadWrite, Delete'
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try { return $fs.Length } finally { $fs.Dispose() }
}

function Get-SunshineIoBytes {
    $total = [double]0
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='sunshine.exe'")) {
        $total += [double]$p.ReadTransferCount + [double]$p.WriteTransferCount + [double]$p.OtherTransferCount
    }
    return $total
}

# Returns a text that tells why a stream is active, or $null.
# Rule 1: sunshine.log was written in the last 60 s (last write time), or
#         its length changed during the I/O samples.
# Rule 2: the mean I/O rate of all sunshine.exe processes (read + write +
#         other transfer bytes of Win32_Process) over 3 samples of 1 s is
#         more than 100 KB/s.
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
# Download and verification
# ---------------------------------------------------------------------------
function Get-Asset {
    param([string]$Url, [string]$Path)
    if (-not $Url.StartsWith("https://github.com/$Repo/releases/download/")) {
        throw "Unexpected asset URL: $Url"
    }
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 600 -Headers @{ 'User-Agent' = $UserAgent }
}

function Test-ReleaseSignature {
    param([byte[]]$Data, [byte[]]$Signature)
    try {
        $p = New-Object System.Security.Cryptography.RSAParameters
        $p.Modulus = [Convert]::FromBase64String($PublicKeyModulusBase64)
        $p.Exponent = [Convert]::FromBase64String($PublicKeyExponentBase64)
        if ($p.Modulus.Length -ne 384) { throw 'The embedded public key is not RSA 3072.' }
        if ($Signature.Length -ne 384) { throw "The signature has $($Signature.Length) bytes, not 384." }
        $rsa = [System.Security.Cryptography.RSA]::Create()
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

# Reads the SHA-256 for Apollo.exe from the verified SHA256SUMS bytes.
function Get-ExpectedHash {
    param([byte[]]$SumsBytes)
    $text = [System.Text.Encoding]::ASCII.GetString($SumsBytes)
    $hashes = @()
    foreach ($line in ($text -split "`n")) {
        $m = [regex]::Match($line.TrimEnd("`r"), '^([0-9a-fA-F]{64}) [ *]Apollo\.exe$')
        if ($m.Success) { $hashes += $m.Groups[1].Value.ToLowerInvariant() }
    }
    if ($hashes.Count -ne 1) { throw "SHA256SUMS must have exactly one line for Apollo.exe. Found $($hashes.Count)." }
    return $hashes[0]
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

function Wait-Installed {
    param([string]$FullSha)
    $deadline = (Get-Date).AddSeconds($ServiceWaitSec)
    while ($true) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        $status = if ($svc) { [string]$svc.Status } else { 'missing' }
        $sha = Get-InstalledSha
        if ($status -eq 'Running' -and (Test-ShaMatch -ShortSha $sha -FullSha $FullSha)) {
            Write-Log "$ServiceName is Running and sunshine.exe has version $(Get-InstalledVersion)"
            return $true
        }
        if ((Get-Date) -gt $deadline) {
            Write-Log "Timeout: $ServiceName is $status and sunshine.exe has version $(Get-InstalledVersion)" 'ERROR'
            return $false
        }
        Start-Sleep -Seconds 2
    }
}

# ---------------------------------------------------------------------------
# Backup and restore
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-Backup {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $zipPath = Join-Path $BackupRoot "auto-$ts.zip"
    $cfgPath = Join-Path $BackupRoot "auto-config-$ts"
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
    Remove-OldBackups
    return New-Object PSObject -Property @{ Zip = $zipPath; Config = $cfgPath }
}

# Removes a folder tree. "rmdir /s" does not go into junctions or links,
# but Remove-Item -Recurse in Windows PowerShell 5.1 can.
function Remove-DirectoryTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $out = & cmd.exe /d /c rmdir /s /q "$Path" 2>&1
    if (Test-Path -LiteralPath $Path) { throw "Cannot remove ${Path}: $out" }
}

function Remove-OldBackups {
    $zips = @(Get-ChildItem -LiteralPath $BackupRoot -Filter 'auto-*.zip' -File -Force | Sort-Object Name -Descending)
    foreach ($z in ($zips | Select-Object -Skip $KeepBackups)) {
        Write-Log "Remove old backup $($z.FullName)"
        Remove-Item -LiteralPath $z.FullName -Force
    }
    $dirs = @(Get-ChildItem -LiteralPath $BackupRoot -Filter 'auto-config-*' -Directory -Force | Sort-Object Name -Descending)
    foreach ($d in ($dirs | Select-Object -Skip $KeepBackups)) {
        if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Log "Do not remove $($d.FullName): it is a reparse point" 'WARN'
            continue
        }
        Write-Log "Remove old backup $($d.FullName)"
        Remove-DirectoryTree -Path $d.FullName
    }
}

function Restore-Backup {
    param($Backup)
    Write-Log "Restore the backup $($Backup.Zip) and $($Backup.Config)" 'WARN'
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
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
        }
    } finally {
        $zip.Dispose()
    }
    $null = New-Item -ItemType Directory -Path $ConfigDir -Force
    Copy-Item -Path (Join-Path $Backup.Config '*') -Destination $ConfigDir -Recurse -Force
    Start-Apollo
    $svc = Get-Service -Name $ServiceName
    $svc.WaitForStatus('Running', (New-TimeSpan -Seconds $ServiceWaitSec))
    Write-Log "Restore complete. sunshine.exe has version $(Get-InstalledVersion)" 'WARN'
}

# ---------------------------------------------------------------------------
# Installer
# ---------------------------------------------------------------------------
function Invoke-Installer {
    param([string]$Path)
    Write-Log "Run $Path /S"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.Arguments = '/S'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        if (-not $proc.WaitForExit($InstallerTimeoutSec * 1000)) {
            Write-Log "The installer did not stop in $InstallerTimeoutSec s. Stop it." 'ERROR'
            try { $proc.Kill() } catch { }
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
    Write-Log "ApolloUpdate start. User: $who. Channel: $Channel. Force: $Force. CheckOnly: $CheckOnly. SkipStreamCheck: $SkipStreamCheck."

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    $rel = Find-NewestRelease -Branch $Channel
    if (-not $rel) {
        Write-Log "No release found for channel $Channel with the assets $($AssetNames -join ', ')." 'WARN'
        return 0
    }
    Write-Log "Newest release: $($rel.Tag) ($($rel.Name)), commit $($rel.Sha), published $($rel.Published)"

    $installedVersion = Get-InstalledVersion
    $installedSha = Get-InstalledSha
    Write-Log "Installed sunshine.exe version: $installedVersion"
    if ((Test-ShaMatch -ShortSha $installedSha -FullSha $rel.Sha) -and -not $Force) {
        Write-Log 'The installed build has the release commit. No update necessary.'
        return 0
    }

    $tagDir = Join-Path $UpdateRoot $rel.Tag
    $failedMarker = Join-Path $tagDir 'FAILED'
    if ((Test-Path -LiteralPath $failedMarker) -and -not $Force) {
        Write-Log "Release $($rel.Tag) failed before (see $failedMarker). Skip it. Use -Force to try again." 'WARN'
        return 0
    }

    if (-not $SkipStreamCheck) {
        $active = Get-StreamActivity
        if ($active) {
            Write-Log "A stream is possibly active ($active). Skip the update."
            return 0
        }
        Write-Log 'No active stream found.'
    }

    if ($CheckOnly) {
        Write-Log "CheckOnly: an update to $($rel.Tag) is available. No change made."
        return 0
    }

    # Download into a new, empty folder.
    if (Test-Path -LiteralPath $tagDir) {
        $item = Get-Item -LiteralPath $tagDir -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "$tagDir is a reparse point." }
        Remove-DirectoryTree -Path $tagDir
    }
    $null = New-Item -ItemType Directory -Path $tagDir -Force
    foreach ($name in $AssetNames) {
        Write-Log "Download $name"
        Get-Asset -Url $rel.Urls[$name] -Path (Join-Path $tagDir $name)
    }

    $sumsBytes = [System.IO.File]::ReadAllBytes((Join-Path $tagDir 'SHA256SUMS'))
    $sigBytes = [System.IO.File]::ReadAllBytes((Join-Path $tagDir 'SHA256SUMS.sig'))
    if (-not (Test-ReleaseSignature -Data $sumsBytes -Signature $sigBytes)) {
        Write-Log 'The signature of SHA256SUMS is NOT valid. Stop. Nothing was installed.' 'ERROR'
        return 1
    }
    Write-Log 'The signature of SHA256SUMS is valid.'
    $expected = Get-ExpectedHash -SumsBytes $sumsBytes

    # Keep Apollo.exe open without write or delete share from the hash check
    # until the installer stops. Thus nobody can replace it between the check
    # and the start.
    $exePath = Join-Path $tagDir 'Apollo.exe'
    $exeLock = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $actual = Get-StreamSha256 -Stream $exeLock
        if ($actual -ne $expected) {
            Write-Log "Apollo.exe SHA-256 is $actual, but SHA256SUMS has $expected. Stop. Nothing was installed." 'ERROR'
            return 1
        }
        Write-Log "Apollo.exe SHA-256 is correct: $actual"

        if (-not $SkipStreamCheck) {
            $active = Get-StreamActivity
            if ($active) {
                Write-Log "A stream is possibly active ($active). Skip the update."
                return 0
            }
        }

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
                $ok = Wait-Installed -FullSha $rel.Sha
            }
        } catch {
            Write-Log ('Installation error: ' + $_.Exception.Message) 'ERROR'
            $ok = $false
        }
    } finally {
        $exeLock.Dispose()
    }

    if ($ok) {
        Write-Log "Update to $($rel.Tag) complete. Remove the download folder."
        try { Remove-DirectoryTree -Path $tagDir } catch { Write-Log $_.Exception.Message 'WARN' }
        return 0
    }

    Set-Content -LiteralPath $failedMarker -Value ("Failed at {0}" -f (Get-Date -Format 's')) -Encoding ASCII
    try {
        Restore-Backup -Backup $backup
        Write-Log "Update to $($rel.Tag) failed. The backup is restored. The download stays in $tagDir." 'ERROR'
        return 2
    } catch {
        Write-Log ('Restore failed: ' + $_.Exception.Message + ". Restore manually from $($backup.Zip) and $($backup.Config).") 'ERROR'
        return 3
    }
}

$exitCode = 1
$mutex = $null
$haveMutex = $false
try {
    if (-not $CheckOnly) {
        Set-SecureDirectory -Path $BackupRoot -UsersRead $false
        Set-SecureDirectory -Path $UpdateRoot -UsersRead $true
    }
    if (Test-Path -LiteralPath $UpdateRoot) { Initialize-Log }

    $mutex = New-Object System.Threading.Mutex($false, 'Global\ApolloUpdate')
    try {
        $haveMutex = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $haveMutex = $true
    }
    if (-not $haveMutex) {
        Write-Log 'An other ApolloUpdate run is active. Stop.' 'WARN'
        $exitCode = 0
    } else {
        $exitCode = [int](Invoke-Update | Select-Object -Last 1)
    }
} catch {
    Write-Log ('Error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage) 'ERROR'
    $exitCode = 1
} finally {
    if ($haveMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
Write-Log "ApolloUpdate end. Exit code: $exitCode"
exit $exitCode
