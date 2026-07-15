#!/usr/bin/env bash

# public.sh - Cloud Run 服務公開存取管理工具
#
# 部署完成後若瀏覽器出現「Error: Forbidden」，代表服務尚未開放未驗證存取
# （部署時的 --allow-unauthenticated 可能被組織政策擋下而默默失效）。
#
# 用法:
#   ./public.sh open <服務>     開放公開存取（任何人可呼叫）
#   ./public.sh close <服務>    關閉公開存取（恢復 IAM 驗證）
#   ./public.sh status <服務>   查看目前公開狀態
#
# open 會先用標準做法授權 allUsers 呼叫；若被組織政策
# （constraints/iam.allowedPolicyMemberDomains，禁止授權給網域外成員）擋下，
# 自動改用 --no-invoker-iam-check 關閉 invoker IAM 檢查，效果相同且不受該政策影響。

set -eo pipefail

# ==========================================
# 🔧 全域設定（可用環境變數覆寫）
# ==========================================
REGION="${RUN_REGION:-asia-east1}"
PROJECT_ID="${RUN_PROJECT_ID:-}"

# ==========================================
# 🛠️ 共用函式
# ==========================================
usage() {
    cat << 'EOF'
用法: public.sh [-p <project-id>] [-r <region>] <指令> <服務>

指令:
  open <服務>     開放公開存取（任何人不需登入即可呼叫此服務）
  close <服務>    關閉公開存取（恢復 IAM 驗證，僅授權過的身份可呼叫）
  status <服務>   查看目前公開狀態

選項:
  -p, --project <id>    指定 GCP 專案 ID（預設: $RUN_PROJECT_ID 或 gcloud config 目前專案）
  -r, --region <區域>   服務所在區域（預設: $RUN_REGION 或 asia-east1）
  -h, --help            顯示此說明

環境變數:
  RUN_PROJECT_ID        預設專案 ID
  RUN_REGION            預設區域（asia-east1）

範例:
  ./public.sh open my-frontend
  ./public.sh status my-frontend
  ./public.sh -r us-central1 open my-api
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

require_service() {
    gcloud run services describe "$1" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null \
        || die "找不到 Cloud Run 服務 '$1'（區域: ${REGION}），請確認名稱與區域（gcloud run services list）。"
}

# 服務是否已授權 allUsers 呼叫（標準的公開存取做法）
has_allusers_binding() {
    gcloud run services get-iam-policy "$1" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --flatten="bindings[].members" \
        --filter="bindings.role:roles/run.invoker" \
        --format="value(bindings.members)" 2>/dev/null | grep -qx "allUsers"
}

# 服務是否已關閉 invoker IAM 檢查（--no-invoker-iam-check 的效果）
invoker_check_disabled() {
    gcloud run services describe "$1" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="json(metadata.annotations)" 2>/dev/null \
        | grep -q '"run.googleapis.com/invoker-iam-disabled": *"true"'
}

# ==========================================
# 🌐 open - 開放公開存取
# ==========================================
cmd_open() {
    local svc="$1" err
    require_login
    resolve_project
    require_service "${svc}"

    if has_allusers_binding "${svc}" || invoker_check_disabled "${svc}"; then
        ok "服務 '${svc}' 已是公開狀態，不需調整。"
        return
    fi

    info "授權 allUsers 呼叫服務 '${svc}'..."
    if err=$(gcloud run services add-iam-policy-binding "${svc}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --member="allUsers" \
        --role="roles/run.invoker" 2>&1 >/dev/null); then
        ok "服務 '${svc}' 已開放公開存取（allUsers + roles/run.invoker）。"
    elif echo "${err}" | grep -qi "allowedPolicyMemberDomains\|FAILED_PRECONDITION\|violates.*constraint"; then
        # 組織政策禁止授權給網域外成員（allUsers 也算），改關 invoker IAM 檢查
        info "組織政策不允許授權 allUsers，改用 --no-invoker-iam-check..."
        gcloud run services update "${svc}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --no-invoker-iam-check
        ok "服務 '${svc}' 已開放公開存取（invoker IAM 檢查已關閉）。"
    else
        echo "${err}" >&2
        die "授權失敗，請檢查上方錯誤訊息。"
    fi

    echo ""
    echo "⚠️  此服務現在任何人都能呼叫，設定約數十秒內生效。"
    echo "   若前面有掛 LB（lb.sh），建議執行 lock 關閉 run.app 直連："
    echo "   ../lb/lb.sh lock ${svc}"
}

# ==========================================
# 🔒 close - 關閉公開存取
# ==========================================
cmd_close() {
    local svc="$1" changed=0
    require_login
    resolve_project
    require_service "${svc}"

    if has_allusers_binding "${svc}"; then
        gcloud run services remove-iam-policy-binding "${svc}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --member="allUsers" \
            --role="roles/run.invoker" >/dev/null
        ok "已移除 allUsers 的呼叫授權。"
        changed=1
    fi

    if invoker_check_disabled "${svc}"; then
        gcloud run services update "${svc}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --invoker-iam-check
        ok "已恢復 invoker IAM 檢查。"
        changed=1
    fi

    if [ "${changed}" -eq 1 ]; then
        ok "服務 '${svc}' 已關閉公開存取，僅授權過的身份可呼叫。"
    else
        ok "服務 '${svc}' 本來就未開放公開存取，不需調整。"
    fi
}

# ==========================================
# 🔍 status - 查看公開狀態
# ==========================================
cmd_status() {
    local svc="$1" pub=0
    require_login
    resolve_project
    require_service "${svc}"

    echo "服務 '${svc}'（區域: ${REGION}）："
    if has_allusers_binding "${svc}"; then
        echo "   ✔ allUsers 具有 roles/run.invoker（標準公開授權）"
        pub=1
    else
        echo "   ✘ 未授權 allUsers 呼叫"
    fi
    if invoker_check_disabled "${svc}"; then
        echo "   ✔ invoker IAM 檢查已關閉（--no-invoker-iam-check）"
        pub=1
    else
        echo "   ✘ invoker IAM 檢查為開啟狀態"
    fi

    echo ""
    if [ "${pub}" -eq 1 ]; then
        echo "🌐 目前狀態：公開，任何人可呼叫。"
    else
        echo "🔒 目前狀態：未公開，未驗證的請求會收到 403 Forbidden。"
        echo "   開放方式: ./public.sh open ${svc}"
    fi
}

# ==========================================
# 🚀 主程式
# ==========================================
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            PROJECT_ID="$2"
            shift 2
            ;;
        -r|--region)
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

COMMAND="${ARGS[0]:-}"
case "${COMMAND}" in
    open|close|status)
        [ -n "${ARGS[1]:-}" ] || die "請指定服務名稱，例如: ./public.sh ${COMMAND} my-frontend"
        "cmd_${COMMAND}" "${ARGS[1]}"
        ;;
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
