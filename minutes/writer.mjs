// meetingbox's outside minutes: the only Node in meetingbox. The engine runs it with an empty
// environment as `env -i <node> writer.mjs <command>`, writes one JSON object to its stdin, and reads
// one JSON object from its stdout. It never shows this script's stderr.
//
//   version   {"router": "1.1.1"}, the version of the router installed beside it
//   list      {kind, address, key?}  ->  {"models": [...]} or {"error": {"type", "message"}}
//   complete  {kind, address, key?, model, system, user, timeoutMs, maxTokens}
//             ->  {"text", "finishReason", "inputTokens", "tokenSource"}
//              or {"error": {"type", "message", "sent"}}
//
// It exits 0 even when the request failed; 2 means bad input (an address the rule refuses included),
// with the one line "bad input" on stderr. Anything it did not expect prints "writer failed" and
// exits 1. The key, the transcript and the source's reply never reach stdout (but for the reply's text
// on success), stderr or a file, and nothing is read from the environment.

import { realpathSync, writeSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import {
  complete,
  AuthError,
  ContextLengthError,
  MalformedResponseError,
  QuotaExhaustedError,
  RateLimitError,
  TimeoutError,
} from "ai-execution-router";

const ROUTER_VERSION = createRequire(import.meta.url)("ai-execution-router/package.json").version;

const KEY_RULE = /^[A-Za-z0-9._~+/=-]{1,4096}$/;
const MODEL_RULE = /^[A-Za-z0-9._:/+@-]{1,200}$/;
// A fetch that rejected with one of these, on its cause or in an AggregateError, never connected.
const CONNECT_CODES = new Set(["ECONNREFUSED", "ENOTFOUND", "EAI_AGAIN", "EHOSTUNREACH", "ENETUNREACH", "UND_ERR_CONNECT_TIMEOUT"]);
// Node's own waits: for the reply's headers, or for the next part of its body.
const TIMEOUT_CODES = new Set(["UND_ERR_HEADERS_TIMEOUT", "UND_ERR_BODY_TIMEOUT"]);
const LIST_LIMIT_MS = 10_000;
const LIST_PAGES = 10;
const MAX_INPUT = 64 * 1024 * 1024;
const MESSAGE_LIMIT = 200;

// --- the address rule (spec section 5, tests/fixtures/addresses.txt) -------------------------------

const DNS_LABEL = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const PATH_RULE = /^(?:\/[A-Za-z0-9._~!$&()*+,;=:%/-]*)?$/;
const LOCAL_HOSTS = ["127.0.0.1", "localhost", "[::1]"];

/** The host the address names, as the rule parses it, or null when the rule refuses the address. */
export function addressHost(address) {
  if (typeof address !== "string" || address.length === 0 || address.length > 2048) return null;
  let scheme;
  let rest;
  if (address.startsWith("https://")) [scheme, rest] = ["https", address.slice(8)];
  else if (address.startsWith("http://")) [scheme, rest] = ["http", address.slice(7)];
  else return null;
  const slash = rest.indexOf("/");
  const authority = slash === -1 ? rest : rest.slice(0, slash);
  if (!PATH_RULE.test(slash === -1 ? "" : rest.slice(slash))) return null;
  let host;
  let port;
  if (authority.startsWith("[")) {
    const close = authority.indexOf("]");
    if (close === -1) return null;
    host = authority.slice(0, close + 1);
    const after = authority.slice(close + 1);
    if (after !== "") {
      if (!after.startsWith(":")) return null;
      port = after.slice(1);
    }
    if (!ipv6(host.slice(1, -1))) return null;
  } else {
    const colon = authority.indexOf(":");
    host = colon === -1 ? authority : authority.slice(0, colon);
    if (colon !== -1) port = authority.slice(colon + 1);
  }
  if (port !== undefined && !(/^[1-9][0-9]{0,4}$/.test(port) && Number(port) <= 65535)) return null;
  if (scheme === "http") return LOCAL_HOSTS.includes(host) ? host : null;
  if (host.startsWith("[")) return host;
  return dnsName(host) ? host : null;
}

// Lower-case labels of letters, digits and hyphens, the last with a letter in it (so never an IPv4
// literal), at most 253 characters in all.
function dnsName(host) {
  if (host.length === 0 || host.length > 253) return false;
  const labels = host.split(".");
  return labels.every((l) => DNS_LABEL.test(l)) && /[a-z]/.test(labels[labels.length - 1]);
}

// Lower-case hex groups of 1 to 4 digits: eight of them, or at most seven around one "::".
function ipv6(text) {
  if (!/^[0-9a-f:]+$/.test(text)) return false;
  const halves = text.split("::");
  if (halves.length > 2) return false;
  const groups = halves.flatMap((h) => (h === "" ? [] : h.split(":")));
  if (!groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return false;
  return halves.length === 2 ? groups.length <= 7 : groups.length === 8;
}

// --- input ----------------------------------------------------------------------------------------

function isObject(v) { return typeof v === "object" && v !== null && !Array.isArray(v); }

function checkSource(input) {
  if (!isObject(input)) return null;
  const { kind, address, key } = input;
  if (kind !== "claude" && kind !== "standard") return null;
  if (addressHost(address) === null) return null;
  if (key !== undefined && (typeof key !== "string" || !KEY_RULE.test(key))) return null;
  return { kind, address, key };
}

function checkComplete(input) {
  const source = checkSource(input);
  if (!source) return null;
  const { model, system, user, timeoutMs, maxTokens } = input;
  if (typeof model !== "string" || !MODEL_RULE.test(model)) return null;
  if (typeof system !== "string" || typeof user !== "string" || user.length === 0) return null;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 900_000) return null;
  if (!Number.isInteger(maxTokens) || maxTokens < 1 || maxTokens > 1_000_000) return null;
  return { ...source, model, system, user, timeoutMs, maxTokens };
}

// --- the fetch guard ------------------------------------------------------------------------------

// Every code on an error, its cause and an AggregateError's errors, a few levels down.
function codesOf(err, depth = 0, found = []) {
  if (!err || typeof err !== "object" || depth > 4) return found;
  if (typeof err.code === "string") found.push(err.code);
  if (Array.isArray(err.errors)) for (const e of err.errors) codesOf(e, depth + 1, found);
  codesOf(err.cause, depth + 1, found);
  return found;
}
function connectStage(err) {
  const places = [err?.cause, ...(Array.isArray(err?.cause?.errors) ? err.cause.errors : []), ...(Array.isArray(err?.errors) ? err.errors : [])];
  return places.some((p) => p && typeof p === "object" && CONNECT_CODES.has(p.code));
}
function timedOut(err) { return codesOf(err).some((c) => TIMEOUT_CODES.has(c)); }

// Runs WORK with globalThis.fetch, whatever it is now, wrapped: every call passes redirect: "error",
// and the record says whether any call passed on reached the source, which is all "sent" means. It
// is false only when no call was passed on, or every one rejected with a connect-stage code.
async function guarded(work) {
  const original = globalThis.fetch;
  const record = { passed: 0, reached: false, timedOut: false };
  const note = (err) => {
    if (!connectStage(err)) record.reached = true;
    if (timedOut(err)) record.timedOut = true;
  };
  globalThis.fetch = function guardedFetch(resource, init) {
    record.passed += 1;
    let pending;
    try {
      pending = original(resource, { ...(init ?? {}), redirect: "error" });
    } catch (err) {
      note(err);
      throw err;
    }
    return Promise.resolve(pending).then(
      (response) => { record.reached = true; return response; },
      (err) => { note(err); throw err; },
    );
  };
  try {
    return await work(record);
  } finally {
    globalThis.fetch = original;
  }
}
function sentBy(record) { return record.passed > 0 && record.reached; }

// --- what a failure says --------------------------------------------------------------------------

// A run of SIZE characters of TEXT inside LINE: the line repeats what was sent, so it is dropped.
function shares(line, text, size) {
  if (!text || size < 1 || line.length < size) return false;
  for (let i = 0; i + size <= line.length; i++) if (text.includes(line.slice(i, i + size))) return true;
  return false;
}

// Built only from the error's name, its status and the first line of its message: control characters
// removed, the key replaced by [key], cut to 200 characters. A line that still repeats eight
// characters running of what was sent (the transcript, the context line), or of the key, is left out.
// Never the body or the cause.
function messageOf(err, input) {
  const name = typeof err?.name === "string" && /^[A-Za-z0-9_]{1,40}$/.test(err.name) ? err.name : "Error";
  const status = Number.isInteger(err?.status) && err.status >= 100 && err.status <= 599 ? err.status : undefined;
  let line = "";
  try {
    line = String(err?.message ?? "").split(/\r\n|\r|\n/)[0];
  } catch {
    line = "";
  }
  line = line.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, "");
  if (input.key) line = line.split(input.key).join("[key]");
  line = line.slice(0, MESSAGE_LIMIT);
  if (shares(line, input.user, 8) || (input.key && shares(line, input.key, Math.min(8, input.key.length)))) line = "";
  return name + (status ? ` (HTTP ${status})` : "") + (line ? `: ${line}` : "");
}

// The error's type, checked in the contract's order.
function typeOf(err, record) {
  if (err instanceof TimeoutError || err?.name === "TimeoutError" || record.timedOut || timedOut(err)) return "timeout";
  if (err instanceof QuotaExhaustedError) return "quota";
  if (err instanceof RateLimitError) return "rate";
  if (err instanceof AuthError) return "refused";
  if (err instanceof ContextLengthError) return "context";
  if (err instanceof MalformedResponseError) return "other";
  if (typeof err?.status === "number") return "http";
  return sentBy(record) ? "other" : "connect";
}

// --- complete -------------------------------------------------------------------------------------

/**
 * One outside-minutes request through the router's complete(), streamed. INPUT has passed the input
 * checks; CALL is the router's complete() unless a test gives another.
 */
export async function send(input, call = complete) {
  return guarded(async (record) => {
    // The router would refuse a call with no credential at all; a Claude API source always needs one.
    if (input.kind === "claude" && !input.key) {
      return { error: { type: "refused", message: "AuthError: the Claude API needs a key", sent: false } };
    }
    const endpoint = { provider: input.kind === "claude" ? "anthropic" : "openai-chat", baseUrl: input.address };
    // With no key, one fixed header that carries no secret passes the router's credential check, and
    // no Authorization header is sent.
    if (input.key) endpoint.apiKey = input.key;
    else endpoint.headers = { "x-meetingbox": "1" };
    try {
      const result = await call({
        model: input.model,
        input: { system: input.system, messages: [{ role: "user", content: input.user }] },
        maxTokens: input.maxTokens,
        timeoutMs: input.timeoutMs,
        endpoint,
        // Streamed, so the reply's headers come at once and Node's own wait for them never runs out;
        // the text is taken only from the router's final result.
        onDelta: () => {},
      });
      return {
        text: result.text,
        finishReason: result.finishReason ?? null,
        inputTokens: result.promptTokens,
        tokenSource: result.tokenSource,
      };
    } catch (err) {
      return { error: { type: typeOf(err, record), message: messageOf(err, input), sent: sentBy(record) } };
    }
  });
}

// --- list -----------------------------------------------------------------------------------------

function failure(name, message, status) {
  const err = new Error(message);
  err.name = name;
  if (status !== undefined) err.status = status;
  return err;
}

async function getList(url, headers, signal) {
  const response = await fetch(url, { method: "GET", headers, signal });
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw failure("HttpError", "the source answered with an error", response.status);
  }
  let body;
  try {
    body = await response.json();
  } catch (err) {
    if (err?.name === "TimeoutError" || err?.name === "AbortError" || timedOut(err)) throw err;
    throw failure("MalformedResponseError", "the answer was not JSON");
  }
  if (!isObject(body) || !Array.isArray(body.data)) throw failure("MalformedResponseError", "the answer was not a list of models");
  return body;
}

function listType(err, record) {
  if (err?.name === "TimeoutError" || err?.name === "AbortError" || record.timedOut || timedOut(err)) return "timeout";
  if (err?.status === 401 || err?.status === 403) return "refused";
  if (err?.status === 429) return "rate";
  if (typeof err?.status === "number") return "http";
  if (err?.name === "MalformedResponseError") return "other";
  return sentBy(record) ? "other" : "connect";
}

/** The source's models, from its own list call (the router only runs requests). */
async function list(input) {
  return guarded(async (record) => {
    if (input.kind === "claude" && !input.key) return { error: { type: "refused", message: "AuthError: the Claude API needs a key" } };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new DOMException("the list took too long", "TimeoutError")), LIST_LIMIT_MS);
    const base = input.address.replace(/\/+$/, "");
    const ids = (body) => body.data.map((m) => m?.id).filter((id) => typeof id === "string");
    try {
      const models = [];
      if (input.kind === "standard") {
        models.push(...ids(await getList(`${base}/models`, input.key ? { authorization: `Bearer ${input.key}` } : {}, controller.signal)));
      } else {
        const headers = { "x-api-key": input.key, "anthropic-version": "2023-06-01" };
        let after;
        for (let page = 0; page < LIST_PAGES; page++) {
          const body = await getList(`${base}/v1/models?limit=1000${after ? `&after_id=${encodeURIComponent(after)}` : ""}`, headers, controller.signal);
          const got = ids(body);
          models.push(...got);
          if (body.has_more !== true) break;
          after = typeof body.last_id === "string" && body.last_id ? body.last_id : got[got.length - 1];
          if (!after) break;
        }
      }
      return { models };
    } catch (err) {
      return { error: { type: listType(err, record), message: messageOf(err, { key: input.key, user: "" }) } };
    } finally {
      clearTimeout(timer);
    }
  });
}

// --- the commands ---------------------------------------------------------------------------------

/** Runs one command on its input: {code, output}, where code 2 means bad input and output is null. */
export async function run(command, input) {
  if (command === "version") return { code: 0, output: { router: ROUTER_VERSION } };
  if (command === "list") {
    const checked = checkSource(input);
    return checked ? { code: 0, output: await list(checked) } : { code: 2, output: null };
  }
  if (command === "complete") {
    const checked = checkComplete(input);
    return checked ? { code: 0, output: await send(checked) } : { code: 2, output: null };
  }
  return { code: 2, output: null };
}

// --- the command line -----------------------------------------------------------------------------

function writeAll(fd, text) {
  const bytes = Buffer.from(text, "utf8");
  let done = 0;
  while (done < bytes.length) done += writeSync(fd, bytes, done, bytes.length - done);
}

// One fixed line, never the error, which may quote the key or the transcript.
function writerFailed() {
  try { writeAll(2, "writer failed\n"); } catch { /* nothing more can be said */ }
  process.exit(1);
}

async function readInput() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_INPUT) return undefined;
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return undefined;   // never the parser's message: it quotes stdin
  }
}

async function main() {
  process.on("uncaughtException", writerFailed);
  process.on("unhandledRejection", writerFailed);
  const command = process.argv[2];
  // version reads nothing: its stdin is whatever the engine's is.
  const input = command === "version" ? {} : await readInput();
  const { code, output } = input === undefined ? { code: 2, output: null } : await run(command, input);
  if (code === 0) writeAll(1, `${JSON.stringify(output)}\n`);
  else writeAll(2, "bad input\n");
  process.exit(code);
}

function isMain() {
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}
if (isMain()) main().catch(writerFailed);
