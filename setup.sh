#!/usr/bin/env bash
# Installs EiN on this machine, and updates it when run again: brings this folder up to date from
# the source's deploy, fetches the sources under src/, writes .env the first time, pulls EiN's image
# and builds the others, and starts them with compose.
#
#   ./setup.sh                    EiN and its database; run again, the newest sources of what is here
#   ./setup.sh --ems              also the media service: every media tool and model, about 30 GB
#   ./setup.sh --llm              also the assistant's language model
#   ./setup.sh --module archive   also a module, which EiN installs at its start with the modules it needs
#   ./setup.sh --no-ems --no-llm  leave an option out again; its data stays
#   ./setup.sh --only ein         update one service, ein, ems, db or llm, and restart only it
#   ./setup.sh --source URL       fetch the sources and the modules from this organisation instead
#   ./setup.sh --db-dir DIR       keep the database in this folder instead of the engine's storage
#
# An option once chosen is kept in .env, so a later run without it keeps it. With podman or Docker,
# whichever is here (podman first; EIN_ENGINE=docker picks Docker), and its compose: `podman compose`
# or `docker compose`, which work from this folder afterwards as usual (ps, logs, down, up -d). The
# engine is kept in .env too: a later run uses it, whichever else is installed. Under podman-compose,
# a container that `podman compose up -d` makes again, after a change to .env, has no swap limit:
# this script gives each one (see start), and a run of it gives it back. An update that came up
# removes the images it replaced, and says how much that freed.
#
# --source names an organisation on GitHub, Forgejo or Gitea that has EiN's repositories under their
# own names (default: https://github.com/einhq), such as http://forge.example:3000/ein. When it is a
# Forgejo or a Gitea, EiN installs its modules from there too. EiN's image is pulled from GitHub's
# registry only from https://github.com/einhq, which publishes it, and built here from any other
# source's core. EIN_SOURCE_KEY in the environment is the token that reads it, when its repositories
# are private; it is kept in .env with the source.
#
# Read the first time only, when .env is written:
#   EIN_DATA       the folder for your originals, the renditions, scratch space and the model (default: ./data)
#   EIN_HTTP_PORT  the web interface's port (default: 8080, or the next free one)
#   EIN_SSH_PORT   SSH and SFTP's port (default: 2222, or the next free one)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here"

# EiN's image as compose.yaml names it, which GitHub publishes from core.
ein_image=ghcr.io/einhq/core:main

main() {
  local args=("$@") want_ems= want_llm= modules=() source= db_dir= only= key=${EIN_SOURCE_KEY:-} options=0
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
      --source)
        [ $# -ge 2 ] || fail "--source needs an organisation's address, such as https://github.com/einhq"
        source=${2%/}
        [[ $source =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._-]+$ ]] ||
          fail "--source takes an organisation's address, such as https://github.com/einhq or http://forge.example:3000/ein: $2"
        shift
        ;;
      --db-dir)
        [ $# -ge 2 ] || fail "--db-dir needs a folder"
        db_dir=$2
        shift
        ;;
      --only)
        [ $# -ge 2 ] || fail "--only needs a service: ein, ems, db or llm"
        only=$2
        shift 2
        continue
        ;;
      -h | --help)
        sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
        return
        ;;
      *) fail "unknown option $1 (--help lists them)" ;;
    esac
    options=$((options + 1))
    shift
  done

  update_self "$source" "${args[@]}"
  pick_engine
  if [ -n "$only" ]; then
    [ "$options" = 0 ] || fail "--only updates what is installed: give the other options without it"
    [ -f .env ] || fail "--only updates an installation: run ./setup.sh first"
    load_env
    # podman-compose 1.0 hashes the whole project's config: after a change to the override, starting
    # one service makes every container again, with that one's swap limit, which the database's
    # start refuses. Then every service starts again, each on its own (start).
    local override
    override=$(cat compose.override.yaml 2>/dev/null || true)
    write_override
    if [ "$compose_tool" != podman-compose ] || [ "$(cat compose.override.yaml)" = "$override" ]; then
      update_one "$only"
      return
    fi
    echo "compose.override.yaml changed, so every service is updated and started again, not $only alone"
  fi

  [ -f .env ] || write_env
  [ -z "$want_ems" ] || set_env EIN_EMS "$want_ems"
  [ -z "$want_llm" ] || set_env EIN_LLM "$want_llm"
  [ ${#modules[@]} = 0 ] || add_modules "${modules[@]}"
  [ -z "$key" ] || set_env EIN_SOURCE_KEY "$key"
  [ -z "$source" ] || set_source "$source"
  [ -z "$db_dir" ] || set_db_dir "$db_dir"
  load_env
  module_sources
  write_override

  step "Fetching the sources"
  ! ein_built || fetch core src/core
  fetch db src/db
  [ "$EIN_EMS" != 1 ] || fetch ems src/ems
  [ "$EIN_LLM" != 1 ] || fetch llm src/llm

  step "Getting the images$([ "$EIN_EMS" != 1 ] || echo ' (the media service the first time: about 30 GB)')"
  local old
  old=$(built_images)
  build

  step "Starting EiN"
  mkdir -p "$EIN_DATA"/{files,old,files-volatile,files-tmp,llm,modules}
  prepare_db_dir
  free_ports
  # A network podman made before it could give names keeps without them: down takes it away with
  # the containers, and up makes it again.
  if [ "$engine" = podman ] && [ "$(podman network inspect --format '{{.DNSEnabled}}' ein_default 2>/dev/null)" = false ]; then
    compose down
  fi
  # On an update, --force-recreate: older podman-compose starts the new images only when the config
  # changed. --remove-orphans: an option left out stops its service. podman-compose's
  # --force-recreate takes every service down first anyway, so there they are taken down and started
  # one by one (start).
  if [ "$compose_tool" = podman-compose ]; then
    compose down --remove-orphans
    start db ein ems llm
  else
    local recreate=()
    [ -z "$("$engine" ps -aq --filter label=com.docker.compose.project=ein)" ] || recreate=(--force-recreate)
    compose up -d "${recreate[@]}" --remove-orphans
  fi
  check_db_mount
  wait_for_ein
  remove_replaced $old
  after_reboot
  modules_need
}

# One service fetched, built and restarted, the others left running: an update of EiN alone does not
# restart the media service, the model or the database.
update_one() {
  case $1 in
    ein) ! ein_built || fetch core src/core ;;
    db) fetch db src/db ;;
    ems | llm)
      local option=EIN_${1^^}
      [ "${!option}" = 1 ] || fail "$1 is not installed here: ./setup.sh --$1 adds it"
      fetch "$1" "src/$1"
      ;;
    *) fail "--only takes ein, ems, db or llm, not $1" ;;
  esac
  step "Getting $1's image"
  local old
  old=$(built_images)
  build "$1"
  [ "$1" != db ] || prepare_db_dir
  # EiN goes and comes back with the database: podman keeps a container that another requires.
  if [ "$1" = db ]; then recreate ein db; else recreate "$1"; fi
  case $1 in
    db) check_db_mount && wait_for_ein ;;
    ein) wait_for_ein ;;
  esac
  remove_replaced $old
}

# The services' containers replaced by new ones from their images, and nothing else touched. Not
# compose's own --force-recreate: podman-compose 1.0 takes the services' dependencies down with
# them, --no-deps or not.
recreate() {
  step "Restarting $*"
  local service ids
  for service in "$@"; do
    ids=$("$engine" ps -aq --filter label=com.docker.compose.project=ein --filter "label=com.docker.compose.service=$service")
    [ -z "$ids" ] || { "$engine" stop -t 60 $ids >/dev/null && "$engine" rm $ids >/dev/null; }
  done
  if [ "$compose_tool" = podman-compose ]; then start "$@"; else compose up -d --no-deps "$@"; fi
}

# The services named, of those installed, started one by one in the order a service needs the one
# before it, under podman-compose. It never reads memswap_limit, and podman then lets a container
# swap as much again as its memory limit: EMS's idle search models went to swap, and a search waited
# for them. Each service is started on its own, its swap limit the memory limit podman-compose gives
# it (from a dry run), as every compose file here has it. Kept in the container's config, it holds
# through a restart; a plain `podman compose up -d` that creates a container leaves it out.
start() {
  local service mem
  for service in db ein ems llm; do
    [[ " $* " == *" $service "* ]] || continue
    case $service in ems | llm) local option=EIN_${service^^}; [ "${!option}" = 1 ] || continue ;; esac
    # The dry run writes its commands to stderr, the services this one needs too: 1.0 ignores --no-deps.
    mem=$(compose --dry-run up -d --no-deps "$service" 2>&1 |
      sed -n "/^podman run .* --label com.docker.compose.service=$service /s/.* -m \([^ ]*\) .*/\1/p" | tail -1)
    if [ -n "$mem" ]; then
      compose --podman-run-args="--memory-swap=$mem" up -d --no-deps "$service"
    else
      compose up -d --no-deps "$service"
    fi
  done
}

# A module that needs a service which is not installed here, said last, where it is read. The
# Archive's photos, videos and documents are analysed by the media service.
modules_need() {
  if [[ " ${EIN_MODULES:-} " == *" archive "* ]] && [ "$EIN_EMS" != 1 ]; then
    echo "The Archive module needs the media service, which is not installed here: ./setup.sh --ems adds it."
  fi
}

# The engine kept in .env, or on the first run EIN_ENGINE, else podman, else Docker. Under the other
# engine EiN would be a second one beside the first, without its database.
pick_engine() {
  local kept=
  [ ! -f .env ] || kept=$(sed -n 's/^EIN_ENGINE=//p' .env)
  if [ -n "$kept" ] && [ -n "${EIN_ENGINE:-}" ] && [ "$EIN_ENGINE" != "$kept" ]; then
    fail "EiN here runs under $kept (EIN_ENGINE in .env); under $EIN_ENGINE it would be a second, empty EiN beside it. Run ./setup.sh without EIN_ENGINE=$EIN_ENGINE"
  fi
  engine=${kept:-${EIN_ENGINE:-}}
  if [ -z "$engine" ]; then
    if command -v podman >/dev/null; then engine=podman; elif command -v docker >/dev/null; then engine=docker; else
      fail "neither podman nor Docker is installed"
    fi
  fi
  case $engine in podman | docker) ;; *) fail "EIN_ENGINE is podman or docker, not $engine" ;; esac
  command -v "$engine" >/dev/null || fail "EiN here runs under $engine, which is not installed"
  "$engine" compose version >/dev/null 2>&1 ||
    fail "'$engine compose' does not run: install podman-compose (or docker-compose) for podman, or the compose plugin for Docker"
  # docker-compose under podman, when it is installed and podman-compose is not: it reaches podman
  # through podman's socket, and builds through it too rather than with a docker command.
  compose_tool=
  if [ "$engine" = podman ] && [[ $(podman compose version 2>&1) == *podman-compose* ]]; then compose_tool=podman-compose; fi
  if [ "$engine" = podman ] && [ "$compose_tool" != podman-compose ]; then
    export COMPOSE_DOCKER_CLI_BUILD=0
    curl -sf -o /dev/null --unix-socket "$(podman info --format '{{.Host.RemoteSocket.Path}}')" http://d/_ping ||
      fail "'podman compose' runs docker-compose here, which needs podman's socket: systemctl --user enable --now podman.socket, then ./setup.sh again"
  fi
  # Under podman's older network backend, CNI, containers find each other by name only with its
  # dnsname plugin, and EiN finds its database by the name db.
  if [ "$engine" = podman ] && [ "$(podman info --format '{{.Host.NetworkBackend}}')" = cni ] && ! has_dnsname; then
    fail "podman's networks here give no names, which EiN needs to find its database: install podman's CNI plugin dnsname (Debian and Ubuntu: golang-github-containernetworking-plugin-dnsname; Fedora: podman-plugins), then ./setup.sh again"
  fi
  [ ! -f .env ] || [ -n "$kept" ] || set_env EIN_ENGINE "$engine"
}

has_dnsname() {
  local dir
  for dir in /usr/local/libexec/cni /usr/libexec/cni /usr/local/lib/cni /usr/lib/cni /opt/cni/bin; do
    [ ! -x "$dir/dnsname" ] || return 0
  done
  return 1
}

compose() { "$engine" compose -p ein "$@"; }

# The settings, with passwords made here: nothing else keeps them, so this file is the one to back up.
write_env() {
  local data=${EIN_DATA:-$here/data} gpu=0
  # A database from an earlier install has the password of that install's .env, which a new one
  # does not know: EiN would not get in.
  ! "$engine" volume inspect ein_db >/dev/null 2>&1 ||
    fail "the database of an earlier install is here, the volume ein_db, and its password was in the .env that is gone. Put that .env back, or remove the database for a new one: $engine volume rm ein_db"
  mkdir -p "$data"
  data=$(cd "$data" && pwd)
  if nvidia-smi >/dev/null 2>&1 && { [ -s /var/run/cdi/nvidia.yaml ] || compgen -G '/etc/cdi/nvidia*.yaml' >/dev/null; }; then gpu=1; fi
  cat >.env <<EOF
# EiN's settings, written by setup.sh on $(date +%F). Keep this file: the passwords below are in it
# and nowhere else. compose reads it, and EiN and the media service get it as their environment, so
# a CFG_ line for EiN or an EMS_ line for the media service goes here too. Apply a change with
# ./setup.sh, or \`$engine compose up -d\` when no option changed.$(swap_note)

# The compose project's name, which names its containers, network and volumes.
COMPOSE_PROJECT_NAME=ein

# The container engine, podman or docker, which setup.sh picked at the install and keeps to: under
# the other one EiN would be a second, empty one.
EIN_ENGINE=$engine

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

# The admin account's first password, which EiN takes at its first start; changing it here later
# does nothing. setup.sh shows it at the end of each run until you delete this line: do that once
# you have changed the password in EiN.
INITIAL_ADMIN_PASSWORD=$(openssl rand -hex 8)

# The web interface and SSH, on every address of this machine. 127.0.0.1 keeps them to this machine,
# behind an HTTPS proxy of your own.
EIN_BIND=0.0.0.0
EIN_HTTP_PORT=${EIN_HTTP_PORT:-8080}
EIN_SSH_PORT=${EIN_SSH_PORT:-2222}

# A hosted language model instead of --llm: its address (without /v1), key, name and model.
# CFG_LLM_URL=https://api.openai.com
# CFG_LLM_KEY=
# CFG_LLM_PROVIDER=OpenAI
# CFG_LLM_MODEL=

# Where the sources come from: an organisation with EiN's repositories under their own names, and
# the token that reads them when they are private. setup.sh --source sets both; a Forgejo or a Gitea
# is where EiN finds its modules too (CFG_MODULE_SOURCES below, which setup.sh keeps in step).
EIN_SOURCE=https://github.com/einhq
EIN_SOURCE_KEY=

# The database's folder: empty keeps it in the container engine's storage, as the volume ein_db.
# setup.sh --db-dir sets it, to put the database on a faster disk than the one the files are on.
EIN_DB_DIR=
EOF
  chmod 600 .env
  echo "Wrote .env: your files go under $data"
}

secret() { openssl rand -hex 24; }

# For .env's head under podman-compose: `up -d` leaves out the swap limit start gives each container.
swap_note() {
  [ "$compose_tool" = podman-compose ] || return 0
  printf '\n%s' \
    "# Under podman-compose, a container that \`podman compose up -d\` makes again has no swap limit," \
    "# which setup.sh gives it: the media service's idle models then go to swap, and a search waits" \
    "# for them. ./setup.sh makes the containers again with it."
}

set_env() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >>.env; fi
}
unset_env() { sed -i "/^$1=/d" .env; }

# .env as this script's variables.
load_env() {
  # shellcheck disable=SC1091
  set -a && . ./.env && set +a
}

# This folder, a clone of the source's deploy, moved to its newest commit before anything else, and
# this script run again with the same options when that changed it: an update takes the compose
# files and setup.sh as they are now, not as they were installed. The source is
# --source when given, else the one in .env; the token is EIN_SOURCE_KEY from the environment, else
# from .env. A folder that is not a git clone is left as it is.
update_self() {
  local source=$1 before after
  shift
  [ -e .git ] || return 0
  [ -n "$source" ] || [ ! -f .env ] || source=$(sed -n 's/^EIN_SOURCE=//p' .env)
  local EIN_SOURCE_KEY=${EIN_SOURCE_KEY:-}
  [ -n "$EIN_SOURCE_KEY" ] || [ ! -f .env ] || EIN_SOURCE_KEY=$(sed -n 's/^EIN_SOURCE_KEY=//p' .env)
  [ -z "$source" ] || git remote set-url origin "$source/deploy.git"
  before=$(git rev-parse HEAD)
  git_source pull --ff-only --quiet ||
    fail "$here could not be brought up to date from $(git remote get-url origin): git status there says why"
  after=$(git rev-parse HEAD)
  [ "$after" != "$before" ] || return 0
  echo "Updated $here to $(git log -1 --format='%h %cs'); running its setup.sh"
  exec "$here/setup.sh" "$@"
}

# An organisation's address, https://host/owner, as the source of the sources and the modules. Back
# on GitHub, the module settings a Forgejo or a Gitea source wrote go again, and EiN's default holds.
set_source() {
  local url=$1
  if is_github "$url" && ! is_github "$(sed -n 's/^EIN_SOURCE=//p' .env)"; then
    unset_env CFG_MODULE_SOURCES
    unset_env CFG_MODULE_SOURCES_KEY
  fi
  set_env EIN_SOURCE "$url"
}

host_of() {
  local host=${1#*://}
  host=${host%%/*}
  echo "${host,,}"
}
is_github() { [[ $(host_of "$1") =~ ^(www\.)?github\.com$ ]]; }

# EiN's image is pulled when the sources are GitHub's einhq, which publishes it, and built here from
# core's sources when they come from anywhere else, whose commits that image does not have.
ein_built() {
  local owner=${EIN_SOURCE##*/}
  ! is_github "$EIN_SOURCE" || [ "${owner,,}" != einhq ]
}

# A Forgejo or a Gitea source is where EiN installs its modules from too, with its token: core's
# CFG_MODULE_SOURCES and CFG_MODULE_SOURCES_KEY (host[:port]=token), kept in step with the source.
module_sources() {
  ! is_github "$EIN_SOURCE" || return 0
  set_env CFG_MODULE_SOURCES "$EIN_SOURCE"
  if [ -n "$EIN_SOURCE_KEY" ]; then
    set_env CFG_MODULE_SOURCES_KEY "$(host_of "$EIN_SOURCE")=$EIN_SOURCE_KEY"
  else
    unset_env CFG_MODULE_SOURCES_KEY
  fi
}

set_db_dir() {
  [[ $1 == /* ]] || fail "--db-dir takes an absolute path: $1"
  set_env EIN_DB_DIR "${1%/}"
}

# A command in the database's image as its root, with a folder or a volume mounted at /d with the
# mount's options: the folder's owner and contents as the database sees them, which under rootless
# podman this user cannot read itself.
db_sh() { "$engine" run --rm --user 0 --entrypoint sh -v "$1:/d:$2" localhost/ein-db -c "$3"; }

# The database's folder given to the image's postgres user, before the database starts. Mounting it
# with :z here labels it for the containers under SELinux once, so compose.yaml mounts it plainly
# and the same on every engine (ein/core#729).
prepare_db_dir() {
  [ -n "${EIN_DB_DIR:-}" ] || return 0
  mkdir -p "$EIN_DB_DIR"
  if db_sh "$EIN_DB_DIR" z '[ -z "$(ls -A /d)" ]'; then
    if "$engine" volume inspect ein_db >/dev/null 2>&1 && db_sh ein_db ro '[ -e /d/PG_VERSION ]'; then
      fail "the database is in the volume ein_db, and $EIN_DB_DIR is empty. Move it there first:
  $engine compose stop db
  $engine run --rm --user 0 --entrypoint sh -v ein_db:/from:ro -v $EIN_DB_DIR:/to:z localhost/ein-db -c 'cp -a /from/. /to/'
then run ./setup.sh again, and remove the volume once EiN shows your files: $engine volume rm ein_db"
    fi
  elif ! db_sh "$EIN_DB_DIR" z '[ -e /d/PG_VERSION ]'; then
    fail "$EIN_DB_DIR holds files but no database: --db-dir takes an empty folder, or one a database is in"
  fi
  db_sh "$EIN_DB_DIR" z '[ "$(stat -c %U /d)" = postgres ] || chown -R postgres:postgres /d; chmod 700 /d'
}

# The database runs on what was chosen for it: a database that starts on another folder, or on none,
# is a new empty one, and the old one would look lost (ein/db's run.sh once mounted a path the image
# does not use, and the data lived in the container until it was replaced).
check_db_mount() {
  local id source want=${EIN_DB_DIR:-}
  id=$("$engine" ps -q --filter label=com.docker.compose.project=ein --filter label=com.docker.compose.service=db | head -1)
  [ -n "$id" ] || fail "the database did not start: $engine compose logs db"
  source=$("$engine" inspect --format '{{range .Mounts}}{{if eq .Destination "/home/postgres/pgdata/data"}}{{.Source}}{{end}}{{end}}' "$id")
  [ -n "$source" ] || fail "the database's folder is not mounted into its container: $engine inspect $id"
  if [ -n "$want" ] && [ "$(realpath "$source")" != "$(realpath "$want")" ]; then
    fail "the database runs on $source, not on $want: $engine compose down, then ./setup.sh again"
  fi
}

# EiN's ports, each moved to the next free one when something else on this machine listens on it,
# such as another web server on 8080. Not while EiN runs: then it is EiN that holds them.
free_ports() {
  [ -z "$("$engine" ps -q --filter label=com.docker.compose.project=ein --filter label=com.docker.compose.service=ein)" ] || return 0
  local name port
  for name in EIN_HTTP_PORT EIN_SSH_PORT; do
    port=${!name}
    while port_taken "$port"; do port=$((port + 1)); done
    [ "$port" != "${!name}" ] || continue
    echo "Port ${!name} is taken on this machine: EiN uses $port instead ($name in .env)"
    set_env "$name" "$port"
    printf -v "$name" %s "$port"
  done
}

port_taken() {
  if command -v ss >/dev/null; then
    [ -n "$(ss -ltnH "sport = :$1")" ]
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

# What the options and the engine add to compose.yaml. Every compose reads compose.override.yaml
# beside it, so a plain `compose up -d` starts the same services as this script does.
#
# Under podman every service restarts always: at boot podman-restart.service starts only the
# containers with that policy, and leaves unless-stopped ones down. Docker's daemon starts those too.
write_override() {
  local service option lines written=0
  {
    echo "# Written by setup.sh from the options in .env and the container engine; edit those and run"
    echo "# setup.sh again."
    echo "services:"
    for service in db ein ems llm; do
      lines=()
      case $service in
        ems | llm)
          option=EIN_${service^^}
          [ "${!option}" = 1 ] || continue
          lines+=("extends: { file: compose.$service.yaml, service: $service }")
          [ "$EIN_GPU" != 1 ] || lines+=("devices: [nvidia.com/gpu=all]")
          ;;
        ein)
          ! ein_built || lines+=("image: localhost/ein-core" "build: { context: src/core, dockerfile: src/Containerfile }")
          [ "$EIN_LLM" != 1 ] || lines+=("environment:" "  CFG_LLM_CARD: $([ "$EIN_GPU" = 1 ] && echo card || echo cpu)")
          ;;
      esac
      [ "$engine" != podman ] || lines+=("restart: always")
      [ ${#lines[@]} != 0 ] || continue
      echo "  $service:"
      printf '    %s\n' "${lines[@]}"
      written=1
    done
    # Never an empty services: docker-compose 1.x takes such a file for its old version 1 format.
    [ "$written" = 1 ] || echo "  ein: {}"
  } >compose.override.yaml
}

# A repository cloned the first time and moved to its newest commit after, so a run is an update.
# Its origin follows the source, so a new --source takes effect at the next pull.
fetch() {
  if [ -d "$2/.git" ]; then
    git -C "$2" remote set-url origin "$EIN_SOURCE/$1.git"
    git_source -C "$2" pull --ff-only --quiet
  else
    git_source clone --quiet "$EIN_SOURCE/$1.git" "$2"
  fi
  echo "  $1 $(git -C "$2" log -1 --format='%h %cs')"
}

# git with the source's token as a header, given in the environment of this call alone: it is not
# written into .git/config, nor shown on a command line.
git_source() {
  if [ -n "${EIN_SOURCE_KEY:-}" ]; then
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: token $EIN_SOURCE_KEY" git "$@"
  else
    git "$@"
  fi
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

# Every image, or the one service's when one is named: EiN's pulled or built (ein_built), the
# database's and the media service's built. The model's is not built: compose up pulls it.
build() {
  local one=${1:-}
  # Under podman the build's scratch files go next to its storage: /tmp is often too small for the
  # media service's layers. Docker keeps them in its own storage already.
  if [ "$engine" = podman ]; then
    TMPDIR="$(podman info --format '{{.Store.GraphRoot}}')/tmp"
    mkdir -p "$TMPDIR"
    export TMPDIR
  fi
  if [ "$EIN_EMS" = 1 ] && { [ -z "$one" ] || [ "$one" = ems ]; }; then
    # What the media service's health reports as its build, as its own Makefile writes it.
    echo "$(git -C src/ems describe --always --dirty) $(git -C src/ems log -1 --format=%cI)" >src/ems/ems/BUILD
  fi
  if [ -z "$one" ] || [ "$one" = ein ]; then
    if ein_built; then
      # What core's system-info says it runs, as a tree without its .git says it: the commit and its date.
      git -C src/core log -1 --format='{"commit":"%h","date":"%cI"}' >src/core/src/build.json
    else
      "$engine" pull "$ein_image"
    fi
  fi
  # compose builds the services that have a build, and EiN only when the override gives it one.
  case $one in
    '') compose build ;;
    llm) ;;
    ein) ! ein_built || compose build ein ;;
    *) compose build "$one" ;;
  esac
}

# The ids of the images build tags or pull.
built_images() {
  local name
  for name in localhost/ein-core "$ein_image" localhost/ein-ems localhost/ein-db; do
    "$engine" image inspect --format '{{.Id}}' "$name" 2>/dev/null || true
  done
}

# The images named that lost their name to a new build, removed, and the space that freed said: each
# update would otherwise leave its old images behind, the media service's about 30 GB. One still
# named, or that a container uses, is kept.
remove_replaced() {
  local id store before after removed=0
  store=$(if [ "$engine" = podman ]; then podman info --format '{{.Store.GraphRoot}}'; else docker info --format '{{.DockerRootDir}}'; fi) || true
  before=$(free_bytes "$store")
  for id in "$@"; do
    [ "$("$engine" image inspect --format '{{len .RepoTags}}' "$id" 2>/dev/null)" = 0 ] || continue
    if "$engine" rmi "$id" >/dev/null 2>&1; then removed=$((removed + 1)); fi
  done
  [ "$removed" -gt 0 ] || return 0
  after=$(free_bytes "$store")
  if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
    echo "Removed the images this update replaced, which freed $(numfmt --to=iec --suffix=B $((after - before)))"
  else
    echo "Removed the images this update replaced"
  fi
}

# The bytes free on the file system of a folder, or nothing where df cannot see it (Docker Desktop's
# storage is inside its virtual machine).
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 || true; }

# EiN answers once its database is up and its boot is through.
wait_for_ein() {
  local url="http://127.0.0.1:$EIN_HTTP_PORT/" id line last= down=0
  echo "Waiting for EiN to answer at $url; its first start takes a minute or more"
  for i in $(seq 300); do
    if curl -fs -o /dev/null --max-time 5 "$url"; then
      echo
      echo "EiN is up at http://$(hostname):$EIN_HTTP_PORT/"
      [ -z "${INITIAL_ADMIN_PASSWORD:-}" ] ||
        echo "Sign in as admin with the password $INITIAL_ADMIN_PASSWORD and change it, then delete the line INITIAL_ADMIN_PASSWORD from $here/.env."
      return
    fi
    # A container that stopped, or that its engine restarts again and again, does not come up by
    # waiting longer.
    id=$("$engine" ps -aq --filter label=com.docker.compose.project=ein --filter label=com.docker.compose.service=ein | head -1)
    if [ -z "$id" ] || [ "$("$engine" inspect --format '{{.State.Running}}' "$id")" != true ]; then
      down=$((down + 1))
    else
      down=0
    fi
    if [ "$down" -ge 3 ] || { [ -n "$id" ] && [ "$("$engine" inspect --format '{{.RestartCount}}' "$id")" -ge 3 ]; }; then
      [ -z "$id" ] || "$engine" logs --tail 30 "$id" >&2 || true
      fail "EiN stopped before it answered; its log is above: $engine compose logs ein"
    fi
    # Every 10 seconds, what EiN last logged, when it is new.
    if [ -n "$id" ] && [ $((i % 5)) = 0 ]; then
      line=$("$engine" logs --tail 1 "$id" 2>&1 | tail -1 | cut -c1-150)
      [ -z "$line" ] || [ "$line" = "$last" ] || echo "  $line"
      last=$line
    fi
    sleep 2
  done
  fail "EiN did not answer at $url in 10 minutes: $engine compose logs ein"
}

# Whether EiN starts again when the machine does, made so where this user may, and what it takes
# where not. Docker's daemon starts EiN when it starts itself. Under podman, podman-restart.service
# does; rootless, it is a user unit, which runs at boot only for a user who lingers.
after_reboot() {
  local todo=() scope=(--user) user
  user=$(id -un)
  if [ "$engine" = docker ]; then
    systemctl is-enabled --quiet docker.service 2>/dev/null || systemctl --user is-enabled --quiet docker.service 2>/dev/null ||
      todo+=("sudo systemctl enable docker")
  else
    [ "$(id -u)" != 0 ] || scope=()
    if ! systemctl "${scope[@]}" is-enabled --quiet podman-restart.service 2>/dev/null; then
      if systemctl "${scope[@]}" enable podman-restart.service >/dev/null 2>&1; then
        echo "Enabled podman-restart.service, which starts EiN's containers at boot"
      else
        todo+=("systemctl ${scope[*]} enable podman-restart.service")
      fi
    fi
    if [ "$(id -u)" != 0 ] && [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" != yes ]; then
      if loginctl --no-ask-password enable-linger 2>/dev/null; then
        echo "Enabled lingering for $user, so podman-restart.service runs at boot without a login"
      else
        todo+=("sudo loginctl enable-linger $user")
      fi
    fi
  fi
  if [ ${#todo[@]} = 0 ]; then
    echo "EiN starts again when the machine does."
  else
    echo "EiN does not start again when the machine does until this has run:"
    printf '  %s\n' "${todo[@]}"
    echo "Until then, start it after a reboot with: cd $here && $engine compose up -d"
  fi
}

step() { printf '\n== %s\n' "$1"; }
fail() {
  echo "setup.sh: $1" >&2
  exit 1
}

main "$@"
