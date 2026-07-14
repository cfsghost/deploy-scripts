#!/usr/bin/env bash

# sql.sh - GCP Cloud SQL (PostgreSQL) 管理工具
#
# 用法:
#   ./sql.sh create [實例名稱]            建立 Cloud SQL 實例（1 vCPU / 3.75GB / 20GB SSD 自動擴容）
#   ./sql.sh --private create [實例名稱]  建立純 private IP 實例（需先跑 gcp/network/network.sh setup）
#   ./sql.sh delete [實例名稱]            刪除 Cloud SQL 實例（需輸入實例名稱確認）
#   ./sql.sh create_database <db名稱>     在實例中建立資料庫
#   ./sql.sh create_user <帳號> [db名稱]  建立帳號並自動產生密碼，輸出 .env 格式連線資訊
#   ./sql.sh generate_github_secrets <owner/repo> [.env檔]
#                                         把 .env 連線資訊轉成 gh secret set 命令（GitHub Secrets）

set -eo pipefail

# ==========================================
# 🔧 全域設定（可用環境變數覆寫）
# ==========================================
REGION="${SQL_REGION:-asia-east1}"              # 台灣彰化機房
DB_VERSION="${SQL_DB_VERSION:-POSTGRES_18}"
INSTANCE_NAME="${SQL_INSTANCE:-prod-pg-lite}"
NETWORK="${SQL_NETWORK:-default}"               # --private 模式使用的 VPC
PROJECT_ID="${SQL_PROJECT_ID:-}"
PRIVATE_MODE=0

# ==========================================
# 🛠️ 共用函式
# ==========================================
usage() {
    cat << 'EOF'
用法: sql.sh [選項] <指令>

指令:
  create [實例名稱]             建立 Cloud SQL PostgreSQL 實例
                                （1 vCPU / 3.75GB RAM / 20GB SSD 自動擴容）
  delete [實例名稱]             刪除實例及其中所有資料（需輸入實例名稱確認）
  create_database <db名稱>      在實例中建立資料庫
  create_user <帳號> [db名稱]   建立帳號並自動產生隨機密碼，輸出 .env 格式連線資訊
                                （狀態訊息走 stderr，stdout 可直接重新導向存檔）
  generate_github_secrets <owner/repo> [.env檔]
                                把 .env 裡的連線資訊轉成一串 gh secret set 命令，
                                在已登入 gh CLI 的機器上執行即可全部放進 GitHub Secrets
                                （預設讀取 ./.env）

選項:
  -p, --project <id>     指定 GCP 專案 ID（預設: $SQL_PROJECT_ID 或 gcloud config 目前專案）
  -i, --instance <名稱>  指定實例名稱（預設: $SQL_INSTANCE 或 prod-pg-lite）
  --private              create 時建立純 private IP 實例（不配公網 IP）
                         需先完成 VPC 私有服務連線: ../network/network.sh setup
  --network <VPC名稱>    --private 模式使用的 VPC（預設: $SQL_NETWORK 或 default）
  -h, --help             顯示此說明

環境變數:
  SQL_PROJECT_ID    預設專案 ID
  SQL_INSTANCE      預設實例名稱（預設: prod-pg-lite）
  SQL_REGION        區域（預設: asia-east1）
  SQL_DB_VERSION    資料庫版本（預設: POSTGRES_18）
  SQL_NETWORK       --private 模式的預設 VPC（預設: default）

範例:
  ./sql.sh create
  ./sql.sh --private create
  ./sql.sh create_database my_app_db
  ./sql.sh create_user app_user my_app_db > .env
  ./sql.sh generate_github_secrets fred/go-api
  ./sql.sh -i staging-pg delete
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

require_instance() {
    gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" &>/dev/null \
        || die "找不到實例 '${INSTANCE_NAME}'，請先執行 './sql.sh create'。"
}

# 取得實例的私有 IP，沒有則輸出空字串
get_private_ip() {
    gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
        | awk '/ipAddress:/{ip=$NF} /type: PRIVATE/{print ip; exit}' || true
}

# ==========================================
# 🚀 create - 建立 Cloud SQL 實例
# ==========================================
cmd_create() {
    [ -n "${1:-}" ] && INSTANCE_NAME="$1"
    require_login
    resolve_project

    echo "🚀 建立 Cloud SQL 實例 '${INSTANCE_NAME}'（專案: ${PROJECT_ID}，區域: ${REGION}）"

    gcloud services enable sqladmin.googleapis.com --project="${PROJECT_ID}"

    if gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
        info "實例 '${INSTANCE_NAME}' 已存在，跳過建立步驟。"
        return
    fi

    # private 模式走 VPC 私有 IP，需要 VPC 已完成私有服務連線（peering）
    local ip_flags=(--assign-ip)
    if [ "${PRIVATE_MODE}" -eq 1 ]; then
        if ! gcloud services vpc-peerings list \
            --network="${NETWORK}" \
            --service=servicenetworking.googleapis.com \
            --project="${PROJECT_ID}" 2>/dev/null | grep -q "servicenetworking"; then
            die "VPC '${NETWORK}' 尚未設定私有服務連線，請先執行 '../network/network.sh setup ${NETWORK}'。"
        fi
        ip_flags=(--network="projects/${PROJECT_ID}/global/networks/${NETWORK}" --no-assign-ip)
        info "private IP 模式：實例將只有 VPC '${NETWORK}' 內的私有 IP，不配公網 IP。"
    fi

    # 實惠生產規格：1 vCPU, 3.75GB RAM, 20GB SSD, 自動擴容
    # PostgreSQL 16+ 預設會開成 Enterprise Plus（不支援 db-custom 機型且貴很多），
    # 明確指定 enterprise 版以使用自訂規格
    echo "⏳ 建立中（這通常需要 3-5 分鐘，請稍候）..."
    gcloud sql instances create "${INSTANCE_NAME}" \
        --project="${PROJECT_ID}" \
        --database-version="${DB_VERSION}" \
        --edition=enterprise \
        --cpu=1 \
        --memory=3840MiB \
        --storage-type=SSD \
        --storage-size=20GB \
        --storage-auto-increase \
        --region="${REGION}" \
        "${ip_flags[@]}"

    ok "實例 '${INSTANCE_NAME}' 建立完成！"
    if [ "${PRIVATE_MODE}" -eq 1 ]; then
        info "私有 IP: $(get_private_ip)"
        info "Cloud Run 需設定 VPC egress 才連得到（wif.sh generate_github_workflow 加 --vpc ${NETWORK}）。"
    fi
    echo ""
    echo "接下來："
    echo "   ./sql.sh create_database <db名稱>          建立資料庫"
    echo "   ./sql.sh create_user <帳號> <db名稱> > .env  建立帳號並存下連線資訊"
}

# ==========================================
# 🗑️ delete - 刪除 Cloud SQL 實例
# ==========================================
cmd_delete() {
    [ -n "${1:-}" ] && INSTANCE_NAME="$1"
    require_login
    resolve_project
    require_instance

    echo "⚠️  即將刪除實例 '${INSTANCE_NAME}'（專案: ${PROJECT_ID}）"
    echo "⚠️  其中所有資料庫與資料將一併刪除，且無法復原！"
    printf "確認刪除請輸入實例名稱（%s）: " "${INSTANCE_NAME}"
    read -r answer
    if [ "${answer}" != "${INSTANCE_NAME}" ]; then
        die "輸入不符，已取消刪除。"
    fi

    gcloud sql instances delete "${INSTANCE_NAME}" --project="${PROJECT_ID}" --quiet
    ok "實例 '${INSTANCE_NAME}' 已刪除。"
    info "注意: GCP 限制同名實例約一週內無法重新建立。"
}

# ==========================================
# 📚 create_database - 建立資料庫
# ==========================================
cmd_create_database() {
    local db="$1"
    require_login
    resolve_project
    require_instance

    if gcloud sql databases describe "${db}" --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
        info "資料庫 '${db}' 已存在於實例 '${INSTANCE_NAME}'，跳過建立步驟。"
        return
    fi

    gcloud sql databases create "${db}" --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}"
    ok "資料庫 '${db}' 建立完成（實例: ${INSTANCE_NAME}）。"
}

# ==========================================
# 👤 create_user - 建立帳號並輸出連線資訊
# ==========================================
cmd_create_user() {
    local user="$1"
    local db="${2:-}"
    require_login
    resolve_project
    require_instance

    if gcloud sql users list --instance="${INSTANCE_NAME}" --project="${PROJECT_ID}" --format="value(name)" | grep -qx "${user}"; then
        die "帳號 '${user}' 已存在（重設密碼可用: gcloud sql users set-password ${user} --instance=${INSTANCE_NAME} --prompt-for-password）。"
    fi

    # 自動產生 16 bytes 隨機密碼
    local password
    password=$(openssl rand -base64 16)

    # 狀態訊息全部走 stderr，讓 stdout 可以直接重新導向成 .env
    echo "⏳ 正在建立帳號 '${user}'（實例: ${INSTANCE_NAME}）..." >&2
    gcloud sql users create "${user}" \
        --instance="${INSTANCE_NAME}" \
        --project="${PROJECT_ID}" \
        --password="${password}" >&2

    local connection_name
    connection_name=$(gcloud sql instances describe "${INSTANCE_NAME}" --project="${PROJECT_ID}" --format="value(connectionName)")

    # 實例有私有 IP 時直接輸出，否則輸出本機 Auth Proxy 位址
    local db_host host_note
    db_host=$(get_private_ip)
    if [ -n "${db_host}" ]; then
        host_note="# --- Cloud SQL 連線資訊（private IP，Cloud Run 需設定 VPC egress 才連得到）---"
    else
        db_host="127.0.0.1"
        host_note="# --- Cloud SQL 連線資訊（本機開發請搭配 Cloud SQL Auth Proxy）---"
    fi

    if [ -z "${db}" ]; then
        echo "⚠️  未指定資料庫名稱，輸出中的 DB_NAME 將留空，請自行補上。" >&2
    fi
    ok "帳號 '${user}' 建立完成，連線資訊如下（可用 '> .env' 直接存檔）：" >&2

    cat << EOF
${host_note}
DB_HOST=${db_host}
DB_PORT=5432
DB_NAME=${db}
DB_USER=${user}
DB_PASSWORD=${password}

# GCP 專用連線字串 (Auth Proxy 或 Go SDK 使用)
CLOUD_SQL_CONNECTION_NAME=${connection_name}
EOF
}

# ==========================================
# 🔐 generate_github_secrets - 把 .env 轉成 gh secret set 命令
# ==========================================
cmd_generate_github_secrets() {
    local repo="$1"
    local env_file="${2:-.env}"

    echo "${repo}" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
        || die "repo 格式錯誤，需為 <owner>/<repo>，例如: fred/go-api"
    if [ ! -f "${env_file}" ]; then
        die "找不到 '${env_file}'，請先執行 './sql.sh create_user <帳號> <db名稱> > .env' 產生連線資訊。"
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
        echo "   2. deploy.yaml 的 env_vars 以 \${{ secrets.DB_HOST }} 等方式引用"
        echo "      （wif.sh generate_github_workflow 產生的註解範例已寫好，打開即可）"
        echo "   ⚠️  以上命令含明文密碼，執行完請刪除，不要 commit 進版控。"
    } >&2
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
        -i|--instance)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            INSTANCE_NAME="$2"
            shift 2
            ;;
        --private)
            PRIVATE_MODE=1
            shift
            ;;
        --network)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            NETWORK="$2"
            shift 2
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
    create)
        cmd_create "${ARGS[1]:-}"
        ;;
    delete)
        cmd_delete "${ARGS[1]:-}"
        ;;
    create_database)
        [ -n "${ARGS[1]:-}" ] || die "請指定資料庫名稱，例如: ./sql.sh create_database my_app_db"
        cmd_create_database "${ARGS[1]}"
        ;;
    create_user)
        [ -n "${ARGS[1]:-}" ] || die "請指定帳號名稱，例如: ./sql.sh create_user app_user my_app_db"
        cmd_create_user "${ARGS[1]}" "${ARGS[2]:-}"
        ;;
    generate_github_secrets)
        [ -n "${ARGS[1]:-}" ] || die "請指定 GitHub repo，例如: ./sql.sh generate_github_secrets fred/go-api"
        cmd_generate_github_secrets "${ARGS[1]}" "${ARGS[2]:-}"
        ;;
    help)
        usage
        ;;
    "")
        usage >&2
        exit 1
        ;;
    *)
        usage >&2
        die "未知指令 '${COMMAND}'"
        ;;
esac
