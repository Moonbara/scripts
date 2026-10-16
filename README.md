# scripts

Small automation scripts and guides from my sysadmin studies and homelab. The main project is [`zabbix/zabbix-setup.sh`](zabbix/zabbix-setup.sh) (version 1.1.1). It sets up the **server side** of Zabbix 8.0 LTS on Ubuntu 26.04, either on one VM or split between a database server and an app/web server. It installs MySQL, the Zabbix server, the Apache + PHP-FPM frontend and Zabbix Agent 2, then checks the result. The Windows 11 agent stays **manual**: the script ends by printing the exact values to type on Windows and in the web UI.

| Folder | What it is |
|---|---|
| [`zabbix/`](zabbix/) | Zabbix 8.0 LTS server setup on Ubuntu 26.04 (single VM, or database + app on two VMs), with a manual guide for the Windows 11 agent |

## Requirements

- Ubuntu **26.04** (any other version needs `--force`)
- Root or `sudo`
- Internet access to the Ubuntu archive and to `repo.zabbix.com`
- At least 5 GB free on `/var`; 2 GB RAM recommended (less only gives a warning)
- Two-VM setup: the app server must reach the database server on the MySQL port (default `8090`)
- Optional: `whiptail` for dialogs. Without it, or with `--no-dialog`, the script uses plain text prompts.

## Quick start

Start it in one line on each Ubuntu server:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh)"
```

To pass options, put them after a `_` placeholder:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh)" _ --mode db
```

Or download it, read it, then run the local copy:

```bash
sudo apt install curl -y
curl -fsSLO https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh
less zabbix-setup.sh
chmod +x zabbix-setup.sh
sudo ./zabbix-setup.sh
```

> **Read the script before running it as root.** Piping a script from the internet into a root shell runs whatever that URL serves at that moment. To pin an exact version, replace `main` in the URL with a tag or a commit hash, for example the release tag `zabbix-v1.1.1`:
>
> ```bash
> sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/zabbix-v1.1.1/zabbix/zabbix-setup.sh)"
> ```

With no options, a menu asks which role the machine has: **1** single VM, **2** database server (run it first), **3** app/web server (run it second). Output files are written to the current directory.

## Options

| Option | Purpose |
|---|---|
| `--mode single\|db\|app` | Skip the menu |
| `--dry-run` | Print every command and file edit, numbered like the guide, and change nothing. Saves them to `./zabbix-manual-steps.txt`. No password is needed |
| `--verify` | Health check: PASS / WARN / FAIL table, exit code 1 on any FAIL |
| `--env-file PATH` | Load `ZBX_*` values from a file (default: `./zabbix-setup.env` if present) |
| `--no-env-password` | Leave the password out of the `./zabbix-setup.env` written at the end |
| `--apply-network` | Let the static-IP step apply the change (always through `netplan try`) |
| `--add-user NAME` | Create a sudo user and install an SSH public key |
| `--reset` | Drop and recreate the Zabbix database (db/single only, always asks first) |
| `--no-dialog` | Plain text prompts instead of whiptail dialogs |
| `--force` | Continue on another OS version or a role mismatch |
| `--yes`, `-y` | Accept every default, no prompts |
| `--help`, `-h` | Full list, including every value flag |

Values (`--app-ip`, `--db-ip`, `--db-port`, `--db-name`, `--db-user`, `--timezone`, and others) come from, in priority order: a **flag**, a **`ZBX_*` environment variable**, an **env file**, then a **prompt**. There is no password flag on purpose, because it would leak into shell history and `ps`. Pass the password through the hidden prompt, `--db-password-file`, `ZBX_DB_PASSWORD`, or an env file.

## Documentation

- [`zabbix/HOWTO.md`](zabbix/HOWTO.md): step-by-step usage for both scenarios, the env file, the dry run, the static IP step, the Windows agent and troubleshooting.
- [`zabbix/zabbix-3tier-setup-guide.md`](zabbix/zabbix-3tier-setup-guide.md): the manual procedure the script automates, step by step.

## Security

These generated files contain the **database password**. They are written with mode `600`:

| File | Written by |
|---|---|
| `zabbix-setup.env` and `zabbix-setup.env.bak` | every real run (password left out with `--no-env-password`) |
| `zabbix-handoff.txt` | database server (`--mode db`) |
| `zabbix-next-steps.txt` | app server and single VM |

**Never commit them.** They are listed in [`.gitignore`](.gitignore), and the script warns when it runs inside a git repository where they are not ignored. The log (`/var/log/zabbix-setup.log`) and `zabbix-manual-steps.txt` never contain the password.

Backups of every edited config file go to `/var/backups/zabbix-setup/<timestamp>/`. The copy of `zabbix_server.conf` there holds the password, so the folder is created with mode `700` and every backed-up file is set to `600`. A run of 1.1.1 also tightens backups left by an older version (`755` folders, `644` files).

## Disclaimer

For learning and personal use, at your own risk. Test on a throwaway VM (or take a snapshot) first.
