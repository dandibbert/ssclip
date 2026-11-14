import { handleAdmin } from "./admin.js";
import { handleAPI } from "./api.js";
import { cleanup, currentAPIKey, ensureSchema } from "./db.js";
import { RelayHub } from "./hub.js";
import { fail, secretsEqual } from "./util.js";

const API_PREFIX = "/api/service/";

async function authorized(request, env) {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer ([A-Za-z0-9_-]+)$/);
  if (!match) return false;
  const key = await currentAPIKey(env);
  return key !== null && secretsEqual(match[1], key);
}

async function route(request, env, context) {
  if (!env.DB) return fail(503, "database_not_configured");
  const { pathname } = new URL(request.url);
  await ensureSchema(env.DB);

  if (pathname.startsWith(API_PREFIX)) {
    // 共享 API Key 只授权数据接口，不授权管理页面。
    if (!(await authorized(request, env))) return fail(401, "unauthorized");
    context.waitUntil(cleanup(env.DB).catch(() => {}));
    return handleAPI(request, env, pathname.slice(API_PREFIX.length), context);
  }
  if (pathname === "/admin" || pathname.startsWith("/admin/")) return handleAdmin(request, env, pathname);
  if (pathname === "/") {
    return new Response("SSClip relay\n管理页面：/admin\n", { headers: { "content-type": "text/plain; charset=utf-8" } });
  }
  return fail(404, "not_found");
}

export { RelayHub };

export default {
  async fetch(request, env, context) {
    try {
      return await route(request, env, context);
    } catch (error) {
      console.error("unhandled", error?.message ?? error);
      return fail(500, "internal_error");
    }
  },
  async scheduled(controller, env, context) {
    await ensureSchema(env.DB);
    context.waitUntil(cleanup(env.DB, Date.now(), true));
  },
};
