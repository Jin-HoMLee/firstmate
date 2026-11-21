#!/usr/bin/env node
// Primary-session shell policy for protected-upstream repository writes.
// Shell lexing and command-position recursion come from
// fm-arm-command-policy.mjs. The repository-operation classifier remains solely
// in fm-upstream-write-guard.sh; this adapter only finds executed gh, gh-axi,
// and git command positions and asks that owner for a local-only verdict.
import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { analyzeProgram, Lexer } from "./fm-arm-command-policy.mjs";

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

function isLiteral(word) {
  return word.literal && !word.unquotedExpansion && word.subs.length === 0;
}

function gitCommandInfo(words) {
  let anchoredDirectory = false;
  for (let index = 0; index < words.length; index += 1) {
    const word = words[index];
    if (!isLiteral(word) || !word.value) return null;
    const arg = word.value;
    if (["-C", "-c", "--config-env", "--git-dir", "--work-tree", "--namespace"].includes(arg)) {
      const value = words[index + 1];
      if (!value || !isLiteral(value)) return null;
      if (arg === "-C") anchoredDirectory = isAbsolute(value.value) || anchoredDirectory;
      index += 1;
    } else if (arg.startsWith("-C") && arg.length > 2) {
      anchoredDirectory = isAbsolute(arg.slice(2)) || anchoredDirectory;
    } else if (/^(?:-c.+|--(?:config-env|git-dir|work-tree|namespace)=)/.test(arg)) {
      continue;
    } else if (["--help", "-h", "--version", "-v"].includes(arg)) {
      return { subcommand: "help", anchoredDirectory };
    } else if (["--no-pager", "--paginate", "--literal-pathspecs", "--no-replace-objects", "--no-optional-locks"].includes(arg)) {
      continue;
    } else if (arg.startsWith("-")) {
      return null;
    } else {
      return { subcommand: arg, anchoredDirectory };
    }
  }
  return { subcommand: "", anchoredDirectory };
}

function hasUnprovedGitEnvironment(position) {
  const prefix = position.words.slice(0, position.index);
  const bindings = base(position.command?.value || "") === "export"
    ? [...prefix, ...position.words.slice(position.index + 1)] : prefix;
  return bindings.some((word) => /^(?:GIT_[A-Za-z0-9_]*|HOME|XDG_CONFIG_HOME|PATH)(?:=|$)/.test(word.value)) ||
    position.wrappers.includes("sudo") || position.wrapperEnvironmentChange ||
    (position.wrappers.includes("env") && prefix.some((word) => !isLiteral(word)));
}

function checkToolWords(tool, words, root, unprovedGitEnvironment) {
  const git = tool === "git" ? gitCommandInfo(words) : null;
  if (tool === "git" && !git) {
    return {
      decision: "deny",
      code: "protected-upstream-write",
      reason: "Git subcommand must be proved literal before a read exemption can be granted",
    };
  }
  if (git?.subcommand === "push" && unprovedGitEnvironment) {
    return {
      decision: "deny",
      code: "protected-upstream-write",
      reason: "command-local Git environment or user context cannot be verified for a push",
    };
  }
  if ((tool !== "git" || git.subcommand === "push") && words.some((word) => !isLiteral(word))) {
    return {
      decision: "deny",
      code: "protected-upstream-write",
      reason: "repository writes require literal arguments and a proved destination; shell expansion is unsupported",
    };
  }
  return checkTool(tool, words.map((word) => word.value), root);
}

function classifyPosition(position, root, unprovedGitEnvironment) {
  if (!position.command) return null;
  if (position.unresolvedWrapperOption) {
    const words = position.words.slice(position.index);
    for (let i = 0; i < words.length; i += 1) {
      const candidate = base(words[i]?.value || "");
      if (!GUARD_TOOLS.has(candidate)) continue;
      const denied = checkToolWords(candidate, words.slice(i + 1), root, unprovedGitEnvironment);
      if (denied) return denied;
    }
    return null;
  }
  const tool = base(position.command.value);
  if (!GUARD_TOOLS.has(tool)) return null;
  const args = position.words.slice(position.index + 1);
  return checkToolWords(tool, args, root, unprovedGitEnvironment);
}

function decodeWord(word) {
  const lexed = new Lexer(word).tokenize();
  if (!lexed.error && lexed.tokens.length === 1 && lexed.tokens[0].type === "word") {
    return lexed.tokens[0].value;
  }
  return word.replace(/\\(.)/g, "$1").replace(/['"]/g, "");
}

function rawLexErrorMention(command) {
  const words = command.split(/[\s;&|<>()]+/).map(decodeWord);
  return words.some((word) => GUARD_TOOLS.has(base(word)));
}

function gitPushInfo(position) {
  if (!position.command || base(position.command.value) !== "git") return null;
  const info = gitCommandInfo(position.words.slice(position.index + 1));
  return info?.subcommand === "push" ? info : null;
}

function isDirectoryChange(position) {
  const tool = base(position.command?.value || "");
  if (position.wrapperDirectoryChange || tool === "cd" || tool === "pushd" || tool === "popd") return true;
  if (tool === "builtin") {
    const name = position.words[position.index + 1]?.value;
    return name === "cd" || name === "pushd" || name === "popd";
  }
  return false;
}

function decision(command, root = defaultRoot) {
  const context = { root, home: root, protectedVariables: new Set(), watcherPatterns: new Set(), watcherPids: new Set() };
  const { traversalError, positions } = analyzeProgram(command, context, 0, 64);
  let unprovedGitEnvironment = false;
  for (const { position } of positions) {
    unprovedGitEnvironment ||= hasUnprovedGitEnvironment(position);
    const denied = classifyPosition(position, root, unprovedGitEnvironment);
    if (denied) return denied;
  }
  let directoryChanged = false;
  for (const { position } of positions) {
    if (isDirectoryChange(position)) directoryChanged = true;
    const info = gitPushInfo(position);
    if (info && !info.anchoredDirectory && directoryChanged) {
      return {
        decision: "deny",
        code: "protected-upstream-write",
        reason: "directory-dependent git push cannot be resolved to its repository locally; refusing before network access",
      };
    }
  }
  if (traversalError === "recursion limit") {
    return {
      decision: "deny",
      code: "protected-upstream-write",
      reason: "command nesting exceeds the shell analysis limit",
    };
  }
  if (traversalError && rawLexErrorMention(command)) {
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
