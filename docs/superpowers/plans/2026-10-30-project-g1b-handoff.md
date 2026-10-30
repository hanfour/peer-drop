# G1b 群組聊天室客戶端交接

記錄日期：2026-10-30。G1b 實作群組客戶端核心與 App 接線；群組介面屬後續 G2。原始範圍與設計決定見 [G1b 計畫](2026-10-25-project-g1b-group-client.md)。

## 本機驗證

- 群組模組：116 項測試，115 項通過、1 項端對端測試因未指定本機伺服器而略過。
- `Scripts/group-e2e.sh`：本機三裝置流程通過，涵蓋帳號及匿名加入、互發、離線補抓、踢人與金鑰輪換、禁止重加入、關房後讀取歷史。每次執行使用獨立的本機 Worker 資料。
- Worker：469 項測試通過；`npx tsc --noEmit` 通過。
- Mac：`PeerDropMac` 建置成功。
- Swift 套件全套：1,669 項中 1 項失敗、2 項略過。失敗為原計畫已列出的 `IdentityKeyManagerTests.testKeyPersistsAcrossInstances`。
- iOS 模擬器全套：826 項中 825 項通過；`ClipboardSyncManagerInjectionTests.test_buildPayload_readsFromInjectedPasteboard` 等待 `payload arrives` 逾時，單獨重跑仍失敗。此項尚待調查，不可視為全套通過。

## 後續事項

- 完成整條分支審查及 iOS 剪貼簿測試失敗的調查。
- 以兩台真機及一台匿名裝置驗證加入、互發、踢人與金鑰輪換；另驗證背景推播文案及第二台裝置接手後舊裝置的狀態。
- G2 實作群組清單、聊天室、設定與建立流程、成員管理、檢舉與封鎖，並移除舊 P2P 群組介面，更新隱私說明與年齡分級。
- G2 送審前確認 Cloudflare Workers 為付費方案，以支援大群組推播的子請求數量。
