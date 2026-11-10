# Pliik Workstation for Termux

A development workstation for Android devices running Termux.

## Features

- Installs Termux dependencies.
- Clones the Pliik repository.
- Clones VS-CODE-IN-TERMUX as reference.
- Installs the QEMU Docker environment.
- Deploys Code Server using Docker Compose.
- Provides start, stop and status commands.

## Requirements

- Android device.
- Termux.
- Termux package manager access (`pkg`); the installer installs and validates OpenSSL.
- Internet connection.
- Sufficient storage and RAM.
- GitHub authentication if Pliik is private.

## Quick installation

Run inside Termux:

    curl -fsSL https://raw.githubusercontent.com/mutualendemic/pliik/main/install-pliik-workstation.sh | bash

The installer checks that OpenSSL can report its version and generate a 24-byte hexadecimal value before using it for the Code Server password.

## Access

Open:

    http://127.0.0.1:8080

The installer generates a random password stored in `.env`.

View it with:

    grep '^CODE_SERVER_PASSWORD=' .env

## Management

    ~/bin-dev-start
    ~/bin-dev-stop
    ~/bin-dev-status

## OpenSSL troubleshooting

If the installer reports an OpenSSL error, check the Termux binary directly:

    pkg install -y openssl
    hash -r
    "$PREFIX/bin/openssl" version
    test "$("$PREFIX/bin/openssl" rand -hex 24 | wc -c)" -eq 49

For a traced installer run, download the script and run it with Bash tracing enabled:

    curl -fsSL https://raw.githubusercontent.com/mutualendemic/pliik/main/install-pliik-workstation.sh -o install-pliik-workstation.sh
    set -o pipefail
    bash -x ./install-pliik-workstation.sh 2>&1 | tee "$HOME/pliik-openssl-debug.log"

The installer also prints its OpenSSL search paths and version/random-generation results when validation fails. Share only the relevant diagnostic output; never share `~/.config/pliik-workstation/.env` or its password.

## Repositories

- https://github.com/mutualendemic/pliik
- https://github.com/Skynetfc/VS-CODE-IN-TERMUX
- https://github.com/luisdavim/termux-qemu-docker
- https://github.com/coder/code-server

## Security

- Never commit `.env`.
- Never embed GitHub tokens in scripts.
- Use `gh auth login` for private repository access.
- Keep Code Server bound to localhost.

## Important

The Pliik application container is optional and requires a valid Dockerfile and confirmed application port.
