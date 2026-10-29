#!/usr/bin/env node
/**
 * 把「跑批产物」打包成可以直接往 ADO 评论里贴的图：`output/<ID>/comment-NN-<含义>.png`。
 *
 * 为什么要有这个脚本：ADO 评论的图不是随手截一张就行，硬规则是
 *   1) 文件名 `comment-NN-...`，NN 是**粘贴顺序**（不是条目号）；
 *   2) 每张图要说清覆盖评论里的哪几条；
 *   3) 一条可能配多张（整页 + 局部），一张也可能同时证明几条。
 * 手工 `Copy-Item` + 数序号每次都要重来一遍，还容易错位（实测工作项 4489 就重排过两轮）。
 *
 * 用法（在工作区根目录跑）：
 *   node scripts/pack-comment.mjs --manifest tmp/pack-4489.json
 *   node scripts/pack-comment.mjs --id 4489 --manifest tmp/pack.json --out output/4489
 *   node scripts/pack-comment.mjs --manifest tmp/pack.json --dry-run     # 只打印，不落盘
 *
 * manifest 结构（顺序即粘贴顺序）：
 *   {
 *     "id": "4489",
 *     "text": "output/4489/comment.txt",        // 可选：评论正文，原样复制
 *     "items": [
 *       { "src": "output/playwright/sit/x/a.png", "name": "dg12-imr1-check", "covers": [3] },
 *       { "src": "output/playwright/sit/x/b.png", "name": "dg12-imr1-chinese", "covers": [3] }
 *     ]
 *   }
 *
 * 输出：
 *   - 按顺序复制成 `output/<ID>/comment-NN-<name>.png`（已存在则跳过，`--force` 覆盖）；
 *   - 打印清单：`NN 文件名 —— 覆盖 1、3`，并检查 1..最大条目号 是否每条都有图；
 *   - 有 `text` 时复制评论正文；
 *   - `--dry-run` 只打印计划。
 */

import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { basename, dirname, extname, join, resolve } from 'node:path';

const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : undefined;
};
const has = (name) => argv.includes(`--${name}`);

const manifestPath = flag('manifest');
if (!manifestPath) {
  console.error('用法：node scripts/pack-comment.mjs --manifest <pack.json> [--id 4489] [--out output/4489] [--dry-run] [--force]');
  process.exit(2);
}
if (!existsSync(manifestPath)) {
  console.error(`manifest 不存在：${manifestPath}`);
  process.exit(2);
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const id = String(flag('id') ?? manifest.id ?? '').trim();
if (!id) {
  console.error('manifest 里要有 id，或用 --id 指定工作项编号');
  process.exit(2);
}
const outDir = resolve(flag('out') ?? join('output', id));
const items = Array.isArray(manifest.items) ? manifest.items : [];
if (!items.length) {
  console.error('manifest.items 是空的');
  process.exit(2);
}

const dryRun = has('dry-run');
const force = has('force');
const copied = [];
const problems = [];

if (!dryRun) mkdirSync(outDir, { recursive: true });

items.forEach((item, index) => {
  const nn = String(index + 1).padStart(2, '0');
  const src = resolve(String(item.src ?? ''));
  const name = String(item.name ?? '').trim() || stripExt(src);
  const ext = extname(src) || '.png';
  const dest = join(outDir, `comment-${nn}-${slug(name)}${ext}`);
  const covers = normalizeCovers(item.covers);

  if (!item.src || !existsSync(src)) {
    problems.push(`第 ${nn} 张源文件不存在：${item.src || '(空)'}`);
    return;
  }
  if (statSync(src).size === 0) {
    problems.push(`第 ${nn} 张源文件是 0 字节：${item.src}`);
    return;
  }
  if (existsSync(dest) && !force) {
    problems.push(`已存在，跳过（要覆盖加 --force）：${dest}`);
    copied.push({ nn, dest, covers, skipped: true });
    return;
  }
  if (!dryRun) copyFileSync(src, dest);
  copied.push({ nn, dest, covers, skipped: false });
});

if (manifest.text) {
  const textSrc = resolve(String(manifest.text));
  const textDest = join(outDir, 'comment.txt');
  if (!existsSync(textSrc)) {
    problems.push(`评论正文不存在：${manifest.text}`);
  } else if (!dryRun) {
    copyFileSync(textSrc, textDest);
  }
}

// ---- 图号核对（正文里的 （图N） 必须和 comment-NN 对得上）--------------------
// 规则见 SKILL.md「每条末尾标图号」：N = 粘贴顺序 = 文件名 comment-NN 的 NN。
const figureReport = [];
if (manifest.text) {
  const textSrc = resolve(String(manifest.text));
  if (existsSync(textSrc)) {
    const text = readFileSync(textSrc, 'utf8');
    const refs = new Set();
    for (const m of text.matchAll(/（图([0-9]+(?:[、,，]图?[0-9]+)*)）/g)) {
      for (const n of m[1].split(/[、,，]|图/)) {
        const num = Number(String(n).trim());
        if (Number.isFinite(num) && num > 0) refs.add(num);
      }
    }
    const maxFig = Math.max(0, ...refs);
    const haveFig = new Set(copied.map((row) => Number(row.nn)));
    const missingFiles = [...refs].filter((n) => !haveFig.has(n)).sort((a, b) => a - b);
    const noRef = [...haveFig].filter((n) => !refs.has(n)).sort((a, b) => a - b);
    if (missingFiles.length) problems.push(`正文引用了不存在的图：${missingFiles.map((n) => `图${n}`).join('、')}`);
    if (noRef.length) problems.push(`这些图正文里没写图号：${noRef.map((n) => `图${n}`).join('、')}`);
    if (maxFig && refs.size) {
      const gaps = [];
      for (let i = 1; i <= maxFig; i += 1) if (!refs.has(i)) gaps.push(i);
      if (gaps.length) figureReport.push(`图号不连续，缺 ${gaps.join('、')}`);
    }
    const items = text.split(/\r?\n/).filter((line) => /^\d+\./.test(line));
    const noFigItems = items.filter((line) => !/（图[0-9]/.test(line));
    if (noFigItems.length) figureReport.push(`有 ${noFigItems.length} 条正文没写图号（如：${noFigItems[0].slice(0, 40)}）`);
    figureReport.unshift(`正文引用图号：${[...refs].sort((a, b) => a - b).map((n) => `图${n}`).join('、') || '(无)'}`);
  }
}

// ---- 报告 ------------------------------------------------------------------

const rel = (p) => p.replace(`${process.cwd()}\\`, '').replaceAll('\\', '/');
console.log(dryRun ? '（dry-run，未写盘）' : `输出目录：${outDir}`);
console.log('');
for (const row of copied) {
  const covers = row.covers.length ? row.covers.join('、') : '(未标)';
  console.log(`${row.nn} ${rel(row.dest)} —— 覆盖 ${covers}${row.skipped ? '（跳过）' : ''}`);
}
if (manifest.text) console.log(`   ${rel(join(outDir, 'comment.txt'))} —— 评论正文`);

const covered = new Set(copied.flatMap((row) => row.covers));
const maxItem = covered.size ? Math.max(...covered) : 0;
const missing = [];
for (let i = 1; i <= maxItem; i += 1) if (!covered.has(i)) missing.push(i);
if (missing.length) problems.push(`评论条目 ${missing.join('、')} 没有配图`);
if (copied.some((row) => !row.covers.length)) problems.push('有图没标 covers，贴进 ADO 时说不清证明哪条');

if (figureReport.length) {
  console.log('\n图号核对：');
  for (const line of figureReport) console.log(`  ${line}`);
}

if (problems.length) {
  console.log('\n待处理：');
  for (const p of problems) console.log(`  - ${p}`);
}
console.log(`\n共 ${copied.length} 张图，覆盖条目 ${[...covered].sort((a, b) => a - b).join('、') || '(无)'}`);

function normalizeCovers(value) {
  const list = Array.isArray(value) ? value : value == null ? [] : String(value).split(/[,，、\s]+/);
  return [...new Set(list.map((v) => Number(v)).filter((v) => Number.isFinite(v) && v > 0))].sort((a, b) => a - b);
}

function slug(text) {
  return String(text)
    .trim()
    .replace(/[\\/:*?"<>|\s]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

function stripExt(file) {
  return basename(file, extname(file));
}
