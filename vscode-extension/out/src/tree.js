"use strict";
// 側邊欄「設定」面板的模型：doctor 的結構化結果 ＋ 設定檔現值 ＋ schema → 一棵樹。**不 import vscode。**
//
// 這棵樹買到的是「一眼看到全部設定的現值、改值只要一步、改完一起套用」。它不判任何規則：
//   - 值合不合法、有沒有套用、hooks 信任了沒 → 看 doctor
//   - 有哪些選項、每個選項什麼意思 → 看專案裡的 schema
//   - 寫檔 → sdlc.ps1 set（extension.ts 負責叫它）
// 「未套用」也不是這裡自己記的狀態：它就是 doctor 的 tuning.stale，只是在寫完、doctor 還沒回來之前先標上。
Object.defineProperty(exports, "__esModule", { value: true });
exports.pendingAgentsOf = pendingAgentsOf;
exports.buildSettingsTree = buildSettingsTree;
exports.buildPanel = buildPanel;
exports.statusCard = statusCard;
exports.attentionCount = attentionCount;
exports.upgradeOffer = upgradeOffer;
exports.effortChoicesForModel = effortChoicesForModel;
exports.flatten = flatten;
const contract_1 = require("./contract");
const schema_1 = require("./schema");
const status_1 = require("./status");
const RULES_FILE = 'guidelines/rules.json';
// 未套用 = doctor 說對不上的 ∪ 剛寫、doctor 還沒回來的。orchestrator 沒有 agent 定義檔，永遠不算。
function pendingAgentsOf(i) {
    const stale = (i.doctor?.tuning.stale ?? []).map((f) => f.replace(/\.toml$/i, ''));
    return [...new Set([...stale, ...i.pendingAgents])].filter((a) => a !== 'orchestrator').sort();
}
function buildSettingsTree(i) {
    return [statusSection(i), agentsSection(i), reviewSection(i), updateSection(i), guidelinesSection(i), machineSection(i)];
}
function buildPanel(i) {
    const sections = buildSettingsTree(i);
    const section = (id) => sections.find((s) => s.id === id);
    const pending = pendingAgentsOf(i);
    // 調校 view 不再包「Agent 調校」「審核」兩層標題：agent 直接列，最上面一行就是要按的那個動作。
    const top = [];
    if (i.justApplied) {
        top.push({ id: 'settings/applied', label: i.justApplied.length > 0 ? `已套用 ${i.justApplied.join('、')}` : '已套用，沒有變更', icon: 'check', tone: 'accent' });
    }
    else if (pending.length > 0) {
        top.push({
            id: 'settings/apply', label: `套用 ${pending.length} 項`, description: pending.join('、'), icon: 'check-all', tone: 'accent',
            command: { command: 'codexSdlc.apply', title: '套用' },
            tooltip: `改了還沒套用：${pending.join('、')}。不套用的話流程用的是舊值 —— 按一下只跑一次 apply。`,
        });
    }
    return {
        views: {
            // 「不能改」那一句兩個區段各有一份；攤平之後只留一份。
            settings: [...top, ...(section('agents').children ?? []), ...(section('review').children ?? []).filter((n) => n.id !== 'review/blocked')],
            advanced: [section('update'), section('guidelines'), section('machine')],
        },
        card: statusCard(i, section('status')),
        pending,
        upgrade: upgradeOffer({ doctor: i.doctor, workflowVersion: i.workflowVersion, payloadVersion: i.machine.payloadVersion }),
    };
}
// 卡片上的按鈕要短：一兩個字的動詞。沒列到的就用指令自己的 title。
const ACTION_LABEL = {
    'codexSdlc.mergeAgents': '合併', 'codexSdlc.repair': '補回', 'codexSdlc.apply': '套用', 'codexSdlc.openSettings': '去調校',
    'codexSdlc.openAdvanced': '去設定', 'codexSdlc.doctor': '健檢', 'codexSdlc.showOutput': '看輸出', 'codexSdlc.upgrade': '升級',
};
const cardAction = (c) => c && { label: ACTION_LABEL[c.command] ?? c.title, command: c.command, arguments: c.arguments };
// 要處理的事 = 狀態區段裡亮紅／黃的那幾行。兩種刻意不算：
//   - 新版：那是提示，不是待辦（卡片下面另外一顆小膠囊）。
//   - 調校未套用：那是你自己剛做的改動，不是危險 —— 「套用」在調校 view 的最上面。
function statusCard(i, status = statusSection(i)) {
    const rows = status.children ?? [];
    const quietNode = rows.find((n) => n.id === 'status/quiet');
    const items = [];
    const push = (n) => {
        if (n.contextValue === 'tuningPending')
            return;
        items.push({ level: n.tone === 'error' ? 'error' : 'warn', title: n.label, detail: n.tooltip, action: cardAction(n.command) });
    };
    for (const n of rows) {
        if (n === quietNode || n.id === 'status/update')
            continue;
        if (n.id === 'status/issues')
            (n.children ?? []).forEach(push);
        else
            push(n);
    }
    const offer = upgradeOffer({ doctor: i.doctor, workflowVersion: i.workflowVersion, payloadVersion: i.machine.payloadVersion });
    const at = i.checkedAt !== undefined ? new Date(i.checkedAt) : undefined;
    return {
        state: items.length > 0 ? 'attention' : i.doctor ? 'ok' : i.checking ? 'checking' : i.failure ? 'failed' : 'none',
        items,
        quiet: quietNode?.children?.length ?? 0,
        project: i.rootName,
        version: i.workflowVersion ?? i.doctor?.version.contract,
        checkedAt: at && `${String(at.getHours()).padStart(2, '0')}:${String(at.getMinutes()).padStart(2, '0')}`,
        failure: i.failure,
        upgrade: offer && { version: offer.version, action: { label: '升級', command: 'codexSdlc.upgrade' } },
    };
}
// 活動列圖示上的數字＝卡片上那幾件。兩邊同一個來源，不會一邊說 2 一邊說 3。
function attentionCount(i) {
    return statusCard(i).items.length;
}
// ---- 狀態 ----
function statusSection(i) {
    const d = i.doctor;
    const children = [];
    children.push({
        id: 'status/workflow',
        label: `工作流 ${i.workflowVersion ?? d?.version.contract ?? '（讀不到版本）'}`,
        description: i.checking ? '檢查中…' : d ? (d.problems === 0 ? 'doctor 沒有問題' : `doctor：${d.problems} 個問題`) : '',
        // 問題本身列在「需要處理」底下；這一行只在 doctor 有問題、底下卻一條都沒列出來時才跟著亮。
        icon: d && d.problems > 0 ? 'warning' : 'check',
        tone: d ? (d.problems > 0 && (0, status_1.issuesFromDoctor)(d).length === 0 ? 'warn' : 'ok') : 'muted',
        tooltip: '點一下跑完整健檢（doctor），結果寫進輸出面板。',
        command: { command: 'codexSdlc.doctor', title: 'doctor' },
    });
    children.push(hooksNode(i));
    const merge = mergeNode(i);
    if (merge)
        children.push(merge);
    children.push(updateStatusNode(i));
    // doctor 的其他問題。hooks 那一條上面已經有自己的一行，不重複。
    const issues = d ? (0, status_1.issuesFromDoctor)(d).filter((x) => !/hooks\.json/.test(x.badge)) : [];
    if (issues.length > 0) {
        children.push({
            id: 'status/issues',
            label: `需要處理 ${issues.length} 項`,
            icon: 'list-unordered',
            tone: issues.some((x) => x.level === 'error') ? 'error' : 'warn',
            expanded: true,
            children: issues.map((x, n) => ({
                id: `status/issues/${n}`,
                label: x.badge.replace(/^\$\([^)]+\)\s*/, ''),
                // 修法由 doctor／agent-lint 自己說（violations[].fix）—— 這裡不自己編一套。
                tooltip: x.detail,
                icon: x.level === 'error' ? 'error' : 'warning',
                tone: x.level === 'error' ? 'error' : 'warn',
                ...(x.fix ?? { command: { command: 'codexSdlc.showOutput', title: '顯示輸出' } }),
            })),
        });
    }
    return { id: 'status', label: '狀態', description: i.rootName, expanded: true, children: foldQuiet(i, children) };
}
// 要處理的放最上面；沒事的收成一行（展開還看得到）。全部正常時整段就只剩「一切正常」那一行。
function foldQuiet(i, rows) {
    const loud = rows.filter((n) => n.tone === 'warn' || n.tone === 'error');
    const quiet = rows.filter((n) => !loud.includes(n));
    if (quiet.length === 0)
        return loud;
    const version = i.workflowVersion ?? i.doctor?.version.contract;
    const summary = loud.length > 0
        ? { id: 'status/quiet', label: `其他 ${quiet.length} 項正常`, icon: 'check', tone: 'ok', children: quiet }
        : !i.doctor
            ? { id: 'status/quiet', label: i.checking ? '檢查中…' : '還沒有健檢結果', icon: i.checking ? 'sync~spin' : 'circle-outline', tone: 'muted', description: i.rootName, children: quiet }
            : { id: 'status/quiet', label: '一切正常', icon: 'pass-filled', tone: 'ok', description: [version ? `工作流 ${version}` : '', i.rootName].filter(Boolean).join(' · '), children: quiet };
    return [...loud, summary];
}
// 機械強制層在不在。**這裡不再顯示 Codex 的信任狀態** —— 那要啟動一個 codex 子行程去問，
// 而答案是使用者在這個面板裡按不動的東西。hooks.json 在不在則留著：那是工具檔缺了，而它有得修。
function hooksNode(i) {
    const d = i.doctor;
    const base = { id: 'status/hooks', icon: 'shield' };
    if (!d)
        return { ...base, label: '機械強制層：檢查中…', tone: 'muted' };
    if (d.hooks.status === 'no-hooks') {
        return {
            ...base, label: '機械強制層：沒有 .codex/hooks.json', tone: 'error', contextValue: 'toolFilesMissing',
            command: { command: 'codexSdlc.repair', title: '補回工具檔' },
            tooltip: '整層不存在：handoff-lint／dlp-gate／guideline-gate／build-check 一支都不會跑，寫檔與委派完全沒有人擋。點一下用發佈物把工具檔補回來。',
        };
    }
    return {
        ...base, label: '機械強制層：hooks.json 在', tone: 'ok',
        tooltip: 'handoff-lint／dlp-gate／guideline-gate／build-check 由 .codex/hooks.json 掛上去。Codex 那邊要信任過才會真的跑 —— 那件事只有 Codex 自己知道，這裡不猜。',
    };
}
// AGENTS.md.new 還在 = 安裝／升級寫了新版但還沒合併，而**合併之前整套流程不會啟動**。
// 這一條刻意常駐到 .new 被刪掉為止：它是這套工作流唯一一個「看起來裝好了、其實沒在跑」的狀態。
function mergeNode(i) {
    if (!i.agentsNewExists)
        return undefined;
    return {
        id: 'status/merge', label: 'AGENTS.md.new 還沒合併', icon: 'git-merge', tone: 'error', contextValue: 'needsMerge',
        command: { command: 'codexSdlc.mergeAgents', title: '比對並合併', arguments: [i.rootPath] },
        tooltip: '新版的 AGENTS.md 寫成 .new、沒有覆蓋你那一份。把流程那幾節合進去之前，orchestrator 不會照這一版跑。點一下開左右對照。',
    };
}
function upgradeOffer(i) {
    const u = i.doctor?.update;
    const remote = u?.newer && u.latest ? u.latest : undefined;
    const bundled = i.payloadVersion && i.workflowVersion && (0, contract_1.compareVersions)(i.payloadVersion, i.workflowVersion) > 0 ? i.payloadVersion : undefined;
    if (bundled && (!remote || (0, contract_1.compareVersions)(bundled, remote) > 0))
        return { version: bundled, from: 'bundled' };
    return remote ? { version: remote, from: 'remote' } : undefined;
}
function updateStatusNode(i) {
    const u = i.doctor?.update;
    const base = { id: 'status/update', icon: 'cloud' };
    const offer = upgradeOffer({ doctor: i.doctor, workflowVersion: i.workflowVersion, payloadVersion: i.machine.payloadVersion });
    if (offer?.from === 'remote') {
        return {
            ...base, label: `有新版 ${offer.version}`, description: '點一下升級', tone: 'warn',
            command: { command: 'codexSdlc.upgrade', title: '升級' },
            tooltip: '點一下升級：先下載、列出會動哪些檔，你確認了才寫。只想看變更說明：Codex SDLC：whatsnew。',
        };
    }
    if (offer) {
        return {
            ...base, label: `可升級到 ${offer.version}`, description: 'extension 內附，點一下升級', tone: 'warn',
            command: { command: 'codexSdlc.upgrade', title: '升級' },
            tooltip: `這個 extension 內附的工作流是 ${offer.version}，比這個專案的 ${i.workflowVersion} 新 —— 不用連到發佈頁也能升。點一下會先列出會動哪些檔，你確認了才寫。`,
        };
    }
    if (!u)
        return { ...base, label: '更新：檢查中…', tone: 'muted' };
    if (u.check === 'never')
        return { ...base, label: '更新檢查：關閉', tone: 'muted', tooltip: 'update.check = never —— 一條連線都沒有。' };
    if (!u.cached)
        return { ...base, label: '還沒檢查過更新', tone: 'muted', command: { command: 'codexSdlc.checkUpdate', title: '立即檢查更新' } };
    return { ...base, label: '已是最新', tone: 'ok', description: u.checkedAt ? `上次檢查 ${u.checkedAt.slice(0, 16).replace('T', ' ')}` : undefined };
}
// ---- Agent 調校 ----
function agentsSection(i) {
    const pending = pendingAgentsOf(i);
    const children = [];
    if (i.configError) {
        children.push({ id: 'agents/error', label: i.configError, icon: 'error', tone: 'error', command: { command: 'codexSdlc.openFile', title: '開啟', arguments: [`${i.rootPath}/sdlc.config.json`] } });
    }
    else {
        // 沒有 sdlc.config.json 是合法狀態（＝全部 inherit）。照樣把 agent 列出來讓你改 ——
        // 改第一個值的時候 `sdlc.ps1 set` 會替你建一份預設的檔。
        if (!i.config) {
            children.push({
                id: 'agents/none',
                label: '還沒有 sdlc.config.json',
                description: '全部 inherit，交給 Codex CLI 決定',
                icon: 'info',
                tone: 'muted',
                tooltip: '這是合法狀態。改任何一個值，就會替你建一份預設的設定檔（內容跟現在的行為一樣）。',
            });
        }
        const agents = i.config?.agents ?? i.knownAgents.map((name) => ({ name, model: 'inherit', effort: 'inherit' }));
        for (const a of agents)
            children.push(agentNode(i, a.name, a.effort, a.model, pending.includes(a.name)));
        children.push(tuneNode(i));
        // 「換成預設組合…」在調校 view 標題列的「…」裡 —— 一年按一次的東西不佔一整行。
    }
    if (!i.canEdit && i.editBlockedReason)
        children.push(blockedNode('agents', i.editBlockedReason));
    return {
        id: 'agents',
        label: 'Agent 調校',
        description: pending.length > 0 ? `${pending.length} 項未套用` : i.doctor?.tuning.status === 'in-sync' ? '已套用' : undefined,
        tone: pending.length > 0 ? 'pending' : undefined,
        icon: pending.length > 0 ? 'circle-filled' : 'organization',
        contextValue: pending.length > 0 ? 'tuningPending' : undefined,
        tooltip: pending.length > 0
            ? `改了還沒套用：${pending.join('、')}。不套用的話流程用的是舊值，而畫面上看不出來 —— 按「套用」（只跑一次 apply）。`
            : '改值只要一步；需要套用的會標出來，改完一起套用。',
        expanded: true,
        children,
    };
}
// effort 的選項：問得到這台 Codex 的模型清單時，只列 agent 實際用的那個模型支援的（加上 inherit）——
// 子代理的 effort 不在它的模型支援之列，Codex 會直接拒絕那次 spawn。清單裡有、schema 不認得的新值也列（Codex 升版加的）。
function effortChoicesForModel(base, levels) {
    if (!levels || levels.length === 0)
        return base;
    const kept = base.filter((c) => c.value === 'inherit' || levels.includes(c.value));
    const known = new Set(base.map((c) => c.value));
    return [...kept, ...levels.filter((l) => !known.has(l)).map((l) => ({ value: l, label: l, description: '' }))];
}
function agentNode(i, name, effort, model, pending) {
    const isOrch = name === 'orchestrator';
    const s = i.schema;
    const m = i.doctor?.models;
    const cat = m?.catalog.available ? m.catalog : undefined;
    // doctor 的結論只在它判的就是現在這組值時才用（剛 set 完、doctor 還沒回來時，它講的是舊值）。
    const finding = m?.agents.find((a) => a.agent === name && a.model === model && a.effort === effort);
    const bad = finding && (finding.level === 'problem' || finding.level === 'warn') ? finding : undefined;
    const badTone = bad ? (bad.level === 'problem' ? 'error' : 'warn') : undefined;
    const effective = model !== 'inherit' ? model : m?.session.model ?? null;
    const levels = cat && effective ? cat.models.find((x) => x.slug === effective)?.efforts : undefined;
    const allLevels = cat ? new Set(cat.models.flatMap((x) => x.efforts)) : undefined;
    const knownEffort = effort === 'inherit' || (allLevels ? allLevels.has(effort) : !s || s.effort.choices.some((c) => c.value === effort));
    const hint = s?.effort.agentHints[name]?.[effort];
    const effortBad = bad && bad.status !== 'unknown-model' ? bad : undefined;
    const modelBad = bad && bad.status === 'unknown-model' ? bad : undefined;
    const visible = cat ? cat.models.filter((x) => x.visible) : [];
    const modelLabel = model === 'inherit'
        ? (effective ? `inherit（${effective}）` : 'inherit')
        : modelBad ? `${model} · 這台的 Codex 不認得`
            : i.doctor?.unverifiedModel.includes(name) ? `${model} · 沒對 Codex 驗證` : model;
    const effortEdit = s && {
        kind: 'choice', key: `agents.${name}.effort`, title: `${name} 的 effort${levels && effective ? `（${effective} 支援的）` : ''}`, current: effort,
        choices: effortChoicesForModel((0, schema_1.effortChoicesFor)(s, name), levels),
        placeholder: isOrch ? 'orchestrator 的值只是記錄，強制不了' : '選完會標成未套用，改完一起按「套用」',
    };
    const children = [
        {
            id: `agents/${name}/effort`,
            label: 'effort',
            description: [effort, !knownEffort ? '不認得的值' : '', effortBad ? (effortBad.level === 'problem' ? `${name} 會起不來` : '只有部分模型支援') : '', hint && hint.startsWith('⚠') ? hint : ''].filter(Boolean).join(' · '),
            tone: effortBad ? (effortBad.level === 'problem' ? 'error' : 'warn') : !knownEffort || (hint ?? '').startsWith('⚠') ? 'warn' : pending ? 'pending' : undefined,
            tooltip: s ? [s.effort.description, hint ? `${name}：${hint}` : '', effortBad?.message ?? ''].filter(Boolean).join('\n\n') : effortBad?.message ?? undefined,
            ...editable(i, effortEdit),
        },
        {
            id: `agents/${name}/model`,
            label: 'model',
            description: modelLabel,
            tone: modelBad ? (modelBad.level === 'problem' ? 'error' : 'warn') : undefined,
            tooltip: [s?.model.description ?? '', modelBad?.message ?? ''].filter(Boolean).join('\n\n') || undefined,
            ...editable(i, s && {
                kind: 'text', key: `agents.${name}.model`, title: `${name} 的 model`, current: model,
                prompt: `inherit = 不寫這一行，跟主對話用同一個模型${m?.session.model ? `（現在是 ${m.session.model}）` : ''}。` +
                    (cat ? `這台的 Codex ${cat.codexVersion ?? ''} 有：${visible.map((x) => x.slug).join('、')}` : '能用哪些看這台的 Codex：pwsh .codex/scripts/sdlc.ps1 models'),
                pattern: s.model.pattern, patternError: s.model.patternError,
                suggestions: cat
                    ? [{ value: 'inherit', label: 'inherit', description: '不釘（預設），跟主對話一樣' },
                        ...visible.map((x) => ({ value: x.slug, label: x.slug, description: `effort：${x.efforts.join('／')}${x.slug === cat.default ? ' · 沒設模型時用它' : ''}` }))]
                    : s.model.examples.map((x) => ({ value: x, label: x, description: x === 'inherit' ? '不釘（預設）' : '' })),
                allowEmpty: false,
            }),
        },
    ];
    // 給人看的字：inherit 在畫面上講成它的意思，真正的值在 tooltip 與展開後的那兩行。
    const effortText = effort === 'inherit' ? '跟隨' : effort;
    const modelText = model === 'inherit' ? '跟隨主對話' : model;
    const problem = bad?.level === 'problem';
    return {
        id: `agents/${name}`,
        label: name,
        // 側邊欄很窄：只放兩個值；「未套用」由行尾的 ● 表示，「跑不起來」取代 model —— 那時 model 不是重點。
        description: problem ? `${effortText} · 跑不起來`
            : isOrch && effort === 'inherit' && model === 'inherit' ? '只是記錄'
                : [effortText, modelText, isOrch ? '只是記錄' : ''].filter(Boolean).join(' · '),
        icon: isOrch ? 'info' : 'person',
        // 認得的 effort 用訊號格（一眼比較每個 agent 開多深）；Codex 新加、這裡還沒有圖的值退回一般圖示。
        iconFile: EFFORT_ICONS.has(effort) ? `effort-${effort}${problem ? '-error' : ''}` : undefined,
        tone: problem ? 'error' : pending ? 'pending' : badTone ?? (isOrch ? 'muted' : undefined),
        tooltip: [
            `effort ${effort} · model ${model}${pending ? ' · 未套用' : ''}`,
            isOrch ? 'orchestrator 沒有 agent 定義檔（它就是 AGENTS.md），這裡的值只是記錄，強制不了 —— 啟動 codex 時要自己帶。' : '',
            bad?.message ?? '',
            effortEdit && i.canEdit ? '點一下改 effort；展開改 model。' : '',
        ].filter(Boolean).join('\n\n'),
        // effort 是最常改的：點那一行就直接選，不必先展開。
        ...editable(i, effortEdit),
        children,
    };
}
const EFFORT_ICONS = new Set(['inherit', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra']);
function tuneNode(i) {
    const tune = { command: 'codexSdlc.tune', title: 'tune' };
    if (!i.proposal || !i.config) {
        return { id: 'agents/tune', label: '依 repo 現況給建議', icon: 'sparkle', tone: 'muted', command: tune, tooltip: '跑 tune：只看 repo 規模與舊系統線索，給每個 agent 一個 effort 建議。這是提議，不會自己套用。' };
    }
    const current = new Map(i.config.agents.map((a) => [a.name, a.effort]));
    const diffs = i.proposal.filter((p) => current.has(p.agent) && current.get(p.agent) !== p.effort);
    if (diffs.length === 0) {
        return { id: 'agents/tune', label: '設定跟建議一致', icon: 'sparkle', tone: 'muted', command: tune, tooltip: '點一下依 repo 現況重新給建議。' };
    }
    return {
        id: 'agents/tune',
        label: `${diffs.length} 項建議：${diffs.map((p) => `${p.agent} → ${p.effort}`).join('、')}`,
        icon: 'sparkle',
        // 建議是好消息，不是警告：用強調色。行內「採用」一次採用這幾項（點那一行則是重跑 tune、看理由）。
        tone: 'accent',
        command: tune,
        contextValue: i.canEdit ? 'tuneProposal' : undefined,
        data: [i.rootPath, diffs.map((p) => p.agent)],
        tooltip: diffs.map((p) => `${p.agent}：${current.get(p.agent)} → ${p.effort}（${p.reason}）`).join('\n'),
    };
}
// ---- 審核 ----
function reviewSection(i) {
    const s = i.schema;
    const d = i.doctor?.review;
    const raw = i.config?.reviewMaxRounds;
    const def = s?.reviewRounds.default ?? d?.maxRounds ?? 3;
    let description;
    let tone;
    if (d && !d.valid) {
        description = `寫壞了（${JSON.stringify(raw)}）→ 照預設 ${d.maxRounds} 輪算`;
        tone = 'warn';
    }
    else if (d) {
        description = `${d.maxRounds} 輪${d.source === 'config' ? '' : '（預設）'}`;
    }
    else {
        description = raw === undefined ? `${def} 輪（預設）` : `${String(raw)} 輪`;
    }
    const current = typeof raw === 'number' ? String(raw) : String(d?.maxRounds ?? def);
    const node = {
        id: 'review/maxRounds',
        // 調校 view 不再有「審核」這層標題，所以這一行自己要說清楚是審核的。
        label: '審核修正輪',
        description,
        tone,
        icon: 'eye',
        tooltip: [s?.reviewRounds.description ?? '', '不必套用 —— 下一次委派就生效。'].filter(Boolean).join('\n\n'),
        ...editable(i, s && {
            kind: 'choice', key: 'review.maxRounds', title: '審核最多修幾輪？', current,
            choices: range(s.reviewRounds.min, s.reviewRounds.max).map((n) => ({ value: String(n), label: `${n} 輪`, description: n === s.reviewRounds.default ? '預設' : '' })),
            placeholder: '到了上限還 FAIL，會停下來交回你決定（可以選「指定重點再跑一輪」）。不必套用。',
        }),
    };
    const children = [node];
    if (!i.canEdit && i.editBlockedReason)
        children.push(blockedNode('review', i.editBlockedReason));
    return { id: 'review', label: '審核', icon: 'eye', expanded: true, children };
}
// ---- 更新 ----
function updateSection(i) {
    const s = i.schema;
    const rawCheck = i.config?.updateCheck;
    const choice = s?.updateCheck.choices.find((c) => c.value === rawCheck);
    const checkNode = {
        id: 'update/check',
        label: s?.updateCheck.title ?? '檢查頻率',
        description: rawCheck === undefined ? `${s?.updateCheck.choices.find((c) => c.value === s?.updateCheck.default)?.label ?? 'daily'}（預設）`
            : choice ? choice.label : `不認得的值「${String(rawCheck)}」→ 照每天算，會連網`,
        tone: rawCheck !== undefined && !choice && s ? 'warn' : undefined,
        icon: 'history',
        tooltip: choice?.description ?? s?.updateCheck.description,
        ...editable(i, s && {
            kind: 'choice', key: 'update.check', title: '多久檢查一次有沒有新版？', current: typeof rawCheck === 'string' ? rawCheck : s.updateCheck.default,
            choices: s.updateCheck.choices, placeholder: '只影響「有新版」的通知，不影響任何流程。',
        }),
    };
    const rawSource = typeof i.config?.updateSource === 'string' ? i.config.updateSource : '';
    // 認不得的寫法（例如 4.14 以前收過的 github.com/o/r）check-update 只會靜默地查不到 —— 在這裡標出來。
    const sourceOk = !rawSource || (0, schema_1.matchesPattern)(s?.updateSource.pattern, rawSource);
    const sourceNode = {
        id: 'update/source',
        label: s?.updateSource.title ?? '來源',
        description: !rawSource ? '未設定 —— 不會有更新通知' : sourceOk ? rawSource : `${rawSource} —— 寫法認不得，查不到更新`,
        tone: !rawSource ? 'muted' : sourceOk ? undefined : 'warn',
        icon: 'repo',
        tooltip: s?.updateSource.description,
        ...editable(i, s && {
            kind: 'text', key: 'update.source', title: '更新來源（發佈物所在的 repo 網址）', current: rawSource,
            prompt: s.updateSource.description, pattern: s.updateSource.pattern, patternError: s.updateSource.patternError,
            suggestions: [], allowEmpty: true,
        }),
    };
    const children = [checkNode, sourceNode, { id: 'update/now', label: '立即檢查更新', icon: 'cloud-download', command: { command: 'codexSdlc.checkUpdate', title: '立即檢查更新' } }];
    if (!i.canEdit && i.editBlockedReason)
        children.push(blockedNode('update', i.editBlockedReason));
    return { id: 'update', label: '更新', icon: 'cloud', children };
}
// ---- 規範 ----
function guidelinesSection(i) {
    const g = i.guidelines;
    const children = [];
    if (!g.dir) {
        children.push({ id: 'guidelines/none', label: '沒有 guidelines/（選用）', icon: 'info', tone: 'muted', tooltip: '團隊規範放在 guidelines/，升級永遠不動它。不需要就不用建。' });
        return { id: 'guidelines', label: '規範', icon: 'library', children };
    }
    const docs = g.files.filter((f) => f.toLowerCase().endsWith('.md') && f.toLowerCase() !== 'readme.md');
    children.push({
        id: 'guidelines/docs',
        label: '規範文件',
        description: docs.length > 0 ? docs.map((f) => f.replace(/\.md$/i, '')).join(' · ') : '沒有',
        icon: 'book',
        children: docs.map((f) => ({ id: `guidelines/docs/${f}`, label: f, icon: 'markdown', command: { command: 'codexSdlc.openFile', title: '開啟', arguments: [`${i.rootPath}/guidelines/${f}`] } })),
    });
    if (g.rulesExists) {
        const invalid = (i.doctor?.guidelines ?? []).find((f) => f.code === 'rules-invalid');
        children.push({
            id: 'guidelines/rules',
            label: '機械規則',
            description: `rules.json${g.ruleCount !== undefined ? ` · ${g.ruleCount} 條` : ''}${invalid ? ' · 有規則沒生效' : i.doctor ? ' · 驗證通過' : ''}`,
            icon: invalid ? 'error' : 'law',
            tone: invalid ? 'error' : i.doctor ? 'ok' : undefined,
            tooltip: invalid ? invalid.text : '存檔時會替你驗一次（guideline-gate -Validate），問題會出現在 Problems 面板的那一條規則上。',
            contextValue: 'openable',
            command: { command: 'codexSdlc.openFile', title: '開啟', arguments: [`${i.rootPath}/${RULES_FILE}`] },
        });
    }
    if (g.rulesExists || g.gateDisabled) {
        children.push({
            id: 'guidelines/gate',
            label: '機械層',
            description: g.gateDisabled ? '關（guidelines/.gate-disabled）' : '開',
            icon: g.gateDisabled ? 'circle-slash' : 'pass',
            tone: g.gateDisabled ? 'warn' : 'ok',
            contextValue: g.gateDisabled ? 'gateOff' : 'gateOn',
            command: { command: 'codexSdlc.toggleGate', title: g.gateDisabled ? '打開機械層' : '關閉機械層…' },
            tooltip: g.gateDisabled
                ? 'rules.json 一條都不會擋，而且這個開關會活過每一次升級。點一下打開。'
                : '寫檔後會用 rules.json 掃剛寫出去的檔。點一下關閉（會先說明後果再確認）。',
        });
    }
    return { id: 'guidelines', label: '規範', icon: 'library', children };
}
// ---- 這台機器 ----
function machineSection(i) {
    const m = i.machine;
    return {
        id: 'machine',
        label: '這台機器',
        icon: 'vm',
        description: '只影響這台機器，不進 sdlc.config.json',
        children: [
            {
                id: 'machine/pwsh', label: 'pwsh', icon: 'terminal-powershell',
                description: m.pwsh.ok ? m.pwsh.path : '找不到 PowerShell 7',
                tone: m.pwsh.ok ? undefined : 'error',
                tooltip: m.pwsh.ok ? '點一下換一支（寫進這台機器的 VS Code 設定 codexSdlc.pwshPath）。' : m.pwsh.message,
                contextValue: 'machinePwsh',
                command: { command: 'codexSdlc.pickPwsh', title: '選擇 pwsh' },
            },
            { id: 'machine/extension', label: 'extension', icon: 'extensions', description: m.extensionVersion },
            {
                id: 'machine/payload', label: '內附的發佈物', icon: 'package',
                description: m.payloadVersion ?? '沒有（開發模式）',
                tone: m.payloadVersion ? undefined : 'muted',
                tooltip: m.payloadVersion
                    ? `在別的資料夾裡按「安裝到這個工作區」時，沒有更新的遠端版本就用這一份（${m.payloadVersion}）。`
                    : '這個 extension 不是從發佈物裝的，所以沒有內附。安裝時要自己「選擇發佈物…」，或設定發佈物來源。',
            },
        ],
    };
}
// ---- 共用 ----
function editable(i, target) {
    if (!i.canEdit || !target)
        return {};
    return { edit: target, contextValue: 'editable', command: { command: 'codexSdlc.editSetting', title: '修改', arguments: [target] } };
}
function blockedNode(section, reason) {
    return { id: `${section}/blocked`, label: reason, icon: 'lock', tone: 'muted' };
}
function range(lo, hi) {
    const out = [];
    for (let n = lo; n <= hi; n++)
        out.push(n);
    return out;
}
// 把整棵樹攤平（測試與 host 測試用）。
function flatten(nodes) {
    return nodes.flatMap((n) => [n, ...flatten(n.children ?? [])]);
}
