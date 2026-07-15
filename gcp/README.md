# GCP 部署工具集

一組互相搭配的指令工具，讓你在 GCP Cloud Shell 裡用幾條指令，從一個全新的專案完整啟動一個服務：**GitHub push 自動部署到 Cloud Run，資料庫走 Cloud SQL private IP（不開公網）**。

## 目錄

| 目錄 | 工具 | 負責範圍 |
|---|---|---|
| `network/` | `network.sh` | VPC 私有服務連線（Cloud SQL private IP 的前置設定） |
| `cloudsql/` | `sql.sh` | Cloud SQL PostgreSQL 實例、資料庫、帳號 |
| `cloudrun/` | `wif.sh` | WIF 免金鑰部署授權、GitHub Actions workflow 產生 |
| `lb/` | `lb.sh` | 自訂網域 HTTPS LB，按路徑分流到前後端 Cloud Run 服務 |
| `gcs/` | `gcs.sh` | 上傳檔案的物件儲存（GCS bucket，支援 S3 相容 API） |

各工具的完整說明見各目錄的 README；本文描述如何把它們串起來。

## 前置需求

- 已啟用計費的 GCP 專案，操作帳號具備管理權限（工具會自動預檢，不足會擋下並列出缺少的權限）
- 在 [Cloud Shell](https://shell.cloud.google.com/) 操作（gcloud 已登入、專案已設定）並 clone 本 repo
- 目標 GitHub repo 根目錄有 `Dockerfile`

## 完整部署流程（Cloud Run + Cloud SQL private IP）

### 階段 1：網路（每個 VPC 一次）

```bash
cd gcp/network
./network.sh setup      # 保留 peering IP 範圍 + 建立 VPC peering
```

VPC 不用自己建，新專案自帶 `default` VPC。

### 階段 2：資料庫（每個專案一次）

```bash
cd ../cloudsql
./sql.sh --private create                        # 純 private IP 實例（約 3-5 分鐘）
./sql.sh create_database my_app_db
./sql.sh create_user app_user my_app_db > .env   # DB_HOST 會是私有 IP（10.x.x.x）
```

### 階段 3：連線資訊放進 GitHub Secrets（每個 repo 一次）

把階段 2 的 `.env` 轉成一串 `gh secret set` 命令：

```bash
./sql.sh generate_github_secrets <owner>/<repo>      # 預設讀取 ./.env
```

把輸出的命令複製到**已登入 GitHub CLI 的機器**上執行（`gh auth login`），`DB_HOST`、`DB_USER`、`DB_PASSWORD` 等就會全部進到該 repo 的 Actions Secrets，之後 workflow 直接用 `${{ secrets.DB_HOST }}` 引用。

> **替代方案（GCP Secret Manager）**：需要版本管理、存取稽核，或不希望密碼以環境變數形式出現在 Cloud Run 服務設定裡時，可改把密碼放 Secret Manager（`gcloud secrets create` + 授權執行身分 `roles/secretmanager.secretAccessor`），workflow 改用 `secrets:` 參數掛載，詳見 `cloudsql/README.md`。

### 階段 4：部署授權（每個專案一次 + 每個 repo 一次）

```bash
cd ../cloudrun
./wif.sh init <owner>               # AR 倉庫、部署 SA、WIF 信任鏈（每個專案一次）
                                    # <owner> 是你的 GitHub 帳號/組織，provider 只信任它底下的 repo
./wif.sh add <owner>/<repo>         # 授權 GitHub repo（每個 repo 一次）
```

### 階段 5：產生 workflow 並上線（每個 repo 一次）

```bash
./wif.sh --vpc default generate_github_workflow main   # 或 tag（推 v* tag 才部署）
```

打開產生的 `deploy.yaml`，把註解掉的 `env_vars` 區塊打開——值直接引用階段 3 設定好的 GitHub Secrets，不用手填：

```yaml
        env_vars: |
          DB_HOST=${{ secrets.DB_HOST }}
          DB_PORT=${{ secrets.DB_PORT }}
          DB_NAME=${{ secrets.DB_NAME }}
          DB_USER=${{ secrets.DB_USER }}
          DB_PASSWORD=${{ secrets.DB_PASSWORD }}
```

放進目標 repo 後推上去：

```bash
mv deploy.yaml <你的repo>/.github/workflows/
cd <你的repo>
git add .github/workflows/deploy.yaml
git commit -m "Add Cloud Run deploy workflow"
git push origin main          # 觸發第一次部署
```

### 驗證

部署進度看 GitHub repo 的 **Actions** 頁籤，完成後：

```bash
gcloud run services list --region asia-east1    # 取得服務網址
```

### 階段 6（選用）：自訂網域與前後端分流

想用自己的網域對外、並把前後端分流到不同 Cloud Run 服務時，用 LB 掛網域、設規則：

```bash
cd ../lb
./lb.sh init                                          # 靜態 IP + HTTP→HTTPS 轉址（一次）
./lb.sh add_domain app.example.com                    # 掛網域（憑證）
./lb.sh add_rule app.example.com / my-frontend        # 網域預設服務
./lb.sh add_rule app.example.com '/api/*' my-backend  # API 路徑分流
# 照輸出指示設定 DNS A 記錄，憑證簽發進度用 ./lb.sh check 追蹤
./lb.sh lock my-frontend && ./lb.sh lock my-backend   # 建議：關閉 run.app 直連
```

可掛多個網域（共用同一個 IP），每個網域各自設定規則，詳見 `lb/README.md`。

### 階段 7（選用）：上傳檔案的物件儲存

後端需要存放使用者上傳的檔案時，建一個私有 bucket 給服務用：

```bash
cd ../gcs
./gcs.sh create my-app-uploads                            # 建立 bucket（封鎖公開存取）
./gcs.sh grant my-backend my-app-uploads                  # 原生 GCS SDK 走 ADC，免金鑰
./gcs.sh create_hmac my-backend my-app-uploads > .env.storage   # 後端用 AWS S3 SDK 時才需要
./gcs.sh generate_github_secrets <owner>/<repo>           # 轉進 GitHub Secrets
```

> **服務還沒部署？** `grant` / `create_hmac` 用服務名稱時需要該服務已完成第一次部署（階段 5）。想在部署前就把權限與金鑰準備好——例如讓首次部署就帶到 storage 環境變數——把服務名稱換成執行身分的 **SA email** 即可。走本流程部署的服務用的是專案預設 compute SA：
>
> ```bash
> PN=$(gcloud projects describe <專案ID> --format="value(projectNumber)")
> ./gcs.sh grant "${PN}-compute@developer.gserviceaccount.com" my-app-uploads
> ./gcs.sh create_hmac "${PN}-compute@developer.gserviceaccount.com" my-app-uploads > .env.storage
> ```

另有**公開檔案**（靜態資源、公開下載檔）要放時，另建一個公開 bucket，不要與私人上傳混桶；可搭配階段 6 的 LB 掛自訂網域 + CDN：

```bash
./gcs.sh create --public my-app-public                    # 建立公開 bucket（整桶公開讀取）
cd ../lb
./lb.sh add_domain files.example.com
./lb.sh add_rule files.example.com / --bucket my-app-public
```

詳見 `gcs/README.md`（雙 bucket 架構）與 `lb/README.md`（掛 GCS bucket）。

## 精簡流程（不需要資料庫）

只要 Cloud Run 的話，跳過階段 1-3：

```bash
cd gcp/cloudrun
./wif.sh init <owner>
./wif.sh add <owner>/<repo>
./wif.sh generate_github_workflow main
# deploy.yaml 放進 repo 的 .github/workflows/，push 即部署
```

資料庫想走公網 IP + Auth Proxy / unix socket 的簡單路線，也可以用 `./sql.sh create`（不加 `--private`）並跳過階段 1，連線方式見 `cloudsql/README.md`。

## 之後的日常

一次設定完成後，日常只剩一件事：**push（或推 tag）就自動部署**。

- 同專案加第二個 repo/服務：`./wif.sh add` + `generate_github_workflow` 各跑一次即可，網路、資料庫實例、AR、SA 全部共用
- 新資料庫/帳號：`./sql.sh create_database`、`./sql.sh create_user`
- 檢查環境狀態：`./network.sh check`、`./wif.sh check`

## 注意事項

- Cloud SQL 實例與 LB 的 forwarding rule 都是**持續計費**資源，測試完記得 `./sql.sh delete` / `./lb.sh delete`
- private IP 模式下，本機與 CI 連不到資料庫（migration 建議做成 Cloud Run job），詳見 `cloudsql/README.md`
- `.env` 與 `generate_github_secrets` 的輸出都含明文密碼，不要 commit；連線資訊進 GitHub Secrets 後即可刪除
- GitHub Secrets 路線的機密最終會成為 Cloud Run 的**環境變數**（能查看服務設定的人看得到）；需要更嚴格的隔離與稽核時改用 Secret Manager（見階段 3 的替代方案）
