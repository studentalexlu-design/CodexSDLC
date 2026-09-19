"use strict";
// doctor 的結構化結果 → 狀態列要顯示什麼。**不 import vscode**，只吃 contract.ts 驗過的欄位。
//
// 刻意不推測「現在在流程的第幾步」：流程狀態活在對話裡，磁碟上只有 spec.md，
// 靠檔案反推會猜錯 —— 一個顯示錯階段的狀態列比沒有狀態列更糟。這裡只顯示**檔案與腳本說得準**的事。
Object.defineProperty(exports, "__esModule", { value: true });
exports.issuesFromDoctor = issuesFromDoctor;
exports.statusFromDoctor = statusFromDoctor;
exports.statusFromFailure = statusFromFailure;
const rank = { ok: 0, warn: 1, error: 2 };
function issuesFromDoctor(d) {
    const issues = [];
    switch (d.hooks.status) {
        case 'untrusted': {
            const c = d.hooks.counts;
            const parts = [];
            if (c?.untrusted)
                parts.push(`${c.untrusted} 條未信任`);
            if (c?.modified)
                parts.push(`${c.modified} 條改過待重審`);
            if (c?.disabled)
                parts.push(`${c.disabled} 條被停用`);
            issues.push({
                level: 'error',
                badge: '$(shield) hooks 未信任',
                detail: `Codex hooks：${parts.join('、') || '有未信任的'} —— 沒信任的那幾條一次都不會跑，而且不會提示。在專案裡開 codex，「Hooks need review」選 Trust all and continue。`,
            });
            break;
        }
        case 'project-untrusted':
            issues.push({
                level: 'error',
                badge: '$(shield) 專案未信任',
                detail: 'Codex 還沒信任這個專案 —— 專案層的 config 與 hooks 整個停用。在專案裡開 codex，信任這個資料夾，再在「Hooks need review」選 Trust all and continue。',
            });
            break;
        // 檔不在 = 整層不存在，而且沒有任何跡象 —— 這是最該吵的一種。
        case 'no-hooks':
            issues.push({
                level: 'error',
                badge: '$(shield) 沒有 hooks.json',
                detail: '.codex/hooks.json 不在 —— 機械強制層整層不存在：寫檔與委派完全沒有人擋，而且 Codex 不會提示。把發佈物解壓到別處，跑 sdlc.ps1 update -Target <這個專案> 補回工具檔。',
            });
            break;
    }
    if (d.config.exists && !d.config.parsable) {
        issues.push({ level: 'error', badge: '$(error) 設定檔壞了', detail: 'sdlc.config.json 解析不了 —— apply 與 doctor 都讀不到你的設定。' });
    }
    if (d.tuning.status === 'stale') {
        issues.push({
            level: 'warn',
            badge: '$(sync) 調校未套用',
            detail: `sdlc.config.json 改過但沒有 apply：${d.tuning.stale.join('、')} —— 不 apply 的話流程用的是舊值，而畫面上看不出來。`,
        });
    }
    if (d.config.comments) {
        issues.push({
            level: 'warn',
            badge: '$(comment) 設定檔有註解',
            detail: 'sdlc.config.json 裡有註解 —— 這個檔不支援註解，下一次 update 或在面板裡改值時會不見（會先備份）。要留的說明請搬進 _note。',
        });
    }
    const badCheck = d.lint.violations.find((v) => v.rule === 'update-check-invalid');
    if (badCheck) {
        issues.push({
            level: 'warn',
            badge: '$(cloud) 更新檢查頻率寫壞了',
            detail: `${badCheck.detail} —— 不認得的值照 daily 算，會連網檢查。在設定面板的「更新」裡重選一次。`,
        });
    }
    if (!d.review.valid) {
        issues.push({
            level: 'warn',
            badge: '$(debug-restart) 修正輪上限寫壞了',
            detail: `sdlc.config.json 的 review.maxRounds 不是 1–5 的整數 —— 審核實際照預設 ${d.review.maxRounds} 輪算，你設的值沒有生效。`,
        });
    }
    // 調校區塊對不上時 agent-lint（檢查 9）也會紅；review.maxRounds 寫壞時檢查 13 也會紅 ——
    // 同一件事已經由上面那幾條講了，而且那幾條才說得出修法。重複報一次，狀態列會把「agent-lint」排在最前面，
    // 使用者看到的就不是能直接動手的那一句。
    const covered = new Set(['tuning-block-stale', 'tuning-block-missing', 'sdlc-config-unparsable', 'review-max-rounds-invalid', 'review-config-invalid', 'update-check-invalid']);
    const violations = d.lint.violations.filter((v) => !covered.has(v.rule));
    if (d.lint.ran && !d.lint.passed && (violations.length > 0 || d.lint.violations.length === 0)) {
        const n = violations.length;
        issues.push({
            level: 'error',
            badge: '$(error) agent-lint',
            detail: n > 0 ? `agent-lint ${n} 項違規：${violations.slice(0, 3).map((v) => v.rule).join('、')}${n > 3 ? '…' : ''}` : 'agent-lint 沒有跑完',
        });
    }
    for (const f of d.guidelines.filter((g) => g.level === 'warn')) {
        issues.push({ level: 'warn', badge: '$(law) 規範', detail: f.text });
    }
    return issues.sort((a, b) => rank[b.level] - rank[a.level]);
}
function hookLine(d) {
    switch (d.hooks.status) {
        case 'trusted': return `Codex hooks：${d.hooks.counts?.total ?? 0} 條都已信任 —— 機械強制層會跑`;
        case 'untrusted': return 'Codex hooks：有未信任的（見上）';
        case 'project-untrusted': return 'Codex hooks：專案本身未信任（見上）';
        case 'no-hooks': return 'Codex hooks：這個專案沒有 .codex/hooks.json';
        case 'unknown':
            return d.hooks.reason === 'codex-not-found'
                ? 'Codex hooks：無法確認（找不到 codex 執行檔）'
                : 'Codex hooks：無法確認（問 codex 沒有回應）';
        default: return `Codex hooks：${d.hooks.status}`;
    }
}
function statusFromDoctor(d, now) {
    const issues = issuesFromDoctor(d);
    const level = issues.reduce((acc, i) => (rank[i.level] > rank[acc] ? i.level : acc), 'ok');
    let text = level === 'ok' ? `$(check) SDLC ${d.version.contract}` : `$(warning) SDLC ${d.version.contract}`;
    if (issues.length > 0)
        text += ` · ${issues[0].badge}${issues.length > 1 ? ` +${issues.length - 1}` : ''}`;
    const showUpdate = d.update.newer && !d.update.seen && d.update.latest;
    if (showUpdate)
        text += ` $(arrow-up) ${d.update.latest}`;
    const tooltip = [`工作流 ${d.version.contract}（最低相容 ${d.version.minCompatible}）`];
    for (const i of issues)
        tooltip.push(`${i.level === 'error' ? '✖' : '⚠'} ${i.detail}`);
    tooltip.push(hookLine(d));
    tooltip.push(d.tuning.status === 'in-sync' ? '調校：sdlc.config.json 與 agent 定義一致'
        : d.tuning.status === 'no-config' ? '調校：沒有 sdlc.config.json（全部交給 Codex CLI 決定）'
            : `調校：${d.tuning.status}`);
    tooltip.push(`審核修正輪上限：${d.review.maxRounds} 輪（${d.review.source === 'config' ? 'sdlc.config.json 的 review.maxRounds' : '預設'}）`);
    if (d.lint.ran && d.lint.passed)
        tooltip.push('agent-lint：通過');
    if (showUpdate)
        tooltip.push(`有新版 ${d.update.latest} —— 看變更：Codex SDLC：whatsnew`);
    else if (d.update.check === 'never')
        tooltip.push('更新檢查：關閉（update.check = never）');
    for (const e of d.editor.installed.filter((x) => !x.compatible)) {
        tooltip.push(`${e.product} 裝的 extension ${e.version} 跟這個專案的 -Json 形狀對不上 —— 換成這一版發佈物附的 vsix`);
    }
    tooltip.push(`最後檢查：${now.toLocaleTimeString()}`);
    return { text, level, tooltip, issues };
}
function statusFromFailure(kind, message) {
    const badge = {
        'pwsh-missing': '$(error) SDLC：找不到 pwsh',
        'workflow-too-old': '$(warning) SDLC：工作流太舊',
        'schema-mismatch': '$(warning) SDLC：版本不相容',
        'script-failed': '$(error) SDLC：健檢失敗',
    }[kind];
    return { text: badge, level: kind === 'workflow-too-old' || kind === 'schema-mismatch' ? 'warn' : 'error', tooltip: [message], issues: [] };
}
