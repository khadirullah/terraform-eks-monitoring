# ──────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────

output "aws_region" {
  description = "Region everything was created in. scripts/destroy.sh reads this so the orphan sweep looks in the right place."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  description = "Base64 encoded certificate data for the cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_security_group.eks_cluster.id
}

output "node_group_name" {
  description = "Name of the EKS managed node group"
  value       = aws_eks_node_group.main.node_group_name
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider, used in IRSA role trust policies"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for the cluster"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "kubeconfig_command" {
  description = "Ready to paste command that points kubectl at this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}
