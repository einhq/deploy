# deploy

EiN on one Linux machine with podman or Docker and their compose. The installer on
[einhq.eu](https://einhq.eu) asks how EiN is to be installed, fetches this repository into `~/ein`
and runs `setup.sh` with the answers as its options:

```bash
curl -fsSL https://einhq.eu/install.sh | bash              # asks, each default shown
curl -fsSL https://einhq.eu/install.sh | bash -s -- --yes  # the defaults, asking nothing
```

`setup.sh` asks nothing. Every setting is an option of it, and the secrets come in the environment,
off the command line: `INITIAL_ADMIN_PASSWORD`, the admin's first password at the install (made
here when it is not given), and `EIN_SOURCE_KEY` (below).

What is installed is EiN and its database. The media service, the assistant's language model, the
Automation module's sidecar and the modules are added to it with options, at the first install or
any time after:

```bash
./setup.sh --ems              # the media service: every media tool and model, an image of about 30 GB
./setup.sh --llm              # the assistant's language model, Qwen3.5-4B in llama.cpp
./setup.sh --automation       # the Automation module's sidecar: an MQTT broker for its devices on port 1883,
                              # a listener for devices on the network, a restreamer for cameras
./setup.sh --module archive   # a module, which EiN installs at its start with the modules it needs (archive needs ems)
./setup.sh                    # update: this folder and the newest images, pulled and restarted
./setup.sh --only core        # update one service, core, ems, db, llm or automation, and restart only it
./setup.sh --http-port 8081   # the web interface's port; --ssh-port SSH and SFTP's
./setup.sh --bind 127.0.0.1   # listen on this machine alone, behind an HTTPS proxy of your own
```

At the first run only, when it writes `.env`: `--data DIR` names the data folder (default `./data`)
and `--engine podman|docker` the container engine.

The installer passes the same options on: `curl … | bash -s -- --ems --module archive`. An option
chosen once is kept in `.env`; `--no-ems`, `--no-llm` and `--no-automation` leave one out again, and
its data stays.
`./setup.sh --help` lists everything.

```
compose.yaml            EiN and PostgreSQL: the base every install runs
compose.ems.yaml        the media service, which --ems adds
compose.llm.yaml        the language model, which --llm adds
compose.automation.yaml the Automation module's sidecar, which --automation adds
setup.sh                updates this folder, writes .env and compose.override.yaml, pulls or builds the images, starts

src/                    the sources setup.sh fetches: ems and llm with their options, and core, db and
                        module-automation from your own
.env                    the settings, with the passwords made at the install
compose.override.yaml   the options in .env as services, and podman's restart policy, written by setup.sh
data/                   your files, the installed modules and the database, unless --data named another folder at the install
```

The last four are made here and are not in the repository. Every run of `setup.sh` first brings this
folder up to date from the source's `deploy` (a fast-forward `git pull`), and runs the new `setup.sh`
when that changed it, so an update takes the compose files and the script as they are now. A local
commit or change here that the pull cannot pass stops it, and `git status` says why. One run at a time:
a second waits for the first to end, under `flock` on this folder.

The images are pulled: GitHub builds them once a day from the `main` of their repositories, when it
has moved since the last build, EiN's as `ghcr.io/einhq/core:main` with the web interface built in,
the database's as `ghcr.io/einhq/db:main` (and again every week, for PostgreSQL's minor releases)
and the media service's as `ghcr.io/einhq/ems:main`; the automation sidecar's, `ghcr.io/einhq/automation:main`,
is built when its folder in module-automation changes. From another source they are built here
instead (below). The model's is llama.cpp's own.

Back up `.env` and the data folder, which holds the database too, unless `--db-dir` put it
elsewhere (below).

## Running it

`setup.sh` picks podman when it is installed and Docker otherwise (`--engine docker` picks
Docker), and keeps the engine in `.env`: a later run uses it, whichever else is installed. After the
install, compose works from this folder as usual, and with every compose: each reads
`compose.override.yaml` beside `compose.yaml` on its own, so the options are always in.

```bash
podman compose ps               # or docker compose
podman compose logs -f core
podman compose down             # stop; `up -d` starts again
```

Port 8080 is the web interface and 2222 SSH and SFTP, on every address of the machine; when
something else on the machine has one, `setup.sh` takes the next free port and says so. Set
`EIN_BIND=127.0.0.1` in `.env` to keep them to the machine behind an HTTPS proxy of your own. The
database, the media service and the model are reached only by EiN, on the compose network.

A program on another machine that uses the media service, such as a scanning station, reaches it
when `.env` sets `EIN_EMS_BIND` to this machine's address on your network (or `0.0.0.0`): the media
service is then published there, at `EIN_EMS_PORT` (18181). It answers plain HTTP, so only on a
network you trust. Give such a caller a key of its own in `ems.keys` beside `.env`, a line
`<key> <name> [<weight>]`, which `setup.sh` mounts into the media service when the file is there;
the weight is the caller's share when requests wait, and EiN keeps `EMS_KEY`. Run `./setup.sh` after
either.

Under rootless podman a port published on the compose network reaches EiN from an address of that
network, so EiN would see every client as that one address. There EiN gets a network of its own
instead, which keeps each client's address: pasta, or slirp4netns with its own port handler under
podman-compose before 1.1, which knows no pasta. It then reaches the database, the media service and
the model on the machine's loopback, where they are published on 127.0.0.1 alone: `EIN_DB_PORT`
(15432), `EIN_EMS_PORT` (18181) and `EIN_LLM_PORT` (18190), each moved to the next free port like
EiN's own. Under slirp4netns a proxy on the machine reaches EiN from 10.0.2.2, not from loopback, so
EiN believes the forwarding headers of 10.0.2.2 too (`TRUSTED_PROXIES`, which takes the addresses
`.env` names in it besides). When neither is installed, `setup.sh` says so, and
EiN stays on the compose network: install `passt`, which has pasta.

The admin account's first password is `INITIAL_ADMIN_PASSWORD` in `.env`, which EiN takes at its
first start. One chosen at the install, `INITIAL_ADMIN_PASSWORD` in `setup.sh`'s environment, is
removed from `.env` once EiN has answered. One made by `setup.sh` is shown at the end of every run
while its line is there: sign in as `admin`, change the password, and delete the line.

EiN starts again when the machine does, and `setup.sh` ends by saying whether it will. Docker's
daemon starts it when Docker is enabled at boot. Under podman, `podman-restart.service` starts it,
and only containers whose policy is `restart: always`, which `compose.override.yaml` gives every
service there. `setup.sh` enables that unit; under rootless podman it is a user unit, which runs at
boot only for a user who lingers, and `setup.sh` enables lingering too when the system lets it, or
names the command that does (`sudo loginctl enable-linger $USER`). A container stopped with
`podman compose stop` starts again at the next boot; `podman compose down` removes it, and it stays
down.

## Modules

EiN installs its modules itself, from their repositories (`einhq/module-<name>` on GitHub, or the
source's own, below), into
`modules/` in the data folder, which is mounted into EiN, so they stay when EiN is updated or its
container is made again. `EIN_MODULES` in `.env` names the ones it installs at its start when they
are missing, with the modules they need; `--module` adds one there. Settings → Modules in the web
interface lists every published module, and installs, updates and removes them; `mod search` and
`mod install` in EiN's shell do the same. A module is installed at its newest release that EiN's core can run, which is older than the newest
published when the image is older than the module. At each start EiN replaces an installed module
its core cannot run, as after an update that changed the module API, with the newest release it
can. `setup.sh` ends by listing the installed modules, each with its version and release, and what
EiN's start said of those it could not install or run. Otherwise `setup.sh` does not update a
module: Settings → Modules does.

## Installing from your own Forgejo or Gitea

Everything comes from GitHub's `einhq` unless `--source` names another organisation that has EiN's
repositories under the same names: `deploy`, `core`, `db`, `ems`, `llm` and the `module-*` ones,
such as a mirror on a Forgejo or a Gitea of your own, or the one EiN is developed on. Its token, when
the repositories are private, is `EIN_SOURCE_KEY` in the environment; a token that reads repositories
and organisations is enough. The installer takes both and fetches deploy from there too:

```bash
K=…   # the token
curl -fsSL -H "Authorization: token $K" 'http://forge.example:3000/api/v1/repos/ein/einhq.github.io/raw/install.sh?ref=main' \
  | EIN_SOURCE_KEY=$K bash -s -- --source http://forge.example:3000/ein --ems --module archive
```

`.env` keeps them as `EIN_SOURCE` and `EIN_SOURCE_KEY`, so every update fetches from the same place;
`--source` again moves an installation to another. A source on another host, such as GitHub again,
drops the token, unless `EIN_SOURCE_KEY` gives a new one with it. git gets the token as a header for
each call, so it is in no `.git/config`. From any source but GitHub's `einhq`, the images of EiN,
the database, the media service and the automation sidecar are built here from the sources of core,
db, ems and module-automation, as `localhost/ein-core`, `localhost/ein-db`, `localhost/ein-ems` and
`localhost/ein-automation`, since the published images have none of their own commits. The media service's build fetches its wheels and models for about an
hour. From a Forgejo or a Gitea, EiN installs its modules from there too: setup.sh writes
`CFG_MODULE_SOURCES` and `CFG_MODULE_SOURCES_KEY` into `.env` for it, and Settings → Modules lists
that organisation's modules.

## The database

The database is the folder `db` in the data folder, which a new install writes as `EIN_DB_DIR` in
`.env`, so a backup of the data folder holds it. `--db-dir` names another folder for it. On a machine
whose large disk is a spinning one, put it on the SSD: searching the archive reads its vector indexes
at random, a few milliseconds a page on an SSD and tens of milliseconds on a spinning disk under load.
An install whose `EIN_DB_DIR` is empty keeps it in the `ein_db` volume, in the container engine's
storage.

```bash
./setup.sh --db-dir /srv/ssd/ein-db
```

setup.sh gives the folder to the database image's postgres user before the database starts, so under
rootless podman it belongs to one of your subordinate ids: look into it with `podman unshare ls`. It
takes an empty folder, or one a database is in. A database already in the volume is not left
behind: setup.sh says how to copy it over first. A copy of the folder is a backup only while the
database is stopped (`podman compose stop db`), and under rootless podman it is read with `podman
unshare`. A dump is one while it runs, wherever it is:

```bash
podman compose exec db pg_dump -U ein -Fc ein >ein.dump
```

## Settings

`.env` is EiN's environment, so a `CFG_` setting for EiN goes there, and an `EMS_` one for the media
service; `podman compose up -d` applies it. Under podman-compose, a container that makes again has
no swap limit, which `setup.sh` gives each one: the media service's idle models then go to swap, and
a search waits for them. `./setup.sh` makes the containers again with it. A hosted language model instead of `--llm` is its
address, key and name there (`CFG_LLM_URL`, `CFG_LLM_KEY`, `CFG_LLM_PROVIDER`), with examples in the
file.

The media service mounts none of EiN's folders: it reaches the files of each request through EiN's
`ems-files` service, at `CFG_EMS_FILES_ADDRESS`, with an sshfs mount, for which its container has
`/dev/fuse`, the `SYS_ADMIN` capability and no AppArmor profile, since Docker's default one denies
the mount. `./setup.sh` writes the address: EiN's name on the
compose network, or, when EiN has a network of its own under rootless podman, this machine's address
(`host.containers.internal`), where it publishes `CFG_EMS_FILES_PORT` (2224) on `EIN_BIND`. A media
service on another machine is `CFG_EMS_FILES_ADDRESS` in `.env`, the `host:port` it reaches this
machine at, and `./setup.sh` publishes the port for it. The kernel reads ahead only
128 KiB on such a mount; on the machine the media service runs on, a udev rule raises it for every
new one, a moment after the mount, when the setting holds:

```bash
echo 'ACTION=="add", SUBSYSTEM=="bdi", KERNEL=="0:*", RUN+="/bin/sh -c '\''sleep 1; echo 4096 > /sys/class/bdi/%k/read_ahead_kb'\''"' | sudo tee /etc/udev/rules.d/90-fuse-readahead.rules
sudo udevadm control --reload
```

`--automation` runs the Automation module's sidecar, one container on this machine's own network
with three services in it. Its broker takes no anonymous clients. EiN signs in as `ein` and the
devices as `device`, with the passwords `MQTT_EIN_PASSWORD` and `MQTT_DEVICE_PASSWORD` that
`./setup.sh` made in `.env`; give a device the broker's address (this machine, port `MQTT_PORT`,
1883), the user `device` and that password. Changing a password there takes effect at the next
`./setup.sh`. The broker is plain MQTT on your network, without TLS: keep port 1883 off the internet.

Its listener asks what is on the network every two minutes over mDNS and SSDP, hears mDNS
announcements in between on port 5353 beside any responder already there such as Avahi, and
publishes the answers on the broker, where the Automation module names them and offers the ones it
can take as devices (Devices → _found_). A Shelly is added from there: EiN gives it the broker's
address and the `device` account itself. It sends multicast on the network this machine is on, and
nothing leaves it.

Its restreamer, go2rtc, keeps one connection to each camera EiN has and serves it again: to EiN,
which shows it in the browser, on `STREAMS_PORT` (1984), and over RTSP on `RTSP_PORT` (8554), where
the media service reads it to watch it for faces, both behind the account `ein` and
`STREAMS_PASSWORD`. A media service on another machine reads it at this machine's address on the
network: set `CFG_AUTOMATION_STREAMS_RTSP` in `.env` to `rtsp://<this machine>:8554`. EiN gives it the cameras itself; the camera's own password stays with EiN and the sidecar.
On this machine RTSP lets anyone in without a password, as go2rtc does for every local client. Keep
these ports off the internet too.

Under Docker and rootful podman, EiN reaches the sidecar at this machine's address on the compose
network, so it needs `EIN_BIND` to be `0.0.0.0`; `setup.sh` says so when it is not.

## The graphics card

The first `setup.sh` gives an NVIDIA card to the media service and the model when it finds one with
its CDI spec (`EIN_GPU=1` in `.env`): podman passes it, Docker from Engine 28.2, where CDI is on by
default. The spec comes from nvidia-container-toolkit 1.18 and newer; ems's README sets it up.
Podman before 5 (4.9.3 on Ubuntu 24.04 and Mint 22) rejects the spec the toolkit 1.17 and newer
writes (`unknown field "additionalGids"`) and the containers find no card; with `--ems`,
`sudo bash src/ems/deploy/install-cdi-refresh.sh` makes the spec readable to it after every refresh.
The installer reports both. Without a card everything runs on the processor, more slowly.

## Licence

MIT (`LICENSE`).
