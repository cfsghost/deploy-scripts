#!/usr/bin/env bash

# wif.sh - GCP Workload Identity Federation 管理工具（GitHub Actions 部署 Cloud Run 用）
#
# 用法:
#   ./wif.sh init                初始化 GCP 環境（啟用 API、建立 Artifact Registry / SA / WIF Pool / Provider）
#   ./wif.sh check               檢查環境設定與帳號權限是否就緒
#   ./wif.sh list                列出目前已授權部署的 GitHub repos
#   ./wif.sh add <owner/repo>    授權新的 GitHub repo 透過 WIF 部署
#   ./wif.sh remove <owner/repo> 移除 GitHub repo 的部署授權
#   ./wif.sh env                 輸出 GitHub Actions deploy.yaml 所需的 env 區塊
#   ./wif.sh generate_github_workflow <main|tag>
#                                產生已填好設定的 deploy.yaml（main=push 觸發, tag=v* tag 觸發）

set -eo pipefail

# ==========================================
# 🔧 全域設定（可用環境變數覆寫）
# ==========================================
REGION="${WIF_REGION:-asia-east1}"
SUFFIX="${WIF_SUFFIX:-go-run}"   # 需與初始化時使用的後綴一致
AR_REPO="repo-${SUFFIX}"
SA_NAME="sa-${SUFFIX}"
POOL_NAME="pool-${SUFFIX}"
PROVIDER_NAME="provider-${SUFFIX}"

PROJECT_ID="${WIF_PROJECT_ID:-}"
VPC_NETWORK=""   # --vpc 選項：generate_github_workflow 產生的部署設定加上 VPC egress

# init 需要的完整權限
INIT_PERMISSIONS=(
    "serviceusage.services.enable"
    "artifactregistry.repositories.create"
    "artifactregistry.repositories.get"
    "artifactregistry.repositories.setIamPolicy"
    "iam.serviceAccounts.create"
    "iam.serviceAccounts.get"
    "iam.serviceAccounts.setIamPolicy"
    "iam.workloadIdentityPools.create"
    "iam.workloadIdentityPools.get"
    "iam.workloadIdentityPoolProviders.create"
    "iam.workloadIdentityPoolProviders.get"
    "resourcemanager.projects.get"
    "resourcemanager.projects.setIamPolicy"
)

# add / remove 只需要能改 Service Account 的 IAM policy
BIND_PERMISSIONS=(
    "iam.serviceAccounts.getIamPolicy"
    "iam.serviceAccounts.setIamPolicy"
)

# ==========================================
# 🛠️ 共用函式
# ==========================================
usage() {
    cat << 'EOF'
用法: wif.sh [-p <project-id>] <指令>

指令:
  init                 初始化 GCP 環境（啟用 API、建立 Artifact Registry / SA / WIF Pool / Provider）
  check                檢查環境設定與帳號權限是否就緒
  list                 列出目前已授權部署的 GitHub repos
  add <owner/repo>     授權新的 GitHub repo 透過 WIF 部署
  remove <owner/repo>  移除 GitHub repo 的部署授權
  env                  輸出 GitHub Actions deploy.yaml 所需的 env 區塊
  generate_github_workflow <main|tag> [檔案]
                       產生已填好 env 的 GitHub Actions deploy.yaml（預設輸出到 ./deploy.yaml）
                       main: push 到 main 分支時觸發部署
                       tag:  推送 v 開頭的 tag（如 v1.0.0）時觸發部署

選項:
  -p, --project <id>   指定 GCP 專案 ID（預設: $WIF_PROJECT_ID 或 gcloud config 目前專案）
  --vpc <VPC名稱>      generate_github_workflow 時加上 VPC egress 設定
                       （服務需連 private IP Cloud SQL 時使用，通常是 default）
  -h, --help           顯示此說明

環境變數:
  WIF_PROJECT_ID       預設專案 ID
  WIF_REGION           部署區域（預設: asia-east1）
  WIF_SUFFIX           元件命名後綴（預設: go-run，需與初始化時一致）

範例:
  ./wif.sh -p my-project init
  ./wif.sh add fred/go-api
  ./wif.sh list
  ./wif.sh generate_github_workflow tag
  ./wif.sh --vpc default generate_github_workflow main
EOF
}

die() { echo "❌ 錯誤: $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }
ok() { echo "✅ $*"; }

# 新建的 Service Account 在 IAM 各服務間同步需要幾秒到幾十秒，
# 綁定太快會回 "does not exist"，失敗時等待後重試
retry_iam() {
    local n=0 max=6 err
    until err=$("$@" 2>&1 >/dev/null); do
        n=$((n + 1))
        if [ "${n}" -ge "${max}" ]; then
            echo "${err}" >&2
            return 1
        fi
        info "IAM 尚未同步到新建的 Service Account，10 秒後重試（${n}/$((max - 1))）..."
        sleep 10
    done
}

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
    SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
}

resolve_project_number() {
    PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)") \
        || die "無法讀取專案 '${PROJECT_ID}'，請確認專案 ID 正確且帳號有存取權。"
}

require_sa() {
    gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null \
        || die "找不到 Service Account '${SA_EMAIL}'，請先執行 './wif.sh init'。"
}

repo_member() {
    echo "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/$1"
}

# 檢查目前帳號在專案上是否擁有指定權限，缺少的存入 MISSING_PERMISSIONS
# 回傳值: 0=齊全 1=有缺 2=無法檢查
check_permissions() {
    MISSING_PERMISSIONS=()

    local perm_json
    perm_json=$(printf '"%s",' "$@")
    perm_json="[${perm_json%,}]"

    # testIamPermissions 回傳「目前帳號實際擁有」的權限子集，本身不需要特殊權限
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $(gcloud auth print-access-token)" \
        -H "Content-Type: application/json" \
        "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" \
        -d "{\"permissions\": ${perm_json}}") || return 2

    if echo "${response}" | grep -q '"error"'; then
        return 2
    fi

    local perm
    for perm in "$@"; do
        if ! echo "${response}" | grep -q "\"${perm}\""; then
            MISSING_PERMISSIONS+=("${perm}")
        fi
    done

    [ ${#MISSING_PERMISSIONS[@]} -eq 0 ]
}

# 權限不足時直接擋下並列出缺少的權限
require_permissions() {
    local rc=0
    check_permissions "$@" || rc=$?

    if [ "${rc}" -eq 2 ]; then
        echo "⚠️  警告: 無法完成權限檢查（testIamPermissions 呼叫失敗），將直接繼續執行。"
        return 0
    fi

    if [ "${rc}" -ne 0 ]; then
        echo "" >&2
        echo "❌ 錯誤: 目前帳號在專案 '${PROJECT_ID}' 缺少以下 ${#MISSING_PERMISSIONS[@]} 項權限：" >&2
        printf '   - %s\n' "${MISSING_PERMISSIONS[@]}" >&2
        echo "" >&2
        echo "請專案管理員授予以下對應角色（或直接授予 roles/owner）：" >&2
        echo "   - roles/serviceusage.serviceUsageAdmin   （啟用 API）" >&2
        echo "   - roles/artifactregistry.admin           （管理 Artifact Registry）" >&2
        echo "   - roles/iam.serviceAccountAdmin          （管理 Service Account）" >&2
        echo "   - roles/iam.workloadIdentityPoolAdmin    （管理 WIF Pool / Provider）" >&2
        echo "   - roles/resourcemanager.projectIamAdmin  （綁定專案層級 IAM）" >&2
        exit 1
    fi
    ok "權限檢查通過。"
}

print_env_block() {
    local wif_provider="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/providers/${PROVIDER_NAME}"
    cat << EOF

請將以下內容填入 GitHub Actions workflow (.github/workflows/deploy.yaml) 的 env 區塊：
--------------------------------------------------------------------------
env:
  PROJECT_ID: '${PROJECT_ID}'
  REGION: '${REGION}'
  GAR_REPO: '${AR_REPO}'
  WIF_PROVIDER: '${wif_provider}'
  WIF_SERVICE_ACCOUNT: '${SA_EMAIL}'
--------------------------------------------------------------------------
EOF
}

# ==========================================
# 🚀 init - 初始化 GCP 環境
# ==========================================
cmd_init() {
    require_login
    resolve_project
    echo "🚀 開始初始化專案 '${PROJECT_ID}' 的 WIF 部署環境"
    resolve_project_number

    echo "[1/5] 權限預檢..."
    require_permissions "${INIT_PERMISSIONS[@]}"

    echo "[2/5] 啟用 GCP 服務 API (這可能需要幾十秒)..."
    gcloud services enable \
        run.googleapis.com \
        artifactregistry.googleapis.com \
        iam.googleapis.com \
        iamcredentials.googleapis.com \
        --project="${PROJECT_ID}"

    echo "[3/5] 建立 Artifact Registry 倉庫..."
    if gcloud artifacts repositories describe "${AR_REPO}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        info "倉庫 '${AR_REPO}' 已存在，跳過建立步驟。"
    else
        gcloud artifacts repositories create "${AR_REPO}" \
            --repository-format=docker \
            --location="${REGION}" \
            --project="${PROJECT_ID}" \
            --description="Docker repository for Cloud Run deploys"
    fi

    echo "[4/5] 建立 Service Account 與 IAM 權限..."
    if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
        info "Service Account '${SA_EMAIL}' 已存在，跳過建立步驟。"
    else
        gcloud iam service-accounts create "${SA_NAME}" \
            --display-name="GitHub Actions Cloud Run Deployer" \
            --project="${PROJECT_ID}"
    fi

    retry_iam gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/artifactregistry.writer" \
        --quiet

    # 使用 run.admin 而非 run.developer：deploy.yaml 的 --allow-unauthenticated
    # 需要 run.services.setIamPolicy 權限，run.developer 沒有
    retry_iam gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/run.admin" \
        --quiet

    retry_iam gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/iam.serviceAccountUser" \
        --quiet

    echo "[5/5] 建立 WIF Pool 與 Provider..."
    if gcloud iam workload-identity-pools describe "${POOL_NAME}" --location="global" --project="${PROJECT_ID}" &>/dev/null; then
        info "Identity Pool '${POOL_NAME}' 已存在。"
    else
        gcloud iam workload-identity-pools create "${POOL_NAME}" \
            --location="global" \
            --project="${PROJECT_ID}" \
            --display-name="GitHub Actions Pool"
    fi

    if gcloud iam workload-identity-pools providers describe "${PROVIDER_NAME}" --location="global" --workload-identity-pool="${POOL_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
        info "Identity Provider '${PROVIDER_NAME}' 已存在。"
    else
        gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_NAME}" \
            --location="global" \
            --workload-identity-pool="${POOL_NAME}" \
            --project="${PROJECT_ID}" \
            --display-name="GitHub Provider" \
            --attribute-mapping="google.subject=assertion.subject,attribute.repository=assertion.repository" \
            --issuer-uri="https://token.actions.githubusercontent.com"
    fi

    echo ""
    ok "初始化完成！接下來請用 './wif.sh add <owner/repo>' 授權要部署的 GitHub repo。"
}

# ==========================================
# 🔍 check - 檢查環境狀態
# ==========================================
cmd_check() {
    require_login
    resolve_project
    echo "🔍 檢查專案 '${PROJECT_ID}' 的 WIF 部署環境："
    local fail=0

    if PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null); then
        ok "專案可存取（project number: ${PROJECT_NUMBER}）"
    else
        echo "❌ 無法存取專案 '${PROJECT_ID}'"
        fail=1
    fi

    local enabled_apis api
    enabled_apis=$(gcloud services list --enabled --project="${PROJECT_ID}" --format="value(config.name)" 2>/dev/null || true)
    for api in run.googleapis.com artifactregistry.googleapis.com iam.googleapis.com iamcredentials.googleapis.com; do
        if echo "${enabled_apis}" | grep -q "^${api}$"; then
            ok "API 已啟用: ${api}"
        else
            echo "❌ API 未啟用: ${api}"
            fail=1
        fi
    done

    if gcloud artifacts repositories describe "${AR_REPO}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        ok "Artifact Registry 倉庫存在: ${AR_REPO} (${REGION})"
    else
        echo "❌ Artifact Registry 倉庫不存在: ${AR_REPO} (${REGION})"
        fail=1
    fi

    if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
        ok "Service Account 存在: ${SA_EMAIL}"
    else
        echo "❌ Service Account 不存在: ${SA_EMAIL}"
        fail=1
    fi

    if gcloud iam workload-identity-pools describe "${POOL_NAME}" --location="global" --project="${PROJECT_ID}" &>/dev/null; then
        ok "Identity Pool 存在: ${POOL_NAME}"
    else
        echo "❌ Identity Pool 不存在: ${POOL_NAME}"
        fail=1
    fi

    if gcloud iam workload-identity-pools providers describe "${PROVIDER_NAME}" --location="global" --workload-identity-pool="${POOL_NAME}" --project="${PROJECT_ID}" &>/dev/null; then
        ok "Identity Provider 存在: ${PROVIDER_NAME}"
    else
        echo "❌ Identity Provider 不存在: ${PROVIDER_NAME}"
        fail=1
    fi

    local rc=0
    check_permissions "${INIT_PERMISSIONS[@]}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        ok "帳號權限齊全（具備執行 init 所需的全部權限）"
    elif [ "${rc}" -eq 2 ]; then
        echo "⚠️  無法檢查帳號權限（testIamPermissions 呼叫失敗）"
    else
        echo "❌ 帳號缺少以下權限："
        printf '   - %s\n' "${MISSING_PERMISSIONS[@]}"
        fail=1
    fi

    echo ""
    if [ "${fail}" -ne 0 ]; then
        echo "⚠️  部分項目未就緒，可執行 './wif.sh init' 進行初始化。"
        exit 1
    fi
    ok "環境已就緒，可用 './wif.sh add <owner/repo>' 授權 repo。"
}

# ==========================================
# 📋 list - 列出已授權的 repos
# ==========================================
cmd_list() {
    require_login
    resolve_project
    require_sa

    local repos
    repos=$(gcloud iam service-accounts get-iam-policy "${SA_EMAIL}" --project="${PROJECT_ID}" --format=json \
        | grep -o 'attribute\.repository/[^"]*' | sed 's|attribute\.repository/||' | sort -u || true)

    echo "📋 已授權部署的 GitHub repos（專案: ${PROJECT_ID}）："
    if [ -z "${repos}" ]; then
        info "目前沒有任何 repo 被授權，可用 './wif.sh add <owner/repo>' 加入。"
    else
        echo "${repos}" | sed 's/^/   - /'
    fi
}

# ==========================================
# ➕ add - 授權新的 repo
# ==========================================
cmd_add() {
    local repo="$1"
    [[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
        || die "repo 格式錯誤，需為 <owner>/<repo>，例如: fred/go-api"

    require_login
    resolve_project
    require_sa
    resolve_project_number
    require_permissions "${BIND_PERMISSIONS[@]}"

    gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
        --project="${PROJECT_ID}" \
        --role="roles/iam.workloadIdentityUser" \
        --member="$(repo_member "${repo}")" \
        --quiet >/dev/null

    ok "已授權 repo '${repo}' 透過 WIF 部署。"
    print_env_block
}

# ==========================================
# ➖ remove - 移除 repo 授權
# ==========================================
cmd_remove() {
    local repo="$1"
    [[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
        || die "repo 格式錯誤，需為 <owner>/<repo>，例如: fred/go-api"

    require_login
    resolve_project
    require_sa
    resolve_project_number
    require_permissions "${BIND_PERMISSIONS[@]}"

    if gcloud iam service-accounts remove-iam-policy-binding "${SA_EMAIL}" \
        --project="${PROJECT_ID}" \
        --role="roles/iam.workloadIdentityUser" \
        --member="$(repo_member "${repo}")" \
        --quiet >/dev/null 2>&1; then
        ok "已移除 repo '${repo}' 的部署授權。"
    else
        die "移除失敗，repo '${repo}' 可能原本就未被授權（可用 './wif.sh list' 確認）。"
    fi
}

# ==========================================
# 📝 generate_github_workflow - 產生已填好設定的 GitHub Actions deploy.yaml
# ==========================================
cmd_generate_github_workflow() {
    local trigger="$1"
    local output="${2:-deploy.yaml}"

    case "${trigger}" in
        main|tag) ;;
        *) die "觸發模式需為 'main'（push 到 main 觸發）或 'tag'（推送 v* tag 觸發）。" ;;
    esac

    require_login
    resolve_project
    resolve_project_number

    if [ -e "${output}" ]; then
        die "檔案 '${output}' 已存在，請先移除或指定其他輸出路徑，例如: ./wif.sh generate_github_workflow ${trigger} my-deploy.yaml"
    fi

    local wif_provider="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/providers/${PROVIDER_NAME}"

    # tag 模式用 tag 名稱當 image 版本，main 模式用 commit SHA
    local image_tag_expr
    if [ "${trigger}" = "tag" ]; then
        image_tag_expr='${{ github.ref_name }}'
    else
        image_tag_expr='${{ github.sha }}'
    fi

    # 指定 --vpc 時加上 VPC egress，讓服務連得到 VPC 內的 private IP 資源（如 Cloud SQL）
    # subnet 沿用 VPC 同名（auto-mode VPC 如 default 均適用）
    local deploy_flags="--allow-unauthenticated"
    if [ -n "${VPC_NETWORK}" ]; then
        deploy_flags="${deploy_flags} --network=${VPC_NETWORK} --subnet=${VPC_NETWORK} --vpc-egress=private-ranges-only"
    fi

    {
        echo "name: Deploy to Cloud Run"
        echo ""
        if [ "${trigger}" = "main" ]; then
            cat << 'YAML'
on:
  push:
    branches:
      - main
YAML
        else
            cat << 'YAML'
on:
  push:
    tags:
      - 'v*'  # 推送 v 開頭的 tag 時觸發部署，例如 v1.0.0
YAML
        fi

        cat << YAML

env:
  PROJECT_ID: '${PROJECT_ID}'
  REGION: '${REGION}'
  GAR_REPO: '${AR_REPO}'
  # SERVICE_NAME 會自動取自 GitHub repo 名稱（見下方 Set Service Name 步驟）
  WIF_PROVIDER: '${wif_provider}'
  WIF_SERVICE_ACCOUNT: '${SA_EMAIL}'
YAML

        cat << 'YAML'

jobs:
  deploy:
    runs-on: ubuntu-latest

    # 允許向 GitHub 取得 OIDC Token，Workload Identity 必需
    permissions:
      contents: 'read'
      id-token: 'write'

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    # 從 GitHub repo 名稱生成 Cloud Run 服務名稱
    # Cloud Run 只允許小寫字母、數字、連字號，因此將大寫轉小寫、底線和點轉為連字號
    - name: Set Service Name
      run: |
        SERVICE_NAME=$(echo "${{ github.event.repository.name }}" | tr '[:upper:]' '[:lower:]' | tr '_.' '-')
        echo "SERVICE_NAME=$SERVICE_NAME" >> $GITHUB_ENV

    # 透過 OIDC 登入 Google Cloud
    - name: Google Auth
      id: auth
      uses: google-github-actions/auth@v2
      with:
        workload_identity_provider: ${{ env.WIF_PROVIDER }}
        service_account: ${{ env.WIF_SERVICE_ACCOUNT }}

    # 登入 Artifact Registry
    - name: Docker Auth
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGION }}-docker.pkg.dev
        username: oauth2accesstoken
        password: ${{ steps.auth.outputs.access_token }}

    # 建置並推送到 Artifact Registry
    - name: Build and Push Container
      run: |
YAML
        printf '        IMAGE_TAG="${{ env.REGION }}-docker.pkg.dev/${{ env.PROJECT_ID }}/${{ env.GAR_REPO }}/${{ env.SERVICE_NAME }}:%s"\n' "${image_tag_expr}"
        cat << 'YAML'
        docker build -t $IMAGE_TAG .
        docker push $IMAGE_TAG
        echo "IMAGE_TAG=$IMAGE_TAG" >> $GITHUB_ENV

    # 部署到 Cloud Run
    - name: Deploy to Cloud Run
      uses: google-github-actions/deploy-cloudrun@v2
      with:
        service: ${{ env.SERVICE_NAME }}
        region: ${{ env.REGION }}
        image: ${{ env.IMAGE_TAG }}
        # 需要傳環境變數給服務時，可打開以下設定；機密值可引用 GitHub Secrets
        # （用 gcp/cloudsql 的 './sql.sh generate_github_secrets <owner>/<repo>' 一次設定好）：
        # env_vars: |
        #   APP_ENV=production
        #   DB_HOST=${{ secrets.DB_HOST }}
        #   DB_PORT=${{ secrets.DB_PORT }}
        #   DB_NAME=${{ secrets.DB_NAME }}
        #   DB_USER=${{ secrets.DB_USER }}
        #   DB_PASSWORD=${{ secrets.DB_PASSWORD }}
        # 機密若改放 GCP Secret Manager，則改用 secrets 參數掛載：
        # secrets: |
        #   DB_PASSWORD=db-password:latest
        # 公開 API 才需要 allow-unauthenticated，內部微服務請移除
YAML
        printf "        flags: '%s'\n" "${deploy_flags}"
    } > "${output}"

    ok "已產生 '${output}'（觸發模式: ${trigger}，專案: ${PROJECT_ID}）。"
    echo ""
    echo "接下來："
    echo "   1. 將此檔案放到目標 repo 的 .github/workflows/deploy.yaml"
    if [ "${trigger}" = "tag" ]; then
        echo "   2. 推送 v 開頭的 tag 即觸發部署，例如:"
        echo "      git tag v1.0.0 && git push origin v1.0.0"
    else
        echo "   2. push 到 main 分支即觸發部署。"
    fi
    echo "   （記得先用 './wif.sh add <owner>/<repo>' 授權該 repo）"
}

# ==========================================
# 📤 env - 輸出 deploy.yaml 的 env 區塊
# ==========================================
cmd_env() {
    require_login
    resolve_project
    resolve_project_number
    print_env_block
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
        --vpc)
            [ -n "${2:-}" ] || die "選項 '$1' 需要參數。"
            VPC_NETWORK="$2"
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
    init)   cmd_init ;;
    check)  cmd_check ;;
    list)   cmd_list ;;
    add)
        [ -n "${ARGS[1]:-}" ] || die "請指定 repo，例如: ./wif.sh add fred/go-api"
        cmd_add "${ARGS[1]}"
        ;;
    remove)
        [ -n "${ARGS[1]:-}" ] || die "請指定 repo，例如: ./wif.sh remove fred/go-api"
        cmd_remove "${ARGS[1]}"
        ;;
    env)    cmd_env ;;
    generate_github_workflow)
        [ -n "${ARGS[1]:-}" ] || die "請指定觸發模式，例如: ./wif.sh generate_github_workflow main 或 ./wif.sh generate_github_workflow tag"
        cmd_generate_github_workflow "${ARGS[1]}" "${ARGS[2]:-}"
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
