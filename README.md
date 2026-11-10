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
- Internet connection.
- Sufficient storage and RAM.
- GitHub authentication if Pliik is private.

## Quick installation

Run inside Termux:

    curl -fsSL https://raw.githubusercontent.com/mutualendemic/pliik/main/install-pliik-workstation.sh | bash

This command will work after the installer has been committed to main.

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
