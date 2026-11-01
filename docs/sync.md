# Sync

Keep the **Password Store**, **Agent history** (WispTerm Agent / Copilot
conversations), **SSH hosts** and **AI profiles** the same on several computers
through a drive you already have: any WebDAV service (坚果云 / Jianguoyun,
Nextcloud, ownCloud, Synology, InfiniCloud, …) or a folder that a drive client
syncs (OneDrive, iCloud Drive, Dropbox, the 坚果云 client).

Everything is **end-to-end encrypted** on your computer before it leaves it. The
drive only ever sees ciphertext; without your sync passphrase nobody (including
the drive operator) can read your passwords, API keys or conversations.

## Set up

Open the Command Center (`Ctrl+Shift+P`, `Cmd+Shift+P` on macOS) → **Sync**.

1. **Connection**
   - **Storage**: *WebDAV* or *Synced folder*.
   - WebDAV: the **WebDAV URL** (坚果云: `https://dav.jianguoyun.com/dav/`),
     your **Username**, and a **Password**. 坚果云 needs an *app password*
     (账户信息 → 安全选项 → 第三方应用管理), not your login password.
     **Remote folder** (default `WispTerm`) is created on the first sync.
   - Synced folder: the full path of a folder inside your drive, for example
     `D:\OneDrive\WispTerm` or
     `~/Library/Mobile Documents/com~apple~CloudDocs/WispTerm`.
   - **Sync passphrase**: at least 8 characters. Enter it last; WispTerm then
     unlocks (or, on an empty drive folder, initializes) the drive and runs the
     first sync.
2. **What to sync**: turn each kind on or off, and pick **Automatic sync**
   (off, 5, 15, 30 or 60 minutes).
3. **Status**: **Sync now**, the last result, and **Forget on this computer**.

On every other computer, enter the **same drive and the same passphrase**.

The Command Center also has **Sync Now** to run a sync without opening the page.

## When it syncs

- a few seconds after launch,
- every *Automatic sync* interval,
- about a minute after you change a password, SSH host or AI profile,
- whenever you choose **Sync now**.

With *Automatic sync* off, only **Sync now** runs.

## How changes merge

Each kind is merged **item by item**: a password entry (by name), an SSH host
or AI profile (by name), an agent-history session (by id).

- An item changed on one computer replaces the older copy everywhere.
- If the same item changed on two computers between syncs, the newer change
  wins (by modification time).
- Deletions travel too. An item deleted on one computer is deleted on the
  others, unless it was edited somewhere else after it was deleted.
- If a local file disappears (a fresh install, a deleted file), the next sync
  restores it from the drive instead of deleting everything.

## Security

- The sync key is derived from the passphrase with **Argon2id**; every file is
  sealed with **XChaCha20-Poly1305** and bound to its file name, so a file that
  was tampered with, renamed or written with another passphrase fails to open.
- The passphrase is never stored. This computer keeps only the derived key, and
  that key and the WebDAV password are sealed with the same OS-held key as the
  Password Store (login Keychain on macOS, DPAPI on Windows).
- Password Store secrets are decrypted only inside a sync run and re-encrypted
  with each computer's own key when they arrive.
- The drive holds `wispterm-sync.json` (format, Argon2id salt and parameters,
  and a sealed check value; no data), `passwords.wsync`, `ssh_hosts.wsync`,
  `ai_profiles.wsync`, `history.wsync`, and one `history/<hash>.wsync` file per
  session.

There is no way to recover data from the drive without the passphrase. To
change the passphrase, sync into a new remote folder (or an empty synced
folder) with the new one.

## Files on this computer

Sync keeps its state in `sync/` inside the config directory
(`%APPDATA%\wispterm\sync` on Windows,
`~/Library/Application Support/wispterm/sync` on macOS): `settings.json` (drive,
kinds, interval, and the sealed password and key) and one `base-<kind>.json` per
kind (what this computer last agreed on with the drive; names and hashes only).
**Forget on this computer** deletes this folder; your data and the drive are
not touched.

## Troubleshooting

| Status | What to do |
|---|---|
| The drive rejected the login (401/403) | Check the username; for 坚果云 create an app password. |
| The passphrase does not match | Use the passphrase the drive folder was first set up with. |
| Could not reach the drive | Check the network, proxy, or the WebDAV URL. |
| A file on the drive could not be decrypted | Another passphrase was used for this folder, or a file was damaged. |
| The sync folder was not found | Mount/sign in to the drive client, or fix the path. |
| A file changed while syncing | Nothing to do; the next sync merges it. |

Ghostty has no settings or data sync, so this feature has no Ghostty
counterpart; it reuses WispTerm's own Password Store encryption and workbench
page conventions.
