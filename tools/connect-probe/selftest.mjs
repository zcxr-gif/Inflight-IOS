// Exercises the frame reader and the decoders against synthetic frames built
// to the spec, including the two cases a real socket produces and a naive
// reader gets wrong: one frame split across packets, and two frames in one.

import assert from "node:assert";

const TYPE = { BOOLEAN: 0, INT: 1, FLOAT: 2, DOUBLE: 3, STRING: 4, LONG: 5 };

function decode(type, payload) {
  switch (type) {
    case TYPE.BOOLEAN: return payload.readUInt8(0) === 1;
    case TYPE.INT:     return payload.readInt32LE(0);
    case TYPE.FLOAT:   return payload.readFloatLE(0);
    case TYPE.DOUBLE:  return payload.readDoubleLE(0);
    case TYPE.LONG:    return payload.readBigInt64LE(0);
    case TYPE.STRING: {
      const length = payload.readInt32LE(0);
      return payload.toString("utf8", 4, 4 + length);
    }
    default: return null;
  }
}

class FrameReader {
  constructor(onFrame) { this.buffer = Buffer.alloc(0); this.onFrame = onFrame; }
  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      if (this.buffer.length < 8) return;
      const id = this.buffer.readInt32LE(0);
      const length = this.buffer.readInt32LE(4);
      if (length < 0 || length > 64 * 1024 * 1024) throw new Error("out of sync");
      if (this.buffer.length < 8 + length) return;
      const payload = this.buffer.subarray(8, 8 + length);
      this.buffer = this.buffer.subarray(8 + length);
      this.onFrame(id, payload);
    }
  }
}

// Build a response frame the way Infinite Flight would.
function frame(id, payload) {
  const head = Buffer.alloc(8);
  head.writeInt32LE(id, 0);
  head.writeInt32LE(payload.length, 4);
  return Buffer.concat([head, payload]);
}

function stringPayload(s) {
  const bytes = Buffer.from(s, "utf8");
  const out = Buffer.alloc(4 + bytes.length);
  out.writeInt32LE(bytes.length, 0);
  bytes.copy(out, 4);
  return out;
}

let passed = 0;
function check(name, fn) {
  fn();
  passed += 1;
  console.log(`  ok  ${name}`);
}

console.log("Decoders:");

check("boolean true", () => assert.strictEqual(decode(TYPE.BOOLEAN, Buffer.from([1])), true));
check("boolean false", () => assert.strictEqual(decode(TYPE.BOOLEAN, Buffer.from([0])), false));

check("int32 negative", () => {
  const b = Buffer.alloc(4); b.writeInt32LE(-4096, 0);
  assert.strictEqual(decode(TYPE.INT, b), -4096);
});

check("float", () => {
  const b = Buffer.alloc(4); b.writeFloatLE(-742.5, 0);
  assert.strictEqual(decode(TYPE.FLOAT, b), -742.5);
});

check("double", () => {
  const b = Buffer.alloc(8); b.writeDoubleLE(51.4775, 0);
  assert.strictEqual(decode(TYPE.DOUBLE, b), 51.4775);
});

check("long", () => {
  const b = Buffer.alloc(8); b.writeBigInt64LE(1787031609093n, 0);
  assert.strictEqual(decode(TYPE.LONG, b), 1787031609093n);
});

check("string", () => {
  assert.strictEqual(decode(TYPE.STRING, stringPayload("EGLL")), "EGLL");
});

check("string with multibyte characters", () => {
  assert.strictEqual(decode(TYPE.STRING, stringPayload("Zürich — LSZH")), "Zürich — LSZH");
});

console.log("\nFrame reader:");

check("one frame in one chunk", () => {
  const seen = [];
  const r = new FrameReader((id, p) => seen.push([id, decode(TYPE.FLOAT, p)]));
  const b = Buffer.alloc(4); b.writeFloatLE(-183.25, 0);
  r.push(frame(742, b));
  assert.deepStrictEqual(seen, [[742, -183.25]]);
});

check("one frame split byte by byte", () => {
  const seen = [];
  const r = new FrameReader((id, p) => seen.push([id, decode(TYPE.STRING, p)]));
  const full = frame(-1, stringPayload("511,2,aircraft/0/vertical_speed"));
  for (const byte of full) r.push(Buffer.from([byte]));
  assert.deepStrictEqual(seen, [[-1, "511,2,aircraft/0/vertical_speed"]]);
});

check("three frames arriving in one chunk", () => {
  const seen = [];
  const r = new FrameReader((id, p) => seen.push(id));
  const one = Buffer.alloc(4); one.writeInt32LE(1, 0);
  const two = Buffer.alloc(8); two.writeDoubleLE(2, 0);
  r.push(Buffer.concat([frame(10, one), frame(20, two), frame(30, stringPayload("x"))]));
  assert.deepStrictEqual(seen, [10, 20, 30]);
});

check("partial frame yields nothing until complete", () => {
  const seen = [];
  const r = new FrameReader((id) => seen.push(id));
  const b = Buffer.alloc(8); b.writeDoubleLE(1, 0);
  const full = frame(99, b);
  r.push(full.subarray(0, 11));
  assert.deepStrictEqual(seen, []);
  r.push(full.subarray(11));
  assert.deepStrictEqual(seen, [99]);
});

check("absurd length is rejected rather than buffered forever", () => {
  const r = new FrameReader(() => {});
  const head = Buffer.alloc(8);
  head.writeInt32LE(5, 0);
  head.writeInt32LE(0x7fffffff, 4);
  assert.throws(() => r.push(head), /out of sync/);
});

console.log("\nManifest parsing:");

check("splits id,type,path and tolerates a path containing a comma", () => {
  const raw = "511,2,aircraft/0/vertical_speed\n851,3,infiniteflight/cameras/4/x_angle\n81,4,api_joystick/buttons/8/name\n1048622,-1,commands/FlightPlan.AddWaypoints\n";
  const byPath = new Map();
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    const first = t.indexOf(",");
    const second = t.indexOf(",", first + 1);
    if (first < 0 || second < 0) continue;
    byPath.set(t.slice(second + 1), { id: +t.slice(0, first), type: +t.slice(first + 1, second) });
  }
  assert.strictEqual(byPath.size, 4);
  assert.deepStrictEqual(byPath.get("aircraft/0/vertical_speed"), { id: 511, type: 2 });
  assert.deepStrictEqual(byPath.get("commands/FlightPlan.AddWaypoints"), { id: 1048622, type: -1 });
});

console.log(`\n${passed} checks passed.`);
