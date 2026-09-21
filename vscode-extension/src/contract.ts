// sdlc.ps1 與各 gate 的 -Json 合約（TypeScript 那一側）。**不 import vscode。**
//
// extension 只讀結構化欄位（data），**從來不從 output 的中文句子裡撈狀態** —— 那是分岔的起點：
// 改一句措辭，extension 就會靜默地顯示錯的東西。所以這裡驗的是欄位名與型別，而且驗不過就明講，
// 不猜、不退回去解析句子。
//
// PowerShell 那一側的同一份合約由 test-sdlc.ps1 的「-Json 是結構化合約」守住；
// 這一側由 test/integration.test.ts 拿**真的** sdlc.ps1 輸出來驗。欄位改名，兩邊都會紅。

export const SUPPORTED_SCHEMA = 1;

// 結構化的 -Json 從這一版的工作流開始。更舊的 sdlc.ps1 連 -CodexPath 這類參數都不認得，
// 叫下去只會得到一個參數錯誤 —— 狀態列要說的是「工作流太舊」，不是「健檢失敗」。
export const MIN_WORKFLOW_VERSION = '4.8.0';

// 在面板裡改設定要 `sdlc.ps1 set` 與專案裡的 schema，兩者都從這一版開始。更舊的專案照樣有狀態列，
// 面板只顯示、不給改，並說要升到哪一版。
export const MIN_SETTINGS_VERSION = '4.9.0';

export function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map((x) => parseInt(x, 10) || 0);
  const pb = b.split('.').map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < 3; i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return Math.sign(d);
  }
  return 0;
}

export class ContractError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ContractError';
  }
}

type Json = Record<string, unknown>;

function isObj(v: unknown): v is Json {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}
function need<T>(ok: boolean, at: string, want: string, v: unknown): T {
  if (!ok) throw new ContractError(`${at} 應為 ${want}，實際是 ${v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v}`);
  return v as T;
}
function field(o: Json, key: string, at: string): unknown {
  if (!(key in o)) throw new ContractError(`缺欄位 ${at}.${key}`);
  return o[key];
}
const str = (o: Json, k: string, at: string) => { const v = field(o, k, at); return need<string>(typeof v === 'string', `${at}.${k}`, 'string', v); };
const optStr = (o: Json, k: string, at: string) => { const v = field(o, k, at); return need<string | null>(v === null || typeof v === 'string', `${at}.${k}`, 'string|null', v); };
const bool = (o: Json, k: string, at: string) => { const v = field(o, k, at); return need<boolean>(typeof v === 'boolean', `${at}.${k}`, 'boolean', v); };
const num = (o: Json, k: string, at: string) => { const v = field(o, k, at); return need<number>(typeof v === 'number', `${at}.${k}`, 'number', v); };
const arr = (o: Json, k: string, at: string) => { const v = field(o, k, at); return need<unknown[]>(Array.isArray(v), `${at}.${k}`, 'array', v); };
const obj = (o: Json, k: string, at: string) => { const v = field(o, k, at); return need<Json>(isObj(v), `${at}.${k}`, 'object', v); };
const strArr = (o: Json, k: string, at: string) => arr(o, k, at).map((x, i) => need<string>(typeof x === 'string', `${at}.${k}[${i}]`, 'string', x));

// ---- 共同外殼 ----

export interface Envelope {
  schema: number;
  command: string;
  exit: number;
  data: Json;
  warnings: string[];
  output: string[];
}

export function parseEnvelope(stdout: string, expectedCommand: string): Envelope {
  const text = stdout.trim();
  if (!text) throw new ContractError('沒有任何 -Json 輸出');
  let root: unknown;
  try {
    root = JSON.parse(text.slice(text.indexOf('{')));
  } catch {
    throw new ContractError(`-Json 輸出不是 JSON：${text.slice(0, 200)}`);
  }
  if (!isObj(root)) throw new ContractError('-Json 輸出不是物件');
  if (!('schema' in root)) {
    // 4.8.0 以前的 sdlc.ps1：{ command, exit, output } —— 只有句子，沒有結構化欄位。
    throw new ContractError('這個專案的 sdlc.ps1 沒有結構化的 -Json（schema）—— 工作流版本太舊');
  }
  const schema = num(root, 'schema', '$');
  if (schema !== SUPPORTED_SCHEMA) {
    throw new ContractError(`sdlc.ps1 的 -Json 是 schema ${schema}，這個 extension 讀的是 schema ${SUPPORTED_SCHEMA}`);
  }
  const env: Envelope = {
    schema,
    command: str(root, 'command', '$'),
    exit: num(root, 'exit', '$'),
    data: obj(root, 'data', '$'),
    warnings: strArr(root, 'warnings', '$'),
    output: strArr(root, 'output', '$'),
  };
  if (env.command !== expectedCommand) throw new ContractError(`預期 ${expectedCommand} 的輸出，收到 ${env.command}`);
  return env;
}

// ---- doctor ----

export interface Finding { level: string; code: string; text: string }
export interface Violation { rule: string; detail: string; fix: string }
export interface HookCounts { total: number; trusted: number; untrusted: number; modified: number; disabled: number }
export interface HookTrust { status: string; reason?: string; codex: string | null; counts?: HookCounts }
export interface InstalledEditor { product: string; version: string; compatible: boolean }

export interface LintResult { ran: boolean; passed: boolean; violations: Violation[] }

export interface DoctorData {
  version: { contract: string; minCompatible: string };
  // comments／schemaRef 從 4.9.0 起才有；更舊的 doctor 沒有這兩個欄位，讀成 false。
  config: { exists: boolean; parsable: boolean; comments: boolean; schemaRef: boolean };
  tuning: { status: string; stale: string[] };
  unverifiedModel: string[];
  baseline: { exists: boolean; version: string | null; fileCount: number };
  guidelines: Finding[];
  lint: LintResult;
  review: { maxRounds: number; source: string; valid: boolean };
  hooks: HookTrust;
  update: { cached: boolean; stale: boolean; newer: boolean; latest: string | null; seen: boolean; checkedAt: string | null; check: string };
  editor: { installed: InstalledEditor[] };
  problems: number;
}

function parseFinding(v: unknown, at: string): Finding {
  const o = need<Json>(isObj(v), at, 'object', v);
  return { level: str(o, 'level', at), code: str(o, 'code', at), text: str(o, 'text', at) };
}

// doctor 與 install 各回一份 agent-lint 的結論，形狀一樣（install 的那一份是裝完當場跑的）。
function parseLint(o: Json, at: string): LintResult {
  const lint = obj(o, 'lint', at);
  return {
    ran: bool(lint, 'ran', `${at}.lint`),
    passed: bool(lint, 'passed', `${at}.lint`),
    violations: arr(lint, 'violations', `${at}.lint`).map((v, i) => {
      const vat = `${at}.lint.violations[${i}]`;
      const x = need<Json>(isObj(v), vat, 'object', v);
      return { rule: str(x, 'rule', vat), detail: str(x, 'detail', vat), fix: str(x, 'fix', vat) };
    }),
  };
}

export function parseDoctor(env: Envelope): DoctorData {
  const d = env.data;
  const at = '$.data';
  const version = obj(d, 'version', at);
  const config = obj(d, 'config', at);
  const tuning = obj(d, 'tuning', at);
  const baseline = obj(d, 'baseline', at);
  const review = obj(d, 'review', at);
  const hooks = obj(d, 'hooks', at);
  const update = obj(d, 'update', at);
  const editor = obj(d, 'editor', at);

  let counts: HookCounts | undefined;
  if ('counts' in hooks) {
    const c = obj(hooks, 'counts', `${at}.hooks`);
    const cat = `${at}.hooks.counts`;
    counts = { total: num(c, 'total', cat), trusted: num(c, 'trusted', cat), untrusted: num(c, 'untrusted', cat), modified: num(c, 'modified', cat), disabled: num(c, 'disabled', cat) };
  }

  return {
    version: { contract: str(version, 'contract', `${at}.version`), minCompatible: str(version, 'minCompatible', `${at}.version`) },
    config: {
      exists: bool(config, 'exists', `${at}.config`),
      parsable: bool(config, 'parsable', `${at}.config`),
      comments: 'comments' in config ? bool(config, 'comments', `${at}.config`) : false,
      schemaRef: 'schemaRef' in config ? bool(config, 'schemaRef', `${at}.config`) : false,
    },
    tuning: { status: str(tuning, 'status', `${at}.tuning`), stale: strArr(tuning, 'stale', `${at}.tuning`) },
    unverifiedModel: strArr(d, 'unverifiedModel', at),
    baseline: {
      exists: bool(baseline, 'exists', `${at}.baseline`),
      version: optStr(baseline, 'version', `${at}.baseline`),
      fileCount: num(baseline, 'fileCount', `${at}.baseline`),
    },
    guidelines: arr(d, 'guidelines', at).map((f, i) => parseFinding(f, `${at}.guidelines[${i}]`)),
    lint: parseLint(d, at),
    review: {
      maxRounds: num(review, 'maxRounds', `${at}.review`),
      source: str(review, 'source', `${at}.review`),
      valid: bool(review, 'valid', `${at}.review`),
    },
    hooks: {
      status: str(hooks, 'status', `${at}.hooks`),
      reason: 'reason' in hooks ? str(hooks, 'reason', `${at}.hooks`) : undefined,
      codex: 'codex' in hooks ? optStr(hooks, 'codex', `${at}.hooks`) : null,
      counts,
    },
    update: {
      cached: bool(update, 'cached', `${at}.update`),
      stale: bool(update, 'stale', `${at}.update`),
      newer: bool(update, 'newer', `${at}.update`),
      latest: optStr(update, 'latest', `${at}.update`),
      seen: bool(update, 'seen', `${at}.update`),
      checkedAt: optStr(update, 'checkedAt', `${at}.update`),
      check: str(update, 'check', `${at}.update`),
    },
    editor: {
      installed: arr(editor, 'installed', `${at}.editor`).map((x, i) => {
        const xat = `${at}.editor.installed[${i}]`;
        const o = need<Json>(isObj(x), xat, 'object', x);
        return { product: str(o, 'product', xat), version: str(o, 'version', xat), compatible: bool(o, 'compatible', xat) };
      }),
    },
    problems: num(d, 'problems', at),
  };
}

// ---- 其他指令 ----

export interface ApplyData { changed: string[]; warnings: string[] }
export function parseApply(env: Envelope): ApplyData {
  if ('error' in env.data) return { changed: [], warnings: [] };
  return { changed: strArr(env.data, 'changed', '$.data'), warnings: strArr(env.data, 'warnings', '$.data') };
}

export interface CheckUpdateData { status: string; installed: string | null; latest: string | null; newer: boolean }
export function parseCheckUpdate(env: Envelope): CheckUpdateData {
  const d = env.data;
  return {
    status: str(d, 'status', '$.data'),
    installed: 'installed' in d ? optStr(d, 'installed', '$.data') : null,
    latest: 'latest' in d ? optStr(d, 'latest', '$.data') : null,
    newer: 'newer' in d ? bool(d, 'newer', '$.data') : false,
  };
}

// ---- fetch／install（4.10.0 起）----
//
// 這兩個是「在一個還沒裝工作流的資料夾裡把它裝起來」的那條路。網路、下載、解壓、驗 sha 全部在
// sdlc.ps1 那一側 —— extension 只讀這裡的結果，自己一個 socket 都不開。

export interface FetchData {
  chosen: string;                 // remote｜cached｜bundled｜none
  version: string | null;
  path: string | null;            // 可以拿去當 install -Source 的目錄
  remote: { checked: boolean; reachable: boolean; latest: string | null; url: string | null; reason: string | null };
  bundled: { version: string | null; path: string | null };
  cacheDir: string;
}

export function parseFetch(env: Envelope): FetchData {
  const d = env.data;
  const at = '$.data';
  const remote = obj(d, 'remote', at);
  const bundled = obj(d, 'bundled', at);
  return {
    chosen: str(d, 'chosen', at),
    version: optStr(d, 'version', at),
    path: optStr(d, 'path', at),
    remote: {
      checked: bool(remote, 'checked', `${at}.remote`),
      reachable: bool(remote, 'reachable', `${at}.remote`),
      latest: optStr(remote, 'latest', `${at}.remote`),
      url: optStr(remote, 'url', `${at}.remote`),
      reason: optStr(remote, 'reason', `${at}.remote`),
    },
    bundled: { version: optStr(bundled, 'version', `${at}.bundled`), path: optStr(bundled, 'path', `${at}.bundled`) },
    cacheDir: str(d, 'cacheDir', at),
  };
}

export interface InstallData {
  error: string | null;           // not-a-release｜same-path｜nothing-to-adopt
  mode: string;                   // install｜adopt
  target: string;
  version: string | null;
  written: number;
  // 已經有一份、沒有覆蓋的檔（寫成 *.new）。AGENTS.md 幾乎一定在這裡 —— 沒合進去的話整套流程不會啟動。
  needsMerge: string[];
  guidelinesSkeleton: boolean;
  configCreated: boolean;
  preset: string | null;
  hooksWritten: boolean;
  lint: LintResult;
  guidelines: Finding[];
  orchestratorHint: string | null;
}

const EMPTY_INSTALL: InstallData = {
  error: null, mode: '', target: '', version: null, written: 0, needsMerge: [], guidelinesSkeleton: false,
  configCreated: false, preset: null, hooksWritten: false, lint: { ran: false, passed: false, violations: [] },
  guidelines: [], orchestratorHint: null,
};

export function parseInstall(env: Envelope): InstallData {
  const d = env.data;
  const at = '$.data';
  // 還沒開始複製就停下來的失敗（來源不是發佈物、來源＝目標）：只有 error，沒有其他欄位。
  if ('error' in d) return { ...EMPTY_INSTALL, error: optStr(d, 'error', at) };
  const config = obj(d, 'config', at);
  return {
    error: null,
    mode: str(d, 'mode', at),
    target: str(d, 'target', at),
    version: optStr(d, 'version', at),
    written: num(d, 'written', at),
    needsMerge: strArr(d, 'needsMerge', at),
    guidelinesSkeleton: bool(d, 'guidelinesSkeleton', at),
    configCreated: bool(config, 'created', `${at}.config`),
    preset: optStr(config, 'preset', `${at}.config`),
    hooksWritten: bool(d, 'hooksWritten', at),
    lint: parseLint(d, at),
    guidelines: arr(d, 'guidelines', at).map((f, i) => parseFinding(f, `${at}.guidelines[${i}]`)),
    orchestratorHint: optStr(d, 'orchestratorHint', at),
  };
}

export interface UpdateData {
  error: string | null;           // not-a-release｜same-path｜not-managed
  result: string;                 // applied｜up-to-date｜cancelled
  from: string | null;
  to: string | null;
  modified: string[];
  backup: string | null;
}

export function parseUpdate(env: Envelope): UpdateData {
  const d = env.data;
  const at = '$.data';
  if ('error' in d) return { error: optStr(d, 'error', at), result: '', from: null, to: null, modified: [], backup: null };
  return {
    error: null,
    result: 'result' in d ? str(d, 'result', at) : '',
    from: optStr(d, 'from', at),
    to: optStr(d, 'to', at),
    modified: strArr(d, 'modified', at),
    backup: 'backup' in d ? optStr(d, 'backup', at) : null,
  };
}

export interface WhatsNewData { source: string; text: string; latest: string | null }
export function parseWhatsNew(env: Envelope): WhatsNewData {
  const d = env.data;
  const source = str(d, 'source', '$.data');
  if (source === 'cache') {
    return { source, latest: str(d, 'latest', '$.data'), text: str(d, 'notes', '$.data') };
  }
  if (source === 'installed') {
    const entries = arr(d, 'entries', '$.data').map((e, i) => {
      const eat = `$.data.entries[${i}]`;
      const o = need<Json>(isObj(e), eat, 'object', e);
      return `[${str(o, 'key', eat)}]\n${str(o, 'text', eat)}`;
    });
    return { source, latest: null, text: entries.join('\n\n') };
  }
  return { source, latest: null, text: '' };
}

// ---- set（4.9.0 起）----

export interface SettingChange { key: string; from: string | null; to: string; changed: boolean; needsApply: boolean }
export interface SettingError { key: string; value: string | null; message: string; suggestion: string | null }
export interface SetData {
  error: string | null;            // invalid／has-comments／schema-unreadable／config-unreadable／cancelled／…
  changes: SettingChange[];
  errors: SettingError[];
  written: boolean;
  applied: boolean;
  preview: boolean;
  configCreated: boolean;      // 沒有 sdlc.config.json 時，set 會先替你建一份預設的
}

// 值可能是字串或整數（review.maxRounds）；面板只拿來顯示，一律轉成字串。
const scalar = (o: Json, k: string, at: string): string | null => {
  const v = field(o, k, at);
  if (v === null) return null;
  need<unknown>(typeof v === 'string' || typeof v === 'number', `${at}.${k}`, 'string|number|null', v);
  return String(v);
};

export function parseSet(env: Envelope): SetData {
  const d = env.data;
  const error = 'error' in d ? optStr(d, 'error', '$.data') : null;
  // 在讀設定檔、讀 schema 之前就停下來的錯誤，不會有 changes／errors。
  const changes = 'changes' in d ? arr(d, 'changes', '$.data') : [];
  const errors = 'errors' in d ? arr(d, 'errors', '$.data') : [];
  return {
    error,
    changes: changes.map((c, i) => {
      const cat = `$.data.changes[${i}]`;
      const o = need<Json>(isObj(c), cat, 'object', c);
      return { key: str(o, 'key', cat), from: scalar(o, 'from', cat), to: scalar(o, 'to', cat) ?? '', changed: bool(o, 'changed', cat), needsApply: bool(o, 'needsApply', cat) };
    }),
    errors: errors.map((e, i) => {
      const eat = `$.data.errors[${i}]`;
      const o = need<Json>(isObj(e), eat, 'object', e);
      return { key: str(o, 'key', eat), value: optStr(o, 'value', eat), message: str(o, 'message', eat), suggestion: optStr(o, 'suggestion', eat) };
    }),
    written: 'written' in d ? bool(d, 'written', '$.data') : false,
    applied: 'applied' in d ? bool(d, 'applied', '$.data') : false,
    preview: 'preview' in d ? bool(d, 'preview', '$.data') : false,
    configCreated: 'configCreated' in d ? bool(d, 'configCreated', '$.data') : false,
  };
}

export interface ProposalItem { agent: string; current: string; proposed: string; reason: string; signal: string }
export interface TuneData { proposal: ProposalItem[]; applied: boolean; generatedAt: string | null }
export function parseTune(env: Envelope): TuneData {
  const d = env.data;
  if ('error' in d) return { proposal: [], applied: false, generatedAt: null };
  return {
    applied: bool(d, 'applied', '$.data'),
    generatedAt: 'generatedAt' in d ? optStr(d, 'generatedAt', '$.data') : null,
    proposal: arr(d, 'proposal', '$.data').map((p, i) => {
      const pat = `$.data.proposal[${i}]`;
      const o = need<Json>(isObj(p), pat, 'object', p);
      return { agent: str(o, 'agent', pat), current: str(o, 'current', pat), proposed: str(o, 'proposed', pat), reason: str(o, 'reason', pat), signal: str(o, 'signal', pat) };
    }),
  };
}

// ---- gates ----

export interface GuidelineHit { rule: string; severity: string; file: string; line: number; message: string; fix: string }
export interface GuidelineGateResult { status: string; files: string[]; problems: string[]; hits: GuidelineHit[] }

function parseJsonObject(stdout: string, what: string): Json {
  const text = stdout.trim();
  const start = text.indexOf('{');
  if (start < 0) throw new ContractError(`${what} 沒有 -Json 輸出：${text.slice(0, 200)}`);
  let root: unknown;
  try { root = JSON.parse(text.slice(start)); } catch { throw new ContractError(`${what} 的 -Json 輸出不是 JSON`); }
  return need<Json>(isObj(root), '$', 'object', root);
}

export function parseGuidelineGate(stdout: string): GuidelineGateResult {
  const o = parseJsonObject(stdout, 'guideline-gate');
  if (!('status' in o)) throw new ContractError('guideline-gate 的 -Json 沒有 status —— 工作流版本太舊');
  return {
    status: str(o, 'status', '$'),
    files: strArr(o, 'files', '$'),
    problems: strArr(o, 'problems', '$'),
    hits: arr(o, 'hits', '$').map((h, i) => {
      const hat = `$.hits[${i}]`;
      const x = need<Json>(isObj(h), hat, 'object', h);
      return { rule: str(x, 'rule', hat), severity: str(x, 'severity', hat), file: str(x, 'file', hat), line: num(x, 'line', hat), message: str(x, 'message', hat), fix: str(x, 'fix', hat) };
    }),
  };
}

// guideline-gate -Validate -Json（只驗 rules.json 本身）。rule_problems 從 4.9.0 起才有。
export interface RuleProblem { index: number | null; id: string | null; field: string | null; message: string }
export interface RulesValidation { passed: boolean; exists: boolean; ruleCount: number; problems: string[]; ruleProblems: RuleProblem[] }

export function parseRulesValidation(stdout: string): RulesValidation {
  const o = parseJsonObject(stdout, 'guideline-gate -Validate');
  const problems = strArr(o, 'problems', '$');
  const ruleProblems = 'rule_problems' in o
    ? arr(o, 'rule_problems', '$').map((p, i) => {
      const pat = `$.rule_problems[${i}]`;
      const x = need<Json>(isObj(p), pat, 'object', p);
      const index = field(x, 'index', pat);
      return {
        index: need<number | null>(index === null || typeof index === 'number', `${pat}.index`, 'number|null', index),
        id: optStr(x, 'id', pat),
        field: optStr(x, 'field', pat),
        message: str(x, 'message', pat),
      };
    })
    // 舊版只有句子：一律當成檔案層級的問題（放第一行），不從句子裡猜是哪一條。
    : problems.map((message) => ({ index: null, id: null, field: null, message }));
  return { passed: bool(o, 'passed', '$'), exists: bool(o, 'exists', '$'), ruleCount: num(o, 'rule_count', '$'), problems, ruleProblems };
}

export interface DlpCategory { type: string; count: number; lines: number[] }
export interface DlpFinding { file: string; categories: DlpCategory[] }
export interface DlpGateResult { disabled: boolean; scanned: string[]; findings: DlpFinding[] }

export function parseDlpGate(stdout: string): DlpGateResult {
  const o = parseJsonObject(stdout, 'dlp-gate');
  if (!('disabled' in o)) throw new ContractError('dlp-gate 的 -Json 沒有 disabled —— 工作流版本太舊');
  return {
    disabled: bool(o, 'disabled', '$'),
    scanned: strArr(o, 'scanned', '$'),
    findings: arr(o, 'findings', '$').map((f, i) => {
      const fat = `$.findings[${i}]`;
      const x = need<Json>(isObj(f), fat, 'object', f);
      return {
        file: str(x, 'file', fat),
        categories: arr(x, 'categories', fat).map((c, j) => {
          const cat = `${fat}.categories[${j}]`;
          const y = need<Json>(isObj(c), cat, 'object', c);
          return {
            type: str(y, 'type', cat),
            count: num(y, 'count', cat),
            lines: arr(y, 'lines', cat).map((n, k) => need<number>(typeof n === 'number', `${cat}.lines[${k}]`, 'number', n)),
          };
        }),
      };
    }),
  };
}
