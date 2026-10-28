# deploy

EiN on one Linux machine with podman or Docker and their compose. The installer on
[einhq.eu](https://einhq.eu) fetches this repository into `~/ein` and runs `setup.sh`:

```bash
curl -fsSL https://einhq.eu/install.sh | bash
```

What is installed is EiN and its database. The media service, the assistant's language model and
the modules are added to it with options, at the first install or any time after:

```bash
./setup.sh --ems              # the media service: every media tool and model, an image of about 30 GB
./setup.sh --llm              # the assistant's language model, Qwen3.5-4B in llama.cpp
./setup.sh --module archive   # a module, which EiN installs at its start with the modules it needs (archive needs ems)
./setup.sh                    # update: the newest sources of EiN and its services, rebuilt and restarted
./setup.sh --only ein         # update one service, ein, ems, db or llm, and restart only it
```

The installer passes the same options on: `curl … | bash -s -- --ems --module archive`. An option
chosen once is kept in `.env`; `--no-ems` and `--no-llm` leave one out again, and its data stays.
`./setup.sh --help` lists everything.

```
compose.yaml          EiN and PostgreSQL: the base every install runs
compose.ems.yaml      the media service, which --ems adds
compose.llm.yaml      the language model, which --llm adds
ein.Containerfile     core's own image with the web interface built in
setup.sh              fetches the sources, writes .env and compose.override.yaml, builds, starts

src/                  the sources setup.sh builds: core, db, and ems and llm with their options
.env                  the settings, with the passwords made at the install
compose.override.yaml the options in .env as services, and podman's restart policy, written by setup.sh
data/                 your files and the installed modules, unless EIN_DATA named another folder at the install
```

The last four are made here and are not in the repository. Back up `.env` and the data folder; the
database is the `ein_db` volume of the container engine, or the folder `--db-dir` named.

## Running it

`setup.sh` picks podman when it is installed and Docker otherwise (`EIN_ENGINE=docker` picks
Docker). After the install, compose works from this folder as usual, and with every compose: each
reads `compose.override.yaml` beside `compose.yaml` on its own, so the options are always in.

```bash
podman compose ps               # or docker compose
podman compose logs -f ein
podman compose down             # stop; `up -d` starts again
```

Port 8080 is the web interface and 2222 SSH and SFTP, on every address of the machine; when
something else on the machine has one, `setup.sh` takes the next free port and says so. Set
`EIN_BIND=127.0.0.1` in `.env` to keep them to the machine behind an HTTPS proxy of your own. The
database, the media service and the model are reached only by EiN, on the compose network.

A new instance prints its admin password once, and `setup.sh` shows it at the end; sign in as
`admin` and change it.

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
`mod install` in EiN's shell do the same. `setup.sh` does not update a module: Settings → Modules
does.

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

`.env` keeps them as `EIN_SOURCE` and `EIN_SOURCE_KEY`, so every update fetches from the same
place; `--source` again moves an installation to another. git gets the token as a header for each
call, so it is in no `.git/config`. From a Forgejo or a Gitea, EiN installs its modules from there
too: setup.sh writes `CFG_MODULE_SOURCES` and `CFG_MODULE_SOURCES_KEY` into `.env` for it, and
Settings → Modules lists that organisation's modules.

## The database

The database is the `ein_db` volume, in the container engine's storage, unless `--db-dir` names a
folder for it at the install (`EIN_DB_DIR` in `.env`). On a machine whose large disk is a spinning
one, put it on the SSD: searching the archive reads its vector indexes at random, a few milliseconds
a page on an SSD and tens of milliseconds on a spinning disk under load.

```bash
./setup.sh --db-dir /srv/ssd/ein-db
```

setup.sh gives the folder to the database image's postgres user before the database starts, so under
rootless podman it belongs to one of your subordinate ids: look into it with `podman unshare ls`. It
takes an empty folder, or one a database is in. A database already in the volume is not left
behind: setup.sh says how to copy it over first. A backup is the same either way:

```bash
podman compose exec db pg_dump -U ein -Fc ein >ein.dump
```

## Settings

`.env` is EiN's environment, so a `CFG_` setting for EiN goes there, and an `EMS_` one for the media
service; `podman compose up -d` applies it. A hosted language model instead of `--llm` is its
address, key and name there (`CFG_LLM_URL`, `CFG_LLM_KEY`, `CFG_LLM_PROVIDER`), with examples in the
file.

## The graphics card

The first `setup.sh` gives an NVIDIA card to the media service and the model when it finds one with
its CDI spec (`EIN_GPU=1` in `.env`): podman passes it always, Docker from Engine 28.2, where CDI is
on by default. The spec comes from nvidia-container-toolkit 1.18 and newer; ems's README sets it up.
Without a card everything runs on the processor, more slowly.

## Licence

MIT (`LICENSE`).
