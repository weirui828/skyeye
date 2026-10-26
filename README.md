# SkyEye

A macOS menu bar app that keeps an eye on your local dev services: it starts and stops
them, watches their ports and health checks, keeps their logs, and lets you (via `sky`) or
your coding agent (via MCP) control everything. Open SkyEye from the menu bar to manage
services in the card-based menu. The **Canvas** button opens an optional dependency window.

[![macOS CI](https://github.com/weirui828/skyeye/actions/workflows/ci.yml/badge.svg)](https://github.com/weirui828/skyeye/actions/workflows/ci.yml)

**Early developer preview.** Expect rough edges and changes to the UI. macOS 14 or
newer is required. The app supports Apple Silicon and Intel Macs.

## Screenshots

Native SkyEye views with demonstration services, using a separate demo configuration.

<img src="docs/images/service-menu.png" alt="SkyEye service cards with grouped services, live usage, and a Canvas button" width="400">

![Dependency canvas with apps above their shared dependencies](docs/images/dependency-canvas.png)

## Install the Mac app

A packaged release does not require Xcode, a terminal, or `install.sh`:

1. Download the DMG from [Releases](https://github.com/weirui828/skyeye/releases) when a
   signed release is available.
2. Open the DMG and drag **SkyEye.app** into **Applications**.
3. Open SkyEye from Applications. Its telescope icon appears in the menu bar.
4. Add a service with its start command and directory. Open **Canvas** to connect dependencies.

**No notarized public download has been published yet.** Current CI artifacts are
ad-hoc signed developer builds, which macOS may block when downloaded. Use the source
build below until a signed, notarized release is available.

To update a packaged app, quit SkyEye and replace it in Applications with the newer
version. Your services and logs are stored separately and remain intact. There is
no automatic updater yet.

### Optional command-line tools

The app and the AI agent setup in Settings work without installing CLI links. To make
`sky` and `skyeye-mcp` available in your terminal after installing in Applications:

```bash
mkdir -p "$HOME/.local/bin"
ln -sfn /Applications/SkyEye.app/Contents/MacOS/sky "$HOME/.local/bin/sky"
ln -sfn /Applications/SkyEye.app/Contents/MacOS/skyeye-mcp "$HOME/.local/bin/skyeye-mcp"
export PATH="$HOME/.local/bin:$PATH"
```

Add the PATH line to your shell profile if needed. If you installed the app elsewhere,
use that location in the links. Settings generates agent setup commands from the
actual installed app path, so no particular username or install directory is required.

## Build from source

Requires Xcode 15.3+ with Swift 5.10+ and the macOS SDK.

```bash
git clone https://github.com/weirui828/skyeye.git
cd skyeye
./scripts/install.sh
```

The installer builds the app, copies it to `~/Applications`, and links `sky` and
`skyeye-mcp` into `~/.local/bin`. Canceling the app's quit prompt aborts installation;
it never force-quits SkyEye. To build without installing:

```bash
./scripts/build.sh
open build/SkyEye.app
```

### Tests and packages

```bash
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests -v
./scripts/package.sh                 # universal .app, .dmg, .zip, and SHA-256 checksums
swift scripts/make-icon.swift        # regenerate bundled icon artwork
```

Generated packages stay under `build/` and are ignored by Git. CI tests Apple Silicon
and Intel builds and uploads universal developer preview packages for review.
See [Preparing a Mac release](docs/RELEASING.md) for signing and notarization.

## CLI

```bash
sky add api --cmd "npm run dev" --port 3000 --health /health --group shop   # dir defaults to $PWD
sky start api          # waits until the port is open and the health check passes
sky start @shop        # every service in a group
sky list
sky logs api -f
sky port 3000 --kill   # free a port held by something else
sky edit api --port 3001 --env DEBUG=1
```

`sky --help` lists everything.

## Dependency canvas

**Settings → General → Start with SkyEye** chooses which services start when the app
opens: None (default), Selected services, or All services. Selections apply on the
next app launch, include dependencies, and still require command approval. All services
includes services added later; monitor-only services are skipped. Already-running services
are reused, including services taken back over after quitting with keep-running enabled.

The menu remains the default view. Click **Canvas** above the service cards to open a
movable, zoomable DAG in a larger window. Closing the canvas returns you to the menu bar app.
The canvas shows service cards. Arrows point from a
prerequisite to its dependent: `psql → api → vibecab`. Shared prerequisites appear once.
Group names stay on cards; the Groups menu starts or stops services in a group.

- Drag a card's top bar to move it; drag the empty canvas to pan. Use zoom and **Fit**
  to navigate. Positions are remembered between launches.
- Drag a service's connector onto a dependent card to create a dependency. Alternatively,
  click the source connector, then click the target connector. Self-links and cycles are rejected.
- The dependency menu on a card removes links. The service editor also has a **Depends on** picker.
- Dependency changes automatically arrange the affected cards and their dependents, leaving
  unrelated cards in place. **Arrange all** restores the vertical layout, with apps above their dependencies and arrows pointing upward.
- Hover over a card for start/stop, restart, browser, logs, and edit/approval actions.

Dependencies also work through the CLI and MCP:

```bash
sky edit vibecab --depends-on psql,redis
sky start vibecab --timeout 180
sky edit vibecab --depends-on none
```

MCP `add_service` and `update_service` accept `dependencies: ["psql", "redis"]`.
Starting a service starts its prerequisites recursively and waits for each to become ready
(port open and health check passing, when configured). Already-running prerequisites are
reused. Workers without a port count as ready once spawned. Monitor-only prerequisites
must already be running externally. Every command in the chain must be approved.
If a prerequisite fails or times out, the dependent stays stopped with a startup error;
successfully started prerequisites are left running for other services to reuse.

Stopping an app leaves its prerequisites running. On the canvas, stopping a prerequisite
with active dependents asks to stop those dependents first. Renaming a service updates
its dependency links; remove incoming links before deleting a service.

## AI agents (MCP)

```bash
claude mcp add skyeye -- skyeye-mcp
codex mcp add skyeye -- skyeye-mcp
gemini mcp add skyeye skyeye-mcp
```

Tools: `list_services`, `get_service`, `add_service`, `update_service`, `remove_service`,
`start_service`, `stop_service`, `restart_service`, `get_logs`, `check_port`.
`start_service` waits for the service to come up and returns the last log lines if it fails.

## Approval

A service added or changed from the CLI or MCP can't run until you click **Approve** in the
app (you get a notification). Approval is tied to the command, directory and
environment, so changing any of them asks again. Services you add in the app are approved
automatically. You can turn this off in Settings, but anything that can add a service could
then run commands on your machine.

## How it works

- **SkyEyeCore**: config, process management, port/health probes, and a control API on a
  Unix socket (`~/Library/Application Support/SkyEye/skyeye.sock`, owner-only).
- **SkyEyeApp**: the card-based menu and optional dependency canvas; hosts the core and socket server.
- **sky** / **skyeye-mcp**: thin clients of the socket. They launch the app if it isn't running.

Commands run through your login shell (`zsh -i -l -c`) in their own session, so nvm/asdf/mise
work and stopping a service also stops everything it spawned. Quitting SkyEye stops the
services it started, unless **Keep services running when SkyEye quits** is on in Settings
(`keepRunningOnQuit` in config.json): then they keep running and SkyEye takes them back over
the next time it opens.

Status: `starting` until the port opens (and the health check passes, if set), then
`running`; `unhealthy` if it stops responding; `crashed` on a non-zero exit (auto-restart
optional, 5 attempts with backoff); `external` when the port is held by a process SkyEye didn't
start.

Files:
- Config: `~/Library/Application Support/SkyEye/config.json`
- Logs: `~/Library/Logs/SkyEye/<name>.log`

## Log retention

**Settings → Logs → Retention** offers 1 day, **7 days** (default), 30 days, or
Keep forever. Cleanup runs when SkyEye starts, hourly while it is running, and when
the setting changes. It removes expired archives and inactive logs, preserving active logs.

Services started by the updated app rotate their output daily, on the first output
after midnight. Archives are stored under `~/Library/Logs/SkyEye/archive/<name>/`.
The log viewer and `sky logs` include recent archived history; `sky logs -f` follows
the current log across rotation. Services left running when SkyEye quits continue
logging and rotating; cleanup resumes when SkyEye reopens. Existing services pick up
daily rotation on their next restart.

Service definitions and logs live outside this Git repository and are not included
when pushing the repository to GitHub.

## License

[MIT](LICENSE)
