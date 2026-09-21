"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { expectedType, titleAreas, reconcileIssue } = require("./issue-metadata.cjs");

test("type automation requires explicit title protocol", () => {
  assert.equal(expectedType("bug(macos): premature handoff"), "type/bug");
  assert.equal(expectedType("feat(protocol): acknowledge delivery"), "type/feature");
  assert.equal(expectedType("epic(leap): rebuild ownership"), "type/epic");
  assert.equal(expectedType("hardening(codeql): remove nightly bundle"), "type/task");
  assert.equal(expectedType("research(macos): investigate cursor ownership"), null);
  assert.equal(expectedType("Pointer-trap safety umbrella"), null);
});

test("area automation is title-only", () => {
  assert.deepEqual(titleAreas("fix(macos): handoff"), ["area/macos-app"]);
  assert.deepEqual(titleAreas("feat(android): helper"), ["area/android-helper"]);
  assert.deepEqual(titleAreas("hardening(codeql): workflow policy"), ["area/ci"]);
  assert.deepEqual(titleAreas("task: generic maintenance"), []);
});

test("explicit type repairs only managed type conflict and preserves manual areas", () => {
  assert.deepEqual(reconcileIssue({
    title: "bug(macos): handoff",
    labels: ["type/task", "area/protocol", "priority/high"]
  }), {
    expectedType: "type/bug",
    add: ["area/macos-app", "type/bug"],
    remove: ["type/task"],
    diagnostics: []
  });
});

test("unknown title never guesses a type from body or absence", () => {
  assert.deepEqual(reconcileIssue({
    title: "Pointer-trap safety umbrella",
    body: "apps/macos github actions android/helper",
    labels: []
  }), {
    expectedType: null,
    add: ["priority/medium"],
    remove: [],
    diagnostics: ["unclassified-title"]
  });
});

test("unknown title preserves maintainer type and reports ambiguity", () => {
  assert.deepEqual(reconcileIssue({
    title: "Research cursor boundary",
    labels: ["type/task", "type/feature", "area/macos-app", "priority/medium"]
  }), {
    expectedType: null,
    add: [],
    remove: [],
    diagnostics: ["ambiguous-managed-type"]
  });
});
