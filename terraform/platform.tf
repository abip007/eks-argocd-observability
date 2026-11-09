# Everything inside the cluster: StorageClass, LB Controller, ExternalDNS, Prometheus
# Operator CRDs, Argo CD, app + Grafana secrets and the Argo CD root Application. After
# this Terraform never touches the app or the observability stack - Argo CD deploys both from Git.

# ---------- Storage ----------
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  parameters             = { type = "gp3", encrypted = "true", fsType = "ext4" }

  depends_on = [aws_eks_addon.ebs_csi]
}

# ---------- Gateway API CRDs (the LB Controller v3 expects them before it starts) ----------
# Needs aws + kubectl on PATH. One '&&' line works in bash and cmd.exe.
resource "terraform_data" "gateway_crds" {
  triggers_replace = [aws_eks_cluster.this.arn, var.gateway_api_version, var.aws_lbc_version]

  provisioner "local-exec" {
    command = join(" && ", [
      "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region} --kubeconfig ${local.kubeconfig_path} ${local.profile_flag}",
      "kubectl --kubeconfig ${local.kubeconfig_path} apply --server-side=true --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml",
      "kubectl --kubeconfig ${local.kubeconfig_path} apply --server-side=true --force-conflicts -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.aws_lbc_version}/config/crd/gateway/gateway-crds.yaml",
    ])
  }

  depends_on = [aws_eks_node_group.general]
}

# ---------- AWS Load Balancer Controller ----------
# NOTE: Helm signs this controller's webhook certificate with YOUR PC clock.
# If the clock is ahead of AWS, later releases fail with x509 "not yet valid"
# on mservice.elbv2.k8s.aws. Keep Windows Time running (w32tm /resync).
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_lbc_chart_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    clusterName    = aws_eks_cluster.this.name
    region         = var.region
    vpcId          = aws_vpc.this.id
    replicaCount   = 2
    serviceAccount = { create = true, name = "aws-load-balancer-controller" } # = Pod Identity association
  })]

  depends_on = [
    terraform_data.gateway_crds,
    aws_eks_pod_identity_association.controller,
    aws_eks_addon.coredns,
    aws_eks_addon.pod_identity_agent,
  ]
}

# ---------- ExternalDNS: Route 53 records for every Ingress host ----------
resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.external_dns_chart_version
  namespace        = "external-dns"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    provider       = { name = "aws" }
    env            = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
    domainFilters  = [var.domain_name]
    extraArgs      = ["--zone-id-filter=${var.zone_id}"] # only the delegated zone
    policy         = "upsert-only"
    txtOwnerId     = var.cluster_name
    sources        = ["ingress"]
    serviceAccount = { create = true, name = "external-dns" } # = Pod Identity association
  })]

  depends_on = [
    aws_eks_pod_identity_association.controller,
    helm_release.aws_load_balancer_controller, # webhook must be up before charts create Services
  ]
}

# ---------- Prometheus Operator CRDs ----------
# Before Argo CD, so Argo CD's ServiceMonitors can be created. kube-prometheus-stack
# (deployed by Argo CD) runs with crds.enabled=false.
resource "helm_release" "prometheus_operator_crds" {
  name             = "prometheus-operator-crds"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-operator-crds"
  version          = var.prometheus_operator_crds_chart_version
  namespace        = "observability"
  create_namespace = true
  wait             = true

  depends_on = [helm_release.aws_load_balancer_controller]
}

# ---------- Argo CD ----------
locals {
  alb_annotations = {
    "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"     = "ip"
    "alb.ingress.kubernetes.io/group.name"      = var.cluster_name # one ALB for app, Argo CD, Grafana
    "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\":80},{\"HTTPS\":443}]"
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    "alb.ingress.kubernetes.io/ssl-policy"      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    "alb.ingress.kubernetes.io/certificate-arn" = local.certificate_arn
  }
  argocd_metrics = { enabled = true, serviceMonitor = { enabled = true } }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [yamlencode({
    configs = {
      params = { "server.insecure" = true }         # TLS ends at the ALB
      cm     = { "timeout.reconciliation" = "60s" } # poll Git every 60 s
    }
    server = {
      metrics = local.argocd_metrics
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        hostname         = var.argocd_host
        annotations = merge(local.alb_annotations, {
          "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
          "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
        })
      }
    }
    controller     = { metrics = local.argocd_metrics }
    repoServer     = { metrics = local.argocd_metrics }
    applicationSet = { metrics = local.argocd_metrics }
  })]

  depends_on = [helm_release.aws_load_balancer_controller, helm_release.prometheus_operator_crds]
}

# ---------- Secrets (never in Git) ----------
resource "kubernetes_namespace_v1" "app" {
  metadata { name = "bmi-app" }
  depends_on = [aws_eks_node_group.general]
}

resource "random_password" "db" {
  length  = 32
  special = false # safe inside DATABASE_URL
}

resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "postgres-secret"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    POSTGRES_DB       = "bmidb"
    POSTGRES_USER     = "bmi_user"
    POSTGRES_PASSWORD = random_password.db.result
  }
}

resource "kubernetes_secret_v1" "backend" {
  metadata {
    name      = "backend-secret"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    DATABASE_URL = "postgres://bmi_user:${random_password.db.result}@bmi-postgres-svc:5432/bmidb"
  }
}

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = "observability" # created by the prometheus-operator-crds release
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana.result
  }
  depends_on = [helm_release.prometheus_operator_crds]
}

# ---------- Root Application (app-of-apps) ----------
# Shipped through the argocd-apps chart so plan works before Argo CD's CRDs exist.
resource "helm_release" "argocd_root_app" {
  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      root = {
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        project    = "default"
        source = {
          repoURL        = var.git_repo_url
          targetRevision = var.git_branch
          path           = "gitops/argocd/apps"
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.external_dns,
    kubernetes_storage_class_v1.gp3,
    kubernetes_secret_v1.postgres,
    kubernetes_secret_v1.backend,
    kubernetes_secret_v1.grafana_admin,
  ]
}

# On 'terraform destroy' this runs FIRST: delete the Argo CD apps (so the LB
# Controller removes the ALB) and the namespaces with PVCs (frees the EBS volumes)
# while the controllers are still running. Otherwise the VPC can't be deleted.
resource "terraform_data" "app_teardown" {
  input = { kubeconfig = local.kubeconfig_path }

  provisioner "local-exec" {
    when = destroy
    command = join(" && ", [
      "kubectl --kubeconfig ${self.input.kubeconfig} -n argocd delete application root --ignore-not-found --wait=true --timeout=10m",
      "kubectl --kubeconfig ${self.input.kubeconfig} -n argocd delete application bmi-app observability-extras alloy loki kube-prometheus-stack --ignore-not-found --wait=true --timeout=10m",
      "kubectl --kubeconfig ${self.input.kubeconfig} delete namespace bmi-app --ignore-not-found --wait=true --timeout=10m",
      "kubectl --kubeconfig ${self.input.kubeconfig} delete pvc --all -n observability --ignore-not-found --wait=true --timeout=10m",
    ])
  }

  depends_on = [helm_release.argocd_root_app, kubernetes_namespace_v1.app, kubernetes_secret_v1.grafana_admin]
}
