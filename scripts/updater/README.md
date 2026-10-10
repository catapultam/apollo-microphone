# Apollo host updater

These scripts install new Apollo builds on the Windows host without UAC.

| File | Purpose |
| --- | --- |
| `ApolloUpdate.ps1` | The updater. Runs as SYSTEM from the scheduled tasks. Has the public key. |
| `Install-ApolloUpdateTask.ps1` | Installs the updater and the tasks. Run it one time, elevated. |
| `apollo-update-signing.pub.pem` | The same public key in PEM format, for checks on Linux. |
| `../../.github/workflows/build-windows.yml` | Builds, signs and publishes the release. |

## How it works

### CI

1. A push to `master` or `live-resize`, or a manual run of the
   `Build-Windows` workflow on one of these branches, builds `Apollo.exe`
   (the NSIS installer). The build job gives the SHA-256 of `Apollo.exe`
   as a job output.
2. The `publish` job runs only for the branches in its `if:` list. It uses
   the GitHub environment `release`. This environment has the secret
   `APOLLO_UPDATE_SIGNING_KEY` and a deployment branch rule with the same
   branches. A run on a different branch cannot get the key.
3. The job makes sure that the downloaded artifact has the SHA-256 from
   the build job of the same run. Then it writes
   `apollo-update-manifest.txt`:

   ```
   format: apollo-update-manifest-1
   repository: catapultam/apollo-microphone
   channel: <branch>
   commit: <full commit sha>
   run_id: <github.run_id>
   run_number: <github.run_number>
   run_attempt: <github.run_attempt>
   apollo_exe_sha256: <sha256 of Apollo.exe>
   ```

4. It signs the exact bytes of the manifest: RSA 3072, SHA-256,
   PKCS#1 v1.5 (`openssl dgst -sha256 -sign`), to
   `apollo-update-manifest.txt.sig`.
5. It makes a prerelease with the tag `build-<run number>-<short sha>`
   (`-a<attempt>` is added for a re-run) and the assets `Apollo.exe`,
   `apollo-update-manifest.txt` and `apollo-update-manifest.txt.sig`.
   The release body (`branch:`, `commit:`, `run:`, `run_url:`) is for
   people. The updater does not trust it.
6. The checkout uses a detached HEAD. Then `cmake/prep/build_version.cmake`
   adds the short sha to the version on all branches (also on `master`),
   for example `0.0.0.977136a.dirty`.

### Host

All files are in `C:\ProgramData\ApolloUpdate`:

| Path | Content | ACL |
| --- | --- | --- |
| `ApolloUpdate.ps1` | the script | SYSTEM, Administrators: full. Users: read and execute. |
| `logs\ApolloUpdate.log` | the log | same as above |
| `data\downloads\` | manifests and installers | SYSTEM, Administrators only |
| `data\backups\` | `auto-<ts>.zip`, `auto-config-<ts>\`, `auto-config-<ts>.acl` | SYSTEM, Administrators only |
| `data\failed\<tag>` | marks a release that failed | SYSTEM, Administrators only |
| `data\state.json` | last installed run_id, commit, tag | SYSTEM, Administrators only |
| `data\update.lock` | lock while a run is active | SYSTEM, Administrators only |

The updater does not use or change `C:\ApolloBackup`. It does not change
ACLs recursively. It examines that the folders are not links and that
Administrators or SYSTEM own them. If not, it stops (exit 1).

Two tasks run the same script as SYSTEM:

| Task | Start | Stream guard |
| --- | --- | --- |
| `ApolloUpdate` | daily at 04:00 | yes |
| `ApolloUpdateNow` | only manual (`schtasks /run`) | no (`-SkipStreamGuard`) |

You get access to the host through a stream. Thus a manual update must not
wait for the end of the stream. A manual start of `ApolloUpdateNow` means
that you accept that the stream stops during the update.

`ApolloUpdate.ps1` does these steps:

1. Takes the lock file. If a different run has it, exit 4.
2. Gets the releases from the GitHub REST API (no authentication,
   TLS 1.2). It takes the 10 newest releases that are not drafts, that
   have a correct tag, the three assets, and the body line
   `branch: <channel>`.
3. For each one, it downloads the manifest and the signature and verifies
   the signature with the embedded public key. It refuses a manifest with
   a bad signature, a different repository or channel, or a commit that
   does not agree with the tag. From the valid manifests it uses the one
   with the highest `run_id`. If there is none, exit 5.
4. Compares with `data\state.json` and the installed build (the sha at the
   end of the ProductVersion of `sunshine.exe`):
   - `run_id` lower than the last installed `run_id`: refuse (no
     downgrade), exit 10.
   - `run_id` equal to the last installed `run_id`: exit 10. This is also
     true after a manual rollback, so the updater does not undo the
     rollback. `-Force` installs it again.
   - Installed commit equal to the manifest commit: write the state,
     exit 10.
   - A `data\failed\<tag>` file exists: exit 12 (`-Force` tries again).
5. Nightly task only: the stream guard (see below). Active: exit 11.
6. Downloads `Apollo.exe` and verifies its SHA-256 against the signed
   manifest. If it is different, exit 6. Nothing has stopped yet. It keeps
   `Apollo.exe` open (no write or delete share) until the installer stops.
7. Nightly task only: the stream guard again.
8. If more than 45 of the 60 task minutes are used, exit 7 (the
   installation, the check and a restore need up to 15 minutes).
9. Records the health before the update: does `sunshine.exe` run, and does
   it listen on the base port (`port` in `sunshine.conf`, default 47989)
   and the web UI port (base + 1).
10. Stops `ApolloService` and all `sunshine.exe` processes. Makes a backup:
    `data\backups\auto-<ts>.zip` (all of `C:\Program Files\Apollo` without
    `*.log`), `auto-config-<ts>\` (copy of `config`, with `credentials`,
    without `*.log`) and `auto-config-<ts>.acl` (`icacls /save` of the ACLs
    of `config`). Keeps the newest 3 of each.
11. Runs `Apollo.exe /S`, maximum 10 minutes. On timeout it stops the
    installer and its child processes (`taskkill /T /F`) and rolls back.
12. Health check, maximum 90 s: no old uninstaller runs, `ApolloService`
    is Running, `sunshine.exe` has a ProductVersion with the new sha, and,
    if `sunshine.exe` ran before, it runs from `C:\Program Files\Apollo` and
    listens on the same ports as before. Then the same process, the service
    and the ports must stay for 30 s. A crash loop fails this check.
13. Success: writes `data\state.json`, removes the download folder, exit 0.
14. Failure: writes `data\failed\<tag>` and restores the backup: stop the
    service, extract the zip over the install folder, copy the config back,
    `icacls /restore` of the config ACLs, run `delete-firewall-rule.bat` and
    `add-firewall-rule.bat`, and if `ApolloService` does not exist, run
    `install-service.bat` and `autostart-service.bat` from the restored
    files. Then start the service and do the health check (without the
    version). Exit 2. If the restore fails, exit 3.

Note about the installer: `cmake/packaging/windows_nsis.cmake` sets
`CPACK_NSIS_ENABLE_UNINSTALL_BEFORE_INSTALL ON`. The CPack NSIS template of
CMake 4.4.4 (the version that CI uses) runs the old uninstaller with
`ExecWait '"$0" /S _?=$3'`, so it does not copy itself to `%TEMP%` and the
installer waits for it. The old uninstaller removes `ApolloService` and the
firewall rules, then the new installer adds them again. This is why the
restore makes the service again if it is missing. In silent mode,
`IfSilent +2 0` skips only `icacls "$INSTDIR" /reset`.

### Stream guard

The nightly task skips the update if one of these rules is true:

1. `C:\Program Files\Apollo\config\sunshine.log` was written in the last
   60 s (last write time), or its length changed during the I/O samples.
2. The mean I/O rate of all `sunshine.exe` processes is more than
   100 KB/s over 3 samples of 1 s (change of `ReadTransferCount +
   WriteTransferCount + OtherTransferCount` of `Win32_Process`).

Uncertainty: it is not known if Windows counts all socket traffic of
`sunshine.exe` in these counters. It is also not known if Apollo writes
to `sunshine.log` when no stream is active. If it does this each minute,
the nightly task always skips (exit 11). Examine the log after the first
nights. `ApolloUpdateNow` does not use the guard.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The new build is installed. |
| 10 | Skipped: no newer release (up to date, or refused downgrade). |
| 11 | Skipped: a stream is possibly active (nightly task). |
| 12 | Skipped: this release failed before. |
| 1 | Error before a change to the installation. |
| 2 | Installation failed. The backup was restored. |
| 3 | Installation failed and the restore failed. Restore manually. |
| 4 | A different run is active. |
| 5 | No release with a valid signed manifest for the channel. |
| 6 | `Apollo.exe` does not agree with the signed manifest. |
| 7 | Not sufficient time left in the task time limit. |

Parameters of `ApolloUpdate.ps1`:

| Parameter | Effect |
| --- | --- |
| `-Channel <branch>` | Branch to follow. Default: `master`. The tasks have the channel that you gave to the install script. |
| `-Force` | Install again the last installed `run_id`, or a release that failed before. Never a lower `run_id`. |
| `-CheckOnly` | Find and verify the release and do the checks. Downloads only the manifests. Does not stop or change Apollo. |
| `-SkipStreamGuard` | Do not look for an active stream. |

## Install (one time, elevated)

Copy `ApolloUpdate.ps1` and `Install-ApolloUpdateTask.ps1` to one folder on
the host. Then, in an elevated Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-ApolloUpdateTask.ps1 -Channel live-resize
```

Use `-Channel master` (the default) to follow `master`. Run the same
command again to install a new version of `ApolloUpdate.ps1` or to change
the channel. It keeps the data and the log. Add `-ResetState` when you
change to a channel with older builds (the updater does not install a
lower `run_id` than the state file has).

The install script:

- Makes `C:\ProgramData\ApolloUpdate` with owner Administrators and a
  protected ACL: SYSTEM and Administrators full control, Users read and
  execute. If the folder exists and a different owner has it (a normal
  user can make folders in `C:\ProgramData`), it removes it fully first.
- Makes `data\` with a protected ACL for SYSTEM and Administrators only.
- Copies `ApolloUpdate.ps1` into it and compares the SHA-256.
- Registers `\ApolloUpdate` (daily at 04:00) and `\ApolloUpdateNow` (no
  trigger, `-SkipStreamGuard`). Both: user SYSTEM, run level Highest,
  start on demand permitted, start after a missed start off, stop after
  60 minutes, no second instance. Action:
  `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\ApolloUpdate\ApolloUpdate.ps1" -Channel <channel> [-SkipStreamGuard]`
- Sets the security descriptor of both tasks with the `Schedule.Service`
  COM object:

  ```
  D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)
  ```

  - `(A;;FA;;;SY)`: SYSTEM, full access.
  - `(A;;FA;;;BA)`: Administrators, full access.
  - `(A;;GRGX;;;AU)`: Authenticated Users, read and execute. Execute is the
    right to run the task. There is no write right, so they cannot change,
    disable or delete the task.

Group Policy: if a policy sets the PowerShell execution policy
(`MachinePolicy` or `UserPolicy`), `-ExecutionPolicy Bypass` on the command
line has no effect. Then the script must be signed with Authenticode or the
policy must permit it.

## Run on demand

As the normal user, without elevation (the active stream stops):

```bat
schtasks /run /tn ApolloUpdateNow
```

Show the result of the last run ("Last Result" is the exit code):

```bat
schtasks /query /tn ApolloUpdateNow /v /fo list
type C:\ProgramData\ApolloUpdate\logs\ApolloUpdate.log
```

To run with other parameters (for example `-Force` or `-CheckOnly`), use
an elevated Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ApolloUpdate\ApolloUpdate.ps1 -Channel live-resize -CheckOnly
```

## Logs

`C:\ProgramData\ApolloUpdate\logs\ApolloUpdate.log`: all steps, appended.
When the file is 5 MB or more at the start of a run, the updater moves it
to `ApolloUpdate.log.1` (the old `.1` file is deleted). Users can read it.

## Rollback

A rollback is a restore of a backup. Do not delete releases.

1. In an elevated Windows PowerShell, stop the service:
   `Stop-Service ApolloService -Force`. Stop `sunshine.exe` if it runs.
2. Extract the backup zip over the install folder (replace the files):

   ```powershell
   $b = 'C:\ProgramData\ApolloUpdate\data\backups'
   $zip = Get-ChildItem $b -Filter 'auto-*.zip' | Sort-Object Name | Select-Object -Last 1
   Add-Type -AssemblyName System.IO.Compression.FileSystem
   $a = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
   foreach ($e in $a.Entries) { if ($e.Name) {
       $d = Join-Path 'C:\Program Files\Apollo' $e.FullName
       New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null
       [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $d, $true) } }
   $a.Dispose()
   ```

3. Copy the config with the same timestamp back, and restore its ACLs:

   ```powershell
   $ts = $zip.BaseName.Substring(5)
   Copy-Item "$b\auto-config-$ts\*" 'C:\Program Files\Apollo\config\' -Recurse -Force
   icacls 'C:\Program Files\Apollo' /restore "$b\auto-config-$ts.acl" /C
   ```

4. If `ApolloService` does not exist, run
   `C:\Program Files\Apollo\scripts\install-service.bat` and
   `autostart-service.bat`. Then `Start-Service ApolloService`.

The state file keeps the `run_id` of the newer build. Thus the nightly task
does not install that build again (exit 10). The next new build (higher
`run_id`) installs normally. To install the newer build again, run
`ApolloUpdate.ps1 -Force` as administrator.

The restore does not delete files that the newer build added. It does not
undo driver or registry changes of the installer.

## Change the signing key (re-key)

Do this if the private key is possibly known to a different person, or to
replace it. Do it on a Linux computer with `openssl`, `python3` and `gh`.

1. Make a new key pair in memory (not on a disk):

   ```bash
   umask 077
   d=$(mktemp -d /dev/shm/apk.XXXXXX)
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$d/key.pem"
   openssl pkey -in "$d/key.pem" -pubout -out scripts/updater/apollo-update-signing.pub.pem
   ```

2. Set the environment secret:

   ```bash
   gh secret set APOLLO_UPDATE_SIGNING_KEY -R catapultam/apollo-microphone --env release < "$d/key.pem"
   ```

3. Remove the private key: `shred -u "$d/key.pem"; rm -rf "$d"`.
   Do not keep a copy. If the key is lost, make a new one.
4. Get the modulus in base64 and put it in `$PublicKeyModulusBase64` in
   `ApolloUpdate.ps1` (the exponent `AQAB` = 65537 stays the same):

   ```bash
   openssl rsa -pubin -in scripts/updater/apollo-update-signing.pub.pem -noout -modulus \
     | cut -d= -f2 | python3 -c 'import sys,base64;print(base64.b64encode(bytes.fromhex(sys.stdin.read().strip())).decode())'
   ```

5. Commit the two files and push to a publish branch. Make sure that the
   new release verifies:

   ```bash
   openssl dgst -sha256 -verify scripts/updater/apollo-update-signing.pub.pem \
     -signature apollo-update-manifest.txt.sig apollo-update-manifest.txt
   ```

6. On the host, run `Install-ApolloUpdateTask.ps1` again (elevated) with
   the new `ApolloUpdate.ps1`. Until you do this, the host does not accept
   releases with the new key. Releases signed with the old key stay valid
   for a host with the old script. Delete them on GitHub if the old key is
   possibly known to a different person.

To change the publish branches, change the `if:` list of the `publish` job
and the deployment branch rule of the `release` environment (Settings,
Environments, release) together.

## Security model

The tasks run downloaded code as SYSTEM. These items protect it:

- **The signature check is the only thing that stops a malicious release
  from being installed as SYSTEM.** GitHub, TLS and the release body do not
  give this protection. Do not remove or weaken the check.
- The signature covers the manifest: channel, full commit, `run_id` and
  the SHA-256 of `Apollo.exe`. A person with `contents: write` can copy old
  signed assets into a new release, but the updater uses the highest
  signed `run_id`, refuses a different channel, and never installs a
  `run_id` lower than the last installed one. Thus a copy gives no
  downgrade and no build of a different branch.
- The private key is only in the secret `APOLLO_UPDATE_SIGNING_KEY` of the
  environment `release`. Its deployment branch rule permits only the
  publish branches. Only the `publish` job uses the environment and has
  `contents: write`. A person who can push to a publish branch can change
  the workflow and use the key. Thus push access to `master` or
  `live-resize` is equal to the right to sign. Protect these branches if
  other people get write access.
- `C:\ProgramData\ApolloUpdate` is owned by Administrators. Users can only
  read and execute. A normal user cannot change the script, the
  downloads, the backups or the state, and cannot open the lock file.
- The task security descriptor lets Authenticated Users run the tasks, but
  not change them. A user can only start the fixed commands. A user cannot
  give parameters.
- The backups have the credentials (private key of the host). They are in
  the admin-only `data` folder. A restore puts back the original ACLs of
  `config` with `icacls /restore`.
- The updater keeps `Apollo.exe` open without write or delete share from
  the hash check until the installer stops.
- The updater accepts only asset URLs that start with
  `https://github.com/catapultam/apollo-microphone/releases/download/`.

## Test checklist (first run on a cakebox Windows VM)

Do these tests on a Windows VM with Apollo installed before CPLT-4A. All
of these items were not tested on Windows.

1. Install: run the install script elevated. Examine the printed SDDLs:
   the root folder has `(A;OICI;0x1200a9;;;BU)` (read and execute) and no
   write ACE for users; `data` has only SYSTEM and Administrators.
2. As a normal (not elevated) user:
   - `schtasks /run /tn ApolloUpdateNow` starts the task (`SUCCESS`).
   - `schtasks /change /tn ApolloUpdateNow /disable` and
     `schtasks /delete /tn ApolloUpdateNow /f` are refused
     (access denied).
   - Writing to `C:\ProgramData\ApolloUpdate\ApolloUpdate.ps1` and listing
     `C:\ProgramData\ApolloUpdate\data` are refused.
   - `type C:\ProgramData\ApolloUpdate\logs\ApolloUpdate.log` works.
3. Signature on Windows PowerShell 5.1 (the `RSACng` path): run
   `ApolloUpdate.ps1 -CheckOnly` elevated. The log must show
   `valid signature` for the release. Change one byte of a downloaded
   manifest copy and verify with the functions, or publish nothing and
   confirm that a release without a valid signature gives exit 5.
4. Full update with `ApolloUpdateNow`: the log must show the installer
   exit code 0, `Healthy`, `Stable`, exit 0. Examine that the service and
   the firewall rules exist after the update.
5. Session 0: the installer runs as SYSTEM without a desktop. Make sure
   that the SudoVDA driver step does not wait for a prompt. If it waits,
   the installer timeout (10 minutes) must stop it and the restore must
   run (exit 2).
6. Rollback: make the health check fail (for example, set a wrong `port`
   in a test copy, or stop `sunshine.exe` repeatedly during the stable
   time). The log must show the restore, the service must run again with
   the old version, and `config\credentials` must have its old ACL
   (`icacls "C:\Program Files\Apollo\config\credentials"`).
7. Second run: `schtasks /run /tn ApolloUpdateNow` again gives exit 10.
8. Nightly guard: during a stream, run `schtasks /run /tn ApolloUpdate`.
   It must give exit 11. Without a stream, examine if it gives 11 anyway
   (log noise, see "Stream guard").
9. Lock: start `ApolloUpdateNow` twice fast. The second start gives
   exit 4 or the task scheduler ignores it (IgnoreNew).
