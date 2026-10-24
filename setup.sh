#!/usr/bin/env bash
# Installs EiN on this machine, and updates it when run again: fetches the sources under src/,
# writes .env the first time, builds the images and starts them with compose.
#
#   ./setup.sh                    EiN and its database; run again, the newest sources of what is here
#   ./setup.sh --ems              also the media service: every media tool and model, about 30 GB
#   ./setup.sh --llm              also the assistant's language model
#   ./setup.sh --module archive   also a module, which EiN installs at its start with the modules it needs
#   ./setup.sh --no-ems --no-llm  leave an option out again; its data stays
#
# An option once chosen is kept in .env, so a later run without it keeps it. With podman or Docker,
# whichever is here (podman first; EIN_ENGINE=docker picks Docker), and its compose: `podman compose`
# or `docker compose`, which work from this folder afterwards as usual (ps, logs, down, up -d).
#
# Read the first time only, when .env is written:
#   EIN_DATA  the folder for your originals, the renditions, scratch space and the model (default: ./data)
#   EIN_GIT   where the sources are cloned from (default: https://github.com/einhq)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here"

main() {
  local want_ems= want_llm= modules=()
  while [ $# -gt 0 ]; do
    case $1 in
      --ems) want_ems=1 ;;
      --no-ems) want_ems=0 ;;
      --llm) want_llm=1 ;;
      --no-llm) want_llm=0 ;;
      --module)
        [ $# -ge 2 ] || fail "--module needs a name, such as archive"
        modules+=("$2")
        shift
        ;;
      -h | --help)
        sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
        return
        ;;
      *) fail "unknown option $1 (--help lists them)" ;;
    esac
    shift
  done

  pick_engine
  [ -f .env ] || write_env
  [ -z "$want_ems" ] || set_env EIN_EMS "$want_ems"
  [ -z "$want_llm" ] || set_env EIN_LLM "$want_llm"
  [ ${#modules[@]} = 0 ] || add_modules "${modules[@]}"
  # shellcheck disable=SC1091
  set -a && . ./.env && set +a
  write_override

  step "Fetching the sources"
  fetch core src/core
  fetch db src/db
  [ "$EIN_EMS" != 1 ] || fetch ems src/ems
  [ "$EIN_LLM" != 1 ] || fetch llm src/llm

  step "Building the images$([ "$EIN_EMS" != 1 ] || echo ' (the media service the first time: about 30 GB)')"
  build

  step "Starting EiN"
  mkdir -p "$EIN_DATA"/{files,old,files-volatile,files-tmp,llm,modules}
  # On an update, --force-recreate: older podman-compose starts the new images only when the config
  # changed. --remove-orphans: an option left out stops its service.
  local recreate=()
  [ -z "$("$engine" ps -aq --filter label=com.docker.compose.project=ein)" ] || recreate=(--force-recreate)
  compose up -d "${recreate[@]}" --remove-orphans
  wait_for_ein
}

pick_engine() {
  engine=${EIN_ENGINE:-}
  if [ -z "$engine" ]; then
    if command -v podman >/dev/null; then engine=podman; elif command -v docker >/dev/null; then engine=docker; else
      fail "neither podman nor Docker is installed"
    fi
  fi
  "$engine" compose version >/dev/null 2>&1 ||
    fail "'$engine compose' does not run: install podman-compose (or docker-compose) for podman, or the compose plugin for Docker"
}

compose() { "$engine" compose "$@"; }

# The settings, with passwords made here: nothing else keeps them, so this file is the one to back up.
write_env() {
  local data=${EIN_DATA:-$here/data} gpu=0
  mkdir -p "$data"
  data=$(cd "$data" && pwd)
  if nvidia-smi >/dev/null 2>&1 && { [ -s /var/run/cdi/nvidia.yaml ] || compgen -G '/etc/cdi/nvidia*.yaml' >/dev/null; }; then gpu=1; fi
  cat >.env <<EOF
# EiN's settings, written by setup.sh on $(date +%F). Keep this file: the passwords below are in it
# and nowhere else. compose reads it, and EiN and the media service get it as their environment, so
# a CFG_ line for EiN or an EMS_ line for the media service goes here too. Apply a change with
# ./setup.sh, or \`$engine compose up -d\` when no option changed.

# The options: the media service, the assistant's language model, and the graphics card for both.
# setup.sh --ems / --llm sets the first two; it found a card with its CDI spec, or did not.
EIN_EMS=0
EIN_LLM=0
EIN_GPU=$gpu

# The modules EiN installs at its start when it lacks them, with the modules they need, into the
# modules folder under EIN_DATA; setup.sh --module adds one. Settings → Modules lists the published
# ones, and installs, updates and removes them.
EIN_MODULES=""

# Your originals, the renditions, scratch space, the model and the modules, each in a folder of its
# own here.
EIN_DATA=$data
POSTGRES_PASSWORD=$(secret)
EMS_KEY=$(secret)
TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)

# The web interface and SSH, on every address of this machine. 127.0.0.1 keeps them to this machine,
# behind an HTTPS proxy of your own.
EIN_BIND=0.0.0.0
EIN_HTTP_PORT=8080
EIN_SSH_PORT=2222

# A hosted language model instead of --llm: its address (without /v1), key, name and model.
# CFG_LLM_URL=https://api.openai.com
# CFG_LLM_KEY=
# CFG_LLM_PROVIDER=OpenAI
# CFG_LLM_MODEL=

# Where the sources come from.
EIN_GIT=${EIN_GIT:-https://github.com/einhq}
EOF
  chmod 600 .env
  echo "Wrote .env: your files go under $data"
}

secret() { openssl rand -hex 24; }

set_env() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >>.env; fi
}

# What the options add to compose.yaml. Every compose reads compose.override.yaml beside it, so a
# plain `compose up -d` starts the same services as this script does.
write_override() {
  {
    echo "# Written by setup.sh from the options in .env; edit those and run setup.sh again."
    echo "services:"
    [ "$EIN_EMS" = 1 ] || [ "$EIN_LLM" = 1 ] || echo "  {}"
    local service option
    for service in ems llm; do
      option=EIN_${service^^}
      [ "${!option}" = 1 ] || continue
      echo "  $service:"
      echo "    extends: { file: compose.$service.yaml, service: $service }"
      [ "$EIN_GPU" != 1 ] || echo "    devices: [nvidia.com/gpu=all]"
    done
    if [ "$EIN_LLM" = 1 ]; then
      echo "  ein:"
      echo "    environment:"
      echo "      CFG_LLM_CARD: $([ "$EIN_GPU" = 1 ] && echo card || echo cpu)"
    fi
  } >compose.override.yaml
}

# A repository cloned the first time and moved to its newest commit after, so a run is an update.
fetch() {
  if [ -d "$2/.git" ]; then
    git -C "$2" pull --ff-only --quiet
  else
    git clone --quiet "$EIN_GIT/$1.git" "$2"
  fi
  echo "  $1 $(git -C "$2" log -1 --format='%h %cs')"
}

# Modules added to EIN_MODULES, each once. EiN installs them, and what they need, at its next start.
add_modules() {
  local name names
  read -ra names <<<"$(sed -n 's/^EIN_MODULES=//p' .env | tr -d '"')"
  for name in "$@"; do
    [[ $name =~ ^[a-z][a-z0-9-]*$ ]] || fail "--module takes a module's name, such as archive: $name"
    [[ " ${names[*]} " == *" $name "* ]] || names+=("$name")
  done
  set_env EIN_MODULES "\"${names[*]}\""
}

build() {
  # Under podman the build's scratch files go next to its storage: /tmp is often too small for the
  # media service's layers. Docker keeps them in its own storage already.
  if [ "$engine" = podman ]; then
    TMPDIR="$(podman info --format '{{.Store.GraphRoot}}')/tmp"
    mkdir -p "$TMPDIR"
    export TMPDIR
  fi
  if [ "$EIN_EMS" = 1 ]; then
    # What the media service's health reports as its build, as its own Makefile writes it.
    echo "$(git -C src/ems describe --always --dirty) $(git -C src/ems log -1 --format=%cI)" >src/ems/ems/BUILD
  fi
  # What core's system-info says it runs, as a tree without its .git says it: the commit and its date.
  git -C src/core log -1 --format='{"commit":"%h","date":"%cI"}' >src/core/src/build.json
  "$engine" build -t localhost/ein-core -f src/core/src/Containerfile src/core
  compose build
}

# EiN answers once its database is up and its boot is through. A new instance prints its admin
# password to the log, once.
wait_for_ein() {
  local url="http://127.0.0.1:$EIN_HTTP_PORT/" password
  for _ in $(seq 300); do
    if curl -fs -o /dev/null --max-time 5 "$url"; then
      echo
      echo "EiN is up at http://$(hostname):$EIN_HTTP_PORT/"
      password=$(compose logs ein 2>/dev/null | sed -n 's/.*Admin password set to: //p' | tail -1)
      [ -z "$password" ] || echo "Sign in as admin with the password $password, and change it: it is shown this once."
      return
    fi
    sleep 2
  done
  fail "EiN did not answer at $url in 10 minutes: $engine compose logs ein"
}

step() { printf '\n== %s\n' "$1"; }
fail() {
  echo "setup.sh: $1" >&2
  exit 1
}

main "$@"
