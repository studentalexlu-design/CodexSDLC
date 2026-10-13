"use strict";
// 專案裡的 sdlc.config.schema.json → 設定面板要的選項與說明。**不 import vscode。**
//
// 合法值只有一份，在工作流那邊（.codex/bdd-workflow/sdlc.config.schema.json）：`sdlc.ps1 set` 用它驗、
// VS Code 的 JSON 支援用它畫波浪線、這裡用它列選項。extension 自己不寫任何一份清單 ——
// 寫了，下一次 Codex 多一個 effort 值，面板會是最晚被發現沒跟上的那一個。
// schema 的形狀跟這裡對不上時明講（丟 ContractError），不猜。
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.CONFIG_SCHEMA_REL = void 0;
exports.parseSettingsSchema = parseSettingsSchema;
exports.readSettingsSchema = readSettingsSchema;
exports.effortChoicesFor = effortChoicesFor;
exports.matchesPattern = matchesPattern;
const fs = __importStar(require("node:fs"));
const path = __importStar(require("node:path"));
const contract_1 = require("./contract");
exports.CONFIG_SCHEMA_REL = '.codex/bdd-workflow/sdlc.config.schema.json';
const isObj = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
function at(root, pathSegments) {
    let node = root;
    for (const s of pathSegments) {
        if (!isObj(node) || !(s in node))
            throw new contract_1.ContractError(`sdlc.config.schema.json 缺 ${pathSegments.join('.')}`);
        node = node[s];
    }
    return node;
}
// 給了 fallback 的是「有會比較好」的說明文字；沒給的是面板少了它就不能運作的值。
function text(root, p, fallback) {
    let v;
    try {
        v = at(root, p);
    }
    catch (e) {
        if (fallback !== undefined)
            return fallback;
        throw e;
    }
    if (typeof v === 'string')
        return v;
    if (fallback !== undefined)
        return fallback;
    throw new contract_1.ContractError(`sdlc.config.schema.json 的 ${p.join('.')} 應為字串`);
}
const integer = (root, p) => {
    const v = at(root, p);
    if (typeof v !== 'number' || !Number.isInteger(v))
        throw new contract_1.ContractError(`sdlc.config.schema.json 的 ${p.join('.')} 應為整數`);
    return v;
};
function choices(node, where) {
    const values = isObj(node) ? node.enum : undefined;
    if (!Array.isArray(values) || values.length === 0 || !values.every((x) => typeof x === 'string')) {
        throw new contract_1.ContractError(`sdlc.config.schema.json 的 ${where}.enum 應為字串陣列`);
    }
    const descs = isObj(node) && Array.isArray(node.enumDescriptions) ? node.enumDescriptions : [];
    const labels = isObj(node) && Array.isArray(node['x-labels']) ? node['x-labels'] : [];
    return values.map((value, i) => ({
        value,
        label: typeof labels[i] === 'string' ? labels[i] : value,
        description: typeof descs[i] === 'string' ? descs[i] : '',
    }));
}
function parseSettingsSchema(raw) {
    let root;
    try {
        root = JSON.parse(raw);
    }
    catch {
        throw new contract_1.ContractError('sdlc.config.schema.json 不是合法的 JSON');
    }
    const effortNode = at(root, ['definitions', 'effort']);
    const hintsRaw = isObj(effortNode) && isObj(effortNode['x-agent-hints']) ? effortNode['x-agent-hints'] : {};
    const agentHints = {};
    for (const [agent, hints] of Object.entries(hintsRaw)) {
        if (!isObj(hints))
            continue;
        agentHints[agent] = Object.fromEntries(Object.entries(hints).filter(([, v]) => typeof v === 'string'));
    }
    const modelNode = at(root, ['definitions', 'model']);
    const examples = isObj(modelNode) && Array.isArray(modelNode.examples) ? modelNode.examples.filter((x) => typeof x === 'string') : [];
    const rounds = ['properties', 'review', 'properties', 'maxRounds'];
    const check = ['properties', 'update', 'properties', 'check'];
    const source = ['properties', 'update', 'properties', 'source'];
    return {
        effort: { choices: choices(effortNode, 'definitions.effort'), description: text(root, ['definitions', 'effort', 'description'], ''), agentHints },
        model: {
            description: text(root, ['definitions', 'model', 'description'], ''),
            examples,
            pattern: text(root, ['definitions', 'model', 'pattern'], '') || undefined,
            patternError: text(root, ['definitions', 'model', 'patternErrorMessage'], '格式不對'),
        },
        reviewRounds: {
            min: integer(root, [...rounds, 'minimum']),
            max: integer(root, [...rounds, 'maximum']),
            default: integer(root, [...rounds, 'default']),
            title: text(root, [...rounds, 'title'], '修正輪上限'),
            description: text(root, [...rounds, 'description'], ''),
        },
        updateCheck: {
            choices: choices(at(root, check), 'update.check'),
            default: text(root, [...check, 'default']),
            title: text(root, [...check, 'title'], '檢查頻率'),
            description: text(root, [...check, 'description'], ''),
        },
        updateSource: {
            pattern: text(root, [...source, 'pattern']),
            patternError: text(root, [...source, 'patternErrorMessage'], '格式不對'),
            title: text(root, [...source, 'title'], '來源'),
            description: text(root, [...source, 'description'], ''),
        },
    };
}
// 專案裡沒有 schema（4.9.0 以前的工作流）→ undefined：面板只顯示、不給改。
function readSettingsSchema(root) {
    let raw;
    try {
        raw = fs.readFileSync(path.join(root, exports.CONFIG_SCHEMA_REL), 'utf8');
    }
    catch {
        return undefined;
    }
    return parseSettingsSchema(raw);
}
// 某個 agent 的 effort 選項：通用說明之外，疊上 schema 給那個 agent 的提醒（例如 sa-analyst 不要 high）。
function effortChoicesFor(schema, agent) {
    const hints = schema.effort.agentHints[agent] ?? {};
    return schema.effort.choices.map((c) => ({ ...c, description: hints[c.value] ? `${hints[c.value]}${c.description ? `（${c.description}）` : ''}` : c.description }));
}
// JSON schema 的 pattern 是 ECMAScript regex，跟這裡同一種 —— 只拿來給輸入框即時提示，寫不寫得進去仍由 sdlc.ps1 set 判。
function matchesPattern(pattern, value) {
    if (!pattern)
        return true;
    try {
        return new RegExp(pattern).test(value);
    }
    catch {
        return true;
    }
}
