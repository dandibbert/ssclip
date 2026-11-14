import { randomToken, validAPIKey } from "./util.js";

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS devices (
     id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     platform TEXT NOT NULL,
     transport TEXT NOT NULL DEFAULT 'queue',
     can_receive INTEGER NOT NULL DEFAULT 1,
     last_seen_at INTEGER NOT NULL,
     created_at INTEGER NOT NULL,
     bark_server TEXT,
     bark_key TEXT
   )`,
  `CREATE TABLE IF NOT EXISTS messages (
     id TEXT PRIMARY KEY,
     source TEXT NOT NULL,
     target TEXT NOT NULL,
     text TEXT NOT NULL,
     digest TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     expires_at INTEGER NOT NULL,
     state TEXT NOT NULL,
     delivery TEXT,
     delivery_error TEXT,
     delivery_started_at INTEGER,
     acked_at INTEGER
   )`,
  `CREATE INDEX IF NOT EXISTS messages_by_target ON messages (target, state, created_at)`,
  `CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, csrf TEXT NOT NULL, expires_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS login_failures (at INTEGER NOT NULL)`,
];

// 每个 isolate 只建一次表、每分钟最多清理一次，轮询请求不为此多付写入。
const ready = new WeakMap();
const lastCleanup = new WeakMap();

export async function ensureSchema(db) {
  if (!ready.has(db)) {
    ready.set(db, db.batch(SCHEMA.map((statement) => db.prepare(statement))));
  }
  try {
    await ready.get(db);
  } catch (error) {
    ready.delete(db);
    throw error;
  }
}

/** 过期正文立即清空，结束超过一天的记录整行删除。 */
export async function cleanup(db, now = Date.now(), force = false) {
  if (!force && now - (lastCleanup.get(db) ?? 0) < 60_000) return;
  lastCleanup.set(db, now);
  await db.batch([
    db.prepare(`UPDATE messages SET text = '' WHERE expires_at <= ?1 AND text != ''`).bind(now),
    db.prepare(`DELETE FROM messages WHERE expires_at <= ?1`).bind(now - 86_400_000),
    db.prepare(`DELETE FROM sessions WHERE expires_at <= ?1`).bind(now),
    db.prepare(`DELETE FROM login_failures WHERE at <= ?1`).bind(now - 900_000),
  ]);
}

export async function getSetting(db, key) {
  const row = await db.prepare(`SELECT value FROM settings WHERE key = ?1`).bind(key).first();
  return row?.value ?? null;
}

export async function setSetting(db, key, value) {
  await db
    .prepare(`INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET value = excluded.value`)
    .bind(key, value)
    .run();
}

/** 环境变量 API_KEY 优先（方便沿用旧 Key）；否则用数据库里的，首次使用时生成。 */
export async function currentAPIKey(env, { create = false } = {}) {
  if (validAPIKey(env.API_KEY)) return env.API_KEY;
  const stored = await getSetting(env.DB, "api_key");
  if (stored || !create) return stored;
  const generated = randomToken(32);
  await env.DB.prepare(`INSERT OR IGNORE INTO settings (key, value) VALUES ('api_key', ?1)`).bind(generated).run();
  return getSetting(env.DB, "api_key");
}

/** 客户端能看到的设备字段；Bark 的服务器地址和 device key 从不外露。 */
export function publicDevice(row) {
  return {
    id: row.id,
    name: row.name,
    platform: row.platform,
    transport: row.transport,
    can_receive: row.can_receive === 1,
    last_seen_at: row.last_seen_at,
  };
}
