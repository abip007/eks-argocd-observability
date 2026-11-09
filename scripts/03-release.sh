#!/usr/bin/env bash
# Step 3 (and every update) - build + push both images, write the new tag into
# gitops/bmi-app/overlays/prod/kustomization.yaml, commit and push.
# Argo CD sees the commit (within ~60 s) and rolls the app out. No kubectl.
source "$(dirname "$0")/lib.sh"
need aws docker git sed
REGISTRY="$(account_id).dkr.ecr.$AWS_REGION.amazonaws.com"
OVERLAY=gitops/bmi-app/overlays/prod/kustomization.yaml
! grep -q '__[A-Z0-9_]*__' "$OVERLAY" || die "run scripts/00-configure.sh first"

TAG="$(git rev-parse --short HEAD 2>/dev/null || echo manual)-$(date +%Y%m%d%H%M%S)"

say "1. Build and push images ($TAG, linux/amd64)"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
for c in backend frontend; do
  docker build --platform linux/amd64 -t "$REGISTRY/$CLUSTER/bmi-$c:$TAG" "app/$c"
  docker push "$REGISTRY/$CLUSTER/bmi-$c:$TAG"
done

say "2. Bump image tags in Git"
# Every 'newTag:' line in the overlay belongs to our two images.
sed -i -E "s|^(\s*newTag:).*|\1 $TAG|" "$OVERLAY"
grep -n newTag "$OVERLAY"
git add "$OVERLAY"
git commit -m "release: bmi images $TAG"
git push origin "HEAD:$GIT_BRANCH"

cat <<EOF

Pushed. Argo CD syncs within ~60 s. Watch it:
  kubectl -n argocd get application bmi-app -w
  kubectl -n bmi-app get pods -w
Then open https://$APP_HOST, and watch the rollout in Grafana: https://$GRAFANA_HOST (dashboard BMI / BMI app)
EOF
