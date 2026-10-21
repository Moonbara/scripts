# Zabbix 8.0 LTS — 3-Tier Setup Guide (Ubuntu 26.04 + Remote MySQL + Windows 11)

Dedicated 3-tier deployment: a separate App/Web node, a remote MySQL Database node, and a monitored Windows 11 agent host — monitoring CPU, RAM, and storage.

## Variables used in this guide

Fill these in for your environment, then swap them into the commands below.

| Placeholder | Meaning | Example |
|---|---|---|
| `<APP_HOSTNAME>` | Hostname of the App/Web server (a label only: no command uses it, and the script never asks for it) | `capyserver` |
| `<APP_IP>` | IP of the App/Web server | `10.4.0.68` |
| `<DB_IP>` | IP of the remote MySQL server | `10.4.0.79` |
| `<DB_PORT>` | Port MySQL listens on (non-default) | `8090` |
| `<DB_PASSWORD>` | Password for the `zabbix` MySQL user | (choose your own, strong) |
| `<WIN_HOSTNAME>` | Hostname/Host name of the Windows agent | `CapyWin` |
| `<AGENT_HOSTNAME>` | `Hostname=` of the optional Agent 2 on the DB node (Part 1 step 6); usually its short hostname | `capydb` |
| `<WIN_IP>` | IP of the Windows 11 machine | `10.4.0.38` |

> Ubuntu 26.04 ships PHP 8.5-FPM by default rather than `mod_php`, which is why this guide's Apache setup differs from a standard 24.04 install (PHP-FPM needs Apache's proxy modules to hand off requests, instead of `php_value` directives in `apache.conf`).

> Ubuntu 26.04's `mysql-server` package installs **MySQL 8.4** (LTS), not 8.0. Every SQL statement in this guide is unchanged on 8.4; the 8.0 rules below (such as `CREATE USER` before `GRANT`) still apply.

> At the time of writing, the Zabbix 8.0 packages in the official repository may still be a **release candidate** (for example `8.0.0~rc1`). Check with `apt policy zabbix-server-mysql` after Part 2 step 1.

## Infrastructure

| Role | Hostname | IP Address | OS / Software |
|---|---|---|---|
| App & Web Server | `<APP_HOSTNAME>` | `<APP_IP>` | Ubuntu 26.04 LTS (Resolute Raccoon), Zabbix Server 8.0 LTS, Apache 2, PHP 8.5-FPM |
| Database Server | (remote DB node) | `<DB_IP>` | Ubuntu 26.04 LTS, MySQL 8.4 (Ubuntu's `mysql-server` package) |
| Monitored Client | `<WIN_HOSTNAME>` | `<WIN_IP>` | Windows 11, Zabbix Agent 2 |

## Run it (automation)

The server side of this guide (Parts 1 and 2) is automated by [`zabbix-setup.sh`](zabbix-setup.sh). Part 3 (Windows) stays manual: the script ends by printing the exact values to use. Start it in one line on each Ubuntu server:

```bash
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh) "$@"' _
# with options: put them after the "_" placeholder (it becomes $0)
sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/Moonbara/scripts/main/zabbix/zabbix-setup.sh) "$@"' _ --mode db
```

- **Not `bash -c "$(curl ...)"`.** That older form passes the whole script as one argument, and Linux refuses arguments over 128 KiB. The script is bigger than that, so the run stops with "Argument list too long".
- **Not `sudo bash <(curl ...)` either.** sudo closes the pipe `<( )` creates (`/dev/fd/63: No such file or directory`). The short form works only in a root shell: `sudo -i`, then `bash <(curl -fsSL <URL>) --mode db`.

- **Pin a version.** Replace `main` in the URL with a tag or a commit hash, for example `zabbix-v1.1.1`, so the code you run cannot change underneath you.
- **This means trusting the repository.** Piping a script from the internet into a root shell runs whatever that URL serves at that moment. Read it first, or download it and run the local copy:
  `curl -fsSLO <URL> && less zabbix-setup.sh && sudo bash zabbix-setup.sh`.
- Output files (`zabbix-handoff.txt`, `zabbix-setup.env`, `zabbix-next-steps.txt`, `zabbix-manual-steps.txt`) are written to the **current directory**.

---

## Part 1 — Database Node Setup (`<DB_IP>`)

### 1. Install MySQL
```bash
sudo apt update
sudo apt install mysql-server -y
sudo systemctl enable --now mysql
```

### 2. Allow remote connections and set a custom port
```bash
sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf
```
Under the `[mysqld]` section, set both:
```
bind-address = 0.0.0.0
port = <DB_PORT>
```
```bash
sudo systemctl restart mysql
```

### 3. Open the firewall for MySQL
Fresh Ubuntu 26.04 images often ship with `ufw` active by default, which blocks the port even after `bind-address` is fixed:
```bash
sudo ufw status
sudo ufw allow from <APP_IP> to any port <DB_PORT> proto tcp
```
(Skip this if `ufw status` shows `inactive`.)
> The rule only lets the app server in, matching the MySQL user below, which is scoped to `<APP_IP>`. A plain `ufw allow <DB_PORT>/tcp` would open the port to every host.

To turn the firewall **on** (what the script does in this step), always allow SSH first. Use the port sshd really listens on (`sudo sshd -T | grep ^port`), or you lock yourself out:
```bash
sudo apt install ufw -y
sudo ufw allow 22/tcp comment 'zabbix-setup'                                              # SSH - FIRST
sudo ufw allow from <APP_IP> to any port <DB_PORT> proto tcp comment 'zabbix-setup'
sudo ufw allow from <APP_IP> to any port 10050 proto tcp comment 'zabbix-setup'          # only with Agent 2 (step 6)
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status numbered
```
> Changing the firewall over SSH can cut the connection. With the SSH rule in place first, `ufw --force enable` keeps your session. `ufw reset` is never needed: it would throw away your own rules too.

### 4. Create the database and user
```bash
sudo mysql
```
> On Ubuntu, MySQL's `root` account logs in through the local socket (`auth_socket`): `sudo mysql` needs no password. `-u root -p` is not needed.
MySQL 8.0+ requires the user to exist before it can be granted privileges (implicit creation via `GRANT` was removed in 8.0):
```sql
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'<APP_IP>' IDENTIFIED BY '<DB_PASSWORD>';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'<APP_IP>';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EXIT;
```
> The user is scoped to `'zabbix'@'<APP_IP>'` specifically (not `'zabbix'@'%'`) — only the app server's IP can connect with this account, which is good practice for a 2-node split.

> `log_bin_trust_function_creators = 1` is only needed while the schema is imported (Part 2 step 3). It is switched back to `0` **on this DB server** afterwards: the `zabbix` account cannot change global settings, so it cannot do it from the app server.

### 5. Verify remote access works
Before moving to Part 2, test the connection **from the App server** (`<APP_IP>`), not from the DB node itself:
```bash
mysql -h <DB_IP> -P <DB_PORT> -u zabbix -p
```
If this connects, everything in Part 1 is solid and any later connection issue is a Zabbix-side config problem, not MySQL. If it refuses to connect, check in this order: MySQL is running (`sudo systemctl status mysql`), `bind-address` is `0.0.0.0` not `127.0.0.1`, `port` in `mysqld.cnf` matches `<DB_PORT>`, and `ufw` (step 3 above) isn't blocking it.

### 6. (Optional) Install Zabbix Agent 2 on the DB node
This lets the Zabbix server monitor the database server itself. Install **only** the agent here: no server or frontend packages. Use the same repository as Part 2 step 1:
```bash
wget https://repo.zabbix.com/zabbix/8.0/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu26.04_all.deb
sudo dpkg -i zabbix-release_latest+ubuntu26.04_all.deb
sudo apt update
sudo apt install zabbix-agent2 -y
```
```bash
sudo nano /etc/zabbix/zabbix_agent2.conf
```
Change the existing lines (the package ships `Server=127.0.0.1`, `ServerActive=127.0.0.1` and `Hostname=Zabbix server`) rather than adding new ones:
```ini
Server=<APP_IP>
ServerActive=<APP_IP>
Hostname=<AGENT_HOSTNAME>
```
> Do not keep `Hostname=Zabbix server`: that name belongs to the built-in host of the Zabbix server itself, and the two would clash.
```bash
sudo systemctl enable zabbix-agent2
sudo systemctl restart zabbix-agent2
sudo ufw allow from <APP_IP> to any port 10050 proto tcp comment 'zabbix-setup'    # if not already done in step 3
```
Once Part 2 is done, add it in the web UI under **Data collection → Hosts → Create host**:
- Host name: `<AGENT_HOSTNAME>` (must match `Hostname=` exactly)
- Host groups: `Linux servers`
- Interfaces: Agent, `<DB_IP>`, port `10050`
- Templates: **`Linux by Zabbix agent`**

---

## Part 2 — App & Web Server Setup (`<APP_HOSTNAME>` @ `<APP_IP>`)

### 1. Add the Zabbix repository (Ubuntu 26.04 "resolute")
```bash
wget https://repo.zabbix.com/zabbix/8.0/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu26.04_all.deb
sudo dpkg -i zabbix-release_latest+ubuntu26.04_all.deb
sudo add-apt-repository universe -y
sudo apt update
```
> Zabbix's repo path now includes a `/release/` segment (`zabbix/8.0/release/ubuntu/...`) — older guides or cached commands without it will 404.

### 2. Install Zabbix packages
```bash
sudo apt install zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2 mysql-client -y
```
> Zabbix 8.0's official examples install `zabbix-agent2` by default rather than the classic `zabbix-agent` — this also monitors the app server itself, separate from the Agent 2 you're installing on the Windows client in Part 3.

> `mysql-client` provides the `mysql` command used for the connection test (Part 1 step 5) and the schema import (step 3 below). The app server has no MySQL server of its own.

### 3. Import the schema to the remote DB node
```bash
zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql -h <DB_IP> -P <DB_PORT> -u zabbix -p --default-character-set=utf8mb4 zabbix
```
Enter `<DB_PASSWORD>` when prompted — this runs for 1–2 minutes. `--default-character-set=utf8mb4` makes the client send the data in the same character set as the database.

> Zabbix 8.0 ships the schema under `/usr/share/zabbix/sql-scripts/`. The older `/usr/share/zabbix-sql-scripts/` path found in many guides does not exist in 8.0. If unsure, look: `ls /usr/share/zabbix*/`

Once it finishes, reconnect to the **DB node** (`<DB_IP>`) and turn the trust setting back off. This has to happen on the DB node (`sudo mysql`): the `zabbix` account cannot change global settings from the app server.
```sql
SET GLOBAL log_bin_trust_function_creators = 0;
```

### 4. Point the server at the remote database
```bash
sudo nano /etc/zabbix/zabbix_server.conf
```
```ini
DBHost=<DB_IP>
DBPort=<DB_PORT>
DBName=zabbix
DBUser=zabbix
DBPassword=<DB_PASSWORD>
```

**Single-VM variants** (MySQL on the same machine as Zabbix):
- **Default (local socket):** `DBHost=localhost` with no `DBPort=` line. The MySQL user is `'zabbix'@'localhost'`, and the web wizard's Database port is `0`.
- **Custom MySQL port:** set `port = <DB_PORT>` under `[mysqld]` in `/etc/mysql/mysql.conf.d/mysqld.cnf` (`bind-address` stays `127.0.0.1`), restart MySQL, then use TCP to `127.0.0.1`. To the MySQL client, `localhost` always means the socket, and the port would be ignored.
  ```ini
  DBHost=127.0.0.1
  DBPort=<DB_PORT>
  ```
  A TCP login from `127.0.0.1` may be matched as `'zabbix'@'localhost'` or as `'zabbix'@'127.0.0.1'`, so create both accounts, with the same password and grants (Part 1 step 4):
  ```sql
  CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '<DB_PASSWORD>';
  CREATE USER 'zabbix'@'127.0.0.1' IDENTIFIED BY '<DB_PASSWORD>';
  GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
  GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'127.0.0.1';
  ```
  Import with `-h 127.0.0.1 -P <DB_PORT>` (step 3). In the wizard, use Database host `127.0.0.1` and port `<DB_PORT>`.

### 5. Configure Apache for PHP 8.5-FPM
```bash
sudo a2enmod proxy proxy_fcgi proxy_http rewrite
```

### 5a. Set the PHP timezone for the frontend
The web wizard checks PHP's `date.timezone`. With PHP-FPM it is **not** set by the `php_value date.timezone` line in `/etc/zabbix/apache.conf` (that block only applies to `mod_php`). It belongs in the PHP-FPM pool that serves the frontend. To find that pool, check which socket Apache sends Zabbix's PHP to, then which pool listens on it:
```bash
grep -h 'proxy:unix' /etc/zabbix/apache.conf          # e.g. SetHandler "proxy:unix:/var/run/php/zabbix.sock|fcgi://localhost"
grep -l 'zabbix.sock' /etc/zabbix/*.conf /etc/php/*/fpm/pool.d/*.conf
```
With the Zabbix packages this is the `[zabbix]` pool in `/etc/zabbix/php-fpm.conf`. Uncomment or set:
```ini
php_value[date.timezone] = America/Toronto
```
```bash
sudo systemctl restart php8.5-fpm
```

### 6. Generate the en_US locale
```bash
sudo sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8
```

### 7. Start and enable services
```bash
sudo systemctl restart zabbix-server zabbix-agent2 apache2 php8.5-fpm
sudo systemctl enable zabbix-server zabbix-agent2 apache2 php8.5-fpm
```

> On a re-run where the database **port or IP changed**, `zabbix-server` can hang on stop: before exiting it flushes its cache to the old database, which is no longer reachable, and the unit has no stop timeout. Stop it with a time limit and kill it if needed (the history it could not deliver is lost):
> `sudo timeout 60 systemctl stop zabbix-server || sudo systemctl kill --signal=SIGKILL zabbix-server`

### 7a. Open the firewall for the web UI and active checks
Allow SSH first, then the web UI and the agents' active checks, then turn ufw on (the script does exactly this):
```bash
sudo apt install ufw -y
sudo ufw allow 22/tcp comment 'zabbix-setup'                                             # SSH - FIRST (your real sshd port)
sudo ufw allow 80/tcp comment 'zabbix-setup'                                             # web UI
sudo ufw allow from <WIN_IP> to any port 10051 proto tcp comment 'zabbix-setup'         # active checks (ServerActive=)
#   (no Windows IP known yet: sudo ufw allow 10051/tcp comment 'zabbix-setup')
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status numbered
```
If `ufw` was already active, only the `allow` lines are needed.

### 8. Complete the frontend web wizard
Go to `http://<APP_IP>/zabbix`:
- Database host: `<DB_IP>`: the **database** server, not localhost and not the Zabbix server. A host name only works if the app server can resolve it (DNS or `/etc/hosts`); otherwise the wizard fails with `getaddrinfo ... Name or service not known`, so the IP is the safe choice.
- Database port: `<DB_PORT>` (must be set explicitly here — leaving it `0` makes the wizard assume the default port 3306, which will fail since MySQL is listening on `<DB_PORT>` instead)
- Database name: `zabbix`
- User / Password: `zabbix` / `<DB_PASSWORD>`

### 9. Log into the Zabbix website
- Username: `Admin`
- Password: `zabbix`

This is a separate login from the MySQL database account above — it's a row in the `users` table created by the schema import. Change it immediately under **Users → Admin → Change password**.

---

## Part 3 — Windows 11 Agent Setup (`<WIN_HOSTNAME>` @ `<WIN_IP>`)

### 1. Configure the agent
In `C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf` (Agent 2, recommended):
```ini
Hostname=<WIN_HOSTNAME>
Server=<APP_IP>
ServerActive=<APP_IP>
```
Setting both `Server=` (passive checks) and `ServerActive=` (active checks) means both modes work.

### 2. Open the firewall for passive checks
```powershell
New-NetFirewallRule -DisplayName "Zabbix Agent Port 10050" -Direction Inbound -Protocol TCP -LocalPort 10050 -Action Allow
Restart-Service "Zabbix Agent 2"
```

### 3. Add the host in the Zabbix web UI
**Data collection → Hosts → Create host**:
- Host name: `<WIN_HOSTNAME>` (must match `Hostname=` exactly)
- Agent interface: `<WIN_IP>`, port `10050`
- Templates: link **`Windows by Zabbix agent`** (includes CPU, memory, and disk-space discovery items out of the box)

Check **Monitoring → Latest data** filtered to `<WIN_HOSTNAME>` — CPU, memory, and disk metrics should populate within a couple of minutes.

---

## Troubleshooting

| Error | Fix |
|---|---|
| `ERROR 1410 (42000): You are not allowed to create a user with GRANT` | Run `CREATE USER` before `GRANT ALL PRIVILEGES` — MySQL 8.0+ no longer creates users implicitly via `GRANT`. |
| `ERROR 1050 (42S01): Table 'role' already exists` | The schema was partially imported before. On the DB node: `DROP DATABASE zabbix; CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;` then re-run the import. |
| `AH00526: Invalid command 'ProxyTimeout'` | Apache's proxy/FCGI modules aren't enabled. Run `sudo a2enmod proxy proxy_fcgi proxy_http rewrite` and restart Apache. |
| `Locale for language "en_US" is not found on the web server` | Generate `en_US.UTF-8` via `locale-gen` **and** restart `php8.5-fpm` — restarting Apache alone doesn't refresh PHP-FPM's locale. |
| `Get value from agent failed: [104] Connection reset by peer` | Confirm `Server=<APP_IP>` is set in `zabbix_agent2.conf` on the Windows host and restart the **Zabbix Agent 2** service — config changes don't hot-reload. |
| Host shows grey "unknown" status with no data | See full checklist below. |
| `ERROR 2003 (HY000): Can't connect to MySQL server on '<DB_IP>'` (connection refused, not access denied) | This means nothing is reachable at all — check, in order: `sudo systemctl status mysql` on the DB node (is it running?), `bind-address` in `mysqld.cnf` (must be `0.0.0.0`, resets to `127.0.0.1` on fresh installs), `port` in `mysqld.cnf` matches `<DB_PORT>`, and `sudo ufw status` on the DB node (the port may be blocked by default on a fresh Ubuntu 26.04 image). |
| Zabbix web wizard connection test fails even though `mysql -h <DB_IP> -P <DB_PORT>` works manually | The wizard's **Database port** field was left at `0`. `0` only means "use the default port" (3306) — with a custom port you must type `<DB_PORT>` into that field explicitly. |
| `zcat: /usr/share/zabbix-sql-scripts/mysql/server.sql.gz: No such file or directory` | Zabbix 8.0 moved the schema to `/usr/share/zabbix/sql-scripts/mysql/server.sql.gz`. Find it with `ls /usr/share/zabbix*/`. |
| `mysql: command not found` on the app server | Install the client: `sudo apt install mysql-client -y` (Part 2 step 2). |
| `systemctl restart zabbix-server` never returns after the DB port/IP changed | The old process is flushing its cache to an unreachable database (no stop timeout). `sudo timeout 60 systemctl stop zabbix-server \|\| sudo systemctl kill --signal=SIGKILL zabbix-server`, then start it again. |
| Web wizard warns about the PHP time zone | Set `php_value[date.timezone]` in the PHP-FPM pool (Part 2 step 5a) and restart `php8.5-fpm`. The `php_value` lines in `apache.conf` only apply to `mod_php`. |

### Host shows "unknown" / no data
1. Check `C:\Program Files\Zabbix Agent 2\zabbix_agent2.log` for connection errors.
2. Confirm the hostname in Zabbix matches `Hostname=` in the agent config exactly (case-sensitive).
3. From Windows PowerShell: `Test-NetConnection <APP_IP> -Port 10051` (active) or confirm the server can reach `<WIN_IP>:10050` (passive) — a failure here is network/firewall, not Zabbix config.
4. Check **Reports → Queue** in the web UI for stuck items.
5. Restart the **Zabbix Agent 2** service after any config change.

---

## Automation

[`zabbix-setup.sh`](zabbix-setup.sh) performs Parts 1 and 2 with the same step numbers as this guide (plus Part 0 for preparation, the optional Part 1 step 6, and steps 2.5a / 2.7a). Run it as `sudo ./zabbix-setup.sh`, or with the one-liner from [Run it](#run-it-automation). With no options it shows a menu; on a terminal, prompts are whiptail dialogs (`--no-dialog` for plain text).

| Scenario | Command |
|---|---|
| One VM (Zabbix + MySQL together) | `sudo ./zabbix-setup.sh --mode single` |
| Two VMs, on the **DB server first** | `sudo ./zabbix-setup.sh --mode db --app-ip <APP_IP>` |
| Two VMs, then on the **app server** | `sudo ./zabbix-setup.sh --mode app --env-file ./zabbix-handoff.txt` |
| Back on the DB server (trust flag to 0) | `sudo ./zabbix-setup.sh --mode db --yes` |

- **`--dry-run`** prints every command and file edit, numbered like this guide, and changes nothing. No password is needed. The list is also saved to `zabbix-manual-steps.txt`, a ready-made revision sheet for the scenario you picked.
- **`--verify`** re-checks a server at any time: a PASS / WARN / FAIL table, each FAIL with a one-line fix.
- **Output of a real run:** one line per step, with this guide's step number. A green `[✓]` and the duration replace the running `[✗]` and spinner once the step is done; `[-]` marks a step with nothing to do:

  ```text
  ( 7/19) [✓] 1.4 Create the database and user (CREATE USER before GRANT - MySQL 8) (0s)
  ( 8/19) [✓] 1.5 Verify the zabbix user can log in (local socket) (0s)
  ( 9/19) [✗] 2.1 Add the Zabbix 8.0 repository (Ubuntu 26.04)... ⠸
  ```

  - **Full output:** the commands' output (apt, mysql, systemctl…) goes to `/var/log/zabbix-setup.log`, never with the password. A failed step stays red, with its last 15 lines, the error, the fix from the Troubleshooting table above, and the log path.
  - **`--verbose` / `-v`** (or `ZBX_VERBOSE=1`): every command as `$ ...`, with its live output underneath.
  - **Piped output:** plain `[..]` / `[OK]` / `[FAIL]` lines. `NO_COLOR=1` / `TERM=dumb` turn off colours and the redraw.
- **Verbose** is the first question ("Show detailed output (verbose)?", default no), unless `--verbose` / `-v` or `ZBX_VERBOSE=yes|no` already answers it. The answer goes into `zabbix-setup.env`, never into the hand-off.
- **Firewall:** the script **enables ufw** in Part 1 step 3 (db) and Part 2 step 7a (app, single), with the commands shown in those steps:
  - The exact rule list is shown first, then the question "Enable the ufw firewall with these rules?" (default yes).
  - SSH is always allowed first. Without a detectable SSH port, ufw is not enabled, not even with `--force`, unless `--ssh-port N` names it.
  - A rule that already exists without the comment is left alone and reported as "already present (not managed by the script)".
  - Rules carry the comment `zabbix-setup`. A re-run adds nothing twice and replaces only those rules when the DB port or an IP changed.
  - `--no-ufw` / `ZBX_ENABLE_UFW=no` skip it. `--verify` checks it.
- **The last block of every run**, also saved at the end of `zabbix-next-steps.txt` / `zabbix-handoff.txt`, is **REMEMBER: ZABBIX WEB WIZARD**. It holds the values for step 8, the password (printed only there), and the reminder to change the Admin / zabbix web login, which is a different account from the database user.
- **`--env-file PATH`** loads `ZBX_*` settings from a file (`ZBX_DB_IP=...`, `ZBX_DB_PORT=...`, `ZBX_DB_PASSWORD='...'`). The DB server's `zabbix-handoff.txt` is such a file: copy it to the app server with `scp` and pass it with `--env-file`. Each run also writes `./zabbix-setup.env` (chmod 600) and reads it back automatically on the next run in the same directory. Priority: flag > `ZBX_*` environment variable > env file > prompt.
- The env file, `zabbix-handoff.txt` and `zabbix-next-steps.txt` contain the DB password: keep them chmod 600 and out of git.
- Single VM with a custom MySQL port (`--db-port`): Zabbix then connects over TCP to `127.0.0.1:<port>`, and the wizard's Database host is `127.0.0.1`. `localhost` would make the MySQL client use the socket and ignore the port.
- Agent 2 is optional in every mode (`--agent` / `--no-agent`, `ZBX_INSTALL_AGENT`, default yes). On the DB server it is Part 1 step 6 (`--agent-hostname`, `ZBX_AGENT_HOSTNAME`, default the short hostname), and the hand-off block lists the host to add in the web UI.

---

## Notes

- Store `<DB_PASSWORD>` in a password manager rather than plaintext config files where possible.
- The `'zabbix'@'<APP_IP>'` MySQL user is locked to the app server's specific IP. If the app server's IP ever changes, the MySQL user must be recreated (or widened) to match, or the connection will fail even with the correct password.
