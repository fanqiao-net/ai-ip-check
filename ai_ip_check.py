#!/usr/bin/env python3
"""
ai-ip-check — Concurrent zero-dependency CLI for AI Coding (Claude / ChatGPT / Gemini / Cursor)
& Regional Streaming (Bahamut / Netflix / YouTube Premium / Disney+) connectivity diagnostics.

Works on Windows, macOS, and Linux with Python 3.8+ standard library only.
Repository: https://github.com/fanqiao-net/ai-ip-check | License: MIT
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

VERSION = "1.1.0"
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
AI_BLOCKED = {"CN", "HK", "MO", "RU", "BY", "IR", "KP", "SY", "CU"}
RESIDENTIAL_PAT = re.compile(
    r"Chunghwa|HiNet|Taiwan Fixed|Seednet|Far EasTone|Taiwan Mobile|HKBN|HKT|"
    r"NTT|KDDI|SoftBank|So-net|KT Corp|SK Broadband|LG Uplus|"
    r"Comcast|AT&T|Verizon|Charter|Cox|Deutsche Telekom|BT|Orange|Free SAS",
    re.I,
)


def mask_ip(ip: str, full: bool = False) -> str:
    if not ip:
        return "unknown"
    if full:
        return ip
    if re.match(r"^\d{1,3}(?:\.\d{1,3}){3}$", ip):
        parts = ip.split(".")
        return f"{parts[0]}.{parts[1]}.*.*"
    if ":" in ip:
        parts = ip.split(":")
        return f"{parts[0]}:{parts[1]}:*:*"
    return ip


def build_opener(proxy: Optional[str]) -> urllib.request.OpenerDirector:
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )
    return urllib.request.build_opener()


def http_fetch(
    opener: urllib.request.OpenerDirector,
    url: str,
    timeout: float = 8.0,
    headers: Optional[Dict[str, str]] = None,
    max_bytes: int = 131072,
) -> Tuple[int, int, str, Dict[str, str], str]:
    t0 = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    try:
        with opener.open(req, timeout=timeout) as r:
            body = r.read(max_bytes).decode("utf-8", "replace")
            ms = int((time.monotonic() - t0) * 1000)
            hdrs = {k.lower(): v for k, v in r.headers.items()}
            return r.status, ms, r.url, hdrs, body
    except urllib.error.HTTPError as e:
        body = e.read(max_bytes).decode("utf-8", "replace") if e.fp else ""
        ms = int((time.monotonic() - t0) * 1000)
        hdrs = {k.lower(): v for k, v in e.headers.items()} if e.headers else {}
        return e.code, ms, e.url or url, hdrs, body
    except Exception as exc:
        ms = int((time.monotonic() - t0) * 1000)
        return 0, ms, url, {}, str(exc)


def parse_trace(text: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    ap = argparse.ArgumentParser(description="AI Coding & Streaming Connectivity Diagnostic")
    ap.add_argument("-x", "--proxy", help="HTTP/HTTPS proxy URL, e.g. http://127.0.0.1:7897")
    ap.add_argument("-m", "--timeout", type=float, default=8.0, help="Timeout per probe in seconds")
    ap.add_argument("--ai-only", action="store_true", help="Run AI & developer API checks only")
    ap.add_argument("--stream-only", action="store_true", help="Run streaming unlock checks only")
    ap.add_argument("--full-ip", action="store_true", help="Display full exit IP without masking")
    ap.add_argument("--json", dest="json_out", action="store_true", help="Output structured JSON")
    args = ap.parse_args()

    run_ai = not args.stream_only
    run_stream = not args.ai_only
    opener = build_opener(args.proxy)

    tty = sys.stdout.isatty() and not args.json_out
    C_RST = "\033[0m" if tty else ""
    C_BLD = "\033[1m" if tty else ""
    C_DIM = "\033[2m" if tty else ""
    C_GRN = "\033[32m" if tty else ""
    C_YLW = "\033[33m" if tty else ""
    C_RED = "\033[31m" if tty else ""
    C_CYN = "\033[36m" if tty else ""

    tasks: Dict[str, Tuple[str, Optional[Dict[str, str]]]] = {
        "cf_trace": ("https://www.cloudflare.com/cdn-cgi/trace", None),
        "ipsb": ("https://api.ip.sb/geoip", {"Accept": "application/json"}),
    }
    if run_ai:
        tasks.update({
            "claude_trace": ("https://claude.ai/cdn-cgi/trace", None),
            "anthropic_api": ("https://api.anthropic.com/v1/messages", None),
            "gpt_trace": ("https://chatgpt.com/cdn-cgi/trace", None),
            "gpt_ios": ("https://ios.chat.openai.com/public-api/mobile/server_status/v1", None),
            "openai_api": ("https://api.openai.com/v1/models", None),
            "gemini_web": ("https://gemini.google.com/app", None),
            "gemini_api": ("https://generativelanguage.googleapis.com/v1beta/models", None),
            "aistudio": ("https://aistudio.google.com/", None),
            "stripe": ("https://api.stripe.com/healthcheck", None),
            "cursor": ("https://api2.cursor.sh", None),
            "copilot": ("https://api.githubcopilot.com/_ping", None),
        })
    if run_stream:
        tasks.update({
            "bahamut": ("https://ani.gamer.com.tw/ajax/token.php?adID=89422&sn=37783", None),
            "nf_nonorig": ("https://www.netflix.com/title/81280792", None),
            "nf_orig": ("https://www.netflix.com/title/80018499", None),
            "yt_red": ("https://www.youtube.com/red", {"Accept-Language": "en-US,en;q=0.9"}),
            "disney": ("https://www.disneyplus.com/", None),
            "tiktok": ("https://www.tiktok.com/explore", None),
        })

    raw: Dict[str, Tuple[int, int, str, Dict[str, str], str]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futs = {
            pool.submit(http_fetch, opener, url, args.timeout, hdrs): key
            for key, (url, hdrs) in tasks.items()
        }
        for fut in concurrent.futures.as_completed(futs):
            raw[futs[fut]] = fut.result()

    cf_kv = parse_trace(raw["cf_trace"][4]) if raw["cf_trace"][0] == 200 else {}
    cf_ip = cf_kv.get("ip", "")
    cf_loc = cf_kv.get("loc", "")
    cf_colo = cf_kv.get("colo", "")
    asn_info = ""
    ip_type = ""
    if raw["ipsb"][0] == 200:
        try:
            j = json.loads(raw["ipsb"][4])
            cf_ip = cf_ip or str(j.get("ip", ""))
            cf_loc = cf_loc or str(j.get("country_code", ""))
            asn = j.get("asn")
            org = j.get("asn_organization") or j.get("isp") or ""
            if asn or org:
                asn_info = f"AS{asn} {org}".strip()
                ip_type = "家宽/本土运营商 ASN" if RESIDENTIAL_PAT.search(org) else "数据中心/商业网络 ASN"
        except Exception:
            pass

    masked_default = mask_ip(cf_ip, args.full_ip)
    results: List[Dict[str, Any]] = []
    warnings: List[str] = []

    if cf_loc == "CN":
        warnings.append("当前终端默认出口为中国大陆 [CN]：请开启客户端 TUN 虚拟网卡模式或配置 HTTPS_PROXY。")

    def add(cat: str, name: str, status: str, region: str, ms: int, detail: str) -> None:
        results.append({
            "category": cat,
            "name": name,
            "status": status,
            "region": region,
            "latency_ms": ms,
            "detail": detail,
        })

    claude_ip = ""
    claude_loc = ""
    gpt_ip = ""
    gpt_loc = ""

    if run_ai:
        c_code, c_ms, _, _, c_body = raw["claude_trace"]
        ckv = parse_trace(c_body) if c_code == 200 else {}
        claude_ip, claude_loc = ckv.get("ip", ""), ckv.get("loc", "")
        cmask = mask_ip(claude_ip, args.full_ip)
        if c_code == 200 and claude_loc:
            if claude_loc in AI_BLOCKED:
                add("ai", "Claude Web (claude.ai)", "fail", claude_loc, c_ms, f"出口位于受限地区 ({cmask})")
                warnings.append(f"Claude 落入不支持地区 [{claude_loc}]：请将 Claude 策略组固定到美国 AI 或台湾家宽节点。")
            else:
                add("ai", "Claude Web (claude.ai)", "ok", claude_loc, c_ms, f"出口 {cmask}")
        else:
            add("ai", "Claude Web (claude.ai)", "fail", "", c_ms, f"连接失败 (HTTP {c_code})")

        a_code, a_ms, _, _, _ = raw["anthropic_api"]
        if a_code in (400, 401, 405):
            add("ai", "Claude Code API", "ok", claude_loc, a_ms, "api.anthropic.com 握手正常")
        elif a_code == 403:
            add("ai", "Claude Code API", "fail", claude_loc, a_ms, "HTTP 403 被防火墙或地区策略拦截")
        else:
            add("ai", "Claude Code API", "fail", "", a_ms, f"连接异常 (HTTP {a_code})")

        gt_code, _, _, _, gt_body = raw["gpt_trace"]
        gkv = parse_trace(gt_body) if gt_code == 200 else {}
        gpt_ip, gpt_loc = gkv.get("ip", ""), gkv.get("loc", "")
        gmask = mask_ip(gpt_ip, args.full_ip)

        gi_code, gi_ms, _, _, gi_body = raw["gpt_ios"]
        if gi_code == 200 and '"status":"normal"' in gi_body:
            st = "warn" if gpt_loc in AI_BLOCKED else "ok"
            add("ai", "ChatGPT (Web + App)", st, gpt_loc, gi_ms, f"网页与移动端完整解锁 ({gmask})")
        elif re.search(r"unsupported_country|vpn_detected|disallowed_isp", gi_body, re.I):
            add("ai", "ChatGPT (Web + App)", "warn", gpt_loc, gi_ms, f"移动端受限或被识别机房代理 ({gmask})")
        elif gi_code == 403:
            add("ai", "ChatGPT (Web + App)", "warn", gpt_loc, gi_ms, f"触发 Cloudflare 盾或风控 ({gmask})")
        else:
            add("ai", "ChatGPT (Web + App)", "fail", gpt_loc, gi_ms, f"不可用 (HTTP {gi_code})")

        oa_code, oa_ms, _, _, oa_body = raw["openai_api"]
        if oa_code == 401:
            add("ai", "OpenAI Codex / API", "ok", gpt_loc, oa_ms, "api.openai.com 鉴权端点可达")
        elif oa_code == 403 or "unsupported_country_region_territory" in oa_body:
            add("ai", "OpenAI Codex / API", "fail", gpt_loc, oa_ms, "地区受限 (unsupported_country)")
        else:
            add("ai", "OpenAI Codex / API", "fail", "", oa_ms, f"连接异常 (HTTP {oa_code})")

        gm_code, gm_ms, gm_url, _, _ = raw["gemini_web"]
        if gm_code == 200 and not re.search(r"/faq|sorry/index", gm_url, re.I):
            add("ai", "Google Gemini Web", "ok", "", gm_ms, "gemini.google.com 正常开放")
        elif "sorry/index" in gm_url.lower():
            add("ai", "Google Gemini Web", "warn", "", gm_ms, "触发 Google 人机验证")
        else:
            add("ai", "Google Gemini Web", "fail", "", gm_ms, f"当前出口未开放 ({gm_code})")
            warnings.append("Google Gemini 不可用：切勿将 Google / 其他 AI 策略组指向香港或无 AI 节点。")

        gma_code, gma_ms, _, _, gma_body = raw["gemini_api"]
        if "user location is not supported" in gma_body.lower():
            add("ai", "Gemini API / AI Studio", "fail", "", gma_ms, "User location is not supported")
        elif gma_code in (400, 403):
            add("ai", "Gemini API / AI Studio", "ok", "", gma_ms, "generativelanguage API 正常")
        else:
            add("ai", "Gemini API / AI Studio", "fail", "", gma_ms, f"连接异常 (HTTP {gma_code})")

        cu_code, cu_ms, _, _, _ = raw["cursor"]
        cp_code, cp_ms, _, _, _ = raw["copilot"]
        if cu_code == 200 and cp_code == 200:
            add("ai", "Cursor & Copilot", "ok", "", cu_ms, f"Cursor {cu_ms}ms / Copilot {cp_ms}ms")
        elif cu_code == 200 or cp_code == 200:
            add("ai", "Cursor & Copilot", "warn", "", cu_ms, f"Cursor HTTP {cu_code} / Copilot HTTP {cp_code}")
        else:
            add("ai", "Cursor & Copilot", "fail", "", cu_ms, f"Cursor HTTP {cu_code} / Copilot HTTP {cp_code}")

        as_code, as_ms, as_url, _, _ = raw["aistudio"]
        if as_code == 200 and not re.search(r"available_regions|sorry/index", as_url, re.I):
            add("ai", "Google AI Studio", "ok", "", as_ms, "aistudio.google.com 正常开放")
        else:
            add("ai", "Google AI Studio", "warn", "", as_ms, f"当前出口地区受限或需验证 ({as_code})")

        st_code, st_ms, _, _, _ = raw["stripe"]
        if st_code == 200:
            add("ai", "Stripe 订阅收银台", "ok", "", st_ms, "api.stripe.com 可达（建议与 Claude 同出口）")
        else:
            add("ai", "Stripe 订阅收银台", "warn", "", st_ms, f"连接受限 (HTTP {st_code})")

    if run_stream:
        bh_code, bh_ms, _, _, bh_body = raw["bahamut"]
        if bh_code == 200 and "animeSn" in bh_body:
            add("stream", "巴哈姆特动画疯", "ok", "TW", bh_ms, "台湾原生/家宽解锁")
        else:
            add("stream", "巴哈姆特动画疯", "warn", "", bh_ms, "仅限台湾原生 IP 解锁")

        nf_code, nf_ms, nf_url, nf_hdrs, _ = raw["nf_nonorig"]
        orig_u = nf_hdrs.get("x-originating-url", nf_url)
        m_nf = re.search(r"netflix\.com/([a-z]{2})(?:-[a-z]+)?/title/", orig_u, re.I)
        nf_reg = m_nf.group(1).upper() if m_nf else ("US" if nf_code == 200 else "")
        if nf_code == 200:
            add("stream", "Netflix", "ok", nf_reg, nf_ms, "完整解锁非自制剧与自制剧")
        elif raw["nf_orig"][0] == 200:
            add("stream", "Netflix", "warn", "", nf_ms, "仅解锁 Netflix 自制剧 (Originals Only)")
        else:
            add("stream", "Netflix", "fail", "", nf_ms, f"当前出口未解锁 (HTTP {nf_code})")

        yt_code, yt_ms, _, _, yt_body = raw["yt_red"]
        m_yt = re.search(r'"INNERTUBE_CONTEXT_GL":"([A-Z]{2})"|"countryCode":"([A-Z]{2})"', yt_body)
        yt_gl = (m_yt.group(1) or m_yt.group(2)) if m_yt else ""
        if yt_code == 200 and "premium is not available in your country" not in yt_body.lower():
            add("stream", "YouTube Premium", "ok", yt_gl, yt_ms, "可正常订阅与后台播放")
        elif yt_code == 200:
            add("stream", "YouTube Premium", "warn", yt_gl, yt_ms, "该地区暂未开放 Premium")
        else:
            add("stream", "YouTube Premium", "fail", "", yt_ms, f"无法连接 YouTube (HTTP {yt_code})")

        dp_code, dp_ms, dp_url, _, _ = raw["disney"]
        if dp_code == 200 and not re.search(r"unavailable|error", dp_url, re.I):
            m_dp = re.search(r"disneyplus\.com/[a-z]{2}-([a-z]{2})", dp_url, re.I)
            add("stream", "Disney+", "ok", m_dp.group(1).upper() if m_dp else "", dp_ms, "区域入口可达")
        else:
            add("stream", "Disney+", "warn", "", dp_ms, f"当前出口地区未开放或受限 (HTTP {dp_code})")

        tt_code, tt_ms, _, _, tt_body = raw["tiktok"]
        m_tt = re.search(r'"region":"([A-Z]{2})"', tt_body)
        tt_reg = m_tt.group(1) if m_tt else ""
        if tt_code == 200 and tt_reg not in ("CN", "HK"):
            add("stream", "TikTok", "ok", tt_reg, tt_ms, "海外区域访问正常")
        else:
            add("stream", "TikTok", "warn", tt_reg, tt_ms, f"出口受限（请避开香港/大陆节点，HTTP {tt_code}）")

    if args.json_out:
        print(json.dumps({
            "version": VERSION,
            "exit": {
                "ip": masked_default,
                "country": cf_loc,
                "asn": asn_info,
                "type": ip_type,
                "colo": cf_colo,
            },
            "warnings": warnings,
            "results": results,
        }, ensure_ascii=False, indent=2))
        return 0

    print(f"\n{C_BLD}=== AI Coding & Streaming Connectivity Diagnostic (v{VERSION}) ==={C_RST}")
    mode = f"Proxy {args.proxy}" if args.proxy else "当前终端直测"
    print(f"{C_DIM}Mode:  {mode} (IP 默认脱敏，完整显示加 --full-ip){C_RST}")
    print(f"\n{C_BLD}[1] 终端默认出口画像{C_RST}")
    print(f"  默认出口 IP : {C_CYN}{masked_default}{C_RST} ({cf_loc or '未知'})")
    if asn_info:
        print(f"  所属运营商  : {asn_info} ({ip_type})")
    if cf_colo:
        print(f"  边缘接入点  : Cloudflare {cf_colo}")

    def disp_pad(s: str, width: int) -> str:
        w = sum(2 if ord(ch) > 127 else 1 for ch in s)
        return s + " " * max(0, width - w)

    def render_cat(cat: str, title: str) -> None:
        sub = [r for r in results if r["category"] == cat]
        if not sub:
            return
        print(f"\n{C_BLD}{title}{C_RST}")
        for r in sub:
            st = r["status"]
            badge, col = ("✓ 可用", C_GRN) if st == "ok" else (("△ 受限", C_YLW) if st == "warn" else ("✗ 不可用", C_RED))
            reg = f"[{r['region']}] " if r["region"] else ""
            ms = f" ({r['latency_ms']}ms)" if r["latency_ms"] > 0 else ""
            print(f"  {disp_pad(r['name'], 24)} {col}{disp_pad(badge, 10)}{C_RST} {reg}{r['detail']}{C_DIM}{ms}{C_RST}")

    render_cat("ai", "[2] AI 编程与大模型连通性")
    if run_ai and claude_ip and gpt_ip and claude_ip != gpt_ip:
        print(
            f"  {C_CYN}↳ 检测到按服务智能分流：Claude ({mask_ip(claude_ip, args.full_ip)} [{claude_loc}]) "
            f"≠ ChatGPT ({mask_ip(gpt_ip, args.full_ip)} [{gpt_loc}]){C_RST}"
        )
    render_cat("stream", "[3] 台湾与全球流媒体解锁")

    if warnings:
        print(f"\n{C_BLD}[诊断建议]{C_RST}")
        for w in warnings:
            print(f"  {C_YLW}• {w}{C_RST}")

    print(
        f"\n{C_DIM}Repo: https://github.com/fanqiao-net/ai-ip-check  |  "
        f"AI 分流规则与 TUN 指南: https://fanqiao.net/guide/ai-coding?utm_source=gh-ipcheck{C_RST}\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
