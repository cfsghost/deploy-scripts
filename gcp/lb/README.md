# 外部 HTTPS Load Balancer（多網域 + 路徑分流到 Cloud Run）

用 `lb.sh` 建立 Global External Application Load Balancer，掛上一個或多個網域，並為每個網域設定「路徑 → 目標」的分流規則。目標可以是 Cloud Run 服務，也可以是**公開 GCS bucket**（自動開 CDN，適合靜態資源與公開下載檔）。包含固定 IP、每個網域一張 Google 管理 SSL 憑證，以及 HTTP→HTTPS 自動轉址。

```
app.example.com   ──┐          ┌── app.example.com   /*        ──> Cloud Run（frontend）
                    ├─> LB ────┼── app.example.com   /api/*    ──> Cloud Run（backend）
files.example.com ──┘          └── files.example.com /*        ──> GCS bucket（CDN）
      （所有網域的 A 記錄都指向同一個靜態 IP）
```

## 目錄內容

| 檔案 | 用途 |
|---|---|
| `lb.sh` | LB 管理工具：初始化、掛/卸網域、增/刪分流規則、檢查、鎖定直連、整組刪除 |

## 前置需求

- 要掛上的 Cloud Run 服務**已完成第一次部署**（可搭配 `../cloudrun/wif.sh` 的流程）
- 一個你能設定 DNS 記錄的網域
- ⚠️ 外部 LB 的 forwarding rule 是**持續計費**資源（約 $18/月起），測試完記得 `delete`

## 快速開始

```bash
# 1. 基礎設施（每組 LB 一次）：靜態 IP、HTTP→HTTPS 轉址
./lb.sh init

# 2. 掛上網域（每個網域一次）：建立 Google 管理憑證
./lb.sh add_domain app.example.com

# 3. 設定分流規則：路徑 '/' 是該網域的預設服務，需最先設定
./lb.sh add_rule app.example.com / my-frontend
./lb.sh add_rule app.example.com '/api/*' my-backend

# 4. 檢視結果
./lb.sh list
```

完成後照輸出指示做兩件事：

```bash
# 1. 到 DNS 服務商加一筆 A 記錄: app.example.com → <靜態 IP>
#    （IP 隨時可用 ./lb.sh ip 查；所有網域都指向同一個 IP）

# 2. 追蹤憑證簽發進度（DNS 生效後 Google 自動簽發，通常 15-60 分鐘）
./lb.sh check
```

憑證顯示 `ACTIVE` 後，`https://app.example.com` 就通了。要掛第二個網域，重複 `add_domain` + `add_rule` 即可，共用同一個 IP 與 LB。

規則異動直接下指令，馬上生效：

```bash
./lb.sh add_rule app.example.com '/api/*' my-backend-v2   # 同路徑重下 = 換服務
./lb.sh remove_rule app.example.com '/api/*'              # 移除規則
./lb.sh remove_domain admin.example.com                   # 卸下整個網域（規則+憑證）
```

不再被任何規則引用的 backend service / NEG / backend bucket 會自動清除，不留孤兒資源。

## 掛 GCS bucket（靜態資源 / 公開下載檔）

規則目標改用 `--bucket`，就能把網域（或其中一段路徑）指到**公開 GCS bucket**，並自動開啟 Cloud CDN：

```bash
# bucket 需可公開讀取，建議用 ../gcs/gcs.sh 建立
../gcs/gcs.sh create --public                                # 建立 <專案ID>-public

./lb.sh add_domain files.example.com
./lb.sh add_rule files.example.com / --bucket my-proj-public          # 整個網域給 bucket
# 或混搭：同網域下服務 + bucket
./lb.sh add_rule app.example.com '/static/*' --bucket my-proj-public  # 靜態資源走 CDN
```

檔案網址即 `https://files.example.com/<物件路徑>`。注意：

- LB 是匿名對外服務，bucket **必須開放公開讀取**才拿得到檔案；掛上封鎖公開存取的 bucket 會收到警告，瀏覽器會拿到 403。**私人檔案（使用者上傳）不應掛 domain**，請維持私有 bucket + presigned URL（見 `../gcs/README.md`）。
- 移除規則時自動建立的 backend bucket 會一併清除，**GCS bucket 與檔案本身不受影響**。

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
./lb.sh init                        建立基礎設施：靜態 IP、HTTP→HTTPS 轉址（每組 LB 一次）
./lb.sh add_domain <網域>           掛上網域（建立憑證，DNS 生效後自動簽發）
./lb.sh add_rule <網域> <路徑> <服務>
./lb.sh add_rule <網域> <路徑> --bucket <bucket>
                                    設定該網域下路徑對應的目標：Cloud Run 服務，
                                    或公開 GCS bucket（自動建 backend bucket + CDN）
                                    路徑 '/' 為該網域預設目標，需最先設定；同路徑重下即覆蓋
./lb.sh remove_rule <網域> <路徑>   移除規則
./lb.sh remove_domain <網域>        卸下網域（移除其規則與憑證）
./lb.sh list                        列出所有網域與規則
./lb.sh check                       逐項檢查元件與各網域憑證簽發狀態
./lb.sh ip                          輸出靜態 IP（設定 DNS A 記錄用）
./lb.sh lock <服務>                 限制服務只接受 LB 流量（關閉 run.app 直連）
./lb.sh unlock <服務>               恢復服務可直連
./lb.sh delete                      刪除整組 LB 元件（需輸入 LB 名稱確認；不動 Cloud Run 服務）
```

### 選項與環境變數

| 設定 | 說明 |
|---|---|
| `-p, --project <id>` | 指定 GCP 專案 ID（優先於環境變數與 gcloud config） |
| `-n, --name <名稱>` | LB 元件命名，預設 `web`；同專案建第二組 LB 時使用，且之後每次執行都需帶同樣的值 |
| `--region <區域>` | Cloud Run 服務所在區域，預設 `asia-east1` |
| `--bucket <bucket>` | `add_rule` 的目標改為 GCS bucket（bucket 需可公開讀取） |
| `LB_PROJECT_ID` / `LB_NAME` / `LB_REGION` | 上述設定的環境變數版本 |

## 常見問題

- **憑證一直停在 `PROVISIONING`**：幾乎都是 DNS 還沒生效或 A 記錄指錯 IP，用 `./lb.sh ip` 核對；DNS 正確後最長可能等上一小時。
- **`www.example.com` 和 `example.com` 都要**：各 `add_domain` 一次、各設規則即可（兩張憑證、同一個 IP）。
- **路徑規則的寫法**：`/api/*` 匹配 `/api/` 底下所有路徑；精確路徑如 `/health` 也可以。`/` 不是 path rule，代表該網域的預設服務（其他規則都沒中時的去向）。
- **backend 想拿到真實來源 IP**：LB 會帶 `X-Forwarded-For`，取第一個值即可。
- **需要 CDN**：bucket 規則（`--bucket`）預設就開 CDN；Cloud Run 服務的 backend 可事後開啟 `gcloud compute backend-services update bs-<服務> --global --enable-cdn`。
- **費用**：forwarding rule 約 $0.025/小時（前 5 條合計），加上流量處理費；靜態 IP 掛在 LB 上不另外收費；憑證與規則數量不影響費用。
