# Build everything from the AWS Console (step by step)

This guide builds the same platform as `terraform/` and `scripts/`, by clicking through the AWS
Console: the EKS cluster, Argo CD, the app, **and the observability stack** (Prometheus, Grafana,
Loki, Alloy). A few steps can't be done in the AWS Console at all (Helm installs, Kubernetes
secrets). For those, this guide uses **AWS CloudShell**, a terminal inside the console, so you
never leave the browser. You can run the same commands from **your PC** instead (Step 8, Option B).

> **Use one path only.** The console, the scripts and Terraform all create resources with the
> same names (`obs-eks-*`). If you mix them in one account, the names collide.

**Values used in this guide.** Replace them if yours differ:

| Setting | Value |
| --- | --- |
| Region | `ap-south-1` (Mumbai). Pick it top-right in the console **before every step** |
| Cluster name | `obs-eks` |
| Kubernetes version | `1.36` |
| VPC CIDR | `10.2.0.0/16` |
| Domain (Route 53 hosted zone) | `bestclick.click` |
| App URL | `https://obs-bmi.bestclick.click` |
| Argo CD URL | `https://obs-argocd.bestclick.click` |
| Grafana URL | `https://obs-grafana.bestclick.click` |
| Git repo Argo CD watches | `https://github.com/abip007/eks-argocd-observability.git` |

Sign in to the console as your **IAM user** (for example `abip007`), never as root.
The identity that creates the cluster becomes its first admin.

---

## Step 0: Put the project on GitHub

Argo CD deploys whatever is in Git, so the repo has to exist first.

1. On GitHub: **New repository** → name `eks-argocd-observability` → **Public** (a private
   repo needs credentials in Argo CD; see [Troubleshooting](#troubleshooting)) → **Create**.
2. On your PC:
   ```bash
   cd C:/DevOps/eks-argocd-observability
   git init -b main && git add -A && git commit -m "Initial import"
   git remote add origin https://github.com/abip007/eks-argocd-observability.git
   git push -u origin main
   ```

You'll fill in the placeholders in [Step 10](#step-10-fill-in-the-git-placeholders), once you know the certificate ARN and the hosted zone ID.

---

## Step 1: VPC

**VPC console** → **Create VPC**

1. **Resources to create**: `VPC and more`
2. **Name tag auto-generation**: `obs-eks`
3. **IPv4 CIDR block**: `10.2.0.0/16`
4. **Number of Availability Zones**: `3`
5. **Number of public subnets**: `3`. **Number of private subnets**: `3`
6. **Customize subnets CIDR blocks**: public `10.2.0.0/20`, `10.2.16.0/20`, `10.2.32.0/20`;
   private `10.2.64.0/19`, `10.2.96.0/19`, `10.2.128.0/19`. Use larger private subnets because every pod gets a VPC IP.
7. **NAT gateways**: `In 1 AZ` (cheap). `1 per AZ` is the high-availability option and costs about 3×.
8. **VPC endpoints**: `S3 Gateway`. It's free and cuts NAT traffic for ECR image layers.
9. **DNS options**: enable both **DNS hostnames** and **DNS resolution**.
10. **Create VPC**.

### 1.1 Tag the subnets (the ALB won't be created without these)

**VPC → Subnets**. For each subnet, go to **Tags** → **Manage tags** → **Add new tag**:

| Subnets | Key | Value |
| --- | --- | --- |
| the 3 **public** ones | `kubernetes.io/role/elb` | `1` |
| the 3 **private** ones | `kubernetes.io/role/internal-elb` | `1` |

Then, for each **public** subnet: **Actions → Edit subnet settings** → tick
**Enable auto-assign public IPv4 address** → Save.

---

## Step 2: IAM roles

**IAM console → Roles → Create role.** Create these five roles.

### 2.1 Cluster role `obs-eks-cluster-role`
- Trusted entity: **AWS service** → Use case **EKS** → **EKS - Cluster**
- Permissions: `AmazonEKSClusterPolicy` (pre-selected)
- Name: `obs-eks-cluster-role` → **Create role**

### 2.2 Node role `obs-eks-node-role`
- Trusted entity: **AWS service** → Use case **EC2**
- Permissions: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly`,
  `AmazonEKS_CNI_Policy`, `AmazonSSMManagedInstanceCore` (lets you open a shell on a node without SSH keys)
- Name: `obs-eks-node-role`

### 2.3 Controller policies (create these first)
**IAM → Policies → Create policy → JSON tab**, paste the file contents, then click **Next** and enter the name:

| Policy name | Paste this file |
| --- | --- |
| `obs-eks-lbc` | [`policies/aws-load-balancer-controller.json`](../policies/aws-load-balancer-controller.json) |
| `obs-eks-external-dns` | [`policies/external-dns.json`](../policies/external-dns.json) |

### 2.4 Pod Identity roles (one per controller)
For each row: **Create role** → Trusted entity **AWS service** → Use case **EKS** →
**EKS - Pod Identity** → attach the policy → name it.

| Role name | Attach policy |
| --- | --- |
| `obs-eks-ebs-csi` | `AmazonEBSCSIDriverPolicy` (AWS managed) |
| `obs-eks-lbc` | `obs-eks-lbc` (from 2.3) |
| `obs-eks-external-dns` | `obs-eks-external-dns` (from 2.3) |

> The observability stack needs **no IAM role**: Prometheus, Grafana, Loki and Alloy only talk to
> the Kubernetes API and to each other. Their volumes are created by the EBS CSI driver's role.

---

## Step 3: EKS cluster

**EKS console → Clusters → Create cluster**

1. Choose **Custom configuration** and turn **EKS Auto Mode off**. This project
   manages its own node group and add-ons.
2. **Configure cluster**
   - Name `obs-eks`, Kubernetes version `1.36`
   - Cluster IAM role: `obs-eks-cluster-role`
   - **Cluster access**: *Bootstrap cluster administrator access* = **Allow**;
     *Cluster authentication mode* = **EKS API**
   - **Upgrade policy**: **Standard** (avoids paid extended support)
   - **Next**
3. **Specify networking**
   - VPC: `obs-eks-vpc`
   - Subnets: select **only the 3 private** subnets
   - Security groups: leave empty (EKS creates the cluster security group)
   - Cluster endpoint access: **Public and private**. Under *Advanced settings* you can
     restrict the public endpoint to your IP (`curl https://checkip.amazonaws.com`).
   - **Next**
4. **Configure observability**: under *Control plane logs*, tick **API server**, **Audit**,
   **Authenticator** → **Next**. (Leave *Prometheus metrics* / *Amazon Managed Service for
   Prometheus* off: this project runs its own Prometheus inside the cluster.)
5. **Select add-ons**: tick **Amazon VPC CNI**, **kube-proxy**, **CoreDNS**,
   **Amazon EKS Pod Identity Agent**, **Metrics Server**, **Amazon EBS CSI Driver** → **Next**
6. **Configure selected add-ons settings**
   - **Amazon EBS CSI Driver** → *Pod Identity IAM role for service account*: `obs-eks-ebs-csi`
   - **Amazon VPC CNI** → *Optional configuration settings* → *Configuration values*:
     `{"enableNetworkPolicy":"true"}`
   - Use the default (latest) version for everything else → **Next**
7. **Review and create** → **Create**. Status changes from *Creating* to **Active** in about 10–15 minutes.

---

## Step 4: Node group

**Cluster `obs-eks` → Compute tab → Add node group**

1. Name `general`, Node IAM role `obs-eks-node-role`, Kubernetes label `role` = `general` → **Next**
2. AMI type **Amazon Linux 2023 (x86_64) Standard**, Capacity **On-Demand**, Instance type **m7i-flex.large**, Disk **20 GiB**.
   m7i-flex.large is free-plan eligible and fits 29 pods; a t3.small fits only 11, which causes "Too many pods".
3. Scaling: **Minimum 2 / Desired 3 / Maximum 5**. Maximum unavailable: **1 node** → **Next**.
   The third node is for the observability stack (Prometheus alone asks for 1 GiB of memory).
4. Subnets: the **3 private** subnets. Leave *Configure remote access* **off** → **Next** → **Create**

Wait until the node group is **Active** and the **Add-ons** tab shows every add-on as *Active*. CoreDNS and the EBS CSI driver only turn Active once nodes are running.

---

## Step 5: Pod Identity associations for the controllers

**Cluster → Access tab → Pod Identity associations → Create.** The namespaces don't have to exist yet.

| IAM role | Kubernetes namespace | Service account |
| --- | --- | --- |
| `obs-eks-lbc` | `kube-system` | `aws-load-balancer-controller` |
| `obs-eks-external-dns` | `external-dns` | `external-dns` |

The EBS CSI association was already created by the add-on in Step 3.6.

### 5.1 Cluster access for your CLI identity (only if it's different)
**Access tab → IAM access entries.** The console user that created the cluster already has admin.
If your PC's `aws` profile uses a **different** IAM identity: **Create access entry** →
choose its ARN → Type *Standard* → **Add policy** `AmazonEKSClusterAdminPolicy`, scope *Cluster* → Create.

---

## Step 6: ECR repositories

**ECR console → Private registry → Repositories → Create repository.** Create two:

- `obs-eks/bmi-backend`
- `obs-eks/bmi-frontend`

Settings for both: **Image tag mutability = Immutable** (a tag in Git then always means
the same image). Turn on scan on push (or *basic scanning* under **Private registry → Settings → Scanning**).

---

## Step 7: Route 53 zone and ACM certificate

### 7.1 Hosted zone ID
**Route 53 → Hosted zones** → `bestclick.click` (type **Public**) → copy the **Hosted zone ID**
(`Z0…`). You need it in Step 10.

> If there are **two** zones named `bestclick.click`, only one is live: the one whose 4 **NS**
> records match **Route 53 → Registered domains → bestclick.click → Name servers**. Use that one.
> ExternalDNS is pinned to it, so records never land in the wrong zone.

### 7.2 Certificate
**Certificate Manager (in `ap-south-1`) → Request → Request a public certificate**

1. Fully qualified domain name: `bestclick.click` → **Add another name**: `*.bestclick.click`
2. Validation: **DNS validation**, key algorithm RSA 2048 → **Request**
3. Open the certificate → **Create records in Route 53** → **Create records**
4. Wait until the status is **Issued** (1–5 minutes). **Copy the ARN** because you'll need it in Step 10.

> If an **Issued** certificate for `bestclick.click` + `*.bestclick.click` already exists
> (from `eks-argocd-3tier`), reuse it and skip this step. The wildcard covers `obs-grafana` too.

---

## Step 8: Open a terminal and connect to the cluster

Steps 9–12 and the clean-up need `kubectl` and `helm`. Run them from **one** of these:

| Option | Where | Good for |
| --- | --- | --- |
| **A. AWS CloudShell** (recommended) | Browser, inside the console | Nothing to install, already signed in as the cluster admin, clock always correct |
| **B. Your PC** | Git Bash on Windows (or any bash) | Keeping your files and history; you need Docker Desktop on the PC anyway for Step 13 |

Pick one and use it for Steps 9–12. Where later steps say **"in your terminal"**, they mean the one you picked.

### Option A: AWS CloudShell

Click the **CloudShell** icon (`>_`) in the console header. It runs in the browser as your
console identity, which is the cluster admin, and its clock is always correct (see
[Troubleshooting](#troubleshooting) for why that matters).

```bash
# kubectl + helm (skip whichever is already installed)
command -v kubectl || { curl -sLO "https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl" && chmod +x kubectl && mkdir -p ~/bin && mv kubectl ~/bin/; }
command -v helm    || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

aws eks update-kubeconfig --name obs-eks --region ap-south-1
kubectl get nodes            # 3 nodes, STATUS Ready

git clone https://github.com/abip007/eks-argocd-observability.git && cd eks-argocd-observability
```

> CloudShell keeps only your home folder (1 GB) and deletes it after 120 days without use.
> Sessions time out after about 20 minutes idle. Run `cd ~/eks-argocd-observability` again after reconnecting.

### Option B: Your PC (Git Bash)

**1. Install the tools** (PowerShell, once; then open a new Git Bash window):
```powershell
winget install Amazon.AWSCLI Kubernetes.kubectl Helm.Helm Git.Git
```

**2. Sign in as your IAM user** (never root keys). Use an access key from
**IAM → Users → `abip007` → Security credentials → Create access key → CLI**:
```bash
aws configure --profile abip007          # region ap-south-1, output json
export AWS_PROFILE=abip007 AWS_REGION=ap-south-1
aws sts get-caller-identity              # Arn must be the user that created the cluster
```
If the ARN is a **different** identity than the console user that created the cluster, give it
access first (Step 5.1), or `kubectl` returns `Unauthorized`.

**3. Check your clock.** Helm signs the LB Controller's webhook certificate with your PC's clock.
If it's more than a few seconds off, Step 9.2 fails with `x509: certificate ... not yet valid`:
```bash
aws_date=$(curl -sI https://sts.ap-south-1.amazonaws.com | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2}')
echo "skew: $(( $(date -u +%s) - $(date -u -d "$aws_date" +%s) ))s"     # should be between -5 and 5
```
If it isn't, fix it in **admin PowerShell**: `Start-Service w32time; w32tm /resync /force`.

**4. Connect and get the repo:**
```bash
aws eks update-kubeconfig --name obs-eks --region ap-south-1
kubectl get nodes            # 3 nodes, STATUS Ready

cd /c/DevOps                 # or wherever you keep projects
git clone https://github.com/abip007/eks-argocd-observability.git && cd eks-argocd-observability
# already cloned in Step 0? just: cd eks-argocd-observability && git pull
```

> **Windows Helm cache:** if `helm` later says `no cached repo found`, delete
> `%LOCALAPPDATA%\Temp\helm` and `%APPDATA%\helm\repositories.yaml`, or use a private cache:
> `export HELM_CACHE_HOME=$PWD/.helm/cache HELM_CONFIG_HOME=$PWD/.helm/config HELM_DATA_HOME=$PWD/.helm/data`.

---

## Step 9: Install the platform (in your terminal)

These are the same commands `scripts/02-install-platform.sh` runs.

### 9.1 Default StorageClass `gp3`
```bash
kubectl apply -f platform/storageclass-gp3.yaml
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite 2>/dev/null || true
```

### 9.2 Gateway API CRDs + AWS Load Balancer Controller
```bash
kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/config/crd/gateway/gateway-crds.yaml

VPC_ID=$(aws eks describe-cluster --name obs-eks --query cluster.resourcesVpcConfig.vpcId --output text)
helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts -n kube-system \
  --set clusterName=obs-eks --set region=ap-south-1 --set vpcId=$VPC_ID \
  --set serviceAccount.name=aws-load-balancer-controller --wait
kubectl -n kube-system get deploy aws-load-balancer-controller     # 2/2 READY
```

---

## Step 10: Fill in the Git placeholders

Argo CD reads real values from Git, so replace the `__PLACEHOLDER__` values and push.

**Option A: let the script do it** (on your PC, in Git Bash):
```bash
bash scripts/00-configure.sh      # finds the zone + your ISSUED cert, fills every file
git add -A && git commit -m "Configure for obs-eks" && git push
```

**Option B: by hand** (GitHub web editor works too). Replace these values in these files:

| File | Placeholders |
| --- | --- |
| `gitops/bmi-app/overlays/prod/kustomization.yaml` | `__ACCOUNT_ID__` (12 digits, top-right menu), `__REGION__`, `__CLUSTER__`, `__APP_HOST__`, `__CERT_ARN__` |
| `gitops/argocd/root-app.yaml`, every file in `gitops/argocd/apps/` | `__GIT_REPO_URL__` |
| `gitops/observability/kube-prometheus-stack-values.yaml` | `__GRAFANA_HOST__`, `__CLUSTER__`, `__CERT_ARN__` |
| `gitops/observability/alloy-values.yaml` | `__CLUSTER__` |
| `platform/argocd-values.yaml` | `__ARGOCD_HOST__`, `__CLUSTER__`, `__CERT_ARN__` |
| `platform/external-dns-values.yaml` | `__REGION__`, `__DOMAIN__`, `__ZONE_ID__` (Step 7.1, without `/hostedzone/`), `__CLUSTER__` |

(`eksctl/cluster.yaml` has placeholders too, but the console path doesn't use it.)

Back in your terminal, pull the change: `git pull`. Check nothing is left: `grep -rn '__[A-Z_]*__' gitops platform` prints nothing.

---

## Step 11: ExternalDNS, Prometheus Operator CRDs, Argo CD (in your terminal)

```bash
helm upgrade --install external-dns external-dns \
  --repo https://kubernetes-sigs.github.io/external-dns/ -n external-dns --create-namespace \
  -f platform/external-dns-values.yaml --wait

# CRDs for ServiceMonitor / PrometheusRule / ... BEFORE Argo CD: Argo CD's values create
# ServiceMonitors so Prometheus can scrape Argo CD itself.
helm upgrade --install prometheus-operator-crds prometheus-operator-crds \
  --repo https://prometheus-community.github.io/helm-charts --version 33.0.1 \
  -n observability --create-namespace --wait
kubectl get crd | grep monitoring.coreos.com       # servicemonitors, prometheusrules, ...

helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm -n argocd --create-namespace \
  -f platform/argocd-values.yaml --wait

kubectl -n argocd get ingress          # ADDRESS = k8s-obseks-....elb.amazonaws.com after ~2 min
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Check the results in the console:
- **EC2 → Load Balancers**: a new ALB `k8s-obseks-…`, state *Active*
- **Route 53 → Hosted zones → bestclick.click**: ExternalDNS added `obs-argocd` **A** and **TXT** records

---

## Step 12: Secrets (in your terminal, never in Git)

```bash
# App database
kubectl create namespace bmi-app
DB_PASS=$(openssl rand -hex 16)
kubectl -n bmi-app create secret generic postgres-secret \
  --from-literal=POSTGRES_DB=bmidb --from-literal=POSTGRES_USER=bmi_user --from-literal=POSTGRES_PASSWORD=$DB_PASS
kubectl -n bmi-app create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgres://bmi_user:$DB_PASS@bmi-postgres-svc:5432/bmidb"

# Grafana admin login (the observability namespace was created in Step 11)
kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -hex 12)"
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo   # note it
```

---

## Step 13: First images (on your PC; needs Docker Desktop)

**ECR → `obs-eks/bmi-backend` → View push commands** shows the login command. Then:

```bash
cd C:/DevOps/eks-argocd-observability
ACCOUNT=<your 12-digit id>; REG=$ACCOUNT.dkr.ecr.ap-south-1.amazonaws.com; TAG=v1
aws ecr get-login-password --region ap-south-1 --profile abip007 | docker login --username AWS --password-stdin $REG
docker build --platform linux/amd64 -t $REG/obs-eks/bmi-backend:$TAG  app/backend
docker build --platform linux/amd64 -t $REG/obs-eks/bmi-frontend:$TAG app/frontend
docker push $REG/obs-eks/bmi-backend:$TAG && docker push $REG/obs-eks/bmi-frontend:$TAG
```

Then on **GitHub**, edit `gitops/bmi-app/overlays/prod/kustomization.yaml`, set **both**
`newTag:` lines to `v1`, and **Commit changes**.

(`bash scripts/03-release.sh` does all of Step 13 in one command.)

---

## Step 14: Create the Argo CD root application (Argo CD UI)

Open **https://obs-argocd.bestclick.click** (wait 2–5 minutes for DNS) and log in as `admin` with the password from Step 11.

**+ NEW APP**:

| Field | Value |
| --- | --- |
| Application Name | `root` |
| Project Name | `default` |
| Sync Policy | **Automatic**, tick **Prune Resources** and **Self Heal** |
| Repository URL | `https://github.com/abip007/eks-argocd-observability.git` |
| Revision | `main` |
| Path | `gitops/argocd/apps` |
| Cluster URL | `https://kubernetes.default.svc` |
| Namespace | `argocd` |

**CREATE.** The `root` app finds the five files in `gitops/argocd/apps/` and creates five child applications:

| Application | Deploys | Into namespace |
| --- | --- | --- |
| `bmi-app` | Postgres, migrations Job, backend + HPA + ServiceMonitor, frontend, Ingress | `bmi-app` |
| `kube-prometheus-stack` | Prometheus Operator, Prometheus, Alertmanager, Grafana (+ Ingress), node-exporter, kube-state-metrics | `observability` |
| `loki` | Loki single binary + 10 GiB volume | `observability` |
| `alloy` | Alloy log collector | `observability` |
| `observability-extras` | BMI dashboard ConfigMap, BMI PrometheusRule | `observability` |

`bmi-app` syncs in waves:

1. wave 0: Postgres StatefulSet + EBS volume (gp3)
2. wave 1: `bmi-migrations` Job (Sync hook) runs the SQL
3. wave 2: backend + HPA + ServiceMonitor, frontend
4. wave 3: Ingress. The ALB gets an HTTPS rule for the app, and ExternalDNS creates `obs-bmi`.

The Grafana Ingress joins the same ALB, and ExternalDNS creates `obs-grafana`.
The first sync of all five takes about 3–5 minutes.

(The same thing without the UI: `kubectl apply -f gitops/argocd/root-app.yaml`.)

---

## Step 15: Verify

- Argo CD UI: `root` and all 5 child apps are **Healthy** and **Synced**
- Open **https://obs-bmi.bestclick.click**, add a measurement, and refresh. The data is stored in Postgres.
- **EC2 → Volumes**: 4 gp3 encrypted volumes are *in-use*: Postgres 10 GiB, Prometheus 20 GiB, Loki 10 GiB, Alertmanager 2 GiB
- **EC2 → Load Balancers → `k8s-obseks-…` → Listeners → HTTPS:443 → rules**: one rule per host (`obs-bmi`, `obs-argocd`, `obs-grafana`)
- Your terminal: `kubectl -n bmi-app get pods,hpa,ingress,pvc` and `kubectl -n observability get pods,pvc,ingress`

---

## Step 16: Explore observability (Grafana UI)

Open **https://obs-grafana.bestclick.click** and log in as `admin` with the password from Step 12.

### 16.1 Data sources
**Connections → Data sources** shows **Prometheus** (added by the chart) and **Loki** (added by
`additionalDataSources` in the values file). Open each → **Save & test** → *Successfully queried*.

### 16.2 Dashboards
**Dashboards** lists:
- folder **BMI** → **BMI app**: up pods, requests/s, 5xx ratio, p95 latency, restarts, Postgres
  disk, CPU/memory per pod, log rate, and the live logs of the `bmi-app` namespace. Click around
  the app to make the numbers move.
- **Kubernetes / Compute Resources / Cluster**, **… / Namespace (Pods)**, **Node Exporter / Nodes**:
  the standard dashboards that ship with kube-prometheus-stack.

### 16.3 Explore metrics (PromQL)
**Explore** → data source **Prometheus** → switch the editor to **Code** and try:

| Question | PromQL |
| --- | --- |
| Is everything being scraped? | `up == 0` (empty = all targets up) |
| Requests per second per route | `sum by (route) (rate(http_request_duration_seconds_count{namespace="bmi-app"}[5m]))` |
| p95 API latency | `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="bmi-app"}[5m])))` |
| Memory per pod | `sum by (pod) (container_memory_working_set_bytes{namespace="bmi-app", container!=""})` |
| Node CPU busy % | `100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))` |
| Argo CD apps not healthy | `argocd_app_info{health_status!="Healthy"}` |

### 16.4 Explore logs (LogQL)
**Explore** → data source **Loki** → **Code**:

| Question | LogQL |
| --- | --- |
| All app logs | `{namespace="bmi-app"}` |
| Backend errors only | `{app="bmi-backend"} \| json \| level="error"` |
| Slow requests | `{app="bmi-backend"} \| json \| msg="request" \| duration_ms > 200` |
| 5xx per minute | `sum(count_over_time({app="bmi-backend"} \| json \| status >= 500 [1m]))` |
| Kubernetes events (OOMKilled, image pull, scheduling) | `{job="kubernetes-events"}` |
| Logs of one pod | `{namespace="bmi-app", pod=~"bmi-backend-.*"}` |

Or use **Drilldown → Logs** to browse logs by label without writing queries.

### 16.5 Alerts
**Alerting → Alert rules** shows the Prometheus rules, including the **bmi-app** group
(`BmiBackendDown`, `BmiHighErrorRate`, `BmiHighLatency`, `BmiPostgresVolumeFilling`).
`Watchdog` always fires on purpose: it proves the alert pipeline works.

**Try it: make an alert fire.**

1. Argo CD → `bmi-app` → **Details → Sync policy → Disable auto-sync**. Otherwise Self Heal undoes the next step.
2. In your terminal (CloudShell or PC):
   ```bash
   kubectl -n bmi-app delete hpa bmi-backend                  # the HPA would scale it back up
   kubectl -n bmi-app scale deploy bmi-backend --replicas=0
   ```
3. Within about 3 minutes `BmiBackendDown` goes *Pending*, then *Firing* (the rule has `for: 2m`).
   The app shows errors, and the dashboard's "Backend pods up" turns red.
4. Restore: Argo CD → `bmi-app` → **Enable auto-sync** (it recreates the HPA), then
   `kubectl -n bmi-app scale deploy bmi-backend --replicas=2`. The HPA doesn't scale up from 0 by itself. The alert resolves.

---

## Day 2: Deploy a new version (the GitOps loop)

1. Change code in `app/`.
2. Build and push images with a **new** tag (Step 13 with `TAG=v2`). Tags are immutable,
   so pushing `v1` again fails.
3. Set `newTag: v2` in the overlay and commit.
4. Argo CD notices the commit within about 60 seconds and runs a rolling update. To see it immediately, click
   **REFRESH** in the UI. Watch it on the **BMI app** dashboard: pods restart, latency and errors stay flat.

**Change the observability stack the same way:** edit `gitops/observability/*-values.yaml` on
GitHub (for example `retention: 15d`) and commit. Argo CD runs `helm upgrade` for you.

Rollback: revert that commit in Git, or use Argo CD → `bmi-app` → **History and rollback**.
A manual `kubectl edit` is undone automatically by **Self Heal**, because Git always wins.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `x509: certificate has expired or is not yet valid ... mservice.elbv2.k8s.aws` | Helm signs the LB Controller webhook certificate with the clock of the machine running Helm. Your PC's clock is ahead of AWS. | Run Helm from CloudShell, or fix your PC's clock (admin PowerShell: `Start-Service w32time; w32tm /resync /force`), then `helm uninstall` the failed release and reinstall it. |
| Argo CD install: `no matches for kind "ServiceMonitor"` | Prometheus Operator CRDs not installed yet | Run the `prometheus-operator-crds` install from Step 11, then the Argo CD install again |
| Helm: `cannot re-use a name that is still in use` | A failed release is still installed | `helm -n <ns> uninstall <name>` and run the install again |
| Helm: `no cached repo found` | Stale global Helm cache on Windows (`%TEMP%\helm`) | `helm repo update`. The scripts and Terraform use a private `.helm/` folder, which avoids this. |
| Ingress has no ADDRESS | Subnets missing the `kubernetes.io/role/elb` tag (Step 1.1), or the LBC is missing its Pod Identity association (Step 5) | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Pods `Pending`, "Too many pods" or "Insufficient memory" | Not enough nodes for the app + observability | Raise the node group's desired size to 3–4 (Step 4) |
| A PVC stays `Pending` | EBS CSI add-on has no role / StorageClass missing | Step 3.6 role + Step 9.1 |
| `kube-prometheus-stack` app *Degraded*, Grafana pod `CreateContainerConfigError` | Secret `grafana-admin` missing | Step 12, then delete the Grafana pod |
| Grafana: Loki data source fails | Loki pod not ready yet, or wrong URL | `kubectl -n observability get pods -l app.kubernetes.io/name=loki`; URL must be `http://loki.observability.svc.cluster.local:3100` |
| No logs in Loki | Alloy not running or can't reach Loki | `kubectl -n observability logs deploy/alloy` |
| BMI dashboard: "No data" in metric panels | Backend image without `/metrics`, or ServiceMonitor not picked up | Prometheus UI → **Status → Targets** (port-forward, see the command-line guide) should list `bmi-app/bmi-backend` |
| `bmi-backend` CrashLoopBackOff "password authentication failed" | Secrets were recreated after the database was initialised | Recreate the secrets with the old password, or delete PVC `data-postgres-0` (this **deletes the data**) |
| App `ImagePullBackOff` | `newTag` points to a tag that was never pushed | Push the image, or fix the tag in Git |
| Argo CD `repository not found` | The repo is private | Argo CD → **Settings → Repositories → CONNECT REPO** (HTTPS + GitHub token) |
| DNS name doesn't resolve | ExternalDNS has no permissions / wrong `domainFilters` / wrong `--zone-id-filter` | `kubectl -n external-dns logs deploy/external-dns` |

---

## Clean up (in this order, or the VPC won't delete)

1. **Argo CD UI** → `root` → **DELETE** (cascade, foreground). This removes all 5 child apps, their Ingresses and pods.
2. In your terminal (CloudShell or PC):
   ```bash
   kubectl delete namespace bmi-app observability       # frees the 4 EBS volumes (PVCs aren't pruned by Argo CD)
   helm -n argocd uninstall argocd                     # removes the Argo CD Ingress, which removes the ALB
   sleep 60
   helm -n external-dns uninstall external-dns
   helm -n kube-system uninstall aws-load-balancer-controller
   ```
3. **EC2 → Load Balancers**: confirm no `k8s-obseks-…` ALB is left (delete it if there is one).
   **EC2 → Volumes**: no *available* volumes tagged with `obs-eks` left.
4. **EKS** → `obs-eks` → **Compute** → delete node group `general`, wait, then **Delete cluster**.
5. **VPC console** → select `obs-eks-vpc` → **Actions → Delete VPC**. This deletes the NAT gateway, subnets and endpoint.
   Then **Elastic IPs**: release the NAT's EIP if it's still allocated.
6. **ECR**: delete both `obs-eks/*` repositories. **IAM**: delete the 5 `obs-eks-*` roles and 2 policies.
7. **Route 53**: delete the `obs-bmi` / `obs-argocd` / `obs-grafana` A and TXT records. ExternalDNS runs in
   upsert-only mode, so it never deletes them itself. Keep the ACM certificate if other projects use it.
