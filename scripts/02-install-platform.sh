#!/usr/bin/env bash
# Step 2 - platform on the cluster: gp3 StorageClass, AWS Load Balancer Controller,
# ExternalDNS, Prometheus Operator CRDs, Argo CD, app + Grafana secrets, and the Argo CD
# root app. Argo CD then deploys the app AND the observability stack
# (kube-prometheus-stack, Loki, Alloy) from gitops/.
# Idempotent: re-run any time (helm upgrade --install).
source "$(dirname "$0")/lib.sh"
need aws kubectl helm curl openssl
! grep -rq '__[A-Z0-9_]*__' platform gitops || die "run scripts/00-configure.sh first (and git push)"
check_clock
kubeconfig
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)

say "1. Default StorageClass gp3"
kubectl apply -f platform/storageclass-gp3.yaml
# eksctl/EKS may also ship a 'gp2' default; keep only one default.
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite 2>/dev/null || true

say "2. Gateway API CRDs (the LB Controller v3 expects them before it starts)"
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/config/crd/gateway/gateway-crds.yaml

say "3. AWS Load Balancer Controller"
helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts -n kube-system \
  --set clusterName="$CLUSTER" --set region="$AWS_REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 10m
# Its webhook must answer before anything creates a Service/Ingress.
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=300s

say "4. ExternalDNS (Route 53 records for every Ingress host)"
helm upgrade --install external-dns external-dns \
  --repo https://kubernetes-sigs.github.io/external-dns/ -n external-dns --create-namespace \
  -f platform/external-dns-values.yaml --wait --timeout 5m

say "5. Prometheus Operator CRDs (ServiceMonitor, PrometheusRule, ...)"
# Installed before Argo CD so Argo CD's own ServiceMonitors (argocd-values.yaml) can be
# created. kube-prometheus-stack then runs with crds.enabled=false.
helm upgrade --install prometheus-operator-crds prometheus-operator-crds \
  --repo https://prometheus-community.github.io/helm-charts --version 33.0.1 \
  -n observability --create-namespace --wait

say "6. Argo CD"
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm -n argocd --create-namespace \
  -f platform/argocd-values.yaml --wait --timeout 10m

say "7. Secrets (generated once, never in Git)"
kubectl create namespace bmi-app --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n bmi-app get secret postgres-secret >/dev/null 2>&1; then
  DB_PASS=$(openssl rand -hex 16)   # hex = safe inside DATABASE_URL
  kubectl -n bmi-app create secret generic postgres-secret \
    --from-literal=POSTGRES_DB=bmidb --from-literal=POSTGRES_USER=bmi_user \
    --from-literal=POSTGRES_PASSWORD="$DB_PASS"
  kubectl -n bmi-app create secret generic backend-secret \
    --from-literal=DATABASE_URL="postgres://bmi_user:$DB_PASS@bmi-postgres-svc:5432/bmidb"
  echo "  app secrets created"
else
  echo "  app secrets exist - keeping them (the database already uses that password)"
fi
if ! kubectl -n observability get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n observability create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -hex 12)"
  echo "  grafana-admin created"
else
  echo "  grafana-admin exists - keeping it"
fi

say "8. Argo CD root application (app-of-apps)"
kubectl apply -f gitops/argocd/root-app.yaml

ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
GRAFANA_PASS=$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
cat <<EOF

Done. Argo CD now syncs $GIT_REPO_URL ($GIT_BRANCH):
  bmi-app, kube-prometheus-stack, loki, alloy, observability-extras   (first sync ~3-5 min)
  watch: kubectl -n argocd get applications -w

  Argo CD : https://$ARGOCD_HOST    admin / $ARGO_PASS
  Grafana : https://$GRAFANA_HOST   admin / $GRAFANA_PASS
            (DNS can take 2-5 min; or kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80)
  App     : https://$APP_HOST  (after the first image release)

Next: bash scripts/03-release.sh   # build + push images, bump tag in Git -> Argo CD deploys
EOF
