// The outside-minutes script, against the real ai-execution-router installed beside it (tests/run.sh
// installs it into a scratch copy). Nothing here reaches the network: globalThis.fetch is replaced by
// a recorder, or the request goes to a node:http server on 127.0.0.1 that the test runs.

import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";
import { complete as routerComplete } from "ai-execution-router";
import { run, send } from "../writer.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const WRITER = join(here, "..", "writer.mjs");

const KEY = "sk-test-0123456789abcdefghijKLMNOPQRSTUVwxyz";
const SECRET = "BLUEHERON";
const LINE = `[00:00:01] Me: the quarterly plan codename is ${SECRET} and we ship it in March`;
const USER = "Meeting recorded on Tuesday 10 November 2026 at 17:54, 36 minutes.\n\n<transcript>\n" + LINE +
  "\n[00:00:09] Them 1: agreed, the plan ships in March\n</transcript>";
const SYSTEM = "Write the minutes of this meeting.";
const STANDARD = "http://127.0.0.1:11434/v1";
const CLAUDE = "https://api.anthropic.com";

function req(over = {}) {
  return { kind: "standard", address: STANDARD, model: "llama3", system: SYSTEM, user: USER, timeoutMs: 900000, maxTokens: 16000, ...over };
}

// --- the fetch recorder ---------------------------------------------------------------------------

const realFetch = globalThis.fetch;
let calls = [];
function useFetch(handler) {
  calls = [];
  const recorder = async (url, init = {}) => {
    const entry = {
      url: String(url),
      method: init.method ?? "GET",
      headers: new Headers(init.headers),
      redirect: init.redirect,
      body: typeof init.body === "string" ? JSON.parse(init.body) : undefined,
      signal: init.signal,
    };
    calls.push(entry);
    return handler(entry, calls.length);
  };
  globalThis.fetch = recorder;
  return recorder;
}
afterEach(() => { globalThis.fetch = realFetch; });

function sse(events, chunkSize) {
  const text = events.map((e) => `data: ${typeof e === "string" ? e : JSON.stringify(e)}\n\n`).join("");
  const bytes = new TextEncoder().encode(text);
  const size = chunkSize ?? bytes.length;
  const body = new ReadableStream({
    start(c) {
      for (let i = 0; i < bytes.length; i += size) c.enqueue(bytes.slice(i, i + size));
      c.close();
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}
function pieces(text, n) {
  const out = [];
  const step = Math.ceil(text.length / n);
  for (let i = 0; i < text.length; i += step) out.push(text.slice(i, i + step));
  return out;
}
// An OpenAI-style streamed reply: the text in several frames, split again across byte chunks.
function standardReply(text, { finish = "stop", usage = { prompt_tokens: 1234, completion_tokens: 300 }, chunkSize = 7 } = {}) {
  const events = pieces(text, 4).map((p) => ({ id: "c1", choices: [{ index: 0, delta: { content: p } }] }));
  events.push({ id: "c1", choices: [{ index: 0, delta: {}, finish_reason: finish }] });
  if (usage) events.push({ id: "c1", choices: [], usage });
  events.push("[DONE]");
  return sse(events, chunkSize);
}
// An Anthropic streamed reply: input tokens on message_start, output tokens on message_delta. A count
// given as null is left out.
function claudeReply(text, { stop = "end_turn", input = 1234, output = 300, chunkSize = 11 } = {}) {
  const start = { id: "msg_1", usage: {} };
  if (input !== null) start.usage.input_tokens = input;
  const delta = { type: "message_delta", delta: { stop_reason: stop }, usage: {} };
  if (output !== null) delta.usage.output_tokens = output;
  const events = [{ type: "message_start", message: start }, { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }];
  for (const p of pieces(text, 3)) events.push({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: p } });
  events.push({ type: "content_block_stop", index: 0 }, delta, { type: "message_stop" });
  return sse(events, chunkSize);
}
function json(status, body, headers = {}) {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status, headers: { "content-type": "application/json", ...headers },
  });
}
// A fetch rejected the way Node's own is: a TypeError whose cause carries the code.
function fetchFailed(cause) {
  const err = new TypeError("fetch failed");
  err.cause = cause;
  return err;
}
function coded(code, message = code) { return Object.assign(new Error(message), { code }); }

const MINUTES = "## Summary\nThe plan was agreed.\n\n## Decisions\n- Ship in March\n\n## Actions\nNone\n\n## Open questions\nNone\n";

// --- the router is called once, for the right wire shape ------------------------------------------

test("complete calls the router once, with provider anthropic for the Claude API and openai-chat for Standard", async () => {
  for (const [kind, address, provider, reply] of [
    ["claude", CLAUDE, "anthropic", claudeReply], ["standard", STANDARD, "openai-chat", standardReply]]) {
    useFetch(() => reply(MINUTES));
    const seen = [];
    const out = await send(req({ kind, address, key: KEY }), (p) => { seen.push(p); return routerComplete(p); });
    assert.equal(seen.length, 1, kind);
    assert.equal(seen[0].endpoint.provider, provider);
    assert.equal(seen[0].endpoint.baseUrl, address);
    assert.equal(seen[0].endpoint.apiKey, KEY);
    assert.equal(seen[0].endpoint.headers, undefined, "with a key, no extra header");
    assert.equal(typeof seen[0].onDelta, "function");
    assert.equal(seen[0].timeoutMs, 900000);
    assert.equal(seen[0].maxTokens, 16000);
    assert.equal(seen[0].model, "llama3");
    assert.deepEqual(seen[0].input, { system: SYSTEM, messages: [{ role: "user", content: USER }] });
    assert.equal(calls.length, 1);
    assert.equal(out.text, MINUTES);
  }
});

test("the Claude API is POSTed at <address>/v1/messages with its key and version headers", async () => {
  useFetch(() => claudeReply(MINUTES));
  const r = await run("complete", req({ kind: "claude", address: CLAUDE, key: KEY }));
  assert.equal(r.code, 0);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].url, `${CLAUDE}/v1/messages`);
  assert.equal(calls[0].headers.get("x-api-key"), KEY);
  assert.equal(calls[0].headers.get("anthropic-version"), "2023-06-01");
  assert.equal(calls[0].headers.get("authorization"), null);
  assert.equal(calls[0].body.system, SYSTEM);
  assert.deepEqual(calls[0].body.messages, [{ role: "user", content: USER }]);
  assert.equal(r.output.text, MINUTES);
});

// --- keys -----------------------------------------------------------------------------------------

test("keyless Standard: one POST to <address>/chat/completions with x-meetingbox: 1 and no authorization, and it succeeds", async () => {
  useFetch(() => standardReply(MINUTES));
  const r = await run("complete", req());
  assert.equal(r.code, 0);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].url, `${STANDARD}/chat/completions`);
  assert.equal(calls[0].headers.get("x-meetingbox"), "1");
  assert.equal(calls[0].headers.get("authorization"), null);
  assert.deepEqual(r.output, { text: MINUTES, finishReason: "stop", inputTokens: 1234, tokenSource: "reported" });
});

test("Standard with a key: authorization: Bearer <key>, and no x-meetingbox", async () => {
  useFetch(() => standardReply(MINUTES));
  const r = await run("complete", req({ key: KEY }));
  assert.equal(r.code, 0);
  assert.equal(calls[0].headers.get("authorization"), `Bearer ${KEY}`);
  assert.equal(calls[0].headers.get("x-meetingbox"), null);
});

test("a Claude API source with no key makes no fetch and is refused, not sent", async () => {
  useFetch(() => claudeReply(MINUTES));
  const r = await run("complete", req({ kind: "claude", address: CLAUDE }));
  assert.equal(r.code, 0);
  assert.equal(calls.length, 0);
  assert.equal(r.output.error.type, "refused");
  assert.equal(r.output.error.sent, false);
});

test("a key that breaks the key rule is bad input, and nothing is sent", async () => {
  useFetch(() => standardReply(MINUTES));
  for (const key of ["", "has space", "quote\"d", "back\\slash", "new\nline", "x".repeat(4097), "é"]) {
    const r = await run("complete", req({ key }));
    assert.equal(r.code, 2, JSON.stringify(key));
  }
  assert.equal(calls.length, 0);
});

// --- streaming ------------------------------------------------------------------------------------

test("streamed: stream: true, and for Standard stream_options.include_usage; a reply over many chunks comes back whole", async () => {
  useFetch(() => standardReply(MINUTES, { chunkSize: 5 }));
  let r = await run("complete", req());
  assert.equal(calls[0].body.stream, true);
  assert.deepEqual(calls[0].body.stream_options, { include_usage: true });
  assert.equal(calls[0].body.max_tokens, 16000);
  assert.equal(r.output.text, MINUTES);
  useFetch(() => claudeReply(MINUTES, { chunkSize: 3 }));
  r = await run("complete", req({ kind: "claude", address: CLAUDE, key: KEY }));
  assert.equal(calls[0].body.stream, true);
  assert.equal(calls[0].body.max_tokens, 16000);
  assert.equal(r.output.text, MINUTES);
});

// --- redirects ------------------------------------------------------------------------------------

test("every fetch carries redirect: error, for complete and for list", async () => {
  useFetch(() => standardReply(MINUTES));
  await run("complete", req());
  const seen = [...calls];
  useFetch(() => claudeReply(MINUTES));
  await run("complete", req({ kind: "claude", address: CLAUDE, key: KEY }));
  seen.push(...calls);
  useFetch((c, n) => json(200, { data: [{ id: `m${n}` }], has_more: n < 3, last_id: `m${n}` }));
  await run("list", { kind: "claude", address: CLAUDE, key: KEY });
  seen.push(...calls);
  useFetch(() => json(200, { data: [{ id: "llama3" }] }));
  await run("list", { kind: "standard", address: STANDARD });
  seen.push(...calls);
  assert.equal(seen.length, 6);
  for (const c of seen) assert.equal(c.redirect, "error", c.url);
});

test("run restores globalThis.fetch afterwards, after a failure too", async () => {
  const recorder = useFetch(() => { throw fetchFailed(coded("ECONNREFUSED")); });
  await run("complete", req());
  assert.equal(globalThis.fetch, recorder);
  useFetch(() => standardReply(MINUTES));
  const again = globalThis.fetch;
  await run("complete", req());
  assert.equal(globalThis.fetch, again);
});

// --- error types, in the contract's order ---------------------------------------------------------

async function errorOf(handler, over = {}) {
  useFetch(handler);
  const r = await run("complete", req(over));
  assert.equal(r.code, 0);
  assert.ok(r.output.error, JSON.stringify(r.output));
  return r.output.error;
}
function waitForAbort(c) {
  return new Promise((_, reject) => {
    c.signal.addEventListener("abort", () => reject(new DOMException("This operation was aborted", "AbortError")), { once: true });
  });
}

test("TimeoutError gives timeout", async () => {
  const e = await errorOf((c) => waitForAbort(c), { timeoutMs: 50 });
  assert.equal(e.type, "timeout");
  assert.equal(e.sent, true);
});

test("a fetch rejected with UND_ERR_HEADERS_TIMEOUT gives timeout, and it was sent", async () => {
  const e = await errorOf(() => { throw fetchFailed(coded("UND_ERR_HEADERS_TIMEOUT", "Headers Timeout Error")); });
  assert.equal(e.type, "timeout");
  assert.equal(e.sent, true);
});

test("a fetch rejected with UND_ERR_BODY_TIMEOUT gives timeout", async () => {
  const e = await errorOf(() => { throw fetchFailed(coded("UND_ERR_BODY_TIMEOUT", "Body Timeout Error")); });
  assert.equal(e.type, "timeout");
  assert.equal(e.sent, true);
});

test("a streamed body that stops with UND_ERR_BODY_TIMEOUT gives timeout", async () => {
  const e = await errorOf(() => {
    const body = new ReadableStream({
      start(c) {
        c.enqueue(new TextEncoder().encode(`data: ${JSON.stringify({ choices: [{ delta: { content: "## Sum" } }] })}\n\n`));
        c.error(fetchFailed(coded("UND_ERR_BODY_TIMEOUT", "Body Timeout Error")));
      },
    });
    return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
  });
  assert.equal(e.type, "timeout");
  assert.equal(e.sent, true);
});

test("QuotaExhaustedError gives quota", async () => {
  const e = await errorOf(() => json(429, { error: { type: "insufficient_quota", message: "You exceeded your current quota, please check your plan and billing details." } }));
  assert.equal(e.type, "quota");
  assert.equal(e.sent, true);
});

test("RateLimitError gives rate", async () => {
  const e = await errorOf(() => json(429, { error: { message: "Rate limit reached for requests" } }));
  assert.equal(e.type, "rate");
  assert.equal(calls.length, 1);
});

test("AuthError (a 401) gives refused, and it was sent", async () => {
  const e = await errorOf(() => json(401, { error: { message: "invalid x-api-key" } }), { kind: "claude", address: CLAUDE, key: KEY });
  assert.equal(e.type, "refused");
  assert.equal(e.sent, true);
});

test("ContextLengthError gives context", async () => {
  const e = await errorOf(() => json(400, { error: { message: "prompt is too long: 250000 tokens > 200000 maximum" } }));
  assert.equal(e.type, "context");
});

test("MalformedResponseError (a 200 HTML body) gives other", async () => {
  const e = await errorOf(() => new Response("<html><body>Gateway login</body></html>", { status: 200, headers: { "content-type": "text/html" } }));
  assert.equal(e.type, "other");
  assert.equal(e.sent, true);
});

test("a 500 gives http, with its status in the message", async () => {
  const e = await errorOf(() => json(500, { error: { message: "upstream exploded" } }));
  assert.equal(e.type, "http");
  assert.match(e.message, /^[A-Za-z]+ \(HTTP 500\)/);
});

test("the message is the name, the status and the first line, cut to 200, with the key as [key]", async () => {
  const e = await errorOf(() => json(500, { error: { message: `upstream rejected ${KEY} today\u0007 ${"z".repeat(300)}\nsecond line` } }), { key: KEY });
  assert.ok(e.message.startsWith(`TransientError (HTTP 500): upstream rejected [key] today ${"z".repeat(20)}`), e.message);
  assert.ok(e.message.length <= 200 + "TransientError (HTTP 500): ".length, String(e.message.length));
  assert.ok(!e.message.includes("second line"));
  assert.ok(!e.message.includes(KEY));
  assert.ok(!/[\u0000-\u001f]/.test(e.message));
});

// --- sent -----------------------------------------------------------------------------------------

async function server(handler) {
  const s = createServer(handler);
  await new Promise((resolve) => s.listen(0, "127.0.0.1", resolve));
  return {
    port: s.address().port,
    url: `http://127.0.0.1:${s.address().port}`,
    close: () => new Promise((resolve) => { s.closeAllConnections?.(); s.close(() => resolve()); }),
  };
}

test("a redirect is refused, and counts as sent; the redirect's target gets nothing", async () => {
  let reached = 0;
  const target = await server((rq, rs) => { reached++; rs.end("{}"); });
  const source = await server((rq, rs) => {
    rq.resume();
    rq.on("end", () => { rs.writeHead(307, { location: `${target.url}/v1/chat/completions` }); rs.end(); });
  });
  try {
    const r = await run("complete", req({ address: `${source.url}/v1` }));
    assert.equal(r.code, 0);
    assert.equal(r.output.error.sent, true);
    assert.equal(r.output.error.type, "other");
    assert.equal(reached, 0);
  } finally {
    await source.close(); await target.close();
  }
});

test("a connection reset after the request went counts as sent", async () => {
  const s = await server((rq) => { rq.resume(); rq.on("end", () => rq.socket.resetAndDestroy()); });
  try {
    const r = await run("complete", req({ address: `${s.url}/v1` }));
    assert.equal(r.output.error.sent, true);
    assert.notEqual(r.output.error.type, "connect");
  } finally { await s.close(); }
  const e = await errorOf(() => { throw fetchFailed(coded("ECONNRESET", "read ECONNRESET")); });
  assert.equal(e.sent, true);
  assert.equal(e.type, "other");
});

test("ECONNREFUSED gives connect, not sent", async () => {
  const s = await server(() => {});
  const port = s.port;
  await s.close();
  const r = await run("complete", req({ address: `http://127.0.0.1:${port}/v1` }));
  assert.equal(r.code, 0);
  assert.deepEqual([r.output.error.type, r.output.error.sent], ["connect", false]);
});

test("every connect-stage code, on the cause or in an AggregateError, gives connect, not sent", async () => {
  for (const code of ["ECONNREFUSED", "ENOTFOUND", "EAI_AGAIN", "EHOSTUNREACH", "ENETUNREACH", "UND_ERR_CONNECT_TIMEOUT"]) {
    let e = await errorOf(() => { throw fetchFailed(coded(code)); });
    assert.deepEqual([e.type, e.sent], ["connect", false], code);
    const agg = Object.assign(new AggregateError([coded(code), coded(code)], code), { code });
    e = await errorOf(() => { throw fetchFailed(agg); });
    assert.deepEqual([e.type, e.sent], ["connect", false], `${code} in an AggregateError`);
  }
});

test("an error thrown before any fetch (no baseUrl) is not sent", async () => {
  useFetch(() => standardReply(MINUTES));
  const out = await send(req(), (p) => routerComplete({ ...p, endpoint: { ...p.endpoint, baseUrl: undefined } }));
  assert.equal(calls.length, 0);
  assert.equal(out.error.sent, false);
  assert.equal(out.error.type, "connect");
});

// --- finish reasons and tokens --------------------------------------------------------------------

test("inputTokens is the router's promptTokens, and tokenSource reported, partial and unreported pass through", async () => {
  useFetch(() => standardReply(MINUTES, { usage: { prompt_tokens: 4321, completion_tokens: 10 } }));
  let r = await run("complete", req());
  assert.deepEqual([r.output.inputTokens, r.output.tokenSource], [4321, "reported"]);
  useFetch(() => standardReply(MINUTES, { usage: { prompt_tokens: 4321 } }));
  r = await run("complete", req());
  assert.deepEqual([r.output.inputTokens, r.output.tokenSource], [4321, "partial"]);
  useFetch(() => standardReply(MINUTES, { usage: null }));
  r = await run("complete", req());
  assert.deepEqual([r.output.inputTokens, r.output.tokenSource], [0, "unreported"]);
  useFetch(() => claudeReply(MINUTES, { input: 999, output: null }));
  r = await run("complete", req({ kind: "claude", address: CLAUDE, key: KEY }));
  assert.deepEqual([r.output.inputTokens, r.output.tokenSource], [999, "partial"]);
});

test("finishReason length, max_tokens and model_context_window_exceeded pass through as given", async () => {
  useFetch(() => standardReply(MINUTES, { finish: "length" }));
  let r = await run("complete", req());
  assert.equal(r.output.finishReason, "length");
  useFetch(() => claudeReply(MINUTES, { stop: "max_tokens" }));
  r = await run("complete", req({ kind: "claude", address: CLAUDE, key: KEY }));
  assert.equal(r.output.finishReason, "max_tokens");
  useFetch(() => claudeReply(MINUTES, { stop: "model_context_window_exceeded" }));
  r = await run("complete", req({ kind: "claude", address: CLAUDE, key: KEY }));
  assert.equal(r.output.finishReason, "model_context_window_exceeded");
  assert.equal(r.output.text, MINUTES);
});

// --- the address rule -----------------------------------------------------------------------------

function addressCases() {
  const at = [join(here, "..", "addresses.txt"), join(here, "..", "..", "tests", "fixtures", "addresses.txt")].find(existsSync);
  assert.ok(at, "tests/fixtures/addresses.txt");
  const cases = [];
  for (const line of readFileSync(at, "utf8").split("\n")) {
    if (line === "" || line.startsWith("#")) continue;
    const space = line.indexOf(" ");
    const verdict = line.slice(0, space);
    const address = line.slice(space + 1).replace(/\\(n|r|t|\\)/g, (_, c) => ({ n: "\n", r: "\r", t: "\t", "\\": "\\" })[c]);
    assert.ok(verdict === "allow" || verdict === "refuse", line);
    cases.push([verdict, address]);
  }
  assert.ok(cases.filter(([v]) => v === "refuse").length > 40);
  return cases;
}

test("every refuse line of the address table gives exit 2 and no fetch, for complete and for list", async () => {
  useFetch(() => standardReply(MINUTES));
  for (const [verdict, address] of addressCases()) {
    if (verdict !== "refuse") continue;
    for (const kind of ["standard", "claude"]) {
      assert.equal((await run("complete", req({ kind, address, key: KEY }))).code, 2, JSON.stringify(address));
      assert.equal((await run("list", { kind, address, key: KEY })).code, 2, JSON.stringify(address));
    }
  }
  assert.equal((await run("complete", req({ address: `https://h.example/${"a".repeat(2048)}` }))).code, 2);
  assert.equal(calls.length, 0);
});

test("every allow line of the address table is accepted", async () => {
  for (const [verdict, address] of addressCases()) {
    if (verdict !== "allow") continue;
    useFetch(() => standardReply(MINUTES));
    const r = await run("complete", req({ address }));
    assert.equal(r.code, 0, address);
    assert.equal(r.output.text, MINUTES, address);
    assert.equal(calls[0].url, `${address.replace(/\/+$/, "")}/chat/completions`);
  }
  useFetch(() => standardReply(MINUTES));
  const long = `https://h.example/${"a".repeat(2048 - "https://h.example/".length)}`;
  assert.equal((await run("complete", req({ address: long }))).code, 0);
});

// --- leaks: the key and the transcript never reach stdout or stderr -------------------------------

function cli(args, stdin, { preload, env = {} } = {}) {
  return new Promise((resolve) => {
    const argv = [...(preload ? ["--import", pathToFileURL(join(here, preload)).href] : []), WRITER, ...args];
    const child = spawn(process.execPath, argv, { env, stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (code) => resolve({ code, out, err }));
    if (stdin !== undefined) child.stdin.end(stdin);
  });
}
function clean(r) {
  for (const text of [r.out, r.err]) {
    assert.ok(!text.includes(KEY), `the key leaked: ${text}`);
    assert.ok(!text.includes(SECRET), `the transcript leaked: ${text}`);
    assert.ok(!text.includes(KEY.slice(8, 24)), `part of the key leaked: ${text}`);
  }
}

test("a 400 whose body echoes the transcript and the key leaves both out of stdout and stderr", async () => {
  for (const shape of ["json", "text"]) {
    const s = await server((rq, rs) => {
      let body = "";
      rq.on("data", (d) => { body += d; });
      rq.on("end", () => {
        const echo = `bad request ${JSON.parse(body).messages[1].content} key ${KEY}`;
        rs.writeHead(400, { "content-type": shape === "json" ? "application/json" : "text/plain" });
        rs.end(shape === "json" ? JSON.stringify({ error: { message: echo } }) : echo);
      });
    });
    try {
      const r = await cli(["complete"], JSON.stringify(req({ address: `${s.url}/v1`, key: KEY })));
      assert.equal(r.code, 0);
      assert.equal(r.err, "");
      const out = JSON.parse(r.out);
      assert.equal(out.error.type, "http");
      assert.equal(out.error.sent, true);
      clean(r);
    } finally { await s.close(); }
  }
});

test("a 400 that echoes only the first line of the transcript leaves it out too", async () => {
  const e = await errorOf(() => json(400, { error: { message: `cannot parse: ${LINE}` } }), { key: KEY });
  assert.ok(!e.message.includes(SECRET), e.message);
  assert.equal(e.type, "http");
});

test("a malformed 200 whose body holds minutes text leaves it out of stdout and stderr", async () => {
  for (const type of ["application/json", "text/html"]) {
    const s = await server((rq, rs) => {
      rq.resume();
      rq.on("end", () => {
        rs.writeHead(200, { "content-type": type });
        rs.end(type === "text/html" ? `<html>${SECRET} minutes ${KEY}</html>`
          : JSON.stringify({ choices: [{ message: { content: `## Summary\n${SECRET} minutes` } }], error: { message: `${SECRET} ${KEY}` } }));
      });
    });
    try {
      const r = await cli(["complete"], JSON.stringify(req({ address: `${s.url}/v1`, key: KEY })));
      assert.equal(r.code, 0);
      assert.ok(JSON.parse(r.out).error, r.out);
      clean(r);
    } finally { await s.close(); }
  }
});

test("stdin of bad JSON holding the key prints only bad input, exit 2", async () => {
  const r = await cli(["complete"], `{"kind": "standard", "key": "${KEY}", "user": "${SECRET}"`);
  assert.deepEqual([r.code, r.out, r.err], [2, "", "bad input\n"]);
  clean(r);
});

test("bad input of every other kind prints only bad input, exit 2", async () => {
  for (const stdin of ["", "[]", "null", "42", JSON.stringify({ ...req(), model: "" }), JSON.stringify({ ...req(), kind: "gemini" }),
    JSON.stringify({ ...req(), user: 7 }), JSON.stringify({ ...req(), timeoutMs: -1 }), JSON.stringify({ ...req(), model: "a\nb" })]) {
    const r = await cli(["complete"], stdin);
    assert.deepEqual([r.code, r.out, r.err], [2, "", "bad input\n"], stdin);
  }
  const r = await cli(["nonsense"], JSON.stringify(req()));
  assert.deepEqual([r.code, r.out, r.err], [2, "", "bad input\n"]);
});

test("an unhandled rejection prints only writer failed, exit 1", async () => {
  const r = await cli(["complete"], undefined, { preload: "fixtures/reject.mjs" });
  assert.deepEqual([r.code, r.out, r.err], [1, "", "writer failed\n"]);
  clean(r);
});

test("an uncaught exception prints only writer failed, exit 1", async () => {
  const r = await cli(["complete"], undefined, { preload: "fixtures/throw.mjs" });
  assert.deepEqual([r.code, r.out, r.err], [1, "", "writer failed\n"]);
  clean(r);
});

test("the command line: one JSON object on stdout, exit 0, and version", async () => {
  const s = await server((rq, rs) => {
    rq.resume();
    rq.on("end", () => {
      rs.writeHead(200, { "content-type": "text/event-stream" });
      rs.end(`data: ${JSON.stringify({ choices: [{ delta: { content: "## Summary\nfine" }, finish_reason: "stop" }] })}\n\ndata: [DONE]\n\n`);
    });
  });
  try {
    const r = await cli(["complete"], JSON.stringify(req({ address: `${s.url}/v1` })));
    assert.equal(r.code, 0);
    assert.equal(r.err, "");
    assert.deepEqual(JSON.parse(r.out), { text: "## Summary\nfine", finishReason: "stop", inputTokens: 0, tokenSource: "unreported" });
    assert.equal(r.out.trim().split("\n").length, 1);
  } finally { await s.close(); }
  const v = await cli(["version"], "");
  assert.deepEqual([v.code, JSON.parse(v.out)], [0, { router: "1.1.1" }]);
  assert.deepEqual(await run("version", {}), { code: 0, output: { router: "1.1.1" } });
});

// --- the environment is never read ----------------------------------------------------------------

test("an environment variable such as ANTHROPIC_API_KEY is never read", async () => {
  const src = readFileSync(WRITER, "utf8");
  assert.ok(!/process\.env|import\.meta\.env|getenv/.test(src), "writer.mjs reads the environment");
  process.env.ANTHROPIC_API_KEY = `sk-ant-env-${KEY}`;
  process.env.OPENAI_API_KEY = `sk-env-${KEY}`;
  try {
    useFetch(() => claudeReply(MINUTES));
    let r = await run("complete", req({ kind: "claude", address: CLAUDE }));
    assert.equal(calls.length, 0);
    assert.deepEqual([r.output.error.type, r.output.error.sent], ["refused", false]);
    useFetch(() => standardReply(MINUTES));
    r = await run("complete", req());
    assert.equal(calls[0].headers.get("authorization"), null);
    assert.equal(calls[0].headers.get("x-api-key"), null);
    useFetch(() => json(200, { data: [] }));
    r = await run("list", { kind: "claude", address: CLAUDE });
    assert.equal(calls.length, 0);
    assert.equal(r.output.error.type, "refused");
  } finally {
    delete process.env.ANTHROPIC_API_KEY;
    delete process.env.OPENAI_API_KEY;
  }
  const r = await cli(["complete"], JSON.stringify(req({ kind: "claude", address: "http://127.0.0.1:9/v1" })),
    { env: { ANTHROPIC_API_KEY: KEY } });
  assert.equal(r.code, 0);
  assert.deepEqual([JSON.parse(r.out).error.type, JSON.parse(r.out).error.sent], ["refused", false]);
});

// --- list -----------------------------------------------------------------------------------------

test("list, Standard: GET <address>/models, reading data[].id, with no authorization header when keyless", async () => {
  useFetch(() => json(200, { object: "list", data: [{ id: "llama3" }, { id: "qwen2.5:7b" }, { id: "gpt-oss:20b-cloud" }] }));
  let r = await run("list", { kind: "standard", address: `${STANDARD}/` });
  assert.deepEqual(r, { code: 0, output: { models: ["llama3", "qwen2.5:7b", "gpt-oss:20b-cloud"] } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `${STANDARD}/models`);
  assert.equal(calls[0].method, "GET");
  assert.equal(calls[0].headers.get("authorization"), null);
  useFetch(() => json(200, { data: [{ id: "a" }] }));
  r = await run("list", { kind: "standard", address: STANDARD, key: KEY });
  assert.equal(calls[0].headers.get("authorization"), `Bearer ${KEY}`);
});

test("list, Claude API: limit=1000 with the Anthropic headers, and a second page through after_id", async () => {
  useFetch((c, n) => json(200, n === 1
    ? { data: [{ id: "claude-a" }, { id: "claude-b" }], has_more: true, first_id: "claude-a", last_id: "claude-b" }
    : { data: [{ id: "claude-c" }], has_more: false, first_id: "claude-c", last_id: "claude-c" }));
  const r = await run("list", { kind: "claude", address: CLAUDE, key: KEY });
  assert.deepEqual(r.output, { models: ["claude-a", "claude-b", "claude-c"] });
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, `${CLAUDE}/v1/models?limit=1000`);
  assert.equal(calls[1].url, `${CLAUDE}/v1/models?limit=1000&after_id=claude-b`);
  for (const c of calls) {
    assert.equal(c.headers.get("x-api-key"), KEY);
    assert.equal(c.headers.get("anthropic-version"), "2023-06-01");
    assert.equal(c.headers.get("authorization"), null);
  }
});

test("list follows at most 10 pages", async () => {
  useFetch((c, n) => json(200, { data: [{ id: `m${n}` }], has_more: true, last_id: `m${n}` }));
  const r = await run("list", { kind: "claude", address: CLAUDE, key: KEY });
  assert.equal(calls.length, 10);
  assert.equal(r.output.models.length, 10);
});

test("list errors: a 401 is refused, a closed port is connect, a body that is not a list is other", async () => {
  useFetch(() => json(401, { error: { message: "nope" } }));
  let r = await run("list", { kind: "standard", address: STANDARD, key: KEY });
  assert.equal(r.output.error.type, "refused");
  useFetch(() => { throw fetchFailed(coded("ECONNREFUSED")); });
  r = await run("list", { kind: "standard", address: STANDARD });
  assert.equal(r.output.error.type, "connect");
  useFetch(() => new Response("<html></html>", { status: 200, headers: { "content-type": "text/html" } }));
  r = await run("list", { kind: "standard", address: STANDARD });
  assert.equal(r.output.error.type, "other");
  for (const out of [r.output]) assert.ok(!JSON.stringify(out).includes(KEY));
});
