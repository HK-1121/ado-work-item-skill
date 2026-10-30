#!/usr/bin/env node
/**
 * ado-comment.mjs — 把 `output/<ID>/comment.txt` 发到对应 ADO 工作项的 Discussion（REST 直连）。
 *
 * 只做一件事：**发评论**。不改状态、不改字段、不加 @、不建关联、不转 bug。
 *
 * 规则（和 SKILL.md 一致）：
 *   - pass：纯文字，正文里不许出现 `（图N）`，一张图都不上传；
 *   - fail / partial / blocked：只上传正文引用到的失败截图，按图号顺序附在评论末尾；
 *     每张图在 pack 阶段已经烤好「图N」水印（scripts/pack-comment.mjs 默认会烤）。
 *
 * 用法（在工作区根目录跑）：
 *   node scripts/ado-comment.mjs --id 4613
 *   node scripts/ado-comment.mjs --id 4187 --text output/4187/comment.txt
 *   node scripts/ado-comment.mjs --id 4613 --dry-run      # 只校验，不发
 *   node scripts/ado-comment.mjs --id 4613 --force        # 忽略查重，再发一条
 *
 * PAT 来源：环境变量 AZDO_PAT / PERSONAL_ACCESS_TOKEN，或 ~/.codex/config.toml 的
 * [mcp_servers.azure-devops.env] PERSONAL_ACCESS_TOKEN（base64(":"+PAT)）。
 * 需要 Work Items **读写** 权限。
 */

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const ORG = process.env.AZDO_ORG || 'LD-23175';
const PROJECT = process.env.AZDO_PROJECT || 'LD-ECCMS';
const API = '7.1-preview.4';

const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : undefined;
};
const has = (name) => argv.includes(`--${name}`);

main().catch((err) => {
  console.error(err?.message || String(err));
  process.exitCode = err?.exitCode || 1;
});

async function main() {
  const id = String(flag('id') ?? '').trim();
  if (!/^\d+$/.test(id)) {
    return fail('用法：node scripts/ado-comment.mjs --id <工作项编号> [--text output/<ID>/comment.txt] [--dry-run] [--force]', 2);
  }

  const dryRun = has('dry-run');
  const force = has('force');
  const textPath = path.resolve(flag('text') ?? path.join('output', id, 'comment.txt'));
  const outDir = path.dirname(textPath);

  if (!existsSync(textPath)) return fail(`找不到评论正文：${textPath}`, 2);

  const text = readFileSync(textPath, 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').trimEnd();
  if (!text.trim()) return fail('评论正文是空的', 2);

  // ---------- 1. 校验格式与结果词 ----------------------------------------------
  const resultMatch = text.match(/【sit test result】：\s*(\S+)/);
  if (!resultMatch) return fail('评论正文里没有「【sit test result】：」这一行，先按 SKILL.md 的格式写', 2);
  const result = resultMatch[1].trim();
  if (!['pass', 'fail', 'partial', 'blocked'].includes(result)) {
    return fail(`结果词「${result}」不合法，只能是 pass / fail / partial / blocked`, 2);
  }

  const lines = text.split('\n');
  const figures = collectFigures(text);

  // 逐条解析：编号行 → 正文 → 标记行
  const items = [];
  let current = null;
  for (const line of lines) {
    if (/^\d+\./.test(line.trim())) {
      current = { no: Number(line.trim().match(/^\d+/)[0]), body: [line], mark: '' };
      items.push(current);
    } else if (/^---(√|×|\?)$/.test(line.trim())) {
      if (current) current.mark = line.trim().slice(3);
    } else if (current) {
      current.body.push(line);
    }
  }

  if (result === 'pass') {
    if (figures.length) {
      return fail(
        `pass 评论不配图，但正文里出现了 ${figures.map((n) => `图${n}`).join('、')}。删掉图号再发。`,
        2,
      );
    }
  } else {
    const noShot = items.filter((it) => it.mark === '×' && !collectFigures(it.body.join('\n')).length);
    if (noShot.length) {
      return fail(
        `这些不通过条目没有图号：${noShot.map((it) => `第 ${it.no} 条`).join('、')}。每条 ---× 至少配一张失败截图`,
        2,
      );
    }
    for (const n of figures) {
      if (!findFigureFile(outDir, n)) {
        return fail(`正文引用了图${n}，但 ${outDir} 里没有 comment-${String(n).padStart(2, '0')}-*.png`, 2);
      }
    }
  }

  // ---------- 2. 取 PAT / 查重 -------------------------------------------------
  const basic = await loadBasicToken();
  const base = `https://dev.azure.com/${ORG}/${PROJECT}/_apis/wit`;

  async function api(url, options = {}) {
    const res = await fetch(url, {
      ...options,
      headers: {
        Authorization: 'Basic ' + basic,
        Accept: 'application/json',
        ...(options.headers || {}),
      },
    });
    const body = await res.text();
    if (!res.ok) {
      const hint =
        res.status === 401
          ? 'PAT 无效或已过期'
          : res.status === 403
            ? 'PAT 没有 Work Items 写权限（评论/附件需要 Read & Write）'
            : res.status === 404
              ? '工作项或项目不存在，或没有读权限'
              : 'ADO 返回错误';
      const err = new Error(`HTTP ${res.status}（${hint}）\n${body.slice(0, 600)}`);
      err.exitCode = 1;
      throw err;
    }
    return body ? JSON.parse(body) : {};
  }

  let existing = [];
  try {
    const data = await api(`${base}/workItems/${id}/comments?api-version=${API}&$top=200`);
    existing = Array.isArray(data.comments) ? data.comments : [];
  } catch (err) {
    err.message = '读现有评论失败：' + err.message;
    throw err;
  }

  const mine = squash(text);
  const duplicate = existing.find((c) => mine && squash(c.text || '').includes(mine));
  if (duplicate && !force) {
    console.log(
      `已发过同样的评论（comment id ${duplicate.id}，${duplicate.createdBy?.displayName || ''} ${duplicate.createdDate || ''}），跳过。要重发加 --force。`,
    );
    console.log(`链接：https://dev.azure.com/${ORG}/${PROJECT}/_workitems/edit/${id}`);
    return;
  }

  // ---------- 3. 上传失败截图（仅非 pass） -------------------------------------
  const uploaded = [];
  if (result !== 'pass' && figures.length) {
    for (const n of figures) {
      const file = findFigureFile(outDir, n);
      const bytes = readFileSync(file);
      if (dryRun) {
        uploaded.push({ n, file, url: '(dry-run)' });
        continue;
      }
      const fileName = path.basename(file);
      const up = await api(
        `https://dev.azure.com/${ORG}/${PROJECT}/_apis/wit/attachments?fileName=${encodeURIComponent(fileName)}&api-version=7.1`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/octet-stream' },
          body: bytes,
        },
      );
      const url =
        up.url ||
        `https://dev.azure.com/${ORG}/${PROJECT}/_apis/wit/attachments/${up.id}?fileName=${encodeURIComponent(fileName)}`;
      uploaded.push({ n, file, url });
      console.log(`已上传 图${n}：${fileName}（${(bytes.length / 1024).toFixed(0)} KB）`);
    }
  }

  // ---------- 4. 组装 HTML 并发评论 --------------------------------------------
  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  let html = lines.map((line) => (line.trim() ? esc(line) : '&nbsp;')).join('<br>');
  if (uploaded.length) {
    html += '<br><br><b>失败截图</b>';
    for (const row of uploaded) {
      html += `<br><b>图${row.n}</b><br><img src="${row.url}" alt="图${row.n}">`;
    }
  }

  if (dryRun) {
    console.log(`\n（dry-run）结果=${result}，图 ${uploaded.length} 张，正文 ${text.length} 字`);
    console.log(`将发到：https://dev.azure.com/${ORG}/${PROJECT}/_workitems/edit/${id}`);
    return;
  }

  let posted;
  try {
    posted = await api(`${base}/workItems/${id}/comments?api-version=${API}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: html }),
    });
  } catch (err) {
    err.message = '发评论失败：' + err.message;
    throw err;
  }

  console.log('');
  console.log(`已发评论 #${posted.id}  结果=${result}  图=${uploaded.length} 张`);
  console.log(`链接：https://dev.azure.com/${ORG}/${PROJECT}/_workitems/edit/${id}`);
}

// ---------- 工具 ---------------------------------------------------------------

function fail(message, code = 2) {
  const err = new Error(message);
  err.exitCode = code;
  throw err;
}

function collectFigures(body) {
  const refs = new Set();
  for (const m of body.matchAll(/（图([0-9]+(?:[、,，]图?[0-9]+)*)）/g)) {
    for (const n of m[1].split(/[、,，]|图/)) {
      const num = Number(String(n).trim());
      if (Number.isFinite(num) && num > 0) refs.add(num);
    }
  }
  return [...refs].sort((a, b) => a - b);
}

function findFigureFile(dir, n) {
  if (!existsSync(dir)) return null;
  const prefix = `comment-${String(n).padStart(2, '0')}-`;
  const files = readdirSync(dir).filter((f) => f.startsWith(prefix) && /\.(png|jpe?g)$/i.test(f));
  return files.length ? path.join(dir, files.sort()[0]) : null;
}

function squash(s) {
  return String(s)
    .replace(/<br\s*\/?>/gi, '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/\s+/g, '');
}

async function loadBasicToken() {
  for (const key of ['AZDO_PAT', 'PERSONAL_ACCESS_TOKEN']) {
    const v = process.env[key];
    if (v) return v.includes(':') || v.endsWith('=') ? v : Buffer.from(':' + v).toString('base64');
  }
  const cfgPath = path.join(homedir(), '.codex', 'config.toml');
  let cfgText;
  try {
    cfgText = readFileSync(cfgPath, 'utf8');
  } catch {
    throw new Error(`找不到 PAT：环境变量 AZDO_PAT 未设置，也读不到 ${cfgPath}`);
  }
  const section = cfgText.match(/\[mcp_servers\.azure-devops\.env\]([\s\S]*?)(?:\n\[|$)/);
  const t = section && section[1].match(/PERSONAL_ACCESS_TOKEN\s*=\s*(?:"([^"]+)"|'([^']+)')/);
  const val = t && (t[1] ?? t[2]);
  if (!val) throw new Error('config.toml 里没有 [mcp_servers.azure-devops.env] PERSONAL_ACCESS_TOKEN');
  return val;
}
