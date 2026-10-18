import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

function runProcess(command, args) {
  return new Promise((done) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("error", () => done({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => done({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  if (result.code === 0 && result.stdout.trim()) return result.stdout.trim();
  try { return realpathSync(anchor); } catch { return resolve(anchor); }
}

export const FmPrimaryUpstreamWriteCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try { return realpathSync(worktree); } catch { return resolve(worktree); }
  })() : await resolveRoot(directory);
  return {
    "tool.execute.before": async (input, output) => {
      if (!root || input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;
      const result = await runProcess(`${root}/bin/fm-upstream-write-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;
      throw new Error(result.stderr.trim() || "denied by the protected-upstream write guard");
    },
  };
};
