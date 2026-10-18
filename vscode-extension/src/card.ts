// 側邊欄最上面那張狀態卡片：tree.ts 的 StatusCard → 一份 webview HTML。**不 import vscode。**
//
// 這張卡片買到的是「一眼知道現在好不好、要處理的事旁邊就是那顆按鈕」—— 原生的樹做不到字級、留白與卡片。
// 它只負責畫：要不要處理、處理要跑哪個指令，全部來自 StatusCard（也就是 doctor）。
// 按鈕只送回一個索引；extension 用它查 actions 再執行 —— webview 裡的東西叫不動任何沒列在這裡的指令。

import type { CardAction, StatusCard } from './tree';

export interface RenderedCard { html: string; actions: CardAction[] }

export function renderCard(card: StatusCard, opts: { nonce: string; cspSource: string }): RenderedCard {
  const actions: CardAction[] = [];
  const button = (a: CardAction, cls = '') => {
    actions.push(a);
    return `<button type="button" class="${cls}" data-a="${actions.length - 1}">${esc(a.label)}</button>`;
  };
  const doctor: CardAction = { label: '健檢', command: 'codexSdlc.doctor' };
  const checkUpdate: CardAction = { label: '檢查更新', command: 'codexSdlc.checkUpdate' };
  const where = [card.project, card.version ? `工作流 ${card.version}` : ''].filter(Boolean).join(' · ');

  let body: string;
  if (card.state === 'attention') {
    const items = card.items.map((it) => `
      <li class="item ${it.level}">
        ${it.level === 'error' ? ICON.error : ICON.warn}
        <div class="text"><div class="t">${esc(it.title)}</div>${it.detail ? `<div class="d" title="${esc(it.detail)}">${esc(it.detail)}</div>` : ''}</div>
        ${it.action ? button(it.action) : ''}
      </li>`).join('');
    body = `
    <section class="card" aria-label="狀態">
      <div class="head"><span class="count">${card.items.length}</span><span class="title">件事要處理</span></div>
      <ul class="items">${items}</ul>
      <div class="foot"><span>${card.quiet > 0 ? `其他 ${card.quiet} 項正常` : ''}</span><span>${esc(where)}</span></div>
    </section>`;
  } else {
    const head = {
      ok: ['dot', '一切正常'],
      checking: ['dot spin', '檢查中…'],
      failed: ['dot bad', '健檢沒跑起來'],
      none: ['dot idle', '還沒有健檢結果'],
    }[card.state];
    const meta = card.state === 'failed'
      ? `<span class="d">${esc(card.failure ?? '')}</span>`
      : `<span>${esc(where)}</span>${card.checkedAt ? `<span>${esc(card.checkedAt)} 檢查過</span>` : ''}`;
    // 檢查中不給按鈕（按了也只是排隊）。button() 會登記動作，所以沒畫出來的就不要呼叫它。
    const buttons = card.state === 'checking' ? ''
      : card.state === 'failed'
        ? `${button({ label: '再試一次', command: 'codexSdlc.refresh' }, 'primary')}${button({ label: '看輸出', command: 'codexSdlc.showOutput' })}`
        : `${button(doctor, 'primary')}${button(checkUpdate)}`;
    body = `
    <section class="card" aria-label="狀態">
      <div class="head"><span class="${head[0]}" aria-hidden="true"></span><span class="title">${head[1]}</span></div>
      <div class="meta">${meta}</div>
      <div class="row">${buttons}</div>
    </section>`;
  }
  // 新版是提示，不是待辦：卡片外面一顆安靜的膠囊，不算進數字。
  const pill = card.upgrade ? `
    <div class="pill">${ICON.up}<span>有新版 ${esc(card.upgrade.version)}</span>${button(card.upgrade.action, 'link')}</div>` : '';

  const html = `<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${opts.cspSource} 'nonce-${opts.nonce}'; script-src 'nonce-${opts.nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style nonce="${opts.nonce}">${CSS}</style>
</head>
<body>${body}${pill}
<script nonce="${opts.nonce}">
const vscode = acquireVsCodeApi();
document.addEventListener('click', (e) => {
  const b = e.target.closest('button[data-a]');
  if (b) vscode.postMessage({ a: Number(b.dataset.a) });
});
</script>
</body>
</html>`;
  return { html, actions };
}

export function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

const ICON = {
  error: '<svg class="ic" aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="8" cy="8" r="6.25"/><path d="M8 4.75v3.75M8 11v.01"/></svg>',
  warn: '<svg class="ic" aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"><path d="M8 2l6.5 11.5h-13z"/><path d="M8 6.5v3M8 11.5v.01"/></svg>',
  up: '<svg aria-hidden="true" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 13V3M4 7l4-4 4 4"/></svg>',
};

// 顏色一律來自主題（--vscode-*），淺色、深色、高對比都跟著走。強調色是 package.json 宣告的 codexSdlc.accent。
const CSS = `
:root {
  --accent: var(--vscode-codexSdlc-accent, #2EC4B6);
  --on-accent: var(--vscode-codexSdlc-accentForeground, #0B1F1D);
  --line: var(--vscode-widget-border, var(--vscode-sideBarSectionHeader-border, rgba(128,128,128,.22)));
  --muted: var(--vscode-descriptionForeground);
  --bad: var(--vscode-errorForeground);
  --warn: var(--vscode-editorWarning-foreground, #CCA700);
}
body { margin: 0; padding: 4px 12px 12px; color: var(--vscode-foreground); background: transparent;
  font-family: var(--vscode-font-family); font-size: var(--vscode-font-size); }
.card { border: 1px solid var(--line); border-radius: 10px; overflow: hidden;
  background: color-mix(in srgb, var(--vscode-foreground) 4%, transparent); }
.head { display: flex; align-items: center; gap: 10px; padding: 16px 16px 0; }
.title { font-size: 15px; font-weight: 600; }
.dot { width: 10px; height: 10px; border-radius: 50%; background: var(--accent);
  box-shadow: 0 0 0 4px color-mix(in srgb, var(--accent) 18%, transparent); flex-shrink: 0; }
.dot.bad { background: var(--bad); box-shadow: 0 0 0 4px color-mix(in srgb, var(--bad) 18%, transparent); }
.dot.idle { background: var(--muted); box-shadow: none; }
.dot.spin { background: none; box-shadow: none; border: 2px solid var(--line); border-top-color: var(--accent); width: 8px; height: 8px;
  animation: spin .9s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { .dot.spin { animation: none; } }
.meta { display: flex; flex-direction: column; gap: 2px; padding: 10px 16px 0; font-size: 12px; color: var(--muted); }
.row { display: flex; gap: 8px; padding: 14px 16px 16px; flex-wrap: wrap; }
.row:empty { padding: 0 0 16px; }
.count { font-size: 22px; font-weight: 700; color: var(--bad); }
.head:has(.count) { align-items: baseline; gap: 8px; padding-bottom: 10px; }
.items { list-style: none; margin: 0; padding: 0; }
.item { display: flex; gap: 10px; align-items: flex-start; padding: 10px 16px; border-top: 1px solid var(--line); }
.item .ic { flex-shrink: 0; margin-top: 2px; }
.item.error .ic { color: var(--bad); }
.item.warn .ic { color: var(--warn); }
.text { flex-grow: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.d { font-size: 12px; color: var(--muted); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.foot { display: flex; justify-content: space-between; gap: 8px; padding: 8px 16px; border-top: 1px solid var(--line);
  font-size: 12px; color: var(--muted); background: color-mix(in srgb, var(--vscode-foreground) 2%, transparent); }
button { font: inherit; font-size: 12px; height: 26px; padding: 0 12px; border-radius: 6px; cursor: pointer; flex-shrink: 0;
  color: var(--vscode-foreground); background: transparent; border: 1px solid var(--vscode-button-border, var(--line)); }
button:hover { background: var(--vscode-toolbar-hoverBackground); }
button:focus-visible { outline: 1px solid var(--vscode-focusBorder); outline-offset: 2px; }
button.primary { background: var(--accent); color: var(--on-accent); border-color: transparent; font-weight: 600; }
button.primary:hover { background: color-mix(in srgb, var(--accent) 85%, var(--vscode-foreground)); }
button.link { border: 0; color: var(--accent); font-weight: 600; padding: 0 8px; }
.pill { display: flex; align-items: center; gap: 8px; margin-top: 10px; padding: 0 4px 0 12px; height: 30px; border-radius: 15px;
  font-size: 12px; background: color-mix(in srgb, var(--accent) 10%, transparent); }
.pill svg { color: var(--accent); flex-shrink: 0; }
.pill span { flex-grow: 1; }
`;
