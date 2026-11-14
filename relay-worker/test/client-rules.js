// 客户端（Sources/SSClip/Services/RelayProtocol.swift、RelayController.swift 和
// Shortcuts/SSClip-send.cherri）对服务端响应的校验规则，逐条照搬成 JS。
// 服务端的响应必须全部通过这些检查，客户端才会接受。

const encoder = new TextEncoder();
const utf8 = (text) => encoder.encode(text).length;
const idPattern = /^[A-Za-z0-9_-]{8,96}$/;

export const validDeviceID = (value) => typeof value === "string" && idPattern.test(value);
export const validText = (text) => typeof text === "string" && text.length > 0 && utf8(text) <= 32768;

// RelayConnectionConfiguration.parse
export function parseConnectionConfiguration(raw) {
  if (utf8(raw) > 16384) return null;
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (value.format !== "ssclip-connection" || value.version !== 1) return null;
  let url;
  try {
    url = new URL(value.server_url);
  } catch {
    return null;
  }
  const rootOnly = url.protocol === "https:" && !url.username && !url.password && !url.search && !url.hash &&
    (url.pathname === "" || url.pathname === "/");
  if (!rootOnly || !/^[A-Za-z0-9_-]{32,256}$/.test(value.api_key)) return null;
  return value;
}

// Codable 解码要求的必填字段类型。
const isNumber = (value) => typeof value === "number" && Number.isFinite(value);

export function decodeDevicesResponse(body) {
  if (!Array.isArray(body.devices) || !isNumber(body.server_time)) throw new Error("devices response shape");
  for (const device of body.devices) {
    if (typeof device.id !== "string" || typeof device.name !== "string" || typeof device.platform !== "string" ||
        !isNumber(device.last_seen_at)) throw new Error("device shape");
    if (device.can_receive !== undefined && typeof device.can_receive !== "boolean") throw new Error("can_receive type");
    if (device.transport !== undefined && typeof device.transport !== "string") throw new Error("transport type");
  }
  return body;
}

// RelayController.connect 里对设备列表的整体校验。
export function acceptableDeviceList(devices, ownID) {
  return devices.length <= 128 &&
    new Set(devices.map((device) => device.id)).size === devices.length &&
    devices.some((device) => device.id === ownID) &&
    devices.every((device) => validDeviceID(device.id) && device.name.length > 0 && device.name.length <= 80 &&
      Number.isFinite(device.last_seen_at) && ["macos", "ios", "web"].includes(device.platform));
}

// RelayDevice.canReceive（Mac 客户端可选的发送目标）。
export const macCanSendTo = (device) =>
  device.id !== "ios-shortcut-sender" && (device.can_receive ?? true) && (device.platform !== "ios" || device.transport === "bark");

// iPhone 快捷指令列出的目标：仅 Mac，排除显式 can_receive:false 和自己。
export const shortcutCanSendTo = (device) =>
  device.platform === "macos" && !/"can_receive"\s*:\s*false\s*[,}]/.test(JSON.stringify(device)) &&
  device.id !== "ios-shortcut-sender" && validDeviceID(device.id);

export function decodePollResponse(body) {
  if (!Array.isArray(body.messages) || !isNumber(body.server_time)) throw new Error("poll response shape");
  for (const message of body.messages) {
    for (const key of ["id", "source", "target", "text"]) {
      if (typeof message[key] !== "string") throw new Error(`message.${key} type`);
    }
    if (!isNumber(message.created_at) || !isNumber(message.expires_at)) throw new Error("message time type");
  }
  return body;
}

// RelayPolicy.valid
export const acceptableMessage = (message, target, serverTime) =>
  idPattern.test(message.id) && validDeviceID(message.source) && validDeviceID(target) &&
  message.source !== target && message.target === target && validText(message.text) &&
  message.created_at <= serverTime && message.expires_at > serverTime &&
  message.expires_at - message.created_at <= 1_200_000;

// 客户端一次响应最多接受这么多字节。
export const MAX_RESPONSE_BYTES = 1_000_000;
