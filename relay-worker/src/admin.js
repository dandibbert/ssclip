import { deliverToBark } from "./api.js";
import { BARK_ERROR_STATUS, DEFAULT_BARK_SERVER, parseBarkTarget } from "./bark.js";
import { currentAPIKey, setSetting } from "./db.js";
import { hub } from "./hub.js";
import {
  MAX_DEVICES, cleanName, escapeHTML, randomToken, secretsEqual, sha256Hex, validAPIKey, validID,
} from "./util.js";

const SESSION_COOKIE = "ssclip_admin";
const SESSION_TTL_MS = 12 * 60 * 60 * 1000;
const MAX_LOGIN_FAILURES = 10;

const html = (body, status = 200, headers = {}) =>
  new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      ...headers,
    },
  });

// 表单提交后回到管理页；API 路径从不重定向。
const back = (notice, headers = {}) =>
  new Response(null, { status: 303, headers: { location: `/admin?notice=${encodeURIComponent(notice)}`, ...headers } });

async function session(request, env) {
  const match = (request.headers.get("cookie") ?? "").match(new RegExp(`(?:^|;\\s*)${SESSION_COOKIE}=([A-Za-z0-9_-]+)`));
  if (!match) return null;
  const row = await env.DB
    .prepare(`SELECT csrf FROM sessions WHERE token_hash = ?1 AND expires_at > ?2`)
    .bind(await sha256Hex(match[1]), Date.now())
    .first();
  return row ? { csrf: row.csrf, token: match[1] } : null;
}

export async function handleAdmin(request, env, path) {
  const url = new URL(request.url);
  if (!env.ADMIN_PASSWORD) {
    return html(page("SSClip 中继", `<p class="warn">还没有设置管理密码。运行 <code>npx wrangler secret put ADMIN_PASSWORD</code> 后刷新。</p>`), 503);
  }
  const current = await session(request, env);

  if (request.method === "GET") {
    if (path === "/admin") {
      return current ? html(await dashboard(env, url, current)) : html(loginPage(url.searchParams.get("notice")));
    }
    if (path === "/admin/config" && current) return exportConfiguration(env, url);
    return html(page("SSClip 中继", `<p>页面不存在。<a href="/admin">返回管理页</a></p>`), 404);
  }
  if (request.method !== "POST") return html(page("SSClip 中继", "<p>不支持的请求。</p>"), 405);

  // 只接受本站页面提交的表单。
  const origin = request.headers.get("origin");
  if (origin && origin !== url.origin) return html(page("SSClip 中继", "<p>请求来源不符。</p>"), 403);
  const form = await request.formData().catch(() => null);
  if (!form) return html(page("SSClip 中继", "<p>表单无效。</p>"), 400);
  const field = (name) => (typeof form.get(name) === "string" ? form.get(name) : "");

  if (path === "/admin/login") return login(env, field("password"));
  if (!current) return back("请先登录");
  if (!(await secretsEqual(field("csrf"), current.csrf))) return html(page("SSClip 中继", "<p>表单已过期，请返回刷新后重试。</p>"), 403);

  switch (path) {
    case "/admin/logout":
      await env.DB.prepare(`DELETE FROM sessions WHERE token_hash = ?1`).bind(await sha256Hex(current.token)).run();
      return back("已退出", { "set-cookie": `${SESSION_COOKIE}=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=Strict` });
    case "/admin/key/rotate":
      if (validAPIKey(env.API_KEY)) return back("API Key 由环境变量 API_KEY 指定，请在 Cloudflare 里修改");
      await setSetting(env.DB, "api_key", randomToken(32));
      return back("已生成新的 API Key；旧 Key 立即失效，请重新导出连接配置并导入每台设备");
    case "/admin/key/set":
      if (validAPIKey(env.API_KEY)) return back("API Key 由环境变量 API_KEY 指定，请在 Cloudflare 里修改");
      if (!validAPIKey(field("api_key").trim())) return back("API Key 需为 32–256 位字母、数字、_ 或 -，未修改");
      await setSetting(env.DB, "api_key", field("api_key").trim());
      return back("已改用指定的 API Key");
    case "/admin/devices/delete":
      await env.DB.batch([
        env.DB.prepare(`DELETE FROM devices WHERE id = ?1`).bind(field("id")),
        env.DB.prepare(`UPDATE messages SET text = '', expires_at = MIN(expires_at, ?2) WHERE target = ?1 AND state = 'pending'`).bind(field("id"), Date.now()),
      ]);
      await hub(env)?.disconnect(field("id")).catch(() => {});
      return back("已删除设备；发给它的未读消息一并作废");
    case "/admin/bark/add":
      return addBarkTarget(env, field("name"), field("server"), field("key"));
    case "/admin/messages/retry":
      return retryBark(env, field("id"));
    default:
      return html(page("SSClip 中继", `<p>页面不存在。<a href="/admin">返回管理页</a></p>`), 404);
  }
}

async function login(env, password) {
  const now = Date.now();
  const { total } = await env.DB
    .prepare(`SELECT COUNT(*) AS total FROM login_failures WHERE at > ?1`)
    .bind(now - 900_000)
    .first();
  if (total >= MAX_LOGIN_FAILURES) return html(loginPage("失败次数过多，请 15 分钟后再试"), 429);
  if (!(await secretsEqual(password, env.ADMIN_PASSWORD))) {
    await env.DB.prepare(`INSERT INTO login_failures (at) VALUES (?1)`).bind(now).run();
    return html(loginPage("密码不正确"), 401);
  }
  const token = randomToken(32);
  await env.DB
    .prepare(`INSERT INTO sessions (token_hash, csrf, expires_at) VALUES (?1, ?2, ?3)`)
    .bind(await sha256Hex(token), randomToken(24), now + SESSION_TTL_MS)
    .run();
  return back("已登录", {
    "set-cookie": `${SESSION_COOKIE}=${token}; Path=/admin; Max-Age=${SESSION_TTL_MS / 1000}; HttpOnly; Secure; SameSite=Strict`,
  });
}

async function exportConfiguration(env, url) {
  const configuration = {
    format: "ssclip-connection",
    version: 1,
    server_url: url.origin,
    api_key: await currentAPIKey(env, { create: true }),
  };
  return new Response(JSON.stringify(configuration, null, 2) + "\n", {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "content-disposition": `attachment; filename="ssclip-connection.ssclip.json"`,
      "cache-control": "no-store",
    },
  });
}

async function addBarkTarget(env, rawName, rawServer, rawKey) {
  const name = cleanName(rawName);
  const target = parseBarkTarget(rawServer, rawKey);
  if (!name) return back("名称需为 1–80 个字符，未添加");
  if (!target) return back("Bark 地址需为 HTTPS，device key 需为 8–128 位字母、数字、_ 或 -，未添加");
  const { total } = await env.DB.prepare(`SELECT COUNT(*) AS total FROM devices`).first();
  if (total >= MAX_DEVICES) return back(`设备数已达上限 ${MAX_DEVICES}，未添加`);
  const now = Date.now();
  await env.DB
    .prepare(
      `INSERT INTO devices (id, name, platform, transport, can_receive, last_seen_at, created_at, bark_server, bark_key)
       VALUES (?1, ?2, 'ios', 'bark', 1, ?3, ?3, ?4, ?5)`,
    )
    .bind(`ssclip-bark-${randomToken(9)}`, name, now, target.server, target.key)
    .run();
  return back(`已添加 Bark 接收端“${name}”`);
}

async function retryBark(env, id) {
  if (!validID(id)) return back("消息编号无效");
  const now = Date.now();
  const message = await env.DB.prepare(`SELECT * FROM messages WHERE id = ?1`).bind(id).first();
  if (!message || !["failed", "rejected", "unknown"].includes(message.delivery)) return back("这条消息不需要重试");
  if (message.expires_at <= now || message.text === "") return back("消息已过期，正文已清除，无法重试");
  const receiver = await env.DB.prepare(`SELECT * FROM devices WHERE id = ?1 AND transport = 'bark'`).bind(message.target).first();
  if (!receiver) return back("接收端已删除，无法重试");
  // 条件更新充当锁：同一条消息同时只会有一次重试在进行。
  const claimed = await env.DB
    .prepare(`UPDATE messages SET delivery = 'in_progress', delivery_started_at = ?1 WHERE id = ?2 AND delivery = ?3`)
    .bind(now, id, message.delivery)
    .run();
  if (claimed.meta.changes === 0) return back("这条消息正在处理中");
  const error = await deliverToBark(env, message, receiver);
  return back(error ? `重试未成功（${error}）` : "Bark 已接受这条推送");
}

const time = (value) => new Date(value).toISOString().replace("T", " ").slice(0, 19) + " UTC";

async function dashboard(env, url, current) {
  const now = Date.now();
  const [key, devices, messages] = await Promise.all([
    currentAPIKey(env, { create: true }),
    env.DB.prepare(`SELECT * FROM devices ORDER BY name, id`).all(),
    env.DB.prepare(
      `SELECT id, source, target, created_at, expires_at, state, delivery, delivery_error, text != '' AS has_text
       FROM messages ORDER BY created_at DESC LIMIT 50`,
    ).all(),
  ]);
  const csrf = `<input type="hidden" name="csrf" value="${escapeHTML(current.csrf)}">`;
  const names = new Map(devices.results.map((device) => [device.id, device.name]));
  const label = (id) => escapeHTML(names.get(id) ?? id);
  const fromEnvironment = validAPIKey(env.API_KEY);

  const deviceRows = devices.results.map((device) => `
    <tr>
      <td>${escapeHTML(device.name)}</td>
      <td><code>${escapeHTML(device.id)}</code></td>
      <td>${device.transport === "bark" ? "iOS · Bark" : escapeHTML(device.platform)}${device.can_receive === 1 ? "" : " · 仅发送"}</td>
      <td>${time(device.last_seen_at)}</td>
      <td><form method="post" action="/admin/devices/delete">${csrf}<input type="hidden" name="id" value="${escapeHTML(device.id)}"><button class="danger">删除</button></form></td>
    </tr>`).join("");

  const messageRows = messages.results.map((message) => {
    const expired = message.expires_at <= now;
    const state = message.state === "acknowledged" ? "已确认"
      : message.delivery === "submitted" ? "Bark 已接受"
      : message.delivery === "in_progress" ? "Bark 推送中"
      : message.delivery ? `Bark 未成功（${escapeHTML(message.delivery_error ?? message.delivery)}）`
      : expired ? "已过期" : "等待接收";
    const retry = ["failed", "rejected", "unknown"].includes(message.delivery) && !expired && message.has_text
      ? `<form method="post" action="/admin/messages/retry">${csrf}<input type="hidden" name="id" value="${escapeHTML(message.id)}"><button>重试</button></form>`
      : "";
    return `<tr><td>${time(message.created_at)}</td><td>${label(message.source)} → ${label(message.target)}</td><td>${state}</td><td>${retry}</td></tr>`;
  }).join("");

  const notice = url.searchParams.get("notice");
  return page("SSClip 中继管理", `
    ${notice ? `<p class="notice">${escapeHTML(notice)}</p>` : ""}
    <section>
      <h2>连接配置</h2>
      <p>服务地址 <code>${escapeHTML(url.origin)}</code></p>
      <p>API Key <code>${escapeHTML(key.slice(0, 4))}…${escapeHTML(key.slice(-4))}</code>${fromEnvironment ? "（来自环境变量 API_KEY）" : ""}</p>
      <p><a class="button" href="/admin/config">导出连接配置</a></p>
      <p class="hint">导出的文件含 API Key，等同密钥。在每台 Mac 的 SSClip 设置里导入，iPhone 快捷指令首次运行时选择它。</p>
      ${fromEnvironment ? "" : `
      <details><summary>更换 API Key</summary>
        <form method="post" action="/admin/key/rotate">${csrf}<button class="danger">生成新的 API Key</button></form>
        <form method="post" action="/admin/key/set">${csrf}
          <label>沿用已有的 Key <input name="api_key" autocomplete="off" minlength="32" maxlength="256" pattern="[A-Za-z0-9_\\-]+" required></label>
          <button>保存</button>
        </form>
        <p class="hint">换 Key 后旧 Key 立即失效，所有设备都要重新导入连接配置。</p>
      </details>`}
    </section>
    <section>
      <h2>设备</h2>
      ${deviceRows ? `<table><tr><th>名称</th><th>编号</th><th>类型</th><th>最近在线</th><th></th></tr>${deviceRows}</table>` : `<p class="hint">还没有设备。Mac 导入连接配置后会自动出现在这里。</p>`}
    </section>
    <section>
      <h2>添加 Bark 接收端（iPhone / iPad）</h2>
      <form method="post" action="/admin/bark/add">${csrf}
        <label>名称 <input name="name" maxlength="80" required placeholder="我的 iPhone"></label>
        <label>Bark 服务器 <input name="server" value="${DEFAULT_BARK_SERVER}" placeholder="${DEFAULT_BARK_SERVER}"></label>
        <label>Device key <input name="key" autocomplete="off" required placeholder="也可以直接粘贴 Bark 里的完整推送地址"></label>
        <button>添加</button>
      </form>
      <p class="hint">通知正文和元数据合计不能超过 APNs 的 4096 字节，超出不会截断，直接拒绝。Bark 接受推送不代表手机已收到或复制。</p>
    </section>
    <section>
      <h2>最近的消息</h2>
      ${messageRows ? `<table><tr><th>时间</th><th>方向</th><th>状态</th><th></th></tr>${messageRows}</table>` : `<p class="hint">暂无消息。</p>`}
      <p class="hint">这里不显示正文。正文在确认接收、Bark 接受或过期后清除；过期超过一天的记录整条删除。</p>
    </section>
    <form method="post" action="/admin/logout">${csrf}<button>退出登录</button></form>`);
}

const loginPage = (notice) => page("SSClip 中继管理", `
  ${notice ? `<p class="notice">${escapeHTML(notice)}</p>` : ""}
  <form method="post" action="/admin/login">
    <label>管理密码 <input type="password" name="password" autocomplete="current-password" required autofocus></label>
    <button>登录</button>
  </form>`);

function page(title, body) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHTML(title)}</title>
<style>
  :root { color-scheme: light dark; --line: color-mix(in srgb, currentColor 16%, transparent); --soft: color-mix(in srgb, currentColor 6%, transparent); }
  body { font: 15px/1.6 -apple-system, system-ui, "PingFang SC", sans-serif; max-width: 760px; margin: 0 auto; padding: 24px 16px 48px; }
  h1 { font-size: 22px; } h2 { font-size: 16px; margin: 0 0 8px; }
  section { border: 1px solid var(--line); border-radius: 12px; padding: 16px; margin: 16px 0; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; display: block; overflow-x: auto; }
  th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; }
  code { font: 12px ui-monospace, SFMono-Regular, monospace; background: var(--soft); padding: 1px 5px; border-radius: 5px; }
  label { display: block; margin: 8px 0; } input { font: inherit; padding: 6px 8px; width: 100%; max-width: 420px; box-sizing: border-box; border: 1px solid var(--line); border-radius: 8px; background: transparent; color: inherit; }
  button, .button { font: inherit; padding: 6px 14px; border-radius: 8px; border: 1px solid var(--line); background: var(--soft); color: inherit; cursor: pointer; text-decoration: none; display: inline-block; }
  .danger { color: #c0392b; } form { margin: 8px 0; } td form { margin: 0; }
  .hint { opacity: .7; font-size: 13px; } .notice, .warn { padding: 10px 12px; border-radius: 10px; background: var(--soft); }
  details { margin-top: 8px; } summary { cursor: pointer; }
</style>
</head>
<body>
<h1>${escapeHTML(title)}</h1>
${body}
</body>
</html>`;
}
