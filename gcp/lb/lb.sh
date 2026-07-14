#!/usr/bin/env bash

# lb.sh - GCP 外部 HTTPS Load Balancer 管理工具（多網域 + 路徑分流到 Cloud Run）
#
# 用法:
#   ./lb.sh init                          建立基礎設施：靜態 IP、HTTP→HTTPS 轉址（每組 LB 一次）
#   ./lb.sh add_domain <網域>             掛上網域（建立 Google 管理憑證）
#   ./lb.sh add_rule <網域> <路徑> <服務>  設定該網域下路徑對應的 Cloud Run 服務
#                                         路徑 '/' 代表該網域的預設服務（需最先設定）
#   ./lb.sh remove_rule <網域> <路徑>     移除規則
#   ./lb.sh remove_domain <網域>          卸下網域（移除規則與憑證）
#   ./lb.sh list                          列出所有網域與規則
#   ./lb.sh check                         逐項檢查元件與憑證簽發狀態
#   ./lb.sh ip                            輸出靜態 IP（設定 DNS A 記錄用）
#   ./lb.sh lock/unlock <服務>            關閉/恢復 Cloud Run run.app 直連
#   ./lb.sh delete                        刪除整組 LB 元件（不動 Cloud Run 服務本身）

set -eo pipefail

# ==========================================
# 🔧 全域設定（可用環境變數覆寫）
# ==========================================
REGION="${LB_REGION:-asia-east1}"       # Cloud Run 服務所在區域
LB_NAME="${LB_NAME:-web}"               # 元件命名用，一組 LB 一個名字
PROJECT_ID="${LB_PROJECT_ID:-}"

# ==========================================
# 🛠️ 共用函式
# ==========================================
usage() {
    cat << 'EOF'
用法: lb.sh [選項] <指令>

指令:
  init                        建立基礎設施：靜態 IP、HTTP→HTTPS 轉址（每組 LB 一次）
  add_domain <網域>           掛上網域（建立 Google 管理憑證，DNS 生效後自動簽發）
  add_rule <網域> <路徑> <服務>
                              設定該網域下路徑對應的 Cloud Run 服務
                              路徑 '/' 代表該網域的預設服務，需最先設定
                              例: add_rule app.example.com / my-frontend
                                  add_rule app.example.com '/api/*' my-backend
  remove_rule <網域> <路徑>   移除該網域下的規則
  remove_domain <網域>        卸下網域（移除其規則與憑證）
  list                        列出所有網域與規則
  check                       逐項檢查元件與憑證簽發狀態
  ip                          輸出靜態 IP（設定 DNS A 記錄用）
  lock <服務>                 限制 Cloud Run 服務只接受 LB 流量（關閉 run.app 直連）
  unlock <服務>               恢復 Cloud Run 服務可直連
  delete                      刪除整組 LB 元件（含所有網域憑證；不動 Cloud Run 服務）

選項:
  -p, --project <id>    指定 GCP 專案 ID（預設: $LB_PROJECT_ID 或 gcloud config 目前專案）
  -n, --name <名稱>     LB 元件命名（預設: $LB_NAME 或 web；同專案建第二組 LB 時使用）
  --region <區域>       Cloud Run 服務所在區域（預設: $LB_REGION 或 asia-east1）
  -h, --help            顯示此說明

環境變數:
  LB_PROJECT_ID    預設專案 ID
  LB_NAME          預設 LB 名稱（預設: web）
  LB_REGION        區域（預設: asia-east1）

範例:
  ./lb.sh init
  ./lb.sh add_domain app.example.com
  ./lb.sh add_rule app.example.com / my-frontend
  ./lb.sh add_rule app.example.com '/api/*' my-backend
  ./lb.sh add_domain admin.example.com
  ./lb.sh add_rule admin.example.com / my-admin
  ./lb.sh list
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
    HTTPS_PROXY_NAME="proxy-https-${LB_NAME}"
    HTTP_PROXY_NAME="proxy-http-${LB_NAME}"
    FR_HTTPS_NAME="fr-https-${LB_NAME}"
    FR_HTTP_NAME="fr-http-${LB_NAME}"
}

# 網域轉元件名稱用（app.example.com → app-example-com）
sanitize() { echo "$1" | tr '.' '-'; }
cert_name_of() { echo "cert-${LB_NAME}-$(sanitize "$1")"; }
pm_name_of() { echo "pm-$(sanitize "$1")"; }

validate_domain() {
    echo "$1" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$' \
        || die "網域格式錯誤: '$1'"
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

# 這組 LB 的所有憑證名稱（一個網域一張）
list_lb_certs() {
    gcloud compute ssl-certificates list --project="${PROJECT_ID}" \
        --filter="name~^cert-${LB_NAME}-" --format="value(name)" 2>/dev/null || true
}

cert_domain_of() {  # <憑證名稱> → 網域
    gcloud compute ssl-certificates describe "$1" --global --project="${PROJECT_ID}" \
        --format="value(managed.domains)" 2>/dev/null || true
}

# 讀取網域目前的規則，每行 "路徑|bs名稱"，預設服務為 "DEFAULT|bs名稱"；網域未設定時輸出空
get_domain_rules() {
    local pm
    pm=$(pm_name_of "$1")
    gcloud compute url-maps describe "${UM_NAME}" --global --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
        | awk -v pm="${pm}" '
            /^- defaultService:/ { ds = $NF; active = 0 }
            /^  name: /          { if ($2 == pm && ds != "") { active = 1; print "DEFAULT|" ds } }
            active && /^    - \// { path = $2 }
            active && /^    service: / { print path "|" $NF }
        ' \
        | sed 's|https://.*/backendServices/||' || true
}

# 從 URL map 找出這組 LB 用到的 backend services（check / delete 反查用）
get_lb_backend_services() {
    gcloud compute url-maps describe "${UM_NAME}" --global --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
        | grep -o 'backendServices/[A-Za-z0-9-]*' | sed 's|backendServices/||' | sort -u || true
}

# 找出 backend service 掛的 serverless NEG 名稱
get_bs_negs() {
    gcloud compute backend-services describe "$1" --global --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
        | grep -o 'networkEndpointGroups/[A-Za-z0-9-]*' | sed 's|networkEndpointGroups/||' | sort -u || true
}

# 為一個 Cloud Run 服務準備 serverless NEG + backend service（冪等）
ensure_backend() {
    local svc="$1"
    local neg="neg-${svc}" bs="bs-${svc}"

    gcloud run services describe "${svc}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null \
        || die "找不到 Cloud Run 服務 '${svc}'（區域: ${REGION}），請先完成第一次部署。"

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

# 規則移除後，backend service 若已不被專案內任何 URL map 引用，連同 NEG 清除
cleanup_orphan_backend() {
    local bs="$1"
    [ -n "${bs}" ] || return 0
    global_exists backend-services "${bs}" || return 0
    if gcloud compute url-maps list --project="${PROJECT_ID}" --format=yaml 2>/dev/null \
        | grep -q "backendServices/${bs}$"; then
        return 0
    fi
    local neg negs
    negs=$(get_bs_negs "${bs}")
    gcloud compute backend-services delete "${bs}" --global --project="${PROJECT_ID}" --quiet
    ok "Backend service '${bs}' 已無規則引用，已一併清除。"
    for neg in ${negs}; do
        if neg_exists "${neg}"; then
            gcloud compute network-endpoint-groups delete "${neg}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
            ok "已清除 NEG '${neg}'。"
        fi
    done
}

# URL map 與至少一張憑證就緒後，補建 HTTPS proxy 與 443 forwarding rule（冪等）
ensure_https() {
    global_exists url-maps "${UM_NAME}" || return 0
    global_exists addresses "${IP_NAME}" || return 0
    local certs certs_csv
    certs=$(list_lb_certs)
    [ -n "${certs}" ] || return 0
    certs_csv=$(echo "${certs}" | paste -sd, -)

    if global_exists target-https-proxies "${HTTPS_PROXY_NAME}"; then
        info "HTTPS proxy '${HTTPS_PROXY_NAME}' 已存在，跳過。"
    else
        gcloud compute target-https-proxies create "${HTTPS_PROXY_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --url-map="${UM_NAME}" \
            --ssl-certificates="${certs_csv}"
        ok "HTTPS proxy '${HTTPS_PROXY_NAME}' 建立完成。"
    fi

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
}

# ==========================================
# 🚀 init - 建立基礎設施
# ==========================================
cmd_init() {
    require_login
    resolve_project

    echo "🚀 初始化 LB '${LB_NAME}' 基礎設施（專案: ${PROJECT_ID}）"

    gcloud services enable compute.googleapis.com --project="${PROJECT_ID}"

    # 1. 保留全域靜態 IP（所有網域的 DNS A 記錄都指向這裡）
    if global_exists addresses "${IP_NAME}"; then
        info "靜態 IP '${IP_NAME}' 已存在，跳過。"
    else
        gcloud compute addresses create "${IP_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --network-tier=PREMIUM
        ok "靜態 IP '${IP_NAME}' 保留完成。"
    fi

    # 2. HTTP→HTTPS 轉址（80 埠）
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

    echo ""
    ok "基礎設施就緒！靜態 IP: $(get_static_ip)"
    echo ""
    echo "接下來："
    echo "   ./lb.sh add_domain <網域>              掛上網域"
    echo "   ./lb.sh add_rule <網域> / <服務>        設定網域的預設服務"
    echo "   ./lb.sh add_rule <網域> <路徑> <服務>   加路徑分流規則"
    echo ""
    info "外部 LB 的 forwarding rule 是持續計費資源，測試完不用請 './lb.sh delete'。"
}

# ==========================================
# 🌐 add_domain - 掛上網域
# ==========================================
cmd_add_domain() {
    local domain="$1"
    validate_domain "${domain}"
    require_login
    resolve_project

    global_exists addresses "${IP_NAME}" \
        || die "尚未初始化基礎設施，請先執行 './lb.sh init'。"

    local cert
    cert=$(cert_name_of "${domain}")

    if global_exists ssl-certificates "${cert}"; then
        info "網域 '${domain}' 的憑證 '${cert}' 已存在，跳過。"
    else
        gcloud compute ssl-certificates create "${cert}" \
            --project="${PROJECT_ID}" \
            --global \
            --domains="${domain}"
        ok "SSL 憑證 '${cert}' 建立完成（DNS 生效後自動簽發）。"
    fi

    # 憑證掛上 HTTPS proxy；proxy 還沒建（尚無任何規則）時由 ensure_https 之後補
    if global_exists target-https-proxies "${HTTPS_PROXY_NAME}"; then
        local certs_csv
        certs_csv=$(list_lb_certs | paste -sd, -)
        gcloud compute target-https-proxies update "${HTTPS_PROXY_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --ssl-certificates="${certs_csv}"
        ok "憑證已掛上 HTTPS proxy。"
    else
        ensure_https
    fi

    echo ""
    echo "接下來："
    echo "   1. 到 DNS 服務商為 '${domain}' 加一筆 A 記錄，指向: $(get_static_ip)"
    echo "   2. 設定這個網域的服務："
    echo "      ./lb.sh add_rule ${domain} / <預設服務>"
    echo "      ./lb.sh add_rule ${domain} '/api/*' <API服務>"
    echo "   3. 憑證簽發進度（DNS 生效後通常 15-60 分鐘）: ./lb.sh check"
}

# ==========================================
# 📏 add_rule - 設定網域下的路徑規則
# ==========================================

# 以「現有規則 ± 異動」重建網域的 path matcher
rebuild_path_matcher() {  # <網域> <預設bs> <規則列表: 每行 "路徑|bs">
    local domain="$1" default_bs="$2" rules="$3"
    local pm
    pm=$(pm_name_of "${domain}")

    # 組 --path-rules 參數（路徑1=bs1,路徑2=bs2）
    local csv="" p s
    while IFS='|' read -r p s; do
        [ -n "${p}" ] || continue
        csv="${csv:+${csv},}${p}=${s}"
    done <<< "${rules}"

    # URL map 不存在時先建立（全域預設掛第一個服務，未匹配網域的流量會落到這裡）
    if ! global_exists url-maps "${UM_NAME}"; then
        gcloud compute url-maps create "${UM_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --default-service="${default_bs}"
        ok "URL map '${UM_NAME}' 建立完成。"
    elif [ -n "$(get_domain_rules "${domain}")" ]; then
        # 已有此網域的 matcher → 先移除再重建（gcloud 無法就地修改）
        gcloud compute url-maps remove-path-matcher "${UM_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --path-matcher-name="${pm}"
    fi

    local rule_flags=()
    if [ -n "${csv}" ]; then
        rule_flags=(--path-rules="${csv}")
    fi
    gcloud compute url-maps add-path-matcher "${UM_NAME}" \
        --project="${PROJECT_ID}" \
        --global \
        --path-matcher-name="${pm}" \
        --default-service="${default_bs}" \
        --new-hosts="${domain}" \
        "${rule_flags[@]}"
}

# 顯示網域目前的規則
print_domain_rules() {
    local domain="$1" line p s
    while IFS='|' read -r p s; do
        [ -n "${p}" ] || continue
        if [ "${p}" = "DEFAULT" ]; then
            printf "   %-12s → %s（預設）\n" "/" "${s#bs-}"
        else
            printf "   %-12s → %s\n" "${p}" "${s#bs-}"
        fi
    done <<< "$(get_domain_rules "${domain}")"
}

cmd_add_rule() {
    local domain="$1" path="$2" svc="$3"
    validate_domain "${domain}"
    echo "${path}" | grep -q '^/' || die "路徑需以 '/' 開頭，例如 / 或 /api/*"
    echo "${svc}" | grep -Eq '^[a-z0-9-]+$' || die "服務名稱格式錯誤: '${svc}'"
    require_login
    resolve_project

    global_exists ssl-certificates "$(cert_name_of "${domain}")" \
        || die "網域 '${domain}' 尚未掛上，請先執行 './lb.sh add_domain ${domain}'。"

    ensure_backend "${svc}"

    # 讀取現有規則，套上這次異動
    local existing default_bs rules old_bs
    existing=$(get_domain_rules "${domain}")
    default_bs=$(echo "${existing}" | awk -F'|' '$1 == "DEFAULT" { print $2 }')
    rules=$(echo "${existing}" | awk -F'|' -v p="${path}" '$1 != "DEFAULT" && $1 != p' || true)

    if [ "${path}" = "/" ]; then
        old_bs="${default_bs}"
        default_bs="bs-${svc}"
    else
        [ -n "${default_bs}" ] \
            || die "網域 '${domain}' 還沒有預設服務，請先執行 './lb.sh add_rule ${domain} / <服務>'。"
        old_bs=$(echo "${existing}" | awk -F'|' -v p="${path}" '$1 == p { print $2 }')
        rules=$(printf '%s\n%s' "${rules}" "${path}|bs-${svc}")
    fi

    rebuild_path_matcher "${domain}" "${default_bs}" "${rules}"
    ensure_https

    # 覆蓋規則時，被換掉的服務若已無任何規則引用，順手清除
    if [ -n "${old_bs}" ] && [ "${old_bs}" != "bs-${svc}" ]; then
        cleanup_orphan_backend "${old_bs}"
    fi

    echo ""
    ok "規則設定完成，'${domain}' 目前的規則："
    print_domain_rules "${domain}"
}

# ==========================================
# 🧹 remove_rule - 移除網域下的規則
# ==========================================
cmd_remove_rule() {
    local domain="$1" path="$2"
    validate_domain "${domain}"
    require_login
    resolve_project

    local existing default_bs rules pm
    existing=$(get_domain_rules "${domain}")
    [ -n "${existing}" ] || die "網域 '${domain}' 沒有任何規則。"
    default_bs=$(echo "${existing}" | awk -F'|' '$1 == "DEFAULT" { print $2 }')
    rules=$(echo "${existing}" | awk -F'|' '$1 != "DEFAULT"' || true)
    pm=$(pm_name_of "${domain}")

    if [ "${path}" = "/" ]; then
        if [ -n "${rules}" ]; then
            die "網域 '${domain}' 還有其他規則，預設服務不能先移除；請先移除其他規則，或直接 './lb.sh remove_domain ${domain}'。"
        fi
        gcloud compute url-maps remove-path-matcher "${UM_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --path-matcher-name="${pm}"
        ok "網域 '${domain}' 的規則已全部移除（憑證仍掛著，可重新 add_rule）。"
        cleanup_orphan_backend "${default_bs}"
        return
    fi

    # 路徑可能含 * 等 regex 字元，用 awk 做字串比較
    echo "${existing}" | awk -F'|' -v p="${path}" '$1 == p { found = 1 } END { exit found ? 0 : 1 }' \
        || die "網域 '${domain}' 沒有 '${path}' 這條規則。"
    local removed_bs
    removed_bs=$(echo "${existing}" | awk -F'|' -v p="${path}" '$1 == p { print $2 }')
    rules=$(echo "${rules}" | awk -F'|' -v p="${path}" '$1 != p' || true)
    rebuild_path_matcher "${domain}" "${default_bs}" "${rules}"
    cleanup_orphan_backend "${removed_bs}"

    echo ""
    ok "規則已移除，'${domain}' 目前的規則："
    print_domain_rules "${domain}"
}

# ==========================================
# 🗑️ remove_domain - 卸下網域
# ==========================================
cmd_remove_domain() {
    local domain="$1"
    validate_domain "${domain}"
    require_login
    resolve_project

    local cert pm
    cert=$(cert_name_of "${domain}")
    pm=$(pm_name_of "${domain}")
    global_exists ssl-certificates "${cert}" || die "網域 '${domain}' 沒有掛在 LB '${LB_NAME}' 上。"

    # 移除規則（path matcher 連同 host rule），先記下用到的服務以便清理
    local domain_bs_list=""
    if [ -n "$(get_domain_rules "${domain}")" ]; then
        domain_bs_list=$(get_domain_rules "${domain}" | awk -F'|' '{ print $2 }' | sort -u)
        gcloud compute url-maps remove-path-matcher "${UM_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --path-matcher-name="${pm}"
        ok "已移除 '${domain}' 的規則。"
    fi

    # 從 HTTPS proxy 卸下憑證（proxy 至少要留一張，最後一個網域只能整組 delete）
    if global_exists target-https-proxies "${HTTPS_PROXY_NAME}"; then
        local remaining
        remaining=$(list_lb_certs | grep -vx "${cert}" || true)
        if [ -z "${remaining}" ]; then
            die "'${domain}' 是最後一個網域，HTTPS proxy 不能沒有憑證；要整組拆除請用 './lb.sh delete'。"
        fi
        gcloud compute target-https-proxies update "${HTTPS_PROXY_NAME}" \
            --project="${PROJECT_ID}" \
            --global \
            --ssl-certificates="$(echo "${remaining}" | paste -sd, -)"
        ok "憑證已從 HTTPS proxy 卸下。"
    fi

    gcloud compute ssl-certificates delete "${cert}" --global --project="${PROJECT_ID}" --quiet

    # 這個網域用到的服務若已無其他規則引用，順手清除
    local bs
    for bs in ${domain_bs_list}; do
        cleanup_orphan_backend "${bs}"
    done

    ok "網域 '${domain}' 已卸下。"
    info "記得移除 DNS 的 A 記錄。"
}

# ==========================================
# 📋 list - 列出網域與規則
# ==========================================
cmd_list() {
    require_login
    resolve_project

    local certs cert domain status
    certs=$(list_lb_certs)
    if [ -z "${certs}" ]; then
        info "LB '${LB_NAME}' 尚未掛任何網域，請先 './lb.sh add_domain <網域>'。"
        return
    fi

    echo "📋 LB '${LB_NAME}'（專案: ${PROJECT_ID}，靜態 IP: $(get_static_ip)）"
    echo ""
    for cert in ${certs}; do
        domain=$(cert_domain_of "${cert}")
        status=$(gcloud compute ssl-certificates describe "${cert}" --global --project="${PROJECT_ID}" \
            --format="value(managed.status)" 2>/dev/null || true)
        echo "🌐 ${domain}（憑證: ${status:-未知}）"
        if [ -n "$(get_domain_rules "${domain}")" ]; then
            print_domain_rules "${domain}"
        else
            echo "   （尚未設定規則: ./lb.sh add_rule ${domain} / <服務>）"
        fi
        echo ""
    done
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
        echo "❌ 靜態 IP '${IP_NAME}' 不存在（請先 './lb.sh init'）"
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
    local certs cert domain cert_status
    certs=$(list_lb_certs)
    if [ -z "${certs}" ]; then
        echo "❌ 尚未掛任何網域（請 './lb.sh add_domain <網域>'）"
        FAILED=$((FAILED + 1))
    else
        for cert in ${certs}; do
            domain=$(cert_domain_of "${cert}")
            cert_status=$(gcloud compute ssl-certificates describe "${cert}" --global --project="${PROJECT_ID}" \
                --format="value(managed.status)" 2>/dev/null || true)
            if [ "${cert_status}" = "ACTIVE" ]; then
                echo "✅ SSL 憑證 '${domain}' 已簽發"
            else
                echo "⏳ SSL 憑證 '${domain}' 狀態: ${cert_status:-未知}"
                echo "   尚未簽發通常代表 DNS 還沒生效，請確認 A 記錄已指向 ${ip:-<靜態IP>}"
                FAILED=$((FAILED + 1))
            fi
        done
    fi

    echo ""
    if [ "${FAILED}" -eq 0 ]; then
        ok "LB 全部就緒。"
    else
        die "有 ${FAILED} 個項目未就緒。"
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
    [ -n "${ip}" ] || die "靜態 IP '${IP_NAME}' 不存在，請先執行 './lb.sh init'。"
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
    echo "⚠️  forwarding rules、proxies、URL maps、所有網域憑證、backend services、NEGs、靜態 IP"
    echo "⚠️  Cloud Run 服務本身不會被刪除，但所有網域將無法連到服務。"
    printf "確認刪除請輸入 LB 名稱（%s）: " "${LB_NAME}"
    read -r answer
    if [ "${answer}" != "${LB_NAME}" ]; then
        die "輸入不符，已取消刪除。"
    fi

    # 先反查這組 LB 的 backend services 與憑證，再依相依順序拆除
    local bs_list cert_list bs neg cert
    bs_list=$(get_lb_backend_services)
    cert_list=$(list_lb_certs)

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
    for cert in ${cert_list}; do
        if global_exists ssl-certificates "${cert}"; then
            gcloud compute ssl-certificates delete "${cert}" --global --project="${PROJECT_ID}" --quiet
            ok "已刪除 SSL 憑證 '${cert}'。"
        fi
    done
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
    info "記得移除各網域 DNS 的 A 記錄；服務若曾 lock，請用 './lb.sh unlock <服務>' 恢復直連。"
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
    init)
        cmd_init
        ;;
    add_domain)
        [ -n "${ARGS[1]:-}" ] || die "請指定網域，例如: ./lb.sh add_domain app.example.com"
        cmd_add_domain "${ARGS[1]}"
        ;;
    remove_domain)
        [ -n "${ARGS[1]:-}" ] || die "請指定網域，例如: ./lb.sh remove_domain app.example.com"
        cmd_remove_domain "${ARGS[1]}"
        ;;
    add_rule)
        [ -n "${ARGS[3]:-}" ] || die "用法: ./lb.sh add_rule <網域> <路徑> <服務>，例如: ./lb.sh add_rule app.example.com / my-frontend"
        cmd_add_rule "${ARGS[1]}" "${ARGS[2]}" "${ARGS[3]}"
        ;;
    remove_rule)
        [ -n "${ARGS[2]:-}" ] || die "用法: ./lb.sh remove_rule <網域> <路徑>"
        cmd_remove_rule "${ARGS[1]}" "${ARGS[2]}"
        ;;
    list)
        cmd_list
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
