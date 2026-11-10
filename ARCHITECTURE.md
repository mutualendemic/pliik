# Pliik Workstation Architecture

## Overview

The Pliik Workstation provides an Android development environment using:

- Termux
- QEMU-backed Docker
- Docker Compose
- Code Server
- Git

## Architecture

    ANDROID DEVICE
          |
          v
        TERMUX
          |
          +-------------------+
          |                   |
          v                   v
       GIT / GH           QEMU DOCKER
          |                   |
          v                   v
      Pliik source        Docker Engine
          |                   |
          v                   v
      Reference          Docker Compose
                              |
                              v
                         CODE SERVER
                              |
                              v
                   http://127.0.0.1:8080

## Repository responsibilities

| Repository | Responsibility |
|---|---|
| mutualendemic/pliik | Main application |
| Skynetfc/VS-CODE-IN-TERMUX | Reference implementation |
| luisdavim/termux-qemu-docker | QEMU Docker environment |

## Installation workflow

1. Check Termux environment.
2. Install required packages.
3. Clone Pliik.
4. Clone VS-CODE-IN-TERMUX.
5. Clone QEMU Docker.
6. Execute upstream setup script if available.
7. Detect Docker socket.
8. Generate Compose configuration.
9. Generate secure Code Server password.
10. Deploy Code Server.
11. Create management commands.

## Code Server

- Container: pliik-code-server
- Internal port: 8080
- Host port: 8080
- Workspace: /workspace
- Pliik: /workspace/pliik
- Reference: /workspace/VS-CODE-IN-TERMUX

The service binds to localhost.

## Pliik application container

The Pliik application container is optional.

It requires:

- A valid Dockerfile.
- Known runtime dependencies.
- A confirmed listening port.

The deployment does not assume these details.

## Security

- Never commit `.env`.
- Never embed PAT credentials in scripts.
- Use `gh auth login` for private repositories.
- Keep Code Server restricted to localhost.
- Protect the generated password.

## Limitations

The deployment has not been validated on every Android device.

Compatibility depends on Android version, architecture, available RAM, storage and kernel capabilities.

## Upstream projects

- https://github.com/mutualendemic/pliik
- https://github.com/Skynetfc/VS-CODE-IN-TERMUX
- https://github.com/luisdavim/termux-qemu-docker
- https://github.com/coder/code-server
