#!/usr/bin/env node
// Primary-session shell policy for protected-upstream repository writes.
// Shell lexing comes from fm-arm-command-policy.mjs. The repository-operation
// classifier remains solely in fm-upstream-write-guard.sh; this adapter only
// finds executed gh, gh-axi, and git command positions and asks that owner for
// a local-only verdict.
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

const self = fileURLToPath(import.meta.url);
const defaultRoot = resolve(dirname(self), "..");

function base(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function decision(command, root = defaultRoot) {
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return { decision: "allow" };
  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    const position = commandPosition(node);
    if (!position.command || position.unresolvedWrapperOption) continue;
    const tool = base(position.command.value);
    if (!new Set(["gh", "gh-axi", "git"]).has(tool)) continue;
    const args = position.words.slice(position.index + 1).map((word) => word.value);
    const checked = spawnSync(`${root}/bin/fm-upstream-write-guard.sh`, ["check", tool, ...args], {
      cwd: process.cwd(),
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (checked.status === 2) {
      const reason = checked.stderr.trim() || "protected-upstream repository mutation refused";
      return { decision: "deny", code: "protected-upstream-write", reason };
    }
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
