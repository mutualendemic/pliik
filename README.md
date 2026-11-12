# Pliik Workstation for Termux

A development workstation for Android devices running Termux. The installer runs `pi-web` directly in Termux; it does not set up a QEMU guest, Docker, or Code Server.

## Features

- Installs Node.js/npm, `pi-web`, and the Pi coding agent SDK.
- Runs both the web server and its session daemon in Termux.
- Clones the Pliik repository and VS-CODE-IN-TERMUX as a reference.
- Creates a projects directory under `~/pliik-workstation`.
- Installs commands to start, stop, and check the `pi-web` server.

## Requirements

- Android device with Termux and internet access.
- Run as the regular Termux user, not as root.
- GitHub credentials configured in Termux if cloning requires authentication.

## Installation

Run inside Termux:

    curl -fsSL https://raw.githubusercontent.com/mutualendemic/pliik/main/install-pliik-workstation.sh | bash

The installer installs the required Termux packages and npm packages, creates the workstation directories, clones the repositories, and starts both `pi-web-server` and `pi-web-sessiond`. It manages these processes directly because `pi-web install` requires systemd or LaunchAgents, which Termux does not provide.

## Access and management

Open the browser app at:

    http://127.0.0.1:8504

Manage the server with:

    bin-dev-start
    bin-dev-stop
    bin-dev-status

The commands are installed under `$PREFIX/bin`. Startup output is written to `~/.config/pliik-workstation/pi-web.log`; session daemon output is in `~/.config/pliik-workstation/pi-web-sessiond.log`.

`bin-dev-start` acquires a Termux wakelock when `termux-wake-lock` is available; `bin-dev-stop` releases it. The installer installs the `termux-api` command package. Install the separate Termux:API Android app from the same source as Termux for the wakelock command to work. Also set Termux's Android battery usage to **Unrestricted** (or disable battery optimization for Termux), otherwise Android may still stop its background process.

## Troubleshooting

Check whether the server, session daemon, and socket are available with:

    bin-dev-status

If dependencies are missing, install or update them in Termux and rerun the installer:

    pkg update
    pkg install git curl wget nodejs npm termux-api

The installer does not launch the separate Go portal in `portal/`; that component is not part of the current Termux runtime.

## Repositories

- https://github.com/mutualendemic/pliik
- https://github.com/Skynetfc/VS-CODE-IN-TERMUX

Keep the browser app accessible only to trusted users; review its authentication and network binding before exposing it beyond the device.
