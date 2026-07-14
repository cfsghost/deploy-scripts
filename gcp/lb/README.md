# 外部 HTTPS Load Balancer（自訂網域 + Cloud Run 前後端分流）

用 `lb.sh` 建立 Global External Application Load Balancer，讓自訂網域的流量按路徑分流到不同的 Cloud Run 服務——預設 `/api/*` 給 backend，其餘（頁面、靜態資源）給 frontend。包含固定 IP、Google 管理的 SSL 憑證與 HTTP→HTTPS 自動轉址。

```
                        ┌──> /api/*   ──> Cloud Run（backend）
網域 ──> 靜態 IP ──> LB ──┤
                        └──> 其餘流量 ──> Cloud Run（frontend）
```

## 目錄內容

| 檔案 | 用途 |
|---|---|
| `lb.sh` | LB 管理工具：建立/檢查/刪除整組 LB、輸出靜態 IP、鎖定 Cloud Run 直連 |

## 前置需求

- frontend / backend 的 Cloud Run 服務**已完成第一次部署**（可搭配 `../cloudrun/wif.sh` 的流程）
- 一個你能設定 DNS 記錄的網域
- ⚠️ 外部 LB 的 forwarding rule 是**持續計費**資源（約 $18/月起），測試完記得 `delete`

## 快速開始

```bash
./lb.sh setup app.example.com --frontend my-frontend --backend my-backend
```

`setup` 依序完成（冪等，重跑會跳過已存在的）：

1. 確認 Cloud Run 服務存在、啟用 Compute API
2. 保留全域靜態 IP
3. 為每個服務建立 serverless NEG + backend service
4. 建立 URL map（預設 → frontend，`/api/*` → backend）
5. 建立 Google 管理 SSL 憑證
6. 建立 HTTPS proxy、HTTP→HTTPS 轉址、443/80 forwarding rules

完成後照輸出指示做兩件事：

```bash
# 1. 到 DNS 服務商加一筆 A 記錄: app.example.com → <輸出的靜態 IP>
#    （IP 隨時可用 ./lb.sh ip 再查）

# 2. 追蹤憑證簽發進度（DNS 生效後 Google 自動簽發，通常 15-60 分鐘）
./lb.sh check
```

憑證顯示 `ACTIVE` 後，`https://app.example.com` 就通了。

## 鎖定直連（建議）

LB 建好後，服務原本的 `*.run.app` 網址仍然可以直連，繞過 LB。建議鎖定：

```bash
./lb.sh lock my-frontend
./lb.sh lock my-backend
# 之後 run.app 直連會回 404，只有走 LB（與 VPC 內部）的流量進得來
./lb.sh unlock my-frontend    # 需要時恢復
```

## 指令一覽

```
./lb.sh setup <網域> --frontend <服務> [--backend <服務>]
                       建立整組 LB（冪等，可重跑補齊）
./lb.sh check          逐項檢查元件與憑證簽發狀態
./lb.sh ip             輸出靜態 IP（設定 DNS A 記錄用）
./lb.sh lock <服務>     限制服務只接受 LB 流量（關閉 run.app 直連）
./lb.sh unlock <服務>   恢復服務可直連
./lb.sh delete         刪除整組 LB 元件（需輸入 LB 名稱確認；不動 Cloud Run 服務）
```

### 選項與環境變數

| 設定 | 說明 |
|---|---|
| `-p, --project <id>` | 指定 GCP 專案 ID（優先於環境變數與 gcloud config） |
| `-n, --name <名稱>` | LB 元件命名，預設 `web`；同專案建第二組 LB 時使用，且之後每次執行都需帶同樣的值 |
| `--region <區域>` | Cloud Run 服務所在區域，預設 `asia-east1` |
| `--frontend <服務>` | 接收預設流量的 Cloud Run 服務（`setup` 必填） |
| `--backend <服務>` | 接收 API 流量的 Cloud Run 服務（`setup` 選填，不給就不分流） |
| `--api-path <路徑>` | 分流到 backend 的路徑，預設 `/api/*` |
| `LB_PROJECT_ID` / `LB_NAME` / `LB_REGION` / `LB_API_PATH` | 上述設定的環境變數版本 |

## 常見問題

- **憑證一直停在 `PROVISIONING`**：幾乎都是 DNS 還沒生效或 A 記錄指錯 IP，用 `./lb.sh ip` 核對；DNS 正確後最長可能等上一小時。
- **想改分流路徑或加規則**：`setup` 只建立初始規則，之後用 `gcloud compute url-maps edit um-<名稱>` 直接編輯。
- **要同時服務 `www.example.com` 和 `example.com`**：Google 管理憑證建立後無法加網域；請 `delete` 後改建（`lb.sh` 目前一組 LB 對一個網域，多網域可用 `-n` 建第二組，或手動建含多網域的憑證）。
- **backend 想拿到真實來源 IP**：LB 會帶 `X-Forwarded-For`，取第一個值即可。
- **需要 CDN**：backend service 可事後開啟 `gcloud compute backend-services update bs-<服務> --global --enable-cdn`，適合 frontend 靜態資源。
- **費用**：forwarding rule 約 $0.025/小時（前 5 條合計），加上流量處理費；靜態 IP 掛在 LB 上不另外收費。
