# BMI Health Tracker on EKS with Argo CD + observability (Prometheus, Grafana, Loki)

The same 3-tier app as `eks-argocd-3tier` (React/nginx → Node.js API → PostgreSQL on EBS) on
Amazon EKS, deployed with **GitOps**, plus a full **observability stack**, also deployed by Argo CD:

| Tool | Job |
| --- | --- |
| **Prometheus** (kube-prometheus-stack) | collects **metrics**: nodes, pods, Kubernetes objects, Argo CD, Loki, and the app's own `/metrics` |
| **Alertmanager** | receives **alerts** from Prometheus rules (default + BMI-specific) |
| **Grafana** | **dashboards** and **Explore** for metrics (PromQL) and logs (LogQL), at `https://obs-grafana.<domain>` |
| **Loki** | stores **logs** (single binary, gp3 EBS volume, 7-day retention) |
| **Grafana Alloy** | **collects** every pod's logs plus Kubernetes events and pushes them to Loki |

```
 git push ──► GitHub ◄── polls every 60 s ── Argo CD ──► bmi-app + observability namespaces
                                                          │
 Browser ─HTTPS─► ALB (ACM cert, one ALB for 3 hosts)
                   ├─ obs-bmi.…     ──► frontend (nginx) ──/api──► backend ──► postgres (gp3 EBS)
                   ├─ obs-argocd.…  ──► Argo CD                        │ /metrics + JSON logs
                   └─ obs-grafana.… ──► Grafana ◄── PromQL ── Prometheus ◄─ scrape ─┘
                                           ▲                     │ alerts → Alertmanager
                                           └── LogQL ── Loki ◄── Alloy ◄── pod logs + events
 Route 53 ◄── ExternalDNS writes A records for every Ingress host
```

## Three ways to build the platform (pick one)

All three create the same thing: VPC, EKS cluster, node group, add-ons, Pod Identity roles, ECR
repos, LB Controller, ExternalDNS, Prometheus Operator CRDs and Argo CD. After that, **Argo CD
deploys the app and the observability stack from `gitops/` in every case.**

| Path | Start here | Best for |
| --- | --- | --- |
| AWS Console (click-by-click + CloudShell) | [docs/01-console-guide.md](docs/01-console-guide.md) | Learning what each piece is |
| Command line, step by step (what the scripts do, one command at a time) | [docs/02-command-line-guide.md](docs/02-command-line-guide.md) | Understanding and debugging the scripts |
| Shell scripts (eksctl + helm) | [Shell path](#shell-path) | Fast, repeatable, few tools |
| Terraform | [Terraform path](#terraform-path) | Infrastructure as code with state, plan and destroy |

Resource names start with `obs-eks-*`. They don't collide with `eks-argocd-3tier` (`argo-eks-*`),
so both projects can live in one account. Inside this project, **don't mix paths**.

### Common first steps (all paths)

1. Create the GitHub repo `eks-argocd-observability` (public, or add credentials in Argo CD) and push this folder.
2. Edit [scripts/config.env](scripts/config.env) (profile, region, domain, hosts, Git URL).
3. `bash scripts/00-configure.sh`. It finds the Route 53 zone, finds or requests the ACM certificate,
   then writes your account ID, hosts, certificate, zone and Git URL into `gitops/`, `platform/` and `eksctl/`.
4. `git add -A && git commit -m "configure" && git push`. Argo CD reads these values from Git.

Tools on your PC: AWS CLI v2, kubectl, Helm 3, Docker Desktop, Git Bash, and **eksctl** (shell
path, `winget install eksctl`) or **Terraform ≥ 1.6** (Terraform path).

### Shell path

```bash
bash scripts/01-create-cluster.sh     # IAM policies, ECR, eksctl cluster (~20 min)
bash scripts/02-install-platform.sh   # StorageClass, LBC, ExternalDNS, CRDs, Argo CD, secrets, root app
bash scripts/03-release.sh            # build + push images, bump tag in Git -> Argo CD deploys
bash scripts/99-destroy.sh            # tear everything down in the right order
```

### Terraform path

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars    # keep values equal to scripts/config.env; set zone_id
terraform init
terraform plan -out tf.plan && terraform apply tf.plan   # ~25 min, needs aws + kubectl on PATH
cd .. && bash scripts/03-release.sh             # first images -> Argo CD deploys the app
terraform -chdir=terraform output grafana_admin_password_command
```

## Day-2: the release loop

```bash
# change code in app/, then:
bash scripts/03-release.sh
```
Then watch the rollout in Grafana → **Dashboards → BMI → BMI app**: request rate, errors, latency,
pod CPU/memory and the app's logs on one page. To roll back, `git revert` the release commit.

## Layout

| Path | What |
| --- | --- |
| `app/` | Backend (Express + pg + **prom-client**, JSON logs) and frontend (React/Vite → nginx) |
| `gitops/argocd/` | `root-app.yaml` (app-of-apps) and `apps/`: bmi-app, kube-prometheus-stack, loki, alloy, observability-extras |
| `gitops/bmi-app/` | Kustomize base + prod overlay for the app, including its **ServiceMonitor** |
| `gitops/observability/` | Helm values for kube-prometheus-stack, Loki and Alloy |
| `gitops/observability/extras/` | BMI Grafana dashboard (ConfigMap) and alert rules (PrometheusRule) |
| `platform/` | StorageClass and Helm values for Argo CD / ExternalDNS (shell + console paths) |
| `policies/` | IAM policies for the LB Controller and ExternalDNS (used by all three paths) |
| `eksctl/cluster.yaml` | Cluster definition for the shell path |
| `terraform/` | Terraform path |
| `scripts/` | `config.env` + numbered scripts |

## How the observability stack is wired

- **Helm charts deployed by Argo CD.** Each tool is an Argo CD Application with two sources:
  the chart (pinned version) and the values file from this repo (`$values/...`). Changing a
  setting = edit `gitops/observability/*-values.yaml` and `git push`.
- **CRDs first.** The Prometheus Operator CRDs are installed by Helm *before* Argo CD, so Argo CD
  can create its own ServiceMonitors. kube-prometheus-stack runs with `crds.enabled: false`.
- **Prometheus finds targets by ServiceMonitor** in any namespace (`*SelectorNilUsesHelmValues: false`).
  The app ships one: `gitops/bmi-app/base/servicemonitor.yaml` → backend `/metrics`.
- **EKS control plane** components (etcd, scheduler, controller-manager) can't be scraped, so those
  jobs and their alert rules are turned off.
- **Logs**: one Alloy pod tails all containers through the Kubernetes API and adds labels
  `namespace`, `pod`, `container`, `app`, `node`, `cluster`. The backend logs one JSON line per
  request, so LogQL can filter on fields: `{app="bmi-backend"} | json | status >= 500`.
- **Grafana** gets its admin password from Secret `grafana-admin` (created outside Git) and loads
  every ConfigMap labelled `grafana_dashboard=1` as a dashboard.
- **Storage**: Prometheus 20 GiB (7 days), Loki 10 GiB (7 days), Alertmanager 2 GiB, all gp3 EBS.

## How the app deploy works

- **Sync waves**: Postgres (wave 0) → migrations Job (Sync hook, wave 1) → backend/frontend/ServiceMonitor (wave 2) → Ingress (wave 3).
- **Secrets are not in Git**: `postgres-secret`, `backend-secret` and `grafana-admin` are created by
  `02-install-platform.sh`, by Terraform (`random_password`), or by hand (console guide).
- **One ALB** for the app, Argo CD and Grafana (`alb.ingress.kubernetes.io/group.name: obs-eks`).
- **Pod Identity** (not IRSA) gives the LB Controller, ExternalDNS and the EBS CSI driver their AWS permissions.

## Lessons carried over

- **PC clock skew breaks Helm installs.** `02-install-platform.sh` checks the skew against AWS first.
- **Stale Windows Helm cache** (`no cached repo found`): the scripts and Terraform use a private `.helm/` folder.
- **A failed Helm release blocks reinstall** (`cannot re-use a name`). Run `helm uninstall` on it first.
- **Duplicate Route 53 zones**: ExternalDNS is pinned to one zone with `--zone-id-filter`.

Costs: the EKS control plane, NAT gateway, ALB, three m7i-flex.large nodes and about 42 GiB of gp3
volumes are billed by the hour. Destroy the stack when you're done.
#   e k s - a r g o c d - o b s e r v a b i l i t y  
 