# VPC 私有服務連線設定（Private Services Access）

用 `network.sh` 打通 VPC 與 Google 管理服務之間的私有連線，讓 Cloud SQL 等服務能取得 VPC 內的私有 IP。這是「Cloud Run + Cloud SQL private IP（不開公網）」架構的一次性前置設定。

## 目錄內容

| 檔案 | 用途 |
|---|---|
| `network.sh` | 私有服務連線工具：保留 peering IP 範圍、建立 VPC peering、檢查狀態 |

## 什麼時候需要

只有走 **private IP 架構**才需要（`sql.sh --private create` 會檢查並要求先完成本設定）。如果 Cloud SQL 用公網 IP + unix socket / Auth Proxy 連線，完全可以跳過這個目錄。

VPC 本身**不用自己建**：新專案啟用 Compute Engine API 時會自動建立 `default` VPC（每個 region 都有現成 subnet）。除非組織政策停用了自動建立，才需要先手動建 VPC。

## 使用方式

```bash
./network.sh setup          # 對 default VPC 做設定（每個 VPC 只需一次）
./network.sh check          # 檢查是否就緒
./network.sh setup my-vpc   # 對其他 VPC 做設定
```

`setup` 依序完成（冪等，重跑會跳過已存在的）：

1. 啟用 `compute.googleapis.com`、`servicenetworking.googleapis.com`
2. 保留一段 VPC peering 用的 IP 範圍（`google-managed-services-<VPC名稱>`，預設 `/16`）
3. 建立與 Google 管理服務（`servicenetworking.googleapis.com`）的 VPC peering

### 選項與環境變數

| 設定 | 說明 |
|---|---|
| `-p, --project <id>` | 指定 GCP 專案 ID（優先於環境變數與 gcloud config） |
| `NET_PROJECT_ID` | 預設專案 ID |
| `NET_VPC` | 預設 VPC 名稱，預設 `default` |
| `NET_PREFIX_LENGTH` | 保留範圍的 prefix 長度，預設 `16` |

## 完成後的下一步

```bash
cd ../cloudsql
./sql.sh --private create                        # 建立純 private IP 的 Cloud SQL 實例
```

搭配 Cloud Run 時，部署 workflow 要加 VPC egress 設定：

```bash
cd ../cloudrun
./wif.sh --vpc default generate_github_workflow main
```

## 注意事項

- **保留範圍一次選對**：`NET_PREFIX_LENGTH` 決定的網段之後不易更改，且不能與 VPC 現有網段重疊；預設 `/16` 對一般專案足夠。
- **peering 剛建好時**，第一次建 Cloud SQL 實例偶爾會失敗，等 1-2 分鐘重試即可。
- 保留 IP 範圍與 peering 本身**不收費**，費用來自之後建立的 Cloud SQL 等資源。
- 實例轉為 private only 之後，本機和 GitHub Actions runner 都連不到資料庫（詳見 `../cloudsql/README.md` 的說明）。
