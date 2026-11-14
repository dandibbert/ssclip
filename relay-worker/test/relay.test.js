import { SELF, fetchMock } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  MAX_RESPONSE_BYTES, acceptableDeviceList, acceptableMessage, decodeDevicesResponse, decodePollResponse,
  macCanSendTo, parseConnectionConfiguration, shortcutCanSendTo,
} from "./client-rules.js";

const ORIGIN = "https://relay.example.test";
let apiKey = "";
let cookie = "";
let csrf = "";

const uuid = () => crypto.randomUUID();
const api = (path, { method = "GET", body, key = apiKey } = {}) =>
  SELF.fetch(`${ORIGIN}/api/service/${path}`, {
    method,
    redirect: "manual",
    headers: {
      accept: "application/json",
      ...(key ? { authorization: `Bearer ${key}` } : {}),
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
const post = (path, body) => api(path, { method: "POST", body });

async function adminPost(path, fields) {
  return SELF.fetch(`${ORIGIN}${path}`, {
    method: "POST",
    redirect: "manual",
    headers: { cookie, origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ csrf, ...fields }).toString(),
  });
}

async function registerMac(name = "Test Mac") {
  const id = uuid();
  const response = await post("register", { id, name, platform: "macos" });
  expect(response.status).toBe(200);
  return id;
}

async function addBarkTarget(name, server = "https://bark.example.test") {
  const response = await adminPost("/admin/bark/add", { name, server, key: "barkDeviceKey1234" });
  expect(response.status).toBe(303);
  const list = await (await api("devices")).json();
  return list.devices.find((device) => device.name === name).id;
}

function mockDNS(address = "93.184.216.34") {
  fetchMock
    .get("https://cloudflare-dns.com")
    .intercept({ path: (path) => path.startsWith("/dns-query") && path.endsWith("type=A") })
    .reply(200, { Answer: address ? [{ type: 1, data: address }] : [] });
  fetchMock
    .get("https://cloudflare-dns.com")
    .intercept({ path: (path) => path.startsWith("/dns-query") && path.endsWith("type=AAAA") })
    .reply(200, {});
}

beforeAll(async () => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
  const login = await SELF.fetch(`${ORIGIN}/admin/login`, {
    method: "POST",
    redirect: "manual",
    headers: { origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" },
    body: "password=test-admin-password",
  });
  expect(login.status).toBe(303);
  cookie = login.headers.get("set-cookie").split(";")[0];
  const page = await (await SELF.fetch(`${ORIGIN}/admin`, { headers: { cookie } })).text();
  csrf = page.match(/name="csrf" value="([^"]+)"/)[1];
  const exported = await (await SELF.fetch(`${ORIGIN}/admin/config`, { headers: { cookie } })).text();
  const configuration = parseConnectionConfiguration(exported);
  expect(configuration).not.toBeNull();
  expect(configuration.server_url).toBe(ORIGIN);
  apiKey = configuration.api_key;
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

describe("认证", () => {
  it("没有或错误的 API Key 一律 401，且不重定向", async () => {
    for (const key of ["", "x".repeat(40)]) {
      const response = await api("devices", { key });
      expect(response.status).toBe(401);
      expect(response.headers.get("location")).toBeNull();
    }
  });

  it("API Key 不能打开管理页面，管理会话也不能调用数据接口", async () => {
    const page = await SELF.fetch(`${ORIGIN}/admin`, { headers: { authorization: `Bearer ${apiKey}` } });
    expect(await page.text()).toContain('name="password"');
    const config = await SELF.fetch(`${ORIGIN}/admin/config`, { headers: { authorization: `Bearer ${apiKey}` } });
    expect(config.status).toBe(404);
    const data = await SELF.fetch(`${ORIGIN}/api/service/devices`, { headers: { cookie } });
    expect(data.status).toBe(401);
  });

  it("管理表单缺少 CSRF 令牌或来源不符时被拒绝", async () => {
    const noToken = await SELF.fetch(`${ORIGIN}/admin/key/rotate`, {
      method: "POST", redirect: "manual", headers: { cookie, origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" }, body: "",
    });
    expect(noToken.status).toBe(403);
    const foreign = await SELF.fetch(`${ORIGIN}/admin/key/rotate`, {
      method: "POST", redirect: "manual",
      headers: { cookie, origin: "https://evil.example", "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ csrf }).toString(),
    });
    expect(foreign.status).toBe(403);
    expect((await api("devices")).status).toBe(200);
  });
});

describe("Mac 客户端流程", () => {
  it("注册、发现设备、发送、轮询、确认，全程通过客户端校验", async () => {
    const sender = await registerMac("书房的 Mac");
    const receiver = await registerMac("客厅的 Mac");

    const list = decodeDevicesResponse(await (await api("devices")).json());
    expect(acceptableDeviceList(list.devices, sender)).toBe(true);
    expect(macCanSendTo(list.devices.find((device) => device.id === receiver))).toBe(true);

    const id = uuid().toUpperCase();
    const text = "跨设备文本 中😀\n第二行";
    const sent = await post("send", { id, source: sender, target: receiver, text, ttl_seconds: 1200 });
    expect(sent.status).toBe(200);
    const sentBody = await sent.json();
    expect(sentBody.state).toBe("pending");
    expect(sentBody.delivery).toBeUndefined();

    const polled = decodePollResponse(await (await api(`poll?target=${receiver}`)).json());
    expect(polled.messages).toHaveLength(1);
    expect(acceptableMessage(polled.messages[0], receiver, polled.server_time)).toBe(true);
    expect(polled.messages[0]).toMatchObject({ id, source: sender, target: receiver, text });

    // 发送方轮询不到别人的消息。
    expect((await (await api(`poll?target=${sender}`)).json()).messages).toHaveLength(0);

    const acked = await post("ack", { id, target: receiver });
    expect(acked.status).toBe(200);
    expect((await (await api(`poll?target=${receiver}`)).json()).messages).toHaveLength(0);
    // 确认可以重复，客户端重试不会出错。
    expect((await post("ack", { id, target: receiver })).status).toBe(200);
  });

  it("确认未知消息返回 404，客户端视为终态", async () => {
    const receiver = await registerMac();
    expect((await post("ack", { id: uuid(), target: receiver })).status).toBe(404);
  });

  it("过期消息不再下发，确认返回 410", async () => {
    const sender = await registerMac();
    const receiver = await registerMac();
    const id = uuid();
    expect((await post("send", { id, source: sender, target: receiver, text: "短命", ttl_seconds: 1 })).status).toBe(200);
    await new Promise((resolve) => setTimeout(resolve, 1100));
    expect((await (await api(`poll?target=${receiver}`)).json()).messages).toHaveLength(0);
    expect((await post("ack", { id, target: receiver })).status).toBe(410);
  });

  it("有效期最长 20 分钟，更长的请求被收紧", async () => {
    const sender = await registerMac();
    const receiver = await registerMac();
    await post("send", { id: uuid(), source: sender, target: receiver, text: "ttl", ttl_seconds: 999999 });
    const polled = await (await api(`poll?target=${receiver}`)).json();
    expect(polled.messages[0].expires_at - polled.messages[0].created_at).toBe(1_200_000);
    expect(acceptableMessage(polled.messages[0], receiver, polled.server_time)).toBe(true);
  });

  it("正文上限是 32768 个 UTF-8 字节，超限不截断", async () => {
    const sender = await registerMac();
    const receiver = await registerMac();
    const atLimit = "中".repeat(10922) + "ab";
    expect(new TextEncoder().encode(atLimit).length).toBe(32768);
    expect((await post("send", { id: uuid(), source: sender, target: receiver, text: atLimit })).status).toBe(200);
    expect((await post("send", { id: uuid(), source: sender, target: receiver, text: atLimit + "c" })).status).toBe(413);
    expect((await post("send", { id: uuid(), source: sender, target: receiver, text: "" })).status).toBe(400);
    const polled = await (await api(`poll?target=${receiver}`)).json();
    expect(polled.messages.map((message) => message.text)).toEqual([atLimit]);
  });

  it("同一编号重复发送只入队一次；内容不同则冲突", async () => {
    const sender = await registerMac();
    const receiver = await registerMac();
    const body = { id: uuid(), source: sender, target: receiver, text: "一次", ttl_seconds: 1200 };
    expect((await post("send", body)).status).toBe(200);
    const again = await post("send", body);
    expect(again.status).toBe(200);
    expect((await again.json()).state).toBe("pending");
    expect((await post("send", { ...body, text: "另一段" })).status).toBe(409);
    expect((await (await api(`poll?target=${receiver}`)).json()).messages).toHaveLength(1);
  });

  it("目标不存在、仅发送的目标、发给自己都不入队", async () => {
    const sender = await registerMac();
    expect((await post("send", { id: uuid(), source: sender, target: uuid(), text: "x" })).status).toBe(404);
    expect((await post("send", { id: uuid(), source: sender, target: sender, text: "x" })).status).toBe(400);
    await post("register", { id: "ios-shortcut-sender", name: "iOS 快捷指令", platform: "ios", can_receive: false });
    expect((await post("send", { id: uuid(), source: sender, target: "ios-shortcut-sender", text: "x" })).status).toBe(409);
  });

  it("积压很多大消息时，单次轮询响应仍在客户端的大小上限内，并按时间顺序分批取完", async () => {
    const sender = await registerMac();
    const receiver = await registerMac();
    const big = "数".repeat(10000);
    const ids = [];
    for (let index = 0; index < 40; index += 1) {
      const id = uuid();
      ids.push(id);
      expect((await post("send", { id, source: sender, target: receiver, text: `${index}:${big}` })).status).toBe(200);
    }
    const received = [];
    for (let round = 0; round < 5 && received.length < ids.length; round += 1) {
      const raw = await (await api(`poll?target=${receiver}`)).text();
      expect(new TextEncoder().encode(raw).length).toBeLessThan(MAX_RESPONSE_BYTES);
      const polled = decodePollResponse(JSON.parse(raw));
      expect(polled.messages.length).toBeGreaterThan(0);
      for (const message of polled.messages) {
        expect(acceptableMessage(message, receiver, polled.server_time)).toBe(true);
        received.push(message.id);
        await post("ack", { id: message.id, target: receiver });
      }
    }
    expect(received).toEqual(ids);
  });

  it("改名后重新注册沿用同一编号", async () => {
    const id = await registerMac("旧名字");
    await post("register", { id, name: "  新名字  ", platform: "macos" });
    const list = await (await api("devices")).json();
    expect(list.devices.filter((device) => device.id === id).map((device) => device.name)).toEqual(["新名字"]);
  });

  it("不合规的注册被 4xx 拒绝", async () => {
    for (const body of [
      { id: "short", name: "Mac", platform: "macos" },
      { id: uuid(), name: "", platform: "macos" },
      { id: uuid(), name: "x".repeat(81), platform: "macos" },
      { id: uuid(), name: "Mac", platform: "windows" },
      { id: uuid(), name: "Mac\u0007", platform: "macos" },
    ]) {
      expect((await post("register", body)).status).toBe(400);
    }
  });
});

describe("iPhone 快捷指令流程", () => {
  it("注册发送端、只列出 Mac、提交后返回 id 与 pending", async () => {
    const mac = await registerMac("接收的 Mac");
    const registered = await post("register", {
      id: "ios-shortcut-sender", name: "iOS 快捷指令", platform: "ios", can_receive: false,
    });
    expect((await registered.json()).device.id).toBe("ios-shortcut-sender");

    const list = decodeDevicesResponse(await (await api("devices")).json());
    const choices = list.devices.filter(shortcutCanSendTo).map((device) => device.id);
    expect(choices).toContain(mac);
    expect(choices).not.toContain("ios-shortcut-sender");
    // Mac 客户端同样不会把快捷指令发送端当成目标。
    expect(macCanSendTo(list.devices.find((device) => device.id === "ios-shortcut-sender"))).toBe(false);

    const id = "msg-123456789-234567890-345678901-456789012";
    const sent = await (await post("send", {
      id, source: "ios-shortcut-sender", target: mac, text: "来自 iPhone", ttl_seconds: 1200,
    })).json();
    expect(sent.id).toBe(id);
    expect(["pending", "acknowledged"]).toContain(sent.state);

    const polled = await (await api(`poll?target=${mac}`)).json();
    expect(acceptableMessage(polled.messages[0], mac, polled.server_time)).toBe(true);
  });
});

describe("Bark 接收端", () => {
  it("管理端添加后出现在设备列表里，Mac 可选、快捷指令不可选，且不泄露 device key", async () => {
    const mac = await registerMac();
    const bark = await addBarkTarget(`手机 ${uuid().slice(0, 8)}`);
    const raw = await (await api("devices")).text();
    expect(raw).not.toContain("barkDeviceKey1234");
    expect(raw).not.toContain("bark.example.test");
    const list = decodeDevicesResponse(JSON.parse(raw));
    expect(acceptableDeviceList(list.devices, mac)).toBe(true);
    const device = list.devices.find((entry) => entry.id === bark);
    expect(device).toMatchObject({ platform: "ios", transport: "bark" });
    expect(macCanSendTo(device)).toBe(true);
    expect(shortcutCanSendTo(device)).toBe(false);
  });

  it("Bark 接受后返回 delivery: submitted，推送内容是原文", async () => {
    const mac = await registerMac();
    const bark = await addBarkTarget(`手机 ${uuid().slice(0, 8)}`);
    mockDNS();
    let pushed = null;
    fetchMock.get("https://bark.example.test").intercept({ path: "/push", method: "POST" }).reply((request) => {
      pushed = JSON.parse(request.body);
      return { statusCode: 200, data: { code: 200, message: "success" } };
    });
    const body = { id: uuid(), source: mac, target: bark, text: "给手机的文本", ttl_seconds: 1200 };
    const sent = await post("send", body);
    expect(sent.status).toBe(200);
    expect(await sent.json()).toMatchObject({ state: "pending", delivery: "submitted" });
    expect(pushed).toMatchObject({ device_key: "barkDeviceKey1234", body: "给手机的文本" });
    // 重复提交同一编号不会再推一次。
    const again = await post("send", body);
    expect(again.status).toBe(200);
    expect((await again.json()).delivery).toBe("submitted");
  });

  it("超出 APNs 预算时返回 413 bark_text_too_large，不联网也不截断", async () => {
    const mac = await registerMac();
    const bark = await addBarkTarget(`手机 ${uuid().slice(0, 8)}`);
    const sent = await post("send", { id: uuid(), source: mac, target: bark, text: "长".repeat(1300) });
    expect(sent.status).toBe(413);
    expect((await sent.json()).error).toBe("bark_text_too_large");
  });

  it("Bark 拒绝、出错、超时分别对应客户端认识的错误码", async () => {
    const mac = await registerMac();
    const bark = await addBarkTarget(`手机 ${uuid().slice(0, 8)}`);
    const cases = [
      [() => ({ statusCode: 400, data: { code: 400, message: "failed to get device token" } }), 502, "bark_rejected"],
      [() => ({ statusCode: 500, data: { code: 500, message: "push failed" } }), 502, "bark_delivery_failed"],
      [() => { throw new Error("socket closed"); }, 502, "bark_delivery_unknown"],
    ];
    for (const [reply, status, error] of cases) {
      mockDNS();
      const interceptor = fetchMock.get("https://bark.example.test").intercept({ path: "/push", method: "POST" });
      if (error === "bark_delivery_unknown") interceptor.replyWithError(new Error("socket closed"));
      else interceptor.reply(reply);
      const sent = await post("send", { id: uuid(), source: mac, target: bark, text: "文本" });
      expect(sent.status).toBe(status);
      expect((await sent.json()).error).toBe(error);
    }
  });

  it("自建 Bark 域名解析到内网或解析不到时不推送", async () => {
    const mac = await registerMac();
    const bark = await addBarkTarget(`手机 ${uuid().slice(0, 8)}`);
    mockDNS("10.0.0.8");
    const blocked = await post("send", { id: uuid(), source: mac, target: bark, text: "文本" });
    expect(blocked.status).toBe(503);
    expect((await blocked.json()).error).toBe("bark_private_address_blocked");
    mockDNS(null);
    const missing = await post("send", { id: uuid(), source: mac, target: bark, text: "文本" });
    expect(missing.status).toBe(503);
    expect((await missing.json()).error).toBe("bark_dns_unavailable");
  });

  it("推送失败的消息保留正文，可在管理端重试；成功后不能再重试", async () => {
    const mac = await registerMac();
    const bark = await addBarkTarget(`手机 ${uuid().slice(0, 8)}`);
    const id = uuid();
    mockDNS();
    fetchMock.get("https://bark.example.test").intercept({ path: "/push", method: "POST" })
      .reply(500, { code: 500, message: "push failed" });
    expect((await post("send", { id, source: mac, target: bark, text: "稍后重试" })).status).toBe(502);

    mockDNS();
    let pushed = null;
    fetchMock.get("https://bark.example.test").intercept({ path: "/push", method: "POST" }).reply((request) => {
      pushed = JSON.parse(request.body);
      return { statusCode: 200, data: { code: 200, message: "success" } };
    });
    const retried = await adminPost("/admin/messages/retry", { id });
    expect(decodeURIComponent(retried.headers.get("location"))).toContain("Bark 已接受");
    expect(pushed.body).toBe("稍后重试");

    const second = await adminPost("/admin/messages/retry", { id });
    expect(decodeURIComponent(second.headers.get("location"))).toContain("不需要重试");
  });

  it("客户端不能用 Bark 接收端的编号注册", async () => {
    const bark = await addBarkTarget(`手机 ${uuid().slice(0, 8)}`);
    expect((await post("register", { id: bark, name: "冒充", platform: "macos" })).status).toBe(409);
  });
});

describe("管理端", () => {
  it("删除设备后它不再出现，发给它的消息作废", async () => {
    const sender = await registerMac();
    const receiver = await registerMac("将被删除");
    await post("send", { id: uuid(), source: sender, target: receiver, text: "作废" });
    expect((await adminPost("/admin/devices/delete", { id: receiver })).status).toBe(303);
    const list = await (await api("devices")).json();
    expect(list.devices.some((device) => device.id === receiver)).toBe(false);
    expect((await api(`poll?target=${receiver}`)).status).toBe(404);
    // 同一台设备重新注册后不会收到删除前的旧消息。
    await post("register", { id: receiver, name: "回来了", platform: "macos" });
    expect((await (await api(`poll?target=${receiver}`)).json()).messages).toHaveLength(0);
  });

  it("管理页不显示完整 API Key 和消息正文", async () => {
    const sender = await registerMac();
    const receiver = await registerMac();
    await post("send", { id: uuid(), source: sender, target: receiver, text: "不该出现在管理页的正文" });
    const page = await (await SELF.fetch(`${ORIGIN}/admin`, { headers: { cookie } })).text();
    expect(page).not.toContain(apiKey);
    expect(page).not.toContain("不该出现在管理页的正文");
  });

  it("更换 API Key 后旧 Key 立即失效", async () => {
    const old = apiKey;
    expect((await adminPost("/admin/key/rotate", {})).status).toBe(303);
    expect((await api("devices", { key: old })).status).toBe(401);
    const exported = await (await SELF.fetch(`${ORIGIN}/admin/config`, { headers: { cookie } })).text();
    apiKey = parseConnectionConfiguration(exported).api_key;
    expect(apiKey).not.toBe(old);
    expect((await api("devices")).status).toBe(200);
  });
});
