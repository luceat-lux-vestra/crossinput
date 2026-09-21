"use strict";

const MANAGED_TYPES = new Set(["type/bug", "type/feature", "type/task", "type/epic"]);

function expectedType(title) {
  const value = String(title || "").trim().toLowerCase();
  if (/^(fix|bug)(\([^)]*\))?:|^\[bug\]/.test(value)) return "type/bug";
  if (/^(feat|feature)(\([^)]*\))?:|^\[feature\]/.test(value)) return "type/feature";
  if (/^epic(\([^)]*\))?:/.test(value)) return "type/epic";
  if (/^(task|test|build|ci|chore|refactor|release|hardening)(\([^)]*\))?:/.test(value)) return "type/task";
  return null;
}

function titleAreas(title) {
  const value = String(title || "").trim().toLowerCase();
  const areas = new Set();
  if (/\(macos\)|\bmacos\b/.test(value)) areas.add("area/macos-app");
  if (/\(android\)|\bandroid\b/.test(value)) areas.add("area/android-helper");
  if (/\(protocol\)|\bprotocol\b/.test(value)) areas.add("area/protocol");
  if (/\(ci\)|^ci:|^hardening[(:]|github|workflow|dependabot|ruleset/.test(value)) areas.add("area/ci");
  if (/\brelease\b/.test(value)) areas.add("area/release");
  if (/^docs[:(]|documentation/.test(value)) areas.add("area/docs");
  return [...areas].sort();
}

function reconcileIssue(issue) {
  const labels = (issue.labels || [])
    .map((label) => typeof label === "string" ? label : label?.name)
    .filter(Boolean);
  const existingTypes = labels.filter((label) => MANAGED_TYPES.has(label));
  const expected = expectedType(issue.title);
  const add = [];
  const remove = [];
  const diagnostics = [];

  for (const area of titleAreas(issue.title)) {
    if (!labels.includes(area)) add.push(area);
  }

  if (expected) {
    if (!labels.includes(expected)) add.push(expected);
    for (const label of existingTypes) if (label !== expected) remove.push(label);
  } else if (existingTypes.length === 0) {
    diagnostics.push("unclassified-title");
  } else if (existingTypes.length > 1) {
    diagnostics.push("ambiguous-managed-type");
  }

  if (!labels.some((label) => label.startsWith("priority/"))) add.push("priority/medium");

  return {
    expectedType: expected,
    add: [...new Set(add)].sort(),
    remove: [...new Set(remove)].sort(),
    diagnostics
  };
}

module.exports = { MANAGED_TYPES, expectedType, titleAreas, reconcileIssue };
