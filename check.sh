#!/usr/bin/env bash
# ai-ip-check — Zero-dependency CLI diagnostic for AI Coding (Claude / ChatGPT / Gemini / Cursor)
# & Regional Streaming (Bahamut / Netflix / YouTube Premium / TikTok) connectivity.
# Repository: https://github.com/fanqiao-net/ai-ip-check
# License: MIT | Zero telemetry, forum-safe masked IP by default.

set -u

VERSION="1.1.0"
PROXY_URL=""
TIMEOUT=8
FULL_IP=0
JSON_OUT=0
RUN_AI=1
RUN_STREAM=1

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
AI_BLOCKED_REGIONS="CN HK MO RU BY IR KP SY CU"

usage() {
  cat <<'EOF'
Usage: check.sh [OPTIONS]

Options:
  -x, --proxy <URL>     Specify proxy (e.g. http://127.0.0.1:7897 or socks5h://127.0.0.1:7890)
  -m, --timeout <SEC>   Per-request timeout in seconds (default: 8)
      --ai-only         Run AI & developer API checks only
      --stream-only     Run regional streaming checks only
      --full-ip         Display unmasked exit IP (default masks as a.b.*.* for safe sharing)
      --json            Output machine-readable JSON
  -h, --help            Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -x|--proxy)
      PROXY_URL="${2:-}"
      shift 2
      ;;
    -m|--timeout)
      TIMEOUT="${2:-8}"
      shift 2
      ;;
    --ai-only)
      RUN_AI=1; RUN_STREAM=0; shift ;;
    --stream-only)
      RUN_AI=0; RUN_STREAM=1; shift ;;
    --full-ip)
      FULL_IP=1; shift ;;
    --json)
      JSON_OUT=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not installed." >&2
  exit 1
fi

if [ "$JSON_OUT" -eq 0 ] && [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

CURL_PROXY_ARGS=()
if [ -n "$PROXY_URL" ]; then
  CURL_PROXY_ARGS=(-x "$PROXY_URL")
fi

mask_ip() {
  local ip="$1"
  if [ -z "$ip" ]; then
    printf "unknown"
    return
  fi
  if [ "$FULL_IP" -eq 1 ]; then
    printf "%s" "$ip"
    return
  fi
  if printf "%s" "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf "%s" "$ip" | awk -F. '{printf "%s.%s.*.*", $1, $2}'
  elif printf "%s" "$ip" | grep -q ':'; then
    printf "%s" "$ip" | awk -F: '{printf "%s:%s:*:*", $1, $2}'
  else
    printf "%s" "$ip"
  fi
}

is_blocked_ai_loc() {
  local loc="$1"
  [ -z "$loc" ] && return 1
  for b in $AI_BLOCKED_REGIONS; do
    [ "$loc" = "$b" ] && return 0
  done
  return 1
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

# curl helper: writes body to $1, prints "<http_code>|<time_ms>|<url_effective>"
fetch_meta() {
  local out_file="$1"
  local url="$2"
  shift 2
  local raw
  raw=$(curl -sS -L --max-time "$TIMEOUT" -A "$UA" ${CURL_PROXY_ARGS[@]+"${CURL_PROXY_ARGS[@]}"} "$@" \
    -o "$out_file" -w '%{http_code}|%{time_total}|%{url_effective}' "$url" 2>/dev/null) || raw="000|0|"
  local code="${raw%%|*}"
  local rest="${raw#*|}"
  local secs="${rest%%|*}"
  local eff="${rest#*|}"
  local ms
  ms=$(awk -v s="$secs" 'BEGIN { printf "%d", (s + 0) * 1000 }')
  printf "%s|%s|%s" "$code" "$ms" "$eff"
}

parse_trace_val() {
  local file="$1"
  local key="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r\n'
}

TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'aiipcheck')
trap 'rm -rf "$TMP_DIR"' EXIT

JSON_ITEMS=()
WARNINGS=()

record_item() {
  local category="$1" name="$2" status="$3" region="$4" ms="$5" detail="$6"
  JSON_ITEMS+=("{\"category\":\"$(json_escape "$category")\",\"name\":\"$(json_escape "$name")\",\"status\":\"$(json_escape "$status")\",\"region\":\"$(json_escape "$region")\",\"latency_ms\":${ms:-0},\"detail\":\"$(json_escape "$detail")\"}")
  if [ "$JSON_OUT" -eq 0 ]; then
    local badge badge_pad color
    case "$status" in
      ok)   badge="✓ 可用";   badge_pad="    "; color="$C_GREEN" ;;
      warn) badge="△ 受限";   badge_pad="    "; color="$C_YELLOW" ;;
      *)    badge="✗ 不可用"; badge_pad="  ";   color="$C_RED" ;;
    esac
    local reg_str=""
    [ -n "$region" ] && reg_str="[${region}] "
    local ms_str=""
    [ "${ms:-0}" -gt 0 ] && ms_str=" (${ms}ms)"
    local ascii_bytes total_bytes cjk_chars disp_w name_pad=""
    ascii_bytes=$(printf "%s" "$name" | LC_ALL=C tr -cd '\000-\177' | wc -c | tr -d ' ')
    total_bytes=$(printf "%s" "$name" | wc -c | tr -d ' ')
    cjk_chars=$(( (total_bytes - ascii_bytes) / 3 ))
    disp_w=$(( ascii_bytes + cjk_chars * 2 ))
    while [ "$disp_w" -lt 24 ]; do
      name_pad="${name_pad} "
      disp_w=$(( disp_w + 1 ))
    done
    printf "  %s%s %s%s%s%s %s%s%s%s\n" "$name" "$name_pad" "$color" "$badge" "$C_RESET" "$badge_pad" "$reg_str" "$detail" "$C_DIM" "$ms_str$C_RESET"
  fi
}

if [ "$JSON_OUT" -eq 0 ]; then
  printf "\n%s=== AI Coding & Streaming Connectivity Diagnostic (v%s) ===%s\n" "$C_BOLD" "$VERSION" "$C_RESET"
  if [ -n "$PROXY_URL" ]; then
    printf "%sProxy: %s (IP 默认脱敏，完整显示加 --full-ip)%s\n" "$C_DIM" "$PROXY_URL" "$C_RESET"
  else
    printf "%sMode:  当前终端环境直测 (IP 默认脱敏，指定端口加 -x http://127.0.0.1:7897)%s\n" "$C_DIM" "$C_RESET"
  fi
fi

# 1. Exit IP & ASN Profile
CF_META=$(fetch_meta "$TMP_DIR/cf.txt" "https://www.cloudflare.com/cdn-cgi/trace")
CF_IP=$(parse_trace_val "$TMP_DIR/cf.txt" "ip")
CF_LOC=$(parse_trace_val "$TMP_DIR/cf.txt" "loc")
CF_COLO=$(parse_trace_val "$TMP_DIR/cf.txt" "colo")

ASN_INFO=""
IP_TYPE_HINT=""
IPSB_META=$(fetch_meta "$TMP_DIR/ipsb.json" "https://api.ip.sb/geoip" -H "Accept: application/json")
if [ "${IPSB_META%%|*}" = "200" ]; then
  ASN_NUM=$(sed -n 's/.*"asn"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$TMP_DIR/ipsb.json" | head -n 1)
  ASN_ORG=$(sed -n 's/.*"asn_organization"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP_DIR/ipsb.json" | head -n 1)
  [ -z "$CF_IP" ] && CF_IP=$(sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP_DIR/ipsb.json" | head -n 1)
  [ -z "$CF_LOC" ] && CF_LOC=$(sed -n 's/.*"country_code"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP_DIR/ipsb.json" | head -n 1)
  if [ -n "$ASN_NUM" ] || [ -n "$ASN_ORG" ]; then
    ASN_INFO="AS${ASN_NUM} ${ASN_ORG}"
    if printf "%s" "$ASN_ORG" | grep -Eiq 'Chunghwa|HiNet|Taiwan Fixed|Seednet|Far EasTone|Taiwan Mobile|HKBN|HKT|NTT|KDDI|SoftBank|So-net|KT Corp|SK Broadband|LG Uplus|Comcast|AT&T|Verizon|Charter|Cox|Deutsche Telekom|BT|Orange|Free SAS'; then
      IP_TYPE_HINT="家宽/本土运营商 ASN"
    else
      IP_TYPE_HINT="数据中心/商业网络 ASN"
    fi
  fi
fi

MASKED_DEFAULT_IP=$(mask_ip "$CF_IP")

if [ "$JSON_OUT" -eq 0 ]; then
  printf "\n%s[1] 终端默认出口画像%s\n" "$C_BOLD" "$C_RESET"
  printf "  默认出口 IP : %s%s%s (%s)\n" "$C_CYAN" "$MASKED_DEFAULT_IP" "$C_RESET" "${CF_LOC:-未知}"
  if [ -n "$ASN_INFO" ]; then
    printf "  所属运营商  : %s (%s)\n" "$ASN_INFO" "$IP_TYPE_HINT"
  fi
  [ -n "$CF_COLO" ] && printf "  边缘接入点  : Cloudflare %s\n" "$CF_COLO"
fi

if [ "$CF_LOC" = "CN" ]; then
  WARNINGS+=("当前终端默认出口为中国大陆 [CN]：CLI 工具通常不读浏览器系统代理，请开启客户端 TUN 模式或设置 HTTPS_PROXY。")
fi

# 2. AI Coding & LLM Checks
if [ "$RUN_AI" -eq 1 ]; then
  [ "$JSON_OUT" -eq 0 ] && printf "\n%s[2] AI 编程与大模型连通性%s\n" "$C_BOLD" "$C_RESET"

  # 2.1 Claude Web (claude.ai)
  M=$(fetch_meta "$TMP_DIR/claude_trace.txt" "https://claude.ai/cdn-cgi/trace")
  C_CODE="${M%%|*}"; REST="${M#*|}"; C_MS="${REST%%|*}"
  CLAUDE_IP=$(parse_trace_val "$TMP_DIR/claude_trace.txt" "ip")
  CLAUDE_LOC=$(parse_trace_val "$TMP_DIR/claude_trace.txt" "loc")
  CLAUDE_MASK=$(mask_ip "$CLAUDE_IP")
  if [ "$C_CODE" = "200" ] && [ -n "$CLAUDE_LOC" ]; then
    if is_blocked_ai_loc "$CLAUDE_LOC"; then
      record_item "ai" "Claude Web (claude.ai)" "fail" "$CLAUDE_LOC" "$C_MS" "出口位于不支持地区 (${CLAUDE_MASK})"
      WARNINGS+=("Claude 流量落入受限地区 [${CLAUDE_LOC}]：请将 Claude 策略组固定到美国 AI 或台湾家宽节点。")
    else
      record_item "ai" "Claude Web (claude.ai)" "ok" "$CLAUDE_LOC" "$C_MS" "出口 ${CLAUDE_MASK}"
    fi
  else
    record_item "ai" "Claude Web (claude.ai)" "fail" "" "$C_MS" "连接失败 (HTTP ${C_CODE})"
  fi

  # 2.2 Claude Code / Anthropic API
  M=$(fetch_meta "$TMP_DIR/anthropic_api.txt" "https://api.anthropic.com/v1/messages")
  A_CODE="${M%%|*}"; REST="${M#*|}"; A_MS="${REST%%|*}"
  if [ "$A_CODE" = "405" ] || [ "$A_CODE" = "401" ] || [ "$A_CODE" = "400" ]; then
    record_item "ai" "Claude Code API" "ok" "$CLAUDE_LOC" "$A_MS" "api.anthropic.com 握手正常"
  elif [ "$A_CODE" = "403" ]; then
    record_item "ai" "Claude Code API" "fail" "$CLAUDE_LOC" "$A_MS" "HTTP 403 被防火墙或地区策略拦截"
  else
    record_item "ai" "Claude Code API" "fail" "" "$A_MS" "连接异常 (HTTP ${A_CODE})"
  fi

  # 2.3 ChatGPT Web & Mobile App
  M=$(fetch_meta "$TMP_DIR/gpt_trace.txt" "https://chatgpt.com/cdn-cgi/trace")
  GPT_LOC=$(parse_trace_val "$TMP_DIR/gpt_trace.txt" "loc")
  GPT_IP=$(parse_trace_val "$TMP_DIR/gpt_trace.txt" "ip")
  GPT_MASK=$(mask_ip "$GPT_IP")

  M2=$(fetch_meta "$TMP_DIR/gpt_ios.json" "https://ios.chat.openai.com/public-api/mobile/server_status/v1")
  G_CODE="${M2%%|*}"; REST="${M2#*|}"; G_MS="${REST%%|*}"
  if [ "$G_CODE" = "200" ] && grep -q '"status":"normal"' "$TMP_DIR/gpt_ios.json" 2>/dev/null; then
    if is_blocked_ai_loc "$GPT_LOC"; then
      record_item "ai" "ChatGPT (Web + App)" "warn" "$GPT_LOC" "$G_MS" "接口返回正常但出口为受限区 (${GPT_MASK})"
    else
      record_item "ai" "ChatGPT (Web + App)" "ok" "$GPT_LOC" "$G_MS" "网页与移动端完整解锁 (${GPT_MASK})"
    fi
  elif grep -Eiq 'unsupported_country|vpn_detected|disallowed_isp' "$TMP_DIR/gpt_ios.json" 2>/dev/null; then
    record_item "ai" "ChatGPT (Web + App)" "warn" "$GPT_LOC" "$G_MS" "移动端受限或出口被标记机房代理 (${GPT_MASK})"
  elif [ "$G_CODE" = "403" ]; then
    record_item "ai" "ChatGPT (Web + App)" "warn" "$GPT_LOC" "$G_MS" "触发 Cloudflare 盾或移动端风控 (${GPT_MASK})"
  else
    record_item "ai" "ChatGPT (Web + App)" "fail" "$GPT_LOC" "$G_MS" "不可用 (HTTP ${G_CODE})"
  fi

  # 2.4 OpenAI API / Codex CLI
  M=$(fetch_meta "$TMP_DIR/oai_api.json" "https://api.openai.com/v1/models")
  OA_CODE="${M%%|*}"; REST="${M#*|}"; OA_MS="${REST%%|*}"
  if [ "$OA_CODE" = "401" ]; then
    record_item "ai" "OpenAI Codex / API" "ok" "$GPT_LOC" "$OA_MS" "api.openai.com 鉴权端点可达"
  elif [ "$OA_CODE" = "403" ] || grep -q 'unsupported_country_region_territory' "$TMP_DIR/oai_api.json" 2>/dev/null; then
    record_item "ai" "OpenAI Codex / API" "fail" "$GPT_LOC" "$OA_MS" "地区受限 (unsupported_country)"
  else
    record_item "ai" "OpenAI Codex / API" "fail" "" "$OA_MS" "连接异常 (HTTP ${OA_CODE})"
  fi

  # 2.5 Google Gemini Web & API
  M=$(fetch_meta "$TMP_DIR/gemini_web.html" "https://gemini.google.com/app")
  GM_CODE="${M%%|*}"; REST="${M#*|}"; GM_MS="${REST%%|*}"; GM_EFF="${REST#*|}"
  if [ "$GM_CODE" = "200" ] && ! printf "%s" "$GM_EFF" | grep -Eiq '/faq|sorry/index'; then
    record_item "ai" "Google Gemini Web" "ok" "" "$GM_MS" "gemini.google.com 正常开放"
  elif printf "%s" "$GM_EFF" | grep -iq 'sorry/index'; then
    record_item "ai" "Google Gemini Web" "warn" "" "$GM_MS" "出口并发较高，触发 Google 人机验证"
  else
    record_item "ai" "Google Gemini Web" "fail" "" "$GM_MS" "当前出口地区未开放 (重定向至 FAQ 或 ${GM_CODE})"
    WARNINGS+=("Google Gemini 不可用：切勿将 Google / 其他 AI 策略组指向香港或无 AI 节点。")
  fi

  M=$(fetch_meta "$TMP_DIR/gemini_api.json" "https://generativelanguage.googleapis.com/v1beta/models")
  GMA_CODE="${M%%|*}"; REST="${M#*|}"; GMA_MS="${REST%%|*}"
  if grep -iq 'User location is not supported' "$TMP_DIR/gemini_api.json" 2>/dev/null; then
    record_item "ai" "Gemini API / AI Studio" "fail" "" "$GMA_MS" "User location is not supported"
  elif [ "$GMA_CODE" = "403" ] || [ "$GMA_CODE" = "400" ]; then
    record_item "ai" "Gemini API / AI Studio" "ok" "" "$GMA_MS" "generativelanguage API 正常"
  else
    record_item "ai" "Gemini API / AI Studio" "fail" "" "$GMA_MS" "连接异常 (HTTP ${GMA_CODE})"
  fi

  # 2.6 Cursor & GitHub Copilot
  M=$(fetch_meta "$TMP_DIR/cursor.txt" "https://api2.cursor.sh")
  CU_CODE="${M%%|*}"; REST="${M#*|}"; CU_MS="${REST%%|*}"
  M2=$(fetch_meta "$TMP_DIR/copilot.txt" "https://api.githubcopilot.com/_ping")
  CP_CODE="${M2%%|*}"; REST2="${M2#*|}"; CP_MS="${REST2%%|*}"
  if [ "$CU_CODE" = "200" ] && [ "$CP_CODE" = "200" ]; then
    record_item "ai" "Cursor & Copilot" "ok" "" "$CU_MS" "Cursor ${CU_MS}ms / Copilot ${CP_MS}ms"
  elif [ "$CU_CODE" = "200" ] || [ "$CP_CODE" = "200" ]; then
    record_item "ai" "Cursor & Copilot" "warn" "" "$CU_MS" "Cursor HTTP ${CU_CODE} / Copilot HTTP ${CP_CODE}"
  else
    record_item "ai" "Cursor & Copilot" "fail" "" "$CU_MS" "Cursor HTTP ${CU_CODE} / Copilot HTTP ${CP_CODE}"
  fi

  # 2.7 Google AI Studio & Stripe Billing Endpoint
  M=$(fetch_meta "$TMP_DIR/aistudio.html" "https://aistudio.google.com/")
  AS_CODE="${M%%|*}"; REST="${M#*|}"; AS_MS="${REST%%|*}"; AS_EFF="${REST#*|}"
  if [ "$AS_CODE" = "200" ] && ! printf "%s" "$AS_EFF" | grep -Eiq 'available_regions|sorry/index'; then
    record_item "ai" "Google AI Studio" "ok" "" "$AS_MS" "aistudio.google.com 正常开放"
  else
    record_item "ai" "Google AI Studio" "warn" "" "$AS_MS" "当前出口地区受限或需验证 (${AS_CODE})"
  fi

  M=$(fetch_meta "$TMP_DIR/stripe.txt" "https://api.stripe.com/healthcheck")
  ST_CODE="${M%%|*}"; REST="${M#*|}"; ST_MS="${REST%%|*}"
  if [ "$ST_CODE" = "200" ]; then
    record_item "ai" "Stripe 订阅收银台" "ok" "" "$ST_MS" "api.stripe.com 可达（建议与 Claude 同出口）"
  else
    record_item "ai" "Stripe 订阅收银台" "warn" "" "$ST_MS" "连接受限 (HTTP ${ST_CODE})"
  fi

  # Split-routing insight
  if [ -n "$CLAUDE_IP" ] && [ -n "$GPT_IP" ] && [ "$CLAUDE_IP" != "$GPT_IP" ] && [ "$JSON_OUT" -eq 0 ]; then
    printf "  %s↳ 检测到按服务智能分流：Claude (%s [%s]) ≠ ChatGPT (%s [%s])%s\n" \
      "$C_CYAN" "$CLAUDE_MASK" "$CLAUDE_LOC" "$GPT_MASK" "$GPT_LOC" "$C_RESET"
  fi
fi

# 3. Regional Streaming Checks
if [ "$RUN_STREAM" -eq 1 ]; then
  [ "$JSON_OUT" -eq 0 ] && printf "\n%s[3] 台湾与全球流媒体解锁%s\n" "$C_BOLD" "$C_RESET"

  # 3.1 Bahamut Anime Crazy (Taiwan Native check)
  M=$(fetch_meta "$TMP_DIR/baha.json" "https://ani.gamer.com.tw/ajax/token.php?adID=89422&sn=37783")
  BH_CODE="${M%%|*}"; REST="${M#*|}"; BH_MS="${REST%%|*}"
  if [ "$BH_CODE" = "200" ] && grep -q 'animeSn' "$TMP_DIR/baha.json" 2>/dev/null; then
    record_item "stream" "巴哈姆特动画疯" "ok" "TW" "$BH_MS" "台湾原生/家宽解锁"
  else
    record_item "stream" "巴哈姆特动画疯" "warn" "" "$BH_MS" "仅限台湾原生 IP 解锁"
  fi

  # 3.2 Netflix (Non-Original 81280792 + Original 80018499)
  NF_HDR="$TMP_DIR/nf_hdr.txt"
  NF_RAW=$(curl -sS -L --max-time "$TIMEOUT" -A "$UA" ${CURL_PROXY_ARGS[@]+"${CURL_PROXY_ARGS[@]}"} \
    -D "$NF_HDR" -o "$TMP_DIR/nf1.html" -w '%{http_code}|%{time_total}' \
    "https://www.netflix.com/title/81280792" 2>/dev/null) || NF_RAW="000|0"
  NF_CODE="${NF_RAW%%|*}"
  NF_MS=$(awk -v s="${NF_RAW#*|}" 'BEGIN { printf "%d", (s + 0) * 1000 }')
  NF_ORIG_URL=$(grep -i '^x-originating-url:' "$NF_HDR" 2>/dev/null | tail -n 1 | tr -d '\r\n')
  NF_REG=$(printf "%s" "$NF_ORIG_URL" | sed -n 's#.*netflix\.com/\([a-zA-Z]\{2\}\)\(-[a-zA-Z]*\)\{0,1\}/title/.*#\1#p' | tr '[:lower:]' '[:upper:]')
  [ -z "$NF_REG" ] && [ "$NF_CODE" = "200" ] && NF_REG="US"

  if [ "$NF_CODE" = "200" ]; then
    record_item "stream" "Netflix" "ok" "$NF_REG" "$NF_MS" "完整解锁非自制剧与自制剧"
  else
    M_O=$(fetch_meta "$TMP_DIR/nf2.html" "https://www.netflix.com/title/80018499")
    NFO_CODE="${M_O%%|*}"
    if [ "$NFO_CODE" = "200" ]; then
      record_item "stream" "Netflix" "warn" "" "$NF_MS" "仅解锁 Netflix 自制剧 (Originals Only)"
    else
      record_item "stream" "Netflix" "fail" "" "$NF_MS" "当前出口未解锁 (HTTP ${NF_CODE})"
    fi
  fi

  # 3.3 YouTube Premium
  M=$(fetch_meta "$TMP_DIR/yt.html" "https://www.youtube.com/red" -H "Accept-Language: en-US,en;q=0.9")
  YT_CODE="${M%%|*}"; REST="${M#*|}"; YT_MS="${REST%%|*}"
  YT_GL=$(sed -n 's/.*"INNERTUBE_CONTEXT_GL":"\([A-Z]\{2\}\)".*/\1/p' "$TMP_DIR/yt.html" | head -n 1)
  [ -z "$YT_GL" ] && YT_GL=$(sed -n 's/.*"countryCode":"\([A-Z]\{2\}\)".*/\1/p' "$TMP_DIR/yt.html" | head -n 1)
  if [ "$YT_CODE" = "200" ] && ! grep -Eiq 'Premium is not available in your country' "$TMP_DIR/yt.html" 2>/dev/null; then
    record_item "stream" "YouTube Premium" "ok" "$YT_GL" "$YT_MS" "可正常订阅与后台播放"
  elif [ "$YT_CODE" = "200" ]; then
    record_item "stream" "YouTube Premium" "warn" "$YT_GL" "$YT_MS" "该地区暂未开放 Premium"
  else
    record_item "stream" "YouTube Premium" "fail" "" "$YT_MS" "无法连接 YouTube (HTTP ${YT_CODE})"
  fi

  # 3.4 Disney+
  M=$(fetch_meta "$TMP_DIR/dp.html" "https://www.disneyplus.com/")
  DP_CODE="${M%%|*}"; REST="${M#*|}"; DP_MS="${REST%%|*}"; DP_EFF="${REST#*|}"
  if [ "$DP_CODE" = "200" ] && ! printf "%s" "$DP_EFF" | grep -Eiq 'unavailable|error'; then
    DP_REG=$(printf "%s" "$DP_EFF" | sed -n 's#.*disneyplus\.com/\([a-z]\{2\}-[a-z]\{2\}\).*#\1#p' | awk -F- '{print toupper($2)}')
    record_item "stream" "Disney+" "ok" "$DP_REG" "$DP_MS" "区域入口可达"
  else
    record_item "stream" "Disney+" "warn" "" "$DP_MS" "当前出口地区未开放或受限 (HTTP ${DP_CODE})"
  fi

  # 3.5 TikTok Web
  M=$(fetch_meta "$TMP_DIR/tt.html" "https://www.tiktok.com/explore")
  TT_CODE="${M%%|*}"; REST="${M#*|}"; TT_MS="${REST%%|*}"
  TT_REG=$(sed -n 's/.*"region":"\([A-Z]\{2\}\)".*/\1/p' "$TMP_DIR/tt.html" | head -n 1)
  if [ "$TT_CODE" = "200" ] && [ "$TT_REG" != "CN" ] && [ "$TT_REG" != "HK" ]; then
    record_item "stream" "TikTok" "ok" "$TT_REG" "$TT_MS" "海外区域访问正常"
  else
    record_item "stream" "TikTok" "warn" "$TT_REG" "$TT_MS" "出口受限（请避开香港/大陆节点，HTTP ${TT_CODE}）"
  fi
fi

# Output JSON or Summary Footer
if [ "$JSON_OUT" -eq 1 ]; then
  ITEMS_JOINED=""
  for it in ${JSON_ITEMS[@]+"${JSON_ITEMS[@]}"}; do
    [ -n "$ITEMS_JOINED" ] && ITEMS_JOINED="${ITEMS_JOINED},"
    ITEMS_JOINED="${ITEMS_JOINED}${it}"
  done
  printf '{"version":"%s","exit":{"ip":"%s","country":"%s","asn":"%s","type":"%s","colo":"%s"},"results":[%s]}\n' \
    "$VERSION" "$(json_escape "$MASKED_DEFAULT_IP")" "$(json_escape "$CF_LOC")" \
    "$(json_escape "$ASN_INFO")" "$(json_escape "$IP_TYPE_HINT")" "$(json_escape "$CF_COLO")" "$ITEMS_JOINED"
  exit 0
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
  printf "\n%s[诊断建议]%s\n" "$C_BOLD" "$C_RESET"
  for w in ${WARNINGS[@]+"${WARNINGS[@]}"}; do
    printf "  %s• %s%s\n" "$C_YELLOW" "$w" "$C_RESET"
  done
fi

printf "\n%sRepo: https://github.com/fanqiao-net/ai-ip-check  |  AI 分流规则与 TUN 指南: https://fanqiao.net/guide/ai-coding?utm_source=gh-ipcheck%s\n\n" "$C_DIM" "$C_RESET"
