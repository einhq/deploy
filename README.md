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
./setup.sh --module archive   # a module, cloned into modules/ with the modules it needs (archive needs ems)
./setup.sh                    # update: the newest sources of everything here, rebuilt and restarted
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
modules/              the modules, mounted into EiN and set up at every start
.env                  the settings, with the passwords made at the install
compose.override.yaml the options in .env as services, written by setup.sh
data/                 your files, unless EIN_DATA named another folder at the install
```

The last five are made here and are not in the repository. Back up `.env` and the data folder; the
database is the `ein_db` volume of the container engine.

## Running it

`setup.sh` picks podman when it is installed and Docker otherwise (`EIN_ENGINE=docker` picks
Docker). After the install, compose works from this folder as usual, and with every compose: each
reads `compose.override.yaml` beside `compose.yaml` on its own, so the options are always in.

```bash
podman compose ps               # or docker compose
podman compose logs -f ein
podman compose down             # stop; `up -d` starts again
```

Port 8080 is the web interface and 2222 SSH and SFTP, on every address of the machine. Set
`EIN_BIND=127.0.0.1` in `.env` to keep them to the machine behind an HTTPS proxy of your own. The
database, the media service and the model are reached only by EiN, on the compose network.

A new instance prints its admin password once, and `setup.sh` shows it at the end; sign in as
`admin` and change it.

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
