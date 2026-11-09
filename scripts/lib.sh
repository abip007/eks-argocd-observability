# Shared helpers - sourced by every script, not run directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=config.env
source "$ROOT/scripts/config.env"

# Private Helm repo config/cache: a stale global ~/.cache or %TEMP% helm cache
# otherwise breaks installs with "no cached repo found".
export HELM_REPOSITORY_CONFIG="$ROOT/.helm/repositories.yaml"
export HELM_REPOSITORY_CACHE="$ROOT/.helm/cache"
mkdir -p "$ROOT/.helm/cache"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
need() { for t in "$@"; do command -v "$t" >/dev/null || die "'$t' not found on PATH"; done; }

account_id() { aws sts get-caller-identity --query Account --output text; }

kubeconfig() {
  aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" >/dev/null
  kubectl get nodes >/dev/null || die "cannot reach cluster $CLUSTER"
}

# Helm signs the LB Controller webhook certificate with YOUR clock. If your PC
# is ahead of AWS, the cert is "not yet valid" and later installs fail with
# x509 errors on mservice.elbv2.k8s.aws. Stop early instead.
check_clock() {
  local aws_date skew
  aws_date=$(curl -sI "https://sts.$AWS_REGION.amazonaws.com" | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2}')
  [ -n "$aws_date" ] || { echo "  (could not read AWS time, skipping clock check)"; return 0; }
  skew=$(( $(date -u +%s) - $(date -u -d "$aws_date" +%s) ))
  echo "  local clock vs AWS: ${skew}s"
  [ "${skew#-}" -le 5 ] || die "clock is off by ${skew}s. Windows (admin PowerShell): Start-Service w32time; w32tm /resync /force"
}

# Finds an ISSUED ACM certificate covering DOMAIN and *.DOMAIN, or prints nothing.
find_cert() {
  aws acm list-certificates --region "$AWS_REGION" --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='$DOMAIN' || DomainName=='*.$DOMAIN'].CertificateArn | [0]" \
    --output text | grep -v '^None$' || true
}
