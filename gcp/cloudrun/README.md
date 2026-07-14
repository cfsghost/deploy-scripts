# Cloud Run 自動部署（GitHub Actions + Workload Identity Federation）

透過 GitHub Actions 將容器化應用自動部署到 GCP Cloud Run。使用 Workload Identity Federation（WIF）以 OIDC 建立信任，**不需要下載或保存任何 Service Account 金鑰**。

## 目錄內容

| 檔案 | 用途 |
|---|---|
| `wif.sh` | WIF 管理工具：初始化 GCP 環境、授權/移除 GitHub repo、檢查環境狀態、產生 GitHub Actions workflow |

## 前置需求

- 一個已啟用計費的 GCP 專案
- 執行 `wif.sh` 的帳號需具備足夠權限（`roles/owner`，或 API / Artifact Registry / SA / WIF / IAM 的管理角色）——`wif.sh` 會在執行前自動預檢，權限不足會擋下並列出缺少的項目
- 目標 GitHub repo 的**根目錄要有 `Dockerfile`**（workflow 用 `docker build .` 建置）

建議直接在 [GCP Cloud Shell](https://shell.cloud.google.com/) 操作，gcloud 已登入且專案已設定好。

## 從零到完成一個 repo 的部署

### Step 1：初始化 GCP 環境（每個 GCP 專案只需一次）

在 Cloud Shell 取得本目錄的 `wif.sh`（git clone 本 repo 或直接上傳檔案），然後執行：

```bash
./wif.sh init
```

專案 ID 預設取自 gcloud 目前設定的專案；要指定其他專案時加 `-p`：

```bash
./wif.sh -p my-gcp-project init
```

`init` 會依序完成（冪等，重跑不會出錯）：

1. 權限預檢（不足直接擋下並列出缺少的權限與對應角色）
2. 啟用 Cloud Run、Artifact Registry、IAM 等必要 API
3. 建立 Artifact Registry Docker 倉庫（`repo-go-run`）
4. 建立部署用 Service Account（`sa-go-run@...`）並綁定 `artifactregistry.writer`、`run.admin`、`iam.serviceAccountUser`
5. 建立 WIF Pool 與 GitHub OIDC Provider

### Step 2：授權 GitHub repo（每個 repo 一次）

```bash
./wif.sh add <owner>/<repo>
# 例如
./wif.sh add fred/go-api
```

完成後會直接輸出一段 `env:` 區塊，**複製起來**，下一步會用到。之後隨時可用 `./wif.sh env` 重新輸出。

### Step 3：產生 GitHub Actions workflow

```bash
./wif.sh generate_github_workflow main   # push 到 main 分支時觸發部署，image 以 commit SHA 為版本
# 或
./wif.sh generate_github_workflow tag    # 推送 v 開頭的 tag（如 v1.0.0）時觸發部署，image 以 tag 為版本
```

會在目前目錄產生一份 env 已填好的 `deploy.yaml`（可加第二個參數指定輸出路徑），放到目標 repo 的 `.github/workflows/deploy.yaml` 即可，不需要再手動編輯。

`SERVICE_NAME` 不用設定——workflow 會自動取 GitHub repo 名稱（轉小寫、底線和點轉連字號）作為 Cloud Run 服務名稱。

### Step 4：推送觸發部署

```bash
git add .github/workflows/deploy.yaml
git commit -m "Add Cloud Run deploy workflow"
git push origin main            # main 模式：push 即觸發

git tag v1.0.0                  # tag 模式：推送 tag 才觸發
git push origin v1.0.0
```

部署進度可在 GitHub repo 的 **Actions** 頁籤查看。成功後查詢服務網址：

```bash
gcloud run services list --region asia-east1
```

## wif.sh 指令一覽

```
./wif.sh init                初始化 GCP 環境（每個專案一次）
./wif.sh check               逐項檢查環境與帳號權限是否就緒
./wif.sh list                列出目前已授權部署的 GitHub repos
./wif.sh add <owner/repo>    授權新的 GitHub repo
./wif.sh remove <owner/repo> 移除 GitHub repo 的授權
./wif.sh env                 重新輸出 deploy.yaml 所需的 env 區塊
./wif.sh generate_github_workflow <main|tag> [檔案]
                             產生已填好 env 的 GitHub Actions deploy.yaml（預設輸出到 ./deploy.yaml）
```

服務需要連 **private IP 的 Cloud SQL** 時，產生 workflow 時加 `--vpc`，部署設定會多出 VPC egress 相關 flags：

```bash
./wif.sh --vpc default generate_github_workflow main
```

（前置的網路與資料庫設定見 `../network/README.md` 與 `../cloudsql/README.md` 的 Private IP 模式。）

### 選項與環境變數

| 設定 | 說明 |
|---|---|
| `-p, --project <id>` | 指定 GCP 專案 ID（優先於環境變數與 gcloud config） |
| `WIF_PROJECT_ID` | 預設專案 ID |
| `WIF_REGION` | 部署區域，預設 `asia-east1` |
| `WIF_SUFFIX` | 元件命名後綴，預設 `go-run`；同一專案要建第二套獨立環境時使用，且之後每次執行都需帶同樣的值 |

## 常見問題

- **`init` 被權限預檢擋下**：把輸出列出的角色清單交給專案管理員授權，或請管理員代跑 `init`（之後的 `add`/`remove` 只需要能修改 Service Account IAM 的權限）。
- **部署失敗在 docker build**：確認 repo 根目錄有 `Dockerfile`。
- **同一個 GCP 專案部署多個 repo**：`init` 跑一次即可，每個 repo 各跑一次 `./wif.sh add`，共用同一組 Artifact Registry / SA / WIF。
- **repo 改名或搬家**：WIF 信任是綁 repo 完整路徑的，需 `./wif.sh remove` 舊路徑再 `./wif.sh add` 新路徑。
