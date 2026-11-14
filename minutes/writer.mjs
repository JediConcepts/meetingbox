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
// It exits 0 even when the request failed; 2 means bad input (an address the rule or the URL parser
// refuses included), with the one line "bad input" on stderr; 3 means the router could not be loaded,
// so nothing was sent, with the one line "writer failed". Anything else it did not expect prints
// "writer failed" and exits 1. The key, the transcript and the source's reply never reach stdout (but
// for the reply's text on success, with any copy of a key of 8 or more characters in it replaced by
// [key], and a finish reason and token count only as values it knows), stderr or a file, and nothing
// is read from the environment.

import dc from "node:diagnostics_channel";
import { realpathSync, writeSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const KEY_RULE = /^[A-Za-z0-9._~+/=-]{1,4096}$/;
const MODEL_RULE = /^[A-Za-z0-9._:/+@-]{1,200}$/;
// Node's own fetch publishes these for each connection it tries: connected once one is made (for https,
// once its first handshake is done), connectError when one could not be. A bad port, which fetch
// refuses before connecting, publishes neither.
const CONNECTED = "undici:client:connected";
const CONNECT_ERROR = "undici:client:connectError";
// The codes of a failure to connect, on a rejection's cause or in an AggregateError: refused, no such
// host, no route, a connect timeout, or a certificate the handshake refused (Node's documented X509
// codes, less OUT_OF_MEM, and the altname check). A code alone proves nothing: over TLS 1.2 a source can
// renegotiate after the request was written, and a certificate that has expired by then fails with
// CERT_HAS_EXPIRED. So a code counts only beside the channels' evidence (see sentBy).
const CONNECT_CODES = new Set([
  "ECONNREFUSED", "ENOTFOUND", "EAI_AGAIN", "EHOSTUNREACH", "ENETUNREACH", "UND_ERR_CONNECT_TIMEOUT",
  "UNABLE_TO_GET_ISSUER_CERT", "UNABLE_TO_GET_CRL", "UNABLE_TO_DECRYPT_CERT_SIGNATURE", "UNABLE_TO_DECRYPT_CRL_SIGNATURE",
  "UNABLE_TO_DECODE_ISSUER_PUBLIC_KEY", "CERT_SIGNATURE_FAILURE", "CRL_SIGNATURE_FAILURE", "CERT_NOT_YET_VALID",
  "CERT_HAS_EXPIRED", "CRL_NOT_YET_VALID", "CRL_HAS_EXPIRED", "ERROR_IN_CERT_NOT_BEFORE_FIELD",
  "ERROR_IN_CERT_NOT_AFTER_FIELD", "ERROR_IN_CRL_LAST_UPDATE_FIELD", "ERROR_IN_CRL_NEXT_UPDATE_FIELD",
  "DEPTH_ZERO_SELF_SIGNED_CERT", "SELF_SIGNED_CERT_IN_CHAIN", "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
  "UNABLE_TO_VERIFY_LEAF_SIGNATURE", "CERT_CHAIN_TOO_LONG", "CERT_REVOKED", "INVALID_CA", "PATH_LENGTH_EXCEEDED",
  "INVALID_PURPOSE", "CERT_UNTRUSTED", "CERT_REJECTED", "HOSTNAME_MISMATCH", "ERR_TLS_CERT_ALTNAME_INVALID",
]);
// Node's own waits: for the reply's headers, or for the next part of its body.
const TIMEOUT_CODES = new Set(["UND_ERR_HEADERS_TIMEOUT", "UND_ERR_BODY_TIMEOUT"]);
// The Fetch standard's bad ports: fetch refuses them before connecting, so they are answered here, at
// once, as not sent.
export const BAD_PORTS = new Set(["1", "7", "9", "11", "13", "15", "17", "19", "20", "21", "22", "23", "25", "37", "42", "43",
  "53", "69", "77", "79", "87", "95", "101", "102", "103", "104", "109", "110", "111", "113", "115", "117", "119", "123",
  "135", "137", "139", "143", "161", "179", "389", "427", "465", "512", "513", "514", "515", "526", "530", "531", "532",
  "540", "548", "554", "556", "563", "587", "601", "636", "989", "990", "993", "995", "1719", "1720", "1723", "2049",
  "3659", "4045", "4190", "5060", "5061", "6000", "6566", "6665", "6666", "6667", "6668", "6669", "6679", "6697", "10080"]);
// The finish reasons the two wire formats name. Any other value is the source's own text, which could be
// anything, the key included, so it is passed on as null.
const FINISH_REASONS = new Set(["stop", "length", "max_tokens", "end_turn", "stop_sequence", "tool_use", "tool_calls",
  "function_call", "content_filter", "model_context_window_exceeded", "pause_turn", "refusal"]);
const TOKEN_SOURCES = new Set(["reported", "partial", "unreported"]);
// A key shorter than this (a placeholder such as "ollama") is not looked for in what the source sends
// back: it would turn ordinary words into [key] and drop ordinary model ids.
const SCRUB_MIN = 8;
// The list's own limit, over every page; a test may shorten it.
export const limits = { listMs: 10_000 };
const LIST_PAGES = 10;
const MAX_INPUT = 64 * 1024 * 1024;

// --- the router, loaded only when needed --------------------------------------------------------

let router = null;
let routerVersion = null;
// Imported, not named in a static import, so that a router that is missing or whose entry throws is an
// error main can catch, after its handlers are installed, and answer with status 3.
async function loadRouter() {
  if (!router) {
    const loaded = await import("ai-execution-router");
    routerVersion = createRequire(import.meta.url)("ai-execution-router/package.json").version;
    router = loaded;
  }
  return router;
}

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

// Lower-case labels of letters, digits and hyphens, at most 253 characters in all, whose last label
// is not a number to the URL parser: it has a letter, and is not 0x followed only by hex digits.
function dnsName(host) {
  if (host.length === 0 || host.length > 253) return false;
  const labels = host.split(".");
  const last = labels[labels.length - 1];
  return labels.every((l) => DNS_LABEL.test(l)) && /[a-z]/.test(last) && !/^0x[0-9a-f]*$/.test(last);
}

// Lower-case hex groups of 1 to 4 digits, eight of them or at most seven around one "::", written as
// the URL parser writes them: no leading zero, and the first longest run of two or more zero groups,
// and only that, as "::".
function ipv6(text) {
  if (!/^[0-9a-f:]+$/.test(text)) return false;
  const halves = text.split("::");
  if (halves.length > 2) return false;
  const parts = halves.map((h) => (h === "" ? [] : h.split(":")));
  const groups = parts.flat();
  if (!groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return false;
  if (halves.length === 2 ? groups.length > 7 : groups.length !== 8) return false;
  const pieces = halves.length === 2 ? [...parts[0], ...Array(8 - groups.length).fill("0"), ...parts[1]] : groups;
  return canonical(pieces.map((g) => parseInt(g, 16))) === text;
}
function canonical(pieces) {
  let start = -1;
  let length = 0;
  for (let i = 0; i < 8;) {
    if (pieces[i] !== 0) { i++; continue; }
    let j = i;
    while (j < 8 && pieces[j] === 0) j++;
    if (j - i > length && j - i >= 2) [start, length] = [i, j - i];
    i = j;
  }
  const hex = pieces.map((p) => p.toString(16));
  if (start === -1) return hex.join(":");
  return `${hex.slice(0, start).join(":")}::${hex.slice(start + length).join(":")}`;
}

// --- input ----------------------------------------------------------------------------------------

function isObject(v) { return typeof v === "object" && v !== null && !Array.isArray(v); }

function checkSource(input) {
  if (!isObject(input)) return null;
  const { kind, address, key } = input;
  if (kind !== "claude" && kind !== "standard") return null;
  // An address the rule accepts and the URL parser refuses (a label such as xn--a) is refused too.
  if (addressHost(address) === null || !URL.canParse(address)) return null;
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

// The address's port is one fetch refuses.
function badPort(address) { return BAD_PORTS.has(new URL(address).port); }

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

// Runs WORK with globalThis.fetch, whatever it is now, wrapped so that every call passes redirect:
// "error", and with a record of what happened, from the calls and from Node's own channels. "Not sent"
// needs evidence that no connection was ever made (see sentBy).
async function guarded(work) {
  const original = globalThis.fetch;
  const record = { passed: 0, connected: false, connectErrors: 0, otherwise: false, timedOut: false };
  const onConnected = () => { record.connected = true; };
  const onConnectError = () => { record.connectErrors += 1; };
  // A call that answered, or rejected with no connect-stage code, is "otherwise".
  const note = (err) => {
    if (!connectStage(err)) record.otherwise = true;
    if (timedOut(err)) record.timedOut = true;
  };
  dc.subscribe(CONNECTED, onConnected);
  dc.subscribe(CONNECT_ERROR, onConnectError);
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
      (response) => { record.otherwise = true; return response; },
      (err) => { note(err); throw err; },
    );
  };
  try {
    return await work(record);
  } finally {
    globalThis.fetch = original;
    dc.unsubscribe(CONNECTED, onConnected);
    dc.unsubscribe(CONNECT_ERROR, onConnectError);
  }
}
// Not sent when no call was passed on: the router's one fetch is globalThis.fetch, looked up at each
// call. Otherwise not sent only when all of these hold: connected was never published, connectError
// was at least once, and every call passed on rejected with a connect-stage code. Anything else is
// sent, a call for which neither channel fired included.
function sentBy(record) {
  if (record.passed === 0) return false;
  return record.connected || record.connectErrors === 0 || record.otherwise;
}

// --- what a failure says --------------------------------------------------------------------------

// Only the error's name and, when it has one, its status: never any text the source sent, which could
// carry the key or the transcript in any spelling. The engine reads only the status.
function messageOf(err) {
  const name = typeof err?.name === "string" && /^[A-Za-z0-9_]{1,40}$/.test(err.name) ? err.name : "Error";
  const status = Number.isInteger(err?.status) && err.status >= 100 && err.status <= 599 ? err.status : undefined;
  return name + (status ? ` (HTTP ${status})` : "");
}

// The error's type, checked in the contract's order.
function typeOf(err, record, r) {
  if (err instanceof r.TimeoutError || err?.name === "TimeoutError" || record.timedOut || timedOut(err)) return "timeout";
  if (err instanceof r.QuotaExhaustedError) return "quota";
  if (err instanceof r.RateLimitError) return "rate";
  if (err instanceof r.AuthError) return "refused";
  if (err instanceof r.ContextLengthError) return "context";
  if (err instanceof r.MalformedResponseError) return "other";
  if (typeof err?.status === "number") return "http";
  return sentBy(record) ? "other" : "connect";
}

// A key the source handed back is never passed on (a key under SCRUB_MIN characters is not looked for).
function scrubbed(key) { return typeof key === "string" && key.length >= SCRUB_MIN; }
function scrub(text, key) { return scrubbed(key) ? text.split(key).join("[key]") : text; }
function holdsKey(text, key) { return scrubbed(key) && text.includes(key); }

// The result's other fields, each only as a value writer.mjs knows: the router copies them from the
// source's reply as given.
function finishOf(value) { return FINISH_REASONS.has(value) ? value : null; }
function tokensOf(value) { return Number.isSafeInteger(value) && value >= 0 ? value : null; }
function tokenSourceOf(value, tokens) { return tokens !== null && TOKEN_SOURCES.has(value) ? value : "unreported"; }

// --- complete -------------------------------------------------------------------------------------

/**
 * One outside-minutes request through the router's complete(), streamed. INPUT has passed the input
 * checks; CALL is the router's complete() unless a test gives another.
 */
export async function send(input, call) {
  const r = await loadRouter();
  const ask = call ?? r.complete;
  return guarded(async (record) => {
    // The router would refuse a call with no credential at all; a Claude API source always needs one.
    if (input.kind === "claude" && !input.key) return { error: { type: "refused", message: "AuthError", sent: false } };
    if (badPort(input.address)) return { error: { type: "connect", message: "BadPortError", sent: false } };
    const endpoint = { provider: input.kind === "claude" ? "anthropic" : "openai-chat", baseUrl: input.address };
    // With no key, one fixed header that carries no secret passes the router's credential check, and
    // no Authorization header is sent.
    if (input.key) endpoint.apiKey = input.key;
    else endpoint.headers = { "x-meetingbox": "1" };
    try {
      const result = await ask({
        model: input.model,
        input: { system: input.system, messages: [{ role: "user", content: input.user }] },
        maxTokens: input.maxTokens,
        timeoutMs: input.timeoutMs,
        endpoint,
        // Streamed, so the reply's headers come at once and Node's own wait for them never runs out;
        // the text is taken only from the router's final result.
        onDelta: () => {},
      });
      const inputTokens = tokensOf(result.promptTokens);
      return {
        text: scrub(result.text, input.key),
        finishReason: finishOf(result.finishReason),
        inputTokens,
        tokenSource: tokenSourceOf(result.tokenSource, inputTokens),
      };
    } catch (err) {
      return { error: { type: typeOf(err, record, r), message: messageOf(err), sent: sentBy(record) } };
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
    if (input.kind === "claude" && !input.key) return { error: { type: "refused", message: "AuthError" } };
    if (badPort(input.address)) return { error: { type: "connect", message: "BadPortError" } };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new DOMException("the list took too long", "TimeoutError")), limits.listMs);
    const base = input.address.replace(/\/+$/, "");
    // An id holding the key is dropped: the source handed the key back.
    const ids = (body) => body.data.map((m) => m?.id).filter((id) => typeof id === "string" && !holdsKey(id, input.key));
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
      return { error: { type: listType(err, record), message: messageOf(err) } };
    } finally {
      clearTimeout(timer);
    }
  });
}

// --- the commands ---------------------------------------------------------------------------------

/** Runs one command on its input: {code, output}, where code 2 means bad input and output is null. */
export async function run(command, input) {
  if (command === "version") {
    await loadRouter();
    return { code: 0, output: { router: routerVersion } };
  }
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
function writerFailed(status = 1) {
  try { writeAll(2, "writer failed\n"); } catch { /* nothing more can be said */ }
  process.exit(status);
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
  process.on("uncaughtException", () => writerFailed(1));
  process.on("unhandledRejection", () => writerFailed(1));
  // The router first, for every command: without it nothing can have been sent.
  try {
    await loadRouter();
  } catch {
    writerFailed(3);
  }
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
if (isMain()) main().catch(() => writerFailed(1));
