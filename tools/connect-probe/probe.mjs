#!/usr/bin/env node
//
// A throwaway client for the Infinite Flight Connect API v2, used to find out
// what a real device actually publishes before any of it is written in Swift.
//
// It does four things, in order:
//
//   1. finds Infinite Flight on the network, or takes the address you give it
//   2. pulls the manifest and writes it to disk
//   3. reads the states the tracker cares about and prints what came back
//   4. watches the landing statistics until you stop it
//
// Nothing here is meant to ship. The Swift client resolves the same paths
// through the same manifest; this exists so the paths in it are known to be
// right rather than assumed.
//
// Usage:
//
//   node probe.mjs                      discover on the LAN
//   node probe.mjs 192.168.1.42         connect directly
//   node probe.mjs 192.168.1.42 --watch stay attached and print each landing
//
// Requires Infinite Flight with Settings -> General -> Enable Infinite Flight
// Connect switched on, and this machine on the same Wi-Fi.

import net from "node:net";
import dgram from "node:dgram";
import { writeFileSync } from "node:fs";

const BROADCAST_PORT = 15000;
const CONNECT_PORT = 10112;
const MANIFEST_ID = -1;

const TYPE = { BOOLEAN: 0, INT: 1, FLOAT: 2, DOUBLE: 3, STRING: 4, LONG: 5, COMMAND: -1 };
const TYPE_NAME = { 0: "bool", 1: "int", 2: "float", 3: "double", 4: "string", 5: "long", "-1": "command" };

// The states the tracker wants, grouped by what they would be used for. Paths
// are guesses until this script says otherwise -- anything that does not
// resolve is reported rather than skipped, which is the entire point.
const WANTED = {
  "Session identity (the join to the live feed)": [
    "infiniteflight/live/current_flight/id",
    "infiniteflight/live/current_server/id",
    "infiniteflight/live/current_server/name",
    "infiniteflight/current_user",
    "infiniteflight/app_state",
    "infiniteflight/app_version",
    "infiniteflight/api_version",
  ],
  "Position and attitude": [
    "aircraft/0/latitude",
    "aircraft/0/longitude",
    "aircraft/0/altitude_msl",
    "aircraft/0/altitude_agl",
    "aircraft/0/heading_magnetic",
    "aircraft/0/heading_true",
    "aircraft/0/pitch",
    "aircraft/0/bank",
    "aircraft/0/groundspeed",
    "aircraft/0/indicated_airspeed",
    "aircraft/0/true_airspeed",
    "aircraft/0/vertical_speed",
    "aircraft/0/turn_rate",
  ],
  "Configuration": [
    "aircraft/0/systems/landing_gear/state",
    "aircraft/0/systems/flaps/state",
    "aircraft/0/systems/spoilers/state",
    "aircraft/0/systems/parking_brake/state",
    "aircraft/0/systems/fuel/fuel_remaining",
    "aircraft/0/systems/engines/engine_count",
    "aircraft/0/is_on_ground",
    "aircraft/0/onground",
  ],
  "Where we are": [
    "infiniteflight/nearest_airport",
    "infiniteflight/nearest_airports",
    "aircraft/0/systems/nav_sources/gps/next_waypoint_name",
  ],
  "Landing statistics (the reason we are here)": [
    "simulator/statistics/last_landing/vertical_speed",
    "simulator/statistics/last_landing/score",
    "simulator/statistics/last_landing/max_g_force",
    "simulator/statistics/last_landing/distance_from_centerline",
    "simulator/statistics/last_landing/distance_from_1kft_marker",
    "simulator/statistics/last_landing/ground_speed",
    "simulator/statistics/last_landing/indicated_airspeed",
    "simulator/statistics/last_landing/location/latitude",
    "simulator/statistics/last_landing/location/longitude",
    "simulator/statistics/last_landing/flight_time",
  ],
  "Time": [
    "simulator/flight_time",
    "simulator/time_utc",
    "simulator/real_time_utc",
  ],
};

// The landing states re-read on a loop in --watch mode.
const LANDING_GROUP = WANTED["Landing statistics (the reason we are here)"];

// MARK: - Wire format
//
// Little-endian throughout. A request is the state id, then one byte saying
// whether this is a write. A response is the id, the length of what follows,
// and then that many bytes.

function encodeGet(id) {
  const buffer = Buffer.alloc(5);
  buffer.writeInt32LE(id, 0);
  buffer.writeInt8(0, 4);
  return buffer;
}

/// Decodes one value out of a response payload, given the type the manifest
/// declared for it. `payload` starts after the id and length fields.
function decode(type, payload) {
  switch (type) {
    case TYPE.BOOLEAN: return payload.readUInt8(0) === 1;
    case TYPE.INT:     return payload.readInt32LE(0);
    case TYPE.FLOAT:   return payload.readFloatLE(0);
    case TYPE.DOUBLE:  return payload.readDoubleLE(0);
    case TYPE.LONG:    return payload.readBigInt64LE(0);
    case TYPE.STRING: {
      // Strings carry their own length again, inside the payload.
      const length = payload.readInt32LE(0);
      return payload.toString("utf8", 4, 4 + length);
    }
    default: return null;
  }
}

/// Pulls whole frames out of a stream that arrives in arbitrary chunks.
///
/// TCP does not preserve message boundaries, so a reply can be split across
/// packets and two replies can share one. Everything accumulates here and a
/// frame is only emitted once all of its declared bytes have arrived.
class FrameReader {
  constructor(onFrame) {
    this.buffer = Buffer.alloc(0);
    this.onFrame = onFrame;
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);

    for (;;) {
      if (this.buffer.length < 8) return;
      const id = this.buffer.readInt32LE(0);
      const length = this.buffer.readInt32LE(4);
      if (length < 0 || length > 64 * 1024 * 1024) {
        throw new Error(`Refusing a frame claiming ${length} bytes -- stream out of sync.`);
      }
      if (this.buffer.length < 8 + length) return;

      const payload = this.buffer.subarray(8, 8 + length);
      this.buffer = this.buffer.subarray(8 + length);
      this.onFrame(id, payload);
    }
  }
}

// MARK: - Discovery

function discover(timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket({ type: "udp4", reuseAddr: true });
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error(
        `No broadcast on UDP ${BROADCAST_PORT} after ${timeoutMs / 1000}s. ` +
        `Check Connect is enabled in Infinite Flight and that this machine is ` +
        `on the same Wi-Fi, or pass the device's IP directly.`
      ));
    }, timeoutMs);

    socket.on("message", (message) => {
      let payload;
      try {
        payload = JSON.parse(message.toString());
      } catch {
        return; // Something else is talking on this port.
      }

      const addresses = payload.Addresses ?? [];
      const ipv4 = addresses.find((a) => /^\d+\.\d+\.\d+\.\d+$/.test(a));
      if (!ipv4) return;

      clearTimeout(timer);
      socket.close();
      console.log(`Found ${payload.DeviceName ?? payload.DeviceID ?? "a device"} at ${ipv4}`);
      console.log(`  state ${payload.State ?? "?"}, app ${payload.AppVersion ?? "?"}`);
      console.log(`  broadcast payload: ${JSON.stringify(payload)}\n`);
      resolve(ipv4);
    });

    socket.on("error", (error) => { clearTimeout(timer); socket.close(); reject(error); });
    socket.bind(BROADCAST_PORT, () => {
      console.log(`Listening for Infinite Flight on UDP ${BROADCAST_PORT}...`);
    });
  });
}

// MARK: - A session

class Probe {
  constructor(host) {
    this.host = host;
    this.socket = null;
    this.byId = new Map();     // id -> { type, path }
    this.byPath = new Map();   // path -> { id, type }
    this.pending = [];         // FIFO of resolvers, one per outstanding request
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.socket = net.createConnection({ host: this.host, port: CONNECT_PORT }, () => {
        console.log(`Connected to ${this.host}:${CONNECT_PORT}\n`);
        resolve();
      });

      const reader = new FrameReader((id, payload) => this.handle(id, payload));
      this.socket.on("data", (chunk) => {
        try { reader.push(chunk); } catch (error) { console.error(error.message); this.close(); }
      });
      this.socket.on("error", reject);
      this.socket.on("close", () => console.log("\nConnection closed."));
    });
  }

  handle(id, payload) {
    const waiter = this.pending.shift();
    if (!waiter) return;

    if (id === MANIFEST_ID) {
      const length = payload.readInt32LE(0);
      waiter.resolve(payload.toString("utf8", 4, 4 + length));
      return;
    }

    const entry = this.byId.get(id);
    if (!entry) { waiter.resolve(null); return; }

    try {
      waiter.resolve(decode(entry.type, payload));
    } catch (error) {
      waiter.resolve(`<undecodable: ${error.message}>`);
    }
  }

  /// Sends one request and waits for its reply.
  ///
  /// Strictly sequential: Infinite Flight answers in the order it was asked,
  /// and the reply carries no correlation id beyond the state id -- which is
  /// not unique across two outstanding reads of the same state. One in flight
  /// at a time is the only way to be certain which answer belongs to which
  /// question.
  request(id, timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.pending.findIndex((p) => p.timer === timer);
        if (index >= 0) this.pending.splice(index, 1);
        reject(new Error(`Timed out waiting for state ${id}`));
      }, timeoutMs);

      this.pending.push({
        timer,
        resolve: (value) => { clearTimeout(timer); resolve(value); },
      });

      this.socket.write(encodeGet(id));
    });
  }

  async loadManifest() {
    // The manifest is big and arrives over many packets; give it longer.
    const raw = await this.request(MANIFEST_ID, 20000);

    for (const line of raw.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      // `id,type,path` -- the path may itself contain commas in principle, so
      // only the first two separators are treated as structure.
      const first = trimmed.indexOf(",");
      const second = trimmed.indexOf(",", first + 1);
      if (first < 0 || second < 0) continue;

      const id = Number.parseInt(trimmed.slice(0, first), 10);
      const type = Number.parseInt(trimmed.slice(first + 1, second), 10);
      const path = trimmed.slice(second + 1);
      if (Number.isNaN(id) || Number.isNaN(type)) continue;

      this.byId.set(id, { type, path });
      this.byPath.set(path, { id, type });
    }

    return raw;
  }

  async read(path) {
    const entry = this.byPath.get(path);
    if (!entry) return { missing: true };
    if (entry.type === TYPE.COMMAND) return { command: true, id: entry.id };

    try {
      const value = await this.request(entry.id);
      return { value, type: entry.type, id: entry.id };
    } catch (error) {
      return { error: error.message, id: entry.id };
    }
  }

  close() { this.socket?.destroy(); }
}

// MARK: - Reporting

function format(result) {
  if (result.missing) return "\x1b[31mNOT IN MANIFEST\x1b[0m";
  if (result.error) return `\x1b[31m${result.error}\x1b[0m`;
  if (result.command) return `command #${result.id}`;

  const value = typeof result.value === "number"
    ? Number(result.value.toFixed(4))
    : result.value;
  return `\x1b[32m${value}\x1b[0m  \x1b[90m(${TYPE_NAME[result.type]}, #${result.id})\x1b[0m`;
}

async function main() {
  const args = process.argv.slice(2);
  const watch = args.includes("--watch");
  const address = args.find((a) => /^\d+\.\d+\.\d+\.\d+$/.test(a));

  const host = address ?? await discover();

  const probe = new Probe(host);
  await probe.connect();

  console.log("Fetching the manifest...");
  const raw = await probe.loadManifest();

  const file = new URL("./manifest.txt", import.meta.url).pathname;
  writeFileSync(file, raw);
  console.log(`Manifest: ${probe.byPath.size} states, written to ${file}\n`);

  // What is actually in there, by namespace -- the shape of the API for this
  // aircraft, which differs between aircraft.
  const namespaces = new Map();
  for (const path of probe.byPath.keys()) {
    const head = path.split("/")[0];
    namespaces.set(head, (namespaces.get(head) ?? 0) + 1);
  }
  console.log("Namespaces:");
  for (const [name, count] of [...namespaces].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(count).padStart(5)}  ${name}/`);
  }
  console.log();

  // Now the states the tracker wants. Anything printed in red needs its path
  // corrected before the Swift client can rely on it.
  let missing = 0;
  for (const [group, paths] of Object.entries(WANTED)) {
    console.log(`\x1b[1m${group}\x1b[0m`);
    for (const path of paths) {
      const result = await probe.read(path);
      if (result.missing) missing += 1;
      console.log(`  ${path.padEnd(58)} ${format(result)}`);
    }
    console.log();
  }

  if (missing > 0) {
    console.log(
      `\x1b[33m${missing} path(s) are not in this manifest.\x1b[0m ` +
      `Search manifest.txt for the real spelling, e.g.:\n` +
      `  grep -iE 'altitude|latitude|groundspeed' manifest.txt\n`
    );
  }

  if (!watch) {
    probe.close();
    return;
  }

  // Landing watch. Fly a circuit; every time the values change, a touchdown
  // has been scored and this is what the logbook would have recorded.
  console.log("\x1b[1mWatching for landings. Fly a circuit; Ctrl-C to stop.\x1b[0m\n");

  let previous = null;
  for (;;) {
    const snapshot = {};
    for (const path of LANDING_GROUP) {
      const result = await probe.read(path);
      snapshot[path.split("/").pop()] = result.value ?? null;
    }

    const serialised = JSON.stringify(snapshot);
    if (previous !== null && serialised !== previous) {
      console.log(`\x1b[32m[${new Date().toLocaleTimeString()}] Landing recorded\x1b[0m`);
      for (const [key, value] of Object.entries(snapshot)) {
        const shown = typeof value === "number" ? Number(value.toFixed(2)) : value;
        console.log(`  ${key.padEnd(30)} ${shown}`);
      }
      console.log();
    }
    previous = serialised;

    await new Promise((r) => setTimeout(r, 2000));
  }
}

main().catch((error) => {
  console.error(`\x1b[31m${error.message}\x1b[0m`);
  process.exit(1);
});
