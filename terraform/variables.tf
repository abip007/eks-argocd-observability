# ---------- General ----------
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for Terraform and kubectl/helm auth. null = default credential chain."
  type        = string
  default     = "abip007"
}

variable "cluster_name" {
  description = "EKS cluster name. Prefixes IAM roles/policies, ECR repositories and the ALB group."
  type        = string
  default     = "obs-eks"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "tags" {
  type = map(string)
  default = {
    "managed-by" = "terraform"
    "project"    = "eks-argocd-observability"
  }
}

# ---------- Network ----------
variable "vpc_cidr" {
  description = "VPC CIDR (3 public /20 + 3 private /19 across 3 AZs)."
  type        = string
  default     = "10.2.0.0/16"
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (cheap). false = one per AZ (HA)."
  type        = bool
  default     = true
}

variable "api_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API, e.g. [\"203.0.113.10/32\"]."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------- Nodes ----------
variable "node_instance_types" {
  description = "Free-plan eligible: m7i-flex.large / c7i-flex.large = 29 pods/node, t3.small = 11."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  description = "3 nodes: the app plus Prometheus, Loki, Grafana and Alloy."
  type        = number
  default     = 3
}

variable "node_max_size" {
  type    = number
  default = 5
}

# ---------- DNS / TLS ----------
variable "domain_name" {
  description = "Public Route 53 hosted zone in this account."
  type        = string
  default     = "bestclick.click"
}

variable "app_host" {
  description = "Public hostname of the app (must match the overlay in gitops/)."
  type        = string
  default     = "obs-bmi.bestclick.click"
}

variable "argocd_host" {
  description = "Public hostname of the Argo CD UI."
  type        = string
  default     = "obs-argocd.bestclick.click"
}

variable "grafana_host" {
  description = "Public hostname of Grafana (must match gitops/observability/kube-prometheus-stack-values.yaml)."
  type        = string
  default     = "obs-grafana.bestclick.click"
}

variable "zone_id" {
  description = "Route 53 hosted zone ExternalDNS may write to (the one the registrar delegates to)."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate for domain + *.domain. Empty = look up the newest ISSUED one (scripts/00-configure.sh requests it)."
  type        = string
  default     = ""
}

# ---------- GitOps ----------
variable "git_repo_url" {
  description = "Git repository Argo CD watches (this project, pushed to GitHub)."
  type        = string
  default     = "https://github.com/abip007/eks-argocd-observability.git"
}

variable "git_branch" {
  type    = string
  default = "main"
}

# ---------- Versions ----------
variable "aws_lbc_version" {
  description = "LB Controller release whose gateway CRDs are installed (policies/aws-load-balancer-controller.json matches v3.6.0)."
  type        = string
  default     = "v3.6.0"
}

variable "gateway_api_version" {
  type    = string
  default = "v1.6.0"
}

variable "aws_lbc_chart_version" {
  description = "null = latest."
  type        = string
  default     = null
}

variable "external_dns_chart_version" {
  description = "null = latest."
  type        = string
  default     = null
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version; null = latest."
  type        = string
  default     = null
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version; null = latest."
  type        = string
  default     = null
}

variable "prometheus_operator_crds_chart_version" {
  description = "Keep in step with the operator inside kube-prometheus-stack (gitops/argocd/apps/kube-prometheus-stack.yaml)."
  type        = string
  default     = "33.0.1"
}
