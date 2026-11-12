# Pliik Workstation for Termux

A development workstation for Android devices running Termux. The installer runs `pi-web` directly in Termux; it does not set up a QEMU guest, Docker, or Code Server.

## Features

- Installs Node.js/npm, `pi-web`, and the Pi coding agent SDK.
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

The installer installs the required Termux packages and npm packages, creates the workstation directories, clones the repositories, and starts `pi-web`.

## Access and management

Open the browser app at:

    http://127.0.0.1:8504

Manage the server with:

    bin-dev-start
    bin-dev-stop
    bin-dev-status

The commands are installed under `$PREFIX/bin`. Startup output is written to `~/.config/pliik-workstation/pi-web.log`.

## Troubleshooting

Check whether the server is running and inspect its recent log output with:

    bin-dev-status

If dependencies are missing, install or update them in Termux and rerun the installer:

    pkg update
    pkg install git curl wget nodejs npm

The installer does not launch the separate Go portal in `portal/`; that component is not part of the current Termux runtime.

## Repositories

- https://github.com/mutualendemic/pliik
- https://github.com/Skynetfc/VS-CODE-IN-TERMUX

Keep the browser app accessible only to trusted users; review its authentication and network binding before exposing it beyond the device.
