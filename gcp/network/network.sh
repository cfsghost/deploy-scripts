#!/usr/bin/env bash

# network.sh - GCP VPC 私有服務連線設定工具（Private Services Access）
#
# 讓 Cloud SQL 等 Google 管理服務能取得 VPC 內的私有 IP。
# 這是「Cloud Run + Cloud SQL private IP」架構的一次性網路前置設定，
# 每個 VPC 只需要執行一次。
#
# 用法:
#   ./network.sh setup [VPC名稱]   建立私有服務連線（保留 IP 範圍 + VPC peering）
#   ./network.sh check [VPC名稱]   檢查網路設定是否就緒

set -eo pipefail

# ==========================================
# 🔧 全域設定（可用環境變數覆寫）
# ==========================================
NETWORK="${NET_VPC:-default}"
PREFIX_LENGTH="${NET_PREFIX_LENGTH:-16}"   # 保留範圍大小，之後不易更改，請一次選對
PROJECT_ID="${NET_PROJECT_ID:-}"
RANGE_NAME=""   # 於 resolve 階段決定，預設 google-managed-services-<VPC名稱>

# ==========================================
# 🛠️ 共用函式
# ==========================================
usage() {
    cat << 'EOF'
用法: network.sh [選項] <指令>

指令:
  setup [VPC名稱]   建立私有服務連線（預設 VPC: default），含：
                    1. 啟用 Service Networking / Compute API
                    2. 保留一段 VPC peering 用的 IP 範圍
                    3. 建立與 Google 管理服務的 VPC peering
  check [VPC名稱]   檢查上述設定是否就緒

選項:
  -p, --project <id>   指定 GCP 專案 ID（預設: $NET_PROJECT_ID 或 gcloud config 目前專案）
  -h, --help           顯示此說明

環境變數:
  NET_PROJECT_ID      預設專案 ID
  NET_VPC             預設 VPC 名稱（預設: default）
  NET_PREFIX_LENGTH   保留 IP 範圍的 prefix 長度（預設: 16，之後不易更改）

範例:
  ./network.sh setup
  ./network.sh -p my-project check
  ./network.sh setup my-custom-vpc
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
    RANGE_NAME="google-managed-services-${NETWORK}"
}

network_exists() {
    gcloud compute networks describe "${NETWORK}" --project="${PROJECT_ID}" &>/dev/null
}

range_exists() {
    gcloud compute addresses describe "${RANGE_NAME}" --global --project="${PROJECT_ID}" &>/dev/null
}

peering_exists() {
    gcloud services vpc-peerings list \
        --network="${NETWORK}" \
        --service=servicenetworking.googleapis.com \
        --project="${PROJECT_ID}" 2>/dev/null | grep -q "servicenetworking"
}

# ==========================================
# 🚀 setup - 建立私有服務連線
# ==========================================
cmd_setup() {
    [ -n "${1:-}" ] && NETWORK="$1"
    require_login
    resolve_project

    echo "🚀 設定 VPC '${NETWORK}' 的私有服務連線（專案: ${PROJECT_ID}）"

    echo "[1/3] 啟用必要 API..."
    gcloud services enable \
        compute.googleapis.com \
        servicenetworking.googleapis.com \
        --project="${PROJECT_ID}"

    network_exists || die "找不到 VPC '${NETWORK}'。新專案通常會自動建立 default VPC；若被組織政策停用，請先自行建立 VPC。"

    echo "[2/3] 保留 VPC peering 用的 IP 範圍..."
    if range_exists; then
        info "IP 範圍 '${RANGE_NAME}' 已存在，跳過建立步驟。"
    else
        gcloud compute addresses create "${RANGE_NAME}" \
            --global \
            --purpose=VPC_PEERING \
            --prefix-length="${PREFIX_LENGTH}" \
            --network="${NETWORK}" \
            --project="${PROJECT_ID}" \
            --description="Reserved for Google managed services (Cloud SQL private IP)"
    fi

    echo "[3/3] 建立與 Google 管理服務的 VPC peering..."
    if peering_exists; then
        info "VPC peering 已存在，跳過建立步驟。"
    else
        gcloud services vpc-peerings connect \
            --service=servicenetworking.googleapis.com \
            --ranges="${RANGE_NAME}" \
            --network="${NETWORK}" \
            --project="${PROJECT_ID}"
    fi

    echo ""
    ok "私有服務連線設定完成！"
    echo ""
    echo "接下來可以建立 private IP 的 Cloud SQL 實例，例如："
    echo "   gcloud sql instances create ... \\"
    echo "       --network=projects/${PROJECT_ID}/global/networks/${NETWORK} \\"
    echo "       --no-assign-ip"
    info "剛建好 peering 後第一次建實例偶爾會失敗，等 1-2 分鐘重試即可。"
}

# ==========================================
# 🔍 check - 檢查網路設定
# ==========================================
cmd_check() {
    [ -n "${1:-}" ] && NETWORK="$1"
    require_login
    resolve_project

    echo "🔍 檢查 VPC '${NETWORK}' 的私有服務連線（專案: ${PROJECT_ID}）："
    local fail=0

    local enabled_apis api
    enabled_apis=$(gcloud services list --enabled --project="${PROJECT_ID}" --format="value(config.name)" 2>/dev/null || true)
    for api in compute.googleapis.com servicenetworking.googleapis.com; do
        if echo "${enabled_apis}" | grep -q "^${api}$"; then
            ok "API 已啟用: ${api}"
        else
            echo "❌ API 未啟用: ${api}"
            fail=1
        fi
    done

    if network_exists; then
        ok "VPC 存在: ${NETWORK}"
    else
        echo "❌ VPC 不存在: ${NETWORK}"
        fail=1
    fi

    if range_exists; then
        ok "Peering IP 範圍已保留: ${RANGE_NAME}"
    else
        echo "❌ Peering IP 範圍未保留: ${RANGE_NAME}"
        fail=1
    fi

    if peering_exists; then
        ok "VPC peering 已建立（servicenetworking.googleapis.com）"
    else
        echo "❌ VPC peering 未建立"
        fail=1
    fi

    echo ""
    if [ "${fail}" -ne 0 ]; then
        echo "⚠️  部分項目未就緒，可執行 './network.sh setup ${NETWORK}' 完成設定。"
        exit 1
    fi
    ok "網路已就緒，可建立 private IP 的 Cloud SQL 實例。"
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
    setup)
        cmd_setup "${ARGS[1]:-}"
        ;;
    check)
        cmd_check "${ARGS[1]:-}"
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
