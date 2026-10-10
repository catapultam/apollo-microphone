# Apollo host updater

These scripts install new Apollo builds on the Windows host without UAC.

Files:

| File | Purpose |
| --- | --- |
| `ApolloUpdate.ps1` | The updater. Runs as SYSTEM from the scheduled task. Has the public key. |
| `Install-ApolloUpdateTask.ps1` | Installs the updater and the task. Run it one time, elevated. |
| `apollo-update-signing.pub.pem` | The same public key in PEM format, for checks on Linux. |
| `../../.github/workflows/build-windows.yml` | Builds, signs and publishes the release. |

## How it works

1. A push to `master` or `live-resize`, or a manual run of the
   `Build-Windows` workflow, builds `Apollo.exe` (the NSIS installer).
2. The `publish` job writes `SHA256SUMS` (`sha256sum` format, one line for
   `Apollo.exe`) and signs the exact bytes of this file:
   RSA 3072, SHA-256, PKCS#1 v1.5 (`openssl dgst -sha256 -sign`).
   The private key comes from the Actions secret `APOLLO_UPDATE_SIGNING_KEY`.
3. The job makes a prerelease with the tag `build-<run number>-<short sha>`
   and the assets `Apollo.exe`, `SHA256SUMS` and `SHA256SUMS.sig`.
   The release body has these lines:

   ```
   branch: <branch>
   commit: <full sha>
   run: <run id>
   run_url: <link to the run>
   ```

   A manual run publishes for the branch that it runs on.
4. The checkout uses a detached HEAD. Then `cmake/prep/build_version.cmake`
   adds the short sha to the version on all branches (also on `master`),
   for example `0.0.0.977136a.dirty`. The updater compares this sha.
5. On the host, the task `ApolloUpdate` runs `ApolloUpdate.ps1` as SYSTEM
   every day at 04:00, and when a user starts it.

`ApolloUpdate.ps1` does these steps:

1. Sets the ACL of `C:\ApolloBackup` (SYSTEM and Administrators only) and
   `C:\ApolloBackup\update` (also Users read). See "Security model".
2. Gets the releases from the GitHub REST API (no authentication, TLS 1.2).
   It uses the newest release that is not a draft, that has the line
   `branch: <channel>`, a `commit:` line that agrees with the tag, and all
   three assets.
3. Reads the ProductVersion of `C:\Program Files\Apollo\sunshine.exe`. If
   the sha at its end is the release commit, it stops (exit 0). `-Force`
   installs also in this case.
4. Looks for an active Moonlight stream. If it finds one, it stops (exit 0).
   It uses two rules:
   - `C:\Program Files\Apollo\config\sunshine.log` was written in the last
     60 s (last write time), or its length changed during the I/O samples.
   - The mean I/O rate of all `sunshine.exe` processes is more than
     100 KB/s over 3 samples of 1 s. The rate is the change of
     `ReadTransferCount + WriteTransferCount + OtherTransferCount` from
     `Win32_Process`.

   It does this check again after the download, immediately before it stops
   the service.
5. Downloads the three assets to `C:\ApolloBackup\update\<tag>\`.
   Verifies the signature of `SHA256SUMS` with the embedded public key.
   Verifies the SHA-256 of `Apollo.exe`. If one check fails, it stops
   (exit 1) and does not change the installation. It keeps `Apollo.exe`
   open (no write or delete share) from the hash check until the
   installer stops.
6. Stops `ApolloService` and all `sunshine.exe` processes.
7. Makes a backup:
   - `C:\ApolloBackup\auto-<timestamp>.zip`: all of
     `C:\Program Files\Apollo` without `*.log` files.
   - `C:\ApolloBackup\auto-config-<timestamp>\`: a copy of
     `C:\Program Files\Apollo\config` (with `credentials`) without `*.log`.
   - It keeps only the newest 3 auto backups of each type.
8. Runs `Apollo.exe /S` and waits (maximum 10 minutes).
9. Waits a maximum of 90 s until `ApolloService` is Running and
   `sunshine.exe` has a ProductVersion with the new sha.
10. On success, it removes the download folder (exit 0).
    On failure, it writes `C:\ApolloBackup\update\<tag>\FAILED`, restores
    the backup (stop service, extract the zip over the install folder, copy
    the config back, start service) and stops with exit 2. If the restore
    also fails, exit 3. The download folder stays.
    The updater does not try a release with a `FAILED` file again, except
    with `-Force`. The next build has a new tag.

Exit codes: 0 = installed, no update necessary, or skipped. 1 = error
before a change to the installation. 2 = installation failed, backup
restored. 3 = installation failed, restore failed.

Parameters of `ApolloUpdate.ps1`:

| Parameter | Effect |
| --- | --- |
| `-Channel <branch>` | Branch to follow. Default: `master`. The task has the channel that you gave to the install script. |
| `-Force` | Install also if the commit is the same, or if the release failed before. |
| `-CheckOnly` | Find the release and do the checks. Do not download or change anything. |
| `-SkipStreamCheck` | Do not look for an active stream. |

## Install (one time, elevated)

Copy `ApolloUpdate.ps1` and `Install-ApolloUpdateTask.ps1` to one folder on
the host. Then, in an elevated Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-ApolloUpdateTask.ps1 -Channel live-resize
```

Use `-Channel master` (the default) to follow `master`. Run the same
command again to install a new version of `ApolloUpdate.ps1` or to change
the channel.

The install script:

- Removes `C:\ProgramData\ApolloUpdate` if it exists, and makes it again
  with this ACL (protected, no inherited ACEs), owner Administrators:
  SYSTEM full control, Administrators full control, Users read and execute.
- Copies `ApolloUpdate.ps1` into it and compares the SHA-256.
- Registers the task `\ApolloUpdate`:
  - Action: `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\ApolloUpdate\ApolloUpdate.ps1" -Channel <channel>`
  - User: SYSTEM, run level Highest.
  - Trigger: daily at 04:00.
  - Start on demand: permitted. Start after a missed start: off.
  - Stop the task if it runs longer than 30 minutes. Do not start a
    second instance.
- Sets the task security descriptor with the `Schedule.Service` COM object:

  ```
  D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)
  ```

  - `(A;;FA;;;SY)`: SYSTEM, full access.
  - `(A;;FA;;;BA)`: Administrators, full access.
  - `(A;;GRGX;;;AU)`: Authenticated Users, read and execute. Execute is the
    right to run the task. There is no write right, so they cannot change,
    disable or delete the task.

## Run on demand

As the normal user, without elevation:

```bat
schtasks /run /tn ApolloUpdate
```

Show the result of the last run:

```bat
schtasks /query /tn ApolloUpdate /v /fo list
```

"Last Result" is the exit code of `ApolloUpdate.ps1`.

To run with parameters (for example `-Force` or `-CheckOnly`), use an
elevated Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\ApolloUpdate\ApolloUpdate.ps1 -Channel live-resize -CheckOnly
```

## Logs

- `C:\ApolloBackup\update\ApolloUpdate.log`: all steps, appended. When the
  file is 5 MB or more at the start of a run, the updater moves it to
  `ApolloUpdate.log.1` (the old `.1` file is deleted).
- Users can read the log. Only SYSTEM and Administrators can change it.

## Manual rollback

To go back to the build before the last update:

1. In an elevated Windows PowerShell, stop the service:
   `Stop-Service ApolloService -Force`. Stop `sunshine.exe` if it runs.
2. Extract the newest `C:\ApolloBackup\auto-<timestamp>.zip` over
   `C:\Program Files\Apollo` (replace the files).
3. Copy `C:\ApolloBackup\auto-config-<timestamp>\*` to
   `C:\Program Files\Apollo\config\` (replace the files).
4. Start the service: `Start-Service ApolloService`.

Each backup is the state before an update. The restore does not delete
files that the new build added. It does not undo changes to drivers,
services or the registry that the installer made.

The nightly task installs the newest build again. To stop this, disable the
task as administrator (`schtasks /change /tn ApolloUpdate /disable`) or
publish a new build.

To install an older release, delete the newer releases of the channel on
GitHub. Then the next run installs the newest release that stays, because
its commit is not the installed commit.

## Change the signing key (re-key)

Do this if the private key is possibly known to an other person, or to
replace it. Do it on a Linux computer with `openssl`, `python3` and `gh`.

1. Make a new key pair in memory (not on a disk):

   ```bash
   umask 077
   d=$(mktemp -d /dev/shm/apk.XXXXXX)
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$d/key.pem"
   openssl pkey -in "$d/key.pem" -pubout -out scripts/updater/apollo-update-signing.pub.pem
   ```

2. Set the secret:

   ```bash
   gh secret set APOLLO_UPDATE_SIGNING_KEY -R catapultam/apollo-microphone < "$d/key.pem"
   ```

3. Remove the private key: `shred -u "$d/key.pem"; rm -rf "$d"`.
   Do not keep a copy. If the key is lost, make a new one.
4. Get the modulus in base64 and put it in `$PublicKeyModulusBase64` in
   `ApolloUpdate.ps1` (the exponent `AQAB` = 65537 stays the same):

   ```bash
   openssl rsa -pubin -in scripts/updater/apollo-update-signing.pub.pem -noout -modulus \
     | cut -d= -f2 | python3 -c 'import sys,base64;print(base64.b64encode(bytes.fromhex(sys.stdin.read().strip())).decode())'
   ```

5. Commit the two files and push. Run the workflow and make sure that the
   new release verifies:

   ```bash
   openssl dgst -sha256 -verify scripts/updater/apollo-update-signing.pub.pem \
     -signature SHA256SUMS.sig SHA256SUMS
   ```

6. On the host, run `Install-ApolloUpdateTask.ps1` again (elevated) with
   the new `ApolloUpdate.ps1`. Until you do this, the host does not accept
   releases with the new key. Releases signed with the old key stay valid
   for a host with the old script. Delete them on GitHub if the old key is
   possibly known to an other person.

## Security model

The task runs downloaded code as SYSTEM. These items protect it:

- **The signature check is the only thing that stops a malicious release
  from being installed as SYSTEM.** GitHub, TLS and the release data do not
  give this protection. A person with write access to the repository can
  make a release, but cannot make a valid signature without the private
  key. Do not remove or weaken the check.
- The private key is only in the Actions secret
  `APOLLO_UPDATE_SIGNING_KEY`. Only the `publish` job gets it. Only the
  `publish` job has `contents: write`. A person who can push a change to
  the workflow on a branch can use the secret in a run. Thus write access
  to the repository is equal to the right to sign.
- The release body (`branch:` and `commit:`) is not signed. A person with
  write access to the repository can make a release that points a channel
  to an older signed build, or to a signed build of an other branch. The
  signature stops unsigned code, but it does not stop a downgrade or a
  build from an other branch. The check after the installation uses the
  same unsigned commit value.
- `C:\ProgramData\ApolloUpdate` is owned by Administrators. Users can only
  read and execute. Thus a normal user cannot change the script that SYSTEM
  runs.
- The task security descriptor lets Authenticated Users run the task, but
  not change it. A user can only start the fixed command. A user cannot
  give parameters.
- `C:\ApolloBackup` gets a protected ACL for SYSTEM and Administrators at
  each run, with owner Administrators. The backups have the credentials
  (private key of the host) and the zip is extracted as SYSTEM on a
  restore, so a normal user must not read or change them. This also applies
  to old manual backups in `C:\ApolloBackup`. `C:\ApolloBackup\update` also
  gives Users read access, for the log.
- The updater keeps `Apollo.exe` open without write or delete share from
  the hash check until the installer stops.
- The updater accepts only asset URLs that start with
  `https://github.com/catapultam/apollo-microphone/releases/download/`.
