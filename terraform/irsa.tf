# ──────────────────────────────────────────────
# IRSA: OIDC Identity Provider for the Cluster
# ──────────────────────────────────────────────

# Every EKS cluster ships its own OIDC issuer endpoint, but IAM does not trust it
# until you register it as an identity provider. Registering it is what lets a
# Kubernetes service account assume an IAM role, which is IRSA.

# Read the TLS chain off the issuer so we can pin its thumbprint.
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.project_name}-oidc"
  }
}
