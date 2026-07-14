# Cloud SQL (PostgreSQL) 管理工具

用 `sql.sh` 快速建立實惠生產規格的 Cloud SQL PostgreSQL 實例，並管理資料庫與應用程式帳號。

## 目錄內容

| 檔案 | 用途 |
|---|---|
| `sql.sh` | Cloud SQL 管理工具：建立/刪除實例、建立資料庫、建立帳號並輸出連線資訊 |

## 前置需求

- gcloud CLI 已登入（建議直接用 [GCP Cloud Shell](https://shell.cloud.google.com/)）
- 一個已啟用計費的 GCP 專案
- ⚠️ Cloud SQL 實例是**持續計費**的資源，建立後即使閒置也會產生費用，用完記得 `delete`

## 快速開始

```bash
./sql.sh create                                  # 建立實例（約 3-5 分鐘）
./sql.sh create_database my_app_db               # 建立資料庫
./sql.sh create_user app_user my_app_db > .env   # 建立帳號，連線資訊直接存成 .env
```

產出的 `.env` 內容：

```
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=my_app_db
DB_USER=app_user
DB_PASSWORD=<自動產生的隨機密碼>
CLOUD_SQL_CONNECTION_NAME=<project>:<region>:<instance>
```

> ⚠️ `.env` 含明文密碼，請勿 commit 進版控。正式環境建議把連線資訊放進 GitHub Secrets（見下方 `generate_github_secrets`）或 GCP Secret Manager。

## 指令一覽

```
./sql.sh create [實例名稱]             建立實例（1 vCPU / 3.75GB RAM / 20GB SSD 自動擴容）
./sql.sh --private create [實例名稱]   建立純 private IP 實例（不開公網，見下方說明）
./sql.sh delete [實例名稱]             刪除實例及其中所有資料（需輸入實例名稱確認）
./sql.sh create_database <db名稱>      在實例中建立資料庫
./sql.sh create_user <帳號> [db名稱]   建立帳號並自動產生隨機密碼，輸出 .env 格式連線資訊
./sql.sh generate_github_secrets <owner/repo> [.env檔]
                                       把 .env 連線資訊轉成 gh secret set 命令（預設讀 ./.env）
```

`create` 與 `create_database` 皆為冪等操作，資源已存在時會跳過而不會報錯，可安心重跑。

### 選項與環境變數

| 設定 | 說明 |
|---|---|
| `-p, --project <id>` | 指定 GCP 專案 ID（優先於環境變數與 gcloud config） |
| `-i, --instance <名稱>` | 指定實例名稱 |
| `--private` | `create` 時建立純 private IP 實例（不配公網 IP） |
| `--network <VPC名稱>` | `--private` 模式使用的 VPC |
| `SQL_PROJECT_ID` | 預設專案 ID |
| `SQL_INSTANCE` | 預設實例名稱，預設 `prod-pg-lite` |
| `SQL_REGION` | 區域，預設 `asia-east1` |
| `SQL_DB_VERSION` | 資料庫版本，預設 `POSTGRES_15` |
| `SQL_NETWORK` | `--private` 模式的預設 VPC，預設 `default` |

## 連線方式

`.env` 中的 `DB_HOST=127.0.0.1` 是配合 [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/postgres/sql-proxy) 的本機開發設定：

```bash
cloud-sql-proxy <CLOUD_SQL_CONNECTION_NAME>
# proxy 會在本機 127.0.0.1:5432 開出連線，應用程式直接讀 .env 即可
```

部署在 **Cloud Run** 上的服務則建議掛上實例並走 unix socket：

```bash
gcloud run services update <service> --region asia-east1 \
    --add-cloudsql-instances <CLOUD_SQL_CONNECTION_NAME>
# 連線位址改用 /cloudsql/<CLOUD_SQL_CONNECTION_NAME>
```

## 把連線資訊放進 GitHub Secrets

搭配本 repo 的 `gcp/cloudrun/wif.sh` 部署流程時，最簡單的機密管理方式是把整組連線資訊放進目標 repo 的 GitHub Actions Secrets：

```bash
./sql.sh create_user app_user my_app_db > .env
./sql.sh generate_github_secrets <owner>/<repo>      # 讀取 ./.env，輸出 gh 命令
```

輸出是一串現成的 `gh secret set` 命令，複製到**已登入 GitHub CLI 的機器**（`gh auth login`）執行即可。之後 deploy workflow 的 `env_vars` 直接引用：

```yaml
        env_vars: |
          DB_HOST=${{ secrets.DB_HOST }}
          DB_PORT=${{ secrets.DB_PORT }}
          DB_NAME=${{ secrets.DB_NAME }}
          DB_USER=${{ secrets.DB_USER }}
          DB_PASSWORD=${{ secrets.DB_PASSWORD }}
```

（`wif.sh generate_github_workflow` 產生的 deploy.yaml 已內建這段註解範例，打開即可。）

> 取捨：這條路線的機密最終會成為 Cloud Run 的**環境變數**，能查看服務設定的人看得到。需要版本管理、存取稽核或更嚴格隔離時，把 `DB_PASSWORD` 放 GCP Secret Manager（`gcloud secrets create` + 授權執行身分 `roles/secretmanager.secretAccessor`），deploy workflow 改用 `secrets:` 參數掛載。

## Private IP 模式（不開公網）

資料庫完全不暴露公網的架構，完整流程：

```bash
# 1. 一次性網路設定（每個 VPC 一次，詳見 ../network/README.md）
../network/network.sh setup

# 2. 建立純 private IP 實例（會先檢查網路是否就緒）
./sql.sh --private create
./sql.sh create_database my_app_db
./sql.sh create_user app_user my_app_db > .env   # DB_HOST 會自動輸出私有 IP（10.x.x.x）

# 3. Cloud Run 部署 workflow 加上 VPC egress，服務才連得到私有網段
../cloudrun/wif.sh --vpc default generate_github_workflow main
```

`create_user` 會自動偵測實例有無私有 IP：有就輸出 `DB_HOST=10.x.x.x`（Cloud Run 直連），沒有才輸出 `DB_HOST=127.0.0.1`（本機 Auth Proxy）。

**代價**：實例沒有公網 IP 後，本機的 `cloud-sql-proxy` 和 GitHub Actions runner 都連不到資料庫。臨時查詢可用 GCP console 的 Cloud SQL Studio；本機開發或 CI 跑 migration 需要跳板 VM（IAP tunnel）或改成 Cloud Run job 執行。另建議對純 TCP 連線強制加密：`gcloud sql instances patch <實例> --ssl-mode=ENCRYPTED_ONLY`。

## 常見問題

- **刪掉的實例名稱不能馬上重用**：GCP 限制同名實例約一週內無法重新建立，急用請換名稱。
- **忘記密碼 / 想重設密碼**：`gcloud sql users set-password <帳號> --instance=<實例> --prompt-for-password`。
- **想調整實例規格**：規格（CPU / RAM / 磁碟）寫在 `sql.sh` 的 `cmd_create` 內，依需求修改 `--cpu`、`--memory`、`--storage-size` 參數；已建立的實例可用 `gcloud sql instances patch` 調整。
- **同專案建第二個實例**：`./sql.sh create staging-pg`，之後操作都帶 `-i staging-pg` 即可。
