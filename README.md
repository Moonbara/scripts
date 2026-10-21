# scripts

Small automation scripts and guides from my sysadmin studies and homelab. The main project is [`zabbix/zabbix-setup.sh`](zabbix/zabbix-setup.sh) (version 1.4.0). It sets up the **server side** of Zabbix 8.0 LTS on Ubuntu 26.04, either on one VM or split between a database server and an app/web server. It installs MySQL, the Zabbix server, the Apache + PHP-FPM frontend and (optionally) Zabbix Agent 2 on each server, then checks the result. The Windows 11 agent stays **manual**: the script ends by printing the exact values to type on Windows and in the web UI.

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
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh) "$@"' _
```

To pass options, put them after the `_` placeholder:

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh) "$@"' _ --mode db --verbose
```

> The older form `sudo bash -c "$(curl -fsSL URL)"` no longer works: Linux refuses a single argument over 128 KiB ("Argument list too long"), and the script is bigger than that since version 1.2.0. The form above reads the script through a pipe, so its size does not matter, and your terminal stays connected for the questions.
>
> Do **not** shorten it to `sudo bash <(curl -fsSL URL)`: sudo closes every file descriptor above 2, so the root bash cannot open `/dev/fd/63` ("No such file or directory"). Two other forms work:
>
> ```bash
> sudo -i                                  # a root shell first, then the short form works
> bash <(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh) --mode db
> ```
>
> or download and run (below).

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
> sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/zabbix-v1.1.1/zabbix/zabbix-setup.sh) "$@"' _
> ```

With no options, a menu asks which role the machine has: **1** single VM, **2** database server (run it first), **3** app/web server (run it second). Output files are written to the current directory.

## What a run looks like

Each step is one line, numbered like the guide. While a step runs, its line shows `[✗]` (not finished yet) and a spinner. When it ends, the line turns into a green `[✓]` with its duration, or a yellow `[-]` when there was nothing to do:

```text
==================== Part 1 - Database node ====================
( 4/19) [✓] 1.1 Install MySQL (14s)
( 5/19) [-] 1.2 Remote access / custom port (skipped: single VM uses the local socket)
( 6/19) [-] 1.3 Open the firewall for MySQL (skipped: single VM: MySQL is only used locally)
( 7/19) [✓] 1.4 Create the database and user (CREATE USER before GRANT - MySQL 8) (0s)
( 8/19) [✗] 1.5 Verify the zabbix user can log in (local socket)... ⠹
```

- **Where the output goes:** everything the commands print (apt, mysql, systemctl…) goes to `/var/log/zabbix-setup.log` only, never with the password. Warnings still show under their step.
- **When a step fails:** its line stays a red `[✗]`, followed by the step's last 15 lines of output, the error with its fix, and the log path.
- **At the end:** a list of every step with the total time, the verification table, the hand-off or NEXT STEPS block, and last of all a boxed **REMEMBER: ZABBIX WEB WIZARD** block with the values the web wizard asks for (see [below](#the-firewall-and-the-wizard-reminder)).
- **Verbose:** the script asks "Show detailed output (verbose)?" (default no). Yes, `--verbose` / `-v` or `ZBX_VERBOSE=yes`: every command is printed as `$ ...`, with its live output indented underneath.
- **No terminal:** when the output is piped or captured, you get plain `[..]` / `[OK]` / `[FAIL]` lines with no escape codes. `NO_COLOR=1` or `TERM=dumb` turn off colours and the redraw. A non-UTF-8 locale gets ASCII markers: `[ ]` running, `[v]` done, `[x]` failed.

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
| `--agent` / `--no-agent` | Install Zabbix Agent 2 on this server, or not (all modes, default: yes; see below) |
| `--agent-hostname NAME` | `Hostname=` of that agent, and the host name to use in the web UI |
| `--verbose`, `-v` | Show every command (`$ ...`) and its live output under each step, instead of one line per step. Without it the script asks; also `ZBX_VERBOSE=yes\|no` |
| `--ssh-port N` | SSH port to allow in ufw (also `ZBX_SSH_PORT`). Needed when no SSH port can be detected; otherwise ufw is not enabled |
| `--no-ufw` | Do not enable the ufw firewall (also `ZBX_ENABLE_UFW=no`). Rules are then only added if ufw is already active |
| `--force` | Continue on another OS version or a role mismatch |
| `--yes`, `-y` | Accept every default, no prompts |
| `--help`, `-h` | Full list, including every value flag |

Values (`--app-ip`, `--db-ip`, `--db-port`, `--db-name`, `--db-user`, `--timezone`, and others) come from, in priority order: a **flag**, a **`ZBX_*` environment variable**, an **env file**, then a **prompt**. There is no password flag on purpose, because it would leak into shell history and `ps`. Pass the password through the hidden prompt, `--db-password-file`, `ZBX_DB_PASSWORD`, or an env file.

**Agent 2 on the servers.** In every mode the script asks whether to install Zabbix Agent 2 on the machine it runs on. The default is yes; the keys are `ZBX_INSTALL_AGENT=yes|no` and `ZBX_AGENT_HOSTNAME`.

- **App/single:** the agent monitors the Zabbix server machine itself, through the built-in "Zabbix server" host. Its `Hostname=` stays `Zabbix server` unless you pass `--agent-hostname`. Answer no, and that built-in host shows its agent as unavailable: disable it or ignore it.
- **Database server:** the script adds the Zabbix repository and installs **only** `zabbix-agent2`, never a server or frontend package. It sets `Server=`/`ServerActive=` to the app server and `Hostname=` to the short hostname (or `--agent-hostname`). Port 10050 is allowed for the app server only, in the firewall step. The hand-off block then tells you how to add this server in the web UI ("Linux servers", template "Linux by Zabbix agent").

A "no" never removes an agent that is already installed. The Windows PC's agent is always a separate, manual install.

## The firewall and the wizard reminder

**The script enables `ufw`.** The firewall step (step 1.3 on the database server, 2.7a on the app server and the single VM) first lists the exact rules and asks **"Enable the ufw firewall with these rules?"** (default yes). With yes it:

1. installs `ufw` if needed;
2. allows **SSH first**, on the port sshd really uses (`sshd -T`, else `ss -ltnp`, else `sshd_config`), so you cannot lock yourself out. If no SSH port can be found, ufw is **not** enabled, not even with `--force`, unless you name the port with `--ssh-port N` (or `ZBX_SSH_PORT`);
3. allows the role's ports: the database server `<DB_PORT>` and, with the agent, `10050`, **only from `<APP_IP>`**. The app server and single VM get `80/tcp` and `10051/tcp`, the latter only from the Windows IP when you gave one;
4. sets `default deny incoming` / `default allow outgoing` and runs `ufw --force enable`.

Every rule carries the comment `zabbix-setup`. A rule that already exists without that comment (yours, or from a version before 1.4.0) is left untouched and reported as "already present (not managed by the script)". A re-run never duplicates rules, and when the DB port or an IP changes, only the old `zabbix-setup` rules are replaced. Your own rules are kept (no `ufw reset`). If ufw is already active, only missing rules are added. `--no-ufw` or `ZBX_ENABLE_UFW=no` keep the old behaviour. `--verify` checks that ufw is on with the SSH rule and the role's rules. Changing the firewall over SSH can cut the connection: the SSH rule always goes first. The SSH configuration itself is never changed.

**The last thing every run prints** is the wizard reminder. It is also saved at the end of `zabbix-next-steps.txt`, and commented out at the end of `zabbix-handoff.txt`, both mode 600:

```text
+=========================================================================+
|  REMEMBER: ZABBIX WEB WIZARD    http://<APP_IP>/zabbix
+=========================================================================+
|  DATABASE HOST = THE HOSTNAME/IP OF THE DATABASE SERVER. NOT LOCALHOST, NOT THE ZABBIX SERVER.
|
|  Database type   MySQL
|  Database host   <DB_IP>
|                  (this database server's name is <name> - the name only works if the web server can resolve it (DNS or /etc/hosts), otherwise use the IP)
|  Database port   <DB_PORT>      (type it explicitly - 0 means 3306 and the test would fail)
|  Database name   zabbix
|  User            zabbix
|  Password        <password>
|  ...
|  After the wizard, log in to the Zabbix website with Admin / zabbix, and
|  change that password immediately (Users > Admin).
```

This is the only place the database password is printed. The hand-off and NEXT STEPS blocks shown above it no longer contain it, and the log never does. On a single VM, the block says to type `localhost` (socket, port `0`), or `127.0.0.1` with a custom port.

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

Backups of every edited config file go to `/var/backups/zabbix-setup/<timestamp>/`. The copy of `zabbix_server.conf` there holds the password, so the folder is created with mode `700` and every backed-up file is set to `600`. Since 1.1.1, a run also tightens backups left by an older version (`755` folders, `644` files).

## Disclaimer

For learning and personal use, at your own risk. Test on a throwaway VM (or take a snapshot) first.
