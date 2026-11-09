#!/usr/bin/env bash
# Delete everything created by the shell-script path, in the safe order:
# Argo CD apps first (so the LB Controller deletes the ALB and the EBS volumes
# are released), then the cluster/VPC, then ECR and IAM policies.
# The ACM certificate and Route 53 zone are kept (shared with other projects).
source "$(dirname "$0")/lib.sh"
need aws eksctl kubectl helm
read -r -p "Delete cluster '$CLUSTER' and ALL its data? Type the cluster name: " ok
[ "$ok" = "$CLUSTER" ] || die "aborted"
ACCOUNT_ID=$(account_id)

if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  kubeconfig
  say "1. Argo CD apps (cascade to Ingresses/ALB rules and pods)"
  kubectl -n argocd delete application root --ignore-not-found --wait=true --timeout=10m || true
  for app in bmi-app observability-extras alloy loki kube-prometheus-stack; do
    kubectl -n argocd delete application "$app" --ignore-not-found --wait=true --timeout=10m || true
  done
  # StatefulSet PVCs (Postgres, Prometheus, Alertmanager, Loki) are never pruned by Argo CD;
  # deleting the namespaces frees the EBS volumes.
  kubectl delete namespace bmi-app observability --ignore-not-found --wait=true --timeout=10m || true
  say "2. Argo CD Ingress + charts"
  helm -n argocd uninstall argocd --wait 2>/dev/null || true
  echo "  waiting 60 s for the ALB to be deleted..."; sleep 60
  helm -n external-dns uninstall external-dns 2>/dev/null || true
  helm -n kube-system uninstall aws-load-balancer-controller 2>/dev/null || true
  say "3. Cluster + VPC (eksctl, ~10-15 min)"
  eksctl delete cluster -f eksctl/cluster.yaml --wait --disable-nodegroup-eviction
fi

say "4. ECR repositories"
for r in bmi-backend bmi-frontend; do
  aws ecr delete-repository --repository-name "$CLUSTER/$r" --force >/dev/null 2>&1 && echo "  $CLUSTER/$r deleted" || true
done

say "5. IAM policies"
for p in lbc external-dns; do
  aws iam delete-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-$p" 2>/dev/null && echo "  $CLUSTER-$p deleted" || true
done

echo -e "\nDone. ExternalDNS ran upsert-only: delete the A/TXT records for $APP_HOST, $ARGOCD_HOST and $GRAFANA_HOST in Route 53 if they remain."
