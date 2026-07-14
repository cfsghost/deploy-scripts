# GCP 部署工具集

一組互相搭配的指令工具，讓你在 GCP Cloud Shell 裡用幾條指令，從一個全新的專案完整啟動一個服務：**GitHub push 自動部署到 Cloud Run，資料庫走 Cloud SQL private IP（不開公網）**。

## 目錄

| 目錄 | 工具 | 負責範圍 |
|---|---|---|
| `network/` | `network.sh` | VPC 私有服務連線（Cloud SQL private IP 的前置設定） |
| `cloudsql/` | `sql.sh` | Cloud SQL PostgreSQL 實例、資料庫、帳號 |
| `cloudrun/` | `wif.sh` | WIF 免金鑰部署授權、GitHub Actions workflow 產生 |

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

### 階段 3：機密與執行權限（每個專案一次）

把資料庫密碼放進 Secret Manager，並授權給 Cloud Run 的執行身分（預設是 compute SA）：

```bash
# 從 .env 取出密碼建立 secret
grep '^DB_PASSWORD=' .env | cut -d= -f2- | tr -d '\n' | \
    gcloud secrets create db-password --data-file=-

# 授權執行身分讀取（<PROJECT_NUMBER> 可用 gcloud projects describe <PROJECT_ID> 查）
gcloud secrets add-iam-policy-binding db-password \
    --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
```

### 階段 4：部署授權（每個專案一次 + 每個 repo 一次）

```bash
cd ../cloudrun
./wif.sh init                       # AR 倉庫、部署 SA、WIF 信任鏈（每個專案一次）
./wif.sh add <owner>/<repo>         # 授權 GitHub repo（每個 repo 一次）
```

### 階段 5：產生 workflow 並上線（每個 repo 一次）

```bash
./wif.sh --vpc default generate_github_workflow main   # 或 tag（推 v* tag 才部署）
```

打開產生的 `deploy.yaml`，把註解掉的 `env_vars` / `secrets` 區塊打開填上：

```yaml
        env_vars: |
          DB_HOST=10.x.x.x        # 階段 2 .env 裡的私有 IP
          DB_PORT=5432
          DB_NAME=my_app_db
          DB_USER=app_user
        secrets: |
          DB_PASSWORD=db-password:latest
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

## 精簡流程（不需要資料庫）

只要 Cloud Run 的話，跳過階段 1-3：

```bash
cd gcp/cloudrun
./wif.sh init
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

- Cloud SQL 實例是**持續計費**資源，測試完記得 `./sql.sh delete`
- private IP 模式下，本機與 CI 連不到資料庫（migration 建議做成 Cloud Run job），詳見 `cloudsql/README.md`
- `.env` 含明文密碼，不要 commit；密碼已進 Secret Manager 後，本機的 `.env` 用完即可刪
