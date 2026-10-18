#!/usr/bin/env node
// Primary-session shell policy for protected-upstream repository writes.
// Shell lexing and command-position recursion come from
// fm-arm-command-policy.mjs. The repository-operation classifier remains solely
// in fm-upstream-write-guard.sh; this adapter only finds executed gh, gh-axi,
// and git command positions and asks that owner for a local-only verdict.
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { analyzeShellCommands } from "./fm-arm-command-policy.mjs";

const self = fileURLToPath(import.meta.url);
const defaultRoot = resolve(dirname(self), "..");

const GUARD_TOOLS = new Set(["gh", "gh-axi", "git"]);

function base(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function checkTool(tool, args, root) {
  const checked = spawnSync(`${root}/bin/fm-upstream-write-guard.sh`, ["check", tool, ...args], {
    cwd: process.cwd(),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (checked.status === 2) {
    const reason = checked.stderr.trim() || "protected-upstream repository mutation refused";
    return { decision: "deny", code: "protected-upstream-write", reason };
  }
  return null;
}

function classifyPosition(position, root) {
  if (!position.command || position.unresolvedWrapperOption) return null;
  const tool = base(position.command.value);
  if (!GUARD_TOOLS.has(tool)) return null;
  const args = position.words.slice(position.index + 1).map((word) => word.value);
  return checkTool(tool, args, root);
}

function rawLexErrorMention(command, root) {
  const words = command.split(/\s+/);
  for (let i = 0; i < words.length; i += 1) {
    const tool = base(words[i] || "");
    if (!GUARD_TOOLS.has(tool)) continue;
    if (checkTool(tool, words.slice(i + 1), root)) return true;
  }
  return false;
}

function decision(command, root = defaultRoot) {
  const { error, positions } = analyzeShellCommands(command);
  for (const { position } of positions) {
    const denied = classifyPosition(position, root);
    if (denied) return denied;
  }
  if (error === "recursion limit") {
    return {
      decision: "deny",
      code: "protected-upstream-write",
      reason: "command nesting exceeds the shell analysis limit",
    };
  }
  if (error && rawLexErrorMention(command, root)) {
    return {
      decision: "deny",
      code: "protected-upstream-write",
      reason: "unparseable shell grammar contains a protected-upstream repository mutation",
    };
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", root: defaultRoot };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--command" || argv[i] === "--root") {
      if (i + 1 >= argv.length) throw new Error(`${argv[i]} requires a value`);
      result[argv[i].slice(2)] = argv[i + 1];
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${argv[i]}`);
  }
  return result;
}

function invokedDirectly() {
  try {
    return realpathSync(process.argv[1]) === realpathSync(self);
  } catch {
    return process.argv[1] === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = args.command ? decision(args.command, args.root) : { decision: "allow" };
    if (result.decision === "allow") process.stdout.write("allow\n");
    else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
