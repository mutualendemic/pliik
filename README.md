Pliik Workstation — Architecture

1. Overview

The Pliik Workstation provides an Android-based development environment using:

- Termux as the host environment.
- QEMU-backed Docker for container execution.
- Docker Compose for service deployment.
- Code Server for browser-based development.
- Git for source-code management.

2. Architecture

ANDROID DEVICE
     |
     v
   TERMUX
     |
     +---------------------------+
     |                           |
     v                           v
   GIT / GH                QEMU DOCKER
     |                           |
     v                           v
 Pliik source              Docker Engine
     |                           |
     v                           v
 VS-CODE-IN-TERMUX          Docker Compose
 reference                       |
                                 v
                         CODE SERVER
                                 |
                                 v
                      http://127.0.0.1:8080

3. Repository responsibilities

Repository| Responsibility
mutualendemic/pliik| Main application source
Skynetfc/VS-CODE-IN-TERMUX| Reference implementation
luisdavim/termux-qemu-docker| QEMU Docker environment

The reference repository is cloned for inspection and is mounted read-only in Code Server.

4. Installation workflow

The installation script performs the following operations:

1. Checks the Termux environment.
2. Updates packages.
3. Installs Git, GitHub CLI, Go, OpenSSH and utilities.
4. Clones or updates the Pliik repository.
5. Clones the VS-CODE-IN-TERMUX reference.
6. Clones the QEMU Docker project.
7. Invokes the upstream setup script when available.
8. Detects the Docker socket.
9. Generates Docker Compose configuration and environment files.
10. Generates a random Code Server password.
11. Deploys Code Server.
12. Creates start, stop and status helper commands.

5. Container architecture

Code Server

Code Server provides a browser-based development environment.

- Container: "pliik-code-server"
- Internal port: "8080"
- Host port: "8080"
- Workspace: "/workspace"
- Pliik source: "/workspace/pliik"
- Reference source: "/workspace/VS-CODE-IN-TERMUX"

The host binding is restricted to "127.0.0.1".

Pliik application

The application container is optional.

It requires:

- A valid Dockerfile.
- Known runtime dependencies.
- A confirmed application listening port.

The installer does not assume these details.

6. Security

- No GitHub token is embedded in the installer.
- Private repository access should use "gh auth login".
- ".env" contains the Code Server password.
- ".env" must never be committed.
- The password file should have permissions "600".
- Code Server is bound to localhost by default.

7. Management

The installation creates:

~/bin-dev-start
~/bin-dev-stop
~/bin-dev-status

These commands control the Docker Compose environment.

8. Limitations

This deployment has not been validated on every Android device.

QEMU and Docker support depends on:

- Android version.
- Device architecture.
- Available RAM and storage.
- Kernel capabilities.
- Compatibility with the upstream QEMU Docker implementation.

The upstream setup procedure may change. Consult its documentation if the installation script no longer matches its current structure.

9. Upstream documentation

- Pliik: https://github.com/mutualendemic/pliik
- VS-CODE-IN-TERMUX: https://github.com/Skynetfc/VS-CODE-IN-TERMUX
- Termux QEMU Docker: https://github.com/luisdavim/termux-qemu-docker
- Code Server: https://github.com/coder/code-server
