// 通过 Bark 把文本推到 iPhone / iPad。错误码与客户端 RelayServiceError 一一对应。

export const DEFAULT_BARK_SERVER = "https://api.day.app";
const APNS_PAYLOAD_LIMIT = 4096;
// 通知里除正文外的固定字段（aps 结构、分组、自动复制标记等）预留的字节数。
const APNS_METADATA_RESERVE = 512;
const DNS_TIMEOUT_MS = 8000;
const PUSH_TIMEOUT_MS = 8000;

export const BARK_ERROR_STATUS = {
  bark_text_too_large: 413,
  bark_delivery_in_progress: 409,
  bark_rejected: 502,
  bark_delivery_failed: 502,
  bark_delivery_unknown: 502,
  bark_dns_unavailable: 503,
  bark_private_address_blocked: 503,
  bark_not_configured: 503,
  bark_credential_unavailable: 503,
};

/**
 * 接受 `https://api.day.app/<key>/`、单独的 key，或“服务器地址 + key”。
 * 返回 { server, key }；格式不对返回 null。
 */
export function parseBarkTarget(rawServer, rawKey) {
  let server = (rawServer ?? "").trim();
  let key = (rawKey ?? "").trim();
  if (/^https?:\/\//i.test(key)) {
    try {
      const url = new URL(key);
      const segments = url.pathname.split("/").filter(Boolean);
      if (segments.length === 0) return null;
      key = segments[segments.length - 1];
      segments.pop();
      server = url.origin + (segments.length ? "/" + segments.join("/") : "");
    } catch {
      return null;
    }
  }
  if (!server) server = DEFAULT_BARK_SERVER;
  let url;
  try {
    url = new URL(server);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) return null;
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(key)) return null;
  return { server: url.origin + url.pathname.replace(/\/+$/, ""), key };
}

/** 估算通知总大小：正文按 APNs JSON 转义后的字节数计，再加固定字段的预留。 */
export function exceedsAPNSBudget(text) {
  let bytes = 0;
  for (const character of text) {
    const code = character.codePointAt(0);
    if (character === '"' || character === "\\") bytes += 2;
    else if (code < 0x20 || character === "<" || character === ">" || character === "&") bytes += 6;
    else if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code < 0x10000) bytes += 3;
    else bytes += 4;
  }
  return bytes + APNS_METADATA_RESERVE > APNS_PAYLOAD_LIMIT;
}

function isPrivateIPv4(address) {
  const parts = address.split(".").map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return true;
  const [a, b] = parts;
  return (
    a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 0) ||
    (a === 198 && (b === 18 || b === 19))
  );
}

function isPrivateIPv6(address) {
  const value = address.toLowerCase();
  if (value === "::" || value === "::1") return true;
  const mapped = value.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return isPrivateIPv4(mapped[1]);
  return /^(fc|fd|fe[89ab]|ff)/.test(value) || value.startsWith("::ffff:") || value.startsWith("64:ff9b:");
}

async function resolve(hostname, type, signal, fetcher) {
  const response = await fetcher(
    `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(hostname)}&type=${type}`,
    { headers: { accept: "application/dns-json" }, signal },
  );
  if (!response.ok) throw new Error("dns query failed");
  const body = await response.json();
  const wanted = type === "A" ? 1 : 28;
  return (body.Answer ?? []).filter((answer) => answer.type === wanted).map((answer) => answer.data);
}

/** 自建 Bark 的域名必须能解析，且不能指向内网。返回错误码或 null。 */
export async function checkBarkHost(server, fetcher = fetch) {
  const hostname = new URL(server).hostname;
  if (hostname.startsWith("[")) {
    return isPrivateIPv6(hostname.slice(1, -1)) ? "bark_private_address_blocked" : null;
  }
  if (/^\d+\.\d+\.\d+\.\d+$/.test(hostname)) {
    return isPrivateIPv4(hostname) ? "bark_private_address_blocked" : null;
  }
  if (hostname === "localhost" || hostname.endsWith(".localhost") || hostname.endsWith(".local") || !hostname.includes(".")) {
    return "bark_private_address_blocked";
  }
  try {
    const signal = AbortSignal.timeout(DNS_TIMEOUT_MS);
    const [v4, v6] = await Promise.all([
      resolve(hostname, "A", signal, fetcher),
      resolve(hostname, "AAAA", signal, fetcher),
    ]);
    if (v4.length + v6.length === 0) return "bark_dns_unavailable";
    if (v4.some(isPrivateIPv4) || v6.some(isPrivateIPv6)) return "bark_private_address_blocked";
    return null;
  } catch {
    return "bark_dns_unavailable";
  }
}

/**
 * 发出一次推送。返回 { delivery, error }：
 * delivery 为 submitted / rejected / failed / unknown，error 为对应的协议错误码（成功时为 null）。
 * 不带标题，这样 Bark 的“自动复制”复制到的就是正文本身。
 */
export async function pushToBark({ server, key, text }, fetcher = fetch) {
  let response;
  try {
    response = await fetcher(`${server}/push`, {
      method: "POST",
      headers: { "content-type": "application/json; charset=utf-8" },
      body: JSON.stringify({ device_key: key, body: text, group: "SSClip", autoCopy: "1" }),
      redirect: "manual",
      signal: AbortSignal.timeout(PUSH_TIMEOUT_MS),
    });
  } catch {
    // 超时或连接中断：请求可能已经到达 Bark，结果不明。
    return { delivery: "unknown", error: "bark_delivery_unknown" };
  }
  let body = null;
  try {
    body = await response.json();
  } catch {
    body = null;
  }
  const code = typeof body?.code === "number" ? body.code : response.status;
  const message = typeof body?.message === "string" ? body.message : "";
  if (response.status === 200 && code === 200) return { delivery: "submitted", error: null };
  if (response.status === 413 || code === 413 || /too large|payload/i.test(message)) {
    return { delivery: "rejected", error: "bark_text_too_large" };
  }
  if (response.status >= 500 || code >= 500) return { delivery: "failed", error: "bark_delivery_failed" };
  return { delivery: "rejected", error: "bark_rejected" };
}
