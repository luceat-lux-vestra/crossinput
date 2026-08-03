#!/usr/bin/env node
// Check protocol fixtures (.bin frames) match their golden .json expectations (CI).
// The .bin files are the wire truth; the .json files are the human-readable spec
// of each fixture. Decoding mirrors protocol/protocol.md.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const fixturesDir = new URL("../fixtures/", import.meta.url).pathname;
const T = {
  0x0001: "HELLO", 0x0002: "LIST_DISPLAYS", 0x0003: "SELECT_DISPLAY",
  0x0004: "CREATE_HID_DEVICE", 0x0005: "DESTROY_HID_DEVICE", 0x0006: "HID_REPORT",
  0x0007: "PING", 0x0008: "SHUTDOWN",
  0x8001: "HELLO_ACK", 0x8002: "DISPLAY_LIST", 0x8003: "DISPLAY_CHANGED",
  0x8004: "HID_CREATED", 0x8005: "HID_ERROR", 0x8006: "PONG",
  0x8007: "LOG_EVENT", 0x8008: "FATAL_ERROR",
};
const codes = Object.fromEntries(Object.entries(T).map(([v, k]) => [k, Number(v)]));

function fail(msg) {
  console.error(`check-fixtures: ${msg}`);
  process.exit(1);
}

function u16(buf, off) { return buf.readUInt16LE(off); }
function u32(buf, off) { return buf.readUInt32LE(off); }
function utf8(buf, off, len) { return buf.subarray(off, off + len).toString("utf8"); }

function decodeFrame(bin) {
  if (bin.length < 15) fail(`frame too short: ${bin.length} bytes`);
  const magic = bin.subarray(0, 3).toString("latin1");
  if (magic !== "CXI") fail(`bad magic: ${JSON.stringify(magic)}`);
  const version = u16(bin, 3);
  if (version !== 1) fail(`bad version: ${version}`);
  const typeCode = u16(bin, 5);
  const requestId = u32(bin, 7);
  const payloadLen = u32(bin, 11);
  if (bin.length !== 15 + payloadLen) fail(`payload length mismatch: ${bin.length - 15} != ${payloadLen}`);
  const payload = bin.subarray(15);
  return { type: T[typeCode] ?? `0x${typeCode.toString(16)}`, requestId, payload, typeCode };
}

function lengthPrefixed(buf, off) {
  const len = u32(buf, off);
  return buf.subarray(off + 4, off + 4 + len);
}

function decodeDisplay(buf, off) {
  const d = {
    displayId: u32(buf, off),
    type: buf[off + 4],
    flags: u32(buf, off + 5),
    state: buf[off + 9],
    width: u32(buf, off + 10),
    height: u32(buf, off + 14),
    densityDpi: u32(buf, off + 18),
    rotation: buf[off + 22],
  };
  let p = off + 23;
  const nameLen = u32(buf, p);
  d.name = utf8(buf, p + 4, nameLen);
  p += 4 + nameLen;
  const uniqueLen = u32(buf, p);
  d.uniqueId = utf8(buf, p + 4, uniqueLen);
  p += 4 + uniqueLen;
  d.layerStack = u32(buf, p);
  return { display: d, next: p + 4 };
}

function decodePayload(type, payload) {
  switch (type) {
    case "HELLO":
    case "HELLO_ACK":
      return { version: u16(payload, 0) };
    case "LIST_DISPLAYS":
    case "PING":
    case "PONG":
    case "SHUTDOWN":
      return {};
    case "DISPLAY_LIST": {
      const count = u32(payload, 0);
      const displays = [];
      let p = 4;
      for (let i = 0; i < count; i++) {
        const { display, next } = decodeDisplay(payload, p);
        displays.push(display);
        p = next;
      }
      return { displays };
    }
    case "SELECT_DISPLAY":
      return { displayId: u32(payload, 0) };
    case "CREATE_HID_DEVICE":
      return { descriptorBase64: lengthPrefixed(payload, 0).toString("base64") };
    case "DESTROY_HID_DEVICE":
    case "HID_CREATED":
      return { deviceId: u32(payload, 0) };
    case "HID_REPORT": {
      const deviceId = u32(payload, 0);
      const report = lengthPrefixed(payload, 4);
      return { deviceId, reportBase64: report.toString("base64") };
    }
    case "DISPLAY_CHANGED": {
      const { display } = decodeDisplay(payload, 0);
      return { display };
    }
    case "HID_ERROR": {
      const deviceId = u32(payload, 0);
      const code = u32(payload, 4);
      const message = lengthPrefixed(payload, 8).toString("utf8");
      return { deviceId, code, message };
    }
    case "LOG_EVENT": {
      const level = payload[0];
      const tag = lengthPrefixed(payload, 1).toString("utf8");
      let p = 1 + 4 + Buffer.from(tag, "utf8").length;
      const message = lengthPrefixed(payload, p).toString("utf8");
      return { level, tag, message };
    }
    case "FATAL_ERROR": {
      const code = u32(payload, 0);
      const message = lengthPrefixed(payload, 4).toString("utf8");
      return { code, message };
    }
    default:
      fail(`no decoder for type ${type}`);
  }
}

function check(name, gold, decoded) {
  for (const key of Object.keys(gold)) {
    if (key === "type" || key === "requestId") continue; // verified separately
    const expected = JSON.stringify(gold[key]);
    const actual = JSON.stringify(decoded[key]);
    if (expected !== actual) {
      fail(`${name}: field "${key}" mismatch: expected ${expected}, got ${actual}`);
    }
  }
}

const files = readdirSync(fixturesDir).filter((f) => !f.startsWith("."));
if (files.length === 0) {
  console.log("check-fixtures: no fixtures yet");
  process.exit(0);
}

let checked = 0;
for (const f of files) {
  if (!f.endsWith(".bin")) continue;
  const jsonFile = f.replace(/\.bin$/, ".json");
  if (!files.includes(jsonFile)) fail(`missing golden file: ${jsonFile}`);
  const bin = readFileSync(join(fixturesDir, f));
  const gold = JSON.parse(readFileSync(join(fixturesDir, jsonFile), "utf8"));
  const frame = decodeFrame(bin);
  if (frame.type !== gold.type) fail(`${f}: type mismatch: ${frame.type} != ${gold.type}`);
  if (frame.requestId !== gold.requestId) fail(`${f}: requestId mismatch`);
  const decoded = decodePayload(frame.type, frame.payload);
  check(f, gold, decoded);
  checked++;
}
console.log(`check-fixtures: ${checked} fixtures verified`);
