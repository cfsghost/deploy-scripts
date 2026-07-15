#!/usr/bin/env bash

# gcs.sh - GCP Cloud Storage 管理工具（應用程式上傳檔案用的物件儲存）
#
# 用法:
#   ./gcs.sh create <bucket名稱>            建立 bucket（不開公開存取）
#   ./gcs.sh create --public <bucket名稱>   建立公開讀取的 bucket
#   ./gcs.sh grant <Cloud Run服務> <bucket> 授權服務的執行身分讀寫 bucket（原生 GCS SDK 免金鑰）
#   ./gcs.sh create_hmac <Cloud Run服務> <bucket>
#                                          產生 S3 相容 HMAC 金鑰，輸出 .env 格式連線資訊
#   ./gcs.sh cors <來源> <bucket>           設定 CORS（瀏覽器直傳 presigned URL 用）
#   ./gcs.sh generate_github_secrets <owner/repo> [env檔]
#                                          把 .env.storage 轉成 gh secret set 命令
#   ./gcs.sh list                          列出專案內的 buckets
#   ./gcs.sh delete <bucket名稱>            刪除 bucket 及其中所有檔案（需輸入名稱確認）

set -eo pipefail

# ==========================================
# 🔧 全域設定（可用環境變數覆寫）
# ==========================================
REGION="${GCS_REGION:-asia-east1}"     # 台灣彰化機房
BUCKET="${GCS_BUCKET:-}"               # 各指令以位置參數或 -b 指定，不提供預設名稱
PROJECT_ID="${GCS_PROJECT_ID:-}"
PUBLIC_MODE=""                         # create --public：建立公開讀取的 bucket

# ==========================================
# 🛠️ 共用函式
# ==========================================
usage() {
    cat << 'EOF'
用法: gcs.sh [選項] <指令>

指令:
  create <bucket名稱>            建立 bucket（uniform 權限、強制封鎖公開存取）
  create --public <bucket名稱>   建立【公開讀取】的 bucket（整桶任何人可讀！）
                                 放網站靜態資源、公開下載檔用
                                 可再用 ../lb/lb.sh add_rule 掛自訂網域 + CDN
  grant <Cloud Run服務> <bucket> 授權服務的執行身分讀寫 bucket
                                 （服務用原生 GCS SDK 時做到這步即可，免金鑰）
  create_hmac <Cloud Run服務> <bucket>
                                 為服務的執行身分產生 S3 相容 HMAC 金鑰，
                                 輸出 .env 格式（狀態訊息走 stderr，stdout 可直接存檔）
                                 服務用 AWS S3 SDK / MinIO client 時才需要
  cors <來源> <bucket>           設定 CORS，允許瀏覽器從指定來源直傳
                                 （多個來源用逗號分隔，例如 https://app.example.com）
  generate_github_secrets <owner/repo> [env檔]
                                 把 create_hmac 的輸出（預設 ./.env.storage）轉成
                                 一串 gh secret set 命令，放進 repo 的 Actions Secrets
  list                           列出專案內的 buckets
  delete <bucket名稱>            刪除 bucket 及其中所有檔案（需輸入名稱確認）

選項:
  -p, --project <id>   指定 GCP 專案 ID（預設: $GCS_PROJECT_ID 或 gcloud config 目前專案）
  -b, --bucket <名稱>  指定 bucket 名稱（等同各指令的 bucket 位置參數）
  --public             create 專用：bucket 開放公開讀取
  --region <區域>      bucket 所在區域（預設: asia-east1）
  -h, --help           顯示此說明

環境變數:
  GCS_PROJECT_ID   預設專案 ID
  GCS_BUCKET       預設 bucket 名稱
  GCS_REGION       區域（預設: asia-east1）

範例:
  ./gcs.sh create my-app-uploads
  ./gcs.sh grant my-backend my-app-uploads
  ./gcs.sh create_hmac my-backend my-app-uploads > .env.storage
  ./gcs.sh generate_github_secrets fred/go-api
  ./gcs.sh cors https://app.example.com my-app-uploads
  ./gcs.sh create --public my-app-assets   # 公開 bucket（靜態資源/公開下載）
EOF
}

die() { echo "❌ 錯誤: $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }
ok() { echo "✅ $*"; }

require_login() {
    if ! gcloud auth list --filter=status=ACTIVE --format="value(account)" | grep -q .; then
        die "gcloud 未登入，請先執行 'gcloud auth login'。"
    fi
}

resolve_project() {
    if [ -z "${PROJECT_ID}" ]; then
        PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
    fi
    if [ -z "${PROJECT_ID}" ] || [ "${PROJECT_ID}" = "(unset)" ]; then
        die "未指定專案 ID，請用 '-p <project-id>' 或先執行 'gcloud config set project'。"
    fi
}

resolve_bucket() {
    [ -n "${BUCKET}" ] || die "未指定 bucket 名稱，請以位置參數或 '-b <名稱>' 指定（bucket 名稱是全球唯一的，建議加上專案前綴，例如 ${PROJECT_ID}-uploads）。"
    echo "${BUCKET}" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || die "bucket 名稱格式錯誤: '${BUCKET}'（小寫字母、數字、-、_、.）"
}

require_bucket() {
    gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT_ID}" &>/dev/null \
        || die "找不到 bucket '${BUCKET}'，請先執行 './gcs.sh create ${BUCKET}'。"
}

# 取得 Cloud Run 服務的執行身分（未自訂時為專案預設 compute SA）
resolve_service_sa() {
    local svc="$1" sa
    sa=$(gcloud run services describe "${svc}" \
        --region="${REGION}" --project="${PROJECT_ID}" \
        --format="value(spec.template.spec.serviceAccountName)" 2>/dev/null) \
        || die "找不到 Cloud Run 服務 '${svc}'（區域: ${REGION}），服務需先完成第一次部署。"
    if [ -z "${sa}" ]; then
        local pn
        pn=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
        sa="${pn}-compute@developer.gserviceaccount.com"
    fi
    echo "${sa}"
}

# ==========================================
# 🚀 create - 建立 bucket
# ==========================================
cmd_create() {
    [ -n "${1:-}" ] && BUCKET="$1"
    require_login
    resolve_project
    resolve_bucket

    if [ -n "${PUBLIC_MODE}" ]; then
        echo "🚀 建立【公開】bucket '${BUCKET}'（專案: ${PROJECT_ID}，區域: ${REGION}）"
        echo "⚠️  uniform 權限下公開授權是整個 bucket 生效——任何人可讀桶內所有檔案，"
        echo "⚠️  只放靜態資源與公開下載檔；使用者上傳的私人檔案請放預設的私有 bucket。"
    else
        echo "🚀 建立 bucket '${BUCKET}'（專案: ${PROJECT_ID}，區域: ${REGION}）"
    fi

    if gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT_ID}" &>/dev/null; then
        info "bucket '${BUCKET}' 已存在，跳過建立步驟。"
    else
        if [ -n "${PUBLIC_MODE}" ]; then
            gcloud storage buckets create "gs://${BUCKET}" \
                --project="${PROJECT_ID}" \
                --location="${REGION}" \
                --default-storage-class=STANDARD \
                --uniform-bucket-level-access
        else
            # uniform 權限 + 強制封鎖公開存取：檔案一律走應用程式或簽名網址取用
            gcloud storage buckets create "gs://${BUCKET}" \
                --project="${PROJECT_ID}" \
                --location="${REGION}" \
                --default-storage-class=STANDARD \
                --uniform-bucket-level-access \
                --public-access-prevention
        fi
        ok "bucket '${BUCKET}' 建立完成！"
    fi

    if [ -n "${PUBLIC_MODE}" ]; then
        # 開放任何人讀取（冪等；重複執行只是重設同一條 binding）
        gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
            --project="${PROJECT_ID}" \
            --member="allUsers" \
            --role="roles/storage.objectViewer" >/dev/null
        ok "已開放公開讀取（allUsers → objectViewer）。"

        echo ""
        echo "接下來："
        echo "   檔案直接用 https://storage.googleapis.com/${BUCKET}/<路徑> 存取"
        echo "   ./gcs.sh grant <Cloud Run服務> ${BUCKET}    授權後端寫入這個 bucket"
        echo "   想掛自訂網域 + CDN："
        echo "   ../lb/lb.sh add_domain files.example.com"
        echo "   ../lb/lb.sh add_rule files.example.com / --bucket ${BUCKET}"
    else
        echo ""
        echo "接下來："
        echo "   ./gcs.sh grant <Cloud Run服務> ${BUCKET}        授權服務讀寫（原生 GCS SDK 免金鑰）"
        echo "   ./gcs.sh create_hmac <Cloud Run服務> ${BUCKET}  服務用 S3 SDK 時，產生相容金鑰"
        echo "   ./gcs.sh cors <來源> ${BUCKET}                  需要瀏覽器直傳時設定 CORS"
    fi
}

# ==========================================
# 🔑 grant - 授權 Cloud Run 服務讀寫 bucket
# ==========================================
cmd_grant() {
    local svc="$1"
    [ -n "${2:-}" ] && BUCKET="$2"
    require_login
    resolve_project
    resolve_bucket
    require_bucket

    local sa
    sa=$(resolve_service_sa "${svc}")
    echo "🔑 授權服務 '${svc}'（執行身分: ${sa}）讀寫 bucket '${BUCKET}'..."

    gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
        --project="${PROJECT_ID}" \
        --member="serviceAccount:${sa}" \
        --role="roles/storage.objectAdmin" >/dev/null

    ok "服務 '${svc}' 已可讀寫 bucket '${BUCKET}'。"
    info "服務內用原生 GCS SDK（Application Default Credentials）即可存取，不需要任何金鑰。"
    info "改用 AWS S3 SDK / MinIO client 的話，再執行 './gcs.sh create_hmac ${svc}' 產生金鑰。"
}

# ==========================================
# 🗝️ create_hmac - 產生 S3 相容 HMAC 金鑰
# ==========================================
cmd_create_hmac() {
    local svc="$1"
    [ -n "${2:-}" ] && BUCKET="$2"
    require_login
    resolve_project
    resolve_bucket
    require_bucket

    local sa key_info access_id secret
    sa=$(resolve_service_sa "${svc}")
    echo "⏳ 為服務 '${svc}' 的執行身分（${sa}）產生 HMAC 金鑰..." >&2

    key_info=$(gcloud storage hmac create "${sa}" \
        --project="${PROJECT_ID}" \
        --format="value(metadata.accessId,secret)")
    access_id=$(echo "${key_info}" | awk '{print $1}')
    secret=$(echo "${key_info}" | awk '{print $2}')
    [ -n "${access_id}" ] && [ -n "${secret}" ] || die "HMAC 金鑰建立失敗，請檢查上方 gcloud 輸出。"

    ok "HMAC 金鑰建立完成，S3 相容連線資訊如下（可用 '> .env.storage' 直接存檔）：" >&2
    {
        echo "⚠️  secret 只顯示這一次，遺失只能重新產生（gcloud storage hmac list / delete 管理舊金鑰）。"
        echo ""
        echo "接下來："
        echo "   ./gcs.sh generate_github_secrets <owner>/<repo>"
        echo "   即可把整組資訊放進 GitHub Secrets，供 deploy workflow 的 env_vars 引用。"
    } >&2

    cat << EOF
S3_ENDPOINT=https://storage.googleapis.com
S3_REGION=auto
S3_BUCKET=${BUCKET}
S3_ACCESS_KEY_ID=${access_id}
S3_SECRET_ACCESS_KEY=${secret}
EOF
}

# ==========================================
# 🌐 cors - 設定瀏覽器直傳的 CORS
# ==========================================
cmd_cors() {
    local origins="$1"
    [ -n "${2:-}" ] && BUCKET="$2"
    require_login
    resolve_project
    resolve_bucket
    require_bucket

    echo "🌐 設定 bucket '${BUCKET}' 的 CORS（允許來源: ${origins}）..."

    local cors_file origin_json
    origin_json=$(echo "${origins}" | awk -F',' '{
        for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? ", " : ""), $i
    }')
    cors_file=$(mktemp)
    cat > "${cors_file}" << EOF
[
  {
    "origin": [${origin_json}],
    "method": ["GET", "HEAD", "PUT", "POST", "DELETE"],
    "responseHeader": ["*"],
    "maxAgeSeconds": 3600
  }
]
EOF
    gcloud storage buckets update "gs://${BUCKET}" \
        --project="${PROJECT_ID}" \
        --cors-file="${cors_file}" >/dev/null
    rm -f "${cors_file}"

    ok "CORS 設定完成，瀏覽器可從上述來源直傳（搭配後端簽發的 presigned URL）。"
}

# ==========================================
# 🔐 generate_github_secrets - 把 .env.storage 轉成 gh secret set 命令
# ==========================================
cmd_generate_github_secrets() {
    local repo="$1"
    local env_file="${2:-.env.storage}"

    echo "${repo}" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
        || die "repo 格式錯誤，需為 <owner>/<repo>，例如: fred/go-api"
    if [ ! -f "${env_file}" ]; then
        die "找不到 '${env_file}'，請先執行 './gcs.sh create_hmac <服務> > .env.storage' 產生連線資訊。"
    fi

    # 狀態訊息走 stderr，stdout 可直接重新導向存成 script
    echo "⏳ 讀取 '${env_file}'，產生 gh secret set 命令..." >&2

    local count=0 line key value escaped
    echo "# 在已登入 GitHub CLI 的機器上執行（未登入請先跑: gh auth login）"
    echo "# 目標 repo: ${repo}"
    while IFS= read -r line; do
        # 跳過註解與空行
        case "${line}" in
            \#*|"") continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        echo "${key}" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || continue
        if [ -z "${value}" ]; then
            echo "⚠️  '${key}' 的值是空的，已跳過（請補齊 ${env_file} 後重新產生）。" >&2
            continue
        fi
        # 單引號包住值，值裡的單引號以 '\'' 逸出
        escaped=$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")
        printf "gh secret set %s --repo '%s' --body '%s'\n" "${key}" "${repo}" "${escaped}"
        count=$((count + 1))
    done < "${env_file}"

    [ "${count}" -gt 0 ] || die "'${env_file}' 裡沒有任何 KEY=VALUE 連線資訊。"

    ok "已產生 ${count} 條 gh 命令。" >&2
    {
        echo ""
        echo "接下來："
        echo "   1. 複製以上命令到已登入 gh CLI 的機器執行（或 '> set-secrets.sh' 存檔帶走）"
        echo "   2. deploy.yaml 的 env_vars 以 \${{ secrets.S3_BUCKET }} 等方式引用，"
        echo "      左邊寫成應用程式實際讀的變數名，例如:"
        echo "        MY_APP_S3_BUCKET=\${{ secrets.S3_BUCKET }}"
        echo "   ⚠️  以上命令含明文金鑰，執行完請刪除，不要 commit 進版控。"
    } >&2
}

# ==========================================
# 📋 list - 列出 buckets
# ==========================================
cmd_list() {
    require_login
    resolve_project
    echo "📋 專案 '${PROJECT_ID}' 的 buckets："
    gcloud storage buckets list --project="${PROJECT_ID}" \
        --format="table(name, location, storageClass, timeCreated.date('%Y-%m-%d'))"
}

# ==========================================
# 🗑️ delete - 刪除 bucket
# ==========================================
cmd_delete() {
    [ -n "${1:-}" ] && BUCKET="$1"
    require_login
    resolve_project
    resolve_bucket
    require_bucket

    echo "⚠️  即將刪除 bucket '${BUCKET}' 及其中【所有檔案】，此動作無法復原！"
    printf "確認刪除請輸入 bucket 名稱（%s）: " "${BUCKET}"
    read -r answer
    [ "${answer}" = "${BUCKET}" ] || die "輸入不符，已取消刪除。"

    gcloud storage rm --recursive "gs://${BUCKET}" --project="${PROJECT_ID}"
    ok "bucket '${BUCKET}' 已刪除。"
    info "若曾為服務產生 HMAC 金鑰且不再使用，可用 'gcloud storage hmac list' 檢查並刪除。"
}

# ==========================================
# 🎬 主程式
# ==========================================
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            PROJECT_ID="$2"
            shift 2
            ;;
        -b|--bucket)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            BUCKET="$2"
            shift 2
            ;;
        --region)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            REGION="$2"
            shift 2
            ;;
        --public)
            PUBLIC_MODE="1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            die "未知選項 '$1'"
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

COMMAND="${ARGS[0]:-}"
case "${COMMAND}" in
    create) cmd_create "${ARGS[1]:-}" ;;
    grant)
        [ -n "${ARGS[1]:-}" ] || die "請指定 Cloud Run 服務名稱，例如: ./gcs.sh grant my-backend my-app-uploads"
        cmd_grant "${ARGS[1]}" "${ARGS[2]:-}"
        ;;
    create_hmac)
        [ -n "${ARGS[1]:-}" ] || die "請指定 Cloud Run 服務名稱，例如: ./gcs.sh create_hmac my-backend my-app-uploads"
        cmd_create_hmac "${ARGS[1]}" "${ARGS[2]:-}"
        ;;
    cors)
        [ -n "${ARGS[1]:-}" ] || die "請指定允許的來源，例如: ./gcs.sh cors https://app.example.com my-app-uploads"
        cmd_cors "${ARGS[1]}" "${ARGS[2]:-}"
        ;;
    generate_github_secrets)
        [ -n "${ARGS[1]:-}" ] || die "請指定 GitHub repo，例如: ./gcs.sh generate_github_secrets fred/go-api"
        cmd_generate_github_secrets "${ARGS[1]}" "${ARGS[2]:-}"
        ;;
    list)   cmd_list ;;
    delete) cmd_delete "${ARGS[1]:-}" ;;
    help)   usage ;;
    "")
        usage >&2
        exit 1
        ;;
    *)
        usage >&2
        die "未知指令 '${COMMAND}'"
        ;;
esac
