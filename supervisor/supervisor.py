"""EiN's supervisor: installs and updates the services beside EiN, which EiN asks for over HTTP.

It holds the container engine's socket, which EiN never gets: the socket is root on the machine
under Docker and the whole account under rootless podman, and EiN faces the network and runs
modules' code. EiN reaches it on the compose network, with the key SUPERVISOR_KEY, and may ask
three things, of a fixed set of services:

  GET  /v0/status            each service: whether it is installed, its container, its image, the
                             release it runs and the newer one an update would install; what the
                             modules ask for; the job
  POST /v0/install/<name>    install the media service (ems), the language model (llm) or the
                             devices sidecar (devices): `setup.sh --<name>`
  POST /v0/update            update now, {"services": [...]} or every one with a newer release:
                             `setup.sh --only <names>`, which rolls a service back to the version it
                             ran when the new one does not come up

Each is a job: setup.sh, run in a container of this image beside this one, with the deploy folder
and the data folder mounted at their own paths, so compose reads them as setup.sh on the machine
does. The job's output and outcome are kept under the data folder (supervisor/), which is how the
status reports a job that went on while this container was made again.

Each service runs a release, an image GitHub builds once for it, at the version .env pins
(EIN_CORE_VERSION and the like). Once an hour the supervisor reads which releases GitHub's registry
has, and a service has an update when a newer one is there than the one it runs: the newest of the
line its modules ask for (mod.json's services, `"ems": "^0.4.4"`: 0.4.4 or a newer 0.4) for the media
service and the sidecar, the newest of all for EiN and the database, and deploy's newest release for
the supervisor. The language model has one when compose.llm.yaml names another image than it runs.

Without being asked, once a minute: a service whose version its modules no longer take, another line
or an older patch than one asks for, is updated, and every service with an update is at
EIN_UPDATE_AT (.env, default 04:00, `off` for never), in the hour after it.

`supervisor job <setup.sh options>` is the job itself, run in that container.
"""

import hmac
import http.client
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = '0.1.0'
SOCKET = '/run/engine.sock'
PORT = int(os.environ.get('SUPERVISOR_PORT', '8199'))
DEPLOY = Path(os.environ.get('EIN_DEPLOY', '/ein'))
JOB = 'ein-supervisor-job'
# The container setup.sh runs itself in when it is run on the machine.
SETUP = 'ein-setup'
LOG_LINES = 200

# The services, in the order an update takes them: the supervisor last, since the job makes it
# again. The optional ones are installed on request; core, db and the supervisor always are. Each
# but the model is an einhq image with releases.
ORDER = ['db', 'core', 'ems', 'devices', 'llm', 'supervisor']
OPTIONAL = {'ems', 'llm', 'devices'}
RELEASED = ['db', 'core', 'ems', 'devices', 'supervisor']
TITLES = {
    'core': 'EiN',
    'db': 'the database',
    'ems': 'the media service',
    'llm': 'the language model',
    'devices': 'the devices sidecar',
    'supervisor': 'the supervisor',
}
SIZES = {
    'ems': 'an image of about 30 GB',
    'llm': 'an image of about 3 GB, and a model of about 5 GB fetched into the data folder at its first start',
    'devices': 'an image of about 100 MB',
}


def memory(limit):
    """A compose memory limit as people write it: `16g` → `16 GB`."""
    match = re.match(r'^(\d+(?:\.\d+)?)\s*([kmgt])b?$', limit.strip().lower())
    return f'{match.group(1)} {match.group(2).upper()}B' if match else limit


def gives(name, env):
    """What a service is given beyond an ordinary container, which installing it asks about."""
    card = ['the graphics card'] if env.get('EIN_GPU') == '1' else []
    if name == 'ems':
        return card + [
            '/dev/fuse and the SYS_ADMIN capability, without an AppArmor profile: it mounts the files of each request from EiN with sshfs',
            f"up to {memory(env.get('EMS_MEMORY') or '16g')} of memory",
        ]
    if name == 'llm':
        return card + [f"up to {memory(env.get('LLM_MEMORY') or '10g')} of memory"]
    if name == 'devices':
        ports = ', '.join(env.get(key) or default for key, default in (('MQTT_PORT', '1883'), ('STREAMS_PORT', '1984')))
        return [
            "this machine's network: it asks what is on it over mDNS and SSDP, and hears the devices' announcements",
            f"the ports {ports} on {env.get('EIN_BIND') or '0.0.0.0'}: the devices' MQTT broker, without TLS, and the cameras' streams",
        ]
    return []


def read_env():
    """.env as setup.sh writes it, KEY=value a line."""
    env = {}
    try:
        for line in (DEPLOY / '.env').read_text().splitlines():
            match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
            if match:
                value = match.group(2).strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                    value = value[1:-1]
                env[match.group(1)] = value
    except FileNotFoundError:
        pass
    return env


def state_dir(env):
    path = Path(env.get('EIN_DATA') or DEPLOY / 'data') / 'supervisor'
    path.mkdir(parents=True, exist_ok=True)
    return path


def installed(name, env):
    if name in OPTIONAL:
        return env.get(f'EIN_{name.upper()}') == '1'
    return name != 'supervisor' or env.get('EIN_SUPERVISOR') == '1'


# The engine's API, the Docker one, which podman serves too.


class EngineConnection(http.client.HTTPConnection):
    def __init__(self):
        super().__init__('engine', timeout=30)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(SOCKET)


def engine(path):
    """GET a path of the engine's API: its JSON, or None for 404."""
    connection = EngineConnection()
    try:
        connection.request('GET', path)
        response = connection.getresponse()
        body = response.read()
        if response.status == 404:
            return None
        if response.status >= 300:
            raise RuntimeError(f'the engine answered {response.status} to {path}: {body[:200]!r}')
        return json.loads(body) if body else None
    finally:
        connection.close()


def running(name):
    container = engine(f'/containers/{name}/json')
    return bool(container and container.get('State', {}).get('Running'))


def containers():
    """The ein project's containers, by service: the newest of each."""
    filters = urllib.parse.quote(json.dumps({'label': ['com.docker.compose.project=ein']}))
    found = {}
    for each in engine(f'/containers/json?all=true&filters={filters}') or []:
        service = (each.get('Labels') or {}).get('com.docker.compose.service')
        if service and (service not in found or each.get('Created', 0) > found[service].get('Created', 0)):
            found[service] = each
    return found


def describe(name, env, listed, wanted):
    service = {
        'name': name,
        'title': TITLES[name],
        'optional': name in OPTIONAL,
        'installed': installed(name, env),
        'gives': gives(name, env),
    }
    if name in SIZES:
        service['size'] = SIZES[name]
    if name in wanted:
        service['wanted'] = wanted[name]
    container = listed.get(name)
    if not container:
        return service
    inspected = engine(f"/containers/{container['Id']}/json") or {}
    state = inspected.get('State') or {}
    service['state'] = state.get('Status') or container.get('State') or 'unknown'
    # podman reports a container without a health check as starting.
    health = (state.get('Health') or {}).get('Status') if ((inspected.get('Config') or {}).get('Healthcheck') or {}).get('Test') else None
    if health:
        service['health'] = health
    service['since'] = state.get('StartedAt')
    service['image'] = (inspected.get('Config') or {}).get('Image') or container.get('Image')
    image = engine(f"/images/{urllib.parse.quote(inspected.get('Image') or container.get('ImageID') or '', safe='')}/json") or {}
    labels = (image.get('Config') or {}).get('Labels') or {}
    # Images from before releases said the media service's and the sidecar's version as eu.einhq.api.
    version = labels.get('eu.einhq.version') or labels.get('eu.einhq.api')
    if version:
        service['version'] = version
    if image.get('Created'):
        service['built'] = image['Created']
    newer = available(name, env, service.get('version'), service['image'], wanted)
    if newer:
        service['available'] = newer
    return service


# What the installed modules ask for: mod.json's services, a caret range of each.


def version_key(version):
    return tuple(int(part) for part in version.split('.') if part.isdigit())


def line_of(version):
    parts = version.split('.')
    return f'0.{parts[1]}' if parts[0] == '0' and len(parts) > 1 else parts[0]


def wanted_lines(env):
    """Each service a module names: the newest line asked for, the highest version asked for in it
    (`^0.6` asks for 0.6), and who asks what."""
    asked = {}
    for manifest in sorted(Path(env.get('EIN_DATA') or DEPLOY / 'data').glob('modules/*/mod.json')):
        try:
            services = json.loads(manifest.read_text()).get('services') or {}
        except (OSError, ValueError):
            continue
        for service, wanted in services.items():
            if isinstance(wanted, str) and re.match(r'^\^\d+\.\d+(\.\d+)?$', wanted):
                asked.setdefault(service, []).append({'module': manifest.parent.name, 'range': wanted})
    wanted = {}
    for service, modules in asked.items():
        lines = sorted({line_of(each['range'][1:]) for each in modules}, key=version_key)
        least = max((each['range'][1:] for each in modules if line_of(each['range'][1:]) == lines[-1]), key=version_key)
        wanted[service] = {'line': lines[-1], 'least': least, 'modules': modules}
    return wanted


# The releases GitHub's registry has of each einhq image, read once an hour (refresh), and the
# newer one a service would be updated to.

REGISTRY = 'https://ghcr.io'
CHECK_EVERY = 3600
releases = {}
checked = {'at': None, 'error': None}


def registry_versions(name):
    """The release versions (x.y.z tags) the registry has of ghcr.io/einhq/<name>."""
    with urllib.request.urlopen(f'{REGISTRY}/token?scope=repository:einhq/{name}:pull', timeout=30) as response:
        token = json.load(response)['token']
    request = urllib.request.Request(f'{REGISTRY}/v2/einhq/{name}/tags/list?n=10000', headers={'Authorization': f'Bearer {token}'})
    with urllib.request.urlopen(request, timeout=30) as response:
        tags = json.load(response).get('tags') or []
    return sorted({tag for tag in tags if re.match(r'^\d+\.\d+\.\d+$', tag)}, key=version_key)


def refresh():
    """Every image's releases, read again; one the registry does not answer for keeps what it had."""
    errors = []
    for name in RELEASED:
        try:
            releases[name] = registry_versions(name)
        except Exception as error:  # noqa: BLE001 - said in the status, and tried again in an hour
            errors.append(f'{name}: {error}')
    checked['at'] = time.time()
    checked['error'] = '; '.join(errors) or None


def meets(version, asked):
    """Whether a version is in the line its modules ask for, at the version asked or above."""
    return line_of(version) == asked['line'] and version_key(version) >= version_key(asked['least'])


def newest(name, wanted):
    """The newest release of a service, of those its modules take (the media service and the
    sidecar), or None when none is known."""
    versions = releases.get(name) or []
    if name in ('ems', 'devices') and name in wanted:
        versions = [version for version in versions if meets(version, wanted[name])]
    return versions[-1] if versions else None


def llm_image(env):
    """The model's image compose would start: LLM_IMAGE in .env, or compose.llm.yaml's own."""
    if env.get('LLM_IMAGE'):
        return env['LLM_IMAGE']
    try:
        match = re.search(r'^\s*image:\s*\$\{LLM_IMAGE:-([^}]+)\}', (DEPLOY / 'compose.llm.yaml').read_text(), re.M)
    except OSError:
        return None
    return match.group(1) if match else None


def available(name, env, version, image, wanted):
    """What an update of a service would install that it does not run: {version, image} for a newer
    release, {image} for the model's other image; None when it runs the newest."""
    if name == 'llm':
        named = llm_image(env)
        return {'image': named} if named and named != image else None
    if name not in RELEASED:
        return None
    candidate = newest(name, wanted)
    if not candidate:
        return None
    # A container from before releases runs :main or a line, which its update pins.
    pinned = re.match(rf'^ghcr\.io/einhq/{name}:\d+\.\d+\.\d+$', image or '')
    if pinned and version and version_key(candidate) <= version_key(version):
        return None
    return {'version': candidate, 'image': f'ghcr.io/einhq/{name}:{candidate}'}


def updatable(env):
    """The installed services with something to install, in the order an update takes them."""
    listed = containers()
    wanted = wanted_lines(env)
    return [name for name in ORDER if installed(name, env) and listed.get(name) and describe(name, env, listed, wanted).get('available')]


# Jobs: setup.sh in a container of this image.


class Busy(Exception):
    pass


jobs = threading.Lock()


def busy():
    return running(JOB) or running(SETUP)


# The secrets compose's commands carry, `-e EMS_KEY=…` and `postgres://ein:…@`, which the job's
# lines in EiN do not show.
SECRET = re.compile(r'(\b[A-Z0-9_]*(?:PASSWORD|KEY|SECRET|TOKEN)[A-Z0-9_]*=)(?:"[^"]*"|\'[^\']*\'|[^\s\'"]+)|(://[^/\s:@]+:)[^@\s]+(@)')


def masked(line):
    return SECRET.sub(lambda match: f'{match.group(1)}…' if match.group(1) else f'{match.group(2)}…{match.group(3)}', line)


def job_status(env):
    folder = state_dir(env)
    try:
        job = json.loads((folder / 'job.json').read_text())
    except (OSError, ValueError):
        return None
    try:
        lines = [masked(line) for line in (folder / 'job.log').read_text(errors='replace').splitlines()[-LOG_LINES:]]
    except OSError:
        lines = []
    job['lines'] = lines
    exit_file = folder / 'job.exit'
    if exit_file.exists():
        code = int(exit_file.read_text().strip() or '1')
        job['state'] = 'done' if code == 0 else 'failed'
        job['endedAt'] = time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(exit_file.stat().st_mtime))
    elif running(JOB):
        job['state'] = 'running'
    else:
        job['state'] = 'failed'
        job['lines'].append('The job stopped before it ended, as when the machine went down during it.')
    return job


def start_job(args, by):
    """setup.sh with these options in a job container, unless one runs."""
    with jobs:
        if busy():
            raise Busy('an install or update is running')
        env = read_env()
        folder = state_dir(env)
        job = {'id': time.strftime('%Y%m%d-%H%M%S'), 'args': args, 'by': by, 'startedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z')}
        (folder / 'job.exit').unlink(missing_ok=True)
        (folder / 'job.log').write_text('')
        (folder / 'job.json').write_text(json.dumps(job))
        engine_cli = env.get('EIN_ENGINE') or 'podman'
        mounts = [f"{env['EIN_SOCKET']}:{SOCKET}", f'{DEPLOY}:{DEPLOY}']
        for folder_path in {env.get('EIN_DATA'), env.get('EIN_DB_DIR')} - {None, ''}:
            mounts.append(f'{folder_path}:{folder_path}')
        command = [engine_cli, 'run', '-d', '--rm', '--name', JOB, '--network', 'host', '--uts', 'host', '--security-opt', 'label=disable']
        command += ['--user', env.get('EIN_SUPERVISOR_USER') or '0:0']
        if env.get('EIN_SOCKET_GID'):
            command += ['--group-add', env['EIN_SOCKET_GID']]
        for mount in mounts:
            command += ['-v', mount]
        # A service on its newest release already stays as it is. The job runs in the supervisor's
        # release .env pins now, which an update of the supervisor moves before it makes it again.
        image = f"ghcr.io/einhq/supervisor:{env['EIN_SUPERVISOR_VERSION']}" if env.get('EIN_SUPERVISOR_VERSION') else os.environ['SUPERVISOR_IMAGE']
        command += ['-e', f'EIN_DEPLOY={DEPLOY}', '-e', 'EIN_SUPERVISOR_JOB=1', '-e', 'EIN_KEEP_CURRENT=1', '-w', str(DEPLOY), image, 'job', *args]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            (folder / 'job.log').write_text(result.stdout + result.stderr)
            (folder / 'job.exit').write_text('1')
            raise RuntimeError(f'the job did not start: {(result.stderr or result.stdout).strip()}')
        print(f"supervisor: {by}: setup.sh {' '.join(args)}", flush=True)
        return job


def run_job(args):
    """The job: setup.sh, its output into the log and its exit status beside it."""
    env = read_env()
    folder = state_dir(env)
    with open(folder / 'job.log', 'ab') as log:
        code = subprocess.call(['./setup.sh', *args], cwd=DEPLOY, stdout=log, stderr=subprocess.STDOUT)
    (folder / 'job.exit').write_text(str(code))
    return code


# Unasked: the registry read again, a service whose modules do not take the version it runs, and the
# nightly update.

tried = {}


def tick():
    if checked['at'] is None or time.time() - checked['at'] >= CHECK_EVERY:
        refresh()
    env = read_env()
    if busy():
        return
    listed = containers()
    wanted = wanted_lines(env)
    for name in ('ems', 'devices'):
        if not installed(name, env) or not listed.get(name):
            continue
        service = describe(name, env, listed, wanted)
        newer = (service.get('available') or {}).get('version')
        running = service.get('version')
        asked = wanted.get(name)
        if not newer or not asked or (running and meets(running, asked)):
            continue
        # A release that did not come up is tried again a day later.
        if time.time() - tried.get((name, newer), 0) < 86400:
            continue
        tried[(name, newer)] = time.time()
        modules = [each['module'] for each in asked['modules'] if each['range'][1:] == asked['least']]
        start_job(['--only', name], f"the supervisor: {' and '.join(modules)} {'asks' if len(modules) == 1 else 'ask'} for {TITLES[name]} ^{asked['least']}")
        return
    at = env.get('EIN_UPDATE_AT', '04:00')
    match = re.match(r'^(\d{1,2}):(\d{2})$', at)
    if not match:
        return
    now = time.localtime()
    minutes = now.tm_hour * 60 + now.tm_min - (int(match.group(1)) * 60 + int(match.group(2)))
    if not 0 <= minutes < 60:
        return
    marker = state_dir(env) / 'updated'
    today = time.strftime('%Y-%m-%d', now)
    if marker.exists() and marker.read_text().strip() == today:
        return
    marker.write_text(today)
    names = updatable(env)
    if names:
        start_job(['--only', ','.join(names)], 'the supervisor: the nightly update')


def follow_zone():
    """The machine's time zone, .env's TZ, for the nightly update and the jobs' times."""
    zone = read_env().get('TZ')
    if zone and os.environ.get('TZ') != zone:
        os.environ['TZ'] = zone
        time.tzset()


def schedule():
    while True:
        time.sleep(60)
        try:
            follow_zone()
            tick()
        except Busy:
            pass
        except Exception as error:  # noqa: BLE001 - the loop goes on, and says why it did not
            print(f'supervisor: {error}', flush=True)


# The API.


def status():
    env = read_env()
    listed = containers()
    wanted = wanted_lines(env)
    if checked['at'] is None:
        threading.Thread(target=refresh, daemon=True).start()
    services = [describe(name, env, listed, wanted) for name in ORDER]
    # A service a module names that the supervisor does not know is reported as such, not installed.
    for name in sorted(set(wanted) - set(ORDER)):
        services.append({'name': name, 'title': name, 'optional': False, 'installed': False, 'gives': [], 'wanted': wanted[name], 'unknown': True})
    at = env.get('EIN_UPDATE_AT', '04:00')
    return {
        'version': VERSION,
        'engine': env.get('EIN_ENGINE') or 'podman',
        'updateAt': None if at == 'off' else at,
        'checkedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(checked['at'])) if checked['at'] else None,
        'checkError': checked['error'],
        'services': services,
        'job': job_status(env),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def answer(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorised(self):
        key = os.environ.get('SUPERVISOR_KEY', '')
        given = self.headers.get('Authorization', '')
        if key and hmac.compare_digest(given.encode(), f'Bearer {key}'.encode()):
            return True
        self.answer(401, {'error': 'the supervisor needs its key'})
        return False

    def body(self):
        length = int(self.headers.get('Content-Length') or 0)
        if not length:
            return {}
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            return {}
        return body if isinstance(body, dict) else {}

    def do_GET(self):
        if self.path == '/v0/ping':
            return self.answer(200, {'version': VERSION})
        if not self.authorised():
            return None
        if self.path == '/v0/status':
            try:
                return self.answer(200, status())
            except Exception as error:  # noqa: BLE001 - EiN shows why
                return self.answer(502, {'error': str(error)})
        return self.answer(404, {'error': f'no {self.path} here'})

    def do_POST(self):
        if not self.authorised():
            return None
        body = self.body()
        by = str(body.get('by') or 'EiN')[:100]
        env = read_env()
        try:
            match = re.match(r'^/v0/install/([a-z]+)$', self.path)
            if match:
                name = match.group(1)
                if name not in OPTIONAL:
                    return self.answer(400, {'error': f"{name} is not a service EiN installs: {', '.join(sorted(OPTIONAL))} are"})
                if installed(name, env):
                    return self.answer(409, {'error': f'{TITLES[name]} is installed already'})
                return self.answer(202, {'job': start_job([f'--{name}'], by)})
            if self.path == '/v0/update':
                names = body.get('services') or updatable(env)
                if not names:
                    return self.answer(409, {'error': 'every service runs its newest release'})
                if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
                    return self.answer(400, {'error': 'services is a list of names'})
                for name in names:
                    if name not in ORDER:
                        return self.answer(400, {'error': f"{name} is not a service here: {', '.join(ORDER)} are"})
                    if not installed(name, env):
                        return self.answer(409, {'error': f'{TITLES[name]} is not installed'})
                ordered = [name for name in ORDER if name in names]
                return self.answer(202, {'job': start_job(['--only', ','.join(ordered)], by)})
        except Busy as error:
            return self.answer(409, {'error': str(error)})
        except Exception as error:  # noqa: BLE001 - EiN shows why
            return self.answer(502, {'error': str(error)})
        return self.answer(404, {'error': f'no {self.path} here'})


def serve():
    if not os.environ.get('SUPERVISOR_KEY'):
        sys.exit('supervisor: SUPERVISOR_KEY is not set')
    follow_zone()
    threading.Thread(target=schedule, daemon=True).start()
    # As the container's first process it would ignore the engine's SIGTERM and be killed 10 s later;
    # a job runs in a container of its own, so stopping here leaves it running.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print(f'supervisor {VERSION}: answering on {PORT}', flush=True)
    ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'job':
        sys.exit(run_job(sys.argv[2:]))
    serve()
