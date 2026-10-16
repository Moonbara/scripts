# scripts

Small automation scripts and guides from my sysadmin studies and homelab.

| Folder | What it is |
|---|---|
| [`zabbix/`](zabbix/) | Zabbix 8.0 LTS server setup on Ubuntu 26.04 (single VM or app + database on two VMs), with a manual guide for the Windows 11 agent |

---

## zabbix

`zabbix/zabbix-setup.sh` automates the **server side** of [`zabbix/zabbix-3tier-setup-guide.md`](zabbix/zabbix-3tier-setup-guide.md). The Windows 11 agent (Part 3 of the guide) is deliberately manual: the script finishes by printing the exact values to type on Windows and in the web UI.

### What it sets up

- **Single VM:** Zabbix server, Apache + PHP-FPM frontend and MySQL on one machine.
- **Two VMs:** MySQL on a database server, Zabbix server and frontend on an app server, on a configurable MySQL port (default 8090).
- Zabbix Agent 2 on the server, chrony time sync, timezone, firewall rules (only when `ufw` is already active) and an optional static IP through `netplan try`.

### Requirements

- Ubuntu **26.04** (other versions need `--force`)
- Root / `sudo`, internet access to `repo.zabbix.com`
- At least 5 GB free disk, 2 GB RAM recommended

### Get the script

```bash
sudo apt install curl -y
curl -fsSLO https://raw.githubusercontent.com/YOUR_USER/scripts/main/zabbix/zabbix-setup.sh
chmod +x zabbix-setup.sh
```

Read it before running it as root. To pin an exact version, replace `main` in the URL with a tag such as `zabbix-v1.0.0`, or with a commit hash.

### Run it

With no options, a menu asks which role the machine has and prompts for every value:

```bash
sudo ./zabbix-setup.sh
```

```
Which scenario?
  1) Single VM (Zabbix + MySQL on the same machine)
  2) Two VMs: this machine is the DATABASE server
  3) Two VMs: this machine is the APP/WEB server
```

Or skip the menu:

```bash
# One VM
sudo ./zabbix-setup.sh --mode single

# Two VMs: database server FIRST, then the app server
sudo ./zabbix-setup.sh --mode db  --app-ip <APP_IP>
sudo ./zabbix-setup.sh --mode app --db-ip <DB_IP> --db-port <DB_PORT>

# Back on the database server once the app server has imported the schema
sudo ./zabbix-setup.sh --mode db --yes
```

The database run writes `zabbix-handoff.txt` with the values the app server needs (it prompts for the password, or reads it from `--db-password-file ./zabbix-handoff.txt` after you `scp` the file across).

### Options

| Option | Purpose |
|---|---|
| `--mode single\|db\|app` | Skip the menu |
| `--dry-run` | Print every command and file edit, numbered like the guide, and change nothing. Saves them to `zabbix-manual-steps.txt` |
| `--verify` | Health check with a PASS / WARN / FAIL table (exits 1 on any FAIL) |
| `--add-user NAME` | Create a sudo user and install an SSH public key |
| `--reset` | Drop and recreate the Zabbix database (asks you to type its name) |
| `--yes`, `-y` | Accept every default, no prompts |
| `--force` | Continue on a different OS or a role mismatch |
| `--help` | Full list, including every value flag |

Values come from a flag, an environment variable, or a prompt, in that order. There is no password flag on purpose, because it would leak into shell history and `ps`: use the hidden prompt, `--db-password-file`, or the `DB_PASSWORD` environment variable.

### After the script finishes

The script prints a **NEXT STEPS** block (also saved to `zabbix-next-steps.txt`) with the real values for:

1. The web setup wizard at `http://<APP_IP>/zabbix`. The default login is `Admin` / `zabbix`, so **change it immediately**.
2. Installing Zabbix Agent 2 on Windows 11 (`Hostname`, `Server`, `ServerActive`).
3. The Windows firewall rule for port 10050.
4. Adding the host in the web UI. The template needs an **Agent interface** even when you only use active checks.
5. Checking that data arrives under *Monitoring > Latest data*.

Run `sudo ./zabbix-setup.sh --verify` at any time to re-check the server.

### Good to know

- It is safe to re-run. It keeps the existing database password and skips an already imported schema.
- Nothing destructive happens without `--reset`. SSH configuration and `ufw` on/off state are never changed.
- Back-ups of edited config files go to `/var/backups/zabbix-setup/`, and the log is `/var/log/zabbix-setup.log` (it never contains the password).
- Zabbix 8.0 packages may still be a release candidate, depending on when you run this.

### Security

The generated files `zabbix-handoff.txt` and `zabbix-next-steps.txt` contain the database password (mode 600). They are listed in `.gitignore`: never commit them.

---

## License

For learning and personal use. Use at your own risk, and test on a throwaway VM first.
