// 与客户端 RelayPolicy 相同的取值规则；改动前先对照客户端。
export const MAX_TEXT_BYTES = 32768;
export const MAX_TTL_SECONDS = 1200;
export const MAX_DEVICES = 128;
export const MAX_NAME_UTF16 = 80;
export const PLATFORMS = ["macos", "ios", "web"];

const ID_PATTERN = /^[A-Za-z0-9_-]{8,96}$/;
const KEY_PATTERN = /^[A-Za-z0-9_-]{32,256}$/;
const encoder = new TextEncoder();

export const validID = (value) => typeof value === "string" && ID_PATTERN.test(value);
export const validAPIKey = (value) => typeof value === "string" && KEY_PATTERN.test(value);
export const utf8Length = (text) => encoder.encode(text).length;

/** 去掉首尾空白后 1–80 个 UTF-16 单元，且不含控制字符；不合规返回 null。 */
export function cleanName(value) {
  if (typeof value !== "string") return null;
  const name = value.trim();
  if (name.length === 0 || name.length > MAX_NAME_UTF16) return null;
  return /\p{Cc}/u.test(name) ? null : name;
}

export function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export const fail = (status, error) => json({ error, server_time: Date.now() }, status);

export async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** 比较两个秘密：先各自取 SHA-256，再逐字节比较，耗时与内容无关。 */
export async function secretsEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const [x, y] = await Promise.all([sha256Hex(a), sha256Hex(b)]);
  let difference = 0;
  for (let index = 0; index < x.length; index += 1) difference |= x.charCodeAt(index) ^ y.charCodeAt(index);
  return difference === 0;
}

export function randomToken(bytes = 32) {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...data)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/** 读取 JSON 对象请求体；过大、不是 JSON 或不是对象时返回 null。 */
export async function readJSONObject(request, limit = 262144) {
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > limit) return null;
  const buffer = await request.arrayBuffer();
  if (buffer.byteLength > limit) return null;
  try {
    const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(buffer));
    return value !== null && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

export const escapeHTML = (value) =>
  String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
