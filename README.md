# 🍑 Peach

**iOS Backup Manager for Linux** — plug in your iPhone and back it up from a clean web UI.

---

## Install

```bash
git clone https://github.com/you/peach
cd peach
sudo bash install.sh
```

Then open **http://localhost:5173** in your browser.

---

## What it does

- Detects connected iOS devices via `libimobiledevice`
- Streams backup progress live in a terminal-style log
- Stores full encrypted backups via `idevicebackup2`
- Shows all previous backups with size and date
- Starts automatically on boot via systemd

---

## Requirements

- Linux (Arch, Debian/Ubuntu, or Fedora)
- `libimobiledevice` (installed automatically)
- Python 3.10+
- Your iPhone must **Trust** the computer on first connect

---

## Project structure

```
peach/
├── backend/
│   ├── main.py           # FastAPI backend
│   └── requirements.txt
├── ui/
│   └── index.html        # Web UI (single file)
├── scripts/
│   ├── peach.service     # systemd unit
│   └── 99-peach-ios.rules # udev rule
└── install.sh            # One-command installer
```

---

## Useful commands

```bash
# View live logs
journalctl -u peach -f

# Restart the service
sudo systemctl restart peach

# Check status
sudo systemctl status peach

# Uninstall
sudo systemctl disable --now peach
sudo rm -rf /opt/peach /etc/peach
sudo rm /etc/systemd/system/peach.service
sudo rm /etc/udev/rules.d/99-peach-ios.rules
```

---

## First-time iPhone setup

1. Connect iPhone via USB
2. Unlock your iPhone
3. Tap **Trust** when prompted
4. Open Peach in your browser — your device should appear
5. Hit **Back Up Now**

> Backups are full encrypted local backups, equivalent to iTunes/Finder backups on macOS.