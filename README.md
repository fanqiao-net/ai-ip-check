# ai-ip-check · AI 编程与流媒体终端连通性一键自检工具

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Zero Dependency](https://img.shields.io/badge/deps-zero%20(curl%20%2F%20python3)-blue.svg)](#快速开始)

面向 **Claude Code、Cursor、OpenAI Codex CLI、Gemini CLI / AI Studio、GitHub Copilot** 以及 **台湾巴哈姆特动画疯、Netflix、YouTube Premium、Disney+** 的零依赖终端连通性与分流一致性自检脚本。

由 **[fanqiao·帆桥（帆桥VPN / 帆桥机场，官网 fanqiao.net）](https://fanqiao.net/)** 开源维护。**零遥测、不收集任何数据、默认自动脱敏出口 IP（`a.b.*.*`）**，检测结果可直接放心截图或复制到社区回帖，不会泄露节点 IP。

---

## 为什么需要这个工具？

很多开发者经常遇到 **「浏览器能正常打开 Claude / ChatGPT，但终端里的 Claude Code / Codex CLI 或 Cursor / Windsurf 却报 `Unable to connect to Anthropic services`、`Connection failed (VPN/HTTP2)`、`Unusual activity has been detected`、`unsupported_country_region_territory` 或 `403 Forbidden`」**。常见根因有 3 类：

1. **终端进程不读系统代理**：Node.js `fetch`、Python `httpx`、Go/Rust CLI 默认忽略 macOS/Windows 的系统 HTTP 代理，未开 **TUN 虚拟网卡模式** 或未导出 `HTTPS_PROXY` 时实际走了本地直连（`CN`）。
2. **策略组分流漂移**：主域名走了美国节点，但 API 域名（`api.anthropic.com`、`generativelanguage.googleapis.com`）或支付/风控域名落入了香港（`HK`）或无 AI 节点。
3. **机房段风控与非原生广播 IP**：出口 ASN 被识别为高并发机房代理，导致 ChatGPT App 报 `disallowed_isp` 或台湾巴哈姆特/Netflix 非自制剧无法播放。

`ai-ip-check` 会在 **2–5 秒内** 实测你的**真实终端环境**（或指定代理端口），并自动对比 Claude 与 ChatGPT 是否命中独立分流出口。

---

## 快速开始

### 1. macOS / Linux / WSL / OpenWrt（纯 `curl` 单行运行）

```bash
curl -fsSL https://raw.githubusercontent.com/fanqiao-net/ai-ip-check/main/check.sh | bash
```

不改系统环境、直接指定本地代理端口测试（例如 Clash Verge Rev 默认端口 `7897` 或 Mihomo `7890`）：

```bash
curl -fsSL https://raw.githubusercontent.com/fanqiao-net/ai-ip-check/main/check.sh | bash -s -- -x http://127.0.0.1:7897
```

### 2. Windows PowerShell / 跨平台并发极速版（Python 3 标准库，约 2 秒跑完）

```powershell
# 下载并并发检测（无需 pip 安装任何第三方库）
curl.exe -fsSL https://raw.githubusercontent.com/fanqiao-net/ai-ip-check/main/ai_ip_check.py -o ai_ip_check.py
python ai_ip_check.py -x http://127.0.0.1:7897
```

### 3. JSON 机器可读输出（适用于自动化巡检 / 状态栏脚本）

```bash
bash check.sh --ai-only --json
python3 ai_ip_check.py --json
```

---

## 输出示例

```text
=== AI Coding & Streaming Connectivity Diagnostic (v1.0.0) ===
Mode:  当前终端直测 (IP 默认脱敏，完整显示加 --full-ip)

[1] 终端默认出口画像
  默认出口 IP : 198.51.*.* (TW)
  所属运营商  : AS3462 Data Communication Business Group (家宽/本土运营商 ASN)
  边缘接入点  : Cloudflare TPE

[2] AI 编程与大模型连通性
  Claude Web (claude.ai)   ✓ 可用     [US] 出口 203.0.*.* (185ms)
  Claude Code API          ✓ 可用     [US] api.anthropic.com 握手正常 (192ms)
  ChatGPT (Web + App)      ✓ 可用     [TW] 网页与移动端完整解锁 (198.51.*.*) (118ms)
  OpenAI Codex / API       ✓ 可用     [TW] api.openai.com 鉴权端点可达 (124ms)
  Google Gemini Web        ✓ 可用     gemini.google.com 正常开放 (145ms)
  Gemini API / AI Studio   ✓ 可用     generativelanguage API 正常 (112ms)
  Cursor & Copilot         ✓ 可用     Cursor 178ms / Copilot 164ms (178ms)
  ↳ 检测到按服务智能分流：Claude (203.0.*.* [US]) ≠ ChatGPT (198.51.*.* [TW])

[3] 台湾与全球流媒体解锁
  巴哈姆特动画疯           ✓ 可用     [TW] 台湾原生/家宽解锁 (86ms)
  Netflix                  ✓ 可用     [TW] 完整解锁非自制剧与自制剧 (142ms)
  YouTube Premium          ✓ 可用     [TW] 可正常订阅与后台播放 (110ms)
  Disney+                  ✓ 可用     [TW] 区域入口可达 (128ms)
```

---

## 命令行参数

| 参数 | 说明 |
|---|---|
| `-x, --proxy <URL>` | 指定 HTTP / SOCKS5 代理地址（如 `http://127.0.0.1:7897`） |
| `-m, --timeout <SEC>` | 单项请求超时秒数（默认 `8` 秒） |
| `--ai-only` | 仅检测 AI 编程与大模型接口（Claude / ChatGPT / Gemini / Cursor / Copilot） |
| `--stream-only` | 仅检测流媒体解锁（巴哈姆特动画疯 / Netflix / YouTube Premium / Disney+） |
| `--full-ip` | 显示完整出口 IP（默认脱敏为 `a.b.*.*`，便于论坛/群聊安全贴图） |
| `--json` | 输出标准 JSON 结构化结果 |

---

## 常见异常修复对照表

| 检测现象 | 根因说明 | 解决方案与参考规则 |
|---|---|---|
| 默认出口显示 `[CN]` | 终端未走代理，仅开了浏览器系统代理 | 开启客户端 **TUN 虚拟网卡模式**，或导出 `HTTPS_PROXY` → [AI 编程与 TUN 配置指南](https://fanqiao.net/guide/ai-coding) |
| Claude / Gemini 显示 `[HK]` 不可用 | 香港出口不在 Anthropic / Gemini 支持列表，或分流规则漏配 | 导入固定 AI 策略组规则 → [开源分流规则库 `fanqiao-rules`](https://github.com/fanqiao-net/fanqiao-rules) |
| ChatGPT 提示移动端受限 / 频繁弹盾 | 机房共享段风控较高，或 DNS / WebRTC 泄露 | 切换至 **台湾家宽原生 IP** 或纯净美国 AI 专线 → [台湾家宽原生 IP 解析](https://fanqiao.net/guide/taiwan-native-ip) · [DNS 防泄露指南](https://fanqiao.net/guide/dns-webrtc-leak) |
| 巴哈姆特动画疯受限 / Netflix 仅自制剧 | 当前节点非台湾本地固网（如 HiNet）或非原生解锁段 | 切换至台湾家宽原生节点 → [流媒体跨区解锁指南](https://fanqiao.net/guide/streaming-unlock) |
| Docker / 本地后端调用 OpenAI/Claude 超时 | 容器网桥与宿主机 `127.0.0.1` 隔离 | 使用 `host.docker.internal` 或网关代理 → [本地 API 与 Docker 代理教程](https://fanqiao.net/guide/api-proxy-dev) |

---

## 相关开源项目与文档

- **2026 AI 编程代理与主流机场选型实测手册**：[`fanqiao-net/ai-proxy-guide-2026`](https://github.com/fanqiao-net/ai-proxy-guide-2026)（协议对比、1x 倍率账单分析、热门机场横向评测与报错速查）
- **客户端 AI 固定出口分流规则库**：[`fanqiao-net/fanqiao-rules`](https://github.com/fanqiao-net/fanqiao-rules)（Shadowrocket / Mihomo / Clash Verge Rev / Loon / sing-box 1.12+）
- **AI 常见英文报错代码速查修复表**：[`fanqiao.net/guide/ai-error-codes-fix`](https://fanqiao.net/guide/ai-error-codes-fix) ｜ [Cursor/Windsurf 连接失败修复](https://fanqiao.net/guide/cursor-windsurf-http2-fix) ｜ [AI Studio/NotebookLM 地区限制解决](https://fanqiao.net/guide/google-ai-studio-notebooklm-fix) ｜ [ChatGPT Plus / Claude Pro 订阅防封号](https://fanqiao.net/guide/chatgpt-plus-claude-pro-subscribe)
- **fanqiao·帆桥（帆桥VPN / 帆桥机场）官网**：<https://fanqiao.net/> ｜ [2026热门机场横向对比总表](https://fanqiao.net/compare) ｜ [53 篇全平台配置指南](https://fanqiao.net/guide) ｜ [公开探针状态](https://fanqiao.net/status)
- **防失联镜像导航**：<https://fanqiao-net.github.io/> ｜ <https://sites.google.com/view/fanqiao-vpn>

## License

[MIT License](LICENSE)
