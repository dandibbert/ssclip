import { BARK_ERROR_STATUS, checkBarkHost, exceedsAPNSBudget, pushToBark } from "./bark.js";
import { publicDevice } from "./db.js";
import {
  MAX_DEVICES, MAX_TEXT_BYTES, MAX_TTL_SECONDS, PLATFORMS,
  cleanName, fail, json, readJSONObject, sha256Hex, utf8Length, validID,
} from "./util.js";

// 客户端一次响应最多接受 1,000,000 字节，轮询结果要留出余量。
const POLL_RESPONSE_BUDGET = 900_000;
const POLL_MAX_MESSAGES = 64;
const MAX_PENDING_PER_TARGET = 200;
const LAST_SEEN_RESOLUTION_MS = 60_000;
const IN_PROGRESS_WINDOW_MS = 60_000;

const routes = {
  "POST register": register,
  "GET devices": devices,
  "GET poll": poll,
  "GET status": status,
  "POST ack": ack,
  "POST send": send,
};

export async function handleAPI(request, env, endpoint, context) {
  const handler = routes[`${request.method} ${endpoint}`];
  if (handler) return handler(request, env, context);
  const known = Object.keys(routes).some((route) => route.endsWith(` ${endpoint}`));
  return known ? fail(405, "method_not_allowed") : fail(404, "not_found");
}

const findDevice = (db, id) => db.prepare(`SELECT * FROM devices WHERE id = ?1`).bind(id).first();

async function register(request, env) {
  const body = await readJSONObject(request);
  if (!body) return fail(400, "invalid_request");
  const name = cleanName(body.name);
  if (!validID(body.id) || !name || !PLATFORMS.includes(body.platform)) return fail(400, "invalid_device");
  if (body.can_receive !== undefined && typeof body.can_receive !== "boolean") return fail(400, "invalid_device");
  const canReceive = body.can_receive === false ? 0 : 1;
  const now = Date.now();
  const db = env.DB;

  const existing = await findDevice(db, body.id);
  // Bark 接收端由管理端创建，客户端不能用同一个编号把它改成普通设备。
  if (existing && existing.transport !== "queue") return fail(409, "device_id_reserved");
  if (!existing) {
    const { total } = await db.prepare(`SELECT COUNT(*) AS total FROM devices`).first();
    if (total >= MAX_DEVICES) return fail(409, "device_limit_reached");
  }
  await db
    .prepare(
      `INSERT INTO devices (id, name, platform, transport, can_receive, last_seen_at, created_at)
       VALUES (?1, ?2, ?3, 'queue', ?4, ?5, ?5)
       ON CONFLICT (id) DO UPDATE SET
         name = excluded.name, platform = excluded.platform,
         can_receive = excluded.can_receive, last_seen_at = excluded.last_seen_at`,
    )
    .bind(body.id, name, body.platform, canReceive, now)
    .run();
  return json({ device: publicDevice(await findDevice(db, body.id)), server_time: now });
}

async function devices(request, env) {
  const { results } = await env.DB
    .prepare(`SELECT * FROM devices ORDER BY name, id LIMIT ?1`)
    .bind(MAX_DEVICES)
    .all();
  return json({ devices: results.map(publicDevice), server_time: Date.now() });
}

/** 轮询和状态查询都要求目标是已注册的队列设备，并顺带刷新它的在线时间。 */
async function pollingDevice(request, env) {
  const target = new URL(request.url).searchParams.get("target");
  if (!validID(target)) return { error: fail(400, "invalid_target") };
  const device = await findDevice(env.DB, target);
  if (!device || device.transport !== "queue") return { error: fail(404, "unknown_device") };
  const now = Date.now();
  if (now - device.last_seen_at >= LAST_SEEN_RESOLUTION_MS) {
    await env.DB.prepare(`UPDATE devices SET last_seen_at = ?1 WHERE id = ?2`).bind(now, target).run();
    device.last_seen_at = now;
  }
  return { device, now };
}

async function poll(request, env) {
  const { device, now, error } = await pollingDevice(request, env);
  if (error) return error;
  const { results } = await env.DB
    .prepare(
      `SELECT id, source, target, text, created_at, expires_at FROM messages
       WHERE target = ?1 AND state = 'pending' AND delivery IS NULL AND expires_at > ?2 AND text != ''
       ORDER BY created_at, rowid LIMIT ?3`,
    )
    .bind(device.id, now, POLL_MAX_MESSAGES)
    .all();
  const messages = [];
  let size = 0;
  for (const message of results) {
    size += utf8Length(JSON.stringify(message)) + 1;
    if (size > POLL_RESPONSE_BUDGET) break;
    messages.push(message);
  }
  return json({ messages, server_time: now });
}

async function status(request, env) {
  const { device, now, error } = await pollingDevice(request, env);
  if (error) return error;
  const { total } = await env.DB
    .prepare(
      `SELECT COUNT(*) AS total FROM messages
       WHERE target = ?1 AND state = 'pending' AND delivery IS NULL AND expires_at > ?2 AND text != ''`,
    )
    .bind(device.id, now)
    .first();
  return json({ device: publicDevice(device), pending: total, server_time: now });
}

async function ack(request, env) {
  const body = await readJSONObject(request);
  if (!body || !validID(body.id) || !validID(body.target)) return fail(400, "invalid_request");
  const now = Date.now();
  const message = await env.DB
    .prepare(`SELECT state, expires_at FROM messages WHERE id = ?1 AND target = ?2`)
    .bind(body.id, body.target)
    .first();
  if (!message) return fail(404, "unknown_message");
  if (message.state !== "acknowledged") {
    if (message.expires_at <= now) return fail(410, "message_expired");
    // 确认后立即清除正文。
    await env.DB
      .prepare(`UPDATE messages SET state = 'acknowledged', text = '', acked_at = ?1 WHERE id = ?2 AND target = ?3`)
      .bind(now, body.id, body.target)
      .run();
  }
  return json({ id: body.id, state: "acknowledged", server_time: now });
}

function sendResult(message, now) {
  const body = {
    id: message.id,
    state: message.state,
    target: message.target,
    created_at: message.created_at,
    expires_at: message.expires_at,
    server_time: now,
  };
  if (message.delivery === "submitted") body.delivery = "submitted";
  return json(body);
}

async function send(request, env, context) {
  const body = await readJSONObject(request);
  if (!body) return fail(400, "invalid_request");
  const { id, source, target, text } = body;
  if (!validID(id) || !validID(source) || !validID(target) || source === target) return fail(400, "invalid_request");
  if (typeof text !== "string" || text.length === 0) return fail(400, "empty_text");
  if (utf8Length(text) > MAX_TEXT_BYTES) return fail(413, "text_too_large");
  let ttl = body.ttl_seconds ?? MAX_TTL_SECONDS;
  if (typeof ttl !== "number" || !Number.isFinite(ttl) || ttl < 1) return fail(400, "invalid_ttl");
  ttl = Math.min(Math.floor(ttl), MAX_TTL_SECONDS);

  const db = env.DB;
  const now = Date.now();
  const digest = await sha256Hex(`${source}\n${target}\n${text}`);

  // 同一个编号重复提交：内容相同就返回原结果，不重复入队也不重复推送。
  const existing = await db.prepare(`SELECT * FROM messages WHERE id = ?1`).bind(id).first();
  if (existing) return repeatedSend(existing, digest, now);

  const [sender, receiver] = await Promise.all([findDevice(db, source), findDevice(db, target)]);
  if (!sender) return fail(409, "unknown_source");
  if (!receiver) return fail(404, "unknown_target");
  if (receiver.can_receive !== 1) return fail(409, "target_cannot_receive");

  const isBark = receiver.transport === "bark";
  if (isBark) {
    if (!receiver.bark_server) return fail(BARK_ERROR_STATUS.bark_not_configured, "bark_not_configured");
    if (!receiver.bark_key) return fail(BARK_ERROR_STATUS.bark_credential_unavailable, "bark_credential_unavailable");
    if (exceedsAPNSBudget(text)) return fail(BARK_ERROR_STATUS.bark_text_too_large, "bark_text_too_large");
  } else {
    const { total } = await db
      .prepare(`SELECT COUNT(*) AS total FROM messages WHERE target = ?1 AND state = 'pending' AND expires_at > ?2`)
      .bind(target, now)
      .first();
    if (total >= MAX_PENDING_PER_TARGET) return fail(429, "queue_full");
  }

  const message = {
    id, source, target, text, digest,
    created_at: now,
    expires_at: now + ttl * 1000,
    state: "pending",
    delivery: isBark ? "in_progress" : null,
  };
  const inserted = await db
    .prepare(
      `INSERT OR IGNORE INTO messages
         (id, source, target, text, digest, created_at, expires_at, state, delivery, delivery_started_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', ?8, ?9)`,
    )
    .bind(id, source, target, text, digest, message.created_at, message.expires_at, message.delivery, isBark ? now : null)
    .run();
  if (inserted.meta.changes === 0) {
    // 并发的同编号请求抢先写入了。
    return repeatedSend(await db.prepare(`SELECT * FROM messages WHERE id = ?1`).bind(id).first(), digest, now);
  }
  if (now - sender.last_seen_at >= LAST_SEEN_RESOLUTION_MS) {
    context?.waitUntil(db.prepare(`UPDATE devices SET last_seen_at = ?1 WHERE id = ?2`).bind(now, source).run());
  }
  if (!isBark) return sendResult(message, now);

  const error = await deliverToBark(env, message, receiver);
  if (error) return fail(BARK_ERROR_STATUS[error], error);
  return sendResult({ ...message, delivery: "submitted" }, now);
}

function repeatedSend(existing, digest, now) {
  if (existing.digest !== digest) return fail(409, "message_id_conflict");
  if (existing.delivery === null || existing.delivery === "submitted") return sendResult(existing, now);
  if (existing.delivery === "in_progress") {
    const stillRunning = now - (existing.delivery_started_at ?? 0) < IN_PROGRESS_WINDOW_MS;
    const error = stillRunning ? "bark_delivery_in_progress" : "bark_delivery_unknown";
    return fail(BARK_ERROR_STATUS[error], error);
  }
  const error = existing.delivery_error ?? "bark_delivery_failed";
  return fail(BARK_ERROR_STATUS[error] ?? 502, error);
}

/**
 * 把一条已入库、delivery 为 in_progress 的消息推给 Bark，并记录结果。
 * 成功后清除正文；失败时保留正文到过期，供管理端重试。返回错误码或 null。
 */
export async function deliverToBark(env, message, receiver, fetcher = fetch) {
  const hostError = await checkBarkHost(receiver.bark_server, fetcher);
  const outcome = hostError
    ? { delivery: "failed", error: hostError }
    : await pushToBark({ server: receiver.bark_server, key: receiver.bark_key, text: message.text }, fetcher);
  await env.DB
    .prepare(
      `UPDATE messages SET delivery = ?1, delivery_error = ?2,
         text = CASE WHEN ?1 = 'submitted' THEN '' ELSE text END
       WHERE id = ?3`,
    )
    .bind(outcome.delivery, outcome.error, message.id)
    .run();
  return outcome.error;
}
