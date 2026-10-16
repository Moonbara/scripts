# zabbix-setup.sh: how to use it

Step-by-step usage of [`zabbix-setup.sh`](zabbix-setup.sh) version 1.1.1: Zabbix 8.0 LTS server side on Ubuntu 26.04. The manual procedure it automates is in [`zabbix-3tier-setup-guide.md`](zabbix-3tier-setup-guide.md).

## Contents

1. [Before you start](#1-before-you-start)
2. [Choosing a scenario](#2-choosing-a-scenario)
3. [Scenario A: single VM](#3-scenario-a-single-vm)
4. [Scenario B: two VMs](#4-scenario-b-two-vms)
5. [Using the env file](#5-using-the-env-file)
6. [Dry run](#6-dry-run)
7. [Static IP](#7-static-ip)
8. [Finishing on Windows 11 (manual)](#8-finishing-on-windows-11-manual)
9. [Day-to-day](#9-day-to-day)
10. [Troubleshooting](#10-troubleshooting)
11. [Files the script creates](#11-files-the-script-creates)
12. [Exam tip](#12-exam-tip)

---

## 1. Before you start

You need:

- **One or two VMs** with Ubuntu **26.04**. On any other version the script stops unless you add `--force`.
- **Root access** (`sudo`).
- **Internet access** to the Ubuntu archive and `repo.zabbix.com`.
- **At least 5 GB free on `/var`**. 2 GB RAM is recommended; less only gives a warning.
- **A Windows 11 machine** for the agent (Part 3, done by hand).
- **Your IPs written down** before you start:

| Placeholder | What it is |
|---|---|
| `<APP_IP>` | the Zabbix app/web server (or the single VM) |
| `<DB_IP>` | the MySQL server (two-VM setup only) |
| `<DB_PORT>` | the MySQL port, default `8090` (two-VM setup) |
| `<WIN_IP>`, `<WIN_HOSTNAME>` | the Windows 11 machine |

> **Tip:** take a VM snapshot before the first run. If something goes wrong, you can roll back and try again in a minute.

Get the script on each server: either run it in one line (the commands below use this form), or download it first and run `sudo ./zabbix-setup.sh` instead.

```bash
# one line
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh)" _ --mode single

# or download, read, run
curl -fsSLO https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh
less zabbix-setup.sh
chmod +x zabbix-setup.sh
sudo ./zabbix-setup.sh --mode single
```

Read the script before you run it as root. To pin a version, replace `main` in the URL with a tag or a commit hash, for example `.../Moonbara/scripts/zabbix-v1.1.1/zabbix/zabbix-setup.sh`. The rest of this page uses `sudo ./zabbix-setup.sh`.

**Run it from the directory where you want the output files.** The hand-off, env file and next-steps file are written to the current directory.

**Dialogs.** On a terminal with `whiptail`, questions are dialog boxes:

- **Enter** accepts.
- **Tab** moves between the buttons.
- **Esc** or **Cancel** stops with "nothing was changed".
- Text you type in an input box is **added to** the pre-filled default, so press Backspace first if you want to replace it.

Add `--no-dialog` for plain text prompts.

---

## 2. Choosing a scenario

| Scenario | Menu | Use it when |
|---|---|---|
| Single VM | `1` / `--mode single` | You have one VM, or you just want Zabbix running. MySQL and Zabbix share the machine, and MySQL uses the local socket by default. |
| Two VMs: database | `2` / `--mode db` | Your lab or exam asks for a separate database server. Run it **first**, on the MySQL machine. |
| Two VMs: app/web | `3` / `--mode app` | The second half of the two-VM setup. Run it **second**, on the Zabbix machine. |

Pick the option that matches **this** machine. The script stops early if you get it wrong. For example, it stops on db mode on a machine that already has zabbix-server, or on an app server IP that belongs to the machine itself.

---

## 3. Scenario A: single VM

```bash
sudo ./zabbix-setup.sh --mode single
```

The script asks, in this order:

1. **Does this server already have a static IP?** The default is "yes" when the address is not a DHCP lease. See [Static IP](#7-static-ip).
2. **This server's IP (APP_IP)**: pre-filled with the detected address.
3. **Use the default MySQL setup (local socket, port 0 in the wizard)?** Answer **yes** unless you were told to use a port. If you answer no, the next question is **Custom MySQL port**, and Zabbix will then connect over TCP to `127.0.0.1:<port>`.
4. **Database name** and **Database user**: both default to `zabbix`.
5. **DB password (press Enter to generate one)**: typed twice, or Enter for a random 20-character password.
6. **Timezone**: default `America/Toronto`.
7. **Windows host name / Windows IP**: optional, only used to fill in the printed Windows steps.
8. **Summary**: check it, then confirm. Nothing changes before this point.

What you should see next:

- A preflight table: OS, disk, RAM, the repository, ports.
- The guide's steps running in order: `Step 0.4`, `Step 1.1` … `Step 2.7a`.
- A verification table.
- A **NEXT STEPS** block with the web wizard values and the password. The password is shown once and saved to `zabbix-next-steps.txt`.

Check it worked, now or any time later:

```bash
sudo ./zabbix-setup.sh --verify
```

Expected last line:

```text
  Result: all checks passed (0 WARN)
```

Then open `http://<APP_IP>/zabbix`. The wizard's Database host is `localhost` with port `0` (or `127.0.0.1` with your custom port). Log in as `Admin` / `zabbix` and **change that password immediately**.

---

## 4. Scenario B: two VMs

Follow this exact order:

1. **The database server goes first.** It creates the database and the `zabbix` user, which may only connect from `<APP_IP>`.
2. **Then the app server**, which needs MySQL to answer on `<DB_IP>:<DB_PORT>`. If it does not, the script stops before changing anything.
3. **Back to the database server last.** The schema import needs `log_bin_trust_function_creators = 1`. Only the database server can set it back to `0`, because the `zabbix` account is not allowed to.

### Step 1: database server

```bash
sudo ./zabbix-setup.sh --mode db --app-ip <APP_IP>
```

It asks for the static IP, the **Database port?** (default `8090`), the database name and user, the password and the timezone. Then it:

- installs MySQL
- sets `bind-address = 0.0.0.0` and `port = <DB_PORT>`
- opens the port in `ufw`, but only if `ufw` is already active and only from `<APP_IP>`
- creates the database and the user `'zabbix'@'<APP_IP>'`

The verification ends with two expected warnings: the database is still empty, and `log_bin_trust_function_creators` is still `1`. A third WARN about chrony is harmless if time sync has not settled yet. Then it prints the **hand-off** block and saves it as `zabbix-handoff.txt`:

```text
# ###########################################################################
#  zabbix-setup hand-off - values for the APP server  (...)
#  This file is an env file: load it with --env-file. Keep it chmod 600.
# ###########################################################################
ZBX_MODE='app'
ZBX_APP_IP='<APP_IP>'
ZBX_DB_IP='<DB_IP>'
ZBX_DB_PORT='8090'
...
ZBX_DB_PASSWORD='<password>'
```

### Step 2: copy the hand-off to the app server

```bash
scp zabbix-handoff.txt <user>@<APP_IP>:~/
```

The file belongs to your sudo user with mode `600`, so a normal `scp` works.

### Step 3: app server

Go to the directory that holds `zabbix-handoff.txt`, then:

```bash
cd ~
sudo ./zabbix-setup.sh --mode app --env-file ./zabbix-handoff.txt
```

- All database values, the password included, come from the file. Each one is shown as `(from env file ./zabbix-handoff.txt)`, and the password is never asked.
- It still asks the static IP question, the optional Windows fields and the summary.
- It tests the TCP port and the MySQL login, imports the schema (1–2 minutes), configures zabbix-server, Apache, PHP and the locale, then starts the services.

At the end you usually see this, followed by the NEXT STEPS block:

```text
WARNING: ACTION ON THE DB SERVER (<DB_IP>): the zabbix account may not change global settings. Run there:
```

That NEXT STEPS block starts with step **0**, which is step 4 below.

### Step 4: back on the database server

Run it in the same directory as step 1:

```bash
sudo ./zabbix-setup.sh --mode db --yes
```

It reloads its own `./zabbix-setup.env`, sees the imported schema and prints:

```text
OK: schema already imported - log_bin_trust_function_creators is back to 0 (guide Part 2 step 3)
```

The schema and trust-flag warnings from step 1 are gone now. Delete `zabbix-handoff.txt` on both servers once you are done.

In the web wizard on `http://<APP_IP>/zabbix`, the Database host is `<DB_IP>`, and the port must be typed as `<DB_PORT>`. **Do not leave it at 0.**

---

## 5. Using the env file

An env file holds settings as `ZBX_NAME=value` lines:

```bash
# zabbix-setup.env
ZBX_MODE=app
ZBX_APP_IP=<APP_IP>
ZBX_DB_IP=<DB_IP>
ZBX_DB_PORT=8090
ZBX_DB_PASSWORD='<password>'
```

- **Format:**
  - An optional `export ` and optional `'...'` or `"..."` around the value. Only that outer pair of quotes is removed.
  - Lines starting with `#` and blank lines are ignored.
  - The file is **parsed, never sourced**: `$variables`, `$(commands)` and escapes are taken literally.
  - An unknown key gives a warning. A duplicated key, a malformed line or an invalid value stops the run and names the line number.
- **Keys:** `ZBX_MODE`, `ZBX_APP_IP`, `ZBX_DB_IP`, `ZBX_DB_PORT`, `ZBX_DB_NAME`, `ZBX_DB_USER`, `ZBX_DB_PASSWORD`, `ZBX_TIMEZONE`, `ZBX_WIN_HOSTNAME`, `ZBX_WIN_IP`, `ZBX_IFACE`, `ZBX_STATIC_IP`, `ZBX_PREFIX`, `ZBX_GATEWAY`, `ZBX_DNS`, `ZBX_SSH_KEY_FILE`.
- **Priority:** flag > `ZBX_*` environment variable > env file > prompt.
- **Loading:** `--env-file PATH`. Without that flag, `./zabbix-setup.env` is loaded automatically if it exists, and the script says so.
- **Writing:** every real run (not `--dry-run`) writes `./zabbix-setup.env` with the settings it used, and keeps the previous copy as `zabbix-setup.env.bak`. Add `--no-env-password` to leave the password out.
- **Security:** keep it `chmod 600`; the script warns if group or others can read it. **Never commit it**: the script warns when you run it inside a git repository where it is not ignored.

The same goes for the environment: export `ZBX_DB_PASSWORD` and pass it through with `sudo --preserve-env=ZBX_DB_PASSWORD ./zabbix-setup.sh ...`. The old `DB_PASSWORD` variable still works, but prints a deprecation warning.

---

## 6. Dry run

`--dry-run` prints every command and file edit the chosen scenario would perform, numbered with the guide's step numbers, and **changes nothing**. It needs no root and no password:

```bash
./zabbix-setup.sh --dry-run --mode db
./zabbix-setup.sh --dry-run --mode app --yes      # missing values become placeholders like <DB_IP>
```

Sample output:

```text
--- Step 1.2: Allow remote connections and set port 8090
  [1.2.1] $ sudo mkdir -p /var/backups/zabbix-setup/... && sudo cp -a /etc/mysql/mysql.conf.d/mysqld.cnf ...
  [1.2.2] edit /etc/mysql/mysql.conf.d/mysqld.cnf under [mysqld]:  bind-address = 0.0.0.0
  [1.2.3] edit /etc/mysql/mysql.conf.d/mysqld.cnf under [mysqld]:  port = 8090
  [1.2.4] $ sudo systemctl restart mysql
```

Everything it prints is also saved to **`zabbix-manual-steps.txt`**, with the password masked as `********`. Use it as a study sheet for the scenario you chose.

---

## 7. Static IP

The Windows agent and the MySQL user are tied to the server's IP, so the address must not change. The questions:

1. **Does this server already have a static IP?** If you answer **yes**, it confirms the detected address and changes nothing.
2. If you answer **no**: **Configure a static IP now with netplan? (n = skip and continue)**. Saying yes asks for the interface, IP, prefix length, gateway and DNS, each pre-filled with what was detected.
3. In step 0.3: **Apply this static IP now?** (default no).

When applied, the script:

- backs up `/etc/netplan/*.yaml`
- writes `/etc/netplan/99-zabbix-static.yaml` (mode 600)
- runs `netplan try --timeout 120`: press **Enter** within 120 s to keep it, otherwise it rolls back by itself

The script never runs a bare `netplan apply`.

**Flags:** `--static-ip IP` selects "configure" without asking. `--iface`, `--prefix`, `--gateway` and `--dns IP[,IP]` override the detected values; anything you leave out is detected.

**`--apply-network`** is the explicit opt-in. Without it, `--yes` never touches the network: it only prints the YAML that would be written, plus a reminder.

```bash
sudo ./zabbix-setup.sh --mode db --app-ip <APP_IP> --static-ip <DB_IP> --apply-network
```

`netplan try` needs a terminal to confirm. **Run it from the VM console the first time.** Over SSH, changing the address drops your session, you cannot press Enter, and the change rolls back.

---

## 8. Finishing on Windows 11 (manual)

The NEXT STEPS block (also in `zabbix-next-steps.txt`) has these steps with your real values filled in.

1. **Install Zabbix Agent 2.** Download it from <https://www.zabbix.com/download_agents>: choose Zabbix 8.0 LTS, Windows, amd64, OpenSSL, MSI, and run the installer.
2. **Configure it**, either in the installer or in `C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf`:

   ```ini
   Hostname=<WIN_HOSTNAME>
   Server=<APP_IP>
   ServerActive=<APP_IP>
   ```

3. **Open the firewall** and restart the service (PowerShell as Administrator):

   ```powershell
   New-NetFirewallRule -DisplayName "Zabbix Agent Port 10050" -Direction Inbound -Protocol TCP -LocalPort 10050 -Action Allow
   Restart-Service "Zabbix Agent 2"
   ```

4. **Add the host** in the web UI under *Data collection > Hosts > Create host*:
   - **Host name:** `<WIN_HOSTNAME>`, exactly as in `Hostname=` (case-sensitive).
   - **Host groups:** pick one or type a new one.
   - **Interfaces:** *Add > Agent*, IP `<WIN_IP>`, port `10050`. The template needs an Agent interface even for active checks.
   - **Templates:** `Windows by Zabbix agent`.
5. **Verify.** On Windows, `Test-NetConnection <APP_IP> -Port 10051` should report `TcpTestSucceeded : True`. In the web UI, *Monitoring > Latest data*, filtered on `<WIN_HOSTNAME>`, should show CPU, memory and disk within a few minutes. The agent log is `C:\Program Files\Zabbix Agent 2\zabbix_agent2.log`.

---

## 9. Day-to-day

- **Re-running is safe.**
  - Existing users, databases, the repository and config lines are reused, never duplicated.
  - An imported schema is skipped.
  - MySQL is restarted only when its bind-address or port changes.
  - At the password prompt, **Enter keeps the current password**.
  - A re-run in the same directory reloads `./zabbix-setup.env`.
- **`--verify`** prints a PASS / WARN / FAIL table and exits with code 1 if anything fails. Every FAIL comes with a one-line `fix:`. It reads the machine's role from `/etc/zabbix-setup.state`. If that file is missing, it works the role out from the installed packages.
- **`--reset`** is the **only destructive option**. It drops and recreates the Zabbix database, on the db or single machine only (app mode refuses).
  - It always asks first, even with `--yes`: a yes/no in dialog mode, then you must **type the database name**.
  - On the db server, stop zabbix-server on the app server first, then re-run app mode to import the schema again. A single VM stops zabbix-server and re-imports on its own.
- **`--add-user NAME`** creates a sudo user:
  - It installs an SSH public key, from `--ssh-key-file` or pasted at the prompt, with `~/.ssh` at 700 and `authorized_keys` at 600.
  - It offers to set a password, which `sudo` needs.
  - Used alone it does only that; with `--mode` it runs as step 0.2.
  - SSH configuration is never changed.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| App mode stops: `DB server <DB_IP>:<DB_PORT> answers ... no TCP answer within 3 s`, or `ERROR 2003` connection refused | db mode not run yet, MySQL down, `bind-address` still `127.0.0.1`, or `ufw` blocking the port | On the DB server: run db mode, `sudo systemctl status mysql`, check `/etc/mysql/mysql.conf.d/mysqld.cnf`, `sudo ufw status` |
| Same error, but the DB server looks fine | **Port mismatch:** the app side uses another `--db-port` than the DB side | `sudo ss -ltn \| grep mysqld` on the DB server. Use the port from `zabbix-handoff.txt` (`--env-file` does this for you) |
| `ERROR 1130 Host not allowed` or `ERROR 1045 Access denied` | User created for another app IP, or wrong password | Re-run db mode with `--app-ip <APP_IP>`; reuse the hand-off password |
| Preflight: `repo.zabbix.com reachable ... HTTP 404` | Wrong repository path or Ubuntu version | The URL must contain `/release/` (`zabbix/8.0/release/ubuntu/...`); use Ubuntu 26.04 |
| Web wizard cannot connect, but `mysql -h <DB_IP> -P <DB_PORT>` works | Database port left at `0`, which means 3306 | Type `<DB_PORT>` in the wizard. Single VM with a custom port: host `127.0.0.1` plus that port |
| Host is grey / "unknown", no data | Host name mismatch, firewall, or agent not restarted | Host name must match `Hostname=` exactly; check `zabbix_agent2.log`; `Test-NetConnection <APP_IP> -Port 10051`; restart "Zabbix Agent 2" |
| Saving the host fails with `Cannot inherit item with key "agent.hostname" of template "Windows by Zabbix agent" to host "<name>", because a host interface of type "Agent" is required.` (as seen on Zabbix 8.0; the wording may differ slightly between versions) | Template linked, but the host has no Agent interface | *Interfaces > Add > Agent*, `<WIN_IP>` port `10050`, then save again |
| A re-run pauses about 60 s at step 2.7, then `zabbix-server did not stop within 60 s` | Port or DB IP changed. The old process flushes its cache to a database it can no longer reach | Expected: the script kills it and continues. Unsent history is lost |
| Wizard: `Locale for language "en_US" is not found` | Locale missing, or PHP-FPM not restarted | `sudo locale-gen en_US.UTF-8 && sudo systemctl restart php8.5-fpm` |
| Password rejected: `no space at the start or end` | Leading or trailing space (Zabbix trims it in `zabbix_server.conf`) | Remove it; spaces inside are fine |
| Password rejected: `control characters (tab, newline...) are not supported` / `at least 8 characters` | Tab, other control character, or too short | 8–128 printable characters; anything else, including `' " $ # \ & !`, works |

---

## 11. Files the script creates

| File | Where | Password? |
|---|---|---|
| Log | `/var/log/zabbix-setup.log` (mode 600) | No (masked) |
| Backups of every edited config | `/var/backups/zabbix-setup/<timestamp>/` (folder 700, files 600) | Yes for the copy of `zabbix_server.conf` |
| State (role and non-secret settings, read by `--verify`) | `/etc/zabbix-setup.state` (600) | No |
| Zabbix server config (`DBPassword=`) | `/etc/zabbix/zabbix_server.conf` | Yes (package's own permissions) |
| Hand-off (db mode) | `./zabbix-handoff.txt` (600) | **Yes** |
| Next steps (app/single) | `./zabbix-next-steps.txt` (600) | **Yes** |
| Env file and previous copy | `./zabbix-setup.env`, `./zabbix-setup.env.bak` (600) | **Yes**, unless `--no-env-password` |
| Manual steps (`--dry-run`) | `./zabbix-manual-steps.txt` | No (masked) |
| Static IP (only when applied) | `/etc/netplan/99-zabbix-static.yaml` (600) | No |

`./` means the directory you ran the script from. Never commit the files marked **Yes**.

---

## 12. Exam tip

The script is a helper, not a replacement for knowing the steps. The full manual procedure is in [`zabbix-3tier-setup-guide.md`](zabbix-3tier-setup-guide.md), and the script prints the same step numbers. To get the exact commands for the scenario you were given, without a VM:

```bash
./zabbix-setup.sh --dry-run --mode single      # or --mode db / --mode app
```

Then study `zabbix-manual-steps.txt`.
