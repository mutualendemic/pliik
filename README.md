# Pliik Workstation for Termux

A development workstation for Android devices running Termux. The installer runs `pi-web`, Code Server, and the management portal directly in Termux; it does not set up a QEMU guest or Docker.

## Features

- Installs Node.js/npm, `pi-web`, Code Server, the Pi coding agent SDK, and Go.
- Builds and installs the Go management portal as `$PREFIX/bin/pliik-portal`.
- Runs Pi Web, Code Server, the session daemon, and the management portal in Termux.
- Clones the Pliik repository and VS-CODE-IN-TERMUX as a reference.
- Creates a projects directory under `~/pliik-workstation`.
- Installs commands to start, stop, and check the web server and management portal.

## Requirements

- Android device with Termux and internet access.
- Run as the regular Termux user, not as root.
- GitHub credentials configured in Termux if cloning requires authentication.

## Installation

Run inside Termux:

    curl -fsSL https://raw.githubusercontent.com/mutualendemic/pliik/main/install-pliik-workstation.sh | bash

The installer installs the required Termux and npm packages, switches to Node.js 24 LTS as required by Code Server, builds native dependencies with Termux's Android toolchain, and applies a small Node platform shim so VS Code's PTY host treats Termux as Linux. It then creates the workstation directories, clones the repositories, builds the Go management portal, and starts `pi-web-server`, `pi-web-sessiond`, Code Server, and the portal. Code Server listens on `127.0.0.1:18080` with authentication disabled and is proxied through the portal at `/`. Pi Web is linked directly on its own loopback port (`8504`), so no portal proxy is needed for it; the portal calls Pi Web's local project API when registering cloned projects. The portal executable is installed at `$PREFIX/bin/pliik-portal`. The installer manages these processes directly because `pi-web install` requires systemd or LaunchAgents, which Termux does not provide.

## Access and management

Open Pi Web at:

    http://127.0.0.1:8504

Open Code Server through the portal at `http://127.0.0.1:8080/`, or open the management dashboard at `http://127.0.0.1:8080/portal`. The admin page at `/admin` shows Pi Web and Code Server availability and provides links to both. Repositories cloned from the admin page are shared with Code Server and registered as projects in Pi Web; older clones can be registered with the **Adicionar ao Pi Web** action.

Manage the server with:

    bin-dev-start
    bin-dev-stop
    bin-dev-status

The commands are installed under `$PREFIX/bin`. Startup output is written to `~/.config/pliik-workstation/pi-web.log`, `code-server.log`, and `pi-web-sessiond.log`.

`bin-dev-start` acquires a Termux wakelock when `termux-wake-lock` is available; `bin-dev-stop` releases it. The installer installs the `termux-api` command package. Install the separate Termux:API Android app from the same source as Termux for the wakelock command to work. Also set Termux's Android battery usage to **Unrestricted** (or disable battery optimization for Termux), otherwise Android may still stop its background process.

## Troubleshooting

Check whether the server, session daemon, and socket are available with:

    bin-dev-status

If dependencies are missing, install or update them in Termux and rerun the installer:

    pkg update
    pkg install git curl wget nodejs npm termux-api python make clang

The unauthenticated management portal is available at `http://127.0.0.1:8080/portal`; administration is at `/admin`. It is bound to the local device only. Its startup output is written to `~/.config/pliik-workstation/portal.log`. Check `bin-dev-status` for its state; rerunning the installer rebuilds and reinstalls it.

## Repositories

- https://github.com/mutualendemic/pliik
- https://github.com/Skynetfc/VS-CODE-IN-TERMUX

The portal and proxied Code Server have no authentication. They are intended for local-device use only; the portal enforces a loopback listener. Do not expose them to a LAN or public network, because the admin page can manage GitHub credentials and projects.
