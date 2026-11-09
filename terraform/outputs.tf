output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}${var.aws_profile == null ? "" : " --profile ${var.aws_profile}"}"
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "certificate_arn" {
  value = local.certificate_arn
}

output "app_url" {
  value = "https://${var.app_host}"
}

output "argocd_url" {
  value = "https://${var.argocd_host}"
}

output "grafana_url" {
  value = "https://${var.grafana_host}"
}

output "argocd_admin_password_command" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "grafana_admin_password_command" {
  value = "kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
}
