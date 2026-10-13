"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.doctorFixture = doctorFixture;
exports.modelsFixture = modelsFixture;
// 測試共用的 doctor data。形狀照 sdlc.ps1 doctor -Json 的 data —— 真的輸出由 integration.test.ts 驗。
function doctorFixture() {
    return {
        version: { contract: '4.8.0', minCompatible: '4.2.0' },
        unverifiedModel: [],
        config: { exists: true, parsable: true },
        tuning: { status: 'in-sync', stale: [] },
        baseline: { exists: true, version: '4.8.0', fileCount: 40 },
        guidelines: [],
        lint: { ran: true, passed: true, violations: [] },
        review: { maxRounds: 3, source: 'config', valid: true },
        hooks: { status: 'trusted', codex: 'C:\\bin\\codex.exe', counts: { total: 4, trusted: 4, untrusted: 0, modified: 0, disabled: 0 } },
        update: { cached: false, stale: false, newer: false, latest: null, seen: false, checkedAt: null, check: 'daily' },
        editor: { installed: [] },
        environment: [],
        problems: 0,
    };
}
// doctor 的 models 段（4.15.0 起）：這台的 Codex 有兩個模型 —— gpt-5.5 只到 xhigh、gpt-big 到 ultra，
// 再多一個 schema 還不認得的 hyper（Codex 升版新增的值）；主對話用 gpt-big。
function modelsFixture(agents = []) {
    return {
        catalog: {
            available: true, reason: null, codexVersion: '0.162.1', default: 'gpt-big',
            models: [
                { slug: 'gpt-big', visible: true, defaultEffort: 'low', efforts: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra', 'hyper'] },
                { slug: 'gpt-5.5', visible: true, defaultEffort: 'medium', efforts: ['low', 'medium', 'high', 'xhigh'] },
                { slug: 'gpt-secret', visible: false, defaultEffort: 'medium', efforts: ['low', 'medium'] },
            ],
        },
        session: { model: 'gpt-big', source: '~/.codex/config.toml' },
        checkedWith: null,
        agents,
    };
}
