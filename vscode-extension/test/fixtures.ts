// 測試共用的 doctor data。形狀照 sdlc.ps1 doctor -Json 的 data —— 真的輸出由 integration.test.ts 驗。
export function doctorFixture(): Record<string, unknown> {
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
    problems: 0,
  };
}
