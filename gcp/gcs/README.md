# Cloud Storage（應用程式上傳檔案的物件儲存）

用 `gcs.sh` 建立給後端服務存放上傳檔案的 GCS bucket。預設 bucket 強制封鎖公開存取，檔案一律由應用程式（或其簽發的 presigned URL）取用；後端可用原生 GCS SDK 免金鑰存取，也可產生 HMAC 金鑰走 **S3 相容 API**（AWS S3 SDK、MinIO client 直接可用）。另可用 `create --public` 建立**公開讀取**的 bucket，放靜態資源與公開下載檔，並搭配 `../lb/lb.sh` 掛自訂網域 + CDN。

## 目錄內容

| 檔案 | 用途 |
|---|---|
| `gcs.sh` | GCS 管理工具：建立 bucket、授權 Cloud Run 服務、產生 S3 相容金鑰、設定 CORS、刪除 |

## 前置需求

- gcloud CLI 已登入（建議直接用 [GCP Cloud Shell](https://shell.cloud.google.com/)）
- `grant` / `create_hmac` 以服務名稱指定目標時，該 Cloud Run 服務需**已完成第一次部署**（可搭配 `../cloudrun/wif.sh` 的流程）；服務還沒部署的話，可改給 **SA email** 直接授權執行身分（見常見問題）

## 快速開始

```bash
./gcs.sh create my-app-uploads              # 建立 bucket（名稱全球唯一，建議加專案前綴）
./gcs.sh grant my-backend my-app-uploads    # 授權後端服務的執行身分讀寫
```

到這裡，後端用**原生 GCS SDK** 就能存取了——Cloud Run 上的 Application Default Credentials 會自動生效，不需要任何金鑰，程式裡只要知道 bucket 名稱。

> **服務還沒部署？** 把服務名稱換成執行身分的 **SA email**（帶 `@` 就會被視為 SA），部署前就能先開好權限；`create_hmac` 同理。未自訂執行身分的服務用專案預設 compute SA：
>
> ```bash
> ./gcs.sh grant <專案編號>-compute@developer.gserviceaccount.com my-app-uploads
> # <專案編號>查法: gcloud projects describe <專案ID> --format="value(projectNumber)"
> ```
>
> 或者什麼都不用做，等第一次部署完成後再 `grant`，服務不需重新部署即生效。詳見常見問題。

### 後端用 AWS S3 SDK / MinIO client 的話

再多一步，產生 S3 相容的 HMAC 金鑰：

```bash
./gcs.sh create_hmac my-backend my-app-uploads > .env.storage
```

輸出的 `.env.storage`：

```
S3_ENDPOINT=https://storage.googleapis.com
S3_REGION=auto
S3_BUCKET=<bucket名稱>
S3_ACCESS_KEY_ID=GOOG1E...
S3_SECRET_ACCESS_KEY=<secret，只顯示這一次>
```

S3 SDK 以 path-style 指向 `S3_ENDPOINT` 即可使用。搭配本 repo 的部署流程時，直接轉進 GitHub Secrets：

```bash
./gcs.sh generate_github_secrets <owner>/<repo>      # 預設讀取 ./.env.storage
# 輸出的 gh 命令在已登入 gh CLI 的機器上執行，
# 之後 deploy.yaml 的 env_vars 就能引用 ${{ secrets.S3_BUCKET }} 等，
# 左邊寫成應用程式實際讀的變數名，例如 MY_APP_S3_BUCKET=${{ secrets.S3_BUCKET }}
```

> ⚠️ `.env.storage` 含明文金鑰，不要 commit；進 GitHub Secrets 後即可刪除。

### 瀏覽器直傳（選用）

前端要拿後端簽發的 presigned URL 直接上傳到 bucket 時，需開 CORS：

```bash
./gcs.sh cors https://app.example.com my-app-uploads    # 多個來源用逗號分隔
```

## 公開檔案（雙 bucket 架構）

「使用者上傳的私人檔案」和「任何人都能看的公開檔案」**不要混在同一個 bucket**——uniform 權限下公開授權是整桶生效，沒有折衷。建議一桶私有、一桶公開：

| | 私有 bucket（`create`） | 公開 bucket（`create --public`） |
|---|---|---|
| 命名建議 | `<專案前綴>-uploads` | `<專案前綴>-public` |
| 放什麼 | 使用者上傳、隱私內容 | 網站靜態資源、公開下載檔 |
| 對外取用 | 後端簽發 presigned URL | 直接以 URL 存取（可掛網域 + CDN） |

```bash
./gcs.sh create --public my-app-public       # 建立公開 bucket（會顯示整桶公開的警告）
./gcs.sh grant my-backend my-app-public      # 後端也要寫這桶的話
```

檔案直接用 `https://storage.googleapis.com/<bucket>/<路徑>` 存取。想用自己的網域並走 CDN：

```bash
cd ../lb
./lb.sh add_domain files.example.com
./lb.sh add_rule files.example.com / --bucket my-app-public
# 或掛在既有網域的一段路徑下：
./lb.sh add_rule app.example.com '/static/*' --bucket my-app-public
```

詳見 `../lb/README.md` 的「掛 GCS bucket」一節。

## 指令一覽

```
./gcs.sh create <bucket名稱>            建立 bucket（uniform 權限、強制封鎖公開存取）
./gcs.sh create --public <bucket名稱>   建立【公開讀取】的 bucket
./gcs.sh grant <Cloud Run服務|SA email> <bucket>
                                       授權服務的執行身分讀寫 bucket
                                       （帶 '@' 視為 SA email，服務部署前可先授權）
./gcs.sh create_hmac <Cloud Run服務|SA email> <bucket>
                                       產生 S3 相容 HMAC 金鑰，輸出 .env 格式連線資訊
./gcs.sh cors <來源> <bucket>           設定 CORS（瀏覽器直傳用）
./gcs.sh generate_github_secrets <owner/repo> [env檔]
                                       把 .env.storage 轉成 gh secret set 命令
./gcs.sh list                          列出專案內的 buckets
./gcs.sh delete <bucket名稱>            刪除 bucket 及其中所有檔案（需輸入名稱確認）
```

### 選項與環境變數

| 設定 | 說明 |
|---|---|
| `-p, --project <id>` | 指定 GCP 專案 ID（優先於環境變數與 gcloud config） |
| `-b, --bucket <名稱>` | 指定 bucket 名稱（等同各指令的 bucket 位置參數） |
| `--public` | `create` 專用：bucket 開放公開讀取（allUsers 可讀整桶） |
| `--region <區域>` | bucket 與 Cloud Run 服務所在區域，預設 `asia-east1` |
| `GCS_PROJECT_ID` / `GCS_BUCKET` / `GCS_REGION` | 上述設定的環境變數版本 |

## 常見問題

- **服務還沒部署，怎麼先 grant？**：`grant` 授權的其實是服務的**執行身分 SA**，不是服務本身，所以把服務名稱換成 SA email（帶 `@` 就會被視為 SA）即可在部署前先開好權限。走本 repo `wif.sh` 流程部署的服務沒有自訂執行身分，用的是專案預設 compute SA：`<專案編號>-compute@developer.gserviceaccount.com`（專案編號用 `gcloud projects describe <專案ID> --format="value(projectNumber)"` 查得）。`create_hmac` 同理——HMAC 金鑰掛在 SA 上，服務部署前就能先產。也可以什麼都不做，等第一次部署完成後再照一般流程 `grant <服務> <bucket>`，服務不需要重新部署即生效。
- **bucket 名稱被占用**：bucket 名稱是**全球唯一**的（跟所有 GCP 用戶共用命名空間），短名稱很容易撞名；建議加上專案相關前綴（如 `<專案ID>-uploads`），撞名時換一個即可。
- **檔案要讓使用者下載**：私有 bucket 封鎖了公開存取，請由後端簽發 presigned URL（GCS 原生叫 signed URL，S3 SDK 的 presign 也相容），或經後端轉發。這是刻意的設計——上傳內容不應該整桶公開；真正的公開檔案請放 `create --public` 建立的公開 bucket。
- **HMAC 金鑰洩漏了**：`gcloud storage hmac list` 找出 access ID，`gcloud storage hmac update <access-id> --deactivate` 停用後 `gcloud storage hmac delete <access-id>` 刪除，再重新 `create_hmac`。每個執行身分最多 10 把金鑰。
- **費用**：Standard 儲存約 $0.02/GB/月（asia-east1），加上少量操作與流量費；沒有固定月費，不用時只付已存檔案的錢。誤刪保護（soft delete）預設保留 7 天，會對已刪除資料多收保留期間的儲存費，想關閉可用 `gcloud storage buckets update gs://<bucket> --soft-delete-duration=0`。
- **跟 LB / CDN 搭配**：公開 bucket 可直接用 `../lb/lb.sh add_rule <網域> <路徑> --bucket <bucket>` 掛自訂網域並自動開 CDN（見上方「公開檔案」一節）；私有 bucket（使用者上傳）維持 presigned URL，不要掛 domain。
