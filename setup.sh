#!/usr/bin/env bash
# Installs EiN on this machine, and updates it when run again: fetches the sources under src/,
# writes .env the first time, builds the images and starts them with compose.
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
# or `docker compose`, which work from this folder afterwards as usual (ps, logs, down, up -d).
#
# --source names an organisation on GitHub, Forgejo or Gitea that has EiN's repositories under their
# own names (default: https://github.com/einhq), such as http://forge.example:3000/ein. When it is a
# Forgejo or a Gitea, EiN installs its modules from there too. EIN_SOURCE_KEY in the environment is
# the token that reads it, when its repositories are private; it is kept in .env with the source.
#
# Read the first time only, when .env is written:
#   EIN_DATA       the folder for your originals, the renditions, scratch space and the model (default: ./data)
#   EIN_HTTP_PORT  the web interface's port (default: 8080)
#   EIN_SSH_PORT   SSH and SFTP's port (default: 2222)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here"

main() {
  local want_ems= want_llm= modules=() source= db_dir= only= key=${EIN_SOURCE_KEY:-} options=0
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
        source=$2
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

  pick_engine
  if [ -n "$only" ]; then
    [ "$options" = 0 ] || fail "--only updates what is installed: give the other options without it"
    [ -f .env ] || fail "--only updates an installation: run ./setup.sh first"
    load_env
    update_one "$only"
    return
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
  fetch core src/core
  fetch db src/db
  [ "$EIN_EMS" != 1 ] || fetch ems src/ems
  [ "$EIN_LLM" != 1 ] || fetch llm src/llm

  step "Building the images$([ "$EIN_EMS" != 1 ] || echo ' (the media service the first time: about 30 GB)')"
  build

  step "Starting EiN"
  mkdir -p "$EIN_DATA"/{files,old,files-volatile,files-tmp,llm,modules}
  prepare_db_dir
  # On an update, --force-recreate: older podman-compose starts the new images only when the config
  # changed. --remove-orphans: an option left out stops its service.
  local recreate=()
  [ -z "$("$engine" ps -aq --filter label=com.docker.compose.project=ein)" ] || recreate=(--force-recreate)
  compose up -d "${recreate[@]}" --remove-orphans
  check_db_mount
  wait_for_ein
}

# One service fetched, built and restarted, the others left running: an update of EiN alone does not
# restart the media service, the model or the database.
update_one() {
  case $1 in
    ein) fetch core src/core ;;
    db) fetch db src/db ;;
    ems | llm)
      local option=EIN_${1^^}
      [ "${!option}" = 1 ] || fail "$1 is not installed here: ./setup.sh --$1 adds it"
      fetch "$1" "src/$1"
      ;;
    *) fail "--only takes ein, ems, db or llm, not $1" ;;
  esac
  step "Building $1"
  build "$1"
  [ "$1" != db ] || prepare_db_dir
  # EiN goes and comes back with the database: podman keeps a container that another requires.
  if [ "$1" = db ]; then recreate ein db; else recreate "$1"; fi
  case $1 in
    db) check_db_mount && wait_for_ein ;;
    ein) wait_for_ein ;;
  esac
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
  compose up -d --no-deps "$@"
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

set_env() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >>.env; fi
}
unset_env() { sed -i "/^$1=/d" .env; }

# .env as this script's variables.
load_env() {
  # shellcheck disable=SC1091
  set -a && . ./.env && set +a
}

# An organisation's address, https://host/owner, as the source of the sources and the modules. Back
# on GitHub, the module settings a Forgejo or a Gitea source wrote go again, and EiN's default holds.
set_source() {
  local url=${1%/}
  [[ $url =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._-]+$ ]] ||
    fail "--source takes an organisation's address, such as https://github.com/einhq or http://forge.example:3000/ein: $1"
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

# Every image, or the one service's when one is named. The model's is not built: compose up pulls it.
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
    # What core's system-info says it runs, as a tree without its .git says it: the commit and its date.
    git -C src/core log -1 --format='{"commit":"%h","date":"%cI"}' >src/core/src/build.json
    "$engine" build -t localhost/ein-core -f src/core/src/Containerfile src/core
  fi
  case $one in
    '') compose build ;;
    llm) ;;
    *) compose build "$one" ;;
  esac
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
