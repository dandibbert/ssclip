# SSClip 中继（Cloudflare Workers 版）

SSClip 跨设备同步的自建服务端，跑在 Cloudflare Workers + D1 上。它实现的是 Mac 客户端和 iPhone 快捷指令实际使用的那套接口，所以现有客户端**不用改代码**，只需要导入这个服务导出的连接配置。

接口是照着客户端写的：`codex/ssclip-relay-test` 分支上的 `RelayProtocol.swift`、`RelayController.swift` 和 `Shortcuts/SSClip-send.cherri`。原来 Sites 上的服务端源码不在仓库里，管理页面是重新做的，功能对应但界面不同。

## 部署

需要一个 Cloudflare 账号和 Node.js 20 以上。

```bash
cd relay-worker
```

```bash
npm install
```

```bash
npx wrangler login
```

```bash
npx wrangler d1 create ssclip-relay
```

把上一步输出里的 `database_id` 填进 `wrangler.toml`，然后设置管理密码并部署：

```bash
npx wrangler secret put ADMIN_PASSWORD
```

```bash
npx wrangler deploy
```

表结构在第一次请求时自动创建，不需要手动跑迁移。

## 连接设备

1. 打开 `https://<你的 Worker 地址>/admin`，用管理密码登录。
2. 点“导出连接配置”，得到 `ssclip-connection.ssclip.json`。
3. 在每台 Mac 的 SSClip 设置 → 跨设备同步里导入这个文件；iPhone 上运行“SSClip发送”，选“更换连接配置…”后选择同一个文件。
4. iPhone / iPad 要接收的话，在管理页“添加 Bark 接收端”里填 Bark 的 device key（也可以直接粘贴 Bark 里的完整推送地址）。

换了服务地址就是一个新的连接，客户端不会把旧站的默认目标和自动接收开关带过来，需要重新选一次。

### 沿用原来的 API Key

想让新旧服务用同一个 Key，有两种做法，二选一：

- 管理页 → 连接配置 → 更换 API Key → “沿用已有的 Key”。
- 设成环境变量，此时管理页不能再改它：

```bash
npx wrangler secret put API_KEY
```

## 接口

所有接口都在 `/api/service/` 下，用 `Authorization: Bearer <API Key>` 认证，返回 JSON，从不重定向。时间都是毫秒时间戳。

| 接口 | 作用 |
| --- | --- |
| `POST register` | `{id, name, platform, can_receive?}` 注册或更新设备，返回 `{device}` |
| `GET devices` | 返回 `{devices, server_time}`，含 Bark 接收端 |
| `POST send` | `{id, source, target, text, ttl_seconds}`，返回 `{id, state}`；发给 Bark 且被接受时多一个 `delivery: "submitted"` |
| `GET poll?target=` | 返回 `{messages, server_time}`，按发送时间从早到晚 |
| `POST ack` | `{id, target}` 确认接收并清除正文；未知消息 404，已过期 410 |
| `GET status?target=` | 返回 `{device, pending, server_time}` |

规则与客户端一致：

- 设备和消息编号是 8–96 位字母、数字、`_`、`-`；设备名 1–80 个字符；最多 128 台设备。
- 正文是非空纯文本，UTF-8 最多 32768 字节，超限返回 413，不截断。
- 有效期最长 20 分钟。过期后立即读不到，正文在之后的请求或每小时的定时任务里清除；过期超过一天的记录整条删除。
- 同一个消息编号重复提交只入队一次；编号相同但内容不同返回 409。
- 单次轮询响应控制在 90 万字节以内（客户端上限是 100 万），积压多时分批取完。
- Bark 相关的错误码：`bark_text_too_large`（413）、`bark_delivery_in_progress`（409）、`bark_rejected` / `bark_delivery_failed` / `bark_delivery_unknown`（502）、`bark_dns_unavailable` / `bark_private_address_blocked` / `bark_not_configured` / `bark_credential_unavailable`（503）。

`status` 接口客户端目前没有调用，返回的字段是我定的，不是照原服务端对齐的。

## 安全

- API Key 只能调用数据接口，不能打开管理页面；管理页面只认管理密码。
- 所有设备共用一个 Key，持有它就能读写这个服务上的设备和消息。换 Key 后旧 Key 立即失效。
- 正文在 D1 里明文暂存，不是端到端加密，不要发送密码。管理页不显示正文。
- Bark 的服务器地址和 device key 只存在服务端，不会出现在设备列表接口里。
- 自建 Bark 域名解析不到或解析到内网地址时不推送。
- 登录连续失败 10 次后锁定 15 分钟。

## 用量

Mac 开着“自动接收”时每 3 秒轮询一次，一台设备一天约 28800 次请求。Workers 免费版每天 10 万次请求，够两三台 Mac 常开；更多设备需要付费版。轮询只读数据库，在线时间每分钟最多写一次。

## 开发

```bash
npm test
```

测试在本地的 workerd 里跑真实的 Worker 和 D1。`test/client-rules.js` 把客户端对响应的校验规则逐条搬了过来，服务端的每个响应都要通过它们。

本地调试：

```bash
echo 'ADMIN_PASSWORD=local-dev-password' > .dev.vars
```

```bash
npm run dev
```

管理页的登录 Cookie 带 `Secure`，本地用 `http://localhost` 调试时 Safari 不会保存它，请换 Chrome 或 Firefox。
