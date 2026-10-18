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

const GUARD_TOOLS = new Set(["gh", "gh-axi", "git"]);

function shellInvocation(position) {
  if (!position.command) return null;
  const name = base(position.command.value);
  if (!["sh", "bash", "zsh"].includes(name)) return null;
  const words = position.words;
  let readsStdin = false;
  let optionsEnded = false;
  for (let i = position.index + 1; i < words.length; i += 1) {
    const option = words[i];
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(option.value)) {
      let payloadIndex = i + 1;
      if (words[payloadIndex]?.value === "--") payloadIndex += 1;
      return { kind: "command", payload: words[payloadIndex] || null };
    }
    if (/^[-+]O$/.test(option.value)) {
      i += 1;
      continue;
    }
    if (!optionsEnded && /^-[A-Za-z]*s[A-Za-z]*$/.test(option.value)) readsStdin = true;
    if (option.value === "--") {
      if (readsStdin) return { kind: "stdin", payload: null, operand: words[i + 1] || null };
      optionsEnded = true;
    }
    if (option.value === "--" || /^[-+]/.test(option.value)) continue;
    if (readsStdin) return { kind: "stdin", payload: null, operand: option };
    return { kind: "script", payload: option };
  }
  return { kind: "stdin", payload: null };
}

function shellHeredocPayloads(tokens, position) {
  if (shellInvocation(position)?.kind !== "stdin") return [];
  const heredocs = tokens.filter((token) => token.type === "redir" && token.fd === 0 && typeof token.heredoc === "string");
  return heredocs.length === 0 ? [] : [heredocs.at(-1).heredoc];
}

function shellHereStringPayloads(tokens, position) {
  if (shellInvocation(position)?.kind !== "stdin") return [];
  const payloads = [];
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token.type !== "redir" || token.value !== "<<<" || token.fd !== 0) continue;
    const payload = tokens[i + 1];
    if (payload?.type === "word" && payload.literal && payload.subs.length === 0) payloads.push(payload.value);
  }
  return payloads;
}

function evalPayload(position) {
  if (!position.command || base(position.command.value) !== "eval") return null;
  const payloads = position.words.slice(position.index + 1);
  if (payloads.length === 0 || payloads.some((payload) => !payload.literal || payload.subs.length > 0)) return null;
  return payloads.map((payload) => payload.value).join(" ");
}

function classifyPosition(position, root) {
  if (!position.command || position.unresolvedWrapperOption) return null;
  const tool = base(position.command.value);
  if (!GUARD_TOOLS.has(tool)) return null;
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
  return null;
}

function walk(command, root, depth = 0) {
  if (depth > 12) return null;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return null;
  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    const position = commandPosition(tokens);
    for (const payload of position.wrapperPayloads) {
      const denied = walk(payload, root, depth + 1);
      if (denied) return denied;
    }
    for (const token of tokens) {
      if (token.type === "group") {
        const denied = walk(token.content, root, depth + 1);
        if (denied) return denied;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const denied = walk(substitution.content, root, depth + 1);
          if (denied) return denied;
        }
      }
    }
    const shell = shellInvocation(position);
    if (shell?.kind === "command" && shell.payload) {
      const denied = walk(shell.payload.value, root, depth + 1);
      if (denied) return denied;
    }
    const literalEval = evalPayload(position);
    if (literalEval !== null) {
      const denied = walk(literalEval, root, depth + 1);
      if (denied) return denied;
    }
    for (const payload of [...shellHeredocPayloads(tokens, position), ...shellHereStringPayloads(tokens, position)]) {
      const denied = walk(payload, root, depth + 1);
      if (denied) return denied;
    }
    const denied = classifyPosition(position, root);
    if (denied) return denied;
  }
  return null;
}

function decision(command, root = defaultRoot) {
  return walk(command, root) || { decision: "allow" };
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
