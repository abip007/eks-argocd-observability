# Build everything from the command line (step by step)

This guide does exactly what `scripts/00-…` to `scripts/99-…` do, but **one command at a time**,
and explains what each command does and how to check it worked. It covers the whole platform:
IAM, Route 53, ACM, the EKS cluster, the controllers, Argo CD, the app, **and the observability
stack** (Prometheus, Alertmanager, Grafana, Loki, Alloy). Use it to learn what the scripts
automate, or to debug a step that failed inside a script.

> **Use one path only.** The console guide, the scripts, this guide and Terraform all create
> resources with the same names (`obs-eks-*`). Following this guide *is* the shell path, done by
> hand. You can switch between this guide and the scripts at any step, because every command
> here is safe to run again.

Run everything in **Git Bash** from the repo root (`C:/DevOps/eks-argocd-observability`).
PowerShell won't work: the commands use bash syntax (`$VAR`, `$(...)`, `\` line breaks).

---

## Contents

- [Step 0: Tools, IAM user, and how IAM is used](#step-0-tools-iam-user-and-how-iam-is-used)
- [Step 1: Load the settings](#step-1-load-the-settings)
- [Step 2: AWS identity, clock and Route 53 zone](#step-2-aws-identity-clock-and-route-53-zone)
- [Step 3: ACM certificate](#step-3-acm-certificate-script-00-configuresh)
- [Step 4: Fill the placeholders and push to Git](#step-4-fill-the-placeholders-and-push-to-git-script-00-configuresh)
- [Step 5: IAM policies for the controllers](#step-5-iam-policies-for-the-controllers-script-01-create-clustersh)
- [Step 6: ECR repositories](#step-6-ecr-repositories-script-01-create-clustersh)
- [Step 7: Create the EKS cluster with eksctl](#step-7-create-the-eks-cluster-with-eksctl-script-01-create-clustersh)
- [Step 8: Connect kubectl, and cluster access](#step-8-connect-kubectl-and-cluster-access)
- [Step 9: Default StorageClass gp3](#step-9-default-storageclass-gp3-script-02-install-platformsh)
- [Step 10: Gateway API CRDs](#step-10-gateway-api-crds-script-02-install-platformsh)
- [Step 11: AWS Load Balancer Controller](#step-11-aws-load-balancer-controller-script-02-install-platformsh)
- [Step 12: ExternalDNS](#step-12-externaldns-script-02-install-platformsh)
- [Step 13: Prometheus Operator CRDs](#step-13-prometheus-operator-crds-script-02-install-platformsh)
- [Step 14: Argo CD](#step-14-argo-cd-script-02-install-platformsh)
- [Step 15: Secrets for the app and Grafana](#step-15-secrets-for-the-app-and-grafana-script-02-install-platformsh)
- [Step 16: Build and push the images](#step-16-build-and-push-the-images-script-03-releasesh)
- [Step 17: Point Git at the new tag](#step-17-point-git-at-the-new-tag-script-03-releasesh)
- [Step 18: Create the Argo CD root app](#step-18-create-the-argo-cd-root-app-script-02-install-platformsh)
- [Step 19: Verify the app](#step-19-verify-the-app)
- [Step 20: Verify the observability stack](#step-20-verify-the-observability-stack)
- [Step 21: Query metrics, logs and alerts from the command line](#step-21-query-metrics-logs-and-alerts-from-the-command-line)
- [Day 2: Releases, chart upgrades, alert routing, Loki on S3](#day-2-releases-chart-upgrades-alert-routing-loki-on-s3)
- [Useful commands for exploring](#useful-commands-for-exploring)
- [Troubleshooting](#troubleshooting)
- [Clean up](#clean-up-script-99-destroysh)
- [Appendix: build the cluster without eksctl (plain AWS CLI)](#appendix-build-the-cluster-without-eksctl-plain-aws-cli)

---

## Step 0: Tools, IAM user, and how IAM is used

Install these once (PowerShell, `winget`):

```powershell
winget install Amazon.AWSCLI Kubernetes.kubectl Helm.Helm eksctl Docker.DockerDesktop Git.Git
```

Then open **Git Bash** and check that every tool is on your PATH:

```bash
aws --version          # aws-cli/2.x
kubectl version --client
helm version           # v3.x
eksctl version
docker version         # the "Server" part must show; start Docker Desktop if it doesn't
git --version
openssl version
```

### 0.1 IAM user for the CLI (once per account)

Don't use root access keys for this project. Create an IAM user once, while signed in as an
admin (in CloudShell, or with a profile that already has admin rights):

```bash
aws iam create-user --user-name abip007
# Learning account: full admin. For a shared account, use a narrower policy.
aws iam attach-user-policy --user-name abip007 --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-access-key --user-name abip007     # shows AccessKeyId + SecretAccessKey ONCE - copy them now
```

Store the keys in a named profile on your PC:

```bash
aws configure --profile abip007   # access key, secret key, region ap-south-1, output json
aws sts get-caller-identity --profile abip007
```

**The IAM identity that creates the cluster becomes its first Kubernetes admin**
(`bootstrapClusterCreatorAdminPermissions`). If you create the cluster with one profile and run
kubectl with another, you get `Unauthorized`. See [Step 8.1](#81-who-can-use-the-cluster-iam--kubernetes).

### 0.2 How IAM is used in this project

| Who | IAM identity | Created by | Used for |
| --- | --- | --- | --- |
| You | IAM user `abip007` (profile `abip007`) | you, Step 0.1 | every `aws`, `eksctl`, `kubectl` and `helm` command |
| EKS control plane | role `eksctl-obs-eks-cluster-ServiceRole-…` | eksctl | lets EKS manage ENIs and load balancers for the control plane |
| Worker nodes (EC2) | role `eksctl-obs-eks-nodegroup-general-NodeInstanceRole-…` | eksctl | lets the kubelet join the cluster, pull images from ECR and run the VPC CNI |
| Pods (controllers) | Pod Identity roles for `aws-load-balancer-controller`, `external-dns`, `ebs-csi-controller-sa` | eksctl, from `iam.podIdentityAssociations` | lets those pods call ELB, Route 53 and EC2 (EBS) |
| Observability pods | **none** | | Prometheus, Grafana, Loki and Alloy only talk to the Kubernetes API (with Kubernetes RBAC from their charts) and to each other |

Pod Identity works like this: the `eks-pod-identity-agent` DaemonSet hands temporary credentials
for the linked role to any pod that runs as that **namespace + service account**. No access keys
are stored in the cluster. (If you move Loki to S3, Loki gets a Pod Identity role too. See
[Day 2](#loki-on-s3-adds-an-iam-role).)

---

## Step 1: Load the settings

Every script starts by sourcing [scripts/config.env](../scripts/config.env). Do the same in your shell
so that `$CLUSTER`, `$AWS_REGION` and the other settings exist for every command below.

```bash
cd /c/DevOps/eks-argocd-observability
source scripts/config.env

# Same private Helm cache the scripts use (avoids "no cached repo found" on Windows)
export HELM_REPOSITORY_CONFIG="$PWD/.helm/repositories.yaml"
export HELM_REPOSITORY_CACHE="$PWD/.helm/cache"
mkdir -p .helm/cache

for v in AWS_PROFILE AWS_REGION CLUSTER K8S_VERSION NODE_TYPE NODE_DESIRED DOMAIN APP_HOST ARGOCD_HOST GRAFANA_HOST GIT_REPO_URL; do
  printf '%-14s %s\n' "$v" "${!v}"
done
```

**How it works:** `config.env` uses `: "${VAR:=default}"`. That sets a value only if the
variable is still empty, so a value you export first wins:
`CLUSTER=test-eks source scripts/config.env && echo $CLUSTER` prints `test-eks`.

> If you open a new Git Bash window later, run Step 1 again. Variables don't carry over
> between windows.

---

## Step 2: AWS identity, clock and Route 53 zone

```bash
aws sts get-caller-identity                     # Arn must be ...:user/abip007, not ...:root
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

Check your PC's clock against AWS. This is `check_clock` in `lib.sh`:

```bash
AWS_DATE=$(curl -sI "https://sts.$AWS_REGION.amazonaws.com" | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2}')
echo "skew: $(( $(date -u +%s) - $(date -u -d "$AWS_DATE" +%s) )) s"
```

Anything above about 5 seconds will break Step 11. Helm signs the LB Controller's webhook
certificate with *your* clock, and a certificate from the future is "not yet valid". To fix it,
run this in **admin PowerShell**: `Start-Service w32time; w32tm /resync /force`.

### 2.1 Route 53 hosted zone (and delegation)

ACM validation (Step 3) and ExternalDNS (Step 12) both need the **public hosted zone** for
`bestclick.click`:

```bash
aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
  --query "HostedZones[?Name=='$DOMAIN.'].[Id,Name,Config.PrivateZone,ResourceRecordSetCount]" --output table
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
  --query "HostedZones[?Name=='$DOMAIN.' && Config.PrivateZone==\`false\`].Id | [0]" --output text)
ZONE_ID=${ZONE_ID#/hostedzone/}; echo "$ZONE_ID"
```

**No zone?** Create one. Route 53 Domains creates it for you when you register a domain there.

```bash
ZONE_ID=$(aws route53 create-hosted-zone --name "$DOMAIN" --caller-reference "$(date +%s)" --query HostedZone.Id --output text)
ZONE_ID=${ZONE_ID#/hostedzone/}
```

**Delegation.** The registrar must point the domain at *this* zone's four name servers. If it
doesn't, nothing in the zone is visible on the internet:

```bash
aws route53 get-hosted-zone --id "$ZONE_ID" --query DelegationSet.NameServers --output text   # what the zone uses
nslookup -type=NS "$DOMAIN" 8.8.8.8                                                           # what the internet uses
aws route53domains get-domain-detail --region us-east-1 --domain-name "$DOMAIN" --query Nameservers[].Name   # Route 53 Domains only
```

If the lists differ, either update the registrar:

```bash
NS=$(aws route53 get-hosted-zone --id "$ZONE_ID" --query 'DelegationSet.NameServers' --output text)
aws route53domains update-domain-nameservers --region us-east-1 --domain-name "$DOMAIN" \
  --nameservers $(for n in $NS; do printf 'Name=%s ' "$n"; done)
```

or, if you have **two zones** with the same name, use the delegated one. Set `ZONE_ID=…` in
`scripts/config.env`. ExternalDNS is pinned to this ID (`--zone-id-filter`), so records never
land in the wrong zone.

---

## Step 3: ACM certificate (script: 00-configure.sh)

One certificate for `bestclick.click` + `*.bestclick.click` covers all three hosts
(`obs-bmi`, `obs-argocd`, `obs-grafana`). Look for an existing one (`find_cert` in `lib.sh`):

```bash
CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?DomainName=='$DOMAIN' || DomainName=='*.$DOMAIN'].CertificateArn | [0]" \
  --output text | grep -v '^None$')
echo "${CERT_ARN:-none found}"
```

If you got an ARN, skip to Step 4. Otherwise, request a certificate, create its validation record, and wait:

```bash
CERT_ARN=$(aws acm request-certificate --region "$AWS_REGION" \
  --domain-name "$DOMAIN" --subject-alternative-names "*.$DOMAIN" \
  --validation-method DNS --query CertificateArn --output text)
sleep 10   # the validation record appears a few seconds after the request
read -r RNAME RVALUE <<<"$(aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]' --output text)"
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch \
  "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$RNAME\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$RVALUE\"}]}}]}"
aws acm wait certificate-validated --region "$AWS_REGION" --certificate-arn "$CERT_ARN"     # 1-5 min
```

The CNAME proves to ACM that you control the domain. The bare domain and the wildcard share one record.

---

## Step 4: Fill the placeholders and push to Git (script: 00-configure.sh)

The YAML in `gitops/`, `platform/` and `eksctl/` is shipped with placeholders like
`__ACCOUNT_ID__`. **Argo CD reads the files from GitHub, not from your PC**, so the real values
must be committed.

```bash
grep -rn '__[A-Z0-9_]*__' gitops platform eksctl      # what still needs a value

for f in $(grep -rl '__[A-Z0-9_]*__' gitops platform eksctl); do
  sed -i \
    -e "s|__ACCOUNT_ID__|$ACCOUNT_ID|g"     -e "s|__REGION__|$AWS_REGION|g" \
    -e "s|__CLUSTER__|$CLUSTER|g"           -e "s|__K8S_VERSION__|$K8S_VERSION|g" \
    -e "s|__NODE_TYPE__|$NODE_TYPE|g"       -e "s|__NODE_MIN__|$NODE_MIN|g" \
    -e "s|__NODE_DESIRED__|$NODE_DESIRED|g" -e "s|__NODE_MAX__|$NODE_MAX|g" \
    -e "s|__VPC_CIDR__|$VPC_CIDR|g"         -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__ZONE_ID__|$ZONE_ID|g"           -e "s|__APP_HOST__|$APP_HOST|g" \
    -e "s|__ARGOCD_HOST__|$ARGOCD_HOST|g"   -e "s|__GRAFANA_HOST__|$GRAFANA_HOST|g" \
    -e "s|__CERT_ARN__|$CERT_ARN|g"         -e "s|__GIT_REPO_URL__|$GIT_REPO_URL|g" "$f"
  echo "filled $f"
done
grep -rn '__[A-Z0-9_]*__' gitops platform eksctl || echo "all placeholders filled"

git diff --stat
git add -A && git commit -m "Configure for $CLUSTER" && git push
```

`sed -i` edits the file in place. The `|` is the separator, so the `/` and `:` in URLs and ARNs need no escaping.

---

## Step 5: IAM policies for the controllers (script: 01-create-cluster.sh)

| Policy name | File | Lets the controller… |
| --- | --- | --- |
| `obs-eks-lbc` | [policies/aws-load-balancer-controller.json](../policies/aws-load-balancer-controller.json) | create and modify ALBs, target groups and security groups |
| `obs-eks-external-dns` | [policies/external-dns.json](../policies/external-dns.json) | write records into your Route 53 zone |

```bash
for p in lbc:aws-load-balancer-controller external-dns:external-dns; do
  name="$CLUSTER-${p%%:*}"          # text before ':'  -> obs-eks-lbc
  file="policies/${p#*:}.json"      # text after ':'   -> policies/aws-load-balancer-controller.json
  aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$name" >/dev/null 2>&1 \
    && echo "$name exists" \
    || aws iam create-policy --policy-name "$name" --policy-document "file://$file" --query Policy.Arn --output text
done
aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName,'$CLUSTER-')].[PolicyName,Arn]" --output table
```

Read one to see what it allows: `aws iam get-policy-version --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-external-dns --version-id v1`.
The policies must exist **before** eksctl runs, because [eksctl/cluster.yaml](../eksctl/cluster.yaml) attaches them by ARN.

---

## Step 6: ECR repositories (script: 01-create-cluster.sh)

```bash
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
for r in bmi-backend bmi-frontend; do
  aws ecr describe-repositories --repository-names "$CLUSTER/$r" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$CLUSTER/$r" \
      --image-scanning-configuration scanOnPush=true --query repository.repositoryUri --output text
done
aws ecr describe-repositories --query "repositories[?starts_with(repositoryName,'$CLUSTER/')].repositoryUri" --output table
grep newName gitops/bmi-app/overlays/prod/kustomization.yaml     # must point at these repos
```

`describe … || create …` is the "create only if missing" pattern used throughout the scripts.

---

## Step 7: Create the EKS cluster with eksctl (script: 01-create-cluster.sh)

[eksctl/cluster.yaml](../eksctl/cluster.yaml) describes everything that eksctl builds:

| Section | What it creates |
| --- | --- |
| `vpc` | VPC `10.2.0.0/16`, 3 public + 3 private subnets (already tagged for ALBs), **one** NAT gateway |
| `accessConfig` | EKS access entries (`API` mode); your identity becomes cluster admin |
| `addons` | vpc-cni (with network policy), kube-proxy, coredns, pod-identity agent, metrics-server, EBS CSI driver |
| `iam.podIdentityAssociations` | links the `aws-load-balancer-controller` and `external-dns` service accounts to the policies from Step 5 |
| `managedNodeGroups` | 2–5 × `m7i-flex.large` (3 to start) in private subnets, AL2023, 20 GiB disk |
| `cloudWatch` | control plane logs: api, audit, authenticator |

```bash
eksctl create cluster -f eksctl/cluster.yaml --dry-run | less           # full config with defaults
eksctl get cluster --name "$CLUSTER" --region "$AWS_REGION" 2>/dev/null \
  || eksctl create cluster -f eksctl/cluster.yaml                        # 15-20 min (CloudFormation)
```

Watch it from a second Git Bash window, and read the failure reason if it fails:

```bash
source scripts/config.env
aws cloudformation list-stacks --stack-status-filter CREATE_IN_PROGRESS CREATE_COMPLETE \
  --query "StackSummaries[?contains(StackName,'$CLUSTER')].[StackName,StackStatus]" --output table
aws cloudformation describe-stack-events --stack-name eksctl-$CLUSTER-cluster \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" --output table
```

> To see what eksctl does for you, build the same cluster with plain AWS CLI commands instead:
> [Appendix](#appendix-build-the-cluster-without-eksctl-plain-aws-cli). Use **one** of the two.

### 7.1 Inspect what eksctl built

```bash
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].[AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,Tags[?Key==`kubernetes.io/role/elb`]|[0].Value,Tags[?Key==`kubernetes.io/role/internal-elb`]|[0].Value]' --output table
aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC_ID --query 'NatGateways[].[NatGatewayId,State]' --output table

# IAM roles eksctl created, and what each may do / who may assume it
aws iam list-roles --query "Roles[?starts_with(RoleName,'eksctl-$CLUSTER')].RoleName" --output table
CLUSTER_ROLE=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.roleArn --output text)
NODE_ROLE=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name general --query nodegroup.nodeRole --output text)
aws iam list-attached-role-policies --role-name "${CLUSTER_ROLE##*/}" --output table
aws iam list-attached-role-policies --role-name "${NODE_ROLE##*/}" --output table
aws iam get-role --role-name "${CLUSTER_ROLE##*/}" --query Role.AssumeRolePolicyDocument   # eks.amazonaws.com
aws iam get-role --role-name "${NODE_ROLE##*/}"    --query Role.AssumeRolePolicyDocument   # ec2.amazonaws.com
aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --query 'associations[].[namespace,serviceAccount,associationId]' --output table
```

`${VAR##*/}` removes everything up to the last `/`, turning a role ARN into a role name.

---

## Step 8: Connect kubectl, and cluster access

```bash
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
kubectl get nodes -o wide            # 3 nodes Ready, INTERNAL-IP 10.2.x.x, no EXTERNAL-IP
kubectl get pods -A                  # coredns, aws-node, kube-proxy, ebs-csi-*, metrics-server, eks-pod-identity-agent
kubectl top nodes                    # works once metrics-server is Ready
```

### 8.1 Who can use the cluster (IAM → Kubernetes)

With `authenticationMode: API`, EKS maps IAM ARNs to Kubernetes permissions through **access entries**:

```bash
aws eks list-access-entries --cluster-name "$CLUSTER" --output table
MY_ARN=$(aws sts get-caller-identity --query Arn --output text)
aws eks list-associated-access-policies --cluster-name "$CLUSTER" --principal-arn "$MY_ARN" --output table
kubectl auth whoami
kubectl auth can-i '*' '*' --all-namespaces          # yes = cluster admin

# Give a teammate read-only access (AmazonEKSClusterAdminPolicy for admin):
OTHER=arn:aws:iam::$ACCOUNT_ID:user/teammate
aws eks create-access-entry --cluster-name "$CLUSTER" --principal-arn "$OTHER"
aws eks associate-access-policy --cluster-name "$CLUSTER" --principal-arn "$OTHER" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy --access-scope type=cluster
```

---

## Step 9: Default StorageClass gp3 (script: 02-install-platform.sh)

Four things in this project ask for volumes: Postgres, Prometheus, Loki and Alertmanager. They
all use the `gp3` class (encrypted; `WaitForFirstConsumer` creates each volume in the AZ of its pod).

```bash
kubectl apply -f platform/storageclass-gp3.yaml
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite 2>/dev/null || true
kubectl get storageclass             # exactly one "(default)", on gp3
```

---

## Step 10: Gateway API CRDs (script: 02-install-platform.sh)

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/config/crd/gateway/gateway-crds.yaml
```

LB Controller v3 watches Gateway API objects and expects these CRDs at startup. `--server-side` is
needed because they are too large for client-side apply.

---

## Step 11: AWS Load Balancer Controller (script: 02-install-platform.sh)

```bash
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts -n kube-system \
  --set clusterName="$CLUSTER" --set region="$AWS_REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 10m
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=300s
```

- `helm upgrade --install` installs the first time and upgrades after that, so it's safe to run again.
- `serviceAccount.name` **must** equal the Pod Identity association, or the controller has no AWS permissions.
- Wait for the rollout: the controller's **webhook** checks every Service and Ingress. Until it's
  ready, later installs fail with `failed calling webhook "mservice.elbv2.k8s.aws"`.

Every Ingress in this project has `alb.ingress.kubernetes.io/group.name: obs-eks`, so the controller
merges all three (app, Argo CD, Grafana) into **one ALB** named `k8s-obseks-…`, with one rule per host.

---

## Step 12: ExternalDNS (script: 02-install-platform.sh)

[platform/external-dns-values.yaml](../platform/external-dns-values.yaml): `domainFilters`,
`--zone-id-filter` (only the delegated zone), `policy: upsert-only` (never deletes), and `txtOwnerId: obs-eks`.

```bash
helm upgrade --install external-dns external-dns \
  --repo https://kubernetes-sigs.github.io/external-dns/ -n external-dns --create-namespace \
  -f platform/external-dns-values.yaml --wait --timeout 5m
kubectl -n external-dns logs deploy/external-dns --tail=20     # "All records are already up to date" = permissions OK
```

---

## Step 13: Prometheus Operator CRDs (script: 02-install-platform.sh)

The Prometheus Operator adds its own Kubernetes object types (CRDs):

| CRD | What it describes |
| --- | --- |
| `ServiceMonitor` / `PodMonitor` | "scrape these Services/Pods on this port and path". The operator turns them into Prometheus scrape config |
| `PrometheusRule` | recording and alert rules |
| `Prometheus` / `Alertmanager` | the Prometheus and Alertmanager servers themselves (the operator runs them as StatefulSets) |
| `AlertmanagerConfig`, `Probe`, `ScrapeConfig`, `ThanosRuler` | more advanced routing and scraping |

They're installed **before Argo CD**, because Argo CD's values ([platform/argocd-values.yaml](../platform/argocd-values.yaml))
create ServiceMonitors for Argo CD itself. kube-prometheus-stack later runs with `crds.enabled: false`, so it doesn't fight over them.

```bash
helm upgrade --install prometheus-operator-crds prometheus-operator-crds \
  --repo https://prometheus-community.github.io/helm-charts --version 33.0.1 \
  -n observability --create-namespace --wait
kubectl get crd | grep monitoring.coreos.com
kubectl explain servicemonitor.spec.endpoints | head -30       # built-in docs for any CRD field
```

Keep this chart's version in step with the operator inside kube-prometheus-stack (both are
`appVersion v0.95.1` here: `helm show chart --repo https://prometheus-community.github.io/helm-charts kube-prometheus-stack --version 93.1.1`).

---

## Step 14: Argo CD (script: 02-install-platform.sh)

[platform/argocd-values.yaml](../platform/argocd-values.yaml):

- `server.insecure: true`: TLS ends at the ALB.
- `timeout.reconciliation: 60s`: Argo CD polls Git every 60 seconds.
- `server.ingress`: `obs-argocd.bestclick.click` on the `obs-eks` ALB group.
- `*.metrics.serviceMonitor.enabled`: Prometheus scrapes Argo CD's controller, repo server, API server
  and ApplicationSet controller, which gives you metrics like `argocd_app_info` (sync/health per app).

```bash
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm -n argocd --create-namespace \
  -f platform/argocd-values.yaml --wait --timeout 10m

kubectl -n argocd get pods,servicemonitors
kubectl -n argocd get ingress        # ADDRESS = k8s-obseks-….elb.amazonaws.com after 1-3 minutes
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

This Ingress is the first one in the cluster, so this is when the ALB is created and
ExternalDNS writes `obs-argocd.bestclick.click`. Watch both happen:
`kubectl -n kube-system logs deploy/aws-load-balancer-controller -f` and `kubectl -n external-dns logs deploy/external-dns -f`.

No DNS yet? Use `kubectl -n argocd port-forward svc/argocd-server 8080:80` and open http://localhost:8080.

---

## Step 15: Secrets for the app and Grafana (script: 02-install-platform.sh)

Passwords are **never stored in Git**. Create them once, directly in the cluster:

```bash
kubectl create namespace bmi-app --dry-run=client -o yaml | kubectl apply -f -   # idempotent "create"

if ! kubectl -n bmi-app get secret postgres-secret >/dev/null 2>&1; then
  DB_PASS=$(openssl rand -hex 16)          # hex only, so it's safe inside a URL
  kubectl -n bmi-app create secret generic postgres-secret \
    --from-literal=POSTGRES_DB=bmidb --from-literal=POSTGRES_USER=bmi_user \
    --from-literal=POSTGRES_PASSWORD="$DB_PASS"
  kubectl -n bmi-app create secret generic backend-secret \
    --from-literal=DATABASE_URL="postgres://bmi_user:$DB_PASS@bmi-postgres-svc:5432/bmidb"
fi

# Grafana reads its admin login from this Secret (grafana.admin.existingSecret in the values file)
kubectl -n observability get secret grafana-admin >/dev/null 2>&1 || \
  kubectl -n observability create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -hex 12)"

kubectl -n bmi-app get secrets; kubectl -n observability get secrets
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

**Don't recreate the Postgres secrets after Postgres has started.** Postgres sets the password
only when it first initialises the volume. Changing `grafana-admin` is fine: delete the Grafana
pod afterwards and it starts with the new password.

---

## Step 16: Build and push the images (script: 03-release.sh)

```bash
TAG="$(git rev-parse --short HEAD)-$(date +%Y%m%d%H%M%S)"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
for c in backend frontend; do
  docker build --platform linux/amd64 -t "$REGISTRY/$CLUSTER/bmi-$c:$TAG" "app/$c"
  docker push "$REGISTRY/$CLUSTER/bmi-$c:$TAG"
done
aws ecr describe-images --repository-name "$CLUSTER/bmi-backend" \
  --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags[0],imagePushedAt]' --output text
```

The backend in this project is instrumented for observability ([app/backend/src/server.js](../app/backend/src/server.js)):

- **`/metrics`** (library `prom-client`): default Node.js metrics plus the histogram
  `http_request_duration_seconds{method,route,status_code}`. From this one histogram Prometheus
  calculates request rate (`_count`), error rate (`status_code=~"5.."`) and latency percentiles (`_bucket`).
- **JSON logs**: one line per API request, `{"level":"info","msg":"request","route":"/api/measurements","status":200,"duration_ms":12}`.
  In Loki you can then filter on fields with `| json`.

Try it locally before pushing: `docker run --rm -p 3000:3000 $REGISTRY/$CLUSTER/bmi-backend:$TAG`, then
`curl -s localhost:3000/metrics | grep http_request`. (The API needs a database, but `/metrics` and `/health` work without one.)

---

## Step 17: Point Git at the new tag (script: 03-release.sh)

**This commit is the deployment.** Argo CD deploys whatever tag Git names.

```bash
OVERLAY=gitops/bmi-app/overlays/prod/kustomization.yaml
sed -i -E "s|^(\s*newTag:).*|\1 $TAG|" "$OVERLAY"
grep -n -E 'newName|newTag' "$OVERLAY"
kubectl kustomize gitops/bmi-app/overlays/prod | grep -E 'image:|host:|kind: ServiceMonitor'   # preview
git add "$OVERLAY" && git commit -m "release: bmi images $TAG" && git push origin "HEAD:$GIT_BRANCH"
```

---

## Step 18: Create the Argo CD root app (script: 02-install-platform.sh)

[gitops/argocd/root-app.yaml](../gitops/argocd/root-app.yaml) is the **only** Argo CD object you
apply by hand. It watches `gitops/argocd/apps/` and creates every Application it finds there:

| Application | Source | Namespace |
| --- | --- | --- |
| `bmi-app` | Kustomize: `gitops/bmi-app/overlays/prod` | `bmi-app` |
| `kube-prometheus-stack` | Helm chart 93.1.1 + `$values/gitops/observability/kube-prometheus-stack-values.yaml` | `observability` |
| `loki` | Helm chart 7.5.0 + `$values/gitops/observability/loki-values.yaml` | `observability` |
| `alloy` | Helm chart 1.15.0 + `$values/gitops/observability/alloy-values.yaml` | `observability` |
| `observability-extras` | Kustomize: `gitops/observability/extras` (dashboard + alert rules) | `observability` |

The Helm apps use **multiple sources**: source 1 is the chart from the chart repo, and source 2 is
this Git repo with `ref: values`. `$values/...` means "this file from source 2". So the chart
version and every setting live in Git, and **Argo CD runs the Helm install for you**.

```bash
kubectl apply -f gitops/argocd/root-app.yaml
kubectl -n argocd get applications -w      # all 6 -> Synced / Healthy in about 3-5 min (Ctrl+C to stop)
```

See what Argo CD renders without installing anything:

```bash
helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version 93.1.1 -n observability -f gitops/observability/kube-prometheus-stack-values.yaml | grep -E '^kind:' | sort | uniq -c
helm template loki loki --repo https://grafana.github.io/helm-charts --version 7.5.0 -n observability \
  -f gitops/observability/loki-values.yaml | grep -E '^kind:' | sort | uniq -c
```

---

## Step 19: Verify the app

```bash
kubectl -n bmi-app get pods,svc,hpa,ingress,pvc,servicemonitor
kubectl -n bmi-app logs job/bmi-migrations
kubectl -n bmi-app logs deploy/bmi-backend --tail=5          # JSON lines
nslookup "$APP_HOST"
curl -sI "http://$APP_HOST"  | head -3                       # 301 -> https
curl -s  "https://$APP_HOST" | head -5                       # the React index.html
```

`bmi-app` syncs in waves: Postgres (0) → migrations Job (1) → backend, HPA, ServiceMonitor, frontend (2) → Ingress (3).

---

## Step 20: Verify the observability stack

```bash
kubectl -n observability get pods
```

| Pod | What it is |
| --- | --- |
| `prometheus-kube-prometheus-stack-prometheus-0` | Prometheus (StatefulSet, 20 GiB volume) |
| `alertmanager-kube-prometheus-stack-alertmanager-0` | Alertmanager (2 GiB volume) |
| `kube-prometheus-stack-operator-…` | Prometheus Operator: turns ServiceMonitors/PrometheusRules into config |
| `kube-prometheus-stack-grafana-…` | Grafana + its sidecars that load dashboards and data sources |
| `kube-prometheus-stack-kube-state-metrics-…` | metrics about Kubernetes objects (deployments, pods, restarts…) |
| `kube-prometheus-stack-prometheus-node-exporter-…` | one per node: CPU, memory, disk, network of the node |
| `loki-0` | Loki single binary (10 GiB volume) |
| `alloy-…` | Alloy log collector |

```bash
kubectl -n observability get pvc                         # 3 Bound volumes (Prometheus, Alertmanager, Loki)
kubectl -n observability get ingress                     # Grafana, same ALB ADDRESS as the app
kubectl get servicemonitors -A                           # every scrape target definition
kubectl get prometheusrules -A                           # default rules + bmi-app
kubectl -n observability get configmap -l grafana_dashboard=1   # dashboards Grafana loads
nslookup "$GRAFANA_HOST"; curl -s "https://$GRAFANA_HOST/api/health"   # {"database":"ok",...}
```

Open **https://obs-grafana.bestclick.click** (admin / password from Step 15) → **Dashboards → BMI → BMI app**.

Look inside Alloy: `kubectl -n observability port-forward deploy/alloy 12345:12345` and open
http://localhost:12345. The **Graph** shows the pipeline discovery → relabel → source → write, with health per component.

---

## Step 21: Query metrics, logs and alerts from the command line

Every tool has an HTTP API. Port-forward it, then use `curl`. Grafana uses the same APIs.

```bash
# Run in the background; stop them all at the end with: kill $(jobs -p)
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus   9090:9090 >/dev/null &
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 >/dev/null &
kubectl -n observability port-forward svc/loki                               3100:3100 >/dev/null &
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana      3000:80   >/dev/null &
sleep 3
```

### 21.1 Prometheus (PromQL)

Web UI: http://localhost:9090. **Status → Targets** lists every scrape target and any errors.

```bash
q() { curl -s http://localhost:9090/api/v1/query --data-urlencode "query=$1"; echo; }

q 'up{namespace="bmi-app"}'                                                     # 1 = backend pod scraped OK
q 'count by (job) (up == 0)'                                                    # targets that are down (empty = none)
q 'sum by (route, status_code) (rate(http_request_duration_seconds_count{namespace="bmi-app"}[5m]))'
q 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="bmi-app"}[5m])))'
q 'sum by (pod) (container_memory_working_set_bytes{namespace="observability", container!=""})'   # what the stack itself uses
q 'argocd_app_info'                                                             # sync + health of every Argo CD app
q 'loki_distributor_lines_received_total'                                       # log lines Loki has received
```

Generate some traffic first so the app metrics have data:
`for i in $(seq 50); do curl -s -o /dev/null "https://$APP_HOST/api/measurements"; done`.

### 21.2 Loki (LogQL)

```bash
curl -s http://localhost:3100/ready; echo                                       # "ready"
curl -s http://localhost:3100/loki/api/v1/labels; echo                          # namespace, pod, container, app, node, cluster, job
curl -s http://localhost:3100/loki/api/v1/label/namespace/values; echo

lq() { curl -s -G http://localhost:3100/loki/api/v1/query_range --data-urlencode "query=$1" --data-urlencode limit=${2:-10}; echo; }
lq '{namespace="bmi-app", app="bmi-backend"}' 5                                 # last 5 backend lines (last hour)
lq '{app="bmi-backend"} | json | status >= 400'                                 # failed requests only
lq '{job="kubernetes-events"} |= "Killing"'                                     # pods being killed
lq 'sum by (app) (count_over_time({namespace="bmi-app"}[5m]))'                  # a metric computed from logs
```

LogQL is two parts: the **stream selector** `{label="value"}` picks log streams by label (fast,
uses the index), then **pipeline stages** filter or parse lines (`|= "text"`, `|~ "regex"`, `| json`, `| status >= 500`).
For a nicer CLI, install `logcli` (from the Loki GitHub releases) and run `logcli --addr=http://localhost:3100 query '{app="bmi-backend"}'`.

### 21.3 Alertmanager and alert rules

```bash
curl -s http://localhost:9090/api/v1/rules --data-urlencode 'type=alert' | grep -o '"name":"Bmi[A-Za-z]*"' | sort -u
curl -s http://localhost:9090/api/v1/alerts; echo                               # pending + firing in Prometheus
curl -s http://localhost:9093/api/v2/alerts | grep -o '"alertname":"[^"]*"' | sort | uniq -c   # what Alertmanager holds
```

`Watchdog` always fires on purpose: it proves the whole alert pipeline works. To see a BMI alert fire:

```bash
kubectl -n argocd patch application bmi-app --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'   # pause auto-sync (self-heal)
kubectl -n bmi-app delete hpa bmi-backend
kubectl -n bmi-app scale deploy bmi-backend --replicas=0
# ~3 min later BmiBackendDown is firing:
curl -s http://localhost:9093/api/v2/alerts | grep -o '"alertname":"BmiBackendDown"'
# restore: auto-sync back on (recreates the HPA), then scale up (the HPA doesn't scale up from 0)
kubectl apply -f gitops/argocd/apps/bmi-app.yaml
kubectl -n bmi-app scale deploy bmi-backend --replicas=2
```

### 21.4 Grafana API

```bash
GPASS=$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u admin:$GPASS http://localhost:3000/api/datasources | grep -o '"name":"[^"]*"'   # Prometheus, Loki, Alertmanager
curl -s -u admin:$GPASS "http://localhost:3000/api/search?query=BMI"; echo                 # the BMI app dashboard
curl -s -u admin:$GPASS http://localhost:3000/api/dashboards/uid/bmi-app | head -c 300; echo

kill $(jobs -p)          # stop the port-forwards
```

---

## Day 2: Releases, chart upgrades, alert routing, Loki on S3

### Release a new version

Repeat **Step 16** (new `TAG`) and **Step 17**, or run `bash scripts/03-release.sh`. Watch the
rollout on the BMI app dashboard and with `kubectl -n bmi-app rollout status deploy/bmi-backend`.
Rollback: `git revert <release commit> && git push`.

### Change observability settings

Everything is GitOps. Edit a values file, push, and Argo CD runs `helm upgrade`:

```bash
sed -i 's/retention: 7d/retention: 15d/' gitops/observability/kube-prometheus-stack-values.yaml
git commit -am "prometheus: keep 15 days" && git push
kubectl -n argocd annotate application kube-prometheus-stack argocd.argoproj.io/refresh=hard --overwrite   # don't wait 60 s
```

**Add a dashboard:** build it in Grafana → **Share → Export → Save to file** → copy the JSON to
`gitops/observability/extras/dashboards/`, add it to the `configMapGenerator` in
[extras/kustomization.yaml](../gitops/observability/extras/kustomization.yaml), push.
Dashboards edited only in the UI are lost when the Grafana pod restarts (no volume, by design).

**Add an alert:** add a rule to [extras/bmi-alerts.yaml](../gitops/observability/extras/bmi-alerts.yaml), push.

### Upgrade a chart

```bash
helm show chart --repo https://prometheus-community.github.io/helm-charts kube-prometheus-stack | grep -E '^(version|appVersion)'
```

Read the chart's upgrade notes for breaking changes. Then bump `targetRevision` in
`gitops/argocd/apps/<app>.yaml` and push. For kube-prometheus-stack, also upgrade the CRDs first
(Step 13 with the matching `prometheus-operator-crds` version).

### Send alerts somewhere (Slack example)

By default Alertmanager doesn't notify anyone. Add a receiver to the kube-prometheus-stack values.
Keep the webhook URL out of Git by putting it in a Secret:

```bash
kubectl -n observability create secret generic alertmanager-slack --from-literal=url='https://hooks.slack.com/services/XXX/YYY/ZZZ'
```

```yaml
# gitops/observability/kube-prometheus-stack-values.yaml
alertmanager:
  alertmanagerSpec:
    secrets: [alertmanager-slack]            # mounted at /etc/alertmanager/secrets/alertmanager-slack/
  config:
    route:
      receiver: slack
      group_by: [alertname, namespace]
      routes:
        - receiver: "null"
          matchers: [alertname = "Watchdog"]
    receivers:
      - name: "null"
      - name: slack
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/alertmanager-slack/url
            channel: "#alerts"
            send_resolved: true
```

### Loki on S3 (adds an IAM role)

Logs on one EBS volume are fine for learning. For durability and size, Loki stores chunks in S3.
That needs AWS permissions, given the same way as the controllers, with Pod Identity:

```bash
BUCKET=$CLUSTER-loki-$ACCOUNT_ID
aws s3api create-bucket --bucket $BUCKET --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION
aws iam create-policy --policy-name $CLUSTER-loki --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
  {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\"],\"Resource\":\"arn:aws:s3:::$BUCKET\"},
  {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}"
aws iam create-role --role-name $CLUSTER-loki --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
aws iam attach-role-policy --role-name $CLUSTER-loki --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-loki
aws eks create-pod-identity-association --cluster-name $CLUSTER --namespace observability \
  --service-account loki --role-arn arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER-loki
```

Then in `loki-values.yaml` set `loki.storage.type: s3`, `loki.storage.bucketNames.chunks/ruler` = the
bucket, `loki.storage.s3.region`, and `object_store: s3` in the schema. Add a new schema entry
with a future `from:` date, so existing logs stay readable. Push.

---

## Useful commands for exploring

| Want to… | Command |
| --- | --- |
| Force Argo CD to re-check Git now | `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite` |
| See why an app is OutOfSync / Degraded | `kubectl -n argocd describe application <app>` (see `Status.Conditions` and `Resources`) |
| Events in a namespace, newest last | `kubectl -n observability get events --sort-by=.lastTimestamp` |
| Why a pod won't start | `kubectl -n <ns> describe pod <name>` (Events at the bottom) |
| Logs of a crashed container | `kubectl -n <ns> logs <pod> --previous` |
| Rendered Prometheus config | `kubectl -n observability get secret prometheus-kube-prometheus-stack-prometheus -o jsonpath='{.data.prometheus\.yaml\.gz}' \| base64 -d \| gunzip \| less` |
| Rendered Loki config | `kubectl -n observability get configmap loki -o jsonpath='{.data.config\.yaml}'` |
| Rendered Alloy config | `kubectl -n observability get configmap alloy -o jsonpath='{.data.config\.alloy}'` |
| Open a psql shell | `kubectl -n bmi-app exec -it postgres-0 -- psql -U bmi_user -d bmidb` |
| Resource use of the stack | `kubectl top pods -n observability --sort-by=memory` |
| Show the values a Helm release uses | `helm -n argocd get values argocd` |
| Scale the node group | `eksctl scale nodegroup --cluster $CLUSTER --name general --nodes 4` |

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `x509: certificate … not yet valid … mservice.elbv2.k8s.aws` | PC clock ahead of AWS (Step 2) | Fix the clock, `helm -n kube-system uninstall aws-load-balancer-controller`, redo Step 11 |
| Argo CD install: `no matches for kind "ServiceMonitor"` | Step 13 skipped | Install the CRDs, then Step 14 again |
| Helm `cannot re-use a name that is still in use` | A failed release is still installed | `helm -n <ns> uninstall <name>` and install again |
| Helm `no cached repo found` | Stale global Helm cache on Windows | Set `HELM_REPOSITORY_*` as in Step 1 |
| `error: You must be logged in to the server (Unauthorized)` | Different AWS profile than the cluster creator | `echo $AWS_PROFILE`, Step 1, then Step 8 / 8.1 |
| eksctl fails, stack `ROLLBACK_COMPLETE` | Quota, instance type not offered in an AZ, missing IAM policy | Stack events (Step 7), `eksctl delete cluster -f eksctl/cluster.yaml`, retry |
| Pods `Pending`: "Insufficient memory" / "Too many pods" | Not enough nodes for app + observability | `eksctl scale nodegroup --cluster $CLUSTER --name general --nodes 4` |
| A PVC stays `Pending` | No default StorageClass, or EBS CSI has no role | `kubectl get sc`; `aws eks list-pod-identity-associations --cluster-name $CLUSTER` |
| Grafana pod `CreateContainerConfigError` | Secret `grafana-admin` missing | Step 15, then `kubectl -n observability delete pod -l app.kubernetes.io/name=grafana` |
| `kube-prometheus-stack` app stays OutOfSync | A field the operator changes at runtime | `kubectl -n argocd describe application kube-prometheus-stack`; add it to `ignoreDifferences` |
| Prometheus target `bmi-app/bmi-backend` missing | Service has no `app: bmi-backend` label / port not named `http` | `kubectl -n bmi-app get svc bmi-backend-svc -o yaml` |
| Target is DOWN with 404 | Image built before `/metrics` existed | Release a new image (Step 16–17) |
| No logs in Grafana | Alloy can't reach Loki, or Loki not ready | `kubectl -n observability logs deploy/alloy`; `curl localhost:3100/ready` |
| Loki `entry too far behind` / `out of order` | Old logs replayed after Alloy restart | Harmless; Loki drops lines older than its limits |
| `ImagePullBackOff` | Overlay `newName:newTag` doesn't exist in ECR | Compare with `aws ecr describe-images --repository-name $CLUSTER/bmi-backend` |
| Backend `password authentication failed` | Secrets recreated after Postgres initialised | Restore the old password, or delete PVC `data-postgres-0` (**deletes the data**) |
| DNS name doesn't resolve | ExternalDNS permissions, filter or wrong zone | `kubectl -n external-dns logs deploy/external-dns`; check `--zone-id-filter` (Step 2.1) |

---

## Clean up (script: 99-destroy.sh)

**The order matters.** The ALB and the four EBS volumes were created *by controllers in the
cluster*, not by eksctl. If you delete the cluster first, they're orphaned and the VPC can't be deleted.

```bash
source scripts/config.env && aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"

# 1. Argo CD apps. Their finalizers delete what they created (Ingresses -> ALB rules, pods)
kubectl -n argocd delete application root --ignore-not-found --wait=true --timeout=10m
kubectl -n argocd delete application bmi-app observability-extras alloy loki kube-prometheus-stack --ignore-not-found --wait=true --timeout=10m
# StatefulSet PVCs (Postgres, Prometheus, Alertmanager, Loki) are never pruned; deleting the namespaces releases the volumes
kubectl delete namespace bmi-app observability --ignore-not-found --wait=true --timeout=10m

# 2. Argo CD (its Ingress was the last one on the ALB), then the controllers
helm -n argocd uninstall argocd --wait
sleep 60
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-obseks')].LoadBalancerName"   # should be []
helm -n external-dns uninstall external-dns
helm -n kube-system uninstall aws-load-balancer-controller

# 3. Cluster, node group and VPC (10-15 minutes)
eksctl delete cluster -f eksctl/cluster.yaml --wait --disable-nodegroup-eviction

# 4. ECR and IAM policies
for r in bmi-backend bmi-frontend; do aws ecr delete-repository --repository-name "$CLUSTER/$r" --force; done
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
for p in lbc external-dns; do aws iam delete-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-$p"; done
```

5. **Route 53:** ExternalDNS is `upsert-only`, so delete the `obs-bmi`, `obs-argocd` and `obs-grafana`
   A and TXT records yourself. Keep the certificate and the zone if other projects use them.
6. If you did "Loki on S3": empty and delete the bucket, then delete the `$CLUSTER-loki` role and policy.

Final check that nothing billable is left:

```bash
aws eks list-clusters
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]'
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'
```

---

## Appendix: build the cluster without eksctl (plain AWS CLI)

This builds the same thing as [eksctl/cluster.yaml](../eksctl/cluster.yaml) in Step 7, one AWS API
call at a time. Use it **in place of** Step 7, then continue with Step 8. Run Steps 1, 2 and 5
first. Role names end in `-cli` so they never clash with eksctl's.

**Save the IDs as you go**, so you can reload them in a new shell (`.cli-ids.env` is git-ignored):

```bash
keep() { eval "$1=\"$2\""; echo "$1=\"$2\"" >> .cli-ids.env; echo "$1=$2"; }
# later, in a new shell:  source scripts/config.env && source .cli-ids.env
```

### A.1 VPC and subnets

```bash
keep VPC_ID "$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$CLUSTER-vpc}]" --query Vpc.VpcId --output text)"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames   # nodes need DNS names to join EKS
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support

read -r -a AZS <<<"$(aws ec2 describe-availability-zones --filters Name=zone-type,Values=availability-zone \
  --query 'AvailabilityZones[0:3].ZoneName' --output text)"

# Assumes VPC_CIDR=10.2.0.0/16. Private subnets are larger: every pod gets a VPC IP.
PUB_CIDRS=(10.2.0.0/20 10.2.16.0/20 10.2.32.0/20)
PRIV_CIDRS=(10.2.64.0/19 10.2.96.0/19 10.2.128.0/19)
for i in 0 1 2; do
  keep PUB$i "$(aws ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "${AZS[$i]}" --cidr-block "${PUB_CIDRS[$i]}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER-public-${AZS[$i]}},{Key=kubernetes.io/role/elb,Value=1}]" \
    --query Subnet.SubnetId --output text)"
  v=PUB$i; aws ec2 modify-subnet-attribute --subnet-id "${!v}" --map-public-ip-on-launch
  keep PRIV$i "$(aws ec2 create-subnet --vpc-id "$VPC_ID" --availability-zone "${AZS[$i]}" --cidr-block "${PRIV_CIDRS[$i]}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER-private-${AZS[$i]}},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
    --query Subnet.SubnetId --output text)"
done
```

The `kubernetes.io/role/*` tags tell the LB Controller where to put internet-facing ALBs (public) and internal ones (private).

### A.2 Internet gateway, NAT gateway, route tables

```bash
keep IGW "$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
keep PUB_RT "$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW"
for s in "$PUB0" "$PUB1" "$PUB2"; do aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$s"; done

keep EIP "$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)"
keep NAT "$(aws ec2 create-nat-gateway --subnet-id "$PUB0" --allocation-id "$EIP" --query NatGateway.NatGatewayId --output text)"
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT"
keep PRIV_RT "$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT"
for s in "$PRIV0" "$PRIV1" "$PRIV2"; do aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$s"; done

aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --service-name "com.amazonaws.$AWS_REGION.s3" \
  --vpc-endpoint-type Gateway --route-table-ids "$PRIV_RT"          # free; ECR layers skip the NAT
```

Public subnets route to the internet gateway (the ALB and NAT live there). Private subnets route
to the NAT (nodes live there and only make outbound connections).

### A.3 IAM roles: control plane, nodes, pods

```bash
keep CLUSTER_ROLE_ARN "$(aws iam create-role --role-name "$CLUSTER-cluster-role-cli" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}' \
  --query Role.Arn --output text)"
aws iam attach-role-policy --role-name "$CLUSTER-cluster-role-cli" --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

keep NODE_ROLE_ARN "$(aws iam create-role --role-name "$CLUSTER-node-role-cli" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --query Role.Arn --output text)"
for p in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy --role-name "$CLUSTER-node-role-cli" --policy-arn "arn:aws:iam::aws:policy/$p"
done

POD_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
for r in lbc:arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-lbc \
         external-dns:arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-external-dns \
         ebs-csi:arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy; do
  name="$CLUSTER-${r%%:*}-cli"
  aws iam create-role --role-name "$name" --assume-role-policy-document "$POD_TRUST" --query Role.Arn --output text
  aws iam attach-role-policy --role-name "$name" --policy-arn "${r#*:}"
done
```

| Trust principal | Who may assume the role |
| --- | --- |
| `eks.amazonaws.com` | the EKS control plane |
| `ec2.amazonaws.com` | the worker node instances |
| `pods.eks.amazonaws.com` | the Pod Identity agent, on behalf of the pod matched by an association (A.6) |

### A.4 Cluster

```bash
aws eks create-cluster --name "$CLUSTER" --kubernetes-version "$K8S_VERSION" --role-arn "$CLUSTER_ROLE_ARN" \
  --resources-vpc-config "subnetIds=$PRIV0,$PRIV1,$PRIV2,$PUB0,$PUB1,$PUB2,endpointPublicAccess=true,endpointPrivateAccess=true" \
  --access-config authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator"],"enabled":true}]}' \
  --tags project=eks-argocd-observability --query cluster.status
aws eks wait cluster-active --name "$CLUSTER"        # about 8-12 minutes
```

### A.5 Add-ons and node group

```bash
aws eks create-addon --cluster-name "$CLUSTER" --addon-name eks-pod-identity-agent
aws eks create-addon --cluster-name "$CLUSTER" --addon-name vpc-cni --configuration-values '{"enableNetworkPolicy":"true"}'
aws eks create-addon --cluster-name "$CLUSTER" --addon-name kube-proxy

aws eks create-nodegroup --cluster-name "$CLUSTER" --nodegroup-name general \
  --node-role "$NODE_ROLE_ARN" --subnets "$PRIV0" "$PRIV1" "$PRIV2" \
  --instance-types "$NODE_TYPE" --ami-type AL2023_x86_64_STANDARD --disk-size 20 \
  --scaling-config "minSize=$NODE_MIN,maxSize=$NODE_MAX,desiredSize=$NODE_DESIRED" --labels role=general
aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name general

aws eks create-addon --cluster-name "$CLUSTER" --addon-name coredns
aws eks create-addon --cluster-name "$CLUSTER" --addon-name metrics-server
aws eks create-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver \
  --pod-identity-associations "serviceAccount=ebs-csi-controller-sa,roleArn=arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER-ebs-csi-cli"
```

### A.6 Pod Identity associations for the controllers

```bash
aws eks create-pod-identity-association --cluster-name "$CLUSTER" --namespace kube-system \
  --service-account aws-load-balancer-controller --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER-lbc-cli"
aws eks create-pod-identity-association --cluster-name "$CLUSTER" --namespace external-dns \
  --service-account external-dns --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$CLUSTER-external-dns-cli"
for a in $(aws eks list-addons --cluster-name "$CLUSTER" --query addons --output text); do
  printf '%-24s %s\n' "$a" "$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --query addon.status --output text)"
done                                                  # all ACTIVE
```

Now continue with **[Step 8](#step-8-connect-kubectl-and-cluster-access)**.

### A.7 Clean up the plain-CLI cluster

First do clean-up steps 1–2 above. Then delete in **reverse** order:

```bash
source scripts/config.env && source .cli-ids.env
aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name general
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name general
for a in $(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --query 'associations[].associationId' --output text); do
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER" --association-id "$a"; done
aws eks delete-cluster --name "$CLUSTER" && aws eks wait cluster-deleted --name "$CLUSTER"

aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" && aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT"
aws ec2 release-address --allocation-id "$EIP"
for e in $(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID --query 'VpcEndpoints[].VpcEndpointId' --output text); do
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$e"; done
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
for s in "$PUB0" "$PUB1" "$PUB2" "$PRIV0" "$PRIV1" "$PRIV2"; do aws ec2 delete-subnet --subnet-id "$s"; done
aws ec2 delete-route-table --route-table-id "$PUB_RT"; aws ec2 delete-route-table --route-table-id "$PRIV_RT"
for g in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
  aws ec2 delete-security-group --group-id "$g"; done
aws ec2 delete-vpc --vpc-id "$VPC_ID"

for r in cluster-role node-role lbc external-dns ebs-csi; do
  name="$CLUSTER-$r-cli"
  for p in $(aws iam list-attached-role-policies --role-name "$name" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$name" --policy-arn "$p"; done
  aws iam delete-role --role-name "$name"
done
rm -f .cli-ids.env
```

Then do clean-up steps 4–6 above (ECR, the two controller policies, Route 53 records).
