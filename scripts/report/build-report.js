#!/usr/bin/env node
'use strict';
/**
 * Builds the lab report (.docx) from a week's README.md — one source of truth for the repository
 * view (GitHub) and the submitted document (Word).
 *
 *   node scripts/report/build-report.js docs/week11
 *
 * Reads docs/<week>/report.json (title page: title, subtitle, branch, stack, date, output) and
 * docs/<week>/README.md. Supported Markdown: headings (#–####), paragraphs with **bold**, *italic*,
 * `code` and links, bullet/numbered lists (2 levels), tables, fenced code, images (PNG/JPEG; wide
 * figures get a landscape page), blockquotes, horizontal rules. The README's first H1 is replaced
 * by the title page; a table of contents follows it (Word updates the field on open).
 *
 * Style (same as weeks 6–10): A4, Calibri 10.5 pt, headings in blue, Consolas for code, tables with
 * DXA widths and a shaded header row.
 */
const fs = require('node:fs');
const path = require('node:path');
const { marked } = require('marked');
const d = require('docx');

const weekDir = process.argv[2];
if (!weekDir) {
  console.error('usage: build-report.js docs/<week>');
  process.exit(2);
}
const meta = JSON.parse(fs.readFileSync(path.join(weekDir, 'report.json'), 'utf8'));
const md = fs.readFileSync(path.join(weekDir, 'README.md'), 'utf8');

// ── page geometry (DXA: 1440 = 1 inch) ────────────────────────────────────────────────────────
const A4 = { width: 11906, height: 16838 };
const MARGIN = 1134; // 2 cm
const TEXT_W = A4.width - 2 * MARGIN; // 9638
const TEXT_W_LAND = A4.height - 2 * MARGIN; // 14570
const PX_PER_DXA = 96 / 1440;

const C = { h1: '1F4E79', h2: '2E74B5', h3: '2E74B5', text: '262626', muted: '595959', code: '404040',
  border: 'BFBFBF', head: 'DEEAF6', codeBg: 'F3F5F7', quote: 'F2F7FC' };

// ── inline Markdown → TextRun / ExternalHyperlink ─────────────────────────────────────────────
function decode(s) {
  return s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}
function inline(tokens, style = {}) {
  const out = [];
  for (const t of tokens || []) {
    switch (t.type) {
      case 'strong': out.push(...inline(t.tokens, { ...style, bold: true })); break;
      case 'em': out.push(...inline(t.tokens, { ...style, italics: true })); break;
      case 'del': out.push(...inline(t.tokens, { ...style, strike: true })); break;
      case 'codespan':
        out.push(new d.TextRun({ text: decode(t.text), font: 'Consolas', size: (style.size || 21) - 2,
          color: C.code, bold: style.bold, shading: { type: d.ShadingType.CLEAR, fill: C.codeBg } }));
        break;
      case 'link': {
        const runs = inline(t.tokens, { ...style, color: '0563C1', underline: {} });
        if (/^https?:/.test(t.href)) out.push(new d.ExternalHyperlink({ link: t.href, children: runs }));
        else out.push(...runs); // repository-relative link: keep the text (path is meaningful)
        break;
      }
      case 'br': out.push(new d.TextRun({ break: 1 })); break;
      case 'image': out.push(new d.TextRun({ text: `[${t.text}]`, italics: true, ...style })); break;
      case 'html': break;
      case 'escape':
      case 'text':
        if (t.tokens) out.push(...inline(t.tokens, style));
        else out.push(new d.TextRun({ text: decode(t.text), ...style }));
        break;
      default:
        out.push(new d.TextRun({ text: decode(t.raw || ''), ...style }));
    }
  }
  return out;
}

// ── images ───────────────────────────────────────────────────────────────────────────────────
function imageSize(buf) {
  if (buf.readUInt32BE(0) === 0x89504e47) return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), type: 'png' };
  let i = 2; // JPEG: walk the segments to SOF0/SOF2
  while (i < buf.length) {
    const marker = buf.readUInt16BE(i);
    const len = buf.readUInt16BE(i + 2);
    if (marker === 0xffc0 || marker === 0xffc2) return { w: buf.readUInt16BE(i + 7), h: buf.readUInt16BE(i + 5), type: 'jpg' };
    i += 2 + len;
  }
  throw new Error('unknown image format');
}

// ── document model: a list of sections, each portrait or landscape ───────────────────────────
const sections = [];
let current = null;
function section(landscape) {
  current = { landscape, children: [] };
  sections.push(current);
}
const push = (...xs) => current.children.push(...xs);
let figureNo = 0;
let tableNo = 0;

function heading(depth, tokens) {
  const level = [null, d.HeadingLevel.HEADING_1, d.HeadingLevel.HEADING_2, d.HeadingLevel.HEADING_3,
    d.HeadingLevel.HEADING_4][Math.min(depth, 4)];
  push(new d.Paragraph({ heading: level, children: inline(tokens), keepNext: true,
    pageBreakBefore: depth === 1 && current.children.length > 0 }));
}

function paragraph(tokens) {
  // A paragraph that is just an image (optionally with a caption in italics below) = a figure.
  const imgs = tokens.filter((t) => t.type === 'image');
  if (imgs.length === 1 && tokens.every((t) => t.type === 'image' || (t.type === 'text' && !t.text.trim()))) {
    return figure(imgs[0]);
  }
  push(new d.Paragraph({ children: inline(tokens), spacing: { after: 120 } }));
}

function figure(img) {
  const file = path.join(weekDir, decodeURI(img.href));
  if (!fs.existsSync(file) || !/\.(png|jpe?g)$/i.test(file)) {
    push(new d.Paragraph({ children: [new d.TextRun({ text: `[figure: ${img.href}]`, italics: true })] }));
    return;
  }
  const buf = fs.readFileSync(file);
  const { w, h, type } = imageSize(buf);
  const wide = w / h > 1.45 && w > 1400;
  if (wide && !current.landscape) section(true);
  const maxW = (wide ? TEXT_W_LAND : TEXT_W) * PX_PER_DXA;
  const maxH = ((wide ? A4.width : A4.height) - 2 * MARGIN - 1300) * PX_PER_DXA;
  const scale = Math.min(maxW / w, maxH / h, 1);
  figureNo += 1;
  push(
    new d.Paragraph({ alignment: d.AlignmentType.CENTER, keepNext: true, spacing: { before: 120 },
      children: [new d.ImageRun({ type, data: buf, transformation: { width: Math.round(w * scale), height: Math.round(h * scale) },
        altText: { title: img.text, description: img.text, name: path.basename(file) } })] }),
    new d.Paragraph({ alignment: d.AlignmentType.CENTER, spacing: { after: 200 },
      children: [new d.TextRun({ text: `Figure ${figureNo}. `, bold: true, size: 18, color: C.muted }),
        new d.TextRun({ text: decode(img.text), italics: true, size: 18, color: C.muted })] }),
  );
  if (wide) section(false);
}

function list(tok, level = 0) {
  tok.items.forEach((item) => {
    const blocks = item.tokens || [];
    let first = true;
    for (const b of blocks) {
      if (b.type === 'list') { list(b, level + 1); continue; }
      const runs = inline(b.tokens || [{ type: 'text', text: b.text || '' }]);
      if (item.task) runs.unshift(new d.TextRun({ text: item.checked ? '☑ ' : '☐ ' }));
      push(new d.Paragraph({
        children: runs,
        numbering: first ? { reference: tok.ordered ? `num-${listId}` : 'bullets', level } : undefined,
        indent: first ? undefined : { left: 720 * (level + 1) },
        spacing: { after: 60 },
      }));
      first = false;
    }
  });
  if (tok.ordered && level === 0) listId += 1;
}
let listId = 0;

function table(tok) {
  const cols = tok.header.length;
  const avail = current.landscape ? TEXT_W_LAND : TEXT_W;
  // Column widths proportional to the longest cell text (bounded), summing to the text width.
  const weight = tok.header.map((h, i) => {
    const lens = [h.text, ...tok.rows.map((r) => (r[i] ? r[i].text : ''))].map((s) => Math.min(s.length, 60));
    return Math.max(6, Math.max(...lens));
  });
  const total = weight.reduce((a, b) => a + b, 0);
  const widths = weight.map((x) => Math.floor((avail * x) / total));
  widths[widths.length - 1] += avail - widths.reduce((a, b) => a + b, 0);
  const border = { style: d.BorderStyle.SINGLE, size: 4, color: C.border };
  const borders = { top: border, bottom: border, left: border, right: border };
  const cell = (c, i, head) => new d.TableCell({
    width: { size: widths[i], type: d.WidthType.DXA },
    borders,
    shading: head ? { type: d.ShadingType.CLEAR, fill: C.head } : undefined,
    margins: { top: 50, bottom: 50, left: 90, right: 90 },
    children: [new d.Paragraph({ alignment: tok.align[i] === 'right' ? d.AlignmentType.RIGHT : tok.align[i] === 'center' ? d.AlignmentType.CENTER : d.AlignmentType.LEFT,
      children: inline(c.tokens, { size: 18, bold: head || undefined }) })],
  });
  tableNo += 1;
  push(new d.Table({
    width: { size: avail, type: d.WidthType.DXA },
    columnWidths: widths,
    rows: [
      new d.TableRow({ tableHeader: true, children: tok.header.map((c, i) => cell(c, i, true)) }),
      ...tok.rows.map((r) => new d.TableRow({ cantSplit: true,
        children: Array.from({ length: cols }, (_, i) => cell(r[i] || { tokens: [] }, i, false)) })),
    ],
  }), new d.Paragraph({ spacing: { after: 120 }, children: [] }));
}

function code(tok) {
  const lines = tok.text.split('\n');
  const longest = Math.max(...lines.map((l) => l.length));
  const size = longest > 110 ? 14 : longest > 95 ? 15 : 16;
  lines.forEach((line, i) => push(new d.Paragraph({
    shading: { type: d.ShadingType.CLEAR, fill: C.codeBg },
    spacing: { before: i === 0 ? 80 : 0, after: i === lines.length - 1 ? 160 : 0, line: 240 },
    keepLines: true, keepNext: lines.length < 25 && i < lines.length - 1,
    children: [new d.TextRun({ text: line || ' ', font: 'Consolas', size, color: C.code })],
  })));
}

function block(tok) {
  switch (tok.type) {
    case 'heading': return heading(tok.depth, tok.tokens);
    case 'paragraph': return paragraph(tok.tokens);
    case 'list': return list(tok);
    case 'table': return table(tok);
    case 'code': return code(tok);
    case 'blockquote':
      return tok.tokens.forEach((b) => push(new d.Paragraph({
        children: inline(b.tokens || [], { italics: true, color: C.muted }),
        shading: { type: d.ShadingType.CLEAR, fill: C.quote },
        border: { left: { style: d.BorderStyle.SINGLE, size: 18, color: C.h2, space: 8 } },
        indent: { left: 240 }, spacing: { after: 120 } })));
    case 'hr': return push(new d.Paragraph({ border: { bottom: { style: d.BorderStyle.SINGLE, size: 6, color: C.border, space: 1 } }, children: [] }));
    case 'space': case 'html': case 'def': return undefined;
    default: return push(new d.Paragraph({ children: [new d.TextRun(tok.raw || '')] }));
  }
}

// ── title page + TOC ─────────────────────────────────────────────────────────────────────────
section(false);
const titleLine = (text, opts) => new d.Paragraph({ alignment: d.AlignmentType.CENTER, ...opts.p,
  children: [new d.TextRun({ text, ...opts.r })] });
push(
  titleLine('Software Architecture & DevOps — Laboratory Work', { p: { spacing: { before: 2400, after: 240 } }, r: { size: 26, color: C.muted } }),
  titleLine(meta.week, { p: { spacing: { after: 360 } }, r: { size: 28, bold: true, color: C.h2 } }),
  titleLine(meta.title, { p: { spacing: { after: 240 } }, r: { size: 44, bold: true, color: C.h1 } }),
  titleLine(meta.subtitle, { p: { spacing: { after: 1200 } }, r: { size: 24, italics: true, color: C.muted } }),
);
for (const [k, v] of [['Student', meta.student], ['Repository', meta.repository], ['Branch', meta.branch], ['Stack', meta.stack], ['Date', meta.date]]) {
  push(new d.Paragraph({ alignment: d.AlignmentType.CENTER, spacing: { after: 80 },
    children: [new d.TextRun({ text: `${k}: `, bold: true, color: C.muted }), new d.TextRun({ text: v })] }));
}
push(
  new d.Paragraph({ children: [new d.PageBreak()] }),
  new d.Paragraph({ children: [new d.TextRun({ text: 'Contents', bold: true, size: 32, color: C.h1 })], spacing: { after: 200 } }),
  new d.TableOfContents('Contents', { hyperlink: true, headingStyleRange: '1-2' }),
  new d.Paragraph({ children: [new d.PageBreak()] }),
);

// ── body ─────────────────────────────────────────────────────────────────────────────────────
let skippedTitle = false;
for (const tok of marked.lexer(md)) {
  if (!skippedTitle && tok.type === 'heading' && tok.depth === 1) { skippedTitle = true; continue; }
  block(tok);
}

// ── assemble ─────────────────────────────────────────────────────────────────────────────────
const ordered = Array.from({ length: listId + 1 }, (_, i) => ({
  reference: `num-${i}`,
  levels: [0, 1, 2].map((level) => ({ level, format: [d.LevelFormat.DECIMAL, d.LevelFormat.LOWER_LETTER, d.LevelFormat.LOWER_ROMAN][level],
    text: `%${level + 1}.`, alignment: d.AlignmentType.LEFT, style: { paragraph: { indent: { left: 720 * (level + 1), hanging: 360 } } } })),
}));
const footer = new d.Footer({ children: [new d.Paragraph({ alignment: d.AlignmentType.CENTER, children: [
  new d.TextRun({ text: `${meta.week} · ${meta.title} · page `, size: 16, color: C.muted }),
  new d.TextRun({ children: [d.PageNumber.CURRENT], size: 16, color: C.muted })] })] });

const doc = new d.Document({
  creator: meta.student,
  title: `${meta.week} — ${meta.title}`,
  features: { updateFields: true },
  styles: {
    default: { document: { run: { font: 'Calibri', size: 21, color: C.text }, paragraph: { spacing: { line: 276 } } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 32, bold: true, color: C.h1 }, paragraph: { spacing: { before: 240, after: 160 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 26, bold: true, color: C.h2 }, paragraph: { spacing: { before: 280, after: 120 }, outlineLevel: 1 } },
      { id: 'Heading3', name: 'Heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 22, bold: true, color: C.h3 }, paragraph: { spacing: { before: 200, after: 80 }, outlineLevel: 2 } },
      { id: 'Heading4', name: 'Heading 4', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 21, bold: true, italics: true, color: C.h3 }, paragraph: { spacing: { before: 160, after: 60 }, outlineLevel: 3 } },
    ],
  },
  numbering: { config: [
    { reference: 'bullets', levels: [0, 1, 2].map((level) => ({ level, format: d.LevelFormat.BULLET, text: ['•', '◦', '▪'][level],
      alignment: d.AlignmentType.LEFT, style: { paragraph: { indent: { left: 720 * (level + 1), hanging: 360 } } } })) },
    ...ordered,
  ] },
  sections: sections.filter((s) => s.children.length).map((s) => ({
    properties: { page: { size: { width: A4.width, height: A4.height, orientation: s.landscape ? d.PageOrientation.LANDSCAPE : d.PageOrientation.PORTRAIT },
      margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN } } },
    footers: { default: footer },
    children: s.children,
  })),
});

const out = path.join(weekDir, meta.output);
d.Packer.toBuffer(doc).then((buf) => {
  fs.writeFileSync(out, buf);
  console.log(`${out}: ${(buf.length / 1024).toFixed(0)} KiB, ${figureNo} figures, ${tableNo} tables, ${sections.length} sections`);
});
