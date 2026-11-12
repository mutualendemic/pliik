# Pliik Workstation Architecture

The installer runs Pi Web and the Go administration portal directly in Termux. It does not install or run Code Server or another browser-based editor.

## Runtime architecture

```mermaid
flowchart LR
    User[Developer] --> Browser[Android browser\nhttp://127.0.0.1:8080/admin]
    Browser -->|local HTTP| Portal[pliik-portal admin]
    Browser -->|local HTTP| PiWeb[pi-web-server\n127.0.0.1:8504]
    Portal -->|local project API| PiWeb
    PiWeb -->|Unix socket| Socket[sessiond.sock]

    subgraph Android[Android device]
        subgraph Termux[Termux]
            PiWeb
            Portal
            SessionDaemon[pi-web-sessiond]
            Socket
            TermuxRuntime[Termux-native Node.js/npm]
            Go[Go runtime and portal binary]
            SDK[Pi coding agent SDK]
            Repos["~/pliik-workstation/pliik/"]
            Projects["~/pliik-workstation/projects/"]
            Helpers["bin-dev-start\nbin-dev-stop\nbin-dev-status"]
            Config["~/.config/pliik-workstation/\nservice PID files and logs"]
        end
    end

    TermuxRuntime --> PiWeb
    Go --> Portal
    SessionDaemon --> Socket
    SDK --> PiWeb
    SDK --> SessionDaemon
    Helpers --> PiWeb
    Helpers --> Portal
    Portal --> Config
    PiWeb --> Config
```

The portal is available only through the loopback listener at `127.0.0.1:8080`. Its sole management page is `/admin`; `/` and the former `/portal` URL redirect there. Pi Web has its own loopback URL at port 8504. The portal uses Pi Web's local project API to register cloned repository folders; it does not proxy Pi Web or provide an editor/workspace interface.

The installer launches `pi-web-server`, `pi-web-sessiond`, and the Go portal, supplies `PI_WEB_PI_PACKAGE_DIR` to the Pi Web processes, and waits for `~/.pi-web/sessiond.sock` before starting the web server. It builds the portal from `portal/` and installs the executable at `$PREFIX/bin/pliik-portal`. Management commands are written to `$PREFIX/bin` and start, stop, and report status for the services. On upgrades, the installer also stops and uninstalls the former global Code Server package and removes its Termux platform shim.

## Installation and startup flow

```mermaid
flowchart TD
    Start[Run installer in Termux as regular user]
    Base[Install Git, curl, wget, and OpenSSL packages]
    Runtime[Ensure Node.js and npm]
    PiWeb[Install pi-web if missing]
    SDK[Ensure global Pi coding agent SDK]
    Checkout[Clone or update Pliik]
    LegacyCleanup[Remove legacy Code Server install, if present]
    BuildPortal[Build and install pliik-portal]
    Commands[Create service management commands]
    Sessiond[Start pi-web-sessiond and wait for sessiond.sock]
    Server[Start Pi Web and portal]
    Ready[Open Pi Web :8504 and admin portal :8080/admin]

    Start --> Base --> LegacyCleanup --> Runtime --> PiWeb --> SDK --> Checkout --> BuildPortal --> Commands --> Sessiond --> Server --> Ready
```

## Components and paths

| Component | Location or responsibility |
|---|---|
| Pliik repository | `~/pliik-workstation/pliik`; workstation checkout |
| Projects directory | `~/pliik-workstation/projects`; repository folders registered with Pi Web |
| Runtime | Node.js/npm, Go, globally installed `pi-web`, and Pi SDK packages |
| Pi Web | `http://127.0.0.1:8504` |
| Management portal | `$PREFIX/bin/pliik-portal`, accessed at `http://127.0.0.1:8080/admin` (unauthenticated, loopback only) |
| Server state and logs | PID files and logs for Pi Web and portal under `~/.config/pliik-workstation/` |
| Session daemon state and log | `~/.config/pliik-workstation/pi-web-sessiond.pid` and `pi-web-sessiond.log` |
| Session daemon socket | `~/.pi-web/sessiond.sock` |
| Management commands | `$PREFIX/bin/bin-dev-start`, `bin-dev-stop`, `bin-dev-status` |

The Go portal source is under `portal/`; the installer builds it and installs the executable to `$PREFIX/bin/pliik-portal`.

## Operational notes

- Run the installer in Termux as a regular, non-root user.
- Pi Web and the administration portal are local services. Do not expose them to a LAN, public network, or untrusted users. The portal can manage GitHub credentials and projects and has no authentication.
- The start command acquires an optional Termux wakelock; disable Android battery optimization for Termux to reduce background process suspension.
- The installer keeps project data under `~/pliik-workstation/projects`; removing Code Server does not delete existing repository folders.
