#!/usr/bin/env bash
# Step 1 - IAM policies, ECR repositories, then VPC + EKS cluster + node group
# with eksctl (15-20 min). Run scripts/00-configure.sh first.
source "$(dirname "$0")/lib.sh"
need aws eksctl kubectl
! grep -q '__[A-Z0-9_]*__' eksctl/cluster.yaml || die "run scripts/00-configure.sh first"
ACCOUNT_ID=$(account_id)

say "1. IAM policies for the controllers"
for p in lbc:aws-load-balancer-controller external-dns:external-dns; do
  name="$CLUSTER-${p%%:*}"; file="policies/${p#*:}.json"
  if aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$name" >/dev/null 2>&1; then
    echo "  $name exists"
  else
    aws iam create-policy --policy-name "$name" --policy-document "file://$file" >/dev/null
    echo "  $name created"
  fi
done

say "2. ECR repositories"
for r in bmi-backend bmi-frontend; do
  aws ecr describe-repositories --repository-names "$CLUSTER/$r" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$CLUSTER/$r" \
      --image-scanning-configuration scanOnPush=true >/dev/null
  echo "  $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$CLUSTER/$r"
done

say "3. EKS cluster (eksctl, ~15-20 min)"
if eksctl get cluster --name "$CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "  cluster exists - skipping create"
else
  eksctl create cluster -f eksctl/cluster.yaml
fi
kubeconfig
kubectl get nodes -o wide

echo -e "\nNext: bash scripts/02-install-platform.sh"
