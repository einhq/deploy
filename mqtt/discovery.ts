/**
 * The network listener beside the MQTT broker: what announces itself on this machine's network over
 * mDNS (Bonjour, `_shelly._tcp`, `_hap._tcp`, …) and SSDP (UPnP: TVs, speakers, routers), published
 * on the broker for the Automation module to name and offer as devices.
 *
 * It runs on the host's network, since the multicast it asks with stays on the network it is sent
 * on. Every round (DISCOVERY_INTERVAL seconds, 120 by default) it asks:
 *
 * - mDNS: which service types there are (`_services._dns-sd._udp.local`), then who offers each, from
 *   a port of its own, so responders answer it directly (RFC 6762 §6.7) and a responder already on
 *   5353, such as Avahi, is left alone;
 * - SSDP: `M-SEARCH ssdp:all`, then the description each answer points at, once per address;
 * - the host's ARP table, for the hardware address of each IP that answered.
 *
 * What one address said is one retained JSON message, `<prefix>/host/<id>` (`ein/discovery` by
 * default), the id being its hardware address without colons or, when that is not known, its IP:
 *
 *   { ip, mac?, names: [host.local], seen: <ISO time>,
 *     mdns: [{ type, instance, port?, txt: {k: v} }],
 *     ssdp: [{ st, usn?, server?, location?, friendlyName?, manufacturer?, modelName?,
 *              modelNumber?, serialNumber?, deviceType?, udn? }] }
 *
 * An address unheard for DISCOVERY_FORGET seconds (a day by default) is cleared with an empty
 * retained message. `<prefix>/status`, retained, says when the last round was, how many addresses
 * answered it and `broker`, the address the devices that answered reach the broker at: MQTT_HOST
 * when it names one, else this machine's address on the network most of them are on.
 *
 * Plain Deno with no imports: MQTT 3.1.1 (CONNECT, PUBLISH at QoS 0, DISCONNECT) is written here, one
 * connection per round. Needs --allow-net, --allow-env, --allow-run=cat (the ARP table),
 * --allow-sys=networkInterfaces and --unstable-net (for UDP).
 */

const env = (key: string, fallback = ''): string => Deno.env.get(key)?.trim() || fallback;
const seconds = (key: string, fallback: number): number => {
  const value = Number(env(key));
  return Number.isFinite(value) && value > 0 ? value : fallback;
};

const BIND = env('MQTT_HOST', '127.0.0.1');
const MQTT_HOST = BIND === '0.0.0.0' ? '127.0.0.1' : BIND;
const MQTT_PORT = Number(env('MQTT_PORT', '1883'));
const MQTT_USER = env('MQTT_USER', 'ein');
const MQTT_PASSWORD = env('MQTT_PASSWORD');
const PREFIX = env('DISCOVERY_PREFIX', 'ein/discovery').replace(/\/+$/, '');
const INTERVAL_MS = seconds('DISCOVERY_INTERVAL', 120) * 1000;
const FORGET_MS = seconds('DISCOVERY_FORGET', 86_400) * 1000;
/** How long a round listens for answers, for each of mDNS's two questions and SSDP's one. */
const LISTEN_MS = 3000;

const log = (line: string) => console.log(`discovery: ${line}`);
const message = (error: unknown): string => error instanceof Error ? error.message : String(error);

type MdnsService = { type: string; instance: string; port?: number; txt: Record<string, string> };
type SsdpService = {
  st: string;
  usn?: string;
  server?: string;
  location?: string;
  friendlyName?: string;
  manufacturer?: string;
  modelName?: string;
  modelNumber?: string;
  serialNumber?: string;
  deviceType?: string;
  udn?: string;
};
type Host = { ip: string; mac?: string; names: string[]; seen: string; mdns: MdnsService[]; ssdp: SsdpService[] };

// ---- DNS messages ----

const TYPE = { A: 1, PTR: 12, TXT: 16, SRV: 33, ANY: 255 } as const;
const SERVICES = '_services._dns-sd._udp.local';

type DnsRecord = { name: string; type: number; data: Uint8Array; offset: number; message: Uint8Array };

const encodeName = (name: string): number[] => {
  const bytes: number[] = [];
  for (const label of name.split('.').filter(Boolean)) {
    const encoded = new TextEncoder().encode(label);
    bytes.push(encoded.length, ...encoded);
  }
  return [...bytes, 0];
};

/** A query with one PTR question per name. */
const query = (names: string[]): Uint8Array => {
  const bytes = [0, 0, 0, 0, names.length >> 8, names.length & 0xff, 0, 0, 0, 0, 0, 0];
  for (const name of names) bytes.push(...encodeName(name), 0, TYPE.PTR, 0, 1);
  return new Uint8Array(bytes);
};

/** The name at `offset`, following compression pointers, and where the name ends in place. */
const readName = (message: Uint8Array, offset: number): [string, number] => {
  const labels: string[] = [];
  let end = -1;
  for (let hops = 0; hops < 64; hops++) {
    const length = message[offset];
    if (length === undefined) throw new Error('name runs past the message');
    if (length === 0) return [labels.join('.'), end === -1 ? offset + 1 : end];
    if ((length & 0xc0) === 0xc0) {
      if (end === -1) end = offset + 2;
      offset = ((length & 0x3f) << 8) | message[offset + 1];
      continue;
    }
    labels.push(new TextDecoder().decode(message.subarray(offset + 1, offset + 1 + length)));
    offset += 1 + length;
  }
  throw new Error('name loops');
};

/** Every answer, authority and additional record of a response. */
const parseResponse = (message: Uint8Array): DnsRecord[] => {
  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
  if (message.length < 12 || !(message[2] & 0x80)) return [];
  const questions = view.getUint16(4);
  const records = view.getUint16(6) + view.getUint16(8) + view.getUint16(10);
  let offset = 12;
  for (let i = 0; i < questions; i++) offset = readName(message, offset)[1] + 4;
  const out: DnsRecord[] = [];
  for (let i = 0; i < records && offset < message.length; i++) {
    const [name, end] = readName(message, offset);
    const type = view.getUint16(end);
    const length = view.getUint16(end + 8);
    out.push({ name, type, data: message.subarray(end + 10, end + 10 + length), offset: end + 10, message });
    offset = end + 10 + length;
  }
  return out;
};

const txtOf = (data: Uint8Array): Record<string, string> => {
  const txt: Record<string, string> = {};
  for (let offset = 0; offset < data.length;) {
    const length = data[offset];
    const entry = new TextDecoder().decode(data.subarray(offset + 1, offset + 1 + length));
    offset += 1 + length;
    if (!entry) continue;
    const equals = entry.indexOf('=');
    txt[equals === -1 ? entry : entry.slice(0, equals)] = equals === -1 ? '' : entry.slice(equals + 1);
  }
  return txt;
};

// ---- UDP ----

type Datagram = { data: Uint8Array; ip: string };

/** Sends `payload` to a multicast group from a port of its own and returns what comes back within LISTEN_MS. */
const ask = async (group: string, port: number, payload: Uint8Array): Promise<Datagram[]> => {
  const socket = Deno.listenDatagram({ transport: 'udp', hostname: '0.0.0.0', port: 0 });
  const answers: Datagram[] = [];
  const timer = setTimeout(() => socket.close(), LISTEN_MS);
  try {
    await socket.send(payload, { transport: 'udp', hostname: group, port });
    for await (const [data, from] of socket) answers.push({ data, ip: (from as Deno.NetAddr).hostname });
  } catch (error) {
    if (!(error instanceof Deno.errors.BadResource)) throw error;
  } finally {
    clearTimeout(timer);
    try {
      socket.close();
    } catch { /* closed by the timer */ }
  }
  return answers;
};

// ---- one round ----

type Heard = Map<string, { names: Set<string>; mdns: Map<string, MdnsService>; ssdp: Map<string, SsdpService> }>;

const heardAt = (heard: Heard, ip: string) => {
  let host = heard.get(ip);
  if (!host) heard.set(ip, host = { names: new Set(), mdns: new Map(), ssdp: new Map() });
  return host;
};

/** What answered mDNS, by address: which service types there are, then each type's instances. */
const askMdns = async (heard: Heard): Promise<void> => {
  const types = new Set<string>();
  for (const answer of await ask('224.0.0.251', 5353, query([SERVICES]))) {
    for (const record of parseResponse(answer.data)) {
      if (record.type === TYPE.PTR && record.name === SERVICES) types.add(readName(record.message, record.offset)[0]);
    }
  }
  if (!types.size) return;
  for (const answer of await ask('224.0.0.251', 5353, query([...types]))) {
    const records = parseResponse(answer.data);
    const host = heardAt(heard, answer.ip);
    const instances = new Map<string, MdnsService>();
    for (const record of records) {
      if (record.type !== TYPE.PTR || !types.has(record.name)) continue;
      const full = readName(record.message, record.offset)[0];
      const instance = full.endsWith(`.${record.name}`) ? full.slice(0, -record.name.length - 1) : full;
      instances.set(full, { type: record.name.replace(/\.local$/, ''), instance, txt: {} });
    }
    for (const record of records) {
      const service = instances.get(record.name);
      if (service && record.type === TYPE.SRV) {
        service.port = (record.data[4] << 8) | record.data[5];
        host.names.add(readName(record.message, record.offset + 6)[0]);
      } else if (service && record.type === TYPE.TXT) {
        service.txt = txtOf(record.data);
      } else if (record.type === TYPE.A && record.name.endsWith('.local')) {
        host.names.add(record.name);
      }
    }
    for (const [full, service] of instances) host.mdns.set(full, service);
  }
};

const header = (text: string, name: string): string | undefined => text.match(new RegExp(`^${name}:\\s*(.*?)\\s*$`, 'im'))?.[1];
const element = (xml: string, name: string): string | undefined => {
  const value = xml.match(new RegExp(`<${name}>([^<]*)</${name}>`, 'i'))?.[1]?.trim();
  return value ? value.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'") : undefined;
};

/** What answered SSDP, by address, with what each one's description says of the device. */
const askSsdp = async (heard: Heard): Promise<void> => {
  const search = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n';
  const described = new Map<string, Promise<string | undefined>>();
  const describe = (location: string) => {
    if (!described.has(location)) {
      described.set(
        location,
        fetch(location, { signal: AbortSignal.timeout(LISTEN_MS) })
          .then((response) => response.ok ? response.text() : undefined)
          .catch(() => undefined),
      );
    }
    return described.get(location)!;
  };
  const answers = await ask('239.255.255.250', 1900, new TextEncoder().encode(search));
  await Promise.all(answers.map(async (answer) => {
    const text = new TextDecoder().decode(answer.data);
    const st = header(text, 'ST');
    if (!st) return;
    const usn = header(text, 'USN');
    const location = header(text, 'LOCATION');
    const service: SsdpService = { st, usn, server: header(text, 'SERVER'), location };
    // Only the root device's answer is worth its description; the rest name its services.
    if (location && (st === 'upnp:rootdevice' || !usn?.includes('::'))) {
      const xml = await describe(location);
      if (xml) {
        for (const name of ['friendlyName', 'manufacturer', 'modelName', 'modelNumber', 'serialNumber', 'deviceType'] as const) {
          service[name] = element(xml, name);
        }
        service.udn = element(xml, 'UDN');
      }
    }
    heardAt(heard, answer.ip).ssdp.set(`${st} ${usn ?? ''}`, service);
  }));
};

/** The host's ARP table: hardware address by IP, for the addresses it has talked to. */
const arpTable = async (): Promise<Map<string, string>> => {
  const table = new Map<string, string>();
  // Read through cat: Deno grants a file under /proc only to --allow-all. The image's
  // LD_LIBRARY_PATH would need --allow-run of everything, so cat gets no environment.
  let text = '';
  try {
    const output = await new Deno.Command('cat', { args: ['/proc/net/arp'], stderr: 'null', clearEnv: true }).output();
    text = new TextDecoder().decode(output.stdout);
  } catch (error) {
    log(`reading the ARP table: ${message(error)}`);
  }
  for (const line of text.split('\n').slice(1)) {
    const [ip, , flags, mac] = line.trim().split(/\s+/);
    if (ip && mac && flags !== '0x0' && mac !== '00:00:00:00:00:00') table.set(ip, mac.toLowerCase());
  }
  return table;
};

const round = async (): Promise<Host[]> => {
  const heard: Heard = new Map();
  const results = await Promise.allSettled([askMdns(heard), askSsdp(heard)]);
  for (const result of results) if (result.status === 'rejected') log(`asking: ${message(result.reason)}`);
  const arp = await arpTable();
  const seen = new Date().toISOString();
  return [...heard].filter(([, host]) => host.mdns.size || host.ssdp.size).map(([ip, host]) => ({
    ip,
    ...(arp.get(ip) ? { mac: arp.get(ip) } : {}),
    names: [...host.names].sort(),
    seen,
    mdns: [...host.mdns.values()],
    ssdp: [...host.ssdp.values()],
  }));
};

const ipv4 = (ip: string): number => ip.split('.').reduce((value, part) => value * 256 + Number(part), 0);

/** This machine's address on the network most of `ips` are on, if it has one. */
const ownAddress = (ips: string[]): string | undefined => {
  let best: { address: string; count: number } | undefined;
  for (const each of Deno.networkInterfaces()) {
    if (each.family !== 'IPv4' || each.address.startsWith('127.')) continue;
    const mask = ipv4(each.netmask);
    const network = ipv4(each.address) & mask;
    const count = ips.filter((ip) => (ipv4(ip) & mask) === network).length;
    if (count > (best?.count ?? 0)) best = { address: each.address, count };
  }
  return best?.address;
};

// ---- MQTT 3.1.1 ----

const utf8 = (text: string): number[] => {
  const bytes = new TextEncoder().encode(text);
  return [bytes.length >> 8, bytes.length & 0xff, ...bytes];
};

const packet = (type: number, body: number[]): Uint8Array => {
  const length: number[] = [];
  let remaining = body.length;
  do {
    let byte = remaining % 128;
    remaining = Math.floor(remaining / 128);
    if (remaining > 0) byte |= 0x80;
    length.push(byte);
  } while (remaining > 0);
  return new Uint8Array([type, ...length, ...body]);
};

const STATUS = `${PREFIX}/status`;

/** One connection: publishes each message, retained at QoS 0, and disconnects. */
const publishAll = async (messages: { topic: string; payload: string }[]): Promise<void> => {
  const connection = await Deno.connect({ hostname: MQTT_HOST, port: MQTT_PORT });
  try {
    const flags = 0x02 | (MQTT_USER ? 0x80 : 0) | (MQTT_USER && MQTT_PASSWORD ? 0x40 : 0);
    const body = [...utf8('MQTT'), 4, flags, 0, 60, ...utf8(`ein-discovery-${crypto.randomUUID().slice(0, 8)}`)];
    if (MQTT_USER) body.push(...utf8(MQTT_USER));
    if (MQTT_USER && MQTT_PASSWORD) body.push(...utf8(MQTT_PASSWORD));
    await connection.write(packet(0x10, body));
    const ack = new Uint8Array(4);
    let read = 0;
    while (read < 4) {
      const n = await connection.read(ack.subarray(read));
      if (n === null) throw new Error('the broker closed the connection before answering');
      read += n;
    }
    if (ack[0] !== 0x20) throw new Error('the broker did not answer as MQTT');
    if (ack[3] !== 0) throw new Error(ack[3] === 4 || ack[3] === 5 ? `the broker refused ${MQTT_USER}'s password` : `the broker refused the connection (${ack[3]})`);
    for (const { topic, payload } of messages) {
      await connection.write(packet(0x31, [...utf8(topic), ...new TextEncoder().encode(payload)]));
    }
    await connection.write(new Uint8Array([0xe0, 0]));
  } finally {
    connection.close();
  }
};

// ---- the service ----

const idOf = (host: Host): string => host.mac ? host.mac.replace(/:/g, '') : host.ip;

/** When each id was last heard, so one unheard for FORGET_MS is cleared. */
const lastHeard = new Map<string, number>();

const run = async () => {
  log(`publishing to ${MQTT_HOST}:${MQTT_PORT} under ${PREFIX}, every ${INTERVAL_MS / 1000} s`);
  for (;;) {
    const started = Date.now();
    try {
      const hosts = await round();
      const messages = hosts.map((host) => ({ topic: `${PREFIX}/host/${idOf(host)}`, payload: JSON.stringify(host) }));
      for (const host of hosts) lastHeard.set(idOf(host), started);
      for (const [id, at] of lastHeard) {
        if (started - at < FORGET_MS) continue;
        messages.push({ topic: `${PREFIX}/host/${id}`, payload: '' });
        lastHeard.delete(id);
      }
      const address = BIND !== '0.0.0.0' && BIND !== '127.0.0.1' ? BIND : ownAddress(hosts.map((host) => host.ip));
      const status = { round: new Date(started).toISOString(), hosts: hosts.length, ...(address ? { broker: `${address}:${MQTT_PORT}` } : {}) };
      messages.push({ topic: STATUS, payload: JSON.stringify(status) });
      await publishAll(messages);
    } catch (error) {
      log(message(error));
    }
    await new Promise((resolve) => setTimeout(resolve, Math.max(1000, INTERVAL_MS - (Date.now() - started))));
  }
};

if (import.meta.main) {
  if (Deno.args[0] === '--once') console.log(JSON.stringify(await round(), null, 2));
  else await run();
}
