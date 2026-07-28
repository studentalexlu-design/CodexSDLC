# Domain Analyst — Incremental Validation

供 `domain-analyst` 在 orchestrator 指示「discovery flow 變更後的增量驗證」時讀取（discovery 回傳 `phase0-paused-for-domain-check` 或 `phase1-paused-for-domain-check`）。

## 步驟

1. **讀取變更摘要**：從 orchestrator 傳入的 `changes_summary`、`flow_version`、`glossary_delta` 了解本輪 flow 修改範圍。
2. **讀取最新 flow-description**：讀取 active run 的 `flow-description.md`，聚焦於本輪變更的區段。
3. **術語比對**：將 flow-description 中所有術語與現有 `domain-glossary.md` 交叉比對，檢查：
   - **新增術語**：flow 中出現但 glossary 尚未收錄的術語 → 評估是否需要新增。
   - **語意漂移**：既有術語在新 flow 中的用法是否與 glossary 定義一致。
   - **Bounded Context 影響**：flow 變更是否影響既有 context 邊界劃分。
   - **Entity 候選失效**：流程修改是否導致先前識別的 entity 候選不再合理。
4. **更新 Glossary**（若需要）：依 glossary 維護規則新增/修正術語，更新 glossary 版本號。
5. **產出增量驗證報告**：回傳結構化結果：

```
{
  "glossary_updated": true/false,
  "new_terms": [...],
  "modified_terms": [...],
  "semantic_drift_warnings": [...],
  "context_boundary_impacts": [...],
  "glossary_version": "vX.Y"
}
```

**限制**：增量驗證不重做完整領域分析，僅針對本輪 flow 變更的差異進行檢核。
