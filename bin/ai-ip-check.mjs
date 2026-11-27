#!/usr/bin/env node
/**
 * ai-ip-check — Concurrent zero-dependency Node.js CLI for AI Coding (Claude / ChatGPT / Gemini / Cursor)
 * & Regional Streaming (Bahamut / Netflix / YouTube Premium / Disney+ / TikTok) connectivity diagnostics.
 *
 * Works on Windows, macOS, and Linux with Node.js 18+ standard library only (supports HTTP proxy CONNECT).
 * Repository: https://github.com/fanqiao-net/ai-ip-check | Homepage: https://fanqiao.net/guide/ai-coding
 */
import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';

const VERSION = '1.1.0';
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const AI_BLOCKED = new Set(['CN', 'HK', 'MO', 'RU', 'BY', 'IR', 'KP', 'SY', 'CU']);
const RESIDENTIAL_PAT =
  /Chunghwa|HiNet|Taiwan Fixed|Seednet|Far EasTone|Taiwan Mobile|HKBN|HKT|NTT|KDDI|SoftBank|So-net|KT Corp|SK Broadband|LG Uplus|Comcast|AT&T|Verizon|Charter|Cox|Deutsche Telekom|BT|Orange|Free SAS/i;

function maskIp(ip, full = false) {
  if (!ip) return 'unknown';
  if (full) return ip;
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(ip)) {
    const p = ip.split('.');
    return `${p[0]}.${p[1]}.*.*`;
  }
  if (ip.includes(':')) {
    const p = ip.split(':');
    return `${p[0]}:${p[1]}:*:*`;
  }
  return ip;
}

function parseTrace(text) {
  const out = {};
  for (const line of String(text || '').split(/\r?\n/)) {
    const idx = line.indexOf('=');
    if (idx > 0) out[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
  }
  return out;
}

function parseArgs(argv) {
  const opts = {
    proxy: process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy || '',
    explicitProxy: false,
    timeoutSec: 8.0,
    aiOnly: false,
    streamOnly: false,
    fullIp: false,
    jsonOut: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') opts.help = true;
    else if (a === '--ai-only') opts.aiOnly = true;
    else if (a === '--stream-only') opts.streamOnly = true;
    else if (a === '--full-ip') opts.fullIp = true;
    else if (a === '--json') opts.jsonOut = true;
    else if ((a === '-x' || a === '--proxy') && argv[i + 1]) {
      opts.proxy = argv[++i];
      opts.explicitProxy = true;
    } else if (a.startsWith('--proxy=')) {
      opts.proxy = a.slice(8);
      opts.explicitProxy = true;
    } else if ((a === '-m' || a === '--timeout') && argv[i + 1]) {
      opts.timeoutSec = Math.max(1, parseFloat(argv[++i]) || 8.0);
    } else if (a.startsWith('--timeout=')) {
      opts.timeoutSec = Math.max(1, parseFloat(a.slice(10)) || 8.0);
    }
  }
  return opts;
}

function connectViaHttpProxy(proxyUrl, targetHost, targetPort, timeoutMs) {
  return new Promise((resolve, reject) => {
    const pu = new URL(proxyUrl.includes('://') ? proxyUrl : `http://${proxyUrl}`);
    const auth = pu.username ? `${decodeURIComponent(pu.username)}:${decodeURIComponent(pu.password)}` : '';
    const headers = { Host: `${targetHost}:${targetPort}` };
    if (auth) headers['Proxy-Authorization'] = `Basic ${Buffer.from(auth).toString('base64')}`;
    const req = (pu.protocol === 'https:' ? https : http).request({
      host: pu.hostname,
      port: pu.port || (pu.protocol === 'https:' ? 443 : 80),
      method: 'CONNECT',
      path: `${targetHost}:${targetPort}`,
      headers,
      timeout: timeoutMs,
    });
    req.once('connect', (res, socket) => {
      if (res.statusCode !== 200) {
        socket.destroy();
        reject(new Error(`Proxy CONNECT HTTP ${res.statusCode}`));
        return;
      }
      const tlsSock = tls.connect(
        { socket, servername: targetHost, ALPNProtocols: ['http/1.1'] },
        () => resolve(tlsSock)
      );
      tlsSock.once('error', reject);
    });
    req.once('timeout', () => {
      req.destroy(new Error('Proxy CONNECT timeout'));
    });
    req.once('error', reject);
    req.end();
  });
}

async function singleRequest(urlStr, proxyUrl, timeoutMs, extraHeaders, maxBytes = 131072) {
  const u = new URL(urlStr);
  const isHttps = u.protocol === 'https:';
  const targetPort = u.port ? Number(u.port) : isHttps ? 443 : 80;
  let createConnection;
  let socketPreconnected = null;

  if (proxyUrl && isHttps) {
    socketPreconnected = await connectViaHttpProxy(proxyUrl, u.hostname, targetPort, timeoutMs);
    createConnection = () => socketPreconnected;
  }

  return new Promise((resolve, reject) => {
    let reqOpts;
    let mod = isHttps ? https : http;
    if (proxyUrl && !isHttps) {
      const pu = new URL(proxyUrl.includes('://') ? proxyUrl : `http://${proxyUrl}`);
      mod = pu.protocol === 'https:' ? https : http;
      reqOpts = {
        host: pu.hostname,
        port: pu.port || 80,
        path: urlStr,
        method: 'GET',
        maxHeaderSize: 65536,
        headers: { Host: u.host, 'User-Agent': UA, Connection: 'close', ...(extraHeaders || {}) },
      };
    } else {
      reqOpts = {
        hostname: u.hostname,
        port: targetPort,
        path: u.pathname + u.search,
        method: 'GET',
        maxHeaderSize: 65536,
        headers: { 'User-Agent': UA, Accept: '*/*', Connection: 'close', ...(extraHeaders || {}) },
        ...(createConnection ? { createConnection, agent: false } : {}),
      };
    }

    const req = mod.request(reqOpts, (res) => {
      const chunks = [];
      let total = 0;
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        const hdrs = {};
        for (const [k, v] of Object.entries(res.headers || {})) {
          hdrs[k.toLowerCase()] = Array.isArray(v) ? v.join(', ') : String(v ?? '');
        }
        resolve({
          status: res.statusCode || 0,
          headers: hdrs,
          body: Buffer.concat(chunks).toString('utf8'),
        });
      };
      res.on('data', (chunk) => {
        if (total < maxBytes) {
          const slice = total + chunk.length > maxBytes ? chunk.subarray(0, maxBytes - total) : chunk;
          chunks.push(slice);
          total += slice.length;
        }
        if (total >= maxBytes) {
          finish();
          res.destroy();
        }
      });
      res.once('end', finish);
      res.once('close', finish);
      res.once('error', finish);
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error('Request timeout')));
    req.once('error', (err) => {
      if (socketPreconnected) socketPreconnected.destroy();
      reject(err);
    });
    req.end();
  });
}

async function httpFetch(urlStr, proxyUrl, timeoutSec = 8.0, headers = null) {
  const t0 = performance.now();
  const timeoutMs = Math.round(timeoutSec * 1000);
  let curUrl = urlStr;
  const jar = new Map();
  try {
    for (let hop = 0; hop < 10; hop++) {
      const cookieHdr = jar.size ? { Cookie: Array.from(jar.entries()).map(([k, v]) => `${k}=${v}`).join('; ') } : {};
      const res = await singleRequest(curUrl, proxyUrl, timeoutMs, { ...cookieHdr, ...(headers || {}) });
      if (res.headers['set-cookie']) {
        for (const raw of res.headers['set-cookie'].split(/,(?=\s*[A-Za-z0-9_-]+=)/)) {
          const kv = raw.split(';', 1)[0].trim();
          const eq = kv.indexOf('=');
          if (eq > 0) jar.set(kv.slice(0, eq), kv.slice(eq + 1));
        }
      }
      if ([301, 302, 303, 307, 308].includes(res.status) && res.headers.location) {
        curUrl = new URL(res.headers.location, curUrl).toString();
        continue;
      }
      return [res.status, Math.round(performance.now() - t0), curUrl, res.headers, res.body];
    }
    return [0, Math.round(performance.now() - t0), curUrl, {}, 'Too many redirects'];
  } catch (e) {
    return [0, Math.round(performance.now() - t0), curUrl, {}, String(e?.message || e)];
  }
}

function dispWidth(s) {
  let w = 0;
  for (const ch of s) w += ch.codePointAt(0) > 127 ? 2 : 1;
  return w;
}

function dispPad(s, width) {
  return s + ' '.repeat(Math.max(0, width - dispWidth(s)));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(`ai-ip-check v${VERSION} — AI Coding & Regional Streaming Connectivity Diagnostic CLI

Usage:
  npx ai-ip-check [options]

Options:
  -x, --proxy <url>     HTTP/HTTPS proxy URL, e.g. http://127.0.0.1:7897
  -m, --timeout <sec>   Timeout per probe in seconds (default: 8)
      --ai-only         Run AI & developer API checks only
      --stream-only     Run streaming unlock checks only
      --full-ip         Display full exit IP without masking
      --json            Output structured JSON
  -h, --help            Show help`);
    return 0;
  }

  const runAi = !args.streamOnly;
  const runStream = !args.aiOnly;
  const tty = Boolean(process.stdout.isTTY) && !args.jsonOut;
  const C_RST = tty ? '\x1b[0m' : '';
  const C_BLD = tty ? '\x1b[1m' : '';
  const C_DIM = tty ? '\x1b[2m' : '';
  const C_GRN = tty ? '\x1b[32m' : '';
  const C_YLW = tty ? '\x1b[33m' : '';
  const C_RED = tty ? '\x1b[31m' : '';
  const C_CYN = tty ? '\x1b[36m' : '';

  const tasks = {
    cf_trace: ['https://www.cloudflare.com/cdn-cgi/trace', null],
    ipsb: ['https://api.ip.sb/geoip', { Accept: 'application/json' }],
  };
  if (runAi) {
    Object.assign(tasks, {
      claude_trace: ['https://claude.ai/cdn-cgi/trace', null],
      anthropic_api: ['https://api.anthropic.com/v1/messages', null],
      gpt_trace: ['https://chatgpt.com/cdn-cgi/trace', null],
      gpt_ios: ['https://ios.chat.openai.com/public-api/mobile/server_status/v1', null],
      openai_api: ['https://api.openai.com/v1/models', null],
      gemini_web: ['https://gemini.google.com/app', null],
      gemini_api: ['https://generativelanguage.googleapis.com/v1beta/models', null],
      aistudio: ['https://aistudio.google.com/', null],
      stripe: ['https://api.stripe.com/healthcheck', null],
      cursor: ['https://api2.cursor.sh', null],
      copilot: ['https://api.githubcopilot.com/_ping', null],
    });
  }
  if (runStream) {
    Object.assign(tasks, {
      bahamut: ['https://ani.gamer.com.tw/ajax/token.php?adID=89422&sn=37783', null],
      nf_nonorig: ['https://www.netflix.com/title/81280792', null],
      nf_orig: ['https://www.netflix.com/title/80018499', null],
      yt_red: ['https://www.youtube.com/red', { 'Accept-Language': 'en-US,en;q=0.9' }],
      disney: ['https://www.disneyplus.com/', null],
      tiktok: ['https://www.tiktok.com/explore', null],
    });
  }

  const entries = await Promise.all(
    Object.entries(tasks).map(async ([k, [u, h]]) => [k, await httpFetch(u, args.proxy, args.timeoutSec, h)])
  );
  const raw = Object.fromEntries(entries);

  const cfKv = raw.cf_trace[0] === 200 ? parseTrace(raw.cf_trace[4]) : {};
  let cfIp = cfKv.ip || '';
  let cfLoc = cfKv.loc || '';
  const cfColo = cfKv.colo || '';
  let asnInfo = '';
  let ipType = '';
  if (raw.ipsb[0] === 200) {
    try {
      const j = JSON.parse(raw.ipsb[4]);
      cfIp = cfIp || String(j.ip || '');
      cfLoc = cfLoc || String(j.country_code || '');
      const asn = j.asn;
      const org = j.asn_organization || j.isp || '';
      if (asn || org) {
        asnInfo = `AS${asn || ''} ${org}`.trim();
        ipType = RESIDENTIAL_PAT.test(org) ? '家宽/本土运营商 ASN' : '数据中心/商业网络 ASN';
      }
    } catch {}
  }

  const maskedDefault = maskIp(cfIp, args.fullIp);
  const results = [];
  const warnings = [];
  if (cfLoc === 'CN') {
    warnings.push('当前终端默认出口为中国大陆 [CN]：请开启客户端 TUN 虚拟网卡模式或配置 HTTPS_PROXY。');
  }

  const add = (category, name, status, region, latency_ms, detail) => {
    results.push({ category, name, status, region, latency_ms, detail });
  };

  let claudeIp = '',
    claudeLoc = '',
    gptIp = '',
    gptLoc = '';

  if (runAi) {
    const [cCode, cMs, , , cBody] = raw.claude_trace;
    const ckv = cCode === 200 ? parseTrace(cBody) : {};
    claudeIp = ckv.ip || '';
    claudeLoc = ckv.loc || '';
    const cmask = maskIp(claudeIp, args.fullIp);
    if (cCode === 200 && claudeLoc) {
      if (AI_BLOCKED.has(claudeLoc)) {
        add('ai', 'Claude Web (claude.ai)', 'fail', claudeLoc, cMs, `出口位于受限地区 (${cmask})`);
        warnings.push(`Claude 落入不支持地区 [${claudeLoc}]：请将 Claude 策略组固定到美国 AI 或台湾家宽节点。`);
      } else {
        add('ai', 'Claude Web (claude.ai)', 'ok', claudeLoc, cMs, `出口 ${cmask}`);
      }
    } else {
      add('ai', 'Claude Web (claude.ai)', 'fail', '', cMs, `连接失败 (HTTP ${cCode})`);
    }

    const [aCode, aMs] = raw.anthropic_api;
    if ([400, 401, 405].includes(aCode)) {
      add('ai', 'Claude Code API', 'ok', claudeLoc, aMs, 'api.anthropic.com 握手正常');
    } else if (aCode === 403) {
      add('ai', 'Claude Code API', 'fail', claudeLoc, aMs, 'HTTP 403 被防火墙或地区策略拦截');
    } else {
      add('ai', 'Claude Code API', 'fail', '', aMs, `连接异常 (HTTP ${aCode})`);
    }

    const [gtCode, , , , gtBody] = raw.gpt_trace;
    const gkv = gtCode === 200 ? parseTrace(gtBody) : {};
    gptIp = gkv.ip || '';
    gptLoc = gkv.loc || '';
    const gmask = maskIp(gptIp, args.fullIp);

    const [giCode, giMs, , , giBody] = raw.gpt_ios;
    if (giCode === 200 && giBody.includes('"status":"normal"')) {
      add('ai', 'ChatGPT (Web + App)', AI_BLOCKED.has(gptLoc) ? 'warn' : 'ok', gptLoc, giMs, `网页与移动端完整解锁 (${gmask})`);
    } else if (/unsupported_country|vpn_detected|disallowed_isp/i.test(giBody)) {
      add('ai', 'ChatGPT (Web + App)', 'warn', gptLoc, giMs, `移动端受限或被识别机房代理 (${gmask})`);
    } else if (giCode === 403) {
      add('ai', 'ChatGPT (Web + App)', 'warn', gptLoc, giMs, `触发 Cloudflare 盾或风控 (${gmask})`);
    } else {
      add('ai', 'ChatGPT (Web + App)', 'fail', gptLoc, giMs, `不可用 (HTTP ${giCode})`);
    }

    const [oaCode, oaMs, , , oaBody] = raw.openai_api;
    if (oaCode === 401) {
      add('ai', 'OpenAI Codex / API', 'ok', gptLoc, oaMs, 'api.openai.com 鉴权端点可达');
    } else if (oaCode === 403 || oaBody.includes('unsupported_country_region_territory')) {
      add('ai', 'OpenAI Codex / API', 'fail', gptLoc, oaMs, '地区受限 (unsupported_country)');
    } else {
      add('ai', 'OpenAI Codex / API', 'fail', '', oaMs, `连接异常 (HTTP ${oaCode})`);
    }

    const [gmCode, gmMs, gmUrl] = raw.gemini_web;
    if (gmCode === 200 && !/\/faq|sorry\/index/i.test(gmUrl)) {
      add('ai', 'Google Gemini Web', 'ok', '', gmMs, 'gemini.google.com 正常开放');
    } else if (gmUrl.toLowerCase().includes('sorry/index')) {
      add('ai', 'Google Gemini Web', 'warn', '', gmMs, '触发 Google 人机验证');
    } else {
      add('ai', 'Google Gemini Web', 'fail', '', gmMs, `当前出口未开放 (${gmCode})`);
      warnings.push('Google Gemini 不可用：切勿将 Google / AI 服务策略组指向香港或无 AI 节点。');
    }

    const [gmaCode, gmaMs, , , gmaBody] = raw.gemini_api;
    if (gmaBody.toLowerCase().includes('user location is not supported')) {
      add('ai', 'Gemini API / AI Studio', 'fail', '', gmaMs, 'User location is not supported');
    } else if (gmaCode === 400 || gmaCode === 403) {
      add('ai', 'Gemini API / AI Studio', 'ok', '', gmaMs, 'generativelanguage API 正常');
    } else {
      add('ai', 'Gemini API / AI Studio', 'fail', '', gmaMs, `连接异常 (HTTP ${gmaCode})`);
    }

    const [cuCode, cuMs] = raw.cursor;
    const [cpCode, cpMs] = raw.copilot;
    if (cuCode === 200 && cpCode === 200) {
      add('ai', 'Cursor & Copilot', 'ok', '', cuMs, `Cursor ${cuMs}ms / Copilot ${cpMs}ms`);
    } else if (cuCode === 200 || cpCode === 200) {
      add('ai', 'Cursor & Copilot', 'warn', '', cuMs, `Cursor HTTP ${cuCode} / Copilot HTTP ${cpCode}`);
    } else {
      add('ai', 'Cursor & Copilot', 'fail', '', cuMs, `Cursor HTTP ${cuCode} / Copilot HTTP ${cpCode}`);
    }

    const [asCode, asMs, asUrl] = raw.aistudio;
    if (asCode === 200 && !/available_regions|sorry\/index/i.test(asUrl)) {
      add('ai', 'Google AI Studio', 'ok', '', asMs, 'aistudio.google.com 正常开放');
    } else {
      add('ai', 'Google AI Studio', 'warn', '', asMs, `当前出口地区受限或需验证 (${asCode})`);
    }

    const [stCode, stMs] = raw.stripe;
    if (stCode === 200) {
      add('ai', 'Stripe 订阅收银台', 'ok', '', stMs, 'api.stripe.com 可达（建议与 Claude 同出口）');
    } else {
      add('ai', 'Stripe 订阅收银台', 'warn', '', stMs, `连接受限 (HTTP ${stCode})`);
    }
  }

  if (runStream) {
    const [bhCode, bhMs, , , bhBody] = raw.bahamut;
    if (bhCode === 200 && bhBody.includes('animeSn')) {
      add('stream', '巴哈姆特动画疯', 'ok', 'TW', bhMs, '台湾原生/家宽解锁');
    } else {
      add('stream', '巴哈姆特动画疯', 'warn', '', bhMs, '仅限台湾原生 IP 解锁');
    }

    const [nfCode, nfMs, nfUrl, nfHdrs] = raw.nf_nonorig;
    const origU = nfHdrs['x-originating-url'] || nfUrl;
    const mNf = origU.match(/netflix\.com\/([a-z]{2})(?:-[a-z]+)?\/title\//i);
    const nfReg = mNf ? mNf[1].toUpperCase() : nfCode === 200 ? 'US' : '';
    if (nfCode === 200) {
      add('stream', 'Netflix', 'ok', nfReg, nfMs, '完整解锁非自制剧与自制剧');
    } else if (raw.nf_orig[0] === 200) {
      add('stream', 'Netflix', 'warn', '', nfMs, '仅解锁 Netflix 自制剧 (Originals Only)');
    } else {
      add('stream', 'Netflix', 'fail', '', nfMs, `当前出口未解锁 (HTTP ${nfCode})`);
    }

    const [ytCode, ytMs, , , ytBody] = raw.yt_red;
    const mYt = ytBody.match(/"INNERTUBE_CONTEXT_GL":"([A-Z]{2})"|"countryCode":"([A-Z]{2})"/);
    const ytGl = mYt ? mYt[1] || mYt[2] : '';
    if (ytCode === 200 && !ytBody.toLowerCase().includes('premium is not available in your country')) {
      add('stream', 'YouTube Premium', 'ok', ytGl, ytMs, '可正常订阅与后台播放');
    } else if (ytCode === 200) {
      add('stream', 'YouTube Premium', 'warn', ytGl, ytMs, '该地区暂未开放 Premium');
    } else {
      add('stream', 'YouTube Premium', 'fail', '', ytMs, `无法连接 YouTube (HTTP ${ytCode})`);
    }

    const [dpCode, dpMs, dpUrl] = raw.disney;
    if (dpCode === 200 && !/unavailable|error/i.test(dpUrl)) {
      const mDp = dpUrl.match(/disneyplus\.com\/[a-z]{2}-([a-z]{2})/i);
      add('stream', 'Disney+', 'ok', mDp ? mDp[1].toUpperCase() : '', dpMs, '区域入口可达');
    } else {
      add('stream', 'Disney+', 'warn', '', dpMs, `当前出口地区未开放或受限 (HTTP ${dpCode})`);
    }

    const [ttCode, ttMs, , , ttBody] = raw.tiktok;
    const mTt = ttBody.match(/"region":"([A-Z]{2})"/);
    const ttReg = mTt ? mTt[1] : '';
    if (ttCode === 200 && ttReg !== 'CN' && ttReg !== 'HK') {
      add('stream', 'TikTok', 'ok', ttReg, ttMs, '海外区域访问正常');
    } else {
      add('stream', 'TikTok', 'warn', ttReg, ttMs, `出口受限（请避开香港/大陆节点，HTTP ${ttCode}）`);
    }
  }

  if (args.jsonOut) {
    console.log(
      JSON.stringify(
        {
          version: VERSION,
          exit: { ip: maskedDefault, country: cfLoc, asn: asnInfo, type: ipType, colo: cfColo },
          warnings,
          results,
        },
        null,
        2
      )
    );
    return 0;
  }

  console.log(`\n${C_BLD}=== AI Coding & Streaming Connectivity Diagnostic (v${VERSION}) ===${C_RST}`);
  const mode = args.proxy ? `Proxy ${args.proxy}` : '当前终端直测';
  console.log(`${C_DIM}Mode:  ${mode} (IP 默认脱敏，完整显示加 --full-ip)${C_RST}`);
  console.log(`\n${C_BLD}[1] 终端默认出口画像${C_RST}`);
  console.log(`  默认出口 IP : ${C_CYN}${maskedDefault}${C_RST} (${cfLoc || '未知'})`);
  if (asnInfo) console.log(`  所属运营商  : ${asnInfo} (${ipType})`);
  if (cfColo) console.log(`  边缘接入点  : Cloudflare ${cfColo}`);

  const renderCat = (cat, title) => {
    const sub = results.filter((r) => r.category === cat);
    if (!sub.length) return;
    console.log(`\n${C_BLD}${title}${C_RST}`);
    for (const r of sub) {
      const [badge, col] =
        r.status === 'ok'
          ? ['✓ 可用', C_GRN]
          : r.status === 'warn'
            ? ['△ 受限', C_YLW]
            : ['✗ 不可用', C_RED];
      const reg = r.region ? `[${r.region}] ` : '';
      const ms = r.latency_ms > 0 ? ` (${r.latency_ms}ms)` : '';
      console.log(`  ${dispPad(r.name, 24)} ${col}${dispPad(badge, 10)}${C_RST} ${reg}${r.detail}${C_DIM}${ms}${C_RST}`);
    }
  };

  renderCat('ai', '[2] AI 编程与大模型连通性');
  if (runAi && claudeIp && gptIp && claudeIp !== gptIp) {
    console.log(
      `  ${C_CYN}↳ 检测到按服务智能分流：Claude (${maskIp(claudeIp, args.fullIp)} [${claudeLoc}]) ≠ ChatGPT (${maskIp(gptIp, args.fullIp)} [${gptLoc}])${C_RST}`
    );
  }
  renderCat('stream', '[3] 台湾与全球流媒体解锁');

  if (warnings.length) {
    console.log(`\n${C_BLD}[诊断建议]${C_RST}`);
    for (const w of warnings) console.log(`  ${C_YLW}• ${w}${C_RST}`);
  }

  console.log(
    `\n${C_DIM}npm: npx ai-ip-check  |  Repo: https://github.com/fanqiao-net/ai-ip-check  |  指南: https://fanqiao.net/guide/ai-coding?utm_source=npm-ipcheck${C_RST}\n`
  );
  return 0;
}

main().then((code) => process.exit(code));
