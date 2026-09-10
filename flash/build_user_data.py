#!/usr/bin/env python3
"""Generates cloud-init/user-data from the scripts/ and systemd/ source files.

Run this after editing anything in scripts/ or systemd/, then re-run flash_mother.sh.
Keeping the scripts as standalone files (rather than hand-editing YAML) is what
makes this repo git-diff-friendly.
"""
import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
SYSTEMD = ROOT / "systemd"
OUT = ROOT / "cloud-init" / "user-data"


def read(p):
    return p.read_text()


def str_presenter(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


yaml.add_representer(str, str_presenter)

write_files = [
    {"path": "/home/admin/videoloop.sh", "permissions": "0755", "content": read(SCRIPTS / "videoloop.sh")},
    {"path": "/home/admin/mpvctl.py", "permissions": "0755", "content": read(SCRIPTS / "mpvctl.py")},
    {"path": "/home/admin/videoloop_watchdog.sh", "permissions": "0755", "content": read(SCRIPTS / "videoloop_watchdog.sh")},
    {"path": "/home/admin/.config/systemd/user/videoloop.service", "permissions": "0644", "content": read(SYSTEMD / "videoloop.service")},
    {"path": "/home/admin/.config/systemd/user/videoloop-watchdog.service", "permissions": "0644", "content": read(SYSTEMD / "videoloop-watchdog.service")},
    {"path": "/home/admin/.config/systemd/user/videoloop-watchdog.timer", "permissions": "0644", "content": read(SYSTEMD / "videoloop-watchdog.timer")},
]

user_data = {
    "hostname": "pi-videoloop",
    "manage_etc_hosts": True,
    "users": [
        {
            "name": "admin",
            "groups": "users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo",
            "shell": "/bin/bash",
            "lock_passwd": False,
            "plain_text_passwd": "e4LabPASS",
            "sudo": "ALL=(ALL) NOPASSWD:ALL",
            "ssh_authorized_keys": [
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIERl0N8snJ9mQq01Lu5UUdMNrTQ3LhAJTXRpPyVNmUzT kristofers.rozevskis@gmail.com"
            ],
        }
    ],
    "chpasswd": {"expire": False},
    "ssh_pwauth": True,
    "package_update": True,
    "packages": ["mpv", "alsa-utils", "gpiod"],
    "write_files": write_files,
    "runcmd": [
        "chown -R admin:admin /home/admin",
        "loginctl enable-linger admin",
        "systemctl enable ssh",
        "systemctl start ssh",
        "SERIAL=$(awk '/Serial/{print substr($3,9)}' /proc/cpuinfo); hostnamectl set-hostname \"pi-$SERIAL\"",
        "sudo -u admin XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload",
        "sudo -u admin XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable --now videoloop.service",
        "sudo -u admin XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable --now videoloop-watchdog.timer",
    ],
}

body = yaml.dump(user_data, sort_keys=False, width=100000, default_flow_style=False)
OUT.write_text("#cloud-config\n\n" + body)
print(f"wrote {OUT}")
