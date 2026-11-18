# 實施計劃：for-multica — 輸入應用包名透過 upstream 取得上游資訊

Slug：`for-multica-upstream-query`
標題：for-multica 增加「包名查詢模式」：輸入應用包名，經 upstream API 取得 src_url/arch/orig_version

> 本文件為 `for-multica` 增加包名查詢能力的實施計劃導出文檔，內容與 `local://for-multica-upstream-query-plan.md` 一致。僅為計劃文檔，不影響運行邏輯；不改動 `agent-config.json`。

---

## Context

- 用戶需求（字面）：參考 `examples/linyaps-app-packaging-script-generator-v3.2026.9.16.2.dev`，在 `for-multica/` 下增加「輸入應用包名 → 透過 upstream 取得上游資訊」的能力。
- 範例已完整實作此行為：`…/for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh`（GET n8n webhook `https://n8n.cicd.getdeepin.org/webhook/1f678037-…`, `?id=<pkgName>` → 回傳 `appid→pkgName`, `download_url→src_url`, `version→orig_version`, `arch`），並寫入本倉庫的 `for-multica/agent.md` 流程（步驟1 解析輸入 → 包名查詢 → 按類型分類任務）。
- 本倉庫 `for-multica/` 目前**完全沒有** upstream 查詢能力（`grep` 全無 `query_upstream`/`n8n`/upstream API 引用）。現有 `for-multica/agent.md` 只支援三種輸入模式：目錄掃描 / CSV / JSON（見 agent.md 輸入支援模式）。
- 現有根 `skills/` 已含 `linyaps-src-init-dispatch/`（巢狀技能前例）。
- **API 已實測**（2026-09-16）：`curl '…?id=net.kuribo64.melonDS'` → HTTP 200，回傳 `{"appid":"net.kuribo64.melonDS","download_url":"https://rustfsadmin.cicd2.getdeepin.org/linyaps/net.kuribo64.melonDS/…_x86_64_1.1.AppImage","version":"1.1","arch":"x86_64","success":true}`。`download_url` 域名 `rustfsadmin.cicd2.getdeepin.org` 亦在目前 `agent-config.json` 的 `global.trusted_domains` 內。

---

## Approach（決定——同時實作 B 機制 + A 接線 = 方案 C）

新增獨立 Skill `linyaps-upstream-query`（機制，B）並在 `agent.md` 寫入第 4 輸入模式「包名查詢模式」（接線，A）。此組合同時滿足「輸入應用包名」字面需求，且與範例機制一致、可被 pipeline 複用。

### 需求行為契約（沿用範例，唯來源約束不同）

- **觸發條件（明確聲明）**：upstream 查詢**僅**在用戶只提供應用包名（bare pkg name）、**未提供完整 URL** 時觸發。用戶已提供完整 URL（`src_url`）→ 不呼叫 upstream，直接走既有 Path A/B 處理流程。此聲明寫入 agent.md「包名查詢模式」定義。
- **既有欄位優先，query 只補缺**：輸入任務已含 `src_url`/`orig_version`/`arch` 時不被覆寫；僅補齊缺失欄位。API 回傳值與既有值不同 → stderr `[WARN]`，不覆寫。
- **`success` 門**：僅當 API 回傳 `data.success` 為真值才採用回傳欄位；否則記入 `errors`。
- **來源不限制於 `trusted_domains`（與 running-skills 不同）**：upstream API 為權威來源，其回傳的 `src_url` 直接採用，**不**套用 `global.trusted_domains` 過濾。不可達/失敗才阻塞（`upstream_query_failed`），**絕不**臆造值。

### 新增檔案（2 個 + 本導出文件）

1. `for-multica/skills/linyaps-upstream-query/SKILL.md` — 仿照巢狀技能前例結構，聲明用途、觸發條件（僅 bare pkg name、無完整 URL）、輸入（`--pkg-name` / `--task-file` / stdin）、輸出 JSON 契約（`{"global":…,"tasks":[…],"errors":[…]}`）、既有欄位優先契約、且明確記載來源不限制於 `trusted_domains`。
2. `for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh` — 從範例 `query_upstream.sh`（197 行）完整複製並自適應（見下）。
3. `for-multica/upstream-query-implementation-plan.md` — 本導出文件。

### query_upstream.sh 自適應要點（複製後微調）

- 保留範例核心：`set -euo pipefail`、`python3`+`curl` 依賴檢查、`DEFAULT_API_URL` 硬編碼為同一 n8n webhook、`--pkg-name=`（逗號分隔）/`--task-file=`（`tasks[].pkgName` 或每行一個）/stdin、既有欄位優先、`[INFO]/[OK]/[WARN]/[ERROR]` stderr 日誌、`--quiet`、`--help`、退出口（0 若 ≥1 task 或無 error；1 若 0 task 且有 error）、`/tmp/query_upstream.XXXXXX.json` + `cp --output`。
- 微調僅限：腳本頭部註解路徑/SKILL 名改為本技能的相對路徑；其餘邏輯保持範例原樣。
- 不需新增 `--api-url` 以外的 config；如需覆寫，沿用範例 `--api-url=`。

### agent.md 接線（編輯，中文繁體）

- **輸入支援模式**：在現有三模式後新增第 4 模式「包名查詢模式」，並在定義中明確聲明觸發條件：「輸入一個或多個應用包名（如 `net.kuribo64.melonDS`）時觸發本模式：系統調用與上游同步，取得 `src_url`/`arch`/`orig_version` 後自動進入對應處理路徑」；並加：「**當用戶已提供完整 URL（`src_url`）時不觸發 upstream 查詢**，直接以既有值進入對應流程」。同時把「支援三種輸入模式」→「支援四種輸入模式（由用戶選擇其一）」。
- **解析輸入（步驟 1）**：加入「包名查詢模式（僅當輸入為 bare 包名、無完整 URL 時）→ 調用 `for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh`（`--pkg-name` 或 stdin）取得上游資訊，既有欄位優先、query 只補缺；查詢失敗 → 標記 `upstream_query_failed` 阻塞，不臆造值」。
- **工具介紹（技能表）**：新增 `linyaps-upstream-query` 列（`for-multica/skills/linyaps-upstream-query/`）；輔助腳本表新增 `query_upstream.sh`。
- **上游來源約束——修正，避免與本倉庫實際行為矛盾**：改寫為「upstream API 為權威來源，其回傳的 `src_url` 直接採用、不限制於 `trusted_domains`；僅當查詢失敗（`upstream_query_failed`）時阻塞該任務，絕不臆造來源」。

### 不改

- `agent-config.json` 結構不變（API URL 沿用腳本硬編碼 `DEFAULT_API_URL`）。
- path A/B 既有步驟、Git 同步規範、dispatch 指派邏輯皆不動。

---

## Critical files & anchors

1. `for-multica/agent.md` — 新增技能列（工具表）、新增輸入模式（輸入支援模式）、解析輸入（步驟 1）、上游來源約束改寫。全部繁體中文。
2. `for-multica/agent-config.json` — 僅查驗（不回改）；`trusted_domains` 含 `rustfsadmin.cicd2.getdeepin.org`。
3. `for-multica/skills/linyaps-upstream-query/SKILL.md` — 新增。
4. `for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh` — 新增（複製自範例並自適應）。
5. `for-multica/upstream-query-implementation-plan.md` — 新增（本計劃之導出文檔，繁體中文）。
6. 範例模板：`examples/linyaps-app-packaging-script-generator-v3.2026.9.16.2.dev/for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh` — 只讀來源。

---

## Verification

- **真實驗證（網路通）**：
  ```
  bash for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh --pkg-name=net.kuribo64.melonDS
  ```
  斷言：stdout JSON 的 `tasks[0]` 含 `pkgName=net.kuribo64.melonDS`、`src_url` 非空（`https://rustfsadmin.cicd2.getdeepin.org/…`）、`arch=x86_64`、`orig_version=1.1`；`errors` 為空；exit 0。此處**不應有 trusted_domains 過濾**（`src_url` 已採用）。
- **既有欄位優先**：
  ```
  bash …/query_upstream.sh --task-file=/tmp/t.json   # tasks[0] 已含 src_url/orig_version
  ```
  斷言：既有值不被覆寫，若 API 值不同僅出 `[WARN]` 至 stderr。
- **錯誤處理（回退，network 或 schema 異常時）**：以 `--api-url=mock` 或空回應驗證 `success=false` 時該欄位不採用、記入 `errors`、絕不臆造值；`bash -n query_upstream.sh` 語法檢查；`--help` 輸出旗標清單。
- **agent.md 觸發聲明確認**：grep `包名查詢模式` / `linyaps-upstream-query` 於 `for-multica/agent.md`，確認第 4 模式存在、含「僅 bare 包名、無完整 URL 時觸發」聲明、上游來源約束段落已改寫（不再聲稱限制於 `trusted_domains`）、且皆為繁體。
- **導出文檔確認**：`for-multica/upstream-query-implementation-plan.md` 已存在，內容非空、繁體中文，涵蓋 Approach／Critical files／Verification／Assumptions 四節。

---

## Assumptions & contingencies

- **n8n endpoint 不可達或 schema 變動**（非阻塞前提）：腳本會被困入 `errors` 陣列並以非 0 退出對應分支；agent 標記 `upstream_query_failed, <pkgName>, <detail>` 阻塞該任務。**絕不**臆造 `src_url`/`orig_version`/`arch`。此阻塞是「查詢失敗」，**非** trusted_domains 過濾（本倉庫不做該過濾）。
- **script 路徑慣例**：與範例（skill 內 `scripts/`）及本倉庫巢狀技能前例 `skills/linyaps-src-init-dispatch/scripts/` 一致，故放 `for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh`，非根 `scripts/`。
- **API URL 硬編碼**（範例行為）：延用同一 n8n webhook 為 `DEFAULT_API_URL`，不新增 config key；如需切環境用 `--api-url=` 覆寫。此決定避免 `agent-config.json` schema 變更。
