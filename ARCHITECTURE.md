# Pliik Workstation Architecture

The installer runs the browser-based `pi-web` app directly in Termux. It does not start QEMU, Docker, Code Server, or the separate Go portal.

## Runtime architecture

```mermaid
flowchart LR
    User[Developer] --> Browser[Android browser\nhttp://127.0.0.1:8504]
    Browser -->|local HTTP| Server[pi-web-server]

    subgraph Android[Android device]
        subgraph Termux[Termux]
            Server
            Runtime[Node.js and npm]
            SDK[Pi coding agent SDK]
            Repos["~/pliik-workstation/\npliik/\nVS-CODE-IN-TERMUX/"]
            Projects["~/pliik-workstation/projects/"]
            Helpers["bin-dev-start\nbin-dev-stop\nbin-dev-status"]
            Config["~/.config/pliik-workstation/\npi-web.pid and pi-web.log"]
        end
    end

    Runtime --> Server
    SDK --> Server
    Helpers --> Server
    Server --> Config
```

The installer launches `pi-web-server` as a Termux process and supplies `PI_WEB_PI_PACKAGE_DIR` pointing to the global Pi SDK package. The management commands are written to `$PREFIX/bin`.

## Installation and startup flow

```mermaid
flowchart TD
    Start[Run installer in Termux as regular user]
    Base[Install Git, curl, wget, and OpenSSL packages]
    Runtime[Ensure Node.js and npm]
    PiWeb[Install pi-web if missing]
    SDK[Ensure global Pi coding agent SDK]
    Checkout[Clone or update Pliik and VS-CODE-IN-TERMUX]
    Commands[Create start, stop, and status commands]
    Server[Start pi-web-server]
    Ready[Open http://127.0.0.1:8504]

    Start --> Base --> Runtime --> PiWeb --> SDK --> Checkout --> Commands --> Server --> Ready
```

## Components and paths

| Component | Location or responsibility |
|---|---|
| Pliik repository | `~/pliik-workstation/pliik`; workstation checkout |
| VS-CODE-IN-TERMUX | `~/pliik-workstation/VS-CODE-IN-TERMUX`; reference checkout |
| Projects directory | `~/pliik-workstation/projects`; created for development projects |
| Runtime | Node.js/npm and globally installed `pi-web` and Pi SDK packages |
| Server state and log | `~/.config/pliik-workstation/pi-web.pid` and `pi-web.log` |
| Management commands | `$PREFIX/bin/bin-dev-start`, `bin-dev-stop`, `bin-dev-status` |
| Web app | `pi-web-server`, accessed at `http://127.0.0.1:8504` |

The Go portal under `portal/` is a separate component and is not built or launched by the current installer.

## Operational notes

- Run the installer in Termux as a regular, non-root user.
- Keep the browser app limited to trusted users. Review its authentication and network binding before exposing it beyond the device.
- The installer clones the two repositories under `~/pliik-workstation`; it does not configure QEMU or Docker.
