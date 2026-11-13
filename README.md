# Pliik Workstation for Termux

A small local workstation setup for Android devices running Termux. It installs and runs Pi Web and a Go administration portal directly in Termux, with a CodeMirror editor plugin for browser-based source editing; it does not set up Code Server.

## Features

- Installs Node.js/npm, `pi-web`, the Pi coding agent SDK, and Go.
- Installs the PI WEB CodeMirror editor package for editing supported text files from the browser.
- Builds the administration portal as `$PREFIX/bin/pliik-portal`.
- Runs Pi Web, its session daemon, and the administration portal in Termux.
- Provides a local admin page to save multiple GitHub PATs, choose an account and its repositories, set the commit author identity, clone them into `~/pliik-workstation/projects`, and register them with Pi Web. Each project is associated with its selected GitHub account and gets private, project-specific Git credentials plus local Git identity for authenticated pushes.
- Installs commands to start, stop, and check the services.

## Requirements

- Android device with Termux and internet access.
- Run as the regular Termux user, not as root.
- GitHub credentials configured in Termux if cloning the installer repository requires authentication.

## Installation

Run inside Termux:

    curl -fsSL https://raw.githubusercontent.com/mutualendemic/pliik/main/install-pliik-workstation.sh | bash

The installer installs the required Termux/npm packages, builds Pi Web's native terminal dependency with Termux's Android toolchain, installs the CodeMirror editor Pi package, clones the Pliik repository, builds the management portal, and starts Pi Web, its session daemon, and the portal. The portal is installed at `$PREFIX/bin/pliik-portal`. The installer manages these processes directly because `pi-web install` requires systemd or LaunchAgents, which Termux does not provide.

## Access and management

Open Pi Web at:

    http://127.0.0.1:8504

The installer adds the CodeMirror Editor package. If it is not already enabled, enable **CodeMirror Editor** under **Settings → PI WEB plugins** and reload the page. In the **Files** panel, choose **Edit** for a supported text file. Editing is browser-only; no session-daemon restart is required.

Open the administration page at:

    http://127.0.0.1:8080/admin

The portal is bound to loopback and has no authentication; keep it on this device and do not expose it to a LAN or public network. The admin page supports multiple GitHub accounts: save one PAT per account, then select the account when choosing repositories or configuring an existing project. After upgrading from an earlier version, add your existing PAT once; use **Configure Git** on existing projects to associate each checkout with an account and move it to project-specific credentials. PAT values are entered locally, stored privately, and never displayed again. When cloning projects, enter the commit author name and email; these are saved to each repository's local Git config. Each project uses its own private credential file, so no PAT is written into the project's Git config.

Manage the services with:

    bin-dev-start
    bin-dev-stop
    bin-dev-status

The commands are installed under `$PREFIX/bin`. Logs are written to `~/.config/pliik-workstation/`.

`bin-dev-start` acquires a Termux wakelock when `termux-wake-lock` is available; `bin-dev-stop` releases it. The installer installs the `termux-api` command package. Install the separate Termux:API Android app from the same source as Termux for the wakelock command to work. Also set Termux's Android battery usage to **Unrestricted** (or disable battery optimization for Termux), otherwise Android may still stop its background process.

## Troubleshooting

Check service and session-daemon status with:

    bin-dev-status

If dependencies are missing, install or update them in Termux and rerun the installer:

    pkg update
    pkg install git curl wget nodejs-lts npm golang termux-api python make clang

The unauthenticated administration portal listens only on `127.0.0.1:8080`; its startup output is written to `~/.config/pliik-workstation/portal.log`. Rerunning the installer rebuilds and reinstalls it.

## Repository

- https://github.com/mutualendemic/pliik
