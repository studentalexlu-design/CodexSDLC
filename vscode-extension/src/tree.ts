// 側邊欄「設定」面板的模型：doctor 的結構化結果 ＋ 設定檔現值 ＋ schema → 一棵樹。**不 import vscode。**
//
// 這棵樹買到的是「一眼看到全部設定的現值、改值只要一步、改完一起套用」。它不判任何規則：
//   - 值合不合法、有沒有套用、hooks 信任了沒 → 看 doctor
//   - 有哪些選項、每個選項什麼意思 → 看專案裡的 schema
//   - 寫檔 → sdlc.ps1 set（extension.ts 負責叫它）
// 「未套用」也不是這裡自己記的狀態：它就是 doctor 的 tuning.stale，只是在寫完、doctor 還沒回來之前先標上。

import type { ConfigSnapshot } from './config';
import type { DoctorData } from './contract';
import { effortChoicesFor, type Choice, type SettingsSchema } from './schema';
import { issuesFromDoctor } from './status';

export type Tone = 'ok' | 'warn' | 'error' | 'pending' | 'muted';

export type EditTarget =
  | { kind: 'choice'; key: string; title: string; current: string; choices: Choice[]; placeholder: string }
  | { kind: 'text'; key: string; title: string; current: string; prompt: string; pattern?: string; patternError: string; suggestions: Choice[]; allowEmpty: boolean };

export interface NodeCommand { command: string; title: string; arguments?: unknown[] }

export interface SettingNode {
  id: string;
  label: string;
  description?: string;
  tooltip?: string;
  icon?: string;            // codicon 名稱
  tone?: Tone;
  // 一個標記；package.json 的 view/item/context 用它決定行內出現哪個按鈕。
  contextValue?: string;
  command?: NodeCommand;
  edit?: EditTarget;
  children?: SettingNode[];
  expanded?: boolean;
}

export interface StoredProposalItem { agent: string; effort: string; reason: string }

export interface MachineInfo {
  pwsh: { ok: boolean; path?: string; message?: string };
  codex: { source: 'setting' | 'path' | 'bundled' | 'none'; path?: string };
  extensionVersion: string;
}

export interface TreeInput {
  rootName: string;
  rootPath: string;
  workflowVersion?: string;
  schema?: SettingsSchema;
  canEdit: boolean;
  editBlockedReason?: string;
  config?: ConfigSnapshot;
  configError?: string;
  // 還沒有設定檔時要列出來的 agent（工作流的 .codex/agents/*.toml ＋ orchestrator）
  knownAgents: string[];
  doctor?: DoctorData;
  checking: boolean;
  pendingAgents: string[];
  proposal?: StoredProposalItem[];
  guidelines: { dir: boolean; files: string[]; rulesExists: boolean; ruleCount?: number; gateDisabled: boolean };
  machine: MachineInfo;
}

const RULES_FILE = 'guidelines/rules.json';

// 未套用 = doctor 說對不上的 ∪ 剛寫、doctor 還沒回來的。orchestrator 沒有 agent 定義檔，永遠不算。
export function pendingAgentsOf(i: Pick<TreeInput, 'doctor' | 'pendingAgents'>): string[] {
  const stale = (i.doctor?.tuning.stale ?? []).map((f) => f.replace(/\.toml$/i, ''));
  return [...new Set([...stale, ...i.pendingAgents])].filter((a) => a !== 'orchestrator').sort();
}

export function buildSettingsTree(i: TreeInput): SettingNode[] {
  return [statusSection(i), agentsSection(i), reviewSection(i), updateSection(i), guidelinesSection(i), machineSection(i)];
}

// ---- 狀態 ----

function statusSection(i: TreeInput): SettingNode {
  const d = i.doctor;
  const children: SettingNode[] = [];
  children.push({
    id: 'status/workflow',
    label: `工作流 ${i.workflowVersion ?? d?.version.contract ?? '（讀不到版本）'}`,
    description: i.checking ? '檢查中…' : d ? (d.problems === 0 ? 'doctor 沒有問題' : `doctor：${d.problems} 個問題`) : '',
    icon: d && d.problems > 0 ? 'warning' : 'check',
    tone: d ? (d.problems > 0 ? 'warn' : 'ok') : 'muted',
    tooltip: '點一下跑完整健檢（doctor），結果寫進輸出面板。',
    command: { command: 'codexSdlc.doctor', title: 'doctor' },
  });
  children.push(hooksNode(i));
  children.push(updateStatusNode(i));

  // doctor 的其他問題。hooks 那一條上面已經有自己的一行，不重複。
  const issues = d ? issuesFromDoctor(d).filter((x) => !/hooks 未信任|專案未信任/.test(x.badge)) : [];
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
        tooltip: x.detail,
        icon: x.level === 'error' ? 'error' : 'warning',
        tone: x.level === 'error' ? 'error' : 'warn',
        command: { command: 'codexSdlc.showOutput', title: '顯示輸出' },
      })),
    });
  }
  return { id: 'status', label: '狀態', description: i.rootName, expanded: true, children };
}

function hooksNode(i: TreeInput): SettingNode {
  const d = i.doctor;
  const base = { id: 'status/hooks', icon: 'shield' };
  const trust: NodeCommand = { command: 'codexSdlc.trustHooks', title: '在終端機信任' };
  if (!d) return { ...base, label: 'Codex hooks：檢查中…', tone: 'muted' };
  const h = d.hooks;
  switch (h.status) {
    case 'trusted':
      return { ...base, label: `Codex hooks：${h.counts?.total ?? 0} 條都已信任`, tone: 'ok', tooltip: '機械強制層會跑。' };
    case 'untrusted': {
      const c = h.counts;
      const parts = [c?.untrusted ? `${c.untrusted} 條未信任` : '', c?.modified ? `${c.modified} 條改過待重審` : '', c?.disabled ? `${c.disabled} 條被停用` : ''].filter(Boolean);
      return {
        ...base, label: `Codex hooks：${parts.join('、') || '有未信任的'}`, tone: 'error', contextValue: 'hooksUntrusted', command: trust,
        tooltip: '沒信任的那幾條一次都不會跑，而且不會提示。點一下在終端機開 Codex，「Hooks need review」選 Trust all and continue。',
      };
    }
    case 'project-untrusted':
      return {
        ...base, label: 'Codex 還沒信任這個專案', tone: 'error', contextValue: 'hooksUntrusted', command: trust,
        tooltip: '專案層的設定與 hooks 整個停用。點一下在終端機開 Codex：先信任這個資料夾，再在「Hooks need review」選 Trust all and continue。',
      };
    case 'no-hooks':
      return {
        ...base, label: 'Codex hooks：沒有 hooks.json', tone: 'error',
        tooltip: '機械強制層整層不存在：寫檔與委派完全沒有人擋，而且 Codex 不會提示。把發佈物解壓到別處，跑 sdlc.ps1 update -Target <這個專案> 補回工具檔。',
      };
    case 'unknown': {
      const notFound = h.reason === 'codex-not-found';
      return {
        ...base,
        label: 'Codex hooks：無法確認',
        description: notFound ? '找不到 codex 執行檔' : '問 codex 沒有回應',
        tone: 'warn',
        contextValue: notFound ? 'hooksUnknown' : 'hooksUntrusted',
        command: notFound ? { command: 'codexSdlc.pickCodex', title: '選擇 codex 執行檔' } : trust,
        tooltip: notFound
          ? '不代表沒信任，也不代表有 —— 查不到。點一下選 codex 執行檔的位置（寫進這台機器的 VS Code 設定）。'
          : '不代表沒信任，也不代表有。點一下在終端機開 Codex 確認一次。',
      };
    }
    default:
      return { ...base, label: `Codex hooks：${h.status}`, tone: 'warn' };
  }
}

function updateStatusNode(i: TreeInput): SettingNode {
  const u = i.doctor?.update;
  const base = { id: 'status/update', icon: 'cloud' };
  if (!u) return { ...base, label: '更新：檢查中…', tone: 'muted' };
  if (u.newer && u.latest) {
    return { ...base, label: `有新版 ${u.latest}`, tone: 'warn', command: { command: 'codexSdlc.whatsnew', title: 'whatsnew' }, tooltip: '點一下看變更說明。' };
  }
  if (u.check === 'never') return { ...base, label: '更新檢查：關閉', tone: 'muted', tooltip: 'update.check = never —— 一條連線都沒有。' };
  if (!u.cached) return { ...base, label: '還沒檢查過更新', tone: 'muted', command: { command: 'codexSdlc.checkUpdate', title: '立即檢查更新' } };
  return { ...base, label: '已是最新', tone: 'ok', description: u.checkedAt ? `上次檢查 ${u.checkedAt.slice(0, 16).replace('T', ' ')}` : undefined };
}

// ---- Agent 調校 ----

function agentsSection(i: TreeInput): SettingNode {
  const pending = pendingAgentsOf(i);
  const children: SettingNode[] = [];
  if (i.configError) {
    children.push({ id: 'agents/error', label: i.configError, icon: 'error', tone: 'error', command: { command: 'codexSdlc.openFile', title: '開啟', arguments: [`${i.rootPath}/sdlc.config.json`] } });
  } else {
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
    for (const a of agents) children.push(agentNode(i, a.name, a.effort, a.model, pending.includes(a.name)));
    children.push(tuneNode(i));
    if (i.canEdit) {
      children.push({ id: 'agents/preset', label: '換成預設組合…', icon: 'layers', tooltip: 'fast／balanced／deep —— 先列出會改什麼，確認才寫。', command: { command: 'codexSdlc.applyPreset', title: '換成預設組合' } });
    }
  }
  if (!i.canEdit && i.editBlockedReason) children.push(blockedNode('agents', i.editBlockedReason));
  return {
    id: 'agents',
    label: 'Agent 調校',
    description: pending.length > 0 ? `${pending.length} 項未套用` : i.doctor?.tuning.status === 'in-sync' ? '已套用' : undefined,
    tone: pending.length > 0 ? 'pending' : undefined,
    icon: pending.length > 0 ? 'circle-filled' : undefined,
    contextValue: pending.length > 0 ? 'tuningPending' : undefined,
    tooltip: pending.length > 0
      ? `改了還沒套用：${pending.join('、')}。不套用的話流程用的是舊值，而畫面上看不出來 —— 按「套用」（只跑一次 apply）。`
      : '改值只要一步；需要套用的會標出來，改完一起套用。',
    expanded: true,
    children,
  };
}

function agentNode(i: TreeInput, name: string, effort: string, model: string, pending: boolean): SettingNode {
  const isOrch = name === 'orchestrator';
  const s = i.schema;
  const knownEffort = !s || s.effort.choices.some((c) => c.value === effort);
  const hint = s?.effort.agentHints[name]?.[effort];
  const children: SettingNode[] = [
    {
      id: `agents/${name}/effort`,
      label: 'effort',
      description: [effort, !knownEffort ? '不認得的值' : '', hint && hint.startsWith('⚠') ? hint : ''].filter(Boolean).join(' · '),
      tone: !knownEffort || (hint ?? '').startsWith('⚠') ? 'warn' : pending ? 'pending' : undefined,
      tooltip: s ? `${s.effort.description}${hint ? `\n\n${name}：${hint}` : ''}` : undefined,
      ...editable(i, s && {
        kind: 'choice', key: `agents.${name}.effort`, title: `${name} 的 effort`, current: effort,
        choices: effortChoicesFor(s, name), placeholder: isOrch ? 'orchestrator 的值只是記錄，強制不了' : '選完會標成未套用，改完一起按「套用」',
      }),
    },
    {
      id: `agents/${name}/model`,
      label: 'model',
      description: model === 'inherit' ? 'inherit' : `${model} · 未驗證`,
      tone: model !== 'inherit' ? 'warn' : undefined,
      tooltip: s?.model.description,
      ...editable(i, s && {
        kind: 'text', key: `agents.${name}.model`, title: `${name} 的 model`, current: model,
        prompt: 'inherit = 不寫這一行，交給 Codex CLI。⚠ model 這個 key 尚未在本工作流驗證過 —— Codex 若忽略它，會靜默地用預設模型跑。',
        pattern: s.model.pattern, patternError: s.model.patternError,
        suggestions: s.model.examples.map((m) => ({ value: m, label: m, description: m === 'inherit' ? '不釘（預設）' : '' })),
        allowEmpty: false,
      }),
    },
  ];
  return {
    id: `agents/${name}`,
    label: name,
    description: [`effort ${effort}`, `model ${model}`, isOrch ? '只是記錄，強制不了' : '', pending ? '未套用' : ''].filter(Boolean).join(' · '),
    icon: pending ? 'circle-filled' : isOrch ? 'info' : 'person',
    tone: pending ? 'pending' : isOrch ? 'muted' : undefined,
    tooltip: isOrch ? 'orchestrator 沒有 agent 定義檔（它就是 AGENTS.md），這裡的值強制不了 —— 啟動 codex 時要自己帶。' : undefined,
    children,
  };
}

function tuneNode(i: TreeInput): SettingNode {
  const tune: NodeCommand = { command: 'codexSdlc.tune', title: 'tune' };
  if (!i.proposal || !i.config) {
    return { id: 'agents/tune', label: '依 repo 現況給建議…', icon: 'lightbulb', command: tune, tooltip: '跑 tune：只看 repo 規模與舊系統線索，給每個 agent 一個 effort 建議。這是提議，不會自己套用。' };
  }
  const current = new Map(i.config.agents.map((a) => [a.name, a.effort]));
  const diffs = i.proposal.filter((p) => current.has(p.agent) && current.get(p.agent) !== p.effort);
  if (diffs.length === 0) {
    return { id: 'agents/tune', label: 'tune：現在的設定跟建議一致', icon: 'lightbulb', tone: 'muted', command: tune, tooltip: '點一下依 repo 現況重新給建議。' };
  }
  return {
    id: 'agents/tune',
    label: `tune 有 ${diffs.length} 項建議`,
    description: diffs.map((p) => `${p.agent} → ${p.effort}`).join('、'),
    icon: 'lightbulb',
    tone: 'warn',
    command: tune,
    tooltip: diffs.map((p) => `${p.agent}：${current.get(p.agent)} → ${p.effort}（${p.reason}）`).join('\n'),
  };
}

// ---- 審核 ----

function reviewSection(i: TreeInput): SettingNode {
  const s = i.schema;
  const d = i.doctor?.review;
  const raw = i.config?.reviewMaxRounds;
  const def = s?.reviewRounds.default ?? d?.maxRounds ?? 3;
  let description: string;
  let tone: Tone | undefined;
  if (d && !d.valid) {
    description = `寫壞了（${JSON.stringify(raw)}）→ 照預設 ${d.maxRounds} 輪算`;
    tone = 'warn';
  } else if (d) {
    description = `${d.maxRounds} 輪${d.source === 'config' ? '' : '（預設）'} · 下一次委派就生效`;
  } else {
    description = raw === undefined ? `${def} 輪（預設）` : `${String(raw)} 輪`;
  }
  const current = typeof raw === 'number' ? String(raw) : String(d?.maxRounds ?? def);
  const node: SettingNode = {
    id: 'review/maxRounds',
    label: s?.reviewRounds.title ?? '修正輪上限',
    description,
    tone,
    icon: 'debug-restart',
    tooltip: s?.reviewRounds.description,
    ...editable(i, s && {
      kind: 'choice', key: 'review.maxRounds', title: '審核最多修幾輪？', current,
      choices: range(s.reviewRounds.min, s.reviewRounds.max).map((n) => ({ value: String(n), label: `${n} 輪`, description: n === s.reviewRounds.default ? '預設' : '' })),
      placeholder: '到了上限還 FAIL，會停下來交回你決定（可以選「指定重點再跑一輪」）。不必套用。',
    }),
  };
  const children = [node];
  if (!i.canEdit && i.editBlockedReason) children.push(blockedNode('review', i.editBlockedReason));
  return { id: 'review', label: '審核', expanded: true, children };
}

// ---- 更新 ----

function updateSection(i: TreeInput): SettingNode {
  const s = i.schema;
  const rawCheck = i.config?.updateCheck;
  const choice = s?.updateCheck.choices.find((c) => c.value === rawCheck);
  const checkNode: SettingNode = {
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
  const sourceNode: SettingNode = {
    id: 'update/source',
    label: s?.updateSource.title ?? '來源',
    description: rawSource || '未設定 —— 不會有更新通知',
    tone: rawSource ? undefined : 'muted',
    icon: 'github',
    tooltip: s?.updateSource.description,
    ...editable(i, s && {
      kind: 'text', key: 'update.source', title: '更新來源（GitHub repo 網址）', current: rawSource,
      prompt: s.updateSource.description, pattern: s.updateSource.pattern, patternError: s.updateSource.patternError,
      suggestions: [], allowEmpty: true,
    }),
  };
  const children: SettingNode[] = [checkNode, sourceNode, { id: 'update/now', label: '立即檢查更新', icon: 'cloud-download', command: { command: 'codexSdlc.checkUpdate', title: '立即檢查更新' } }];
  if (!i.canEdit && i.editBlockedReason) children.push(blockedNode('update', i.editBlockedReason));
  return { id: 'update', label: '更新', children };
}

// ---- 規範 ----

function guidelinesSection(i: TreeInput): SettingNode {
  const g = i.guidelines;
  const children: SettingNode[] = [];
  if (!g.dir) {
    children.push({ id: 'guidelines/none', label: '沒有 guidelines/（選用）', icon: 'info', tone: 'muted', tooltip: '團隊規範放在 guidelines/，升級永遠不動它。不需要就不用建。' });
    return { id: 'guidelines', label: '規範', children };
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
  return { id: 'guidelines', label: '規範', children };
}

// ---- 這台機器 ----

function machineSection(i: TreeInput): SettingNode {
  const m = i.machine;
  const codexText = {
    setting: `${m.codex.path}（設定）`,
    path: m.codex.path ?? 'PATH 上的 codex',
    bundled: `${m.codex.path}（OpenAI 擴充內附）`,
    none: '找不到 —— 查不到 hooks 信任狀態',
  }[m.codex.source];
  return {
    id: 'machine',
    label: '這台機器',
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
      {
        id: 'machine/codex', label: 'codex', icon: 'terminal',
        description: codexText,
        tone: m.codex.source === 'none' ? 'warn' : undefined,
        tooltip: '用來問 Codex 這個專案的 hooks 有沒有被信任。點一下選執行檔（寫進 codexSdlc.codexPath）。',
        contextValue: 'machineCodex',
        command: { command: 'codexSdlc.pickCodex', title: '選擇 codex' },
      },
      { id: 'machine/extension', label: 'extension', icon: 'extensions', description: m.extensionVersion },
    ],
  };
}

// ---- 共用 ----

function editable(i: TreeInput, target: EditTarget | undefined | false): Partial<SettingNode> {
  if (!i.canEdit || !target) return {};
  return { edit: target, contextValue: 'editable', command: { command: 'codexSdlc.editSetting', title: '修改', arguments: [target] } };
}

function blockedNode(section: string, reason: string): SettingNode {
  return { id: `${section}/blocked`, label: reason, icon: 'lock', tone: 'muted' };
}

function range(lo: number, hi: number): number[] {
  const out: number[] = [];
  for (let n = lo; n <= hi; n++) out.push(n);
  return out;
}

// 把整棵樹攤平（測試與 host 測試用）。
export function flatten(nodes: SettingNode[]): SettingNode[] {
  return nodes.flatMap((n) => [n, ...flatten(n.children ?? [])]);
}
