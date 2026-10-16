# Zabbix 8.0 LTS — 3-Tier Setup Guide (Ubuntu 26.04 + Remote MySQL + Windows 11)

Dedicated 3-tier deployment: a separate App/Web node, a remote MySQL Database node, and a monitored Windows 11 agent host — monitoring CPU, RAM, and storage.

## Variables used in this guide

Fill these in for your environment, then swap them into the commands below.

| Placeholder | Meaning | Example |
|---|---|---|
| `<APP_HOSTNAME>` | Hostname of the App/Web server | `capyserver` |
| `<APP_IP>` | IP of the App/Web server | `10.4.0.68` |
| `<DB_IP>` | IP of the remote MySQL server | `10.4.0.79` |
| `<DB_PORT>` | Port MySQL listens on (non-default) | `8090` |
| `<DB_PASSWORD>` | Password for the `zabbix` MySQL user | (choose your own, strong) |
| `<WIN_HOSTNAME>` | Hostname/Host name of the Windows agent | `CapyWin` |
| `<WIN_IP>` | IP of the Windows 11 machine | `10.4.0.38` |

> Ubuntu 26.04 ships PHP 8.5-FPM by default rather than `mod_php`, which is why this guide's Apache setup differs from a standard 24.04 install (PHP-FPM needs Apache's proxy modules to hand off requests, instead of `php_value` directives in `apache.conf`).

## Infrastructure

| Role | Hostname | IP Address | OS / Software |
|---|---|---|---|
| App & Web Server | `<APP_HOSTNAME>` | `<APP_IP>` | Ubuntu 26.04 LTS (Resolute Raccoon), Zabbix Server 8.0 LTS, Apache 2, PHP 8.5-FPM |
| Database Server | (remote DB node) | `<DB_IP>` | Ubuntu/Debian, MySQL 8.0 |
| Monitored Client | `<WIN_HOSTNAME>` | `<WIN_IP>` | Windows 11, Zabbix Agent 2 |

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
sudo ufw allow <DB_PORT>/tcp
```
(Skip this if `ufw status` shows `inactive`.)

### 4. Create the database and user
```bash
sudo mysql -u root -p
```
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

### 5. Verify remote access works
Before moving to Part 2, test the connection **from the App server** (`<APP_IP>`), not from the DB node itself:
```bash
mysql -h <DB_IP> -P <DB_PORT> -u zabbix -p
```
If this connects, everything in Part 1 is solid and any later connection issue is a Zabbix-side config problem, not MySQL. If it refuses to connect, check in this order: MySQL is running (`sudo systemctl status mysql`), `bind-address` is `0.0.0.0` not `127.0.0.1`, `port` in `mysqld.cnf` matches `<DB_PORT>`, and `ufw` (step 3 above) isn't blocking it.

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
sudo apt install zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2 -y
```
> Zabbix 8.0's official examples install `zabbix-agent2` by default rather than the classic `zabbix-agent` — this also monitors the app server itself, separate from the Agent 2 you're installing on the Windows client in Part 3.

### 3. Import the schema to the remote DB node
```bash
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -h <DB_IP> -P <DB_PORT> -u zabbix -p zabbix
```
Enter `<DB_PASSWORD>` when prompted — this runs for 1–2 minutes.

Once it finishes, reconnect to the **DB node** (`<DB_IP>`) and turn the trust setting back off:
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

### 5. Configure Apache for PHP 8.5-FPM
```bash
sudo a2enmod proxy proxy_fcgi proxy_http rewrite
```

### 6. Generate the en_US locale
```bash
sudo sed -i '/^# *en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=en_US.UTF-8
```

### 7. Start and enable services
```bash
sudo systemctl restart zabbix-server zabbix-agent2 apache2 php8.5-fpm
sudo systemctl enable zabbix-server zabbix-agent2 apache2 php8.5-fpm
```

### 8. Complete the frontend web wizard
Go to `http://<APP_IP>/zabbix`:
- Database host: `<DB_IP>`
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

### Host shows "unknown" / no data
1. Check `C:\Program Files\Zabbix Agent 2\zabbix_agent2.log` for connection errors.
2. Confirm the hostname in Zabbix matches `Hostname=` in the agent config exactly (case-sensitive).
3. From Windows PowerShell: `Test-NetConnection <APP_IP> -Port 10051` (active) or confirm the server can reach `<WIN_IP>:10050` (passive) — a failure here is network/firewall, not Zabbix config.
4. Check **Reports → Queue** in the web UI for stuck items.
5. Restart the **Zabbix Agent 2** service after any config change.

---

## Notes

- Store `<DB_PASSWORD>` in a password manager rather than plaintext config files where possible.
- The `'zabbix'@'<APP_IP>'` MySQL user is locked to the app server's specific IP. If the app server's IP ever changes, the MySQL user must be recreated (or widened) to match, or the connection will fail even with the correct password.
