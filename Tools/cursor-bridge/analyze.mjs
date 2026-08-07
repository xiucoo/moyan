#!/usr/bin/env node
/**
 * 墨言 ↔ Cursor SDK 桥接：读取 stdin JSON，调用 Agent.prompt，stdout 输出 JSON。
 * 输入: { "apiKey": "...", "prompt": "...", "cwd": "...", "model": "grok-4.5" }
 * 输出: { "ok": true, "status": "...", "text": "..." } | { "ok": false, "error": "..." }
 */
import { readFileSync } from "node:fs";
import { Agent, CursorAgentError } from "@cursor/sdk";

/** 默认与当前对话一致：Cursor Grok 4.5 */
const DEFAULT_MODEL = "grok-4.5";

function readInput() {
  const arg = process.argv[2];
  if (arg && arg !== "-") {
    return JSON.parse(readFileSync(arg, "utf8"));
  }
  const raw = readFileSync(0, "utf8");
  return JSON.parse(raw);
}

function extractText(result) {
  if (!result) return "";
  if (typeof result.result === "string") return result.result;
  if (typeof result.text === "string") return result.text;
  try {
    return JSON.stringify(result.result ?? result, null, 2);
  } catch {
    return String(result.result ?? "");
  }
}

async function main() {
  const input = readInput();
  const apiKey = input.apiKey || process.env.CURSOR_API_KEY;
  const prompt = input.prompt;
  const cwd = input.cwd || process.cwd();
  const model = input.model || DEFAULT_MODEL;

  if (!apiKey) {
    console.log(JSON.stringify({ ok: false, error: "缺少 CURSOR_API_KEY，请在墨言设置中填写。" }));
    process.exit(2);
  }
  if (!prompt || !String(prompt).trim()) {
    console.log(JSON.stringify({ ok: false, error: "prompt 为空" }));
    process.exit(2);
  }

  try {
    const result = await Agent.prompt(String(prompt), {
      apiKey,
      model: { id: model },
      local: { cwd },
    });
    console.log(
      JSON.stringify({
        ok: true,
        status: result.status ?? "ok",
        text: extractText(result),
        id: result.id ?? null,
      })
    );
    if (result.status === "error") process.exit(3);
  } catch (err) {
    const message =
      err instanceof CursorAgentError
        ? `${err.message} (retryable=${err.isRetryable})`
        : err?.message || String(err);
    console.log(JSON.stringify({ ok: false, error: message }));
    process.exit(1);
  }
}

main();
