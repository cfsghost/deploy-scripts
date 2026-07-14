#!/usr/bin/env bash

# lb.sh - GCP 外部 HTTPS Load Balancer 管理工具（Cloud Run 前後端分流）
#
# 用法:
#   ./lb.sh setup <網域> --frontend <服務> [--backend <服務>]
#                        建立 LB：網域 → 靜態 IP → LB → Cloud Run
#                        （預設 /api/* 分流到 backend，其餘流量到 frontend）
#   ./lb.sh check        逐項檢查 LB 元件與憑證簽發狀態
#   ./lb.sh ip           輸出保留的靜態 IP（設定 DNS A 記錄用）
#   ./lb.sh lock <服務>   限制 Cloud Run 服務只接受 LB 流量（關閉 run.app 直連）
#   ./lb.sh unlock <服務> 恢復 Cloud Run 服務可直連
#   ./lb.sh delete       刪除整組 LB 元件（不動 Cloud Run 服務本身）

set -eo pipefail

# ==========================================
# 🔧 全域設定（可用環境變數覆寫）
# ==========================================
REGION="${LB_REGION:-asia-east1}"       # Cloud Run 服務所在區域
LB_NAME="${LB_NAME:-web}"               # 元件命名用，一組 LB 一個名字
API_PATH="${LB_API_PATH:-/api/*}"       # 分流到 backend 的路徑
PROJECT_ID="${LB_PROJECT_ID:-}"
FRONTEND_SVC=""
BACKEND_SVC=""

# ==========================================
# 🛠️ 共用函式
# ==========================================
usage() {
    cat << 'EOF'
用法: lb.sh [選項] <指令>

指令:
  setup <網域>          建立外部 HTTPS LB，把網域流量分流到 Cloud Run 服務
                        需搭配 --frontend，選配 --backend（預設 /api/* 給 backend）
  check                 逐項檢查 LB 元件與憑證簽發狀態
  ip                    輸出保留的靜態 IP（設定 DNS A 記錄用）
  lock <服務>           限制 Cloud Run 服務只接受 LB 流量（關閉 run.app 直連）
  unlock <服務>         恢復 Cloud Run 服務可直連
  delete                刪除整組 LB 元件（靜態 IP、憑證等；不動 Cloud Run 服務）

選項:
  -p, --project <id>    指定 GCP 專案 ID（預設: $LB_PROJECT_ID 或 gcloud config 目前專案）
  -n, --name <名稱>     LB 元件命名（預設: $LB_NAME 或 web；同專案建第二組 LB 時使用）
  --region <區域>       Cloud Run 服務所在區域（預設: $LB_REGION 或 asia-east1）
  --frontend <服務>     接收預設流量的 Cloud Run 服務（setup 必填）
  --backend <服務>      接收 API 流量的 Cloud Run 服務（setup 選填）
  --api-path <路徑>     分流到 backend 的路徑（預設: $LB_API_PATH 或 /api/*）
  -h, --help            顯示此說明

環境變數:
  LB_PROJECT_ID    預設專案 ID
  LB_NAME          預設 LB 名稱（預設: web）
  LB_REGION        區域（預設: asia-east1）
  LB_API_PATH      預設分流路徑（預設: /api/*）

範例:
  ./lb.sh setup app.example.com --frontend my-frontend --backend my-backend
  ./lb.sh setup app.example.com --frontend my-app          # 單一服務，不分流
  ./lb.sh check
  ./lb.sh lock my-backend
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

# LB 元件命名（選項解析完成後呼叫）
set_names() {
    IP_NAME="ip-${LB_NAME}"
    UM_NAME="um-${LB_NAME}"
    UM_REDIRECT_NAME="um-${LB_NAME}-redirect"
    CERT_NAME="cert-${LB_NAME}"
    HTTPS_PROXY_NAME="proxy-https-${LB_NAME}"
    HTTP_PROXY_NAME="proxy-http-${LB_NAME}"
    FR_HTTPS_NAME="fr-https-${LB_NAME}"
    FR_HTTP_NAME="fr-http-${LB_NAME}"
}

# 各類 compute 資源是否存在
global_exists() {  # <資源類型> <名稱>
    gcloud compute "$1" describe "$2" --global --project="${PROJECT_ID}" &>/dev/null
}
neg_exists() {
    gcloud compute network-endpoint-groups describe "$1" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null
}

get_static_ip() {
    gcloud compute addresses describe "${IP_NAME}" --global --project="${PROJECT_ID}" \
        --format="value(address)" 2>/dev/null || true
}

# 從 URL map 找出這組 LB 用到的 backend services（delete 時反查用）
get_lb_backend_services() {
    gcloud compute url-maps describe "${UM_NAME}" --global --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
        | grep -o 'backendServices/[A-Za-z0-9-]*' | sed 's|backendServices/||' | sort -u || true
}

# 找出 backend service 掛的 serverless NEG 名稱
get_bs_negs() {
    gcloud compute backend-services describe "$1" --global --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
        | grep -o 'networkEndpointGroups/[A-Za-z0-9-]*' | sed 's|networkEndpointGroups/||' | sort -u || true
}

# ==========================================
# 🚀 setup - 建立整組 LB
# ==========================================

# 為一個 Cloud Run 服務建立 serverless NEG + backend service
setup_backend() {
    local svc="$1"
    local neg="neg-${svc}" bs="bs-${svc}"

    if neg_exists "${neg}"; then
        info "Serverless NEG '${neg}' 已存在，跳過。"
    else
        gcloud compute network-endpoint-groups create "${neg}" \
            --project="${PROJECT_ID}" \
            --region="${REGION}" \
            --network-endpoint-type=serverless \
            --cloud-run-service="${svc}"
        ok "Serverless NEG '${neg}' 建立完成（→ Cloud Run '${svc}'）。"
    fi

    if global_exists backend-services "${bs}"; then
        info "Backend service '${bs}' 已存在，跳過。"
    else
        gcloud compute backend-services create "${bs}" \
            --project="${PROJECT_ID}" \
            --global \
            --load-balancing-scheme=EXTERNAL_MANAGED \
            --protocol=HTTPS
        ok "Backend service '${bs}' 建立完成。"
    fi

    if gcloud compute backend-services describe "${bs}" --global --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
        | grep -q "networkEndpointGroups/${neg}$"; then
        info "NEG '${neg}' 已掛上 '${bs}'，跳過。"
    else
        gcloud compute backend-services add-backend "${bs}" \
            --project="${PROJECT_ID}" \
            --global \
            --network-endpoint-group="${neg}" \
            --network-endpoint-group-region="${REGION}"
        ok "NEG '${neg}' 已掛上 backend service '${bs}'。"
    fi
}

cmd_setup() {
    local domain="$1"

    [ -n "${domain}" ] || die "請指定網域，例如: ./lb.sh setup app.example.com --frontend my-frontend"
    echo "${domain}" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$' \
        || die "網域格式錯誤: '${domain}'"
    [ -n "${FRONTEND_SVC}" ] || die "請用 '--frontend <服務>' 指定接收預設流量的 Cloud Run 服務。"

    require_login
    resolve_project

    echo "🚀 建立 HTTPS Load Balancer '${LB_NAME}'（專案: ${PROJECT_ID}，網域: ${domain}）"
    if [ -n "${BACKEND_SVC}" ]; then
        info "分流規則: ${API_PATH} → '${BACKEND_SVC}'，其餘 → '${FRONTEND_SVC}'"
    else
        info "全部流量 → '${FRONTEND_SVC}'（未指定 --backend，不設分流）"
    fi

    # 確認 Cloud Run 服務都已存在（LB 指向不存在的服務不會報錯，先擋下來）
    local svc
    for svc in ${FRONTEND_SVC} ${BACKEND_SVC}; do
        gcloud run services describe "${svc}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null \
            || die "找不到 Cloud Run 服務 '${svc}'（區域: ${REGION}），請先完成第一次部署。"
    done

    gcloud services enable compute.googleapis.com --project="${PROJECT_ID}"

    # 1. 保留全域靜態 IP（DNS A 記錄指向這裡）
    if global_exists addresses "${IP_NAME}"; then
        info "靜態 IP '${IP_NAME}' 已存在，跳過。"
    else
        gcloud compute addresses create "${IP_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --network-tier=PREMIUM
        ok "靜態 IP '${IP_NAME}' 保留完成。"
    fi

    # 2. 每個 Cloud Run 服務一組 serverless NEG + backend service
    setup_backend "${FRONTEND_SVC}"
    if [ -n "${BACKEND_SVC}" ]; then
        setup_backend "${BACKEND_SVC}"
    fi

    # 3. URL map：預設流量給 frontend，指定 --backend 時加上路徑分流
    if global_exists url-maps "${UM_NAME}"; then
        info "URL map '${UM_NAME}' 已存在，跳過。"
    else
        gcloud compute url-maps create "${UM_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --default-service="bs-${FRONTEND_SVC}"
        ok "URL map '${UM_NAME}' 建立完成（預設 → bs-${FRONTEND_SVC}）。"
    fi
    if [ -n "${BACKEND_SVC}" ]; then
        if gcloud compute url-maps describe "${UM_NAME}" --global --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
            | grep -q "pathMatchers:"; then
            info "URL map 已有分流規則，跳過（調整規則請用 gcloud compute url-maps edit ${UM_NAME}）。"
        else
            gcloud compute url-maps add-path-matcher "${UM_NAME}" \
                --project="${PROJECT_ID}" \
                --global \
                --path-matcher-name="split" \
                --default-service="bs-${FRONTEND_SVC}" \
                --path-rules="${API_PATH}=bs-${BACKEND_SVC}" \
                --new-hosts='*'
            ok "分流規則建立完成: ${API_PATH} → bs-${BACKEND_SVC}。"
        fi
    fi

    # 4. Google 管理 SSL 憑證（DNS 指向 IP 後自動簽發）
    if global_exists ssl-certificates "${CERT_NAME}"; then
        local existing_domain
        existing_domain=$(gcloud compute ssl-certificates describe "${CERT_NAME}" --global --project="${PROJECT_ID}" \
            --format="value(managed.domains)" 2>/dev/null || true)
        if [ "${existing_domain}" = "${domain}" ]; then
            info "SSL 憑證 '${CERT_NAME}' 已存在，跳過。"
        else
            echo "⚠️  SSL 憑證 '${CERT_NAME}' 已存在但網域是 '${existing_domain}'（本次指定 '${domain}'）。" >&2
            echo "⚠️  憑證無法修改網域，請先 './lb.sh delete' 整組重建，或用 '-n' 另建一組 LB。" >&2
            exit 1
        fi
    else
        gcloud compute ssl-certificates create "${CERT_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --domains="${domain}"
        ok "SSL 憑證 '${CERT_NAME}' 建立完成（等 DNS 生效後自動簽發）。"
    fi

    # 5. HTTPS proxy 與 HTTP→HTTPS 轉址
    if global_exists target-https-proxies "${HTTPS_PROXY_NAME}"; then
        info "HTTPS proxy '${HTTPS_PROXY_NAME}' 已存在，跳過。"
    else
        gcloud compute target-https-proxies create "${HTTPS_PROXY_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --url-map="${UM_NAME}" \
            --ssl-certificates="${CERT_NAME}"
        ok "HTTPS proxy '${HTTPS_PROXY_NAME}' 建立完成。"
    fi
    if global_exists url-maps "${UM_REDIRECT_NAME}"; then
        info "轉址 URL map '${UM_REDIRECT_NAME}' 已存在，跳過。"
    else
        gcloud compute url-maps import "${UM_REDIRECT_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --quiet \
            --source=- << EOF
name: ${UM_REDIRECT_NAME}
defaultUrlRedirect:
  redirectResponseCode: MOVED_PERMANENTLY_DEFAULT
  httpsRedirect: true
EOF
        ok "HTTP→HTTPS 轉址 URL map '${UM_REDIRECT_NAME}' 建立完成。"
    fi
    if global_exists target-http-proxies "${HTTP_PROXY_NAME}"; then
        info "HTTP proxy '${HTTP_PROXY_NAME}' 已存在，跳過。"
    else
        gcloud compute target-http-proxies create "${HTTP_PROXY_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --url-map="${UM_REDIRECT_NAME}"
        ok "HTTP proxy '${HTTP_PROXY_NAME}' 建立完成。"
    fi

    # 6. Forwarding rules：把靜態 IP 的 443/80 接上 proxy
    if global_exists forwarding-rules "${FR_HTTPS_NAME}"; then
        info "Forwarding rule '${FR_HTTPS_NAME}' 已存在，跳過。"
    else
        gcloud compute forwarding-rules create "${FR_HTTPS_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --load-balancing-scheme=EXTERNAL_MANAGED \
            --network-tier=PREMIUM \
            --address="${IP_NAME}" \
            --target-https-proxy="${HTTPS_PROXY_NAME}" \
            --ports=443
        ok "Forwarding rule '${FR_HTTPS_NAME}'（443）建立完成。"
    fi
    if global_exists forwarding-rules "${FR_HTTP_NAME}"; then
        info "Forwarding rule '${FR_HTTP_NAME}' 已存在，跳過。"
    else
        gcloud compute forwarding-rules create "${FR_HTTP_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --load-balancing-scheme=EXTERNAL_MANAGED \
            --network-tier=PREMIUM \
            --address="${IP_NAME}" \
            --target-http-proxy="${HTTP_PROXY_NAME}" \
            --ports=80
        ok "Forwarding rule '${FR_HTTP_NAME}'（80）建立完成。"
    fi

    local ip
    ip=$(get_static_ip)
    echo ""
    ok "LB '${LB_NAME}' 建立完成！"
    echo ""
    echo "接下來："
    echo "   1. 到 DNS 服務商為 '${domain}' 加一筆 A 記錄，指向: ${ip}"
    echo "   2. DNS 生效後 Google 會自動簽發憑證（通常 15-60 分鐘），用 './lb.sh check' 追蹤進度"
    echo "   3. 建議關閉 run.app 網址直連，讓流量只能走 LB："
    echo "      ./lb.sh lock ${FRONTEND_SVC}"
    if [ -n "${BACKEND_SVC}" ]; then
        echo "      ./lb.sh lock ${BACKEND_SVC}"
    fi
    echo ""
    info "外部 LB 的 forwarding rule 是持續計費資源，測試完不用請 './lb.sh delete'。"
}

# ==========================================
# 🩺 check - 逐項檢查 LB 狀態
# ==========================================
check_item() {  # <說明> <指令...>
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        echo "✅ ${desc}"
    else
        echo "❌ ${desc}"
        FAILED=$((FAILED + 1))
    fi
}

cmd_check() {
    require_login
    resolve_project
    FAILED=0

    echo "🩺 檢查 LB '${LB_NAME}'（專案: ${PROJECT_ID}）"
    echo ""

    local ip
    ip=$(get_static_ip)
    if [ -n "${ip}" ]; then
        echo "✅ 靜態 IP '${IP_NAME}': ${ip}"
    else
        echo "❌ 靜態 IP '${IP_NAME}' 不存在"
        FAILED=$((FAILED + 1))
    fi

    check_item "URL map '${UM_NAME}'" gcloud compute url-maps describe "${UM_NAME}" --global --project="${PROJECT_ID}"
    local bs neg
    for bs in $(get_lb_backend_services); do
        check_item "Backend service '${bs}'" gcloud compute backend-services describe "${bs}" --global --project="${PROJECT_ID}"
        for neg in $(get_bs_negs "${bs}"); do
            check_item "Serverless NEG '${neg}'" gcloud compute network-endpoint-groups describe "${neg}" --region="${REGION}" --project="${PROJECT_ID}"
        done
    done
    check_item "HTTPS proxy '${HTTPS_PROXY_NAME}'" gcloud compute target-https-proxies describe "${HTTPS_PROXY_NAME}" --global --project="${PROJECT_ID}"
    check_item "HTTP 轉址 proxy '${HTTP_PROXY_NAME}'" gcloud compute target-http-proxies describe "${HTTP_PROXY_NAME}" --global --project="${PROJECT_ID}"
    check_item "Forwarding rule 443 '${FR_HTTPS_NAME}'" gcloud compute forwarding-rules describe "${FR_HTTPS_NAME}" --global --project="${PROJECT_ID}"
    check_item "Forwarding rule 80 '${FR_HTTP_NAME}'" gcloud compute forwarding-rules describe "${FR_HTTP_NAME}" --global --project="${PROJECT_ID}"

    # 憑證狀態同時反映 DNS 是否已正確指向（DNS 沒生效憑證不會 ACTIVE）
    if global_exists ssl-certificates "${CERT_NAME}"; then
        local cert_status cert_domain
        cert_status=$(gcloud compute ssl-certificates describe "${CERT_NAME}" --global --project="${PROJECT_ID}" \
            --format="value(managed.status)" 2>/dev/null || true)
        cert_domain=$(gcloud compute ssl-certificates describe "${CERT_NAME}" --global --project="${PROJECT_ID}" \
            --format="value(managed.domains)" 2>/dev/null || true)
        if [ "${cert_status}" = "ACTIVE" ]; then
            echo "✅ SSL 憑證 '${CERT_NAME}'（${cert_domain}）已簽發"
        else
            echo "⏳ SSL 憑證 '${CERT_NAME}'（${cert_domain}）狀態: ${cert_status:-未知}"
            echo "   尚未簽發通常代表 DNS 還沒生效，請確認 A 記錄已指向 ${ip:-<靜態IP>}"
            FAILED=$((FAILED + 1))
        fi
    else
        echo "❌ SSL 憑證 '${CERT_NAME}' 不存在"
        FAILED=$((FAILED + 1))
    fi

    echo ""
    if [ "${FAILED}" -eq 0 ]; then
        ok "LB 全部就緒。"
    else
        die "有 ${FAILED} 個項目未就緒，請執行 './lb.sh setup <網域> --frontend <服務> ...' 補齊。"
    fi
}

# ==========================================
# 📤 ip - 輸出靜態 IP
# ==========================================
cmd_ip() {
    require_login
    resolve_project
    local ip
    ip=$(get_static_ip)
    [ -n "${ip}" ] || die "靜態 IP '${IP_NAME}' 不存在，請先執行 './lb.sh setup'。"
    echo "${ip}"
}

# ==========================================
# 🔒 lock / unlock - 控制 Cloud Run 直連
# ==========================================
cmd_lock() {
    local svc="$1"
    require_login
    resolve_project
    gcloud run services update "${svc}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --ingress=internal-and-cloud-load-balancing
    ok "服務 '${svc}' 已鎖定，只接受 LB 與內部流量（run.app 直連會回 404）。"
}

cmd_unlock() {
    local svc="$1"
    require_login
    resolve_project
    gcloud run services update "${svc}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --ingress=all
    ok "服務 '${svc}' 已恢復可直連。"
}

# ==========================================
# 🗑️ delete - 刪除整組 LB
# ==========================================
cmd_delete() {
    require_login
    resolve_project

    echo "⚠️  即將刪除 LB '${LB_NAME}' 的所有元件（專案: ${PROJECT_ID}）："
    echo "⚠️  forwarding rules、proxies、URL maps、SSL 憑證、backend services、NEGs、靜態 IP"
    echo "⚠️  Cloud Run 服務本身不會被刪除，但網域將無法連到服務。"
    printf "確認刪除請輸入 LB 名稱（%s）: " "${LB_NAME}"
    read -r answer
    if [ "${answer}" != "${LB_NAME}" ]; then
        die "輸入不符，已取消刪除。"
    fi

    # 先從 URL map 反查這組 LB 的 backend services 與 NEGs，再依相依順序拆除
    local bs_list bs neg
    bs_list=$(get_lb_backend_services)

    if global_exists forwarding-rules "${FR_HTTPS_NAME}"; then
        gcloud compute forwarding-rules delete "${FR_HTTPS_NAME}" --global --project="${PROJECT_ID}" --quiet
        ok "已刪除 forwarding rule '${FR_HTTPS_NAME}'。"
    fi
    if global_exists forwarding-rules "${FR_HTTP_NAME}"; then
        gcloud compute forwarding-rules delete "${FR_HTTP_NAME}" --global --project="${PROJECT_ID}" --quiet
        ok "已刪除 forwarding rule '${FR_HTTP_NAME}'。"
    fi
    if global_exists target-https-proxies "${HTTPS_PROXY_NAME}"; then
        gcloud compute target-https-proxies delete "${HTTPS_PROXY_NAME}" --global --project="${PROJECT_ID}" --quiet
        ok "已刪除 HTTPS proxy '${HTTPS_PROXY_NAME}'。"
    fi
    if global_exists target-http-proxies "${HTTP_PROXY_NAME}"; then
        gcloud compute target-http-proxies delete "${HTTP_PROXY_NAME}" --global --project="${PROJECT_ID}" --quiet
        ok "已刪除 HTTP proxy '${HTTP_PROXY_NAME}'。"
    fi
    if global_exists url-maps "${UM_REDIRECT_NAME}"; then
        gcloud compute url-maps delete "${UM_REDIRECT_NAME}" --global --project="${PROJECT_ID}" --quiet
        ok "已刪除轉址 URL map '${UM_REDIRECT_NAME}'。"
    fi
    if global_exists url-maps "${UM_NAME}"; then
        gcloud compute url-maps delete "${UM_NAME}" --global --project="${PROJECT_ID}" --quiet
        ok "已刪除 URL map '${UM_NAME}'。"
    fi
    if global_exists ssl-certificates "${CERT_NAME}"; then
        gcloud compute ssl-certificates delete "${CERT_NAME}" --global --project="${PROJECT_ID}" --quiet
        ok "已刪除 SSL 憑證 '${CERT_NAME}'。"
    fi
    local negs
    for bs in ${bs_list}; do
        negs=$(get_bs_negs "${bs}")
        if global_exists backend-services "${bs}"; then
            gcloud compute backend-services delete "${bs}" --global --project="${PROJECT_ID}" --quiet
            ok "已刪除 backend service '${bs}'。"
        fi
        for neg in ${negs}; do
            if neg_exists "${neg}"; then
                gcloud compute network-endpoint-groups delete "${neg}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
                ok "已刪除 NEG '${neg}'。"
            fi
        done
    done
    if global_exists addresses "${IP_NAME}"; then
        gcloud compute addresses delete "${IP_NAME}" --global --project="${PROJECT_ID}" --quiet
        ok "已刪除靜態 IP '${IP_NAME}'。"
    fi

    ok "LB '${LB_NAME}' 已全部拆除。"
    info "記得移除 DNS 的 A 記錄；服務若曾 lock，請用 './lb.sh unlock <服務>' 恢復直連。"
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
        -n|--name)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            LB_NAME="$2"
            shift 2
            ;;
        --region)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            REGION="$2"
            shift 2
            ;;
        --frontend)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            FRONTEND_SVC="$2"
            shift 2
            ;;
        --backend)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            BACKEND_SVC="$2"
            shift 2
            ;;
        --api-path)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            API_PATH="$2"
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

set_names

COMMAND="${ARGS[0]:-}"
case "${COMMAND}" in
    setup)
        cmd_setup "${ARGS[1]:-}"
        ;;
    check)
        cmd_check
        ;;
    ip)
        cmd_ip
        ;;
    lock)
        [ -n "${ARGS[1]:-}" ] || die "請指定 Cloud Run 服務名稱，例如: ./lb.sh lock my-backend"
        cmd_lock "${ARGS[1]}"
        ;;
    unlock)
        [ -n "${ARGS[1]:-}" ] || die "請指定 Cloud Run 服務名稱，例如: ./lb.sh unlock my-backend"
        cmd_unlock "${ARGS[1]}"
        ;;
    delete)
        cmd_delete
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
