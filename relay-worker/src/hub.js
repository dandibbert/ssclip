import { DurableObject } from "cloudflare:workers";

/**
 * 持有各设备的 WebSocket 连接，并在有新消息时通知对应设备。
 * 连接上只传“有新消息”的信号，正文仍由设备用 poll 取、用 ack 确认，
 * 所以推送丢失或连接断开都不会丢消息。
 */
export class RelayHub extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    // 心跳由运行时直接应答，不会把休眠中的对象唤醒。
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const target = new URL(request.url).searchParams.get("target");
    if (!target || request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response(null, { status: 426 });
    }
    // 同一台设备只保留最新的一条连接。
    for (const socket of this.ctx.getWebSockets(target)) {
      try {
        socket.close(4000, "replaced");
      } catch {
        // 已经断开的连接不用处理。
      }
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [target]);
    pair[1].send(JSON.stringify({ type: "hello", server_time: Date.now() }));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** 通知一台设备有新消息；返回收到通知的连接数。 */
  async notify(target) {
    let delivered = 0;
    for (const socket of this.ctx.getWebSockets(target)) {
      try {
        socket.send(JSON.stringify({ type: "notify", server_time: Date.now() }));
        delivered += 1;
      } catch {
        // 连接已失效，设备重连后会自己补拉。
      }
    }
    return delivered;
  }

  /** 断开一台设备的所有连接（设备被删除时用）。 */
  async disconnect(target) {
    for (const socket of this.ctx.getWebSockets(target)) {
      try {
        socket.close(4001, "removed");
      } catch {
        // 已经断开。
      }
    }
  }

  webSocketMessage() {
    // 客户端除了心跳不发别的内容。
  }

  webSocketClose(socket, code) {
    try {
      socket.close(code === 1005 || code === 1006 ? 1000 : code, "closed");
    } catch {
      // 已经关闭。
    }
  }
}

export const hub = (env) => (env.HUB ? env.HUB.get(env.HUB.idFromName("hub")) : null);
