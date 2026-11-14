#!/bin/zsh
set -eu
SCRIPT_DIR=${0:A:h}
TEMPLATE="$SCRIPT_DIR/SSClip-Send.unsigned.shortcut"
NAME="SSClip发送.shortcut"
if [[ ! -s "$TEMPLATE" && -s "$SCRIPT_DIR/../Resources/${TEMPLATE:t}" ]]; then
  TEMPLATE="$SCRIPT_DIR/../Resources/${TEMPLATE:t}"
fi
if [[ ! -s "$TEMPLATE" ]]; then
  print '找不到快捷指令模板。请完整解压签名工具包后重试。'
  exit 1
fi
OUTPUT_DIR=$(mktemp -d "$SCRIPT_DIR/Signed-XXXXXX")
OUTPUT="$OUTPUT_DIR/$NAME"
mkdir "$OUTPUT_DIR/Input"
cp "$TEMPLATE" "$OUTPUT_DIR/Input/$NAME"
NAMED_INPUT="$OUTPUT_DIR/Input/$NAME"
print '使用 Apple 官方工具签名。此 Mac 必须已登录 iCloud；模板不含你的 API Key。'
print '不会修改系统设置、钥匙串或下载安全属性。'
/usr/bin/shortcuts sign --mode anyone --input "$NAMED_INPUT" --output "$OUTPUT" >"$OUTPUT_DIR/signing.log" 2>&1 &
SIGN_PID=$!
(sleep 150; kill -TERM "$SIGN_PID" 2>/dev/null || true) &
TIMEOUT_PID=$!
set +e
wait "$SIGN_PID"
RESULT=$?
set -e
kill "$TIMEOUT_PID" 2>/dev/null || true
rm "$NAMED_INPUT"
rmdir "$OUTPUT_DIR/Input"
if [[ "$RESULT" != 0 || ! -s "$OUTPUT" ]] || cmp -s "$TEMPLATE" "$OUTPUT"; then
  [[ ! -f "$OUTPUT" ]] || rm "$OUTPUT"
  print '未生成可安装文件。请确认这台 Mac 已登录 iCloud，然后再次运行。'
  print "Apple 工具诊断保存在：$OUTPUT_DIR/signing.log"
  print '未签名模板不能直接安装到 iPhone；原模板没有改动。'
  exit 1
fi
if [[ "$(/usr/bin/head -c 4 "$OUTPUT")" != "AEA1" ]]; then
  rm "$OUTPUT"
  print '输出不符合当前 Apple 签名封装，未保留安装文件。原模板未改。'
  exit 1
fi
print "已生成：$OUTPUT"
print '用 AirDrop 发到 iPhone，打开并添加；首次只导入连接 JSON；之后每次发送选择接收 Mac。'
/usr/bin/open -R "$OUTPUT"
