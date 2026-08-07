#!/usr/bin/env node
/**
 * 墨言 AI 搜索（流式）：stdout 输出 NDJSON 行。
 * 输入: { "apiKey", "prompt", "cwd", "model" }
 * 行事件:
 *   { "type": "delta", "text": "..." }
 *   { "type": "done", "ok": true, "text": "...", "status": "..." }
 *   { "type": "done", "ok": false, "error": "..." }
 *
 * 不用 `await using`：部分 Node/工具链会把它解析成 SyntaxError。
 */
import { readFileSync } from "node:fs";
import { Agent, CursorAgentError } from "@cursor/sdk";

const DEFAULT_MODEL = "grok-4.5";

function readInput() {
  const arg = process.argv[2];
  if (arg && arg !== "-") {
    return JSON.parse(readFileSync(arg, "utf8"));
  }
  const raw = readFileSync(0, "utf8");
  return JSON.parse(raw);
}

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
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

async function disposeAgent(agent) {
  if (!agent) return;
  try {
    if (typeof agent.close === "function") {
      await agent.close();
      return;
    }
    const dispose = agent[Symbol.asyncDispose];
    if (typeof dispose === "function") {
      await dispose.call(agent);
    }
  } catch {
    // 忽略清理失败，避免掩盖主错误
  }
}

async function main() {
  const input = readInput();
  const apiKey = input.apiKey || process.env.CURSOR_API_KEY;
  const prompt = input.prompt;
  const cwd = input.cwd || process.cwd();
  const model = input.model || DEFAULT_MODEL;

  if (!apiKey) {
    emit({ type: "done", ok: false, error: "缺少 CURSOR_API_KEY，请在墨言设置中填写。" });
    process.exit(2);
  }
  if (!prompt || !String(prompt).trim()) {
    emit({ type: "done", ok: false, error: "搜索内容为空" });
    process.exit(2);
  }

  let agent;
  try {
    agent = await Agent.create({
      apiKey,
      model: { id: model },
      local: { cwd },
    });

    const run = await agent.send(String(prompt));
    let assembled = "";

    for await (const event of run.stream()) {
      if (event?.type === "assistant" && event.message?.content) {
        for (const block of event.message.content) {
          if (block?.type === "text" && typeof block.text === "string" && block.text) {
            assembled += block.text;
            emit({ type: "delta", text: block.text });
          }
        }
      }
    }

    const result = await run.wait();
    const finalText = extractText(result) || assembled;
    emit({
      type: "done",
      ok: result.status !== "error",
      status: result.status ?? "ok",
      text: finalText,
      id: result.id ?? null,
      error: result.status === "error" ? "模型运行失败" : undefined,
    });
    if (result.status === "error") process.exitCode = 3;
  } catch (err) {
    const message =
      err instanceof CursorAgentError
        ? `${err.message} (retryable=${err.isRetryable})`
        : err?.message || String(err);
    emit({ type: "done", ok: false, error: message });
    process.exitCode = 1;
  } finally {
    await disposeAgent(agent);
  }
}

main();
