#!/usr/bin/env bash
# Installs EiN on this machine, and updates it when run again: brings this folder up to date from
# the source's deploy, writes .env the first time, fetches the sources it needs under src/, pulls
# the images or builds them from those sources, and starts them with compose.
#
#   ./setup.sh                    EiN and its database; run again, the newest sources of what is here
#   ./setup.sh --ems              also the media service: every media tool and model, about 30 GB
#   ./setup.sh --llm              also the assistant's language model
#   ./setup.sh --devices          also the Devices module's sidecar: an MQTT broker for its devices,
#                                 a listener for devices on the network, a restreamer for cameras
#   ./setup.sh --module archive   also a module, which EiN installs at its start with the modules it needs
#   ./setup.sh --no-ems --no-llm  leave an option out again (--no-devices too); its data stays
#   ./setup.sh --only core        update one service, core, ems, db, llm, devices or supervisor, and
#                                 restart only it; --only core,db several, one after another
#   ./setup.sh --no-supervisor    leave the supervisor out, which installs and updates the services
#                                 when EiN asks; --supervisor adds it again
#   ./setup.sh --source URL       fetch the sources and the modules from this organisation instead
#   ./setup.sh --db-dir DIR       keep the database in this folder instead of db under the data folder
#   ./setup.sh --http-port N      the web interface's port (default: 8080, or the next free one)
#   ./setup.sh --ssh-port N       SSH and SFTP's port (default: 2222, or the next free one)
#   ./setup.sh --bind ADDRESS     the address they listen on: 0.0.0.0, every one (default), or
#                                 127.0.0.1, this machine alone, behind an HTTPS proxy of your own
#
# The first run only, when it writes .env:
#   --data DIR                    the folder for your originals, the renditions, scratch space, the
#                                 model, the modules and the database (default: ./data)
#   --engine podman|docker        the container engine (default: podman when it is installed)
#   INITIAL_ADMIN_PASSWORD        in the environment, never on a command line: the admin account's
#                                 first password, 8 characters or more, without ' or \; without it
#                                 one is made, and shown at the end
#
# An option once chosen is kept in .env, so a later run without it keeps it. With podman or Docker,
# whichever is here (podman first), and its compose: `podman compose` or `docker compose`, which
# work from this folder afterwards as usual (ps, logs, down, up -d). The engine is kept in .env too:
# a later run uses it, whichever else is installed. Under podman-compose,
# a container that `podman compose up -d` makes again, after a change to .env, has no swap limit:
# this script gives each one (see start), and a run of it gives it back. An update that came up
# removes the images it replaced, and says how much that freed.
#
# --source names an organisation on GitHub, Forgejo or Gitea that has EiN's repositories under their
# own names (default: https://github.com/einhq), such as http://forge.example:3000/ein. When it is a
# Forgejo or a Gitea, EiN installs its modules from there too. The images of EiN, its database and
# the media service are pulled from GitHub's registry only from https://github.com/einhq, which
# publishes them, and built here from any other source's core, db and ems. EIN_SOURCE_KEY in the
# environment is the token that reads the source, when its repositories are private; it is kept in
# .env with the source, and a --source on another host without a token of its own drops it.
#
# The media service and the sidecar are pulled at the version line the installed modules ask for in
# their mod.json (`"services": { "ems": "^0.4.4" }`: the line 0.4, the image ghcr.io/einhq/ems:0.4),
# kept in .env as EIN_EMS_TAG and EIN_DEVICES_TAG, and :main before any module asks. A run after
# a module's update in EiN pulls the line it asks for then.
#
# --only puts a service whose new image does not come up back on the image it ran, and fails, saying
# so. Run by the supervisor (EIN_KEEP_CURRENT=1), it leaves a service that runs its newest image as
# it is; run here, it starts it again, so a setting changed in .env takes effect.
#
# An installation from GitHub's einhq has the supervisor (compose.supervisor.yaml), unless
# --no-supervisor leaves it out: a container holding the engine's socket, which installs the media
# service, the language model and the sidecar when EiN asks, and updates the services with their
# modules and each night at EIN_UPDATE_AT in .env (04:00; off for never). There every run, its own
# and this one alike, runs in the supervisor's image, with the compose that comes with it, so this
# machine needs the engine alone.
#
# The secrets come in the environment, every other setting as an option. setup.sh asks nothing:
# the installer asks, and passes the answers on.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here"

main() {
  local args=("$@") want_ems= want_llm= want_devices= modules=() source= db_dir= only= key=${EIN_SOURCE_KEY:-} options=0 unknown=
  local http_port= ssh_port= bind= want_supervisor=
  data_dir= want_engine=
  while [ $# -gt 0 ]; do
    case $1 in
      --supervisor) want_supervisor=1 ;;
      --no-supervisor) want_supervisor=0 ;;
      --ems) want_ems=1 ;;
      --no-ems) want_ems=0 ;;
      --llm) want_llm=1 ;;
      --no-llm) want_llm=0 ;;
      --devices) want_devices=1 ;;
      --no-devices) want_devices=0 ;;
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
      --data)
        [ $# -ge 2 ] || fail "--data needs a folder"
        data_dir=$2
        shift
        ;;
      --http-port | --ssh-port)
        [ $# -ge 2 ] && is_port "$2" || fail "$1 takes a port, 1 to 65535"
        if [ "$1" = --http-port ]; then http_port=$2; else ssh_port=$2; fi
        shift
        ;;
      --bind)
        [ $# -ge 2 ] && [[ $2 =~ ^[0-9a-fA-F.:]+$ ]] ||
          fail "--bind takes an address of this machine: 0.0.0.0, every one, or 127.0.0.1, this machine alone"
        bind=$2
        shift
        ;;
      --engine)
        [ $# -ge 2 ] || fail "--engine needs podman or docker"
        want_engine=$2
        shift
        ;;
      --only)
        [ $# -ge 2 ] || fail "--only needs a service: core, ems, db, llm, devices or supervisor"
        only=$2
        shift 2
        continue
        ;;
      -h | --help)
        sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
        return
        ;;
      # Refused once this folder is up to date: the newer setup.sh may know it.
      *) unknown=${unknown:-$1} ;;
    esac
    options=$((options + 1))
    shift
  done

  one_at_a_time "${args[@]}"
  update_self "$source" "${args[@]}"
  [ -z "$unknown" ] || fail "unknown option $unknown (--help lists them)"
  pick_engine
  supervise "$want_supervisor" "$source" "$only" "${args[@]}"
  pick_compose
  if [ -n "$only" ]; then
    [ "$options" = 0 ] || fail "--only updates what is installed: give the other options without it"
    [ -f .env ] || fail "--only updates an installation: run ./setup.sh first"
    load_env
    # podman-compose 1.0 hashes the whole project's config: after a change to any compose file,
    # starting one service makes every container again, with that one's swap limit, which the
    # database's start refuses. Then every service starts again, each on its own (start).
    write_override
    if [ "$compose_tool" != podman-compose ] || [ "$(config_hash)" = "$(running_hash)" ]; then
      local service
      for service in ${only//,/ }; do update_one "$service"; done
      return
    fi
    echo "The compose files changed, so every service is updated and started again, not ${only//,/ and } alone"
  fi

  if [ -f .env ]; then
    # The data folder holds the database and everything else: it is chosen once.
    local kept_data
    kept_data=$(sed -n 's/^EIN_DATA=//p' .env)
    [ -z "$data_dir" ] || [ "$(cd "$data_dir" 2>/dev/null && pwd)" = "$kept_data" ] ||
      fail "--data is chosen at the install, and the data folder here is $kept_data"
  else
    write_env
  fi
  [ -z "$http_port" ] || set_env EIN_HTTP_PORT "$http_port"
  [ -z "$ssh_port" ] || set_env EIN_SSH_PORT "$ssh_port"
  [ -z "$bind" ] || set_env EIN_BIND "$bind"
  [ -z "$want_ems" ] || set_env EIN_EMS "$want_ems"
  [ -z "$want_llm" ] || set_env EIN_LLM "$want_llm"
  [ -z "$want_devices" ] || set_env EIN_DEVICES "$want_devices"
  [ ${#modules[@]} = 0 ] || add_modules "${modules[@]}"
  [ -z "$source" ] || set_source "$source"
  [ -z "$key" ] || set_env EIN_SOURCE_KEY "$key"
  [ -z "$db_dir" ] || set_db_dir "$db_dir"
  load_env
  module_sources
  [ "$EIN_DEVICES" != 1 ] || devices_secrets
  check_devices_bind
  write_override

  # The media service's source comes with its image too: its deploy/ has the fix for the card's CDI
  # spec under podman before 5.
  local repo repos=()
  ! built || repos+=(core db)
  ! built || [ "$EIN_DEVICES" != 1 ] || repos+=(module-devices)
  [ "$EIN_EMS" != 1 ] || repos+=(ems)
  [ ${#repos[@]} = 0 ] || step "Fetching the sources"
  for repo in "${repos[@]}"; do fetch "$repo" "src/$repo"; done

  step "Getting the images$([ "$EIN_EMS" != 1 ] || echo ' (the media service the first time: about 30 GB)')"
  local old
  old=$(built_images)
  build

  step "Starting EiN"
  mkdir -p "$EIN_DATA"/{files,old,files-volatile,llm,modules}
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
    start db devices core ems llm supervisor
  else
    local recreate=()
    [ -z "$("$engine" ps -aq --filter label=com.docker.compose.project=ein)" ] || recreate=(--force-recreate)
    compose up -d "${recreate[@]}" --remove-orphans
  fi
  check_db_mount
  wait_for_ein || exit 1
  follow_lines
  drop_main_tags
  remove_replaced $old
  [ -n "${EIN_SUPERVISOR_JOB:-}" ] || after_reboot
  modules_report
  modules_need
}

# One service fetched, built and restarted, the others left running: an update of EiN alone does not
# restart the media service, the model or the database. One whose new image does not come up goes
# back to the image it ran, and one that runs its newest image already is left as it is when
# EIN_KEEP_CURRENT is set, as the supervisor's runs set it.
update_one() {
  case $1 in
    core) ! built || fetch core src/core ;;
    db) ! built || fetch db src/db ;;
    ems | llm)
      local option=EIN_${1^^}
      [ "${!option}" = 1 ] || fail "$1 is not installed here: ./setup.sh --$1 adds it"
      [ "$1" = llm ] || fetch ems src/ems
      ;;
    devices)
      [ "$EIN_DEVICES" = 1 ] || fail "the devices sidecar is not installed here: ./setup.sh --devices adds it"
      devices_secrets
      ! built || fetch module-devices src/module-devices
      ;;
    supervisor) [ "${EIN_SUPERVISOR:-0}" = 1 ] || fail "the supervisor is not installed here: ./setup.sh --supervisor adds it" ;;
    *) fail "--only takes core, ems, db, llm, devices or supervisor, not $1" ;;
  esac
  step "Getting $1's image"
  local old ran tag
  old=$(built_images)
  ran=$(running_image "$1")
  tag=$(tag_of "$1")
  build "$1"
  [ "$1" != db ] || prepare_db_dir
  # The model's image is pinned in its compose file, and its update is that file and its template.
  if [ -n "${EIN_KEEP_CURRENT:-}" ] && [ "$1" != llm ] && [ -n "$ran" ] && [ "$ran" = "$(image_id "$1")" ]; then
    echo "$1 runs its newest image already"
    # Compose makes it again only when its definition changed; podman-compose 1.0 would make it
    # again whatever, and its changed definition takes the whole project again (main).
    [ "$compose_tool" = podman-compose ] || compose up -d --no-deps "$1"
  else
    restart_service "$1"
    came_up "$1" || roll_back "$1" "$ran" "$tag"
    echo "$1 is up on its new image"
  fi
  [ "$1" != core ] || modules_report
  drop_main_tags
  remove_replaced $old
}

# EiN goes and comes back with the database: podman keeps a container that another requires, so
# the one that requires it goes first.
restart_service() { if [ "$1" = db ]; then recreate core db; else recreate "$1"; fi; }

# Whether a service came up on the image it was made again from: EiN answers, the database and the
# media service report healthy, and the others run without restarting.
came_up() {
  case $1 in
    core) wait_for_ein ;;
    db) container_up db 300 && check_db_mount && wait_for_ein ;;
    ems) container_up ems 900 ;;
    *) container_up "$1" 60 ;;
  esac
}

# A service's container healthy within so many seconds, or, where it has no health check, still
# running 20 seconds after it started and never restarted. podman reports a container without a
# check as starting, so its verdict counts only where the container has a check.
container_up() {
  local id status health restarts waited=0
  echo "Waiting for $1 to come up"
  while [ "$waited" -lt "$2" ]; do
    id=$(service_container "$1")
    status= health= restarts=0
    [ -z "$id" ] || IFS=/ read -r status health restarts \
      <<<"$("$engine" inspect --format '{{.State.Status}}/{{if .Config.Healthcheck}}{{if .Config.Healthcheck.Test}}{{.State.Health.Status}}{{end}}{{end}}/{{.RestartCount}}' "$id" 2>/dev/null)"
    case $status/$health in
      */healthy) return 0 ;;
      */unhealthy | exited/* | dead/*) break ;;
    esac
    [ "${restarts:-0}" -lt 3 ] || break
    [ -n "$health" ] || [ "$status" != running ] || [ "${restarts:-0}" != 0 ] || [ "$waited" -lt 20 ] || return 0
    sleep 5
    waited=$((waited + 5))
  done
  echo "$1 did not come up: ${status:-no container}${health:+, $health}$([ "${restarts:-0}" = 0 ] || echo ", restarted $restarts times")" >&2
  return 1
}

# A service whose new image did not come up, put back on the image it ran (ran), at the line it was
# at (tag). The update fails, saying so; the new image goes.
roll_back() {
  local service=$1 ran=$2 tag=$3 new id
  [ -n "$ran" ] && [ "$service" != llm ] || fail "$service did not come up: $engine compose logs $service"
  id=$(service_container "$service")
  [ -z "$id" ] || { echo "Its log:"; "$engine" logs --tail 30 "$id" 2>&1 | sed 's/^/  /'; } >&2
  step "Putting $service back on the image it ran"
  new=$(image_id "$service")
  if [ "$tag" != "$(tag_of "$service")" ]; then
    set_env "EIN_${service^^}_TAG" "$tag"
    printf -v "EIN_${service^^}_TAG" %s "$tag"
    write_override
  fi
  "$engine" tag "$ran" "$(image_of "$service")"
  restart_service "$service"
  came_up "$service" || fail "$service does not come up on the image it ran before either: $engine compose logs $service"
  [ -z "$new" ] || [ "$new" = "$ran" ] || "$engine" rmi "$new" >/dev/null 2>&1 || true
  fail "$service did not come up on its new image, and runs on the one it ran before; its log above says why"
}

# The container of a service, its image, and the image it would run now.
service_container() { "$engine" ps -aq --filter label=com.docker.compose.project=ein --filter "label=com.docker.compose.service=$1" | head -1; }
running_image() {
  local id
  id=$(service_container "$1")
  [ -z "$id" ] || "$engine" inspect --format '{{.Image}}' "$id"
}
image_id() { "$engine" image inspect --format '{{.Id}}' "$(image_of "$1")" 2>/dev/null || true; }

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
  for service in db devices core ems llm supervisor; do
    [[ " $* " == *" $service "* ]] || continue
    case $service in ems | llm | devices | supervisor) local option=EIN_${service^^}; [ "${!option:-0}" = 1 ] || continue ;; esac
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

# The modules EiN runs from its modules folder, each at the release it was installed at, and what
# its start said of those it could not install or run. EiN installs a module's newest release that
# its core runs, which is older than the newest published when the image is older than the module.
modules_report() {
  local dir version ref id lines=()
  for dir in "$EIN_DATA"/modules/*/; do
    [ -f "$dir/mod.json" ] || continue
    version=$(json_field version "$dir/mod.json")
    ref=$(json_field ref "$dir/.install.json")
    lines+=("$(basename "$dir") ${version:-?}${ref:+ ($ref)}")
  done
  [ ${#lines[@]} != 0 ] || return 0
  echo "The modules installed:"
  printf '  %s\n' "${lines[@]}"
  id=$("$engine" ps -q --filter label=com.docker.compose.project=ein --filter label=com.docker.compose.service=core | head -1)
  [ -n "$id" ] || return 0
  # Its log lines are "[time] [level] [component] text", the level coloured.
  "$engine" logs "$id" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g; s/^\[[^]]*\] \[[^]]*\] \[[^]]*\] //' |
    grep -E 'needs core API|^mod (install|setup): ' | sed 's/^/  /' || true
}

# A string field of a JSON file as JSON.stringify writes it, a field to a line; nothing when the
# file or the field is not there.
json_field() { [ ! -f "$2" ] || sed -n "s/^ *\"$1\": *\"\([^\"]*\)\".*/\1/p" "$2" | head -1; }

# A module that talks to a service which is not installed here, said last, where it is read: the
# services its mod.json names. The Archive's photos, videos and documents are analysed by the media
# service, which the ems module, which it needs, talks to.
modules_need() {
  local service option module
  local -A what=([ems]="the media service" [devices]="the devices sidecar" [llm]="the language model")
  for service in ems devices llm; do
    option=EIN_${service^^}
    [ "${!option:-0}" != 1 ] || continue
    for module in $(modules_asking "$service"); do
      echo "The $module module talks to ${what[$service]}, which is not installed here: $([ "${EIN_SUPERVISOR:-0}" != 1 ] || echo "Settings → Modules in EiN installs it, or ")./setup.sh --$service adds it."
    done
  done
}

# The installed modules whose mod.json names a service, and the version of it each asks for, as
# "<module> <major.minor[.patch]>" lines: a caret range's version, which modules are held to.
modules_services() {
  local file
  for file in "$EIN_DATA"/modules/*/mod.json; do
    [ -f "$file" ] || continue
    sed -n '/^  "services": {/,/^  }/s/^ *"\([a-z][a-z0-9-]*\)": *"^\([0-9][0-9.]*\)".*/\1 \2/p' "$file" |
      sed "s|^|$(basename "$(dirname "$file")") |"
  done
}
modules_asking() { modules_services | awk -v s="$1" '$2 == s { print $1 }'; }

# A version's line, the part a caret range holds: 0.4 for 0.4.x, 1 for 1.x.
line_of() {
  local major=${1%%.*} rest=${1#*.}
  if [ "$major" = 0 ]; then echo "0.${rest%%.*}"; else echo "$major"; fi
}

# The line of a service the installed modules ask for, nothing when none names it. Modules that ask
# for different lines are said, and the newest is taken: the older module's checks then say it is
# out of date.
wanted_line() {
  local module service version lines=() asked=()
  while read -r module service version; do
    [ "$service" = "$1" ] || continue
    asked+=("$module ^$version")
    lines+=("$(line_of "$version")")
  done < <(modules_services)
  [ ${#lines[@]} != 0 ] || return 0
  if [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -gt 1 ]; then
    echo "The modules ask for different versions of $1 ($(IFS=,; echo "${asked[*]}" | sed 's/,/, /g')); the newest is taken" >&2
  fi
  printf '%s\n' "${lines[@]}" | sort -V | tail -1
}

# The version of a service's source under src/, which a built image has: the media service's
# API_VERSION, the sidecar's VERSION.
source_version() {
  case $1 in
    ems) [ ! -f src/ems/ems/__init__.py ] || sed -n 's/^API_VERSION = "\([0-9.]*\)"$/\1/p' src/ems/ems/__init__.py ;;
    devices) [ ! -f src/module-devices/sidecar/discovery.ts ] || sed -n "s/^export const VERSION = '\([0-9.]*\)';$/\1/p" src/module-devices/sidecar/discovery.ts ;;
  esac
}

# Each service installed here at the line its modules ask for, pulled and started again when it is
# at another; a line not published yet leaves it as it is. Built, the source is main's: what it is
# and what the modules ask for are only compared.
follow_lines() {
  local service option line version
  for service in ems devices; do
    option=EIN_${service^^}
    [ "${!option:-0}" = 1 ] || continue
    line=$(wanted_line "$service")
    [ -n "$line" ] || continue
    if built; then
      version=$(source_version "$service")
      [ -z "$version" ] || [ "$(line_of "$version")" = "$line" ] ||
        echo "The modules here ask for $service $line, and its source is $version: their checks in EiN say which is behind"
      continue
    fi
    option=EIN_${service^^}_TAG
    [ "$line" != "${!option:-main}" ] || continue
    step "Getting $service $line, which the modules ask for"
    pull_service "$service" && recreate "$service"
  done
}

# A service's image pulled at the line its modules ask for, or at the one it has when that line is
# not published (yet: a module's release can come before its service's image), or :main when it has
# none. False when its tag stayed.
pull_service() {
  local option=EIN_${1^^}_TAG line
  line=$(wanted_line "$1")
  if [ -n "$line" ] && [ "$line" != "${!option:-main}" ]; then
    if "$engine" pull "ghcr.io/einhq/$1:$line"; then
      set_env "$option" "$line"
      printf -v "$option" %s "$line"
      write_override
      return 0
    fi
    echo "The modules here ask for $1 $line, which is not published yet: it stays at ${!option:-main}"
  fi
  # Called where a failure does not stop the script, so it stops it itself.
  "$engine" pull "$(image_of "$1")" || fail "$(image_of "$1") could not be pulled"
  return 1
}

# The name :main taken off the images of the services that run at a line now, so the image it named
# goes with the others replaced.
drop_main_tags() {
  local service option
  built && return 0
  for service in ems devices; do
    option=EIN_${service^^}_TAG
    [ -n "${!option:-}" ] && [ "${!option}" != main ] || continue
    "$engine" image inspect "ghcr.io/einhq/$service:main" >/dev/null 2>&1 || continue
    "$engine" rmi "ghcr.io/einhq/$service:main" >/dev/null 2>&1 || true
  done
}

# The engine kept in .env, or on the first run --engine, else podman, else Docker. Under the other
# engine EiN would be a second one beside the first, without its database.
pick_engine() {
  local kept=
  [ ! -f .env ] || kept=$(sed -n 's/^EIN_ENGINE=//p' .env)
  if [ -n "$kept" ] && [ -n "$want_engine" ] && [ "$want_engine" != "$kept" ]; then
    fail "EiN here runs under $kept (EIN_ENGINE in .env); under $want_engine it would be a second, empty EiN beside it. Run ./setup.sh without --engine $want_engine"
  fi
  engine=${kept:-$want_engine}
  if [ -z "$engine" ]; then
    if command -v podman >/dev/null; then engine=podman; elif command -v docker >/dev/null; then engine=docker; else
      fail "neither podman nor Docker is installed"
    fi
  fi
  case $engine in podman | docker) ;; *) fail "--engine takes podman or docker, not $engine" ;; esac
  command -v "$engine" >/dev/null || fail "EiN here runs under $engine, which is not installed"
  compose_tool=
  # Under podman's older network backend, CNI, containers find each other by name only with its
  # dnsname plugin, and EiN finds its database by the name db. A run in the supervisor's image
  # has none of this machine's plugin folders to look in: the run that started it looked.
  if [ "$engine" = podman ] && [ -z "${EIN_SUPERVISOR_JOB:-}" ] && [ "$(podman info --format '{{.Host.NetworkBackend}}')" = cni ] && ! has_dnsname; then
    fail "podman's networks here give no names, which EiN needs to find its database: install podman's CNI plugin dnsname (Debian and Ubuntu: golang-github-containernetworking-plugin-dnsname; Fedora: podman-plugins), then ./setup.sh again"
  fi
  [ ! -f .env ] || [ -n "$kept" ] || set_env EIN_ENGINE "$engine"
}

# An installation with the supervisor runs every setup.sh in the supervisor's image, with the
# compose that comes with it: this machine needs the engine alone, and the services are made by the
# same compose whoever starts the run, this machine or the supervisor. This run goes on there, and
# this returns only when it goes on here: in that image already, or without the supervisor.
#
# A new installation has the supervisor when its sources are GitHub's einhq, whose images it pulls,
# and an installation from before it gets it with --supervisor. One whose image cannot be had, or
# whose engine has no socket to give it, goes on without it, and says so.
supervise() {
  local want=$1 source=$2 only=$3 kept= from status=0 data db mounts=()
  shift 3
  [ -z "${EIN_SUPERVISOR_JOB:-}" ] || return 0
  [ -f .env ] || [ -z "$only" ] || return 0
  if [ -f .env ]; then
    kept=$(sed -n 's/^EIN_SUPERVISOR=//p' .env)
    from=$(sed -n 's/^EIN_SOURCE=//p' .env)
  fi
  from=${source:-${from:-https://github.com/einhq}}
  if [ -z "$want" ]; then
    want=$kept
    [ -n "$want" ] || [ -f .env ] || ! published "$from" || want=1
  fi
  if [ "$want" != 1 ]; then
    [ ! -f .env ] || [ "${kept:-0}" = 0 ] || set_env EIN_SUPERVISOR 0
    return 0
  fi
  published "$from" ||
    fail "the supervisor runs the images GitHub's einhq publishes, and the sources here are $from, whose images are built here: run ./setup.sh --no-supervisor"
  [ -f .env ] || write_env
  if ! supervisor_settings; then
    set_env EIN_SUPERVISOR 0
    echo "This run goes on without the supervisor; ./setup.sh --supervisor tries again"
    return 0
  fi
  set_env EIN_SUPERVISOR 1
  data=$(sed -n 's/^EIN_DATA=//p' .env)
  db=$(sed -n 's/^EIN_DB_DIR=//p' .env)
  mounts=(-v "$(sed -n 's/^EIN_SOCKET=//p' .env):/run/engine.sock" -v "$here:$here" -v "$data:$data")
  [ -z "$db" ] || mounts+=(-v "$db:$db")
  local user gid
  user=$(sed -n 's/^EIN_SUPERVISOR_USER=//p' .env)
  gid=$(sed -n 's/^EIN_SOCKET_GID=//p' .env)
  mkdir -p "$data"
  [ -z "$db" ] || mkdir -p "$db"
  # Its network and name are this machine's, so it sees the ports taken here and EiN's own.
  "$engine" run --rm --name ein-setup --network host --uts host --security-opt label=disable \
    --user "$user" ${gid:+--group-add "$gid"} "${mounts[@]}" \
    -e EIN_SETUP_LOCKED=1 -e EIN_SUPERVISOR_JOB=1 -e EIN_DEPLOY="$here" ${EIN_SOURCE_KEY:+-e EIN_SOURCE_KEY} \
    -w "$here" --entrypoint "$here/setup.sh" "$SUPERVISOR_IMAGE" "$@" || status=$?
  [ "$status" != 0 ] || after_reboot
  exit "$status"
}
SUPERVISOR_IMAGE=ghcr.io/einhq/supervisor:main

# Whether the container engine answers on the socket at this path.
answers() { [ -S "$1" ] && curl -sf -o /dev/null --max-time 10 --unix-socket "$1" http://d/_ping; }

# Whether an organisation's address is GitHub's einhq, which publishes the images.
published() {
  local owner=${1##*/}
  is_github "$1" && [ "${owner,,}" = einhq ]
}

# What the supervisor's containers are given, kept in .env for compose.supervisor.yaml and for the
# runs it starts: the engine's socket, which podman is made to listen on; the user they run as, who
# owns this folder: root in the container where the engine is this user's (rootless podman, whose
# root in a container is this user), else this user with the socket's group (Docker's); this
# folder's path; the key EiN asks with; and the image, pulled. False, saying why, without them.
# podman's socket is started when it does not answer, which a file left by a stopped service does not.
supervisor_settings() {
  local socket user=0:0 gid=
  if [ "$engine" = podman ]; then
    socket=$(podman info --format '{{.Host.RemoteSocket.Path}}')
    socket=${socket#unix://}
    if ! answers "$socket"; then
      local scope=(--user)
      [ "$(id -u)" != 0 ] || scope=()
      systemctl "${scope[@]}" enable --now podman.socket >/dev/null 2>&1 || true
    fi
  else
    socket=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    socket=${socket#unix://}
    socket=${socket:-/var/run/docker.sock}
  fi
  if ! answers "$socket"; then
    echo "The supervisor needs $engine's socket, which does not answer at $socket$([ "$engine" != podman ] || echo ": systemctl --user enable --now podman.socket makes it")"
    return 1
  fi
  if [ "$(id -u)" != 0 ] && [ "$(stat -c %u "$socket")" != "$(id -u)" ]; then
    user=$(id -u):$(id -g)
    gid=$(stat -c %g "$socket")
  fi
  set_env EIN_SOCKET "$socket"
  set_env EIN_SUPERVISOR_USER "$user"
  set_env EIN_SOCKET_GID "$gid"
  set_env EIN_DEPLOY "$here"
  grep -q '^SUPERVISOR_KEY=.' .env || set_env SUPERVISOR_KEY "$(secret)"
  grep -q '^EIN_UPDATE_AT=' .env || set_env EIN_UPDATE_AT 04:00
  "$engine" pull "$SUPERVISOR_IMAGE" && return 0
  "$engine" image inspect "$SUPERVISOR_IMAGE" >/dev/null 2>&1 && echo "It goes on with the supervisor's image it has" && return 0
  echo "The supervisor's image, $SUPERVISOR_IMAGE, could not be pulled"
  return 1
}

# The engine's compose, which runs the services: here, or in the supervisor's image (supervise).
pick_compose() {
  "$engine" compose version >/dev/null 2>&1 ||
    fail "'$engine compose' does not run: install podman-compose (or docker-compose) for podman, or the compose plugin for Docker"
  # docker-compose under podman, when it is installed and podman-compose is not: it reaches podman
  # through podman's socket, and builds through it too rather than with a docker command.
  if [ "$engine" = podman ] && [[ $(podman compose version 2>&1) == *podman-compose* ]]; then compose_tool=podman-compose; fi
  if [ "$engine" = podman ] && [ "$compose_tool" != podman-compose ]; then
    export COMPOSE_DOCKER_CLI_BUILD=0
    curl -sf -o /dev/null --unix-socket "$(podman info --format '{{.Host.RemoteSocket.Path}}')" http://d/_ping ||
      fail "'podman compose' runs docker-compose here, which needs podman's socket: systemctl --user enable --now podman.socket, then ./setup.sh again"
  fi
  pick_ein_network
}

# EiN's network under rootless podman, where a port published on the compose network reaches EiN
# through rootlessport, from an address of that network, so every client would look like one: pasta,
# or slirp4netns with its own port handler under podman-compose before 1.1, which knows no pasta.
# Both keep the client's address. EiN then reaches the database, the media service and the model on
# this machine's loopback, where they are published for it (the loopback ports below). Empty under
# Docker and rootful podman, whose published ports keep the address, and where podman has neither.
pick_ein_network() {
  ein_network=
  [ "$engine" = podman ] && [ "$(podman info --format '{{.Host.Security.Rootless}}')" = true ] || return 0
  local version=
  [ "$compose_tool" != podman-compose ] || version=$(podman compose version 2>&1 | sed -n 's/^podman-compose version:* //p')
  if [ -n "$(podman info --format '{{.Host.Pasta.Executable}}' 2>/dev/null)" ] && ! [[ $version =~ ^(0\.|1\.0\.) ]]; then
    ein_network=pasta
  elif [ -n "$(podman info --format '{{.Host.Slirp4NetNS.Executable}}' 2>/dev/null)" ]; then
    ein_network=slirp4netns
  else
    echo "Neither pasta nor slirp4netns is here, so EiN sees every client as one address of its network: install passt, which has pasta"
  fi
}

# The loopback ports EiN reaches the database, the media service, the model and the supervisor on,
# when it has a network of its own (pick_ein_network): each published on 127.0.0.1 alone, and moved
# to the next free one like EiN's own ports.
declare -A loopback_ports=([EIN_DB_PORT]=15432 [EIN_EMS_PORT]=18181 [EIN_LLM_PORT]=18190 [EIN_SUPERVISOR_PORT]=18199)

# A service's loopback port as compose reads it in compose.override.yaml: from .env, or the default.
loopback_port() { echo "\${EIN_${1^^}_PORT:-${loopback_ports[EIN_${1^^}_PORT]}}"; }

has_dnsname() {
  local dir
  for dir in /usr/local/libexec/cni /usr/libexec/cni /usr/local/lib/cni /usr/lib/cni /opt/cni/bin; do
    [ ! -x "$dir/dnsname" ] || return 0
  done
  return 1
}

compose() { "$engine" compose -p ein "$@"; }

# The config hash podman-compose labels the containers it makes with, for the compose files as they
# are now, from a dry run; and the one the running containers were made from.
config_hash() {
  compose --dry-run up -d --no-deps db 2>&1 | grep -o 'io.podman.compose.config-hash=[0-9a-f]*' | head -1 | cut -d= -f2
}
running_hash() {
  local id
  id=$("$engine" ps -aq --filter label=com.docker.compose.project=ein | head -1)
  [ -z "$id" ] || "$engine" inspect -f '{{index .Config.Labels "io.podman.compose.config-hash"}}' "$id"
}

# The settings, with passwords made here: nothing else keeps them, so this file is the one to back up.
write_env() {
  local data=${data_dir:-$here/data} gpu=0 password=${INITIAL_ADMIN_PASSWORD:-}
  # .env is read by bash, by compose and by podman-compose's dotenv, which each take a backslash in
  # quotes their own way.
  if [ -n "$password" ]; then
    [ ${#password} -ge 8 ] || fail "INITIAL_ADMIN_PASSWORD is shorter than 8 characters"
    [[ $password != *[\'\\]* && $password != *$'\n'* ]] ||
      fail "INITIAL_ADMIN_PASSWORD holds a ' or a \\, which .env cannot keep as they are: choose one without"
  fi
  # A database from an earlier install has the password of that install's .env, which a new one
  # does not know: EiN would not get in.
  ! "$engine" volume inspect ein_db >/dev/null 2>&1 ||
    fail "the database of an earlier install is here, the volume ein_db, and its password was in the .env that is gone. Put that .env back, or remove the database for a new one: $engine volume rm ein_db"
  mkdir -p "$data"
  data=$(cd "$data" && pwd)
  # The database's folder belongs to its postgres user, which this user cannot read under rootless
  # podman or Docker: one that cannot be read holds an earlier install's database.
  [ ! -d "$data/db" ] || { [ -r "$data/db" ] && [ -z "$(ls -A "$data/db")" ]; } ||
    fail "the database of an earlier install is here, in $data/db, and its password was in the .env that is gone. Put that .env back, or remove the database for a new one: $(remove_dir_command) $data/db"
  if nvidia-smi >/dev/null 2>&1 && { [ -s /var/run/cdi/nvidia.yaml ] || compgen -G '/etc/cdi/nvidia*.yaml' >/dev/null; }; then gpu=1; fi
  cat >.env <<EOF
# EiN's settings, written by setup.sh on $(date +%F). Keep this file: the passwords below are in it
# and nowhere else. compose reads it, and EiN and the media service get it as their environment, so
# a CFG_ line for EiN or an EMS_ line for the media service goes here too. Apply a change with
# ./setup.sh, or \`$engine compose up -d\` when no option changed.$(swap_note)

# The compose project's name, which names its containers, network and volumes.
COMPOSE_PROJECT_NAME=ein

# This machine's name, which EiN's container takes: EiN shows this machine as the device of that
# name, with its CPU, memory, disks and temperatures.
EIN_HOSTNAME=$(machine_name)

# The container engine, podman or docker, which setup.sh picked at the install and keeps to: under
# the other one EiN would be a second, empty one.
EIN_ENGINE=$engine

# The options: the media service, the assistant's language model, and the graphics card for both.
# setup.sh --ems / --llm sets the first two; it found a card with its CDI spec, or did not.
EIN_EMS=0
EIN_LLM=0
EIN_GPU=$gpu

# The Devices module's sidecar, with setup.sh --devices, on this machine's own network: its
# MQTT broker, on the port the devices on this network reach it on, of EIN_BIND, with the passwords
# EiN (\`ein\`) and the devices (\`device\`) sign in with; and its restreamer for cameras, with
# its API and RTSP ports, and the password EiN signs in to it with.
EIN_DEVICES=0
MQTT_PORT=1883
MQTT_EIN_PASSWORD=$(secret)
MQTT_DEVICE_PASSWORD=$(secret 12)
STREAMS_PORT=1984
RTSP_PORT=8554
STREAMS_PASSWORD=$(secret)

# The supervisor, which installs the media service, the language model and the sidecar when EiN asks,
# and updates the services: with their modules, and each night at EIN_UPDATE_AT (off: only when
# asked). setup.sh --supervisor / --no-supervisor sets it; it is for installations from GitHub's einhq.
EIN_SUPERVISOR=0
EIN_UPDATE_AT=04:00

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

$(admin_password "$password")

# The web interface and SSH, on every address of this machine. 127.0.0.1 keeps them to this machine,
# behind an HTTPS proxy of your own.
EIN_BIND=0.0.0.0
EIN_HTTP_PORT=8080
EIN_SSH_PORT=2222

# The media service, for EiN alone on 127.0.0.1. A caller on another machine reaches it with
# EIN_EMS_BIND set to this machine's address on your network, at EIN_EMS_PORT (18181), and a key of
# its own in ems.keys beside this file, a line \`<key> <name> [<weight>]\` (the weight is its share
# when callers wait). It answers plain HTTP: only on a network you trust.
# EIN_EMS_BIND=127.0.0.1

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

# The database's folder, beside your files so a backup of EIN_DATA holds it too. setup.sh --db-dir
# moves it, such as onto a faster disk than the one the files are on; empty keeps it in the container
# engine's storage, as the volume ein_db.
EIN_DB_DIR=$data/db
EOF
  chmod 600 .env
  echo "Wrote .env: your files go under $data"
}

# The command that removes a folder the database's postgres user owns: under rootless podman it
# belongs to one of this user's subordinate ids, under Docker to root's.
remove_dir_command() { if [ "$engine" = podman ] && [ "$(id -u)" != 0 ]; then echo "podman unshare rm -rf"; else echo "sudo rm -rf"; fi; }

# .env's lines for the admin account's first password: the one chosen at the install, which
# setup.sh removes once EiN has taken it, or one made here, which it shows until you delete it.
admin_password() {
  if [ -n "$1" ]; then
    printf '%s\n' "$CHOSEN_PASSWORD" \
      "# EiN takes it at its first start, and setup.sh removes these lines once EiN has answered." \
      "INITIAL_ADMIN_PASSWORD='$1'"
  else
    printf '%s\n' \
      "# The admin account's first password, which EiN takes at its first start; changing it here later" \
      "# does nothing. setup.sh shows it at the end of each run until you delete this line: do that once" \
      "# you have changed the password in EiN." \
      "INITIAL_ADMIN_PASSWORD=$(secret 8)"
  fi
}
CHOSEN_PASSWORD="# The admin account's first password, chosen at the install."

# A random secret for .env, in hex: 24 bytes, or as many as given.
secret() { head -c "${1:-24}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# For .env's head under podman-compose: `up -d` leaves out the swap limit start gives each container.
swap_note() {
  [ "$compose_tool" = podman-compose ] || return 0
  printf '\n%s' \
    "# Under podman-compose, a container that \`podman compose up -d\` makes again has no swap limit," \
    "# which setup.sh gives it: the media service's idle models then go to swap, and a search waits" \
    "# for them. ./setup.sh makes the containers again with it."
}

is_port() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

set_env() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >>.env; fi
}
unset_env() { sed -i "/^$1=/d" .env; }

# .env as this script's variables, with the options an older .env does not name; this machine's
# name is written into it.
load_env() {
  # shellcheck disable=SC1091
  set -a && . ./.env && set +a
  : "${EIN_DEVICES:=0}"
  [ -n "${EIN_HOSTNAME:-}" ] || { EIN_HOSTNAME=$(machine_name); set_env EIN_HOSTNAME "$EIN_HOSTNAME"; export EIN_HOSTNAME; }
}

# This machine's name without its domain.
machine_name() { local name; name=$(uname -n); echo "${name%%.*}"; }

# The sidecar's passwords and ports, kept in .env, made the first time where an older .env lacks
# them. The sidecar hashes the broker's passwords itself, into its data folder EIN_DATA/mqtt, which
# keeps the broker's retained messages too.
devices_secrets() {
  local name value
  for name in MQTT_EIN_PASSWORD MQTT_DEVICE_PASSWORD STREAMS_PASSWORD; do
    [ -z "${!name:-}" ] || continue
    if [ "$name" = MQTT_DEVICE_PASSWORD ]; then value=$(secret 12); else value=$(secret); fi
    set_env "$name" "$value"
    printf -v "$name" %s "$value"
  done
  for name in MQTT_PORT=1883 STREAMS_PORT=1984 RTSP_PORT=8554; do
    value=${name#*=}
    name=${name%%=*}
    [ -z "${!name:-}" ] || continue
    set_env "$name" "$value"
    printf -v "$name" %s "$value"
  done
  mkdir -p "$EIN_DATA/mqtt"
}

# The sidecar is on this machine's own network, and EiN on the compose network reaches it at this
# machine's address on that network, never at its loopback: listening on 127.0.0.1 alone, it would be
# out of EiN's reach there.
check_devices_bind() {
  [ "$EIN_DEVICES" = 1 ] && [ -z "$ein_network" ] && [ "${EIN_BIND:-0.0.0.0}" = 127.0.0.1 ] || return 0
  fail "--devices listens on EIN_BIND, 127.0.0.1 here, where EiN's container cannot reach it under $engine: set EIN_BIND=0.0.0.0, or leave the sidecar out with --no-devices"
}

# One run in this folder at a time: this script runs again under flock, which holds a lock on the
# folder until that run ends, and a second run waits for the first. A run goes on when the ssh that
# started it is cut, and two at once would fetch the same sources together. -o keeps the lock out
# of what the run starts, so a container's monitor does not hold it after the run. Without flock a
# run goes on unlocked.
one_at_a_time() {
  [ -z "${EIN_SETUP_LOCKED:-}" ] && command -v flock >/dev/null || return 0
  flock -n "$here" true || echo "Another setup.sh is running in $here; waiting for it to end"
  export EIN_SETUP_LOCKED=1
  exec flock -o "$here" "$here/setup.sh" "$@"
}

# This folder, a clone of the source's deploy, moved to its newest commit before anything else, and
# this script run again with the same options when that changed it: an update takes the compose
# files and setup.sh as they are now, not as they were installed. The source is
# --source when given, else the one in .env; the token is EIN_SOURCE_KEY from the environment, else
# from .env when the source is on .env's host. A folder that is not a git clone is left as it is.
update_self() {
  local source=$1 installed= before after
  shift
  [ -e .git ] || return 0
  [ ! -f .env ] || installed=$(sed -n 's/^EIN_SOURCE=//p' .env)
  source=${source:-$installed}
  local EIN_SOURCE_KEY=${EIN_SOURCE_KEY:-}
  [ -n "$EIN_SOURCE_KEY" ] || [ -z "$installed" ] || [ "$(host_of "$source")" != "$(host_of "$installed")" ] ||
    EIN_SOURCE_KEY=$(sed -n 's/^EIN_SOURCE_KEY=//p' .env)
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
# On another host the token goes too, which that host would refuse: main sets the one given with
# --source after this.
set_source() {
  local url=$1 installed
  installed=$(sed -n 's/^EIN_SOURCE=//p' .env)
  if is_github "$url" && ! is_github "$installed"; then
    unset_env CFG_MODULE_SOURCES
    unset_env CFG_MODULE_SOURCES_KEY
  fi
  [ "$(host_of "$url")" = "$(host_of "$installed")" ] || set_env EIN_SOURCE_KEY ""
  set_env EIN_SOURCE "$url"
}

host_of() {
  local host=${1#*://}
  host=${host%%/*}
  echo "${host,,}"
}
is_github() { [[ $(host_of "$1") =~ ^(www\.)?github\.com$ ]]; }

# The images of EiN, the database and the media service are pulled when the sources are GitHub's
# einhq, which publishes them, and built here from the sources when they come from anywhere else,
# whose commits those images do not have.
built() { ! published "$EIN_SOURCE"; }

# The image a service runs, core, db, ems, devices or supervisor: the one GitHub publishes from the
# repository of that name (module-devices's sidecar for devices, deploy's supervisor/ for the
# supervisor), at the line its modules ask for (the media service and the sidecar, EIN_EMS_TAG and
# EIN_DEVICES_TAG) or :main, or the one built here.
image_of() {
  if built; then echo "localhost/ein-$1"; else echo "ghcr.io/einhq/$1:$(tag_of "$1")"; fi
}
tag_of() {
  case $1 in
    ems) echo "${EIN_EMS_TAG:-main}" ;;
    devices) echo "${EIN_DEVICES_TAG:-main}" ;;
    *) echo main ;;
  esac
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
db_sh() { "$engine" run --rm --user 0 --entrypoint sh -v "$1:/d:$2" "$(image_of db)" -c "$3"; }

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
  $engine run --rm --user 0 --entrypoint sh -v ein_db:/from:ro -v $EIN_DB_DIR:/to:z $(image_of db) -c 'cp -a /from/. /to/'
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
# such as another web server on 8080; one that EiN's containers publish is EiN's own. With a network
# of its own, the loopback ports too. The sidecar's, which it listens on itself on this machine's
# network, are its own while it runs.
free_ports() {
  local name port was ours names=(EIN_HTTP_PORT EIN_SSH_PORT)
  if [ "$EIN_DEVICES" = 1 ] &&
    [ -z "$("$engine" ps -q --filter label=com.docker.compose.project=ein --filter label=com.docker.compose.service=devices)" ]; then
    names+=(MQTT_PORT STREAMS_PORT RTSP_PORT)
  fi
  [ -z "$ein_network" ] || names+=("${!loopback_ports[@]}")
  ours=$("$engine" ps --filter label=com.docker.compose.project=ein --format '{{.Ports}}')
  for name in "${names[@]}"; do
    was=${!name:-${loopback_ports[$name]}}
    port=$was
    while [[ $ours != *":$port->"* ]] && port_taken "$port"; do port=$((port + 1)); done
    [ "$port" != "$was" ] || continue
    echo "Port $was is taken on this machine: EiN uses $port instead ($name in .env)"
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
#
# With a network of its own (pick_ein_network), EiN finds the database, the media service and the
# model by their names at this machine's loopback, on the loopback ports, which they are published
# on: pasta forwards those ports from EiN's loopback to this machine's, and slirp4netns lets EiN
# reach this machine's loopback, every port of it, at 10.0.2.2. A proxy on this machine reaches EiN
# from there too under slirp4netns, so EiN believes its forwarding headers (TRUSTED_PROXIES), and
# those of any proxy .env names in TRUSTED_PROXIES.
#
# The supervisor (compose.supervisor.yaml) is given the socket's group under Docker, and EiN its
# address and key.
#
# The devices sidecar is on this machine's own network, listening on its ports itself. EiN with a
# network of its own reaches it at this machine's loopback as it reaches the others; on the compose
# network, at this machine's address there: host.containers.internal under podman, the name
# devices as host-gateway under Docker. The media service, always on the compose network, reads
# the cameras' streams at the sidecar's RTSP the same way, which EiN tells it
# (CFG_DEVICES_STREAMS_RTSP).
write_override() {
  local service option lines env devices written=0 reached=() hosts=() forwards=() files_address files_published=
  local devices_host=devices
  local -A port_in=([db]=5432 [ems]=8181 [llm]=8190 [supervisor]=8199)
  # The media service reaches the files of its requests at EiN's ems-files port: by EiN's name on
  # the compose network, or, with EiN on a network of its own, at this machine's address, where the
  # port is published. One that .env names, a media service elsewhere, reaches it published too.
  files_address=${CFG_EMS_FILES_ADDRESS:-}
  if [ -n "$files_address" ]; then
    files_published=1
  elif [ "$EIN_EMS" = 1 ] && [ -n "$ein_network" ]; then
    files_address=host.containers.internal:${CFG_EMS_FILES_PORT:-2224}
    files_published=1
  elif [ "$EIN_EMS" = 1 ]; then
    files_address=core:${CFG_EMS_FILES_PORT:-2224}
  fi
  if [ -n "$ein_network" ]; then
    reached=(db)
    [ "$EIN_EMS" != 1 ] || reached+=(ems)
    [ "$EIN_LLM" != 1 ] || reached+=(llm)
    [ "$EIN_DEVICES" != 1 ] || reached+=(devices)
    [ "${EIN_SUPERVISOR:-0}" != 1 ] || reached+=(supervisor)
    for service in "${reached[@]}"; do
      hosts+=("\"$service:$([ "$ein_network" = pasta ] && echo 127.0.0.1 || echo 10.0.2.2)\"")
      if [ "$service" = devices ]; then
        forwards+=("-T,\${MQTT_PORT:-1883}" "-T,\${STREAMS_PORT:-1984}")
      else
        forwards+=("-T,$(loopback_port "$service")")
      fi
    done
  elif [ "$EIN_DEVICES" = 1 ] && [ "$engine" = docker ]; then
    hosts+=("\"devices:host-gateway\"")
  elif [ "$EIN_DEVICES" = 1 ]; then
    devices_host=host.containers.internal
  fi
  {
    echo "# Written by setup.sh from the options in .env and the container engine; edit those and run"
    echo "# setup.sh again."
    echo "services:"
    for service in db devices core ems llm supervisor; do
      lines=()
      case $service in
        supervisor)
          [ "${EIN_SUPERVISOR:-0}" = 1 ] || continue
          lines+=("extends: { file: compose.supervisor.yaml, service: supervisor }")
          [ -z "${EIN_SOCKET_GID:-}" ] || lines+=("group_add: [\"$EIN_SOCKET_GID\"]")
          ;;
        devices)
          [ "$EIN_DEVICES" = 1 ] || continue
          lines+=("extends: { file: compose.devices.yaml, service: devices }")
          lines+=("image: $(image_of devices)")
          ! built || lines+=("build: { context: src/module-devices/sidecar, dockerfile: Containerfile }")
          ;;
        ems | llm)
          option=EIN_${service^^}
          [ "${!option}" = 1 ] || continue
          lines+=("extends: { file: compose.$service.yaml, service: $service }")
          [ "$service" = llm ] || lines+=("image: $(image_of ems)")
          [ "$service" = llm ] || ! built || lines+=("build: { context: src/ems, dockerfile: Containerfile }")
          [ "$service" != ems ] || [ "$EIN_DEVICES" != 1 ] || [ "$engine" != docker ] || lines+=("extra_hosts: [\"devices:host-gateway\"]")
          devices=()
          [ "$EIN_GPU" != 1 ] || devices+=(nvidia.com/gpu=all)
          # The media service mounts the files of a request with sshfs (ems-files).
          [ "$service" != ems ] || devices+=(/dev/fuse)
          [ ${#devices[@]} = 0 ] || lines+=("devices: [$(IFS=,; echo "${devices[*]}")]")
          ;;
        core)
          ! built || lines+=("image: $(image_of core)" "build: { context: src/core, dockerfile: src/Containerfile }")
          env=()
          [ "$EIN_LLM" != 1 ] || env+=("CFG_LLM_CARD: $([ "$EIN_GPU" = 1 ] && echo card || echo cpu)")
          if [ -n "$ein_network" ]; then
            if [ "$ein_network" = pasta ]; then
              lines+=("network_mode: \"pasta:$(IFS=,; echo "${forwards[*]}")\"")
            else
              lines+=("network_mode: \"slirp4netns:port_handler=slirp4netns,allow_host_loopback=true\"")
              # A proxy on this machine reaches EiN from 10.0.2.2, not from loopback.
              env+=("TRUSTED_PROXIES: \"10.0.2.2,\${TRUSTED_PROXIES:-}\"")
            fi
            env+=("POSTGRES_URL: postgres://ein:\${POSTGRES_PASSWORD}@db:$(loopback_port db)/ein")
            [ "$EIN_EMS" != 1 ] || env+=("CFG_EMS_URL: http://ems:$(loopback_port ems)")
            [ "$EIN_LLM" != 1 ] || [ -n "${CFG_LLM_URL:-}" ] || env+=("CFG_LLM_URL: http://llm:$(loopback_port llm)")
          fi
          [ ${#hosts[@]} = 0 ] || lines+=("extra_hosts: [$(IFS=,; echo "${hosts[*]}")]")
          if [ "$EIN_DEVICES" = 1 ] && [ -z "${CFG_DEVICES_MQTT_URL:-}" ]; then
            env+=("CFG_DEVICES_MQTT_URL: mqtt://$devices_host:\${MQTT_PORT:-1883}")
            env+=("CFG_DEVICES_MQTT_USER: ein" "CFG_DEVICES_MQTT_KEY: \${MQTT_EIN_PASSWORD}")
            # What a device added from the network signs in with.
            env+=("CFG_DEVICES_DEVICE_USER: device" "CFG_DEVICES_DEVICE_KEY: \${MQTT_DEVICE_PASSWORD}")
          fi
          if [ "$EIN_DEVICES" = 1 ] && [ -z "${CFG_DEVICES_STREAMS_URL:-}" ]; then
            env+=("CFG_DEVICES_STREAMS_URL: http://$devices_host:\${STREAMS_PORT:-1984}")
            env+=("CFG_DEVICES_STREAMS_KEY: \${STREAMS_PASSWORD}")
          fi
          if [ "$EIN_DEVICES" = 1 ] && [ -z "${CFG_DEVICES_STREAMS_RTSP:-}" ]; then
            env+=("CFG_DEVICES_STREAMS_RTSP: rtsp://$([ "$engine" = docker ] && echo devices || echo host.containers.internal):\${RTSP_PORT:-8554}")
          fi
          [ -z "$files_address" ] || [ -n "${CFG_EMS_FILES_ADDRESS:-}" ] || env+=("CFG_EMS_FILES_ADDRESS: $files_address")
          if [ "${EIN_SUPERVISOR:-0}" = 1 ]; then
            env+=("CFG_SUPERVISOR_URL: http://supervisor:$(if [ -n "$ein_network" ]; then loopback_port supervisor; else echo 8199; fi)")
            env+=("CFG_SUPERVISOR_KEY: \${SUPERVISOR_KEY}")
          fi
          [ ${#env[@]} = 0 ] || lines+=("environment:" "${env[@]/#/  }")
          [ -z "$files_published" ] ||
            lines+=("ports: [\"\${EIN_BIND:-0.0.0.0}:\${CFG_EMS_FILES_PORT:-2224}:\${CFG_EMS_FILES_PORT:-2224}\"]")
          ;;
        db) ! built || lines+=("image: $(image_of db)" "build: { context: src/db, dockerfile: Containerfile }") ;;
      esac
      # The media service's port is on loopback for EiN on a network of its own, and on EIN_EMS_BIND
      # as well for a caller on another machine: 0.0.0.0 is both, and the port cannot be bound on it
      # and on 127.0.0.1 together. Its callers' keys beside EMS_KEY are in ems.keys.
      if [ "$service" = ems ] && [ "$EIN_EMS" = 1 ] && { [ -n "$ein_network" ] || [ -n "${EIN_EMS_BIND:-}" ]; }; then
        ems_ports=()
        { [ -n "$ein_network" ] || [ "${EIN_EMS_BIND:-}" = 127.0.0.1 ]; } && [ "${EIN_EMS_BIND:-}" != 0.0.0.0 ] &&
          ems_ports+=("\"127.0.0.1:$(loopback_port ems):8181\"")
        [ -z "${EIN_EMS_BIND:-}" ] || [ "$EIN_EMS_BIND" = 127.0.0.1 ] ||
          ems_ports+=("\"\${EIN_EMS_BIND}:$(loopback_port ems):8181\"")
        lines+=("ports: [$(IFS=,; echo "${ems_ports[*]}")]")
      elif [ -n "$ein_network" ] && [ -n "${port_in[$service]:-}" ]; then
        lines+=("ports: [\"127.0.0.1:$(loopback_port "$service"):${port_in[$service]}\"]")
      fi
      [ "$service" != ems ] || [ "$EIN_EMS" != 1 ] || [ ! -f ems.keys ] || lines+=("volumes: [\"./ems.keys:/etc/ems.keys:ro\"]")
      [ "$engine" != podman ] || lines+=("restart: always")
      [ ${#lines[@]} != 0 ] || continue
      echo "  $service:"
      printf '    %s\n' "${lines[@]}"
      written=1
    done
    # Never an empty services: docker-compose 1.x takes such a file for its old version 1 format.
    [ "$written" = 1 ] || echo "  core: {}"
  } >compose.override.yaml
}

# A repository cloned the first time and moved to its newest commit after, so a run is an update.
# Its origin follows the source, so a new --source takes effect at the next pull.
fetch() {
  if [ -d "$2/.git" ]; then
    git -C "$2" remote set-url origin "$EIN_SOURCE/$1.git"
    git_source -C "$2" fetch --quiet origin
    git -C "$2" merge --ff-only --quiet '@{upstream}'
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

# Every image, or the one service's when one is named: EiN's, the database's, the media service's,
# the devices sidecar's and the supervisor's pulled, or the first four built from their sources
# (built), where there is no supervisor. The model's is neither: compose up pulls it.
build() {
  local one=${1:-} service services=()
  for service in core db ems devices supervisor; do
    [ -z "$one" ] || [ "$one" = "$service" ] || continue
    [ "$service" != ems ] || [ "$EIN_EMS" = 1 ] || continue
    [ "$service" != devices ] || [ "$EIN_DEVICES" = 1 ] || continue
    [ "$service" != supervisor ] || [ "${EIN_SUPERVISOR:-0}" = 1 ] || continue
    services+=("$service")
  done
  [ ${#services[@]} != 0 ] || return 0
  # Under podman a pull's and a build's scratch files go next to its storage: /tmp is often too
  # small for the media service's layers. Docker keeps them in its own storage already, and so does
  # podman for its remote client, in the supervisor's image.
  if [ "$engine" = podman ] && [ -z "${EIN_SUPERVISOR_JOB:-}" ]; then
    TMPDIR="$(podman info --format '{{.Store.GraphRoot}}')/tmp"
    mkdir -p "$TMPDIR"
    export TMPDIR
  fi
  if ! built; then
    for service in "${services[@]}"; do
      case $service in
        ems | devices) pull_service "$service" || true ;;
        # Its image may be one GitHub has not published yet: the one here goes on.
        supervisor) "$engine" pull "$SUPERVISOR_IMAGE" || "$engine" image inspect "$SUPERVISOR_IMAGE" >/dev/null ;;
        *) "$engine" pull "$(image_of "$service")" ;;
      esac
    done
    return
  fi
  local cached=()
  for service in "${services[@]}"; do
    case $service in
      # What core's system-info says it runs, as a tree without its .git says it: the commit and its date.
      core) git -C src/core log -1 --format='{"commit":"%h","date":"%cI"}' >src/core/src/build.json ;;
      # What the media service's health reports as its build, as its own Makefile writes it.
      ems) echo "$(git -C src/ems describe --always --dirty) $(git -C src/ems log -1 --format=%cI)" >src/ems/ems/BUILD ;;
    esac
    [ "$service" = db ] || cached+=("$service")
  done
  [ ${#cached[@]} = 0 ] || build_images "${cached[@]}"
  # The database's PostgreSQL and extensions come at the newest release their apt repositories have,
  # which a cached layer would keep from the build that made it.
  [ ${#cached[@]} = ${#services[@]} ] || build_images --no-cache db
}

# The services' images built, tried twice: a download a build needs, such as the guide's archive
# from GitHub, fails now and then. A build that fails twice stops the update, and the containers
# keep running on the images they have.
build_images() {
  local try
  for try in 1 2; do
    if [ "$compose_tool" = podman-compose ]; then podman_compose_build "$@" && return; else compose build "$@" && return; fi
    [ "$try" = 2 ] || echo "The build failed; it is tried once more"
  done
  fail "the images did not build, so EiN runs on as it was; the build's output is above"
}

# podman-compose 1.0 goes on past a build that fails and exits 0, the old image keeping the name.
# So the name is taken off the old image first: a build that leaves no image under it failed, and
# the old image gets its name back.
podman_compose_build() {
  local arg service image failed=0
  local -A old=()
  for arg in "$@"; do
    [[ $arg == -* ]] && continue
    image=$(image_of "$arg")
    old[$arg]=$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)
    [ -z "${old[$arg]}" ] || podman untag "${old[$arg]}" "$image"
  done
  compose build "$@" || failed=1
  for service in "${!old[@]}"; do
    image=$(image_of "$service")
    podman image exists "$image" && continue
    failed=1
    [ -z "${old[$service]}" ] || podman tag "${old[$service]}" "$image"
  done
  [ "$failed" = 0 ]
}

# The ids of the images build tags or pull.
built_images() {
  local repo name
  for repo in core db ems devices supervisor; do
    for name in "localhost/ein-$repo" "ghcr.io/einhq/$repo:main" "ghcr.io/einhq/$repo:$(tag_of "$repo")"; do
      "$engine" image inspect --format '{{.Id}}' "$name" 2>/dev/null || true
    done
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

# EiN answers once its database is up and its boot is through; false, saying why, when it does not.
wait_for_ein() {
  local url="http://127.0.0.1:$EIN_HTTP_PORT/" id line last= down=0
  echo "Waiting for EiN to answer at $url; its first start takes a minute or more"
  for i in $(seq 300); do
    if curl -fs -o /dev/null --max-time 5 "$url"; then
      echo
      echo "EiN is up at http://$(hostname):$EIN_HTTP_PORT/"
      if grep -qxF "$CHOSEN_PASSWORD" .env; then
        sed -i "/^$CHOSEN_PASSWORD\$/,/^INITIAL_ADMIN_PASSWORD=/d" .env
        echo "Sign in as admin with the password you chose."
      elif [ -n "${INITIAL_ADMIN_PASSWORD:-}" ]; then
        echo "Sign in as admin with the password $INITIAL_ADMIN_PASSWORD and change it, then delete the line INITIAL_ADMIN_PASSWORD from $here/.env."
      fi
      return
    fi
    # A container that stopped, or that its engine restarts again and again, does not come up by
    # waiting longer.
    id=$("$engine" ps -aq --filter label=com.docker.compose.project=ein --filter label=com.docker.compose.service=core | head -1)
    if [ -z "$id" ] || [ "$("$engine" inspect --format '{{.State.Running}}' "$id")" != true ]; then
      down=$((down + 1))
    else
      down=0
    fi
    if [ "$down" -ge 3 ] || { [ -n "$id" ] && [ "$("$engine" inspect --format '{{.RestartCount}}' "$id")" -ge 3 ]; }; then
      [ -z "$id" ] || "$engine" logs --tail 30 "$id" >&2 || true
      echo "setup.sh: EiN stopped before it answered; its log is above: $engine compose logs core" >&2
      return 1
    fi
    # Every 10 seconds, what EiN last logged, when it is new.
    if [ -n "$id" ] && [ $((i % 5)) = 0 ]; then
      line=$("$engine" logs --tail 1 "$id" 2>&1 | tail -1 | cut -c1-150)
      [ -z "$line" ] || [ "$line" = "$last" ] || echo "  $line"
      last=$line
    fi
    sleep 2
  done
  echo "setup.sh: EiN did not answer at $url in 10 minutes: $engine compose logs core" >&2
  return 1
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
